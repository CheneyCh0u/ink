import AppKit
import InkConfig
import InkTerminalView

/// 应用入口：菜单 + 主窗口。窗口结构在 `MainWindowController`。
@MainActor
public final class AppDelegate: NSObject, NSApplicationDelegate {

    struct LaunchPreparation {
        let config: InkConfig
        let menu: NSMenu
    }

    private var mainWindowController: MainWindowController?

    public override init() {
        super.init()
    }

    public func applicationDidFinishLaunching(_ notification: Notification) {
        let configURL = InkConfig.defaultURL
        let launch = Self.prepareLaunch(configURL: configURL, settingsTarget: self)
        NSApplication.shared.mainMenu = launch.menu
        let controller = MainWindowController(
            initialConfig: launch.config,
            configURL: configURL,
            configSyncService: ConfigSyncService()
        )
        controller.onKeyBindingsChange = { [weak self] keyBindings in
            self?.buildMenu(keyBindings: keyBindings)
        }
        controller.showWindow(nil)
        mainWindowController = controller
        NSApplication.shared.activate()
    }

    public func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        true
    }

    public func applicationDidBecomeActive(_ notification: Notification) {
        mainWindowController?.applicationDidBecomeActive()
    }

    public func applicationShouldTerminate(
        _ sender: NSApplication
    ) -> NSApplication.TerminateReply {
        guard let mainWindowController else { return .terminateNow }
        return mainWindowController.requestApplicationTermination()
            ? .terminateNow
            : .terminateCancel
    }

    // MARK: - 菜单

    private func buildMenu(keyBindings: KeyBindingSet) {
        NSApplication.shared.mainMenu = Self.makeMainMenu(
            settingsTarget: self,
            keyBindings: keyBindings
        )
    }

    static func prepareLaunch(
        configURL: URL = InkConfig.defaultURL,
        settingsTarget: AnyObject? = nil
    ) -> LaunchPreparation {
        let config = InkConfig.load(from: configURL)
        return LaunchPreparation(
            config: config,
            menu: makeMainMenu(settingsTarget: settingsTarget, keyBindings: config.keyBindings)
        )
    }

    static func makeMainMenu(
        settingsTarget: AnyObject? = nil,
        keyBindings: KeyBindingSet = .defaults
    ) -> NSMenu {
        let mainMenu = NSMenu()

        let appItem = NSMenuItem()
        let appMenu = NSMenu()
        let settingsItem = appMenu.addItem(
            withTitle: "设置…",
            action: #selector(AppDelegate.showSettings(_:)),
            keyEquivalent: ","
        )
        settingsItem.target = settingsTarget
        appMenu.addItem(.separator())
        appMenu.addItem(
            withTitle: "退出 Ink",
            action: #selector(NSApplication.terminate(_:)),
            keyEquivalent: "q"
        )
        appItem.submenu = appMenu
        mainMenu.addItem(appItem)

        let fileItem = NSMenuItem()
        let fileMenu = NSMenu(title: "文件")
        addConfiguredDescriptors(
            MenuCommandDescriptor.descriptors(in: .file),
            to: fileMenu,
            bindings: keyBindings
        )
        fileMenu.addItem(.separator())
        fileMenu.addItem(
            withTitle: "移除当前项目",
            action: #selector(MainWindowController.removeCurrentProject(_:)),
            keyEquivalent: ""
        )
        fileItem.submenu = fileMenu
        mainMenu.addItem(fileItem)

        let editItem = NSMenuItem()
        let editMenu = NSMenu(title: "编辑")
        addConfiguredDescriptors(
            MenuCommandDescriptor.descriptors(in: .edit).filter { $0.action == .find },
            to: editMenu,
            bindings: keyBindings
        )
        editMenu.addItem(.separator())
        editMenu.addItem(withTitle: "拷贝", action: #selector(TerminalMetalView.copy(_:)), keyEquivalent: "c")
        editMenu.addItem(withTitle: "粘贴", action: #selector(TerminalMetalView.paste(_:)), keyEquivalent: "v")
        editMenu.addItem(.separator())
        addConfiguredDescriptors(
            MenuCommandDescriptor.descriptors(in: .edit).filter { $0.action != .find },
            to: editMenu,
            bindings: keyBindings
        )
        editItem.submenu = editMenu
        mainMenu.addItem(editItem)

        let viewItem = NSMenuItem()
        let viewMenu = NSMenu(title: "显示")
        let viewDescriptors = MenuCommandDescriptor.descriptors(in: .view)
        addConfiguredDescriptors(
            viewDescriptors.filter { $0.action != .toggleSidebar },
            to: viewMenu,
            bindings: keyBindings
        )
        viewMenu.addItem(.separator())
        addConfiguredDescriptors(
            viewDescriptors.filter { $0.action == .toggleSidebar },
            to: viewMenu,
            bindings: keyBindings
        )
        viewItem.submenu = viewMenu
        mainMenu.addItem(viewItem)

        let windowItem = NSMenuItem()
        let windowMenu = NSMenu(title: "窗口")
        let windowDescriptors = MenuCommandDescriptor.descriptors(in: .window)
        addConfiguredDescriptors(
            windowDescriptors.filter {
                [.focusLeft, .focusRight, .focusUp, .focusDown].contains($0.action)
            },
            to: windowMenu,
            bindings: keyBindings
        )
        windowMenu.addItem(.separator())
        addConfiguredDescriptors(
            windowDescriptors.filter { $0.action == .nextTab || $0.action == .previousTab },
            to: windowMenu,
            bindings: keyBindings
        )
        windowMenu.addItem(.separator())
        for i in 1...9 {
            let item = NSMenuItem(
                title: "会话 \(i)",
                action: #selector(MainWindowController.selectSessionMenu(_:)),
                keyEquivalent: "\(i)"
            )
            item.tag = i - 1
            windowMenu.addItem(item)
        }
        windowItem.submenu = windowMenu
        mainMenu.addItem(windowItem)

        return mainMenu
    }

    private static func addConfiguredDescriptors(
        _ descriptors: [MenuCommandDescriptor],
        to menu: NSMenu,
        bindings: KeyBindingSet
    ) {
        for descriptor in descriptors {
            let binding = bindings.binding(for: descriptor.action)
            let item = NSMenuItem(
                title: descriptor.title,
                action: descriptor.selector,
                keyEquivalent: binding.map(KeyBindingAppKitAdapter.keyEquivalent(for:)) ?? ""
            )
            item.keyEquivalentModifierMask = binding.map(
                KeyBindingAppKitAdapter.modifierFlags(for:)
            ) ?? []
            item.tag = descriptor.tag
            menu.addItem(item)
        }
    }

    @objc private func showSettings(_ sender: Any?) {
        mainWindowController?.showSettings(sender)
    }
}
