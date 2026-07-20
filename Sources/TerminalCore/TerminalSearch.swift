import Foundation

/// 一处终端文本匹配，坐标覆盖实际占用的 cell。
public struct TerminalSearchMatch: Sendable, Equatable {
    public let range: SelectionRange

    public init(range: SelectionRange) {
        self.range = range
    }
}

/// 终端历史文本的无状态搜索入口。
public enum TerminalSearchEngine {
    public static func search(
        in terminal: Terminal,
        query: String,
        fromLine: Int = 0
    ) -> [TerminalSearchMatch] {
        guard !query.isEmpty, terminal.totalLines > 0 else { return [] }

        let firstLine = max(0, min(fromLine, terminal.totalLines))
        guard firstLine < terminal.totalLines else { return [] }

        var matches: [TerminalSearchMatch] = []
        var logicalLine = LogicalLine()

        for lineIndex in firstLine..<terminal.totalLines {
            guard let line = terminal.absoluteLine(lineIndex) else { continue }
            logicalLine.append(
                cells: line.cells,
                line: lineIndex,
                clusterTable: terminal.clusterTable
            )

            let nextIsWrapped = lineIndex + 1 < terminal.totalLines
                && (terminal.absoluteLine(lineIndex + 1)?.info.isWrapped ?? false)
            if !nextIsWrapped {
                matches.append(contentsOf: logicalLine.matches(for: query))
                logicalLine.removeAll(keepingCapacity: true)
            }
        }

        return matches
    }
}

private struct LogicalLine {
    private struct CellMapping {
        let utf16Range: Range<Int>
        let start: TextPosition
        let end: TextPosition
        let isBlank: Bool
    }

    private var text = ""
    private var mappings: [CellMapping] = []

    mutating func append(cells: [Cell], line: Int, clusterTable: ClusterTable) {
        for column in cells.indices {
            let cell = cells[column]
            if cell.attr & Cell.Attr.wideTrailing != 0 { continue }

            let cellText = text(for: cell, clusterTable: clusterTable)
            let lowerBound = text.utf16.count
            text.append(cellText)
            let upperBound = text.utf16.count
            guard upperBound > lowerBound else { continue }

            let occupiesTrailingCell = cell.attr & Cell.Attr.wideLeading != 0
                && column + 1 < cells.count
            mappings.append(CellMapping(
                utf16Range: lowerBound..<upperBound,
                start: TextPosition(line: line, column: column),
                end: TextPosition(
                    line: line,
                    column: occupiesTrailingCell ? column + 1 : column
                ),
                isBlank: cell.isBlank
            ))
        }
    }

    func matches(for query: String) -> [TerminalSearchMatch] {
        guard let lastContent = mappings.lastIndex(where: { !$0.isBlank }) else { return [] }
        let searchableLength = mappings[lastContent].utf16Range.upperBound
        guard searchableLength > 0 else { return [] }

        let source = text as NSString
        var results: [TerminalSearchMatch] = []
        var searchLocation = 0

        while searchLocation < searchableLength {
            let result = source.range(
                of: query,
                options: [.caseInsensitive],
                range: NSRange(
                    location: searchLocation,
                    length: searchableLength - searchLocation
                )
            )
            guard result.location != NSNotFound, result.length > 0 else { break }

            let resultEnd = result.location + result.length
            if let first = mappings.first(where: { $0.utf16Range.upperBound > result.location }),
               let last = mappings.last(where: {
                   $0.utf16Range.lowerBound < resultEnd
                       && $0.utf16Range.lowerBound < searchableLength
               }) {
                results.append(TerminalSearchMatch(range: SelectionRange(
                    start: first.start,
                    end: last.end
                )))
            }
            searchLocation = resultEnd
        }

        return results
    }

    mutating func removeAll(keepingCapacity: Bool) {
        text.removeAll(keepingCapacity: keepingCapacity)
        mappings.removeAll(keepingCapacity: keepingCapacity)
    }

    private func text(for cell: Cell, clusterTable: ClusterTable) -> String {
        var value = ""
        if cell.isCluster {
            for scalar in clusterTable.scalars(for: cell.scalar) {
                value.unicodeScalars.append(Unicode.Scalar(scalar) ?? "\u{FFFD}")
            }
        } else {
            value.unicodeScalars.append(Unicode.Scalar(cell.scalar) ?? "\u{FFFD}")
        }
        return value
    }
}
