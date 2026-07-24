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

    @Test("OSC 8 忽略嵌入 C0", arguments: [UInt8(0x00), 0x09, 0x0A])
    func ignoresEmbeddedC0(_ control: UInt8) throws {
        var (parser, terminal) = makeTerminal(columns: 40, rows: 3)
        let sequence = Array("\u{1B}]8;;https://one".utf8)
            + [control]
            + Array(".test\u{07}x".utf8)

        feed(sequence, &parser, &terminal)

        #expect(try #require(terminal.link(at: .init(line: 0, column: 0))).target
            == "https://one.test")
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

    @Test("emoji 序列扩宽保留基字符链接而不改绑到新目标")
    func emojiPromotionPreservesSourceLink() throws {
        var (parser, terminal) = makeTerminal(columns: 20, rows: 2)
        feed(
            "\u{1B}]8;;https://a.test\u{07}⏱"
                + "\u{1B}]8;;https://b.test\u{07}\u{FE0F}x"
                + "\u{1B}]8;;\u{07}",
            &parser,
            &terminal
        )

        #expect(try #require(terminal.link(at: .init(line: 0, column: 0))).target
            == "https://a.test")
        #expect(try #require(terminal.link(at: .init(line: 0, column: 1))).target
            == "https://a.test")
        #expect(try #require(terminal.link(at: .init(line: 0, column: 2))).target
            == "https://b.test")
    }

    @Test("无链接普通输出不分配旁路元数据")
    func plainOutputDoesNotAllocateMetadata() {
        var (parser, terminal) = makeTerminal()
        feed(String(repeating: "plain output ", count: 100), &parser, &terminal)
        #expect(!terminal.hyperlinkMetadataAllocated)
    }

    @Test("唯一 OSC 8 URI 总量受固定预算约束")
    func targetTableHasAggregateByteBudget() {
        var table = HyperlinkTargetTable()
        var accepted = 0
        for index in 0..<3_000 {
            let uri = "https://\(index).test/" + String(repeating: "x", count: 4_000)
            if table.retain(uri: uri) != nil { accepted += 1 }
        }

        #expect(accepted < 3_000)
        #expect(table.storedURIBytes <= HyperlinkTargetTable.maxStoredURIBytes)
    }

    @Test("唯一 OSC 8 目标数量也受固定预算约束")
    func targetTableHasCountBudget() {
        var table = HyperlinkTargetTable(maxStoredURIBytes: 1_024, maxTargetCount: 2)

        #expect(table.retain(uri: "a") != nil)
        #expect(table.retain(uri: "b") != nil)
        #expect(table.retain(uri: "c") == nil)
    }

    @Test("链接记录与 span 数量受固定预算约束")
    func rangeStoreHasMetadataBudgets() {
        var store = HyperlinkRangeStore(maxLineRecords: 2, maxSpans: 3)

        _ = store.replace(headLineID: 1, offsets: 0..<1, with: 1)
        _ = store.replace(headLineID: 2, offsets: 0..<1, with: 1)
        _ = store.replace(headLineID: 3, offsets: 0..<1, with: 1)
        _ = store.replace(headLineID: 1, offsets: 2..<3, with: 2)
        _ = store.replace(headLineID: 1, offsets: 4..<5, with: 3)

        #expect(store.lineCount == 2)
        #expect(store.spanCount == 3)
        #expect(store.record(headLineID: 3) == nil)
        #expect(store.record(headLineID: 1)?.spans.count == 2)
    }

    @Test("span 预算耗尽时覆写旧范围会 fail closed")
    func rangeStoreBudgetDoesNotLeaveStaleLink() {
        var store = HyperlinkRangeStore(maxLineRecords: 1, maxSpans: 1)
        _ = store.replace(headLineID: 1, offsets: 0..<3, with: 1)

        let delta = store.clear(headLineID: 1, offsets: 1..<2)

        #expect(store.record(headLineID: 1) == nil)
        #expect(store.spanCount == 0)
        #expect(delta.counts[1] == -1)
    }

    @Test("相邻不同目标顺序追加不重建已有 span")
    func fragmentedSequentialAppendStaysLinear() {
        var store = HyperlinkRangeStore(maxLineRecords: 1, maxSpans: 20_000)
        for offset in 0..<20_000 {
            _ = store.replace(
                headLineID: 1,
                offsets: UInt32(offset)..<UInt32(offset + 1),
                with: UInt32(offset.isMultiple(of: 2) ? 1 : 2)
            )
        }

        #expect(store.spanCount == 20_000)
        #expect(store.record(headLineID: 1)?.spans.count == 20_000)
    }

    @Test("reflow 多个补白 gap 以有序前缀压缩碎片范围")
    func reflowCompactsMultiplePaddingGaps() {
        var store = HyperlinkRangeStore(maxLineRecords: 1, maxSpans: 8)
        _ = store.replace(headLineID: 1, offsets: 0..<3, with: 1)
        _ = store.replace(headLineID: 1, offsets: 4..<7, with: 2)
        _ = store.replace(headLineID: 1, offsets: 8..<10, with: 1)

        _ = store.remapHeads([1: (
            headLineID: 10,
            cellCount: 8,
            removedGaps: [
                HyperlinkRemovedGap(offsets: 3..<4, removedBefore: 0),
                HyperlinkRemovedGap(offsets: 7..<8, removedBefore: 1),
            ]
        )])

        #expect(store.record(headLineID: 10)?.spans.map(\.offsets) == [0..<3, 3..<6, 6..<8])
    }

    @Test("reflow 裁掉链接空白 cell 时回收未映射范围")
    func reflowClipsLinkedBlankCell() {
        var (parser, terminal) = makeTerminal(columns: 8, rows: 3)
        feed("\r\n\r\n\u{1B}]8;;https://blank.test\u{07} \u{1B}]8;;\u{07}", &parser, &terminal)
        #expect(terminal.explicitHyperlinkRecordCount == 1)

        terminal.resize(to: TerminalSize(columns: 4, rows: 3))

        #expect(terminal.explicitHyperlinkRecordCount == 0)
        #expect(!terminal.hyperlinkMetadataAllocated)
    }

    @Test("reflow 省略光标下方链接空白行时回收范围")
    func reflowDropsOmittedLinkedBlankRow() {
        var (parser, terminal) = makeTerminal(columns: 8, rows: 3)
        feed(
            "\r\n\r\n\u{1B}]8;;https://blank.test\u{07} \u{1B}]8;;\u{07}\u{1B}[1;1H",
            &parser,
            &terminal
        )
        #expect(terminal.explicitHyperlinkRecordCount == 1)

        terminal.resize(to: TerminalSize(columns: 4, rows: 3))

        #expect(terminal.explicitHyperlinkRecordCount == 0)
        #expect(!terminal.hyperlinkMetadataAllocated)
    }

    @Test("屏幕行尾的 OSC 8 空格仍可命中")
    func linkedTrailingBlankRemainsInteractiveOnGrid() {
        var (parser, terminal) = makeTerminal(columns: 8, rows: 2)
        feed("\u{1B}]8;;https://blank.test\u{07} \u{1B}]8;;\u{07}", &parser, &terminal)

        #expect(terminal.link(at: .init(line: 0, column: 0))?.target == "https://blank.test")
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

    @Test("行尾宽字符折行会清掉补白 cell 的旧链接")
    func wideWrapClearsLinkFromPaddingCell() {
        var (parser, terminal) = makeTerminal(columns: 4, rows: 2)
        feed("abc\u{1B}]8;;https://old.test\u{07}X\u{1B}]8;;\u{07}\u{1B}[1;4H终", &parser, &terminal)

        #expect(terminal.link(at: .init(line: 0, column: 3)) == nil)
        #expect(terminal.link(at: .init(line: 1, column: 0)) == nil)
        #expect(terminal.link(at: .init(line: 1, column: 1)) == nil)
    }

    @Test("活动链接跨宽字符折行时使用一致的满宽坐标")
    func activeLinkWideWrapUsesPreservedGridCoordinates() {
        var (parser, terminal) = makeTerminal(columns: 4, rows: 2)
        feed("\u{1B}]8;;https://wide.test\u{07}abc终\u{1B}]8;;\u{07}", &parser, &terminal)

        #expect(terminal.link(at: .init(line: 0, column: 2))?.target == "https://wide.test")
        #expect(terminal.link(at: .init(line: 0, column: 3)) == nil)
        #expect(terminal.link(at: .init(line: 1, column: 0))?.target == "https://wide.test")
        #expect(terminal.link(at: .init(line: 1, column: 1))?.target == "https://wide.test")
    }

    @Test("宽字符补白行进入 scrollback 后不移动后续链接坐标")
    func wideWrapCoordinatesSurviveScrollbackTrimming() throws {
        var (parser, terminal) = makeTerminal(columns: 4, rows: 2)
        feed("\u{1B}]8;;https://wide.test\u{07}abc终\u{1B}]8;;\u{07}\r\n", &parser, &terminal)

        let link = try #require(terminal.link(at: .init(line: 1, column: 0)))
        #expect(terminal.scrollback.count == 1)
        #expect(link.range.start == TextPosition(line: 1, column: 0))
        #expect(link.range.end == TextPosition(line: 1, column: 2))

        terminal.resize(to: TerminalSize(columns: 6, rows: 2))
        let reflowed = try #require(terminal.link(at: .init(line: 0, column: 3)))
        #expect(reflowed.range.start == TextPosition(line: 0, column: 0))
        #expect(reflowed.range.end == TextPosition(line: 0, column: 5))
        #expect(terminal.link(at: .init(line: 0, column: 4))?.target == "https://wide.test")
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

    @Test("密集硬换行链接淘汰保持有界存储")
    func denseHardLineEvictionKeepsBoundedStorage() {
        var (parser, terminal) = makeTerminal(columns: 8, rows: 2, scrollback: 8)
        for _ in 0..<1_000 {
            feed("\u{1B}]8;;https://dense.test\u{07}x\u{1B}]8;;\u{07}\r\n", &parser, &terminal)
        }

        #expect(terminal.explicitHyperlinkRecordCount <= 10)
        #expect(terminal.explicitHyperlinkStorageCount <= 266)
    }

    @Test("链接与普通硬行交替时淘汰仍推进稀疏前缀")
    func alternatingHardLineEvictionKeepsBoundedStorage() {
        var (parser, terminal) = makeTerminal(columns: 8, rows: 2, scrollback: 8)
        for index in 0..<1_000 {
            if index.isMultiple(of: 2) {
                feed("\u{1B}]8;;https://sparse.test\u{07}x\u{1B}]8;;\u{07}\r\n", &parser, &terminal)
            } else {
                feed("plain\r\n", &parser, &terminal)
            }
        }

        #expect(terminal.explicitHyperlinkRecordCount <= 5)
        #expect(terminal.explicitHyperlinkStorageCount <= 261)
    }

    @Test("超长 OSC 8 逻辑行仍可通过稀疏索引命中")
    func explicitLinkBypassesAutomaticURLScanBudget() {
        var terminal = Terminal(
            size: TerminalSize(columns: 80, rows: 2),
            scrollbackCapacity: 2_000
        )
        var parser = Parser()
        feed("\u{1B}]8;;https://explicit.test\u{07}", &parser, &terminal)
        feed(String(repeating: "x", count: 70_000), &parser, &terminal)
        feed("\u{1B}]8;;\u{07}", &parser, &terminal)

        let position = TextPosition(
            line: terminal.totalLines - 1,
            column: max(0, terminal.grid.cursorCol - 1)
        )
        #expect(terminal.link(at: position)?.target == "https://explicit.test")
    }

    @Test("持续软折链接越过 scrollback 容量后保持摊销有界")
    func continuousWrappedEvictionKeepsBoundedIndex() {
        var (parser, terminal) = makeTerminal(columns: 4, rows: 2, scrollback: 8)
        feed("\u{1B}]8;;https://continuous.test\u{07}", &parser, &terminal)
        feed(String(repeating: "x", count: 20_000), &parser, &terminal)
        feed("\u{1B}]8;;\u{07}", &parser, &terminal)

        let tail = TextPosition(
            line: terminal.totalLines - 1,
            column: max(0, terminal.grid.cursorCol - 1)
        )
        #expect(terminal.link(at: tail)?.target == "https://continuous.test")
        #expect(terminal.explicitHyperlinkRecordCount == 1)
        #expect(terminal.explicitHyperlinkRowAnchorCount <= 10)
    }

    @Test("大量普通输出后首次链接从当前稳定行开始清理索引")
    func lateFirstLinkDoesNotScanFromZero() {
        var (parser, terminal) = makeTerminal(columns: 8, rows: 2, scrollback: 8)
        for _ in 0..<20_000 { feed("plain\r\n", &parser, &terminal) }
        feed("\u{1B}]8;;https://late.test\u{07}x\u{1B}]8;;\u{07}\r\n", &parser, &terminal)
        for _ in 0..<20 { feed("plain\r\n", &parser, &terminal) }

        #expect(terminal.explicitHyperlinkRecordCount == 0)
        #expect(terminal.explicitHyperlinkRowAnchorCount == 0)
    }

    @Test("搜索快照不共享链接旁路大表")
    func searchSnapshotDropsHyperlinkMetadata() {
        var (parser, terminal) = makeTerminal(columns: 8, rows: 2)
        feed("\u{1B}]8;;https://search.test\u{07}link\u{1B}]8;;\u{07}", &parser, &terminal)

        let snapshot = terminal.snapshotForSearch()

        #expect(terminal.hyperlinkMetadataAllocated)
        #expect(!snapshot.hyperlinkMetadataAllocated)
        #expect(snapshot.extractText(in: SelectionRange(
            start: TextPosition(line: 0, column: 0),
            end: TextPosition(line: 0, column: 3)
        )) == "link")
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

    @Test("公共清历史回收旧 OSC 8 并把屏上链接重编号")
    func directClearRebasesVisibleHyperlinks() {
        var (parser, terminal) = makeTerminal(columns: 10, rows: 2)
        feed(
            "\u{1B}]8;;https://old.test\u{07}old\u{1B}]8;;\u{07}\r\nnext\r\n",
            &parser,
            &terminal
        )
        feed(
            "\u{1B}]8;;https://screen.test\u{07}screen\u{1B}]8;;\u{07}",
            &parser,
            &terminal
        )
        #expect(terminal.scrollback.count > 0)

        terminal.clearScrollback()

        #expect(terminal.scrollback.count == 0)
        #expect(terminal.link(at: .init(line: 1, column: 1))?.target == "https://screen.test")
        #expect(terminal.explicitHyperlinkRecordCount == 1)
        #expect(terminal.explicitHyperlinkRowAnchorCount == 1)
    }

    @Test("备用屏清历史同时重编号可见与保存主屏链接")
    func directClearRebasesAlternateAndSavedPrimaryLinks() {
        var (parser, terminal) = makeTerminal(columns: 10, rows: 2)
        feed("old\r\nnext\r\n", &parser, &terminal)
        feed(
            "\u{1B}]8;;https://main.test\u{07}main\u{1B}]8;;\u{07}\u{1B}[?1049h",
            &parser,
            &terminal
        )
        feed("\u{1B}]8;;https://alt.test\u{07}alt\u{1B}]8;;\u{07}", &parser, &terminal)

        terminal.clearScrollback()

        #expect(terminal.link(at: .init(line: 0, column: 1))?.target == "https://alt.test")
        feed("\u{1B}[?1049l", &parser, &terminal)
        #expect(terminal.scrollback.count == 0)
        #expect(terminal.link(at: .init(line: 1, column: 1))?.target == "https://main.test")
    }
}
