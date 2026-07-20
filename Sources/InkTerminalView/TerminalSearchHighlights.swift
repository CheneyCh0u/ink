import TerminalCore

/// 一段已经投影到当前视口的搜索高亮。
struct TerminalSearchHighlightSpan: Sendable, Equatable {
    let visualRow: Int
    let columns: ClosedRange<Int>
    let isCurrent: Bool
}

enum TerminalSearchHighlightKind: Sendable, Equatable {
    case none
    case ordinary
    case current
}

enum TerminalSearchHighlights {
    static func project(
        matches: [TerminalSearchMatch],
        currentIndex: Int?,
        scrollbackCount: Int,
        gridRows: Int,
        scrollOffset: Int,
        columns: Int
    ) -> [TerminalSearchHighlightSpan] {
        guard gridRows > 0, columns > 0 else { return [] }
        let offset = min(max(0, scrollOffset), scrollbackCount)
        let viewportStart = scrollbackCount - offset
        let viewportEnd = viewportStart + gridRows - 1
        var spans: [TerminalSearchHighlightSpan] = []

        for (index, match) in matches.enumerated() {
            let range = match.range.normalized
            let firstLine = max(range.start.line, viewportStart)
            let lastLine = min(range.end.line, viewportEnd)
            guard firstLine <= lastLine else { continue }

            for line in firstLine...lastLine {
                let lower = line == range.start.line ? range.start.column : 0
                let upper = line == range.end.line ? range.end.column : columns - 1
                let clippedLower = max(0, min(lower, columns - 1))
                let clippedUpper = max(0, min(upper, columns - 1))
                guard clippedLower <= clippedUpper else { continue }
                spans.append(TerminalSearchHighlightSpan(
                    visualRow: line - viewportStart,
                    columns: clippedLower...clippedUpper,
                    isCurrent: index == currentIndex
                ))
            }
        }
        return spans
    }

    static func kind(
        in spans: [TerminalSearchHighlightSpan],
        visualRow: Int,
        column: Int,
        isSelected: Bool
    ) -> TerminalSearchHighlightKind {
        guard !isSelected else { return .none }
        guard let span = spans.first(where: {
            $0.visualRow == visualRow && $0.columns.contains(column)
        }) else { return .none }
        return span.isCurrent ? .current : .ordinary
    }
}
