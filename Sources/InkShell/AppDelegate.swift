import AppKit
import InkTerminalView

/// 应用入口：菜单 + 主窗口。窗口结构在 `MainWindowController`。
@MainActor
public final class AppDelegate: NSObject, NSApplicationDelegate {

    private var mainWindowController: MainWindowController?

    public override init() {
        super.init()
    }

    public func applicationDidFinishLaunching(_ notification: Notification) {
        buildMenu()
        let controller = MainWindowController()
        controller.showWindow(nil)
        mainWindowController = controller
        NSApplication.shared.activate()
    }

    public func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        true
    }

    // MARK: - 菜单

    private func buildMenu() {
        NSApplication.shared.mainMenu = Self.makeMainMenu(settingsTarget: self)
    }

    static func makeMainMenu(settingsTarget: AnyObject? = nil) -> NSMenu {
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
        fileMenu.addItem(
            withTitle: "新建项目…",
            action: #selector(MainWindowController.newProject(_:)),
            keyEquivalent: "n"
        )
        fileMenu.addItem(
            withTitle: "新建标签",
            action: #selector(MainWindowController.newSession(_:)),
            keyEquivalent: "t"
        )
        fileMenu.addItem(
            withTitle: "向右分屏",
            action: #selector(MainWindowController.splitRight(_:)),
            keyEquivalent: "d"
        )
        let splitDownItem = fileMenu.addItem(
            withTitle: "向下分屏",
            action: #selector(MainWindowController.splitDown(_:)),
            keyEquivalent: "d"
        )
        splitDownItem.keyEquivalentModifierMask = [.command, .shift]
        fileMenu.addItem(
            withTitle: "关闭当前分屏",
            action: #selector(MainWindowController.closeActivePane(_:)),
            keyEquivalent: "w"
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
        editMenu.addItem(withTitle: "拷贝", action: #selector(TerminalMetalView.copy(_:)), keyEquivalent: "c")
        editMenu.addItem(withTitle: "粘贴", action: #selector(TerminalMetalView.paste(_:)), keyEquivalent: "v")
        editItem.submenu = editMenu
        mainMenu.addItem(editItem)

        let viewItem = NSMenuItem()
        let viewMenu = NSMenu(title: "显示")
        viewMenu.addItem(
            withTitle: "切换侧边栏",
            action: #selector(NSSplitViewController.toggleSidebar(_:)),
            keyEquivalent: "0"
        )
        viewItem.submenu = viewMenu
        mainMenu.addItem(viewItem)

        let windowItem = NSMenuItem()
        let windowMenu = NSMenu(title: "窗口")
        let nextItem = NSMenuItem(
            title: "下一个会话",
            action: #selector(MainWindowController.nextSession(_:)),
            keyEquivalent: "]"
        )
        nextItem.keyEquivalentModifierMask = [.command, .shift]
        windowMenu.addItem(nextItem)
        let prevItem = NSMenuItem(
            title: "上一个会话",
            action: #selector(MainWindowController.previousSession(_:)),
            keyEquivalent: "["
        )
        prevItem.keyEquivalentModifierMask = [.command, .shift]
        windowMenu.addItem(prevItem)
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

    @objc private func showSettings(_ sender: Any?) {
        mainWindowController?.showSettings(sender)
    }
}
