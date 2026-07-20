import AppKit
import InkDesign
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

    @Test("设置页打开时顶部栏仍可见并显示选中齿轮")
    func showingSettingsKeepsTabBarVisible() throws {
        let controller = MainWindowController()
        let window = try #require(controller.window)
        window.setFrame(NSRect(x: 640, y: 300, width: 1100, height: 700), display: true)
        window.orderFront(nil)
        controller.newSession(nil)
        spinRunLoop()

        controller.showSettings(nil)
        spinRunLoop()

        let contentView = try #require(window.contentView)
        let tabBar = try #require(
            allSubviews(in: contentView).first { $0 is TabBarView } as? TabBarView
        )
        let settings = try #require(
            tabBar.subviews.compactMap { $0 as? NSButton }
                .first { $0.toolTip == "设置（⌘,）" }
        )
        #expect(!tabBar.isHiddenOrHasHiddenAncestor)
        #expect(settings.state == .on)
        window.close()
    }

    @Test("设置页中点击当前标签返回终端")
    func selectingTabLeavesSettings() throws {
        let controller = MainWindowController()
        let window = try #require(controller.window)
        window.orderFront(nil)
        controller.newSession(nil)
        spinRunLoop()
        controller.showSettings(nil)
        spinRunLoop()

        let item = NSMenuItem(title: "", action: nil, keyEquivalent: "")
        item.tag = 0
        controller.selectSessionMenu(item)
        spinRunLoop()

        let contentView = try #require(window.contentView)
        let settingsTitle = try #require(
            allSubviews(in: contentView)
                .compactMap { $0 as? NSTextField }
                .first { $0.stringValue == "设置" }
        )
        let tabBar = try #require(
            allSubviews(in: contentView).first { $0 is TabBarView } as? TabBarView
        )
        let settings = try #require(
            tabBar.subviews.compactMap { $0 as? NSButton }
                .first { $0.toolTip == "设置（⌘,）" }
        )
        #expect(settingsTitle.isHiddenOrHasHiddenAncestor)
        #expect(settings.state == .off)
        window.close()
    }

    @Test("设置页中创建标签返回终端")
    func creatingTabLeavesSettings() throws {
        let controller = MainWindowController()
        let window = try #require(controller.window)
        window.orderFront(nil)
        controller.showSettings(nil)
        spinRunLoop()

        controller.newSession(nil)
        spinRunLoop()

        let contentView = try #require(window.contentView)
        let settingsTitle = try #require(
            allSubviews(in: contentView)
                .compactMap { $0 as? NSTextField }
                .first { $0.stringValue == "设置" }
        )
        #expect(settingsTitle.isHiddenOrHasHiddenAncestor)
        window.close()
    }

    @Test("设置页不显示完成按钮")
    func settingsDoesNotShowDoneButton() throws {
        let controller = MainWindowController()
        let window = try #require(controller.window)
        window.orderFront(nil)
        controller.showSettings(nil)
        spinRunLoop()

        let contentView = try #require(window.contentView)
        let doneButtons = allSubviews(in: contentView)
            .compactMap { $0 as? NSButton }
            .filter { $0.title == "完成" && !$0.isHiddenOrHasHiddenAncestor }
        #expect(doneButtons.isEmpty)
        window.close()
    }

    @Test("再次点击选中齿轮返回终端")
    func selectingSettingsAgainLeavesSettings() throws {
        let controller = MainWindowController()
        let window = try #require(controller.window)
        window.orderFront(nil)
        controller.newSession(nil)
        controller.showSettings(nil)
        spinRunLoop()

        let contentView = try #require(window.contentView)
        let tabBar = try #require(
            allSubviews(in: contentView).first { $0 is TabBarView } as? TabBarView
        )
        let settings = try #require(
            tabBar.subviews.compactMap { $0 as? NSButton }
                .first { $0.toolTip == "设置（⌘,）" }
        )
        settings.performClick(nil)
        spinRunLoop()

        let settingsTitle = try #require(
            allSubviews(in: contentView)
                .compactMap { $0 as? NSTextField }
                .first { $0.stringValue == "设置" }
        )
        #expect(settingsTitle.isHiddenOrHasHiddenAncestor)
        #expect(settings.state == .off)
        window.close()
    }

    @Test("设置页中关闭标签不把焦点移到隐藏终端")
    func closingTabWhileShowingSettingsKeepsSettingsFocus() throws {
        let controller = MainWindowController()
        let window = try #require(controller.window)
        window.orderFront(nil)
        controller.newSession(nil)
        controller.newSession(nil)
        spinRunLoop()
        controller.showSettings(nil)
        spinRunLoop()
        let settingsResponder = try #require(window.firstResponder)

        let contentView = try #require(window.contentView)
        let closeButtons = allSubviews(in: contentView)
            .compactMap { $0 as? NSButton }
            .filter { $0.image?.accessibilityDescription == "关闭标签" }
        #expect(closeButtons.count == 2)
        let closeButton = try #require(closeButtons.first)
        closeButton.isHidden = false
        let closeAction = try #require(closeButton.action)
        #expect(NSApp.sendAction(closeAction, to: closeButton.target, from: closeButton))
        spinRunLoop()

        let remainingCloseButtons = allSubviews(in: contentView)
            .compactMap { $0 as? NSButton }
            .filter { $0.image?.accessibilityDescription == "关闭标签" }
        #expect(remainingCloseButtons.count == 1)
        #expect(window.firstResponder === settingsResponder)
        window.close()
    }

    @Test("所有设置分组共享同一内容列")
    func settingsSectionsShareOneContentColumn() throws {
        let controller = MainWindowController()
        let window = try #require(controller.window)
        window.setFrame(NSRect(x: 640, y: 200, width: 1100, height: 800), display: true)
        window.orderFront(nil)
        controller.showSettings(nil)
        spinRunLoop()

        let contentView = try #require(window.contentView)
        let sectionTitles = ["外观", "窗口", "终端", "光标", "交互", "高级"]
        let panels = try sectionTitles.map { title in
            let label = try #require(
                allSubviews(in: contentView)
                    .compactMap { $0 as? NSTextField }
                    .first { $0.stringValue == title }
            )
            let section = try #require(label.superview as? NSStackView)
            return try #require(section.arrangedSubviews.last)
        }
        let panelFrames = panels.map { $0.convert($0.bounds, to: contentView) }
        let reference = try #require(panelFrames.first)
        let scrollView = try #require(ancestor(of: panels[0], as: NSScrollView.self))
        let expectedWidth = min(
            InkDesignTokens.Settings.contentWidth,
            scrollView.contentView.bounds.width - InkDesignTokens.Spacing.xl * 2
        )

        #expect(
            abs(reference.width - expectedWidth) < 0.5,
            "设置内容列宽度 \(reference.width)，应占满可用宽度 \(expectedWidth)"
        )
        for (title, frame) in zip(sectionTitles.dropFirst(), panelFrames.dropFirst()) {
            #expect(
                abs(frame.minX - reference.minX) < 0.5,
                "\(title)分组左边缘 \(frame.minX) 与外观分组 \(reference.minX) 不一致"
            )
            #expect(
                abs(frame.width - reference.width) < 0.5,
                "\(title)分组宽度 \(frame.width) 与外观分组 \(reference.width) 不一致"
            )
        }
        window.close()
    }

    private func allSubviews(in view: NSView) -> [NSView] {
        view.subviews.flatMap { [$0] + allSubviews(in: $0) }
    }

    private func ancestor<T: NSView>(of view: NSView, as type: T.Type) -> T? {
        var candidate = view.superview
        while let current = candidate {
            if let match = current as? T { return match }
            candidate = current.superview
        }
        return nil
    }

    /// 驱动主 RunLoop 让异步布局（含 AppKit 显示周期的窗口适配 pass）跑完。
    private func spinRunLoop(cycles: Int = 8) {
        for _ in 0..<cycles {
            RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.05))
        }
    }
}
