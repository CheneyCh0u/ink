import TerminalCore

/// 一段已经投影到当前视口的悬停链接范围。
struct TerminalLinkHighlightSpan: Sendable, Equatable {
    let visualRow: Int
    let columns: ClosedRange<Int>
}

enum TerminalLinkHighlights {
    static func project(
        range: SemanticTextRange?,
        scrollbackCount: Int,
        gridRows: Int,
        scrollOffset: Int,
        columns: Int
    ) -> [TerminalLinkHighlightSpan] {
        guard let range,
              range.start < range.end,
              gridRows > 0,
              columns > 0
        else { return [] }

        let offset = min(max(0, scrollOffset), scrollbackCount)
        let viewportStart = scrollbackCount - offset
        let viewportEnd = viewportStart + gridRows - 1
        let rangeLastLine = range.end.column == 0 ? range.end.line - 1 : range.end.line
        let firstLine = max(range.start.line, viewportStart)
        let lastLine = min(rangeLastLine, viewportEnd)
        guard firstLine <= lastLine else { return [] }

        var spans: [TerminalLinkHighlightSpan] = []
        spans.reserveCapacity(lastLine - firstLine + 1)
        for line in firstLine...lastLine {
            let lower = line == range.start.line ? range.start.column : 0
            let upper = line == range.end.line ? range.end.column - 1 : columns - 1
            let clippedLower = max(0, min(lower, columns - 1))
            let clippedUpper = max(0, min(upper, columns - 1))
            guard clippedLower <= clippedUpper else { continue }
            spans.append(TerminalLinkHighlightSpan(
                visualRow: line - viewportStart,
                columns: clippedLower...clippedUpper
            ))
        }
        return spans
    }
}
