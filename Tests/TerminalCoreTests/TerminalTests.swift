import Testing
@testable import TerminalCore

/// 端到端：原始字节 → Parser → Terminal → grid。
/// 所有 VT 兼容性验证都走这条路，不需要窗口。测试文件间共享。
func makeTerminal(
    columns: Int = 20, rows: Int = 5, scrollback: Int = 100
) -> (Parser, Terminal) {
    (Parser(), Terminal(size: TerminalSize(columns: columns, rows: rows), scrollbackCapacity: scrollback))
}

func feed(_ bytes: some Sequence<UInt8>, _ parser: inout Parser, _ term: inout Terminal) {
    parser.feed(Array(bytes), handler: &term)
}

func feed(_ text: String, _ parser: inout Parser, _ term: inout Terminal) {
    parser.feed(Array(text.utf8), handler: &term)
}

func rowText(_ term: Terminal, _ row: Int) -> String {
    var s = ""
    for cell in term.grid.row(row) where !cell.isCluster {
        if let scalar = UnicodeScalar(cell.scalar & ~Cell.clusterFlag) {
            s.unicodeScalars.append(scalar)
        }
    }
    return String(s.map { $0 == " " ? "·" : $0 })
}

@Suite("Parser 词法")
struct ParserLexTests {
    @Test("CSI 序列被拆在两次 feed 之间不丢")
    func csiSplitAcrossFeeds() {
        var (parser, term) = makeTerminal()
        feed("A\u{1B}[3", &parser, &term)
        feed("1;4H", &parser, &term) // CUP 31;4 → 夹到底行
        #expect(term.grid.cursorRow == 4)
        #expect(term.grid.cursorCol == 3)
    }

    @Test("UTF-8 中文被拆在两次 feed 之间不丢")
    func utf8SplitAcrossFeeds() {
        var (parser, term) = makeTerminal()
        let bytes = Array("终".utf8) // 3 字节
        feed(bytes[0..<1], &parser, &term)
        feed(bytes[1...], &parser, &term)
        #expect(term.grid[0, 0].scalar == UnicodeScalar("终").value)
    }

    @Test("OSC 以 BEL 或 ESC \\ 结束都认")
    func oscTerminators() {
        var (parser, term) = makeTerminal()
        feed("\u{1B}]0;你好\u{07}", &parser, &term)
        #expect(term.title == "你好")
        feed("\u{1B}]2;world\u{1B}\\", &parser, &term)
        #expect(term.title == "world")
    }

    @Test("CAN 中途取消 CSI，后续字节正常打印")
    func canCancelsSequence() {
        var (parser, term) = makeTerminal()
        feed([0x1B, UInt8(ascii: "["), UInt8(ascii: "3"), 0x18, UInt8(ascii: "X")], &parser, &term)
        #expect(term.grid[0, 0].scalar == UnicodeScalar("X").value)
    }

    @Test("超长普通 OSC 整条丢弃而不是执行截断前缀")
    func overlongRegularOSCDropsWholeSequence() {
        var (parser, terminal) = makeTerminal()
        feed("\u{1B}]0;before\u{07}", &parser, &terminal)
        feed("\u{1B}]0;" + String(repeating: "x", count: 4095) + "\u{07}", &parser, &terminal)
        #expect(terminal.title == "before")
    }
}

@Suite("Terminal 语义")
struct TerminalSemanticTests {
    @Test("打印与换行")
    func printAndNewline() {
        var (parser, term) = makeTerminal()
        feed("ab\r\ncd", &parser, &term)
        #expect(rowText(term, 0).hasPrefix("ab"))
        #expect(rowText(term, 1).hasPrefix("cd"))
    }

    @Test("延迟折行：写满行尾不立刻折，下一个字符才折并标记 wrapped")
    func deferredWrap() {
        var (parser, term) = makeTerminal(columns: 4, rows: 3)
        feed("abcd", &parser, &term)
        #expect(term.grid.cursorRow == 0) // 还停在首行
        feed("e", &parser, &term)
        #expect(term.grid.cursorRow == 1)
        #expect(term.grid[1, 0].scalar == UnicodeScalar("e").value)
        #expect(term.grid.info(ofRow: 1).isWrapped) // reflow 的依据
    }

    @Test("底行 LF 滚屏，滚出的行进 scrollback 且已裁尾")
    func scrollIntoScrollback() {
        var (parser, term) = makeTerminal(columns: 10, rows: 2)
        feed("one\r\ntwo\r\nthree", &parser, &term)
        #expect(term.scrollback.count == 1)
        #expect(term.scrollback[0].cells.count == 3) // "one" 裁到 3 cell
        #expect(rowText(term, 0).hasPrefix("two"))
    }

    @Test("SGR 真彩色进旁路表，16 色是调色板索引")
    func sgrColors() {
        var (parser, term) = makeTerminal()
        feed("\u{1B}[31mR\u{1B}[38;2;22;143;175mT\u{1B}[0mN", &parser, &term)
        #expect(Cell.Attr.foreground(of: term.grid[0, 0].attr) == 1) // ANSI red
        let tc = Cell.Attr.foreground(of: term.grid[0, 1].attr)
        #expect(tc >= 257)
        #expect(term.colorTable.rgb(for: tc) == 0x168FAF)
        #expect(Cell.Attr.foreground(of: term.grid[0, 2].attr) == Cell.Attr.colorDefault)
    }

    @Test("SGR 256 色与样式叠加")
    func sgr256AndStyle() {
        var (parser, term) = makeTerminal()
        feed("\u{1B}[1;4;38;5;196mX", &parser, &term)
        let attr = term.grid[0, 0].attr
        #expect(Cell.Attr.foreground(of: attr) == 196)
        #expect(attr & Cell.Attr.bold != 0)
        #expect(attr & Cell.Attr.underline != 0)
    }

    @Test("ED 2 清屏，光标不动")
    func eraseDisplay() {
        var (parser, term) = makeTerminal()
        feed("hello\u{1B}[2J", &parser, &term)
        #expect(rowText(term, 0).allSatisfy { $0 == "·" })
        #expect(term.grid.cursorCol == 5)
    }

    @Test("EL 0/1/2 按段清行")
    func eraseLine() {
        var (parser, term) = makeTerminal(columns: 6, rows: 2)
        feed("abcdef\u{1B}[3;1H", &parser, &term) // 夹到 1 行内
        feed("\u{1B}[1;4H\u{1B}[K", &parser, &term) // 光标列 3，清到行尾
        #expect(rowText(term, 0) == "abc···")
    }

    @Test("DECSTBM 区域滚动不进 scrollback，区域外不动")
    func scrollRegion() {
        var (parser, term) = makeTerminal(columns: 10, rows: 4)
        feed("top\u{1B}[2;3r", &parser, &term) // 区域 2-3 行（1 基）
        feed("\u{1B}[3;1Ha\r\nb\r\nc", &parser, &term) // 区域底部连续 LF
        #expect(rowText(term, 0).hasPrefix("top")) // 区域外保留
        #expect(term.scrollback.count == 0) // 区域滚动不入库
    }

    @Test("备用屏进出：主屏内容与光标恢复，备用屏不入 scrollback")
    func alternateScreen() {
        var (parser, term) = makeTerminal(columns: 10, rows: 3)
        feed("main\u{1B}[?1049h", &parser, &term)
        #expect(term.modes.alternateScreen)
        #expect(rowText(term, 0).allSatisfy { $0 == "·" }) // 备用屏干净
        feed("vim!\u{1B}[?1049l", &parser, &term)
        #expect(!term.modes.alternateScreen)
        #expect(rowText(term, 0).hasPrefix("main")) // 主屏回来了
        #expect(term.grid.cursorCol == 4) // 光标也回来了
    }

    @Test("IL/DL 在光标行插删行")
    func insertDeleteLines() {
        var (parser, term) = makeTerminal(columns: 5, rows: 3)
        feed("a\r\nb\r\nc\u{1B}[1;1H\u{1B}[L", &parser, &term)
        #expect(rowText(term, 0).allSatisfy { $0 == "·" })
        #expect(rowText(term, 1).hasPrefix("a"))
        feed("\u{1B}[M", &parser, &term)
        #expect(rowText(term, 0).hasPrefix("a"))
    }

    @Test("ICH/DCH 行内插删字符")
    func insertDeleteChars() {
        var (parser, term) = makeTerminal(columns: 6, rows: 1)
        feed("abcde\u{1B}[1;2H\u{1B}[2@", &parser, &term) // b 前插 2 空格
        #expect(rowText(term, 0) == "a··bcd")
        feed("\u{1B}[2P", &parser, &term) // 再删掉空格；e 已被 ICH 挤出行尾，不回来
        #expect(rowText(term, 0) == "abcd··")
    }

    @Test("DECAWM 关闭后行尾不折行，末列覆写")
    func autowrapOff() {
        var (parser, term) = makeTerminal(columns: 4, rows: 2)
        feed("\u{1B}[?7labcdXY", &parser, &term)
        #expect(term.grid.cursorRow == 0)
        #expect(term.grid[0, 3].scalar == UnicodeScalar("Y").value)
    }

    @Test("bracketed paste 模式位记录")
    func bracketedPasteMode() {
        var (parser, term) = makeTerminal()
        feed("\u{1B}[?2004h", &parser, &term)
        #expect(term.modes.bracketedPaste)
        feed("\u{1B}[?2004l", &parser, &term)
        #expect(!term.modes.bracketedPaste)
    }

    @Test("OSC 133 语义标记落到行元数据")
    func osc133Semantic() {
        var (parser, term) = makeTerminal()
        feed("\u{1B}]133;A\u{07}$ ", &parser, &term)
        #expect(term.grid.info(ofRow: 0).semanticMark == .prompt)
        #expect(term.grid.info(ofRow: 0).semanticTransitionColumn == 0)
        feed("\u{1B}]133;B\u{07}echo hi", &parser, &term)
        #expect(term.grid.info(ofRow: 0).semanticMark == .command)
        #expect(term.grid.info(ofRow: 0).semanticTransitionColumn == 2)
        feed("\u{1B}]133;C\u{07}\r\nout", &parser, &term)
        #expect(term.grid.info(ofRow: 0).semanticMark == .output)
        #expect(term.grid.info(ofRow: 0).semanticTransitionColumn == 9)
        #expect(term.grid.info(ofRow: 1).semanticMark == .output)
        #expect(term.grid.info(ofRow: 1).semanticTransitionColumn == nil)
    }

    @Test("未知 OSC 133 子命令不伪造语义转换点")
    func unknownOSC133DoesNotStampTransition() {
        var (parser, term) = makeTerminal()
        feed("\u{1B}]133;A\u{07}$ \u{1B}]133;Z\u{07}", &parser, &term)
        #expect(term.grid.info(ofRow: 0).semanticMark == .prompt)
        #expect(term.grid.info(ofRow: 0).semanticTransitionColumn == 0)
    }

    @Test("延迟折行时 OSC 133 边界落在行尾之后")
    func osc133AfterPendingWrap() {
        var (parser, term) = makeTerminal(columns: 4, rows: 3)
        feed("1234\u{1B}]133;B\u{07}x", &parser, &term)
        #expect(term.grid.info(ofRow: 0).semanticTransitionColumn == 4)
        #expect(term.grid.info(ofRow: 1).semanticMark == .command)
    }

    @Test("DSR 光标位置查询有应答——TUI 探测卡死的根源")
    func deviceStatusReport() {
        var (parser, term) = makeTerminal()
        feed("ab\u{1B}[6n", &parser, &term)
        #expect(term.takeResponses() == Array("\u{1B}[1;3R".utf8))
        #expect(term.takeResponses().isEmpty) // 取走即清空
        feed("\u{1B}[c", &parser, &term)
        #expect(!term.takeResponses().isEmpty) // DA1 有回音即可
    }

    @Test("RIS 全量重置")
    func fullReset() {
        var (parser, term) = makeTerminal()
        feed("junk\u{1B}[31m\u{1B}c X", &parser, &term)
        #expect(rowText(term, 0).hasPrefix("·X")) // 空格 + X，颜色已重置
        #expect(Cell.Attr.foreground(of: term.grid[0, 1].attr) == Cell.Attr.colorDefault)
    }
}
