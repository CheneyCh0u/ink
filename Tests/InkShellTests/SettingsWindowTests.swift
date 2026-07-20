import AppKit
import Testing
@testable import InkShell

/// 回归测试：显示内嵌设置页不得改变主窗口 frame。
///
/// 背景（#21 之前的 bug）：设置页滚动区的文档视图漏设
/// `translatesAutoresizingMaskIntoConstraints = false`，零 frame 文档携带的
/// required `width == 0` autoresizing 约束经 `document.width == clipView.width`
/// 等式传导进分栏内容列，AppKit 的窗口适配布局
/// （`_changeWindowFrameFromConstraintsIfNecessary`）随即把整个主窗口压到
/// 侧边栏上限 + 标签栏最小宽（截图里的 387pt）。
@Suite("设置页窗口稳定性", .serialized)
@MainActor
struct SettingsWindowTests {

    @Test("显示设置前后窗口 frame 不变")
    func showingSettingsKeepsWindowFrame() throws {
        let controller = MainWindowController()
        let window = try #require(controller.window)
        window.orderFront(nil)
        spinRunLoop()

        // 固定一个"用户手动调出"的窗口尺寸，排除 frame autosave 干扰。
        window.setFrame(NSRect(x: 640, y: 300, width: 1100, height: 700), display: true)
        controller.newSession(nil) // 至少一个会话标签，贴近真实使用
        spinRunLoop()
        let before = window.frame

        controller.showSettings(nil)
        spinRunLoop()
        let after = window.frame

        #expect(
            abs(after.width - before.width) < 0.5,
            "设置页导致窗口宽度 \(before.width) -> \(after.width)"
        )
        #expect(
            abs(after.height - before.height) < 0.5,
            "设置页导致窗口高度 \(before.height) -> \(after.height)"
        )
        window.close()
    }

    /// 驱动主 RunLoop 让异步布局（含 AppKit 显示周期的窗口适配 pass）跑完。
    private func spinRunLoop(cycles: Int = 8) {
        for _ in 0..<cycles {
            RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.05))
        }
    }
}
