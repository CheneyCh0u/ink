import Testing
@testable import TerminalCore

@Suite("选区与文本提取")
struct SelectionTextTests {
    @Test("跨行提取，行尾空白裁掉")
    func multilineExtract() {
        var (parser, term) = makeTerminal(columns: 10, rows: 4)
        feed("one\r\ntwo\r\nthree", &parser, &term)
        let text = term.extractText(in: SelectionRange(
            start: TextPosition(line: 0, column: 0),
            end: TextPosition(line: 2, column: 9)
        ))
        #expect(text == "one\ntwo\nthree")
    }

    @Test("软折行拼回一行——wrapped 位的回报")
    func wrappedLinesJoin() {
        var (parser, term) = makeTerminal(columns: 4, rows: 3)
        feed("abcdefgh", &parser, &term) // 折成 abcd / efgh
        let text = term.extractText(in: SelectionRange(
            start: TextPosition(line: 0, column: 0),
            end: TextPosition(line: 1, column: 3)
        ))
        #expect(text == "abcdefgh")
    }

    @Test("选区跨进 scrollback，绝对行号稳定")
    func selectionIntoScrollback() {
        var (parser, term) = makeTerminal(columns: 10, rows: 2)
        feed("old\r\nmid\r\nnew", &parser, &term) // old 已入 scrollback
        #expect(term.scrollback.count == 1)
        let text = term.extractText(in: SelectionRange(
            start: TextPosition(line: 0, column: 0),
            end: TextPosition(line: 2, column: 9)
        ))
        #expect(text == "old\nmid\nnew")
    }

    @Test("中文与簇完整提取，宽字符尾格不重复")
    func wideAndClusterExtract() {
        var (parser, term) = makeTerminal(columns: 20, rows: 2)
        feed("终A e\u{0301}b", &parser, &term)
        let text = term.extractText(in: SelectionRange(
            start: TextPosition(line: 0, column: 0),
            end: TextPosition(line: 0, column: 19)
        ))
        #expect(text == "终A e\u{0301}b")
    }

    @Test("块选（Option 矩形）每行取同一列段")
    func blockSelection() {
        var (parser, term) = makeTerminal(columns: 10, rows: 3)
        feed("abcdef\r\nghijkl\r\nmnopqr", &parser, &term)
        let text = term.extractText(in: SelectionRange(
            start: TextPosition(line: 0, column: 1),
            end: TextPosition(line: 2, column: 3),
            block: true
        ))
        #expect(text == "bcd\nhij\nnop")
    }

    @Test("双击选词：路径整选、中文整选")
    func wordSelection() {
        var (parser, term) = makeTerminal(columns: 40, rows: 2)
        feed("vim docs/road-map.md 测试文本 x", &parser, &term)
        // 光标点在路径中间
        let path = term.wordColumns(at: TextPosition(line: 0, column: 8))
        #expect(path == 4...19) // docs/road-map.md
        let cjk = term.wordColumns(at: TextPosition(line: 0, column: 23))
        #expect(cjk == 21...28) // 四个汉字八列
        // 点在空格上不选
        #expect(term.wordColumns(at: TextPosition(line: 0, column: 3)) == nil)
    }

    @Test("归一化：反向拖拽的选区等价")
    func normalization() {
        let sel = SelectionRange(
            start: TextPosition(line: 3, column: 5),
            end: TextPosition(line: 1, column: 2)
        )
        #expect(sel.contains(line: 2, column: 0))
        #expect(!sel.contains(line: 0, column: 9))
    }
}
