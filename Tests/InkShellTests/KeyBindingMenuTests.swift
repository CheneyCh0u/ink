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

    @Test("adapter 将 Command-Shift-= 规范化为 cmd+plus")
    func appKitNormalizesPhysicalPlusKey() throws {
        let event = try #require(NSEvent.keyEvent(
            with: .keyDown,
            location: .zero,
            modifierFlags: [.command, .shift],
            timestamp: 0,
            windowNumber: 0,
            context: nil,
            characters: "+",
            charactersIgnoringModifiers: "=",
            isARepeat: false,
            keyCode: 24
        ))

        #expect(KeyBindingAppKitAdapter.binding(from: event) == KeyBinding.parse("cmd+plus"))
    }

    @Test("adapter 可录制功能键和标准 Delete")
    func appKitRecordsFunctionAndDeleteKeys() throws {
        let f1 = try #require(keyEvent(
            characters: "\u{F704}",
            charactersIgnoringModifiers: "\u{F704}",
            keyCode: 122
        ))
        let delete = try #require(keyEvent(
            characters: "\u{7F}",
            charactersIgnoringModifiers: "\u{7F}",
            keyCode: 51
        ))

        #expect(KeyBindingAppKitAdapter.binding(from: f1) == KeyBinding.parse("cmd+f1"))
        #expect(KeyBindingAppKitAdapter.binding(from: delete) == KeyBinding.parse("cmd+delete"))
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

    @Test("descriptor 穷举全部可配置 action 并直接建立默认菜单")
    func descriptorsCoverEveryMenuAction() throws {
        let expectedActions = Set(KeyBindingAction.allCases.filter { $0 != .splitPrefix })
        let descriptorsByAction = Dictionary(
            grouping: MenuCommandDescriptor.all,
            by: \.action
        )
        #expect(Set(descriptorsByAction.keys) == expectedActions)
        #expect(descriptorsByAction.values.allSatisfy { $0.count == 1 })

        let menu = AppDelegate.makeMainMenu()
        for descriptor in MenuCommandDescriptor.all {
            let menuItem = try #require(item(action: descriptor.selector, in: menu))
            #expect(menuItem.title == descriptor.title)
            #expect(menuItem.menu?.title == descriptor.group.title)
            #expect(menuItem.tag == descriptor.tag)

            if let binding = KeyBindingSet.defaults.binding(for: descriptor.action) {
                #expect(
                    menuItem.keyEquivalent
                        == KeyBindingAppKitAdapter.keyEquivalent(for: binding)
                )
                #expect(
                    menuItem.keyEquivalentModifierMask
                        == KeyBindingAppKitAdapter.modifierFlags(for: binding)
                )
            } else {
                #expect(menuItem.keyEquivalent.isEmpty)
                #expect(menuItem.keyEquivalentModifierMask.isEmpty)
            }
        }
    }

    @Test("启动首个菜单直接使用磁盘配置")
    func launchMenuUsesPersistedBindings() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("ink-launch-menu-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let configURL = directory.appendingPathComponent("config.toml")
        var config = InkConfig()
        _ = config.setKeyBinding(
            .binding(try #require(KeyBinding.parse("cmd+ctrl+t"))),
            for: .newTab
        )
        try config.save(to: configURL)

        let launch = AppDelegate.prepareLaunch(configURL: configURL)
        let newTab = try #require(item(
            action: #selector(MainWindowController.newSession(_:)), in: launch.menu
        ))

        #expect(launch.config.keyBindings == config.keyBindings)
        #expect(newTab.keyEquivalent == "t")
        #expect(newTab.keyEquivalentModifierMask == [.command, .control])
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

    private func keyEvent(
        characters: String,
        charactersIgnoringModifiers: String,
        keyCode: UInt16
    ) -> NSEvent? {
        NSEvent.keyEvent(
            with: .keyDown,
            location: .zero,
            modifierFlags: [.command],
            timestamp: 0,
            windowNumber: 0,
            context: nil,
            characters: characters,
            charactersIgnoringModifiers: charactersIgnoringModifiers,
            isARepeat: false,
            keyCode: keyCode
        )
    }
}
