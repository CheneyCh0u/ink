import AppKit
import Foundation
import InkConfig
import InkTerminalView
import Testing
import TerminalCore
@testable import InkShell

@Suite("主窗口会话布局恢复", .serialized)
@MainActor
struct WorkspaceRestoreWindowTests {
    @Test("连续结构变化合并保存最后状态")
    func persistsCoalescedStructureChanges() async throws {
        let fixture = try Fixture()
        defer { fixture.cleanUp() }
        fixture.seedWorkspace(tabNames: ["初始"])
        let controller = fixture.makeController(recorder: PaneRecorder())
        fixture.controller = controller
        let contentView = try #require(controller.window?.contentView)
        let tabBar = try #require(descendants(of: TabBarView.self, in: contentView).first)

        tabBar.onRename?(0, "重命名")
        controller.newSession(nil)
        let firstTab = NSMenuItem()
        firstTab.tag = 0
        controller.selectSessionMenu(firstTab)
        controller.splitRight(nil)

        let terminalViews = descendants(of: TerminalMetalView.self, in: contentView)
        #expect(terminalViews.count == 2)
        terminalViews[0].onFocus?()
        let split = try #require(
            descendants(of: WorkspaceSplitContainerView.self, in: contentView).first
        )
        split.onWeightsChange?(split.splitID, [0.3, 0.7])
        try await Task.sleep(for: .milliseconds(400))

        let saved = try #require(fixture.workspaceStore.load())
        #expect(saved.projects[0].tabs.map(\.customName) == ["重命名", nil])
        #expect(saved.projects[0].activeTabIndex == 0)
        #expect(saved.projects[0].tabs[0].layout.weights == [0.3, 0.7])
        #expect(saved.projects[0].tabs[0].activePaneID
                == saved.projects[0].tabs[0].layout.firstLeafID)
    }

    @Test("关闭 pane 与 shell 退出后保存收拢结果")
    func persistsRemovalAndExit() async throws {
        let fixture = try Fixture()
        defer { fixture.cleanUp() }
        fixture.seedWorkspace(tabNames: ["保留", "退出"])
        let controller = fixture.makeController(recorder: PaneRecorder())
        fixture.controller = controller

        let secondTab = NSMenuItem()
        secondTab.tag = 1
        controller.selectSessionMenu(secondTab)
        controller.splitRight(nil)
        controller.closeActivePane(nil)
        #expect(controller.currentWorkspaceSnapshot.projects[0].tabs[1].layout.paneCount == 1)

        controller.allPanes.last?.session.onExit?(0)
        try await Task.sleep(for: .milliseconds(400))

        let saved = try #require(fixture.workspaceStore.load())
        #expect(saved.projects[0].tabs.map(\.customName) == ["保留"])
        #expect(saved.projects[0].activeTabIndex == 0)
    }

    @Test("切换项目保存活动项目")
    func persistsActiveProjectSelection() async throws {
        let fixture = try Fixture()
        defer { fixture.cleanUp() }
        let second = fixture.root.appendingPathComponent("second-project")
        try FileManager.default.createDirectory(at: second, withIntermediateDirectories: true)
        let projects = [
            Project(directory: fixture.projectDirectory),
            Project(directory: second),
        ]
        ProjectStore.save(projects, defaults: fixture.defaults)
        let secondPath = (second.path as NSString).abbreviatingWithTildeInPath
        let snapshot = WorkspaceSnapshot(
            activeProjectPath: fixture.projectDisplayName,
            projects: [
                .init(
                    path: fixture.projectDisplayName,
                    activeTabIndex: 0,
                    tabs: [singleTab(
                        name: "一",
                        directory: fixture.projectDirectory.path
                    )]
                ),
                .init(
                    path: secondPath,
                    activeTabIndex: 0,
                    tabs: [singleTab(name: "二", directory: second.path)]
                ),
            ]
        )
        #expect(fixture.workspaceStore.save(snapshot))
        let controller = fixture.makeController(recorder: PaneRecorder())
        fixture.controller = controller

        controller.selectProject(at: 1)
        try await Task.sleep(for: .milliseconds(400))

        #expect(fixture.workspaceStore.load()?.activeProjectPath == secondPath)
    }

    @Test("窗口关闭先保存再清空且重复通知不覆盖")
    func windowCloseFlushesBeforeClearing() throws {
        let fixture = try Fixture()
        defer { fixture.cleanUp() }
        fixture.seedWorkspace(tabNames: ["一", "二"])
        let controller = fixture.makeController(recorder: PaneRecorder())
        fixture.controller = controller
        let contentView = try #require(controller.window?.contentView)
        let tabBar = try #require(descendants(of: TabBarView.self, in: contentView).first)
        tabBar.onRename?(0, "关闭前")

        let notification = Notification(name: NSWindow.willCloseNotification)
        controller.windowWillClose(notification)
        controller.windowWillClose(notification)

        let saved = try #require(fixture.workspaceStore.load())
        #expect(saved.projects[0].tabs.map(\.customName) == ["关闭前", "二"])
        #expect(saved.projects[0].tabs.count == 2)
        #expect(controller.allPanes.isEmpty)
    }

    @Test("启动恢复标签、活动位置、目录和全新会话")
    func restoresWorkspaceWithFreshSessions() throws {
        let fixture = try Fixture()
        defer { fixture.cleanUp() }
        let paneDirectory = fixture.projectDirectory.appendingPathComponent("Sources")
        try FileManager.default.createDirectory(
            at: paneDirectory,
            withIntermediateDirectories: true
        )
        let missingDirectory = fixture.projectDirectory.appendingPathComponent("Missing")
        ProjectStore.save(
            [Project(directory: fixture.projectDirectory)],
            defaults: fixture.defaults
        )
        ProjectStore.setActiveProjectPath(
            fixture.projectDisplayName,
            defaults: fixture.defaults
        )
        let saved = WorkspaceSnapshot(
            activeProjectPath: fixture.projectDisplayName,
            projects: [
                .init(
                    path: fixture.projectDisplayName,
                    activeTabIndex: 1,
                    tabs: [
                        .init(
                            customName: "编辑",
                            activePaneID: "editor",
                            layout: .leaf(
                                paneID: "editor",
                                workingDirectory: paneDirectory.path
                            )
                        ),
                        .init(
                            customName: "测试",
                            activePaneID: "right",
                            layout: .group(
                                axis: "leftRight",
                                weights: [1, 2],
                                children: [
                                    .leaf(
                                        paneID: "left",
                                        workingDirectory: fixture.projectDirectory.path
                                    ),
                                    .leaf(
                                        paneID: "right",
                                        workingDirectory: missingDirectory.path
                                    ),
                                ]
                            )
                        ),
                    ]
                ),
            ]
        )
        #expect(fixture.workspaceStore.save(saved))

        let recorder = PaneRecorder()
        let controller = fixture.makeController(recorder: recorder)
        fixture.controller = controller
        let restored = controller.currentWorkspaceSnapshot

        #expect(restored.activeProjectPath == fixture.projectDisplayName)
        #expect(restored.projects.count == 1)
        #expect(restored.projects[0].tabs.map(\.customName) == ["编辑", "测试"])
        #expect(restored.projects[0].activeTabIndex == 1)
        #expect(restored.projects[0].tabs[1].layout.paneCount == 2)
        #expect(recorder.directories == [
            paneDirectory.standardizedFileURL.path,
            fixture.projectDirectory.standardizedFileURL.path,
            fixture.projectDirectory.standardizedFileURL.path,
        ])
        #expect(controller.allPanes.count == 3)
        #expect(Set(controller.allPanes.map { ObjectIdentifier($0.session) }).count == 3)
        #expect(controller.allPanes.allSatisfy { $0.session.terminal.scrollback.count == 0 })
    }

    @Test("工作区快照不会重新添加已删除或缺失项目")
    func ignoresProjectsOutsideProjectStore() throws {
        let fixture = try Fixture()
        defer { fixture.cleanUp() }
        let removed = fixture.root.appendingPathComponent("removed")
        ProjectStore.save(
            [Project(directory: fixture.projectDirectory)],
            defaults: fixture.defaults
        )
        let snapshot = WorkspaceSnapshot(
            activeProjectPath: removed.path,
            projects: [
                .init(
                    path: removed.path,
                    activeTabIndex: 0,
                    tabs: [singleTab(name: "不应恢复", directory: removed.path)]
                ),
                .init(
                    path: fixture.projectDisplayName,
                    activeTabIndex: 0,
                    tabs: [singleTab(
                        name: "保留",
                        directory: fixture.projectDirectory.path
                    )]
                ),
            ]
        )
        #expect(fixture.workspaceStore.save(snapshot))

        let controller = fixture.makeController(recorder: PaneRecorder())
        fixture.controller = controller
        let restored = controller.currentWorkspaceSnapshot

        #expect(restored.projects.count == 1)
        #expect(restored.projects[0].path == fixture.projectDisplayName)
        #expect(restored.projects[0].tabs.map(\.customName) == ["保留"])
    }

    @Test("没有工作区快照时沿用旧活动项目")
    func migratesLegacyActiveProject() throws {
        let fixture = try Fixture()
        defer { fixture.cleanUp() }
        let second = fixture.root.appendingPathComponent("second")
        try FileManager.default.createDirectory(at: second, withIntermediateDirectories: true)
        ProjectStore.save(
            [
                Project(directory: fixture.projectDirectory),
                Project(directory: second),
            ],
            defaults: fixture.defaults
        )
        let secondDisplayName = (second.path as NSString).abbreviatingWithTildeInPath
        ProjectStore.setActiveProjectPath(secondDisplayName, defaults: fixture.defaults)

        let controller = fixture.makeController(recorder: PaneRecorder())
        fixture.controller = controller

        #expect(controller.currentWorkspaceSnapshot.activeProjectPath == secondDisplayName)
        #expect(controller.allPanes.isEmpty)
    }

    @Test("单个标签创建失败不影响同项目其它标签")
    func failedTabDoesNotBlockOthers() throws {
        let fixture = try Fixture()
        defer { fixture.cleanUp() }
        ProjectStore.save(
            [Project(directory: fixture.projectDirectory)],
            defaults: fixture.defaults
        )
        let snapshot = WorkspaceSnapshot(
            activeProjectPath: fixture.projectDisplayName,
            projects: [
                .init(
                    path: fixture.projectDisplayName,
                    activeTabIndex: 0,
                    tabs: [
                        singleTab(name: "失败", directory: fixture.projectDirectory.path),
                        singleTab(name: "成功", directory: fixture.projectDirectory.path),
                    ]
                ),
            ]
        )
        #expect(fixture.workspaceStore.save(snapshot))
        let recorder = PaneRecorder(failingAttempts: [1])

        let controller = fixture.makeController(recorder: recorder)
        fixture.controller = controller

        #expect(controller.currentWorkspaceSnapshot.projects[0].tabs.map(\.customName) == ["成功"])
        #expect(controller.allPanes.count == 1)
    }

    private func singleTab(
        name: String,
        directory: String
    ) -> WorkspaceSnapshot.Tab {
        WorkspaceSnapshot.Tab(
            customName: name,
            activePaneID: name,
            layout: .leaf(paneID: name, workingDirectory: directory)
        )
    }

    private func descendants<T>(of type: T.Type, in view: NSView) -> [T] {
        view.subviews.flatMap { subview in
            ((subview as? T).map { [$0] } ?? [])
                + descendants(of: type, in: subview)
        }
    }

}

@MainActor
private final class PaneRecorder {
    private(set) var directories: [String] = []
    private var attempt = 0
    private let failingAttempts: Set<Int>

    init(failingAttempts: Set<Int> = []) {
        self.failingAttempts = failingAttempts
    }

    func makePane(size: TerminalSize, directory: String) -> TerminalPane? {
        attempt += 1
        directories.append(directory)
        guard !failingAttempts.contains(attempt) else { return nil }
        return TerminalPane(session: TerminalSession(
            size: size,
            workingDirectory: directory
        ))
    }
}

@MainActor
private final class Fixture {
    let root: URL
    let projectDirectory: URL
    let configURL: URL
    let suiteName: String
    let defaults: UserDefaults
    let workspaceStore: WorkspaceStore
    var controller: MainWindowController?

    var projectDisplayName: String {
        (projectDirectory.path as NSString).abbreviatingWithTildeInPath
    }

    init() throws {
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("ink-workspace-window-\(UUID().uuidString)")
        projectDirectory = root.appendingPathComponent("project")
        configURL = root.appendingPathComponent("config.toml")
        try FileManager.default.createDirectory(
            at: projectDirectory,
            withIntermediateDirectories: true
        )
        suiteName = "ink.workspace-window-tests.\(UUID().uuidString)"
        defaults = try #require(UserDefaults(suiteName: suiteName))
        defaults.removePersistentDomain(forName: suiteName)
        workspaceStore = WorkspaceStore(defaults: defaults)
    }

    func makeController(recorder: PaneRecorder) -> MainWindowController {
        MainWindowController(
            initialConfig: InkConfig(),
            configURL: configURL,
            configSyncService: ConfigSyncService(defaults: defaults),
            projectDefaults: defaults,
            workspaceStore: workspaceStore,
            startPaneOverride: recorder.makePane
        )
    }

    func seedWorkspace(tabNames: [String]) {
        ProjectStore.save(
            [Project(directory: projectDirectory)],
            defaults: defaults
        )
        let tabs = tabNames.map { name in
            WorkspaceSnapshot.Tab(
                customName: name,
                activePaneID: name,
                layout: .leaf(
                    paneID: name,
                    workingDirectory: projectDirectory.path
                )
            )
        }
        _ = workspaceStore.save(WorkspaceSnapshot(
            activeProjectPath: projectDisplayName,
            projects: [
                .init(path: projectDisplayName, activeTabIndex: 0, tabs: tabs),
            ]
        ))
    }

    func cleanUp() {
        controller?.window?.close()
        defaults.removePersistentDomain(forName: suiteName)
        try? FileManager.default.removeItem(at: root)
    }
}

private extension WorkspaceLayoutNode {
    var firstLeafID: String? {
        switch self {
        case let .leaf(paneID, _): paneID
        case let .group(_, _, children): children.first?.firstLeafID
        }
    }
}
