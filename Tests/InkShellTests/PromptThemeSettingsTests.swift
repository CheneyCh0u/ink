import AppKit
import InkConfig
import Testing
@testable import InkShell

@Suite("提示符主题设置", .serialized)
@MainActor
struct PromptThemeSettingsTests {
    @Test("设置默认选中 Ink 并写回用户选择")
    func settingsSelectPromptThemeSource() throws {
        let controller = SettingsViewController(config: InkConfig())
        var changed: InkConfig?
        controller.onChange = { changed = $0 }
        controller.loadView()
        let control = try #require(
            allSubviews(in: controller.view)
                .compactMap { $0 as? NSSegmentedControl }
                .first { $0.accessibilityLabel() == "提示符主题" }
        )

        #expect(control.labels == ["Ink 主题", "用户配置"])
        #expect(control.selectedSegment == 0)
        control.selectedSegment = 1
        let action = try #require(control.action)
        #expect(NSApp.sendAction(action, to: control.target, from: control))
        #expect(changed?.promptThemeSource == .user)
    }

    @Test("外部配置更新同步提示符选项")
    func externalUpdateRefreshesSelection() throws {
        let controller = SettingsViewController(config: InkConfig())
        controller.loadView()
        var external = InkConfig()
        external.promptThemeSource = .user
        controller.update(config: external)
        let control = try #require(
            allSubviews(in: controller.view)
                .compactMap { $0 as? NSSegmentedControl }
                .first { $0.accessibilityLabel() == "提示符主题" }
        )
        #expect(control.selectedSegment == 1)
    }

    private func allSubviews(in view: NSView) -> [NSView] {
        view.subviews.flatMap { [$0] + allSubviews(in: $0) }
    }
}

private extension NSSegmentedControl {
    var labels: [String] {
        (0..<segmentCount).map { label(forSegment: $0) ?? "" }
    }
}
