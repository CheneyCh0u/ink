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
        #expect(
            buttons.filter { !$0.isHidden && $0.frame.maxX < settings.frame.minX }.count == 2
        )
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

    @Test("空间不足时活动标签可见且菜单保留原始索引")
    func overflowKeepsActiveTabVisible() throws {
        let tabBar = makeTabBar(width: 520, count: 8, active: 6)
        let overflow = try #require(
            tabBar.subviews.compactMap { $0 as? NSButton }
                .first { $0.toolTip == "更多标签" }
        )
        let menu = try #require(tabBar.overflowMenu)

        #expect(!overflow.isHidden)
        #expect(tabBar.visibleTabIndices.contains(6))
        #expect(!menu.items.map(\.tag).contains(6))
        #expect(menu.items.map(\.tag) == menu.items.map(\.tag).sorted())

        let stack = try #require(tabBar.subviews.first { $0 is NSStackView } as? NSStackView)
        let frames = stack.arrangedSubviews.map(\.frame)
        #expect(frames.allSatisfy { $0.width >= InkDesignTokens.TabBar.minimumTabWidth })
        #expect(zip(frames, frames.dropFirst()).allSatisfy { pair in
            pair.0.maxX <= pair.1.minX
        })
    }

    @Test("重复标题的菜单项仍选择原始标签")
    func duplicateTitleMenuItemsKeepOriginalTabSelection() throws {
        let tabs = (0..<8).map {
            TabBarView.Tab(
                title: $0 == 2 || $0 == 7 ? "重复" : "标签 \($0)",
                shortcut: "",
                active: $0 == 0
            )
        }
        let tabBar = makeTabBar(width: 520, tabs: tabs)
        var selected: Int?
        tabBar.onSelect = { selected = $0 }
        let menu = try #require(tabBar.overflowMenu)
        let itemIndex = try #require(menu.items.firstIndex { $0.tag == 7 })

        menu.performActionForItem(at: itemIndex)

        #expect(selected == 7)
    }

    @Test("窗口放大后显示更多标签并隐藏空溢出入口")
    func expandingWindowShowsMoreTabsAndHidesEmptyOverflowEntry() throws {
        let tabs = (0..<4).map {
            TabBarView.Tab(title: "标签 \($0)", shortcut: "⌘\($0 + 1)", active: $0 == 2)
        }
        let tabBar = makeTabBar(width: 520, tabs: tabs)
        let narrowCount = tabBar.visibleTabIndices.count
        #expect(tabBar.overflowMenu != nil)

        tabBar.setFrameSize(NSSize(width: 1000, height: 38))
        tabBar.layoutSubtreeIfNeeded()

        #expect(tabBar.visibleTabIndices.count > narrowCount)
        #expect(tabBar.visibleTabIndices == [0, 1, 2, 3])
        #expect(tabBar.overflowMenu == nil)
        let overflow = try #require(
            tabBar.subviews.compactMap { $0 as? NSButton }
                .first { $0.toolTip == "更多标签" }
        )
        #expect(overflow.isHidden)
    }

    @Test("活动标签变化只做最小区间移动")
    func changingActiveTabMinimallyMovesVisibleRange() {
        let tabBar = makeTabBar(width: 520, count: 8, active: 2)
        let before = tabBar.visibleTabIndices
        tabBar.reload(tabs: makeTabs(count: 8, active: before.last! + 1))
        tabBar.layoutSubtreeIfNeeded()

        #expect(tabBar.visibleTabIndices.dropLast() == before.dropFirst())
        #expect(tabBar.visibleTabIndices.last == before.last! + 1)
    }

    private func makeTabBar(
        width: CGFloat = 800,
        count: Int = 1,
        active: Int = 0
    ) -> TabBarView {
        makeTabBar(width: width, tabs: makeTabs(count: count, active: active))
    }

    private func makeTabBar(width: CGFloat, tabs: [TabBarView.Tab]) -> TabBarView {
        let tabBar = TabBarView(frame: NSRect(x: 0, y: 0, width: width, height: 38))
        tabBar.reload(tabs: tabs)
        tabBar.layoutSubtreeIfNeeded()
        return tabBar
    }

    private func makeTabs(count: Int, active: Int) -> [TabBarView.Tab] {
        (0..<count).map {
            TabBarView.Tab(
                title: "标签 \($0)",
                shortcut: $0 < 9 ? "⌘\($0 + 1)" : "",
                active: $0 == active
            )
        }
    }
}
