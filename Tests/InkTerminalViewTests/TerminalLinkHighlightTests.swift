import Testing
import TerminalCore
@testable import InkTerminalView

@Suite("链接悬停投影")
struct TerminalLinkHighlightTests {
    @Test("半开跨行范围投影到 viewport")
    func projectsHalfOpenRange() {
        let spans = TerminalLinkHighlights.project(
            range: SemanticTextRange(
                start: TextPosition(line: 4, column: 7),
                end: TextPosition(line: 6, column: 3)
            ),
            scrollbackCount: 8,
            gridRows: 4,
            scrollOffset: 4,
            columns: 10
        )
        #expect(spans == [
            .init(visualRow: 0, columns: 7...9),
            .init(visualRow: 1, columns: 0...9),
            .init(visualRow: 2, columns: 0...2),
        ])
    }

    @Test("end 第零列不高亮下一行")
    func excludesZeroColumnEnd() {
        let spans = TerminalLinkHighlights.project(
            range: SemanticTextRange(
                start: .init(line: 4, column: 2),
                end: .init(line: 5, column: 0)
            ),
            scrollbackCount: 4,
            gridRows: 2,
            scrollOffset: 0,
            columns: 8
        )
        #expect(spans == [.init(visualRow: 0, columns: 2...7)])
    }
}
