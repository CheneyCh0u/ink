import Testing
@testable import TerminalCore

@Suite("终端历史搜索")
struct TerminalSearchTests {
    @Test("忽略大小写并按旧到新返回")
    func caseInsensitiveOrdering() {
        var (parser, terminal) = makeTerminal(columns: 12, rows: 3, scrollback: 20)
        feed("Alpha\r\nbeta ALPHA", &parser, &terminal)

        let matches = TerminalSearchEngine.search(in: terminal, query: "alpha")

        #expect(matches.map(\.range) == [
            SelectionRange(
                start: TextPosition(line: 0, column: 0),
                end: TextPosition(line: 0, column: 4)
            ),
            SelectionRange(
                start: TextPosition(line: 1, column: 5),
                end: TextPosition(line: 1, column: 9)
            ),
        ])
    }

    @Test("软折行可跨行匹配但硬换行不跨越")
    func wrapBoundarySemantics() {
        var (parser, terminal) = makeTerminal(columns: 4, rows: 4, scrollback: 20)
        feed("abcdef\r\nab\r\ncd", &parser, &terminal)

        #expect(TerminalSearchEngine.search(in: terminal, query: "def").count == 1)
        #expect(TerminalSearchEngine.search(in: terminal, query: "efab").isEmpty)
    }

    @Test("宽字符和组合簇映射回完整 cell")
    func unicodeCellMapping() {
        var (parser, terminal) = makeTerminal(columns: 16, rows: 2, scrollback: 20)
        feed("A终e\u{0301}Z", &parser, &terminal)

        let matches = TerminalSearchEngine.search(in: terminal, query: "终e\u{0301}")

        #expect(matches == [TerminalSearchMatch(range: SelectionRange(
            start: TextPosition(line: 0, column: 1),
            end: TextPosition(line: 0, column: 3)
        ))])
    }

    @Test("空查询不产生结果且重复结果不重叠")
    func emptyAndRepeatedMatches() {
        var (parser, terminal) = makeTerminal(columns: 8, rows: 2)
        feed("aaaa", &parser, &terminal)

        #expect(TerminalSearchEngine.search(in: terminal, query: "").isEmpty)
        #expect(TerminalSearchEngine.search(in: terminal, query: "aa").map(\.range) == [
            SelectionRange(
                start: TextPosition(line: 0, column: 0),
                end: TextPosition(line: 0, column: 1)
            ),
            SelectionRange(
                start: TextPosition(line: 0, column: 2),
                end: TextPosition(line: 0, column: 3)
            ),
        ])
    }

    @Test("ZWJ emoji 簇映射到所属 cell")
    func emojiClusterMapping() {
        var (parser, terminal) = makeTerminal(columns: 12, rows: 2)
        let family = "👨‍👩‍👧‍👦"
        feed("A\(family)Z", &parser, &terminal)

        #expect(TerminalSearchEngine.search(in: terminal, query: family) == [
            TerminalSearchMatch(range: SelectionRange(
                start: TextPosition(line: 0, column: 1),
                end: TextPosition(line: 0, column: 2)
            )),
        ])
    }

    @Test("同时搜索历史区和当前屏幕")
    func scrollbackAndGridCoverage() {
        var (parser, terminal) = makeTerminal(columns: 10, rows: 2, scrollback: 20)
        feed("hit old\r\nmid\r\nhit new", &parser, &terminal)

        #expect(terminal.scrollback.count == 1)
        #expect(TerminalSearchEngine.search(in: terminal, query: "hit").map(\.range) == [
            SelectionRange(
                start: TextPosition(line: 0, column: 0),
                end: TextPosition(line: 0, column: 2)
            ),
            SelectionRange(
                start: TextPosition(line: 2, column: 0),
                end: TextPosition(line: 2, column: 2)
            ),
        ])
    }

    @Test("相同查询只重扫可变后缀")
    func incrementalSuffixUpdate() {
        var (parser, terminal) = makeTerminal(columns: 12, rows: 2, scrollback: 20)
        feed("hit old\r\nkeep", &parser, &terminal)
        var index = TerminalSearchIndex()

        let first = index.update(in: terminal, query: "hit")
        #expect(index.lastUpdateKind == .full)

        feed("\r\nhit new", &parser, &terminal)
        let second = index.update(in: terminal, query: "hit")

        #expect(index.lastUpdateKind == .incremental)
        #expect(second.count == first.count + 1)
        #expect(second.last?.range.start == TextPosition(line: 2, column: 0))
    }

    @Test("环形淘汰后平移保留结果坐标")
    func ringEvictionShiftsCoordinates() {
        var (parser, terminal) = makeTerminal(columns: 12, rows: 2, scrollback: 1)
        feed("hit old\r\nhit mid\r\nplain", &parser, &terminal)
        var index = TerminalSearchIndex()
        #expect(index.update(in: terminal, query: "hit").count == 2)

        feed("\r\nhit new", &parser, &terminal)
        let matches = index.update(in: terminal, query: "hit")

        #expect(index.lastUpdateKind == .incremental)
        #expect(matches.map(\.range.start) == [
            TextPosition(line: 0, column: 0),
            TextPosition(line: 2, column: 0),
        ])
    }

    @Test("查询或 reflow 改变时执行全量扫描")
    func fullInvalidation() {
        var (parser, terminal) = makeTerminal(columns: 12, rows: 3, scrollback: 20)
        feed("hit one\r\ntwo", &parser, &terminal)
        var index = TerminalSearchIndex()
        _ = index.update(in: terminal, query: "hit")

        _ = index.update(in: terminal, query: "two")
        #expect(index.lastUpdateKind == .full)

        terminal.resize(to: TerminalSize(columns: 6, rows: 3))
        _ = index.update(in: terminal, query: "two")
        #expect(index.lastUpdateKind == .full)

        index.clear()
        #expect(index.matches.isEmpty)
        #expect(index.lastUpdateKind == .none)
    }
}
