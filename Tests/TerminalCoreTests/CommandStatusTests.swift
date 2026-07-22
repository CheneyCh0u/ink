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
}
