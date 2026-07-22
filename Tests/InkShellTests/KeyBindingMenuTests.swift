import AppKit
import InkConfig
import Testing
@testable import InkShell

@Suite("自定义快捷键菜单", .serialized)
@MainActor
struct KeyBindingMenuTests {
    @Test("adapter 映射特殊键和显示字形")
    func appKitMapping() throws {
        let binding = try #require(KeyBinding.parse("cmd+alt+left"))
        #expect(KeyBindingAppKitAdapter.keyEquivalent(for: binding) == "\u{F702}")
        #expect(KeyBindingAppKitAdapter.modifierFlags(for: binding) == [.command, .option])
        #expect(KeyBindingAppKitAdapter.displayString(for: binding) == "⌘⌥←")
    }

    @Test("自定义与禁用同步到原生菜单")
    func menuUsesBindings() throws {
        var config = InkConfig()
        _ = config.setKeyBinding(
            .binding(try #require(KeyBinding.parse("ctrl+shift+t"))),
            for: .newTab
        )
        _ = config.setKeyBinding(.disabled, for: .find)
        let menu = AppDelegate.makeMainMenu(keyBindings: config.keyBindings)

        let newTab = try #require(item(
            action: #selector(MainWindowController.newSession(_:)), in: menu
        ))
        let find = try #require(item(
            action: #selector(MainWindowController.findInActivePane(_:)), in: menu
        ))
        #expect(newTab.keyEquivalent == "t")
        #expect(newTab.keyEquivalentModifierMask == [.control, .shift])
        #expect(find.keyEquivalent.isEmpty)
        #expect(find.keyEquivalentModifierMask.isEmpty)
    }

    private func item(action: Selector, in menu: NSMenu) -> NSMenuItem? {
        for item in menu.items {
            if item.action == action { return item }
            if let submenu = item.submenu, let match = self.item(action: action, in: submenu) {
                return match
            }
        }
        return nil
    }
}
