import AppKit
import Testing
@testable import InkShell

@Suite("终端搜索命令")
@MainActor
struct TerminalSearchCommandTests {
    @Test("编辑菜单提供 Command-F 当前 pane 搜索")
    func editMenuFindCommand() throws {
        let menu = AppDelegate.makeMainMenu()
        let editMenu = try #require(menu.items.first { $0.submenu?.title == "编辑" }?.submenu)
        let item = try #require(editMenu.items.first {
            $0.action == #selector(MainWindowController.findInActivePane(_:))
        })

        #expect(item.keyEquivalent == "f")
        #expect(item.keyEquivalentModifierMask == .command)
    }
}
