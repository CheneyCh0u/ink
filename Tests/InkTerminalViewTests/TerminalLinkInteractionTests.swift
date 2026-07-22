import AppKit
import Testing
import TerminalCore
@testable import InkTerminalView

@Suite("终端链接交互")
@MainActor
struct TerminalLinkInteractionTests {
    @Test("普通位置弹出完整原生菜单且显示前已聚焦")
    func ordinaryPositionShowsCompleteMenuAfterFocus() throws {
        let terminal = Terminal(size: TerminalSize(columns: 40, rows: 3))
        let (window, view) = makeWindowView(terminal: { terminal })
        var shownMenu: NSMenu?
        var focusedBeforePresentation = false
        var focused = false
        view.onFocus = { focused = true }
        view.onFind = {}
        view.onSplit = { _ in }
        view.onClearScrollback = {}
        view.pasteboardReader = { "paste text" }
        view.contextMenuPresenter = { menu, _, _ in
            focusedBeforePresentation = focused
            shownMenu = menu
        }

        view.rightMouseDown(with: try event(.rightMouseDown, in: window, modifiers: []))

        #expect(focusedBeforePresentation)
        #expect(menuTitles(shownMenu) == [
            "拷贝", "粘贴", "—", "查找…", "—",
            "向左分屏", "向右分屏", "向上分屏", "向下分屏",
            "—", "清除滚动缓冲区",
        ])
        #expect(shownMenu?.items.first { $0.action == #selector(TerminalMetalView.copy(_:)) }?.isEnabled == false)
        #expect(shownMenu?.items.first { $0.action == #selector(TerminalMetalView.paste(_:)) }?.isEnabled == true)
    }

    @Test("剪贴板没有非空文本时禁用粘贴")
    func disablesPasteWithoutText() throws {
        let terminal = Terminal(size: TerminalSize(columns: 40, rows: 3))
        let (window, view) = makeWindowView(terminal: { terminal })
        var shownMenu: NSMenu?
        view.contextMenuPresenter = { menu, _, _ in shownMenu = menu }
        view.pasteboardReader = { nil }

        view.rightMouseDown(with: try event(.rightMouseDown, in: window, modifiers: []))
        #expect(shownMenu?.items.first { $0.action == #selector(TerminalMetalView.paste(_:)) }?.isEnabled == false)

        view.pasteboardReader = { "" }
        view.rightMouseDown(with: try event(.rightMouseDown, in: window, modifiers: []))
        #expect(shownMenu?.items.first { $0.action == #selector(TerminalMetalView.paste(_:)) }?.isEnabled == false)
    }

    @Test("上下文粘贴仍经过 SafePaste 风险确认")
    func contextPasteUsesSafePaste() throws {
        let terminal = Terminal(size: TerminalSize(columns: 40, rows: 6))
        let (window, view) = makeWindowView(terminal: { terminal })
        let presenter = ContextMenuSafePastePresenter()
        var shownMenu: NSMenu?
        var input = Data()
        view.safePastePresenter = presenter
        view.pasteboardReader = { "rm one\nrm two" }
        view.onInput = { input.append($0) }
        view.contextMenuPresenter = { menu, _, _ in shownMenu = menu }

        view.rightMouseDown(with: try event(.rightMouseDown, in: window, modifiers: []))
        let pasteItem = try #require(shownMenu?.items.first {
            $0.action == #selector(TerminalMetalView.paste(_:))
        })
        _ = NSApp.sendAction(try #require(pasteItem.action), to: pasteItem.target, from: pasteItem)

        #expect(presenter.assessments == [SafePasteAssessment(
            lineCount: 2,
            risks: [.multipleLines, .unprotectedTarget]
        )])
        #expect(input.isEmpty)
    }

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
        let bytesAfterDown = input.count
        view.rightMouseUp(with: try event(.rightMouseUp, in: window, modifiers: [.option]))
        #expect(input.count > bytesAfterDown)

        view.rightMouseDown(with: try event(.rightMouseDown, in: window, modifiers: [.option]))
        #expect(menuTitles(shownMenu) == [
            "打开链接", "复制链接", "—", "拷贝", "粘贴", "—", "查找…", "—",
            "向左分屏", "向右分屏", "向上分屏", "向下分屏",
            "—", "清除滚动缓冲区",
        ])
        let bytesBeforeUp = input.count
        view.rightMouseUp(with: try event(.rightMouseUp, in: window, modifiers: [.option]))
        #expect(input.count == bytesBeforeUp)
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
        let copyItem = try #require(shownMenu?.items.first {
            $0.action == #selector(TerminalMetalView.copyLink(_:))
        })

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

    @Test("清历史通知丢弃旧链接悬停")
    func clearScrollbackResetsHover() throws {
        let terminal = linkedTerminal(mouseReporting: false)
        let (window, view) = makeWindowView(terminal: { terminal })
        view.mouseMoved(with: try event(.mouseMoved, in: window, modifiers: []))
        #expect(view.hoveredLinkForTesting != nil)

        view.scrollbackDidClear()

        #expect(view.hoveredLinkForTesting == nil)
    }

    @Test("清历史通知丢弃旧选区")
    func clearScrollbackResetsSelection() throws {
        var terminal = Terminal(size: TerminalSize(columns: 40, rows: 3))
        var parser = Parser()
        parser.feed(Array("select this text".utf8), handler: &terminal)
        let (window, view) = makeWindowView(terminal: { terminal })
        let copyItem = NSMenuItem(
            title: "拷贝",
            action: #selector(TerminalMetalView.copy(_:)),
            keyEquivalent: ""
        )
        view.mouseDown(with: try event(.leftMouseDown, in: window, modifiers: [], x: 12))
        view.mouseDragged(with: try event(
            .leftMouseDragged,
            in: window,
            modifiers: [],
            x: 80
        ))
        #expect(view.validateMenuItem(copyItem))

        view.scrollbackDidClear()

        #expect(!view.validateMenuItem(copyItem))
    }

    @Test("终端内容 inset 不会夹到边缘链接 cell")
    func paddingDoesNotHitEdgeLink() throws {
        let terminal = linkedTerminal(mouseReporting: false)
        let (window, view) = makeWindowView(terminal: { terminal })
        var opened: URL?
        view.onOpenLink = { opened = $0 }
        let paddingEvent = try event(
            .mouseMoved,
            in: window,
            modifiers: [],
            x: 2,
            yFromTop: 2
        )

        view.mouseMoved(with: paddingEvent)
        view.mouseDown(with: try event(
            .leftMouseDown,
            in: window,
            modifiers: [.command],
            x: 2,
            yFromTop: 2
        ))

        #expect(view.hoveredLinkForTesting == nil)
        #expect(opened == nil)
    }
}

private func menuTitles(_ menu: NSMenu?) -> [String] {
    menu?.items.map { $0.isSeparatorItem ? "—" : $0.title } ?? []
}

@MainActor
private final class ContextMenuSafePastePresenter: SafePastePresenting {
    var assessments: [SafePasteAssessment] = []

    func choose(for assessment: SafePasteAssessment) -> SafePasteChoice {
        assessments.append(assessment)
        return .cancel
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
    modifiers: NSEvent.ModifierFlags,
    x: CGFloat = 12,
    yFromTop: CGFloat = 12
) throws -> NSEvent {
    try #require(NSEvent.mouseEvent(
        with: type,
        location: NSPoint(x: x, y: window.contentView!.bounds.height - yFromTop),
        modifierFlags: modifiers,
        timestamp: 0,
        windowNumber: window.windowNumber,
        context: nil,
        eventNumber: 1,
        clickCount: 1,
        pressure: 0
    ))
}
