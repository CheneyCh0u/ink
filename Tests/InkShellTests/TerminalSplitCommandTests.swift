import AppKit
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
        let controller = MainWindowController()
        let window = try #require(controller.window)
        window.setFrame(NSRect(x: 300, y: 200, width: 1000, height: 700), display: true)
        window.orderFront(nil)
        spinRunLoop()

        controller.newSession(nil)
        spinRunLoop()
        controller.splitRight(nil)
        spinRunLoop()
        #expect(terminalViews(in: window).count == 2)

        controller.closeActivePane(nil)
        spinRunLoop()
        #expect(terminalViews(in: window).count == 1)
        #expect(window.isVisible)

        window.close()
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
}
