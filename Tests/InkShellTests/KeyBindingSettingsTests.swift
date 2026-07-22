import AppKit
import InkConfig
import Testing
@testable import InkShell

@Suite("快捷键设置", .serialized)
@MainActor
struct KeyBindingSettingsTests {
    @Test("合法录制即时回传，冲突保留旧值并显示错误")
    func recordsAndRejectsConflict() throws {
        let controller = SettingsViewController(config: InkConfig())
        var received: [InkConfig] = []
        controller.onChange = { received.append($0) }
        controller.loadView()
        let newTab = try recorder(.newTab, in: controller.view)

        newTab.handle(candidate: try #require(KeyBinding.parse("cmd+ctrl+t")))
        #expect(received.last?.keyBindings.binding(for: .newTab)?.serialized == "cmd+ctrl+t")
        newTab.handle(candidate: try #require(KeyBindingSet.defaults.binding(for: .find)))
        #expect(received.last?.keyBindings.binding(for: .newTab)?.serialized == "cmd+ctrl+t")
        #expect(newTab.validationMessage?.contains("查找") == true)
    }

    @Test("清除、外部刷新和全部恢复默认")
    func clearRefreshAndReset() throws {
        let controller = SettingsViewController(config: InkConfig())
        var received: InkConfig?
        controller.onChange = { received = $0 }
        controller.loadView()
        let newTab = try recorder(.newTab, in: controller.view)

        newTab.clearBinding()
        #expect(received?.keyBindings.assignment(for: .newTab) == .disabled)

        var external = InkConfig()
        _ = external.setKeyBinding(
            .binding(try #require(KeyBinding.parse("cmd+ctrl+t"))),
            for: .newTab
        )
        controller.update(config: external)
        #expect(newTab.assignment == external.keyBindings.assignment(for: .newTab))

        controller.resetAllKeyBindings(confirm: { true })
        #expect(received?.keyBindings == .defaults)
    }

    private func recorder(
        _ action: KeyBindingAction,
        in view: NSView
    ) throws -> KeyBindingRecorderControl {
        if let recorder = view as? KeyBindingRecorderControl, recorder.action == action {
            return recorder
        }
        for subview in view.subviews {
            if let found = try? recorder(action, in: subview) { return found }
        }
        throw RecorderNotFound()
    }
}

private struct RecorderNotFound: Error {}
