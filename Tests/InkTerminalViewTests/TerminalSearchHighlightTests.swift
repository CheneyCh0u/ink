import AppKit
import Testing
import TerminalCore
@testable import InkTerminalView

@Suite("终端搜索高亮")
@MainActor
struct TerminalSearchHighlightTests {
    @Test("只投影可见结果并裁成逐行区间")
    func visibleProjection() {
        let matches = [
            TerminalSearchMatch(range: SelectionRange(
                start: TextPosition(line: 1, column: 2),
                end: TextPosition(line: 1, column: 4)
            )),
            TerminalSearchMatch(range: SelectionRange(
                start: TextPosition(line: 8, column: 6),
                end: TextPosition(line: 10, column: 3)
            )),
        ]

        let spans = TerminalSearchHighlights.project(
            matches: matches,
            currentIndex: 1,
            scrollbackCount: 10,
            gridRows: 4,
            scrollOffset: 2,
            columns: 8
        )

        #expect(spans == [
            TerminalSearchHighlightSpan(visualRow: 0, columns: 6...7, isCurrent: true),
            TerminalSearchHighlightSpan(visualRow: 1, columns: 0...7, isCurrent: true),
            TerminalSearchHighlightSpan(visualRow: 2, columns: 0...3, isCurrent: true),
        ])
    }

    @Test("用户选区覆盖搜索样式")
    func selectionPriority() {
        let span = TerminalSearchHighlightSpan(
            visualRow: 0,
            columns: 2...4,
            isCurrent: true
        )

        #expect(TerminalSearchHighlights.kind(
            in: [span], visualRow: 0, column: 3, isSelected: false
        ) == .current)
        #expect(TerminalSearchHighlights.kind(
            in: [span], visualRow: 0, column: 3, isSelected: true
        ) == .none)
    }

    @Test("定位历史结果会滚动到视口中部")
    func revealHistoricalMatch() {
        var (parser, terminal) = makeSearchTerminal(columns: 12, rows: 4)
        for index in 0..<12 {
            parser.feed(Array("line \(index)\r\n".utf8), handler: &terminal)
        }
        let view = TerminalMetalView(frame: NSRect(x: 0, y: 0, width: 480, height: 240))
        view.terminalProvider = { terminal }
        let match = TerminalSearchMatch(range: SelectionRange(
            start: TextPosition(line: 2, column: 0),
            end: TextPosition(line: 2, column: 3)
        ))

        view.setSearchResults([match], currentIndex: 0)
        view.revealSearchResult(match)

        #expect(view.searchScrollOffset > 0)
        let viewportStart = terminal.scrollback.count - view.searchScrollOffset
        #expect((viewportStart..<(viewportStart + terminal.grid.size.rows)).contains(2))
    }

    @Test("显示和清除搜索不会改变终端格数")
    func overlayDoesNotResizeGrid() throws {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 640, height: 360),
            styleMask: [.titled],
            backing: .buffered,
            defer: false
        )
        let view = TerminalMetalView(frame: window.contentView!.bounds)
        window.contentView = view
        view.layoutSubtreeIfNeeded()
        let before = try #require(view.currentGridSize)
        let match = TerminalSearchMatch(range: SelectionRange(
            start: TextPosition(line: 0, column: 0),
            end: TextPosition(line: 0, column: 2)
        ))

        view.setSearchResults([match], currentIndex: 0)
        view.clearSearchResults()

        #expect(view.currentGridSize == before)
    }

    @Test("搜索选区在 layout revision 改变后失效")
    func searchSelectionRejectsReflow() {
        var terminal = Terminal(
            size: TerminalSize(columns: 12, rows: 2),
            scrollbackCapacity: 20
        )
        let range = SelectionRange(
            start: TextPosition(line: 0, column: 0),
            end: TextPosition(line: 0, column: 3)
        )
        let view = TerminalMetalView(frame: .zero)

        view.updateSelection(range, in: terminal)
        #expect(view.searchSelection(in: terminal) == range)

        terminal.resize(to: TerminalSize(columns: 6, rows: 2))
        #expect(view.searchSelection(in: terminal) == nil)
    }
}

private func makeSearchTerminal(columns: Int, rows: Int) -> (Parser, Terminal) {
    (Parser(), Terminal(
        size: TerminalSize(columns: columns, rows: rows),
        scrollbackCapacity: 100
    ))
}
