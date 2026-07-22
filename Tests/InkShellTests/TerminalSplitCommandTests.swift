import AppKit
import InkConfig
import InkTerminalView
import Testing
@testable import InkShell

@Suite("终端分屏命令", .serialized)
@MainActor
struct TerminalSplitCommandTests {

    @Test("文件菜单提供四方向分屏且不声明复合快捷键")
    func menuOffersFourDirectionsWithoutKeyEquivalent() throws {
        let menu = AppDelegate.makeMainMenu()
        let fileMenu = try #require(menu.items.first { $0.submenu?.title == "文件" }?.submenu)
        let actions = [
            #selector(MainWindowController.splitLeft(_:)),
            #selector(MainWindowController.splitRight(_:)),
            #selector(MainWindowController.splitUp(_:)),
            #selector(MainWindowController.splitDown(_:)),
        ]
        for action in actions {
            let item = try #require(fileMenu.items.first { $0.action == action })
            #expect(item.keyEquivalent.isEmpty)
        }
    }

    @Test("窗口菜单提供 Command-Option 四方向 pane 聚焦")
    func windowMenuOffersPaneFocusShortcuts() throws {
        let menu = AppDelegate.makeMainMenu()
        let windowMenu = try #require(
            menu.items.first { $0.submenu?.title == "窗口" }?.submenu
        )
        let expected: [(Selector, String, String)] = [
            (#selector(MainWindowController.focusPaneLeft(_:)), "聚焦左侧 pane", "\u{F702}"),
            (#selector(MainWindowController.focusPaneRight(_:)), "聚焦右侧 pane", "\u{F703}"),
            (#selector(MainWindowController.focusPaneUp(_:)), "聚焦上方 pane", "\u{F700}"),
            (#selector(MainWindowController.focusPaneDown(_:)), "聚焦下方 pane", "\u{F701}"),
        ]

        for (action, title, key) in expected {
            let item = try #require(windowMenu.items.first { $0.action == action })
            #expect(item.title == title)
            #expect(item.keyEquivalent == key)
            #expect(item.keyEquivalentModifierMask == [.command, .option])
        }
    }

    @Test("窗口 pane 聚焦动作路由方向并按边界与设置页校验")
    func paneFocusActionsAndValidationFollowWorkspace() throws {
        let fixture = makeController(presenter: SplitClosePresenter(result: true))
        defer { fixture.cleanUp() }
        let controller = fixture.controller
        let window = try #require(controller.window)
        window.setFrame(
            NSRect(x: 300, y: 200, width: 1000, height: 700),
            display: true
        )
        window.orderFront(nil)
        controller.newSession(nil)
        spinRunLoop()
        controller.splitRight(nil)
        spinRunLoop()

        let menu = AppDelegate.makeMainMenu()
        let windowMenu = try #require(
            menu.items.first { $0.submenu?.title == "窗口" }?.submenu
        )
        func item(_ action: Selector) throws -> NSMenuItem {
            try #require(windowMenu.items.first { $0.action == action })
        }
        let leftItem = try item(#selector(MainWindowController.focusPaneLeft(_:)))
        let rightItem = try item(#selector(MainWindowController.focusPaneRight(_:)))
        let upItem = try item(#selector(MainWindowController.focusPaneUp(_:)))
        let downItem = try item(#selector(MainWindowController.focusPaneDown(_:)))
        func activeContainer() throws -> TerminalPaneContainerView {
            let contentView = try #require(window.contentView)
            return try #require(
                allSubviews(in: contentView)
                    .compactMap { $0 as? TerminalPaneContainerView }
                    .first(where: { $0.isActive })
            )
        }

        #expect(controller.validateMenuItem(leftItem))
        #expect(!controller.validateMenuItem(rightItem))
        let rightX = try activeContainer().frame.midX
        controller.focusPaneLeft(nil)
        #expect(try activeContainer().frame.midX < rightX)
        #expect(!controller.validateMenuItem(leftItem))
        #expect(controller.validateMenuItem(rightItem))

        controller.focusPaneRight(nil)
        #expect(try activeContainer().frame.midX == rightX)
        controller.splitDown(nil)
        spinRunLoop()
        let bottomY = try activeContainer().frame.midY
        #expect(controller.validateMenuItem(upItem))
        #expect(!controller.validateMenuItem(downItem))

        controller.focusPaneUp(nil)
        #expect(try activeContainer().frame.midY < bottomY)
        #expect(controller.validateMenuItem(downItem))
        controller.focusPaneDown(nil)
        #expect(try activeContainer().frame.midY == bottomY)

        controller.showSettings(nil)
        for item in [leftItem, rightItem, upItem, downItem] {
            #expect(!controller.validateMenuItem(item))
        }
    }

    @Test("Command-W 关闭活动 pane 而不是整个标签")
    func closeCommandRemovesOnlyActivePane() throws {
        let presenter = SplitClosePresenter(result: false)
        let fixture = makeController(presenter: presenter)
        defer { fixture.cleanUp() }
        let controller = fixture.controller
        let window = try #require(controller.window)
        window.setFrame(NSRect(x: 300, y: 200, width: 1000, height: 700), display: true)
        window.orderFront(nil)
        spinRunLoop()

        controller.newSession(nil)
        spinRunLoop()
        controller.splitRight(nil)
        spinRunLoop()
        #expect(terminalViews(in: window).count == 2)

        let closedWithoutConfirmation = waitUntil {
            presenter.contents.removeAll()
            controller.closeActivePane(nil)
            return presenter.contents.isEmpty && terminalViews(in: window).count == 1
        }
        #expect(closedWithoutConfirmation)
        #expect(terminalViews(in: window).count == 1)
        #expect(window.isVisible)

        window.close()
    }

    @Test("非活动 pane 的上下文分屏先聚焦点击目标")
    func contextSplitTargetsClickedPane() throws {
        let fixture = makeController(presenter: SplitClosePresenter(result: true))
        defer { fixture.cleanUp() }
        let controller = fixture.controller
        let window = try #require(controller.window)
        window.setFrame(NSRect(x: 300, y: 200, width: 1000, height: 700), display: true)
        window.orderFront(nil)
        controller.newSession(nil)
        spinRunLoop()
        controller.splitRight(nil)
        spinRunLoop()
        let containers = try #require(window.contentView).subviewsRecursive
            .compactMap { $0 as? TerminalPaneContainerView }
        #expect(containers.count == 2)
        let inactive = try #require(containers.first { !$0.isActive })

        inactive.terminalView.onSplit?(.down)
        spinRunLoop()

        #expect(terminalViews(in: window).count == 3)
    }

    @Test("活跃前台程序取消后保留分屏，确认后才关闭")
    func activeProgramRequiresConfirmationBeforeClosingPane() throws {
        let presenter = SplitClosePresenter(result: false)
        let fixture = makeController(presenter: presenter)
        defer { fixture.cleanUp() }
        let controller = fixture.controller
        let window = try #require(controller.window)
        window.setFrame(NSRect(x: 300, y: 200, width: 1000, height: 700), display: true)
        window.orderFront(nil)
        spinRunLoop()

        controller.newSession(nil)
        spinRunLoop()
        controller.splitRight(nil)
        spinRunLoop()
        let views = terminalViews(in: window)
        #expect(views.count == 2)
        #expect(waitUntil { controller.allPanes.allSatisfy { pane in
            if case .shell = pane.session.foregroundProcess { return true }
            return false
        } })
        for view in views {
            view.onInput?(Data("sleep 10\r".utf8))
        }
        spinRunLoop(cycles: 12)

        controller.closeActivePane(nil)
        spinRunLoop()
        #expect(presenter.contents.count == 1)
        #expect(presenter.contents.first?.destructiveButtonTitle == "关闭分屏")
        #expect(terminalViews(in: window).count == 2)

        presenter.result = true
        controller.closeActivePane(nil)
        spinRunLoop()
        #expect(terminalViews(in: window).count == 1)

        window.close()
    }

    @Test("Command-Q 汇总活跃会话且窗口关闭不重复确认")
    func applicationQuitAggregatesPanesWithoutDuplicateWindowPrompt() throws {
        let presenter = SplitClosePresenter(result: false)
        let fixture = makeController(presenter: presenter)
        defer { fixture.cleanUp() }
        let controller = fixture.controller
        let window = try #require(controller.window)
        window.setFrame(NSRect(x: 300, y: 200, width: 1000, height: 700), display: true)
        window.orderFront(nil)
        spinRunLoop()

        controller.newSession(nil)
        spinRunLoop()
        controller.splitRight(nil)
        spinRunLoop()
        #expect(waitUntil { controller.allPanes.allSatisfy { pane in
            if case .shell = pane.session.foregroundProcess { return true }
            return false
        } })
        for view in terminalViews(in: window) {
            view.onInput?(Data("sleep 10\r".utf8))
        }
        spinRunLoop(cycles: 12)

        #expect(!controller.requestApplicationTermination())
        #expect(presenter.contents.count == 1)
        #expect(presenter.contents.first?.destructiveButtonTitle == "退出 Ink")

        presenter.result = true
        #expect(controller.requestApplicationTermination())
        #expect(controller.windowShouldClose(window))
        #expect(presenter.contents.count == 2)

        window.close()
    }

    private func makeController(presenter: SplitClosePresenter) -> SplitWindowFixture {
        let suite = "ink-split-window-defaults-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defaults.removePersistentDomain(forName: suite)
        let controller = MainWindowController(
            initialConfig: InkConfig(),
            configURL: FileManager.default.temporaryDirectory
                .appendingPathComponent("ink-close-test-\(UUID().uuidString).toml"),
            configSyncService: ConfigSyncService(defaults: defaults),
            sessionCloseCoordinator: SessionCloseCoordinator(presenter: presenter),
            projectDefaults: defaults,
            workspaceStore: WorkspaceStore(defaults: defaults)
        )
        return SplitWindowFixture(controller: controller, defaults: defaults, suite: suite)
    }

    private func terminalViews(in window: NSWindow) -> [TerminalMetalView] {
        guard let contentView = window.contentView else { return [] }
        return allSubviews(in: contentView).compactMap { $0 as? TerminalMetalView }
    }

    private func allSubviews(in view: NSView) -> [NSView] {
        view.subviews.flatMap { [$0] + allSubviews(in: $0) }
    }

    private func spinRunLoop(cycles: Int = 8) {
        for _ in 0..<cycles {
            RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.05))
        }
    }

    private func waitUntil(
        timeout: TimeInterval = 5,
        condition: () -> Bool
    ) -> Bool {
        let deadline = Date(timeIntervalSinceNow: timeout)
        repeat {
            if condition() { return true }
            RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.05))
        } while Date() < deadline
        return condition()
    }
}

private extension NSView {
    var subviewsRecursive: [NSView] {
        subviews.flatMap { [$0] + $0.subviewsRecursive }
    }
}

@MainActor
private struct SplitWindowFixture {
    let controller: MainWindowController
    let defaults: UserDefaults
    let suite: String

    func cleanUp() {
        controller.window?.close()
        defaults.removePersistentDomain(forName: suite)
    }
}

@MainActor
private final class SplitClosePresenter: SessionClosePresenting {
    var result: Bool
    var contents: [SessionCloseAlertContent] = []

    init(result: Bool) {
        self.result = result
    }

    func confirm(_ content: SessionCloseAlertContent) -> Bool {
        contents.append(content)
        return result
    }
}
