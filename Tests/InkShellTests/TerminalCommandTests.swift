import AppKit
import InkConfig
import InkTerminalView
import TerminalCore
import Testing
@testable import InkShell

@Suite("终端命令块菜单", .serialized)
@MainActor
struct TerminalCommandTests {
    @Test("编辑菜单提供命令跳转与复制快捷键")
    func editMenuCommands() throws {
        let menu = AppDelegate.makeMainMenu()
        let edit = try #require(menu.items.first { $0.submenu?.title == "编辑" }?.submenu)
        let expected: [(Selector, String, NSEvent.ModifierFlags)] = [
            (#selector(MainWindowController.previousCommand(_:)), "\u{F700}", [.command, .shift]),
            (#selector(MainWindowController.nextCommand(_:)), "\u{F701}", [.command, .shift]),
            (#selector(MainWindowController.copyCommand(_:)), "c", [.command, .shift]),
            (#selector(MainWindowController.copyCommandOutput(_:)), "o", [.command, .shift]),
        ]

        for (action, key, modifiers) in expected {
            let item = try #require(edit.items.first { $0.action == action })
            #expect(item.keyEquivalent == key)
            #expect(item.keyEquivalentModifierMask == modifiers)
        }
    }

    @Test("工作区只把复制动作发给活动 pane")
    func routesToActivePane() throws {
        let first = TerminalPane(session: TerminalSession(size: TerminalSize(columns: 20, rows: 3)))
        let second = TerminalPane(session: TerminalSession(size: TerminalSize(columns: 20, rows: 3)))
        let tab = TerminalTab(initialPane: first)
        _ = tab.insertPane(second, splitting: first.id, direction: .right)
        let workspace = TerminalWorkspaceViewController()
        workspace.show(tab: tab, config: InkConfig())
        let firstView = try #require(workspace.terminalView(for: first.id))
        let secondView = try #require(workspace.terminalView(for: second.id))
        let pasteboard = NSPasteboard.general
        let original = pasteboard.string(forType: .string)
        defer {
            pasteboard.clearContents()
            if let original { pasteboard.setString(original, forType: .string) }
        }
        firstView.terminalProvider = { commandTerminal("first") }
        secondView.terminalProvider = { commandTerminal("second") }

        workspace.activate(first.id)
        #expect(workspace.copyCommandInActivePane())
        #expect(pasteboard.string(forType: .string) == "first")
        workspace.activate(second.id)
        #expect(workspace.copyCommandInActivePane())
        #expect(pasteboard.string(forType: .string) == "second")
    }

    private func commandTerminal(_ command: String) -> Terminal {
        var terminal = Terminal(size: TerminalSize(columns: 20, rows: 3))
        var parser = Parser()
        let text = "\u{1B}]133;A\u{07}$ \u{1B}]133;B\u{07}\(command)\r\n"
            + "\u{1B}]133;C\u{07}out\r\n\u{1B}]133;D;0\u{07}"
        parser.feed(Array(text.utf8), handler: &terminal)
        return terminal
    }
}
