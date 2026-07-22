import AppKit
import Foundation
import InkConfig
import InkTerminalView
import Testing
@testable import InkShell

@Suite("字号命令", .serialized)
@MainActor
struct FontSizeCommandTests {
    @Test("按一磅步进并恢复 Ink 默认字号")
    func stepAndReset() {
        #expect(FontSizeCommand.increase.updatedValue(from: 15) == 16)
        #expect(FontSizeCommand.decrease.updatedValue(from: 15) == 14)
        #expect(FontSizeCommand.reset.updatedValue(from: 31) == 15)
    }

    @Test("字号命令不会越过配置边界")
    func clampsToRange() {
        #expect(FontSizeCommand.decrease.updatedValue(from: 6) == 6)
        #expect(FontSizeCommand.increase.updatedValue(from: 72) == 72)
    }

    @Test("窗口字号动作写回 TOML 并同步已打开的设置页")
    func windowActionPersistsAndUpdatesSettings() throws {
        let fixture = try FontSizeWindowFixture(fontSize: 15)
        defer { fixture.cleanUp() }
        fixture.controller.showSettings(nil)

        let action = NSSelectorFromString("increaseFontSize:")
        try #require(fixture.controller.responds(to: action))
        #expect(NSApp.sendAction(action, to: fixture.controller, from: nil))

        #expect(InkConfig.load(from: fixture.configURL).fontSize == 16)
        let values = fixture.allSubviews().compactMap { $0.accessibilityValue() as? String }
        #expect(values.contains("16 pt"))
        let preview = try #require(fixture.allSubviews().first {
            $0.accessibilityLabel() == "终端配色预览"
        })
        let previewFont = try #require(
            fixture.allSubviews(in: preview)
                .compactMap { $0 as? NSTextField }
                .first?.attributedStringValue.attribute(
                    .font,
                    at: 0,
                    effectiveRange: nil
                ) as? NSFont
        )
        #expect(previewFont.pointSize == 16)
    }

    @Test("字号动作同步全部可见 pane 并触发自动上传")
    func windowActionUpdatesAllPanesAndCloud() throws {
        let fixture = try FontSizeWindowFixture(fontSize: 15, automaticUpload: true)
        defer { fixture.cleanUp() }
        fixture.controller.newSession(nil)
        fixture.spinRunLoop()
        fixture.controller.splitRight(nil)
        fixture.spinRunLoop()

        try fixture.send("increaseFontSize:")

        let terminalViews = fixture.allSubviews().compactMap { $0 as? TerminalMetalView }
        #expect(terminalViews.count == 2)
        #expect(terminalViews.allSatisfy { $0.fontSize == 16 })
        #expect(fixture.store.setCallCount == 1)
    }

    @Test("恢复默认且边界上的无效动作不重复保存或上传")
    func resetAndNoOpBoundaries() throws {
        let upper = try FontSizeWindowFixture(fontSize: 72, automaticUpload: true)
        defer { upper.cleanUp() }
        try upper.send("increaseFontSize:")
        #expect(InkConfig.load(from: upper.configURL).fontSize == 72)
        #expect(upper.store.setCallCount == 0)

        try upper.send("resetFontSize:")
        #expect(InkConfig.load(from: upper.configURL).fontSize == 15)
        #expect(upper.store.setCallCount == 1)

        let lower = try FontSizeWindowFixture(fontSize: 6)
        defer { lower.cleanUp() }
        try lower.send("decreaseFontSize:")
        #expect(InkConfig.load(from: lower.configURL).fontSize == 6)
    }
}

@MainActor
private struct FontSizeWindowFixture {
    let controller: MainWindowController
    let configURL: URL
    let store: FontSizeMemoryCloudStore
    let defaults: UserDefaults
    let suite: String
    let directory: URL

    init(fontSize: Double, automaticUpload: Bool = false) throws {
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("ink-font-size-\(UUID().uuidString)")
        try FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: true
        )
        configURL = directory.appendingPathComponent("config.toml")
        var config = InkConfig()
        config.fontSize = fontSize
        try config.save(to: configURL)

        suite = "ink-font-size-defaults-\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suite)!
        defaults.removePersistentDomain(forName: suite)
        defaults.set(automaticUpload, forKey: "ink.sync.automaticUpload")
        store = FontSizeMemoryCloudStore()
        controller = MainWindowController(
            initialConfig: config,
            configURL: configURL,
            configSyncService: ConfigSyncService(store: store, defaults: defaults),
            projectDefaults: defaults,
            workspaceStore: WorkspaceStore(defaults: defaults)
        )
        controller.window?.orderFront(nil)
    }

    func send(_ selectorName: String) throws {
        let selector = NSSelectorFromString(selectorName)
        try #require(controller.responds(to: selector))
        #expect(NSApp.sendAction(selector, to: controller, from: nil))
    }

    func allSubviews() -> [NSView] {
        guard let content = controller.window?.contentView else { return [] }
        return allSubviews(in: content)
    }

    func allSubviews(in view: NSView) -> [NSView] {
        view.subviews.flatMap { [$0] + allSubviews(in: $0) }
    }

    func spinRunLoop(cycles: Int = 8) {
        for _ in 0..<cycles {
            RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.05))
        }
    }

    func cleanUp() {
        controller.window?.close()
        defaults.removePersistentDomain(forName: suite)
        try? FileManager.default.removeItem(at: directory)
    }
}

@MainActor
private final class FontSizeMemoryCloudStore: ConfigCloudStore {
    var isAvailable = true
    var setCallCount = 0
    private var values: [String: Data] = [:]

    func data(forKey key: String) -> Data? { values[key] }

    func set(_ data: Data, forKey key: String) {
        setCallCount += 1
        values[key] = data
    }

    func synchronize() -> Bool { true }
}
