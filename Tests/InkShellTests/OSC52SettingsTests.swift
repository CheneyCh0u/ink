import AppKit
import InkConfig
import Testing
@testable import InkShell

@Suite("OSC 52 设置")
@MainActor
struct OSC52SettingsTests {
    @Test("交互区开关展示只写边界并回传配置")
    func toggleUpdatesConfig() throws {
        let controller = SettingsViewController(config: InkConfig())
        var received: InkConfig?
        controller.onChange = { received = $0 }
        controller.loadView()
        let views = descendants(controller.view)
        let toggle = try #require(views.compactMap { $0 as? NSSwitch }.first {
            $0.accessibilityLabel() == "允许终端程序写入剪贴板（OSC 52）"
        })
        #expect(toggle.state == .on)
        #expect(views.compactMap { $0 as? NSTextField }.contains {
            $0.stringValue == "仅允许写入，终端程序不能读取剪贴板。"
        })
        toggle.performClick(nil)
        #expect(received?.osc52WriteEnabled == false)
    }

    private func descendants(_ view: NSView) -> [NSView] {
        view.subviews.flatMap { [$0] + descendants($0) }
    }
}
