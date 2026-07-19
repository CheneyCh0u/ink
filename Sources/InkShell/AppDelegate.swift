import AppKit
import InkDesign
import InkPTY

/// M1 外壳：单窗口 + 占位终端视图 + 一个 PTY 会话。
/// 侧边栏、标签页等真正的外壳是 M5（任务 #12），现在不搭。
@MainActor
public final class AppDelegate: NSObject, NSApplicationDelegate, NSWindowDelegate {

    private var window: NSWindow?
    private var terminalView: PlaceholderTerminalView?
    private var session: PTYSession?

    public override init() {
        super.init()
    }

    public func applicationDidFinishLaunching(_ notification: Notification) {
        buildMenu()
        buildWindow()
        startShell()
        NSApplication.shared.activate()
    }

    public func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        true
    }

    // MARK: - 窗口

    private func buildWindow() {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 960, height: 620),
            styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        window.titlebarAppearsTransparent = true
        window.titleVisibility = .hidden
        window.backgroundColor = InkDesignTokens.Color.canvas
        window.minSize = NSSize(width: 400, height: 300)
        window.delegate = self
        window.isReleasedWhenClosed = false

        let view = PlaceholderTerminalView(frame: window.contentLayoutRect)
        window.contentView = view
        window.center()
        window.makeKeyAndOrderFront(nil)
        view.focus()

        self.window = window
        self.terminalView = view
    }

    public func windowDidResize(_ notification: Notification) {
        guard let view = terminalView, let session else { return }
        let grid = view.gridSize()
        session.resize(columns: grid.columns, rows: grid.rows)
    }

    public func windowWillClose(_ notification: Notification) {
        session?.terminate()
    }

    // MARK: - Shell

    private func startShell() {
        guard let view = terminalView else { return }
        let session = PTYSession()

        session.onOutput = { [weak view] data in
            view?.append(data)
        }
        session.onExit = { [weak self] status in
            self?.terminalView?.appendNotice("[shell 已退出，状态 \(status)]")
            self?.session = nil
        }
        view.onInput = { [weak session] data in
            session?.write(data)
        }

        let grid = view.gridSize()
        do {
            try session.start(columns: grid.columns, rows: grid.rows)
            self.session = session
        } catch {
            view.appendNotice("[启动 shell 失败：\(error)]")
        }
    }

    // MARK: - 菜单

    private func buildMenu() {
        let mainMenu = NSMenu()

        let appItem = NSMenuItem()
        let appMenu = NSMenu()
        appMenu.addItem(
            withTitle: "退出 ink",
            action: #selector(NSApplication.terminate(_:)),
            keyEquivalent: "q"
        )
        appItem.submenu = appMenu
        mainMenu.addItem(appItem)

        let editItem = NSMenuItem()
        let editMenu = NSMenu(title: "编辑")
        editMenu.addItem(withTitle: "拷贝", action: #selector(NSText.copy(_:)), keyEquivalent: "c")
        editMenu.addItem(withTitle: "粘贴", action: #selector(NSText.paste(_:)), keyEquivalent: "v")
        editMenu.addItem(withTitle: "全选", action: #selector(NSText.selectAll(_:)), keyEquivalent: "a")
        editItem.submenu = editMenu
        mainMenu.addItem(editItem)

        NSApplication.shared.mainMenu = mainMenu
    }
}
