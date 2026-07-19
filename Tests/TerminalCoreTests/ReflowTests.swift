import Testing
@testable import TerminalCore

@Suite("Reflow")
struct ReflowTests {
    @Test("变窄重折：26 字符在 10 列下切成 10+10+6，延续行带 wrapped")
    func narrowRewrap() {
        var (parser, term) = makeTerminal(columns: 20, rows: 5)
        feed("abcdefghijklmnopqrstuvwxyz", &parser, &term) // 20 + 6(wrapped)

        term.resize(to: TerminalSize(columns: 10, rows: 5))
        #expect(rowText(term, 0) == "abcdefghij")
        #expect(rowText(term, 1) == "klmnopqrst")
        #expect(rowText(term, 2).hasPrefix("uvwxyz"))
        #expect(!term.grid.info(ofRow: 0).isWrapped)
        #expect(term.grid.info(ofRow: 1).isWrapped)
        #expect(term.grid.info(ofRow: 2).isWrapped)
        // 光标跟着内容末尾走。
        #expect(term.grid.cursorRow == 2)
        #expect(term.grid.cursorCol == 6)
    }

    @Test("变宽拼回：重折的行合并成整行，逻辑行只有一条")
    func widenRejoin() {
        var (parser, term) = makeTerminal(columns: 10, rows: 5)
        feed("abcdefghijklmnopqrstuvwxyz", &parser, &term)
        term.resize(to: TerminalSize(columns: 40, rows: 5))

        #expect(rowText(term, 0).hasPrefix("abcdefghijklmnopqrstuvwxyz"))
        #expect(rowText(term, 1).allSatisfy { $0 == "·" })
        let text = term.extractText(in: SelectionRange(
            start: TextPosition(line: 0, column: 0),
            end: TextPosition(line: 0, column: 39)
        ))
        #expect(text == "abcdefghijklmnopqrstuvwxyz")
    }

    @Test("宽字符不从中间劈开")
    func wideCharNotSplit() {
        var (parser, term) = makeTerminal(columns: 6, rows: 4)
        feed("ab终cd", &parser, &term) // a b 终终 c d 恰好 6 列
        term.resize(to: TerminalSize(columns: 3, rows: 4))

        #expect(rowText(term, 0) == "ab·") // 终 占 2 列放不进剩余 1 列，整字下移
        #expect(term.grid[1, 0].scalar == UnicodeScalar("终").value)
        #expect(term.grid[1, 0].attr & Cell.Attr.wideLeading != 0)
        #expect(rowText(term, 2).hasPrefix("d"))
    }

    @Test("跨 scrollback 边界的软折行拼回一条")
    func rejoinAcrossScrollback() {
        var (parser, term) = makeTerminal(columns: 10, rows: 2)
        feed("0123456789012345678901234", &parser, &term) // 25 字符 → 3 行，首行已入 scrollback
        #expect(term.scrollback.count == 1)

        term.resize(to: TerminalSize(columns: 30, rows: 2))
        #expect(term.scrollback.count == 0)
        #expect(rowText(term, 0).hasPrefix("0123456789012345678901234"))
        #expect(term.grid.cursorCol == 25)
    }

    @Test("语义标记随逻辑行保留到每个重折块")
    func semanticSurvivesReflow() {
        var (parser, term) = makeTerminal(columns: 20, rows: 4)
        feed("\u{1B}]133;C\u{07}abcdefghijklmnopqrstuvwxyz", &parser, &term)
        term.resize(to: TerminalSize(columns: 10, rows: 4))
        #expect(term.grid.info(ofRow: 0).semantic == SemanticMark.output.rawValue)
        #expect(term.grid.info(ofRow: 1).semantic == SemanticMark.output.rawValue)
    }

    @Test("备用屏不 reflow，只裁剪")
    func altScreenSkipsReflow() {
        var (parser, term) = makeTerminal(columns: 20, rows: 4)
        feed("\u{1B}[?1049habcdefghijklmnopqrst", &parser, &term) // 备用屏满一行
        term.resize(to: TerminalSize(columns: 10, rows: 4))
        // 裁剪语义：前 10 个字符保留，无 wrapped 行产生。
        #expect(rowText(term, 0) == "abcdefghij")
        #expect(!term.grid.info(ofRow: 1).isWrapped)
    }

    @Test("只改行数也走 reflow：顶部行滑入 scrollback")
    func rowsShrinkPushesToScrollback() {
        var (parser, term) = makeTerminal(columns: 20, rows: 4)
        feed("one\r\ntwo\r\nthree", &parser, &term)
        term.resize(to: TerminalSize(columns: 20, rows: 2))
        #expect(term.scrollback.count >= 1)
        #expect(rowText(term, 1).hasPrefix("three")) // 光标附近的内容留在屏上
        #expect(term.grid.cursorRow == 1)
    }
}
