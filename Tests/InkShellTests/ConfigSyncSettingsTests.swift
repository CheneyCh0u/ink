import AppKit
import InkConfig
import Testing
@testable import InkShell

@Suite("iCloud 配置同步设置", .serialized)
@MainActor
struct ConfigSyncSettingsTests {
    @Test("iCloud 分组位于交互和高级之间")
    func sectionOrder() {
        let controller = SettingsViewController(config: InkConfig())
        controller.loadView()
        let wanted = ["外观", "窗口", "终端", "光标", "交互", "iCloud", "高级"]
        let labels = allSubviews(in: controller.view)
            .compactMap { $0 as? NSTextField }
            .map(\.stringValue)
            .filter { wanted.contains($0) }

        #expect(labels == wanted)
    }

    @Test("开关与两个按钮只发送明确意图")
    func controlsSendCallbacks() throws {
        let controller = SettingsViewController(config: InkConfig())
        var automatic: Bool?
        var uploads = 0
        var pulls = 0
        controller.onAutomaticUploadChange = { automatic = $0 }
        controller.onUploadConfig = { uploads += 1 }
        controller.onPullConfig = { pulls += 1 }
        controller.loadView()

        let controls = allSubviews(in: controller.view)
        let toggle = try #require(controls.compactMap { $0 as? NSSwitch }.first {
            $0.accessibilityLabel() == "自动上传配置"
        })
        let upload = try #require(controls.compactMap { $0 as? NSButton }.first {
            $0.title == "上传到云端"
        })
        let pull = try #require(controls.compactMap { $0 as? NSButton }.first {
            $0.title == "拉取云端配置"
        })

        toggle.state = .on
        toggle.performClick(nil)
        upload.performClick(nil)
        pull.performClick(nil)

        #expect(automatic == false)
        #expect(uploads == 1)
        #expect(pulls == 1)
    }

    @Test("忙碌时禁用操作，关闭自动上传仍保留手动按钮")
    func stateControlsAvailabilityAndCopy() throws {
        let controller = SettingsViewController(config: InkConfig())
        controller.loadView()
        let controls = allSubviews(in: controller.view)
        let toggle = try #require(controls.compactMap { $0 as? NSSwitch }.first {
            $0.accessibilityLabel() == "自动上传配置"
        })
        let upload = try #require(button(titled: "上传到云端", in: controls))
        let pull = try #require(button(titled: "拉取云端配置", in: controls))
        let status = try #require(controls.compactMap { $0 as? NSTextField }.first {
            $0.accessibilityLabel() == "iCloud 同步状态"
        })

        controller.updateSync(automaticUploadEnabled: true, status: .uploading)
        #expect(toggle.state == .on)
        #expect(!toggle.isEnabled && !upload.isEnabled && !pull.isEnabled)
        #expect(status.stringValue == "正在上传…")

        controller.updateSync(automaticUploadEnabled: false, status: .cloudEmpty)
        #expect(toggle.state == .off)
        #expect(toggle.isEnabled && upload.isEnabled && pull.isEnabled)
        #expect(status.stringValue == "云端暂无配置")

        controller.updateSync(
            automaticUploadEnabled: false,
            status: .cloudSnapshot(Date(), isCurrentDevice: false)
        )
        #expect(status.stringValue.hasPrefix("云端配置来自其它 Mac"))

        controller.updateSync(automaticUploadEnabled: false, status: .failed("损坏数据"))
        #expect(status.stringValue == "同步失败：损坏数据")
    }

    private func button(titled title: String, in views: [NSView]) -> NSButton? {
        views.compactMap { $0 as? NSButton }.first { $0.title == title }
    }

    private func allSubviews(in view: NSView) -> [NSView] {
        view.subviews.flatMap { [$0] + allSubviews(in: $0) }
    }
}
