import AppKit
import Foundation
import InkConfig
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
            ("切换侧边栏", #selector(MainWindowController.toggleSidebarMode(_:)), "s", [.command, .control]),
        ]

        for (title, action, key, modifiers) in expected {
            let item = try #require(view.items.first { $0.title == title })
            #expect(item.action == action)
            #expect(item.keyEquivalent == key)
            #expect(item.keyEquivalentModifierMask == modifiers)
        }
        #expect(view.items.contains { $0.isSeparatorItem })
    }

    @Test("主窗口响应链启用侧边栏菜单")
    func mainWindowResponderChainEnablesSidebarMenu() throws {
        let fixture = try FontSizeMenuWindowFixture()
        defer { fixture.cleanUp() }
        let menu = AppDelegate.makeMainMenu()
        NSApp.mainMenu = menu
        fixture.controller.showWindow(nil)
        fixture.controller.window?.makeKey()
        fixture.spinRunLoop()
        let window = try #require(fixture.controller.window)
        let modalSession = NSApp.beginModalSession(for: window)
        defer { NSApp.endModalSession(modalSession) }
        _ = NSApp.runModalSession(modalSession)

        let view = try #require(menu.items.first { $0.submenu?.title == "显示" }?.submenu)
        view.update()
        let fontItems = try ["放大字号", "缩小字号", "恢复默认字号"].map { title in
            try #require(view.items.first { $0.title == title })
        }
        let sidebarItem = try #require(view.items.first { $0.title == "切换侧边栏" })
        let fontTargets = fontItems.map { item in
            NSApp.target(forAction: item.action!, to: item.target, from: item)
        }
        let sidebarTarget = NSApp.target(
            forAction: sidebarItem.action!,
            to: sidebarItem.target,
            from: sidebarItem
        )

        let fontTargetNames = fontTargets.map { target in
            target.map { String(describing: type(of: $0)) } ?? "nil"
        }
        let sidebarTargetName = sidebarTarget.map {
            String(describing: type(of: $0))
        } ?? "nil"
        print("字号菜单 targets: \(fontTargetNames)")
        print("侧边栏菜单 target: \(sidebarTargetName)")
        #expect(NSApp.modalWindow === window)
        #expect(fontTargets.allSatisfy { ($0 as? MainWindowController) === fixture.controller })
        #expect((sidebarTarget as? MainWindowController) === fixture.controller)
        #expect(sidebarItem.isEnabled)
    }
}

@MainActor
private struct FontSizeMenuWindowFixture {
    let controller: MainWindowController
    let directory: URL
    private let previousMainMenu: NSMenu?

    init() throws {
        let application = NSApplication.shared
        previousMainMenu = application.mainMenu
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("ink-font-menu-\(UUID().uuidString)")
        try FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: true
        )
        let configURL = directory.appendingPathComponent("config.toml")
        let config = InkConfig()
        try config.save(to: configURL)
        controller = MainWindowController(
            initialConfig: config,
            configURL: configURL,
            configSyncService: ConfigSyncService()
        )
    }

    func spinRunLoop(cycles: Int = 8) {
        for _ in 0..<cycles {
            RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.05))
        }
    }

    func cleanUp() {
        controller.window?.close()
        NSApp.mainMenu = previousMainMenu
        try? FileManager.default.removeItem(at: directory)
    }
}
