import AppKit
import Testing
@testable import InkShell

@Suite("字号菜单", .serialized)
@MainActor
struct FontSizeMenuTests {
    @Test("显示菜单提供字号命令与新的侧边栏快捷键")
    func viewMenuBindings() throws {
        let menu = AppDelegate.makeMainMenu()
        let view = try #require(menu.items.first { $0.submenu?.title == "显示" }?.submenu)
        let expected: [(String, Selector, String, NSEvent.ModifierFlags)] = [
            ("放大字号", #selector(MainWindowController.increaseFontSize(_:)), "+", [.command]),
            ("缩小字号", #selector(MainWindowController.decreaseFontSize(_:)), "-", [.command]),
            ("恢复默认字号", #selector(MainWindowController.resetFontSize(_:)), "0", [.command]),
            ("切换侧边栏", #selector(NSSplitViewController.toggleSidebar(_:)), "s", [.command, .control]),
        ]

        for (title, action, key, modifiers) in expected {
            let item = try #require(view.items.first { $0.title == title })
            #expect(item.action == action)
            #expect(item.keyEquivalent == key)
            #expect(item.keyEquivalentModifierMask == modifiers)
        }
        #expect(view.items.contains { $0.isSeparatorItem })
    }

    @Test("侧边栏菜单验证允许执行三态切换")
    func sidebarToggleValidation() {
        let splitViewController = ShellSplitViewController()
        let menuItem = NSMenuItem()
        menuItem.action = #selector(NSSplitViewController.toggleSidebar(_:))
        var toggleCount = 0
        splitViewController.onToggleSidebar = { toggleCount += 1 }

        #expect(splitViewController.validateUserInterfaceItem(menuItem))
        splitViewController.toggleSidebar(nil)
        #expect(toggleCount == 1)
    }
}
