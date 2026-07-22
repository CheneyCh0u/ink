import AppKit
import Foundation
import InkConfig
import TerminalCore
import Testing
@testable import InkShell

@Suite("主窗口项目导入", .serialized)
@MainActor
struct ProjectImportWindowTests {
    @Test("批量导入只为第一个新增项目创建首个会话")
    func importsBatchAndStartsOnlySelectedProject() throws {
        let fixture = try ProjectImportWindowFixture()
        defer { fixture.cleanUp() }
        let controller = fixture.makeController(existing: [fixture.existing])
        let baseline = fixture.startedDirectories.count

        controller.importProjectDirectories([fixture.first, fixture.second])

        #expect(fixture.storedDirectories() == [
            fixture.existing.standardizedFileURL,
            fixture.first.standardizedFileURL,
            fixture.second.standardizedFileURL,
        ])
        #expect(ProjectStore.activeProjectPath(in: fixture.defaults)
            == (fixture.first.path as NSString).abbreviatingWithTildeInPath)
        #expect(fixture.startedDirectories.count == baseline + 1)
        #expect(fixture.startedDirectories.last == fixture.first.path)
    }

    @Test("全部重复时不追加并选择 payload 中第一个已有项目")
    func selectsExistingDuplicateWithoutStartingAnotherPane() throws {
        let fixture = try ProjectImportWindowFixture()
        defer { fixture.cleanUp() }
        let controller = fixture.makeController(existing: [fixture.existing, fixture.first])
        let baseline = fixture.startedDirectories.count

        controller.importProjectDirectories([fixture.first, fixture.existing])

        #expect(fixture.storedDirectories() == [
            fixture.existing.standardizedFileURL,
            fixture.first.standardizedFileURL,
        ])
        #expect(ProjectStore.activeProjectPath(in: fixture.defaults)
            == (fixture.first.path as NSString).abbreviatingWithTildeInPath)
        #expect(fixture.startedDirectories.count == baseline + 1)
        #expect(fixture.startedDirectories.last == fixture.first.path)
    }
}

@MainActor
private final class ProjectImportWindowFixture {
    let root: URL
    let existing: URL
    let first: URL
    let second: URL
    let defaults: UserDefaults
    private let suiteName: String
    private let configURL: URL
    private let workspaceStore: WorkspaceStore
    private(set) var startedDirectories: [String] = []
    private var controller: MainWindowController?

    init() throws {
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("ink-project-import-window-\(UUID().uuidString)")
        existing = root.appendingPathComponent("existing", isDirectory: true)
        first = root.appendingPathComponent("first", isDirectory: true)
        second = root.appendingPathComponent("second", isDirectory: true)
        configURL = root.appendingPathComponent("config.toml")
        try FileManager.default.createDirectory(at: existing, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: first, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: second, withIntermediateDirectories: true)
        suiteName = "ink.project-import-window.\(UUID().uuidString)"
        defaults = try #require(UserDefaults(suiteName: suiteName))
        defaults.removePersistentDomain(forName: suiteName)
        workspaceStore = WorkspaceStore(defaults: defaults)
    }

    func makeController(existing directories: [URL]) -> MainWindowController {
        ProjectStore.save(directories.map { Project(directory: $0) }, defaults: defaults)
        let activePath = displayName(for: directories[0])
        ProjectStore.setActiveProjectPath(activePath, defaults: defaults)
        _ = workspaceStore.save(WorkspaceSnapshot(
            activeProjectPath: activePath,
            projects: [
                .init(
                    path: activePath,
                    activeTabIndex: 0,
                    tabs: [
                        .init(
                            customName: "已有",
                            activePaneID: "existing-pane",
                            layout: .leaf(
                                paneID: "existing-pane",
                                workingDirectory: directories[0].path
                            )
                        ),
                    ]
                ),
            ]
        ))
        let controller = MainWindowController(
            initialConfig: InkConfig(),
            configURL: configURL,
            configSyncService: ConfigSyncService(defaults: defaults),
            projectDefaults: defaults,
            workspaceStore: workspaceStore,
            startPaneOverride: { [weak self] size, directory in
                self?.startedDirectories.append(directory)
                return TerminalPane(session: TerminalSession(
                    size: size,
                    workingDirectory: directory
                ))
            }
        )
        self.controller = controller
        return controller
    }

    func storedDirectories() -> [URL] {
        ProjectStore.load(defaults: defaults).map { $0.directory.standardizedFileURL }
    }

    func cleanUp() {
        controller?.window?.close()
        defaults.removePersistentDomain(forName: suiteName)
        try? FileManager.default.removeItem(at: root)
    }

    private func displayName(for directory: URL) -> String {
        (directory.path as NSString).abbreviatingWithTildeInPath
    }
}
