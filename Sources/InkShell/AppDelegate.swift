import AppKit
import InkDesign
import InkTerminalView
import TerminalCore

/// M2 外壳：单窗口 + Metal 终端视图 + 一个会话。
/// 侧边栏、标签页等真正的外壳是 M5（任务 #12）。
@MainActor
public final class AppDelegate: NSObject, NSApplicationDelegate, NSWindowDelegate {

    private var window: NSWindow?
    private var terminalView: TerminalMetalView?
    private var session: TerminalSession?

    public override init() {
        super.init()
    }

    public func applicationDidFinishLaunching(_ notification: Notification) {
        buildMenu()
        buildWindow()
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

        let view = TerminalMetalView(frame: window.contentLayoutRect)

        // 格数就绪 / 变化：首次启动 shell，之后同步尺寸。
        view.onGridResize = { [weak self] size in
            guard let self else { return }
            if let session = self.session {
                session.resize(to: size)
            } else {
                self.startSession(size: size, view: view)
            }
        }

        window.contentView = view
        window.center()
        window.makeKeyAndOrderFront(nil)
        window.makeFirstResponder(view)

        self.window = window
        self.terminalView = view
    }

    public func windowWillClose(_ notification: Notification) {
        session?.terminate()
    }

    // MARK: - 会话

    private func startSession(size: TerminalSize, view: TerminalMetalView) {
        let session = TerminalSession(size: size)

        view.terminalProvider = { [weak session] in
            session?.terminal ?? Terminal(size: size, scrollbackCapacity: 1)
        }
        view.onInput = { [weak session] data in
            session?.write(data)
        }
        session.onUpdate = { [weak view] in
            view?.markDirty()
        }
        session.onExit = { [weak self] _ in
            // M2 单窗口语义：shell 退了窗口就关。
            self?.window?.close()
        }

        do {
            try session.start()
            self.session = session
        } catch {
            NSAlert(error: error).runModal()
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
        // 拷贝是任务 #9（选中）的一部分，选中做好后接。
        editMenu.addItem(withTitle: "粘贴", action: #selector(TerminalMetalView.paste(_:)), keyEquivalent: "v")
        editItem.submenu = editMenu
        mainMenu.addItem(editItem)

        NSApplication.shared.mainMenu = mainMenu
    }
}
