import Testing
@testable import TerminalCore

@Suite("命令完成状态")
struct CommandStatusTests {
    @Test("只有 C 后的 D 生成带耗时与退出状态的事件")
    func completedCommandEvent() {
        var terminal = Terminal(size: .init(columns: 80, rows: 24))
        let clock = ContinuousClock()
        let start = clock.now

        terminal.handleOSC133(ArraySlice("C".utf8), now: start)
        terminal.handleOSC133(
            ArraySlice("D;7".utf8),
            now: start.advanced(by: .seconds(12) + .milliseconds(345))
        )

        #expect(terminal.takeEvents() == [
            .commandCompleted(.init(exitStatus: 7, duration: .milliseconds(12_345))),
        ])
        #expect(terminal.takeEvents().isEmpty)
    }

    @Test("B 后 D 是取消且异常状态只丢弃状态值")
    func abortAndInvalidStatus() {
        var terminal = Terminal(size: .init(columns: 80, rows: 24))
        let clock = ContinuousClock()
        terminal.handleOSC133(ArraySlice("C".utf8), now: clock.now)
        terminal.handleOSC133(ArraySlice("B".utf8), now: clock.now)
        terminal.handleOSC133(ArraySlice("D;1".utf8), now: clock.now)
        #expect(terminal.takeEvents().isEmpty)

        let start = clock.now
        terminal.handleOSC133(ArraySlice("C".utf8), now: start)
        terminal.handleOSC133(
            ArraySlice("D;999".utf8),
            now: start.advanced(by: .seconds(1))
        )
        #expect(terminal.takeEvents() == [
            .commandCompleted(.init(exitStatus: nil, duration: .seconds(1))),
        ])
    }

    @Test("重复 C 覆盖起点且 BEL 逐个上送")
    func repeatedStartAndBell() {
        var terminal = Terminal(size: .init(columns: 80, rows: 24))
        let clock = ContinuousClock()
        let first = clock.now
        let second = first.advanced(by: .seconds(5))
        terminal.handleOSC133(ArraySlice("C".utf8), now: first)
        terminal.handleOSC133(ArraySlice("C".utf8), now: second)
        terminal.execute(0x07)
        terminal.execute(0x07)
        terminal.handleOSC133(
            ArraySlice("D;0".utf8),
            now: second.advanced(by: .seconds(2))
        )
        #expect(terminal.takeEvents() == [
            .bell,
            .bell,
            .commandCompleted(.init(exitStatus: 0, duration: .seconds(2))),
        ])
    }

    @Test("Bell、命令完成与通知共享事件队列上限")
    func mixedEventsStayBounded() {
        var terminal = Terminal(size: .init(columns: 80, rows: 24))
        for _ in 0..<63 {
            terminal.execute(0x07)
        }
        let clock = ContinuousClock()
        let now = clock.now
        terminal.handleOSC133(ArraySlice("C".utf8), now: now)
        terminal.handleOSC133(ArraySlice("D;0".utf8), now: now)
        terminal.oscDispatch(ArraySlice("9;overflow".utf8))

        let events = terminal.takeEvents()
        #expect(events.count == 64)
        #expect(events.dropLast().allSatisfy { $0 == .bell })
        #expect(events.last == .commandCompleted(.init(exitStatus: 0, duration: .zero)))
    }

    @Test("紧凑完成记录固定为十六字节")
    func compactRecordLayout() {
        #expect(MemoryLayout<CommandCompletionRecord>.stride == 16)
        #expect(MemoryLayout<Cell>.stride == 8)
        #expect(MemoryLayout<RowInfo>.stride == 2)

        let saturated = CommandCompletionRecord(
            lineID: 0,
            column: 0,
            completion: .init(
                exitStatus: 0,
                duration: .milliseconds(Int64(UInt32.max) + 1_000)
            )
        )
        #expect(saturated.elapsedMilliseconds == UInt32.max)
        #expect(saturated.completion.duration == .milliseconds(Int64(UInt32.max)))
    }

    @Test("搜索快照不持有命令完成记录与待处理事件")
    func searchSnapshotDropsCommandState() {
        var terminal = Terminal(size: .init(columns: 80, rows: 24))
        let clock = ContinuousClock()
        let start = clock.now
        terminal.handleOSC133(ArraySlice("C".utf8), now: start)
        terminal.handleOSC133(
            ArraySlice("D;0".utf8),
            now: start.advanced(by: .seconds(12))
        )

        var snapshot = terminal.snapshotForSearch()

        #expect(snapshot.commandCompletionRecordCount == 0)
        #expect(snapshot.takeEvents().isEmpty)
        #expect(terminal.commandCompletionRecordCount == 1)
        #expect(terminal.takeEvents().count == 1)
    }

    @Test("scrollback 淘汰与 ED 2/3 只回收对应完成记录")
    func completionRecordLifecycle() {
        var (parser, terminal) = makeTerminal(columns: 20, rows: 2, scrollback: 2)
        for index in 0..<8 {
            feed(
                "\u{1B}]133;B\u{07}c\(index)\u{1B}]133;C\u{07}o"
                    + "\u{1B}]133;D;0\u{07}\r\n",
                &parser,
                &terminal
            )
        }
        #expect(terminal.commandCompletionRecordCount <= terminal.totalLines)
        #expect(terminal.commandBlocks().count <= 3)

        terminal.csiDispatch(
            prefix: 0,
            params: [2][...],
            intermediates: [],
            final: UInt8(ascii: "J")
        )
        #expect(terminal.commandBlocks().allSatisfy {
            $0.commandRange.end.line < terminal.scrollback.count
        })
        terminal.csiDispatch(
            prefix: 0,
            params: [3][...],
            intermediates: [],
            final: UInt8(ascii: "J")
        )
        #expect(terminal.commandCompletionRecordCount == 0)
    }

    @Test("公共清历史丢弃历史命令状态并重编号屏上完成记录")
    func directClearRebasesVisibleCommandState() throws {
        var (parser, terminal) = makeTerminal(columns: 20, rows: 2, scrollback: 20)
        feed("old\r\nolder\r\n", &parser, &terminal)
        feed(
            "\u{1B}]133;B\u{07}cmd\u{1B}]133;C\u{07}out\u{1B}]133;D;7\u{07}",
            &parser,
            &terminal
        )
        #expect(terminal.scrollback.count > 0)
        #expect(terminal.commandCompletionRecordCount == 1)

        terminal.clearScrollback()

        let block = try #require(terminal.commandBlocks().first)
        #expect(terminal.scrollback.count == 0)
        #expect(terminal.commandCompletionRecordCount == 1)
        #expect(block.commandRange.start.line < terminal.grid.size.rows)
        #expect(block.completion?.exitStatus == 7)
        #expect(terminal.extractText(in: block.commandRange) == "cmd")
        #expect(block.outputRange.map { terminal.extractText(in: $0) } == "out")
    }

    @Test("十万条密集命令记录受历史容量约束")
    func denseCommandRecordsStayBounded() {
        let commandCount = 100_000
        var parser = Parser()
        var terminal = Terminal(
            size: .init(columns: 120, rows: 50),
            scrollbackCapacity: commandCount
        )
        let bytes = Array(
            "\u{1B}]133;B\u{07}x\u{1B}]133;C\u{07}o\u{1B}]133;D;0\u{07}\r\n".utf8
        )
        for index in 0..<commandCount {
            parser.feed(bytes, handler: &terminal)
            if index.isMultiple(of: 512) { _ = terminal.takeEvents() }
        }
        _ = terminal.takeEvents()

        let beforeCount = terminal.commandCompletionRecordCount
        let clock = ContinuousClock()
        let narrow = clock.measure {
            terminal.resize(to: .init(columns: 80, rows: 50))
        }
        let wide = clock.measure {
            terminal.resize(to: .init(columns: 120, rows: 50))
        }

        #expect(beforeCount <= terminal.scrollback.count + terminal.grid.size.rows)
        #expect(terminal.commandCompletionRecordCount <= terminal.totalLines)
        #expect(MemoryLayout<CommandCompletionRecord>.stride == 16)
        print(
            "command status dense: records=\(terminal.commandCompletionRecordCount) "
                + "stride=\(MemoryLayout<CommandCompletionRecord>.stride) "
                + "narrow=\(narrow) wide=\(wide)"
        )
    }
}
