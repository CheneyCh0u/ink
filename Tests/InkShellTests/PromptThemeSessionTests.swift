import Foundation
import InkConfig
import TerminalCore
import Testing
@testable import InkShell

@Suite("提示符主题新会话接线", .serialized)
@MainActor
struct PromptThemeSessionTests {

    @Test("Ink 来源只向新会话注入管理配置")
    func inkSourceInjectsManagedConfig() throws {
        let fixture = try PromptThemeWindowFixture(source: .ink)
        defer { fixture.cleanUp() }
        let session = fixture.controller.makeTerminalSession(
            size: TerminalSize(columns: 80, rows: 24),
            workingDirectory: fixture.directory.path
        )
        #expect(session.environmentOverrides == [
            "STARSHIP_CONFIG": fixture.starshipURL.path,
        ])
        #expect(FileManager.default.fileExists(atPath: fixture.starshipURL.path))
    }

    @Test("用户来源不注入 Starship 覆盖")
    func userSourceKeepsShellEnvironment() throws {
        let fixture = try PromptThemeWindowFixture(source: .user)
        defer { fixture.cleanUp() }
        let session = fixture.controller.makeTerminalSession(
            size: TerminalSize(columns: 80, rows: 24),
            workingDirectory: fixture.directory.path
        )
        #expect(session.environmentOverrides.isEmpty)
        #expect(!FileManager.default.fileExists(atPath: fixture.starshipURL.path))
    }

    @Test("模板写入失败时回退且只警告一次")
    func installFailureFallsBackAndWarnsOnce() throws {
        let fixture = try PromptThemeWindowFixture(source: .ink, blockStarshipDirectory: true)
        defer { fixture.cleanUp() }
        _ = fixture.controller.makeTerminalSession(
            size: TerminalSize(columns: 80, rows: 24),
            workingDirectory: fixture.directory.path
        )
        let second = fixture.controller.makeTerminalSession(
            size: TerminalSize(columns: 80, rows: 24),
            workingDirectory: fixture.directory.path
        )
        #expect(second.environmentOverrides.isEmpty)
        #expect(fixture.warningCount == 1)
    }
}

@MainActor
private final class PromptThemeWindowFixture {
    let controller: MainWindowController
    let directory: URL
    let starshipURL: URL
    private let defaults: UserDefaults
    private let suiteName: String
    private let warningCounter: PromptWarningCounter

    var warningCount: Int { warningCounter.count }

    init(
        source: InkConfig.PromptThemeSource,
        blockStarshipDirectory: Bool = false
    ) throws {
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("ink-prompt-session-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        suiteName = "ink.prompt-session.\(UUID().uuidString)"
        defaults = try #require(UserDefaults(suiteName: suiteName))
        defaults.removePersistentDomain(forName: suiteName)

        var config = InkConfig()
        config.promptThemeSource = source
        let configURL = directory.appendingPathComponent("config.toml")
        try config.save(to: configURL)

        let project = Project(directory: directory)
        ProjectStore.save([project], defaults: defaults)
        let workspaceStore = WorkspaceStore(defaults: defaults)
        _ = workspaceStore.save(WorkspaceSnapshot(
            activeProjectPath: directory.path,
            projects: [
                .init(
                    path: directory.path,
                    activeTabIndex: 0,
                    tabs: [
                        .init(
                            customName: "初始",
                            activePaneID: "initial",
                            layout: .leaf(
                                paneID: "initial",
                                workingDirectory: directory.path
                            )
                        ),
                    ]
                ),
            ]
        ))

        if blockStarshipDirectory {
            let blockedParent = directory.appendingPathComponent("blocked")
            try Data("blocked".utf8).write(to: blockedParent)
            starshipURL = blockedParent.appendingPathComponent("starship.toml")
        } else {
            starshipURL = directory
                .appendingPathComponent("managed")
                .appendingPathComponent("starship.toml")
        }

        let warningCounter = PromptWarningCounter()
        self.warningCounter = warningCounter
        controller = MainWindowController(
            initialConfig: config,
            configURL: configURL,
            configSyncService: ConfigSyncService(defaults: defaults),
            projectDefaults: defaults,
            workspaceStore: workspaceStore,
            startPaneOverride: { size, workingDirectory in
                TerminalPane(session: TerminalSession(
                    size: size,
                    workingDirectory: workingDirectory
                ))
            },
            inkStarshipConfigURL: starshipURL,
            promptConfigFailureHandler: { _ in warningCounter.count += 1 }
        )
    }

    func cleanUp() {
        controller.window?.close()
        defaults.removePersistentDomain(forName: suiteName)
        try? FileManager.default.removeItem(at: directory)
    }
}

@MainActor
private final class PromptWarningCounter {
    var count = 0
}
