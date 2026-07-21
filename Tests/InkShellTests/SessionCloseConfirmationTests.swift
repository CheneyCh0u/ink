import InkPTY
import Testing
@testable import InkShell

@Suite("活跃会话关闭确认")
@MainActor
struct SessionCloseConfirmationTests {
    @Test("空闲 shell 和已退出会话无需确认")
    func idleSessionsNeedNoConfirmation() {
        let content = SessionCloseConfirmation.content(
            target: .tab,
            processes: [.shell(name: "nu"), .exited]
        )

        #expect(content == nil)
    }

    @Test("单会话显示进程和目标动作")
    func singleProgramUsesSpecificCopy() {
        let content = SessionCloseConfirmation.content(
            target: .pane,
            processes: [.program(name: "claude")]
        )

        #expect(content == SessionCloseAlertContent(
            messageText: "关闭正在运行的会话？",
            informativeText: "claude 仍在运行。关闭后，该进程会被终止。",
            destructiveButtonTitle: "关闭分屏"
        ))
    }

    @Test("退出 Ink 聚合所有活跃会话且限制名称摘要")
    func applicationQuitAggregatesPrograms() {
        let content = SessionCloseConfirmation.content(
            target: .application,
            processes: [
                .program(name: "claude"),
                .shell(name: "zsh"),
                .program(name: "vim"),
                .program(name: "ssh"),
                .program(name: "htop"),
            ]
        )

        #expect(content?.messageText == "退出 Ink 并结束 4 个活跃会话？")
        #expect(content?.informativeText == "claude、vim、ssh 等 4 个会话仍在运行。未保存的工作可能丢失。")
        #expect(content?.destructiveButtonTitle == "退出 Ink")
    }

    @Test("未知前台程序使用通用安全文案")
    func unknownProgramUsesGenericCopy() {
        let content = SessionCloseConfirmation.content(
            target: .window,
            processes: [.program(name: nil)]
        )

        #expect(content?.messageText == "关闭窗口并结束 1 个活跃会话？")
        #expect(content?.informativeText == "有会话仍在运行。关闭后，前台进程会被终止。")
    }

    @Test("取消不执行关闭，确认只执行一次")
    func coordinatorGuardsDestructiveAction() {
        let presenter = RecordingClosePresenter(result: false)
        let coordinator = SessionCloseCoordinator(presenter: presenter)
        var closeCount = 0

        #expect(!coordinator.perform(
            target: .tab,
            processes: [.program(name: "vim")]
        ) { closeCount += 1 })
        #expect(closeCount == 0)
        #expect(presenter.contents.count == 1)

        presenter.result = true
        #expect(coordinator.perform(
            target: .tab,
            processes: [.program(name: "vim")]
        ) { closeCount += 1 })
        #expect(closeCount == 1)
    }

    @Test("Command-Q 许可避免窗口重复确认")
    func applicationApprovalAvoidsDuplicateWindowPrompt() {
        let presenter = RecordingClosePresenter(result: true)
        let coordinator = SessionCloseCoordinator(presenter: presenter)
        let processes: [PTYSession.ForegroundProcess] = [.program(name: "claude")]

        #expect(coordinator.requestApplicationTermination(processes: processes))
        #expect(coordinator.allowWindowClose(processes: processes))
        #expect(presenter.contents.count == 1)
    }

    @Test("取消 Command-Q 后窗口关闭仍需重新确认")
    func cancelledApplicationTerminationDoesNotApproveWindowClose() {
        let presenter = RecordingClosePresenter(result: false)
        let coordinator = SessionCloseCoordinator(presenter: presenter)
        let processes: [PTYSession.ForegroundProcess] = [.program(name: "claude")]

        #expect(!coordinator.requestApplicationTermination(processes: processes))
        presenter.result = true
        #expect(coordinator.allowWindowClose(processes: processes))
        #expect(presenter.contents.count == 2)
    }
}

@MainActor
private final class RecordingClosePresenter: SessionClosePresenting {
    var result: Bool
    var contents: [SessionCloseAlertContent] = []

    init(result: Bool) {
        self.result = result
    }

    func confirm(_ content: SessionCloseAlertContent) -> Bool {
        contents.append(content)
        return result
    }
}
