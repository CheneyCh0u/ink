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

    @Test("紧凑完成记录固定为十六字节")
    func compactRecordLayout() {
        #expect(MemoryLayout<CommandCompletionRecord>.stride == 16)
        #expect(MemoryLayout<Cell>.stride == 8)
        #expect(MemoryLayout<RowInfo>.stride == 2)
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
}
