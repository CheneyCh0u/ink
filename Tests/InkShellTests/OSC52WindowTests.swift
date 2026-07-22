import AppKit
import Foundation
import InkConfig
import Testing
@testable import InkShell

@Suite("OSC 52 窗口接线", .serialized)
@MainActor
struct OSC52WindowTests {
    @Test("写入器支持普通和空字符串")
    func writerWritesAndClears() {
        let pasteboard = NSPasteboard(name: .init("ink.osc52.\(UUID().uuidString)"))
        let writer = OSC52PasteboardWriter(pasteboard: pasteboard)
        #expect(writer.write("secret"))
        #expect(pasteboard.string(forType: .string) == "secret")
        #expect(writer.write(""))
        #expect(pasteboard.string(forType: .string) == "")
    }
}

@MainActor
private final class OSC52WriterRecorder: OSC52PasteboardWriting {
    var values: [String] = []
    func write(_ text: String) -> Bool { values.append(text); return true }
}

@MainActor
private final class OSC52NotificationRecorder: CommandNotificationCoordinating {
    var requests: [CommandNotificationRequest] = []
    func submit(_ request: CommandNotificationRequest) { requests.append(request) }
}

@MainActor
private final class OSC52WindowFixture {
    let root: URL
    let defaults: UserDefaults
    let controller: MainWindowController
    let panes: [TerminalPane]
    let writer = OSC52WriterRecorder()
    let notifier = OSC52NotificationRecorder()
    private let suiteName: String

    init(enabled: Bool) throws {
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("ink-osc52-window-\(UUID().uuidString)")
        let projectDirectory = root.appendingPathComponent("project")
        let configURL = root.appendingPathComponent("config.toml")
        try FileManager.default.createDirectory(at: projectDirectory, withIntermediateDirectories: true)
        suiteName = "ink.osc52-window.\(UUID().uuidString)"
        defaults = try #require(UserDefaults(suiteName: suiteName))
        defaults.removePersistentDomain(forName: suiteName)
        ProjectStore.save([Project(directory: projectDirectory)], defaults: defaults)

        let path = (projectDirectory.path as NSString).abbreviatingWithTildeInPath
        let workspaceStore = WorkspaceStore(defaults: defaults)
        #expect(workspaceStore.save(WorkspaceSnapshot(
            activeProjectPath: path,
            projects: [.init(path: path, activeTabIndex: 0, tabs: [
                .init(customName: "前台", activePaneID: "front", layout: .leaf(paneID: "front", workingDirectory: projectDirectory.path)),
                .init(customName: "后台", activePaneID: "back", layout: .leaf(paneID: "back", workingDirectory: projectDirectory.path)),
            ])]
        )))

        var config = InkConfig()
        config.osc52WriteEnabled = enabled
        var created: [TerminalPane] = []
        controller = MainWindowController(
            initialConfig: config,
            configURL: configURL,
            configSyncService: ConfigSyncService(defaults: defaults),
            projectDefaults: defaults,
            workspaceStore: workspaceStore,
            startPaneOverride: { size, directory in
                let pane = TerminalPane(session: TerminalSession(size: size, workingDirectory: directory))
                created.append(pane)
                return pane
            },
            notificationCoordinator: notifier,
            isApplicationActive: { false },
            osc52PasteboardWriter: writer
        )
        panes = created
    }

    func data(_ text: String) -> Data {
        let payload = Data(text.utf8).base64EncodedString()
        return Data("\u{1B}]52;c;\(payload)\u{07}".utf8)
    }

    func cleanUp() {
        controller.window?.close()
        defaults.removePersistentDomain(forName: suiteName)
        try? FileManager.default.removeItem(at: root)
    }
}

@Test("前后台 pane 都能写入且不发送通知")
@MainActor
func allPanesWriteWithoutNotification() throws {
    let fixture = try OSC52WindowFixture(enabled: true)
    defer { fixture.cleanUp() }
    for (index, pane) in fixture.panes.enumerated() {
        pane.session.consumeOutput(fixture.data("pane-\(index)"))
    }
    #expect(fixture.writer.values == ["pane-0", "pane-1"])
    #expect(fixture.notifier.requests.isEmpty)
}

@Test("关闭策略时丢弃已解析效果")
@MainActor
func disabledPolicyDropsEffect() throws {
    let fixture = try OSC52WindowFixture(enabled: false)
    defer { fixture.cleanUp() }
    fixture.panes[0].session.consumeOutput(fixture.data("secret"))
    #expect(fixture.writer.values.isEmpty)
    #expect(fixture.notifier.requests.isEmpty)
}
