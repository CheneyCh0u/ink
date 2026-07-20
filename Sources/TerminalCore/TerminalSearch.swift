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

/// 搜索结果的短生命周期缓存。只保留匹配坐标，不给 cell 或历史行增加常驻字段。
public struct TerminalSearchIndex: Sendable {
    enum UpdateKind: Sendable, Equatable {
        case none
        case full
        case incremental
    }

    private(set) var lastUpdateKind: UpdateKind = .none
    public private(set) var matches: [TerminalSearchMatch] = []
    /// 最近一次增量更新淘汰的历史行数，供 UI 保持当前结果身份。
    public private(set) var lastEvictedLineCount = 0

    private var query: String?
    private var layoutRevision: UInt64 = 0
    private var appendedLines: UInt64 = 0
    private var scrollbackCount = 0

    public init() {}

    @discardableResult
    public mutating func update(in terminal: Terminal, query newQuery: String) -> [TerminalSearchMatch] {
        guard !newQuery.isEmpty else {
            clear()
            return matches
        }

        let requiresFullScan = query != newQuery
            || query == nil
            || layoutRevision != terminal.searchLayoutRevision
            || appendedLines > terminal.scrollback.totalAppendedLines

        if requiresFullScan {
            matches = TerminalSearchEngine.search(in: terminal, query: newQuery)
            lastUpdateKind = .full
            lastEvictedLineCount = 0
            remember(terminal: terminal, query: newQuery)
            return matches
        }

        let appended = Int(terminal.scrollback.totalAppendedLines - appendedLines)
        let evicted = max(0, scrollbackCount + appended - terminal.scrollback.count)
        lastEvictedLineCount = evicted
        let earliestChangedLine: Int
        if appended > 0 {
            earliestChangedLine = max(0, scrollbackCount - evicted)
        } else {
            earliestChangedLine = terminal.scrollback.count
        }
        let rescanStart = rewindToLogicalLineHead(
            earliestChangedLine,
            in: terminal
        )

        var prefix: [TerminalSearchMatch] = []
        prefix.reserveCapacity(matches.count)
        for match in matches {
            var shifted = match.range
            shifted.start.line -= evicted
            shifted.end.line -= evicted
            guard shifted.start.line >= 0, shifted.end.line < rescanStart else { continue }
            prefix.append(TerminalSearchMatch(range: shifted))
        }
        prefix.append(contentsOf: TerminalSearchEngine.search(
            in: terminal,
            query: newQuery,
            fromLine: rescanStart
        ))
        matches = prefix
        lastUpdateKind = .incremental
        remember(terminal: terminal, query: newQuery)
        return matches
    }

    public mutating func clear() {
        matches.removeAll(keepingCapacity: false)
        query = nil
        layoutRevision = 0
        appendedLines = 0
        scrollbackCount = 0
        lastUpdateKind = .none
        lastEvictedLineCount = 0
    }

    private mutating func remember(terminal: Terminal, query: String) {
        self.query = query
        layoutRevision = terminal.searchLayoutRevision
        appendedLines = terminal.scrollback.totalAppendedLines
        scrollbackCount = terminal.scrollback.count
    }

    private func rewindToLogicalLineHead(_ line: Int, in terminal: Terminal) -> Int {
        var result = min(max(0, line), max(0, terminal.totalLines - 1))
        while result > 0, terminal.absoluteLine(result)?.info.isWrapped == true {
            result -= 1
        }
        return result
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
    private var utf16Length = 0

    mutating func append(cells: [Cell], line: Int, clusterTable: ClusterTable) {
        for column in cells.indices {
            let cell = cells[column]
            if cell.attr & Cell.Attr.wideTrailing != 0 { continue }

            let cellText = text(for: cell, clusterTable: clusterTable)
            let lowerBound = utf16Length
            text.append(cellText)
            utf16Length += cellText.utf16.count
            let upperBound = utf16Length
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
        utf16Length = 0
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
