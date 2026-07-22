import Foundation
import TerminalCore
import Testing
@testable import InkShell

@Suite("终端会话事件")
@MainActor
struct TerminalSessionEventTests {
    @Test("同一输出 chunk 的完成与 Bell 按顺序上送且只取一次")
    func forwardsEventsOnce() throws {
        let session = TerminalSession(size: .init(columns: 80, rows: 24))
        var events: [TerminalEvent] = []
        session.onEvent = { events.append($0) }

        session.consumeOutput(Data(
            "\u{07}\u{1B}]133;C\u{07}\u{1B}]133;D;2\u{07}".utf8
        ))

        #expect(events.count == 2)
        #expect(events.first == .bell)
        let last = try #require(events.last)
        guard case let .commandCompleted(completion) = last else {
            Issue.record("最后一个事件应为命令完成")
            return
        }
        #expect(completion.exitStatus == 2)

        session.detach()
        session.consumeOutput(Data("\u{07}".utf8))
        #expect(events.count == 2)
    }

    @Test("OSC 52 效果在更新前上送且不进入事件通道")
    func forwardsClipboardEffectBeforeUpdate() {
        let session = TerminalSession(size: .init(columns: 80, rows: 24))
        var order: [String] = []
        var effects: [TerminalEffect] = []
        var events: [TerminalEvent] = []
        session.onEffect = { effects.append($0); order.append("effect") }
        session.onEvent = { events.append($0) }
        session.onUpdate = { order.append("update") }
        session.consumeOutput(Data("\u{1B}]52;c;aGk=\u{07}".utf8))
        #expect(effects == [.clipboardWrite("hi")])
        #expect(events.isEmpty)
        #expect(order == ["effect", "update"])
        session.detach()
        session.consumeOutput(Data("\u{1B}]52;c;Ynll\u{07}".utf8))
        #expect(effects == [.clipboardWrite("hi")])
    }
}
