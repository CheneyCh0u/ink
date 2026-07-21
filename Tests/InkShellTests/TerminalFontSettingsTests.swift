import AppKit
import InkConfig
import Testing
@testable import InkShell

@Suite("终端字体设置", .serialized)
@MainActor
struct TerminalFontSettingsTests {

    @Test("默认字体度量值与增粗状态")
    func defaultsExposeFontMetricControls() throws {
        let controller = SettingsViewController(config: InkConfig())
        controller.loadView()

        let controls = controls(in: controller.view)
        let thickenSwitch = try #require(
            controls.compactMap { $0 as? NSSwitch }
                .first { $0.accessibilityLabel() == "字体增粗" }
        )
        let cellHeight = try #require(
            controls.first { $0.accessibilityLabel() == "Cell 高度" }
        )
        let strength = try #require(
            controls.first { $0.accessibilityLabel() == "增粗强度" }
        )

        #expect(thickenSwitch.state == .on)
        #expect((cellHeight.accessibilityValue() as? String) == "1 px")
        #expect((strength.accessibilityValue() as? String) == "128 ")
        #expect(isEnabled(strength))
    }

    @Test("关闭字体增粗后写回配置并禁用强度")
    func disablingThickenUpdatesConfigAndDisablesStrength() throws {
        let controller = SettingsViewController(config: InkConfig())
        var changed: InkConfig?
        controller.onChange = { changed = $0 }
        controller.loadView()

        let thickenSwitch = try #require(
            controls(in: controller.view)
                .compactMap { $0 as? NSSwitch }
                .first { $0.accessibilityLabel() == "字体增粗" }
        )
        let strength = try #require(
            controls(in: controller.view)
                .first { $0.accessibilityLabel() == "增粗强度" }
        )

        thickenSwitch.state = .off
        let action = try #require(thickenSwitch.action)
        #expect(NSApp.sendAction(action, to: thickenSwitch.target, from: thickenSwitch))
        #expect(changed?.fontThicken == false)
        #expect(!isEnabled(strength))
    }

    private func controls(in view: NSView) -> [NSView] {
        view.subviews.flatMap { [$0] + controls(in: $0) }
    }

    private func isEnabled(_ control: NSView) -> Bool {
        controls(in: control)
            .compactMap { $0 as? NSControl }
            .allSatisfy(\.isEnabled)
    }
}
