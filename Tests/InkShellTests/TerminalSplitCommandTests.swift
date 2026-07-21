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

    @Test("Command-W 关闭活动 pane 而不是整个标签")
    func closeCommandRemovesOnlyActivePane() throws {
        let presenter = SplitClosePresenter(result: false)
        let controller = makeController(presenter: presenter)
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

    @Test("活跃前台程序取消后保留分屏，确认后才关闭")
    func activeProgramRequiresConfirmationBeforeClosingPane() throws {
        let presenter = SplitClosePresenter(result: false)
        let controller = makeController(presenter: presenter)
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
        let controller = makeController(presenter: presenter)
        let window = try #require(controller.window)
        window.setFrame(NSRect(x: 300, y: 200, width: 1000, height: 700), display: true)
        window.orderFront(nil)
        spinRunLoop()

        controller.newSession(nil)
        spinRunLoop()
        controller.splitRight(nil)
        spinRunLoop()
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

    private func makeController(presenter: SplitClosePresenter) -> MainWindowController {
        MainWindowController(
            initialConfig: InkConfig(),
            configURL: FileManager.default.temporaryDirectory
                .appendingPathComponent("ink-close-test-\(UUID().uuidString).toml"),
            configSyncService: ConfigSyncService(),
            sessionCloseCoordinator: SessionCloseCoordinator(presenter: presenter)
        )
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
