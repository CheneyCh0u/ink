import Testing
@testable import TerminalCore

@Suite("OSC 8 超链接")
struct OSC8HyperlinkTests {
    @Test("BEL 与 ST 终止的显式链接可查询")
    func parsesBothTerminators() throws {
        var (parser, terminal) = makeTerminal(columns: 40, rows: 3)
        feed("\u{1B}]8;;https://one.test\u{07}one\u{1B}]8;;\u{07} ", &parser, &terminal)
        feed("\u{1B}]8;id=x;https://two.test\u{1B}\\two\u{1B}]8;;\u{1B}\\", &parser, &terminal)

        #expect(try #require(terminal.link(at: .init(line: 0, column: 1))).target == "https://one.test")
        #expect(try #require(terminal.link(at: .init(line: 0, column: 5))).target == "https://two.test")
    }

    @Test("结束和替换目标会形成两个合并范围")
    func closesAndReplacesTarget() throws {
        var (parser, terminal) = makeTerminal(columns: 40, rows: 2)
        feed("\u{1B}]8;;https://a.test\u{07}abc\u{1B}]8;;https://b.test\u{07}def\u{1B}]8;;\u{07}x", &parser, &terminal)

        #expect(try #require(terminal.link(at: .init(line: 0, column: 2))).source == .osc8)
        #expect(try #require(terminal.link(at: .init(line: 0, column: 4))).target == "https://b.test")
        #expect(terminal.link(at: .init(line: 0, column: 6)) == nil)
        #expect(terminal.explicitHyperlinkRecordCount == 1)
    }

    @Test("无链接普通输出不分配旁路元数据")
    func plainOutputDoesNotAllocateMetadata() {
        var (parser, terminal) = makeTerminal()
        feed(String(repeating: "plain output ", count: 100), &parser, &terminal)
        #expect(!terminal.hyperlinkMetadataAllocated)
    }

    @Test("无效 UTF-8 OSC 8 不改变当前活动目标")
    func invalidSequenceKeepsActiveTarget() throws {
        var (parser, terminal) = makeTerminal(columns: 30, rows: 2)
        feed("\u{1B}]8;;https://safe.test\u{07}a", &parser, &terminal)
        feed([0x1B, 0x5D, 0x38, 0x3B, 0x3B, 0xFF, 0x07, 0x62], &parser, &terminal)
        #expect(try #require(terminal.link(at: .init(line: 0, column: 1))).target == "https://safe.test")
    }

    @Test("分片 OSC 8 保持解析状态，显式目标优先于可见 URL")
    func splitSequenceAndExplicitPrecedence() throws {
        var (parser, terminal) = makeTerminal(columns: 40, rows: 2)
        feed("\u{1B}]8;;https://target", &parser, &terminal)
        feed(".test\u{07}https://visible.test\u{1B}]8;;\u{07}", &parser, &terminal)
        let link = try #require(terminal.link(at: .init(line: 0, column: 10)))
        #expect(link.target == "https://target.test")
        #expect(link.source == .osc8)
    }

    @Test("无链接覆写会分裂旧范围")
    func overwriteSplitsOldRange() {
        var (parser, terminal) = makeTerminal(columns: 12, rows: 2)
        feed("\u{1B}]8;;https://a.test\u{07}abcdef\u{1B}]8;;\u{07}", &parser, &terminal)
        feed("\u{1B}[1;3HX", &parser, &terminal)

        #expect(terminal.link(at: .init(line: 0, column: 2)) == nil)
        #expect(terminal.link(at: .init(line: 0, column: 0))?.target == "https://a.test")
        #expect(terminal.link(at: .init(line: 0, column: 4))?.target == "https://a.test")
    }

    @Test("ECH 与 EL 删除相交链接")
    func eraseRemovesRanges() {
        var (parser, terminal) = makeTerminal(columns: 12, rows: 2)
        feed("\u{1B}]8;;https://a.test\u{07}abcdef\u{1B}]8;;\u{07}", &parser, &terminal)
        feed("\u{1B}[1;3H\u{1B}[2X", &parser, &terminal)
        #expect(terminal.link(at: .init(line: 0, column: 2)) == nil)
        #expect(terminal.link(at: .init(line: 0, column: 4))?.target == "https://a.test")
        feed("\u{1B}[1;5H\u{1B}[K", &parser, &terminal)
        #expect(terminal.link(at: .init(line: 0, column: 4)) == nil)
    }

    @Test("ICH 与 DCH 只移动当前物理行链接片段")
    func insertDeleteCharactersMoveRanges() {
        var (parser, terminal) = makeTerminal(columns: 8, rows: 2)
        feed("x\u{1B}]8;;https://a.test\u{07}abc\u{1B}]8;;\u{07}yz", &parser, &terminal)
        feed("\u{1B}[1;2H\u{1B}[@", &parser, &terminal)
        #expect(terminal.link(at: .init(line: 0, column: 1)) == nil)
        #expect(terminal.link(at: .init(line: 0, column: 2))?.target == "https://a.test")
        feed("\u{1B}[P", &parser, &terminal)
        #expect(terminal.link(at: .init(line: 0, column: 1))?.target == "https://a.test")
        #expect(terminal.link(at: .init(line: 0, column: 4)) == nil)
    }

    @Test("宽字符两格命中，组合字符不扩张 cell 范围")
    func wideAndCombiningCells() throws {
        var (parser, terminal) = makeTerminal(columns: 12, rows: 2)
        feed("\u{1B}]8;;https://a.test\u{07}终e\u{301}\u{1B}]8;;\u{07}", &parser, &terminal)
        #expect(terminal.link(at: .init(line: 0, column: 0))?.target == "https://a.test")
        #expect(terminal.link(at: .init(line: 0, column: 1))?.target == "https://a.test")
        #expect(try #require(terminal.link(at: .init(line: 0, column: 2))).range.end.column == 3)
    }

    @Test("ED 清理可见范围，RIS 清理目标与所有旁路状态")
    func displayEraseAndResetClearMetadata() {
        var (parser, terminal) = makeTerminal(columns: 12, rows: 2)
        feed("\u{1B}]8;;https://a.test\u{07}abcdef\u{1B}]8;;\u{07}\u{1B}[2J", &parser, &terminal)
        #expect(terminal.explicitHyperlinkRecordCount == 0)
        feed("\u{1B}]8;;https://b.test\u{07}x\u{1B}c", &parser, &terminal)
        #expect(!terminal.hyperlinkMetadataAllocated)
    }

    @Test("局部 IL/DL 搬移链接且不写入 scrollback")
    func regionalLineMovesPreserveLinks() {
        var (parser, terminal) = makeTerminal(columns: 10, rows: 4)
        feed("top\r\n\u{1B}]8;;https://a.test\u{07}link\u{1B}]8;;\u{07}", &parser, &terminal)
        feed("\u{1B}[2;4r\u{1B}[2;1H\u{1B}[L", &parser, &terminal)
        #expect(terminal.link(at: .init(line: 2, column: 1))?.target == "https://a.test")
        #expect(terminal.scrollback.count == 0)
        feed("\u{1B}[M", &parser, &terminal)
        #expect(terminal.link(at: .init(line: 1, column: 1))?.target == "https://a.test")
    }

    @Test("主屏范围跨备用屏恢复，活动目标保持")
    func alternateScreenKeepsSeparateRanges() {
        var (parser, terminal) = makeTerminal(columns: 12, rows: 3)
        feed("\u{1B}]8;;https://active.test\u{07}main\u{1B}[?1049h", &parser, &terminal)
        feed("alt", &parser, &terminal)
        #expect(terminal.link(at: .init(line: 0, column: 1))?.target == "https://active.test")
        feed("\u{1B}]8;;https://alt.test\u{07}z\u{1B}]8;;https://active.test\u{07}", &parser, &terminal)
        #expect(terminal.link(at: .init(line: 0, column: 3))?.target == "https://alt.test")
        feed("\u{1B}[?1049lX\u{1B}]8;;\u{07}", &parser, &terminal)
        #expect(terminal.link(at: .init(line: 0, column: 1))?.target == "https://active.test")
        #expect(terminal.link(at: .init(line: 0, column: 3))?.target == "https://active.test")
        #expect(terminal.link(at: .init(line: 0, column: 4))?.target == "https://active.test")
    }

    @Test("备用屏 resize 分别裁剪主屏与备用屏范围")
    func alternateScreenResizeClipsBothStores() {
        var (parser, terminal) = makeTerminal(columns: 8, rows: 2)
        feed("\u{1B}]8;;https://main.test\u{07}abcdef\u{1B}]8;;\u{07}\u{1B}[?1049h", &parser, &terminal)
        feed("\u{1B}]8;;https://alt.test\u{07}uvwxyz\u{1B}]8;;\u{07}", &parser, &terminal)

        terminal.resize(to: TerminalSize(columns: 4, rows: 2))
        #expect(terminal.link(at: .init(line: 0, column: 3))?.target == "https://alt.test")
        feed("\u{1B}[?1049l", &parser, &terminal)

        let link = terminal.link(at: .init(line: 0, column: 3))
        #expect(link?.target == "https://main.test")
        #expect(link?.range.end.column == 4)
    }

    @Test("环淘汰最终释放显式链接记录")
    func ringEvictionPrunesRecords() {
        var (parser, terminal) = makeTerminal(columns: 5, rows: 2, scrollback: 2)
        feed("\u{1B}]8;;https://a.test\u{07}abcdefghij\u{1B}]8;;\u{07}\r\n", &parser, &terminal)
        feed("one\r\ntwo\r\nthree\r\nfour\r\n", &parser, &terminal)
        #expect(terminal.explicitHyperlinkRecordCount == 0)
    }

    @Test("环淘汰逻辑头行后重定位仍存活的折行范围")
    func ringEvictionRebasesWrappedContinuation() {
        var (parser, terminal) = makeTerminal(columns: 5, rows: 2, scrollback: 1)
        feed("\u{1B}]8;;https://a.test\u{07}abcdefghij\u{1B}]8;;\u{07}\r\n", &parser, &terminal)
        feed("x\r\n", &parser, &terminal)
        #expect(terminal.link(at: .init(line: 0, column: 1))?.target == "https://a.test")
    }

    @Test("反向索引与 CSI T 向下滚动时搬移链接")
    func downwardScrollMovesLinks() {
        var (parser, terminal) = makeTerminal(columns: 10, rows: 4)
        feed("\r\n\u{1B}]8;;https://a.test\u{07}link\u{1B}]8;;\u{07}\u{1B}[1;1H\u{1B}M", &parser, &terminal)
        #expect(terminal.link(at: .init(line: 2, column: 1))?.target == "https://a.test")
        feed("\u{1B}[T", &parser, &terminal)
        #expect(terminal.link(at: .init(line: 3, column: 1))?.target == "https://a.test")
    }

    @Test("ED 3 清除历史链接但保留屏幕链接")
    func clearScrollbackRemovesOnlyHistoryRanges() {
        var (parser, terminal) = makeTerminal(columns: 10, rows: 2)
        feed("\u{1B}]8;;https://old.test\u{07}old\u{1B}]8;;\u{07}\r\nnext\r\n", &parser, &terminal)
        feed("\u{1B}]8;;https://screen.test\u{07}screen\u{1B}]8;;\u{07}\u{1B}[3J", &parser, &terminal)
        #expect(terminal.scrollback.count == 0)
        #expect(terminal.link(at: .init(line: 1, column: 1))?.target == "https://screen.test")
    }
}
