import AppKit
import InkDesign
import Testing
@testable import InkShell

@Suite("顶部标签栏", .serialized)
@MainActor
struct TabBarViewTests {
    @Test("设置齿轮固定在最右侧并提供辅助信息")
    func settingsButtonUsesTrailingSlot() throws {
        let tabBar = makeTabBar()
        let buttons = tabBar.subviews.compactMap { $0 as? NSButton }
        let settings = try #require(buttons.first { $0.toolTip == "设置（⌘,）" })

        #expect(
            abs(tabBar.bounds.maxX - settings.frame.maxX - InkDesignTokens.Spacing.sm) < 0.5
        )
        #expect(settings.accessibilityLabel() == "设置")
        #expect(buttons.filter { $0.frame.maxX < settings.frame.minX }.count == 2)
    }

    @Test("设置齿轮发送回调并同步选中态")
    func settingsButtonSelection() throws {
        let tabBar = makeTabBar()
        var opened = false
        tabBar.onSettings = { opened = true }
        let settings = try #require(
            tabBar.subviews.compactMap { $0 as? NSButton }
                .first { $0.toolTip == "设置（⌘,）" }
        )

        settings.performClick(nil)
        #expect(opened)
        tabBar.setSettingsSelected(true)
        #expect(settings.state == .on)
        tabBar.setSettingsSelected(false)
        #expect(settings.state == .off)
    }

    private func makeTabBar() -> TabBarView {
        let tabBar = TabBarView(frame: NSRect(x: 0, y: 0, width: 800, height: 38))
        tabBar.reload(tabs: [.init(title: "ink", shortcut: "⌘1", active: true)])
        tabBar.layoutSubtreeIfNeeded()
        return tabBar
    }
}
