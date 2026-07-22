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
}
