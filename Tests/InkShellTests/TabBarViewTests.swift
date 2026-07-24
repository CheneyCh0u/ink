import AppKit
import InkDesign
import TerminalCore
import Testing
@testable import InkShell

@Suite("顶部标签栏", .serialized)
@MainActor
struct TabBarViewTests {
    @Test("失败状态使用独立图形且悬停关闭按钮不移动布局")
    func failureAttentionIsNotColorOnly() throws {
        let failure = TabAttention.failed(.init(exitStatus: 2, duration: .seconds(12)))
        let tabBar = makeTabBar(width: 800, tabs: [
            .init(
                title: "构建",
                shortcut: "⌘1",
                active: false,
                attention: failure
            ),
        ])
        let stack = try #require(tabBar.subviews.first { $0 is NSStackView } as? NSStackView)
        let item = try #require(stack.arrangedSubviews.first)
        let image = try #require(descendants(of: NSImageView.self, in: item).first)
        let close = try #require(descendants(of: NSButton.self, in: item).first)
        let before = close.frame

        #expect(image.accessibilityLabel() == "命令失败，退出状态 2，12 秒")
        #expect(image.image != nil)
        #expect(!image.isHidden)
        item.mouseEntered(with: try mouseEvent())
        item.layoutSubtreeIfNeeded()
        #expect(close.frame == before)
        #expect(!close.isHidden)
        #expect(image.isHidden)
    }

    @Test("溢出菜单同步显示未读图形")
    func overflowMenuShowsAttention() throws {
        let failure = TabAttention.failed(.init(exitStatus: 2, duration: .seconds(12)))
        let tabs = (0..<8).map { index in
            TabBarView.Tab(
                title: "标签 \(index)",
                shortcut: "",
                active: index == 6,
                attention: index == 0 ? failure : nil
            )
        }
        let tabBar = makeTabBar(width: 400, tabs: tabs)
        let item = try #require(tabBar.overflowMenu?.items.first { $0.tag == 0 })

        #expect(item.image?.accessibilityDescription == "命令失败，退出状态 2，12 秒")
        #expect(item.image != nil)
    }

    @Test("新建标签按钮贴右缘且不再有设置齿轮")
    func plusButtonUsesTrailingSlot() throws {
        let tabBar = makeTabBar()
        let buttons = tabBar.subviews.compactMap { $0 as? NSButton }
        let plus = try #require(buttons.first {
            $0.image?.accessibilityDescription == "新建标签"
        })

        // 离屏布局下按钮 fitting 宽度带半像素，容差放宽到 1pt。
        #expect(
            abs(tabBar.bounds.maxX - plus.frame.maxX - InkDesignTokens.Spacing.sm) < 1
        )
        #expect(buttons.allSatisfy { $0.toolTip != "设置（⌘,）" })
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

    @Test("标签刷新后旧溢出菜单不能选择已移位标签")
    func staleOverflowMenuCannotSelectShiftedTab() throws {
        let tabBar = makeTabBar(width: 520, count: 8, active: 0)
        var selected: Int?
        tabBar.onSelect = { selected = $0 }
        let staleMenu = try #require(tabBar.overflowMenu)
        let staleItemIndex = try #require(staleMenu.items.firstIndex { $0.tag == 6 })

        tabBar.reload(tabs: makeTabs(count: 7, active: 0))
        tabBar.layoutSubtreeIfNeeded()
        staleMenu.performActionForItem(at: staleItemIndex)

        #expect(selected == nil)

        let currentMenu = try #require(tabBar.overflowMenu)
        let currentItemIndex = try #require(currentMenu.items.firstIndex { $0.tag == 6 })
        currentMenu.performActionForItem(at: currentItemIndex)
        #expect(selected == 6)
    }

    @Test("同一可见区间内缩放只更新宽度约束")
    func liveResizeReusesTabStructure() throws {
        let tabBar = makeTabBar(width: 520, count: 8, active: 0)
        let menu = try #require(tabBar.overflowMenu)
        let stack = try #require(tabBar.subviews.first { $0 is NSStackView } as? NSStackView)
        let firstTab = try #require(stack.arrangedSubviews.first)
        let widthConstraint = try #require(firstTab.constraints.first {
            $0.firstAttribute == .width && $0.secondItem == nil
        })
        let initialWidth = widthConstraint.constant

        tabBar.setFrameSize(NSSize(width: 519, height: 38))
        tabBar.layoutSubtreeIfNeeded()

        let currentWidthConstraint = try #require(firstTab.constraints.first {
            $0.firstAttribute == .width && $0.secondItem == nil
        })
        #expect(tabBar.overflowMenu === menu)
        #expect(currentWidthConstraint === widthConstraint)
        #expect(currentWidthConstraint.constant != initialWidth)
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

    private func descendants<T: NSView>(of type: T.Type, in view: NSView) -> [T] {
        view.subviews.flatMap { child in
            (child as? T).map { [$0] } ?? descendants(of: type, in: child)
        }
    }

    private func mouseEvent() throws -> NSEvent {
        try #require(NSEvent.mouseEvent(
            with: .mouseMoved,
            location: .zero,
            modifierFlags: [],
            timestamp: 0,
            windowNumber: 0,
            context: nil,
            eventNumber: 0,
            clickCount: 0,
            pressure: 0
        ))
    }
}
