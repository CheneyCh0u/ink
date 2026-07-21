import AppKit
import Foundation
import InkConfig
import Testing
@testable import InkShell

@Suite("iCloud 配置同步窗口协调", .serialized)
@MainActor
struct ConfigSyncWindowTests {
    @Test("开启自动上传后立即上传并跟随设置变化")
    func automaticUploadFollowsSettings() throws {
        let fixture = try makeFixture()
        defer { fixture.cleanUp() }
        fixture.controller.showSettings(nil)
        spinRunLoop()

        let toggle = try #require(controls(in: fixture.controller).compactMap { $0 as? NSSwitch }.first {
            $0.accessibilityLabel() == "自动上传配置"
        })
        toggle.performClick(nil)
        #expect(fixture.store.setCallCount == 1)

        let theme = try #require(controls(in: fixture.controller).compactMap { $0 as? NSPopUpButton }.first {
            $0.accessibilityLabel() == "终端配色"
        })
        theme.selectItem(withTitle: "松针")
        let action = try #require(theme.action)
        #expect(NSApp.sendAction(action, to: theme.target, from: theme))
        #expect(fixture.store.setCallCount == 2)
        #expect(try cloudConfig(in: fixture.store).terminalTheme == .pine)
    }

    @Test("手动上传不同配置前明确确认覆盖方向")
    func uploadConfirmsOverwriteDirection() throws {
        let fixture = try makeFixture(remoteConfig: differentConfig())
        defer { fixture.cleanUp() }
        fixture.controller.showSettings(nil)
        spinRunLoop()

        try clickButton("上传到云端", in: fixture.controller)
        spinRunLoop()
        let sheet = try #require(fixture.controller.window?.attachedSheet)
        let sheetContent = try #require(sheet.contentView)
        let copy = allSubviews(in: sheetContent).compactMap { $0 as? NSTextField }.map(\.stringValue)
        #expect(copy.contains { $0.contains("本机配置将覆盖云端配置") })
        #expect(buttons(in: sheetContent).map(\.title).contains("上传并覆盖"))
        #expect(fixture.store.setCallCount == 0)

        try #require(buttons(in: sheetContent).first { $0.title == "上传并覆盖" }).performClick(nil)
        spinRunLoop()
        #expect(fixture.store.setCallCount == 1)
    }

    @Test("手动拉取保留 TOML 扩展且不会自动回传")
    func pullPreservesTOMLAndDoesNotEcho() throws {
        let remote = differentConfig()
        let fixture = try makeFixture(remoteConfig: remote, automaticUpload: true)
        defer { fixture.cleanUp() }
        fixture.controller.showSettings(nil)
        spinRunLoop()

        try clickButton("拉取云端配置", in: fixture.controller)
        spinRunLoop()
        let sheet = try #require(fixture.controller.window?.attachedSheet)
        let sheetContent = try #require(sheet.contentView)
        let copy = allSubviews(in: sheetContent).compactMap { $0 as? NSTextField }.map(\.stringValue)
        #expect(copy.contains { $0.contains("云端配置将覆盖此 Mac") })

        try #require(buttons(in: sheetContent).first { $0.title == "拉取并覆盖" }).performClick(nil)
        spinRunLoop()

        #expect(InkConfig.load(from: fixture.configURL) == remote)
        let text = try String(contentsOf: fixture.configURL, encoding: .utf8)
        #expect(text.contains("# 本机注释"))
        #expect(text.contains("future_option = \"keep\""))
        #expect(fixture.store.setCallCount == 0)
    }

    private func makeFixture(
        remoteConfig: InkConfig? = nil,
        automaticUpload: Bool = false
    ) throws -> WindowFixture {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("ink-sync-window-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let configURL = directory.appendingPathComponent("config.toml")
        try """
        # 本机注释
        [custom]
        future_option = "keep"
        """.write(to: configURL, atomically: true, encoding: .utf8)

        let suite = "ink-sync-window-defaults-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defaults.removePersistentDomain(forName: suite)
        defaults.set(automaticUpload, forKey: "ink.sync.automaticUpload")
        let store = WindowMemoryCloudStore()
        if let remoteConfig {
            store.values[ConfigSyncService.snapshotKey] = try ConfigSyncSnapshot(
                config: remoteConfig,
                modifiedAt: Date(timeIntervalSince1970: 1_785_000_000),
                deviceID: "remote-mac"
            ).encoded()
        }
        let service = ConfigSyncService(store: store, defaults: defaults)
        let initial = InkConfig.load(from: configURL)
        let controller = MainWindowController(
            initialConfig: initial,
            configURL: configURL,
            configSyncService: service
        )
        controller.window?.orderFront(nil)
        return WindowFixture(
            controller: controller,
            store: store,
            defaults: defaults,
            suite: suite,
            directory: directory,
            configURL: configURL
        )
    }

    private func differentConfig() -> InkConfig {
        var config = InkConfig()
        config.appearanceMode = .dark
        config.terminalTheme = .pine
        config.fontSize = 18
        config.copyOnSelect = true
        return config
    }

    private func cloudConfig(in store: WindowMemoryCloudStore) throws -> InkConfig {
        let data = try #require(store.values[ConfigSyncService.snapshotKey])
        return try ConfigSyncSnapshot.decode(data).config
    }

    private func clickButton(_ title: String, in controller: MainWindowController) throws {
        let button = try #require(controls(in: controller).compactMap { $0 as? NSButton }.first {
            $0.title == title
        })
        button.performClick(nil)
    }

    private func controls(in controller: MainWindowController) -> [NSView] {
        guard let content = controller.window?.contentView else { return [] }
        return allSubviews(in: content)
    }

    private func buttons(in view: NSView) -> [NSButton] {
        allSubviews(in: view).compactMap { $0 as? NSButton }
    }

    private func allSubviews(in view: NSView) -> [NSView] {
        view.subviews.flatMap { [$0] + allSubviews(in: $0) }
    }

    private func spinRunLoop(cycles: Int = 8) {
        for _ in 0..<cycles {
            RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.05))
        }
    }
}

@MainActor
private struct WindowFixture {
    let controller: MainWindowController
    let store: WindowMemoryCloudStore
    let defaults: UserDefaults
    let suite: String
    let directory: URL
    let configURL: URL

    func cleanUp() {
        controller.window?.close()
        defaults.removePersistentDomain(forName: suite)
        try? FileManager.default.removeItem(at: directory)
    }
}

@MainActor
private final class WindowMemoryCloudStore: ConfigCloudStore {
    var isAvailable = true
    var values: [String: Data] = [:]
    var setCallCount = 0
    func data(forKey key: String) -> Data? { values[key] }
    func set(_ data: Data, forKey key: String) {
        setCallCount += 1
        values[key] = data
    }
    func synchronize() -> Bool { true }
}
