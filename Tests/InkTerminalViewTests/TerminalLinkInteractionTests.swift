import AppKit
import Testing
import TerminalCore
@testable import InkTerminalView

@Suite("终端链接交互")
@MainActor
struct TerminalLinkInteractionTests {
    @Test("鼠标上报时普通右键上报，Option 右键开原生菜单")
    func routesContextClick() {
        #expect(LinkMouseRouter.contextAction(mouseReporting: true, optionHeld: false) == .reportToTUI)
        #expect(LinkMouseRouter.contextAction(mouseReporting: true, optionHeld: true) == .showNativeMenu)
        #expect(LinkMouseRouter.contextAction(mouseReporting: false, optionHeld: false) == .showNativeMenu)
    }

    @Test("只有绝对 URL 可打开，任意目标仍可复制")
    func validatesOpenableTargets() {
        #expect(TerminalLinkMenuPayload(target: "https://example.test").url?.scheme == "https")
        #expect(TerminalLinkMenuPayload(target: "relative/path").url == nil)
        #expect(TerminalLinkMenuPayload(target: "relative/path").target == "relative/path")
    }

    @Test("菜单载荷不随终端更新改变")
    func payloadIsStable() {
        let payload = TerminalLinkMenuPayload(target: "https://old.test")
        var terminal = Terminal(size: TerminalSize(columns: 20, rows: 2))
        var parser = Parser()
        parser.feed(Array("https://new.test".utf8), handler: &terminal)
        #expect(payload.target == "https://old.test")
    }

    @Test("Command 点击链接优先于 TUI 鼠标上报")
    func commandClickOpensLink() throws {
        let terminal = linkedTerminal(mouseReporting: true)
        let (window, view) = makeWindowView(terminal: { terminal })
        var opened: URL?
        var input = Data()
        view.onOpenLink = { opened = $0 }
        view.onInput = { input.append($0) }

        view.mouseDown(with: try event(.leftMouseDown, in: window, modifiers: [.command]))
        #expect(opened?.absoluteString == "https://example.test")
        #expect(input.isEmpty)
        _ = window
    }

    @Test("Option 右键弹链接菜单，普通右键仍发给 TUI")
    func optionContextMenuOverridesMouseReporting() throws {
        let terminal = linkedTerminal(mouseReporting: true)
        let (window, view) = makeWindowView(terminal: { terminal })
        var shownMenu: NSMenu?
        var input = Data()
        view.contextMenuPresenter = { menu, _, _ in shownMenu = menu }
        view.onInput = { input.append($0) }

        view.rightMouseDown(with: try event(.rightMouseDown, in: window, modifiers: []))
        #expect(!input.isEmpty)
        #expect(shownMenu == nil)

        view.rightMouseDown(with: try event(.rightMouseDown, in: window, modifiers: [.option]))
        #expect(shownMenu?.items.map(\.title) == ["打开链接", "复制链接"])
    }

    @Test("复制动作使用菜单创建时的目标")
    func copyUsesCapturedTarget() throws {
        var terminal = linkedTerminal(mouseReporting: false)
        let (window, view) = makeWindowView(terminal: { terminal })
        var shownMenu: NSMenu?
        var copied = ""
        view.contextMenuPresenter = { menu, _, _ in shownMenu = menu }
        view.pasteboardWriter = { copied = $0; return true }
        view.rightMouseDown(with: try event(.rightMouseDown, in: window, modifiers: []))
        let copyItem = try #require(shownMenu?.items.last)

        var parser = Parser()
        terminal = Terminal(size: TerminalSize(columns: 40, rows: 3))
        parser.feed(Array("https://new.test".utf8), handler: &terminal)
        view.copyLink(copyItem)
        #expect(copied == "https://example.test")
    }

    @Test("鼠标移动解析并保存完整悬停范围")
    func hoverResolvesLink() throws {
        let terminal = linkedTerminal(mouseReporting: false)
        let (window, view) = makeWindowView(terminal: { terminal })
        view.mouseMoved(with: try event(.mouseMoved, in: window, modifiers: []))
        #expect(view.hoveredLinkForTesting?.target == "https://example.test")
        #expect(view.hoveredLinkForTesting?.range.start == TextPosition(line: 0, column: 0))
    }
}

private func linkedTerminal(mouseReporting: Bool) -> Terminal {
    var terminal = Terminal(size: TerminalSize(columns: 40, rows: 3))
    var parser = Parser()
    let mode = mouseReporting ? "\u{1B}[?1000h" : ""
    parser.feed(Array((mode + "https://example.test").utf8), handler: &terminal)
    return terminal
}

@MainActor
private func makeWindowView(
    terminal: @escaping () -> Terminal
) -> (NSWindow, TerminalMetalView) {
    let window = NSWindow(
        contentRect: NSRect(x: 0, y: 0, width: 640, height: 240),
        styleMask: [.titled], backing: .buffered, defer: false
    )
    let view = TerminalMetalView(frame: window.contentView!.bounds)
    view.terminalProvider = terminal
    window.contentView = view
    view.layoutSubtreeIfNeeded()
    return (window, view)
}

@MainActor
private func event(
    _ type: NSEvent.EventType,
    in window: NSWindow,
    modifiers: NSEvent.ModifierFlags
) throws -> NSEvent {
    try #require(NSEvent.mouseEvent(
        with: type,
        location: NSPoint(x: 12, y: window.contentView!.bounds.height - 12),
        modifierFlags: modifiers,
        timestamp: 0,
        windowNumber: window.windowNumber,
        context: nil,
        eventNumber: 1,
        clickCount: 1,
        pressure: 0
    ))
}
