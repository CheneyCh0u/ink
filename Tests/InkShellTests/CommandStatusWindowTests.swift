import AppKit
import Foundation
import InkConfig
import TerminalCore
import Testing
@testable import InkShell

@Suite("主窗口命令状态", .serialized)
@MainActor
struct CommandStatusWindowTests {
    @Test("后台标签与项目聚合状态，选择后只清除可见标签")
    func aggregatesAndClearsVisibleTab() throws {
        let fixture = try Fixture(applicationActive: true)
        defer { fixture.cleanUp() }
        let controller = fixture.controller
        let background = try #require(fixture.panes[safe: 1])

        background.session.onEvent?(.bell)

        #expect(try attentionLabels(in: controller).contains("终端响铃"))
        #expect(try sidebarAttentionLabels(in: controller).contains("终端响铃"))

        let item = NSMenuItem()
        item.tag = 1
        controller.selectSessionMenu(item)

        #expect(try !attentionLabels(in: controller).contains("终端响铃"))
        #expect(try !sidebarAttentionLabels(in: controller).contains("终端响铃"))
    }

    @Test("重新激活只清除当前标签")
    func applicationActivationClearsCurrentOnly() throws {
        let fixture = try Fixture(applicationActive: false)
        defer { fixture.cleanUp() }
        let controller = fixture.controller
        let current = try #require(fixture.panes[safe: 0])
        let background = try #require(fixture.panes[safe: 1])

        current.session.onEvent?(.commandCompleted(.init(
            exitStatus: 0,
            duration: .seconds(3)
        )))
        background.session.onEvent?(.bell)
        #expect(try attentionLabels(in: controller).contains("命令已完成，3 秒"))
        #expect(try attentionLabels(in: controller).contains("终端响铃"))

        fixture.applicationState.isActive = true
        controller.applicationDidBecomeActive()

        #expect(try !attentionLabels(in: controller).contains("命令已完成，3 秒"))
        #expect(try attentionLabels(in: controller).contains("终端响铃"))
    }

    @Test("只为失焦十秒命令提交脱敏通知")
    func notificationGate() throws {
        let fixture = try Fixture(applicationActive: false)
        defer { fixture.cleanUp() }
        let pane = try #require(fixture.panes[safe: 0])

        pane.session.onEvent?(.bell)
        pane.session.onEvent?(.commandCompleted(.init(
            exitStatus: 1,
            duration: .milliseconds(9_999)
        )))
        pane.session.onEvent?(.commandCompleted(.init(
            exitStatus: 1,
            duration: .seconds(10)
        )))

        #expect(fixture.notifier.requests.count == 1)
        #expect(fixture.notifier.requests[0].title == "命令失败")
        #expect(fixture.notifier.requests[0].body.contains("退出状态 1"))
        #expect(fixture.notifier.requests[0].body.contains("前台"))
        #expect(!fixture.notifier.requests[0].body.contains("/"))
    }

    private func attentionLabels(in controller: MainWindowController) throws -> [String] {
        let content = try #require(controller.window?.contentView)
        let tabBar = try #require(descendants(of: TabBarView.self, in: content).first)
        tabBar.layoutSubtreeIfNeeded()
        return descendants(of: NSImageView.self, in: tabBar)
            .compactMap { $0.accessibilityLabel() }
    }

    private func sidebarAttentionLabels(
        in controller: MainWindowController
    ) throws -> [String] {
        let content = try #require(controller.window?.contentView)
        content.layoutSubtreeIfNeeded()
        return descendants(of: NSImageView.self, in: content)
            .filter { image in
                var ancestor = image.superview
                while let current = ancestor {
                    if current is TabBarView { return false }
                    ancestor = current.superview
                }
                return true
            }
            .compactMap { $0.accessibilityLabel() }
    }

    private func descendants<T: NSView>(of type: T.Type, in view: NSView) -> [T] {
        view.subviews.flatMap { child in
            ((child as? T).map { [$0] } ?? []) + descendants(of: type, in: child)
        }
    }

}

@MainActor
private final class Fixture {
    let root: URL
    let defaults: UserDefaults
    let suiteName: String
    let applicationState: ApplicationState
    let notifier: NotificationRecorder
    let panes: [TerminalPane]
    let controller: MainWindowController

    init(applicationActive: Bool) throws {
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("ink-command-status-window-\(UUID().uuidString)")
        let projectDirectory = root.appendingPathComponent("project")
        let configURL = root.appendingPathComponent("config.toml")
        try FileManager.default.createDirectory(
            at: projectDirectory,
            withIntermediateDirectories: true
        )
        suiteName = "ink.command-status-window.\(UUID().uuidString)"
        defaults = try #require(UserDefaults(suiteName: suiteName))
        defaults.removePersistentDomain(forName: suiteName)
        let state = ApplicationState(isActive: applicationActive)
        applicationState = state
        let notificationRecorder = NotificationRecorder()
        notifier = notificationRecorder

        ProjectStore.save([Project(directory: projectDirectory)], defaults: defaults)
        let projectPath = (projectDirectory.path as NSString).abbreviatingWithTildeInPath
        let workspaceStore = WorkspaceStore(defaults: defaults)
        #expect(workspaceStore.save(WorkspaceSnapshot(
            activeProjectPath: projectPath,
            projects: [
                .init(
                    path: projectPath,
                    activeTabIndex: 0,
                    tabs: [
                        Self.tab(name: "前台", directory: projectDirectory.path),
                        Self.tab(name: "后台", directory: projectDirectory.path),
                    ]
                ),
            ]
        )))

        var created: [TerminalPane] = []
        controller = MainWindowController(
            initialConfig: InkConfig(),
            configURL: configURL,
            configSyncService: ConfigSyncService(defaults: defaults),
            projectDefaults: defaults,
            workspaceStore: workspaceStore,
            startPaneOverride: { size, directory in
                let pane = TerminalPane(session: TerminalSession(
                    size: size,
                    workingDirectory: directory
                ))
                created.append(pane)
                return pane
            },
            notificationCoordinator: notificationRecorder,
            isApplicationActive: { state.isActive }
        )
        panes = created
    }

    func cleanUp() {
        controller.window?.close()
        defaults.removePersistentDomain(forName: suiteName)
        try? FileManager.default.removeItem(at: root)
    }

    private static func tab(name: String, directory: String) -> WorkspaceSnapshot.Tab {
        WorkspaceSnapshot.Tab(
            customName: name,
            activePaneID: name,
            layout: .leaf(paneID: name, workingDirectory: directory)
        )
    }
}

@MainActor
private final class NotificationRecorder: CommandNotificationCoordinating {
    private(set) var requests: [CommandNotificationRequest] = []

    func submit(_ request: CommandNotificationRequest) {
        requests.append(request)
    }
}

@MainActor
private final class ApplicationState {
    var isActive: Bool

    init(isActive: Bool) {
        self.isActive = isActive
    }
}

private extension Array {
    subscript(safe index: Index) -> Element? {
        indices.contains(index) ? self[index] : nil
    }
}
