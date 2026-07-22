import Foundation
import Testing
import TerminalCore
@testable import InkShell

@Suite("工作区运行态映射")
@MainActor
struct WorkspaceStateMapperTests {
    @Test("恢复横纵嵌套布局并生成新 pane 身份")
    func restoresNestedLayout() throws {
        let state = nestedTabState()
        var created: [TerminalPane] = []

        let tab = try #require(WorkspaceStateMapper.restoreTab(
            state,
            projectDirectory: FileManager.default.homeDirectoryForCurrentUser
        ) { directory in
            let pane = makePane(workingDirectory: directory)
            created.append(pane)
            return pane
        })

        #expect(tab.customName == "开发")
        #expect(tab.paneCount == 3)
        #expect(tab.activePane === created[2])
        #expect(Set(tab.layout.paneIDs) == Set(created.map(\.id)))
        #expect(created.map(\.id.rawValue.uuidString).allSatisfy {
            !["left", "top", "bottom"].contains($0)
        })

        guard case let .group(_, axis, weights, children) = tab.layout else {
            Issue.record("根布局应为横向分组")
            return
        }
        #expect(axis == .leftRight)
        #expect(weights == [0.25, 0.75])
        #expect(children.count == 2)
        guard case let .group(_, nestedAxis, nestedWeights, _) = children[1] else {
            Issue.record("右侧应保留纵向嵌套分组")
            return
        }
        #expect(nestedAxis == .topBottom)
        #expect(nestedWeights == [2.0 / 3.0, 1.0 / 3.0])
    }

    @Test("目录按保存值、项目、主目录逐级回退")
    func resolvesWorkingDirectoryFallbacks() throws {
        let fileManager = FileManager.default
        let root = fileManager.temporaryDirectory
            .appendingPathComponent("ink-workspace-\(UUID().uuidString)")
        let project = root.appendingPathComponent("project")
        let pane = project.appendingPathComponent("pane")
        let home = root.appendingPathComponent("home")
        try fileManager.createDirectory(at: pane, withIntermediateDirectories: true)
        try fileManager.createDirectory(at: home, withIntermediateDirectories: true)
        defer { try? fileManager.removeItem(at: root) }

        #expect(WorkspaceStateMapper.resolveWorkingDirectory(
            saved: pane.path,
            projectDirectory: project,
            homeDirectory: home
        ) == pane.standardizedFileURL.path)

        #expect(WorkspaceStateMapper.resolveWorkingDirectory(
            saved: project.appendingPathComponent("missing").path,
            projectDirectory: project,
            homeDirectory: home
        ) == project.standardizedFileURL.path)

        try fileManager.removeItem(at: project)
        #expect(WorkspaceStateMapper.resolveWorkingDirectory(
            saved: pane.path,
            projectDirectory: project,
            homeDirectory: home
        ) == home.standardizedFileURL.path)
    }

    @Test("会话查询失败时快照目录保留初始目录")
    func sessionFallsBackToInitialDirectory() {
        let directory = FileManager.default.homeDirectoryForCurrentUser.path
        let session = TerminalSession(
            size: TerminalSize(columns: 80, rows: 24),
            workingDirectory: directory
        )

        #expect(session.snapshotWorkingDirectory == directory)
    }

    @Test("捕获项目、标签、活动 pane 和递归布局")
    func capturesRuntimeState() throws {
        let projectURL = FileManager.default.homeDirectoryForCurrentUser
        let project = Project(directory: projectURL)
        let first = makePane(workingDirectory: projectURL.path)
        let second = makePane(workingDirectory: projectURL.path)
        let tab = TerminalTab(initialPane: first)
        #expect(tab.insertPane(second, splitting: first.id, direction: .right))
        tab.customName = "工作"
        project.tabs = [tab]

        let snapshot = WorkspaceStateMapper.capture(
            projects: [project],
            activeProject: project
        )
        let state = try #require(snapshot.projects.first?.tabs.first)

        #expect(snapshot.activeProjectPath == "~")
        #expect(state.customName == "工作")
        #expect(state.activePaneID == second.id.rawValue.uuidString)
        #expect(state.layout.paneCount == 2)
        #expect(state.layout.leafDirectories == ["~", "~"])
        #expect(snapshot.validated() != nil)
    }

    @Test("pane 创建失败会丢弃已创建的整标签")
    func creationFailureDiscardsPartialTab() {
        let state = nestedTabState()
        var attempts = 0
        var created: [TerminalPane] = []
        var discarded: [PaneID] = []

        let tab = WorkspaceStateMapper.restoreTab(
            state,
            projectDirectory: FileManager.default.homeDirectoryForCurrentUser,
            makePane: { directory in
                attempts += 1
                guard attempts < 3 else { return nil }
                let pane = makePane(workingDirectory: directory)
                created.append(pane)
                return pane
            },
            discardPane: { discarded.append($0.id) }
        )

        #expect(tab == nil)
        #expect(attempts == 3)
        #expect(Set(discarded) == Set(created.map(\.id)))
    }

    @Test("恢复构造器拒绝布局与 pane 字典不一致")
    func restoredTabRejectsMismatchedPanes() {
        let first = makePane(workingDirectory: nil)
        let unrelated = makePane(workingDirectory: nil)

        let tab = TerminalTab(
            restoredLayout: .leaf(first.id),
            panes: [unrelated.id: unrelated],
            activePaneID: unrelated.id,
            customName: nil
        )

        #expect(tab == nil)
    }

    private func makePane(workingDirectory: String?) -> TerminalPane {
        TerminalPane(session: TerminalSession(
            size: TerminalSize(columns: 80, rows: 24),
            workingDirectory: workingDirectory
        ))
    }

    private func nestedTabState() -> WorkspaceSnapshot.Tab {
        WorkspaceSnapshot.Tab(
            customName: "开发",
            activePaneID: "bottom",
            layout: .group(
                axis: "leftRight",
                weights: [1, 3],
                children: [
                    .leaf(paneID: "left", workingDirectory: "~"),
                    .group(
                        axis: "topBottom",
                        weights: [2, 1],
                        children: [
                            .leaf(paneID: "top", workingDirectory: "~"),
                            .leaf(paneID: "bottom", workingDirectory: "~"),
                        ]
                    ),
                ]
            )
        )
    }
}

private extension WorkspaceLayoutNode {
    var leafDirectories: [String] {
        switch self {
        case let .leaf(_, workingDirectory):
            [workingDirectory]
        case let .group(_, _, children):
            children.flatMap(\.leafDirectories)
        }
    }
}
