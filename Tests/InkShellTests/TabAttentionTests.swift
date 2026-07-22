import Foundation
import TerminalCore
import Testing
@testable import InkShell

@Suite("标签未读状态")
@MainActor
struct TabAttentionTests {
    @Test("失败高于 Bell 和成功且同级保留最新")
    func priorityAggregation() {
        let tab = TerminalTab(initialPane: makePane())
        let success = CommandCompletion(exitStatus: 0, duration: .seconds(12))
        let firstFailure = CommandCompletion(exitStatus: 4, duration: .seconds(3))
        let latestFailure = CommandCompletion(exitStatus: 8, duration: .seconds(5))

        tab.receive(.commandCompleted(success), markUnread: true)
        tab.receive(.bell, markUnread: true)
        tab.receive(.commandCompleted(firstFailure), markUnread: true)
        tab.receive(.commandCompleted(success), markUnread: true)
        tab.receive(.commandCompleted(latestFailure), markUnread: true)

        #expect(tab.attention == .failed(latestFailure))
        tab.clearAttention()
        #expect(tab.attention == nil)
    }

    @Test("前台可见事件不制造未读且项目汇总最高优先级")
    func foregroundAndProjectAggregation() {
        let project = Project(directory: FileManager.default.homeDirectoryForCurrentUser)
        let first = TerminalTab(initialPane: makePane())
        let second = TerminalTab(initialPane: makePane())
        project.tabs = [first, second]

        first.receive(.bell, markUnread: false)
        second.receive(.bell, markUnread: true)

        #expect(first.attention == nil)
        #expect(project.attention == .bell)
    }

    @Test("未知退出状态按完成处理且耗时使用紧凑中文格式")
    func unknownStatusAndDurationFormatting() {
        let completion = CommandCompletion(exitStatus: nil, duration: .seconds(61))
        #expect(TabAttention(event: .commandCompleted(completion)) == .completed(completion))
        #expect(CommandStatusFormatter.duration(.milliseconds(999)) == "<1 秒")
        #expect(CommandStatusFormatter.duration(.seconds(61)) == "1 分 01 秒")
        #expect(
            TabAttention.failed(.init(exitStatus: 2, duration: .seconds(12)))
                .presentation.symbolName == "exclamationmark.circle.fill"
        )
        #expect(TabAttention.bell.presentation.symbolName == "bell.fill")
    }

    private func makePane() -> TerminalPane {
        TerminalPane(session: TerminalSession(size: .init(columns: 80, rows: 24)))
    }
}
