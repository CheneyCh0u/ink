import AppKit
import Testing
import TerminalCore
@testable import InkTerminalView

@Suite("终端命令悬停入口")
@MainActor
struct TerminalCommandHoverTests {
    @Test("进入和离开命令首行切换轻量入口")
    func togglesEntryOnCommandStartLine() throws {
        let terminal = makeCommandHoverTerminal()
        let blocks = terminal.commandBlocks()
        let firstLine = try #require(blocks.first?.commandRange.start.line)
        let outputLine = try #require(blocks.first?.outputRange?.start.line)
        let (window, view) = makeCommandHoverWindow(terminal: { terminal })

        view.mouseMoved(with: try hoverEvent(in: window, view: view, absoluteLine: firstLine))
        let button = try #require(commandHoverButton(in: view))
        #expect(!button.isHidden)

        view.mouseMoved(with: try hoverEvent(in: window, view: view, absoluteLine: outputLine))
        #expect(button.isHidden)
    }

    @Test("没有命令记录不显示入口")
    func noCommandsHideEntry() throws {
        var terminal = Terminal(size: .init(columns: 40, rows: 10))
        var parser = Parser()
        parser.feed(Array("plain output".utf8), handler: &terminal)
        let (window, view) = makeCommandHoverWindow(terminal: { terminal })

        view.mouseMoved(with: try hoverEvent(in: window, view: view, absoluteLine: 0))

        #expect(commandHoverButton(in: view)?.isHidden != false)
    }

    @Test("链接命中优先于同一命令首行入口")
    func linkHoverWins() throws {
        var terminal = Terminal(size: .init(columns: 40, rows: 10))
        var parser = Parser()
        parser.feed(Array(commandHoverSequence(
            "https://example.test",
            output: "done"
        ).utf8), handler: &terminal)
        let block = try #require(terminal.commandBlocks().first)
        let (window, view) = makeCommandHoverWindow(terminal: { terminal })

        view.mouseMoved(with: try hoverEvent(
            in: window,
            view: view,
            absoluteLine: block.commandRange.start.line,
            column: block.commandRange.start.column
        ))

        #expect(view.hoveredLinkForTesting?.target == "https://example.test")
        #expect(commandHoverButton(in: view)?.isHidden != false)
    }

    @Test("TUI 鼠标模式仅 Option 显示原生入口")
    func optionOverridesMouseReporting() throws {
        let terminal = makeCommandHoverTerminal(mouseReporting: true)
        let firstLine = try #require(terminal.commandBlocks().first?.commandRange.start.line)
        let (window, view) = makeCommandHoverWindow(terminal: { terminal })
        var input = Data()
        view.onInput = { input.append($0) }

        view.mouseMoved(with: try hoverEvent(
            in: window,
            view: view,
            absoluteLine: firstLine
        ))
        #expect(commandHoverButton(in: view)?.isHidden != false)

        view.mouseMoved(with: try hoverEvent(
            in: window,
            view: view,
            absoluteLine: firstLine,
            modifiers: [.option]
        ))
        #expect(commandHoverButton(in: view)?.isHidden == false)
        #expect(input.isEmpty)
    }

    @Test("终端更新立即隐藏入口")
    func terminalUpdateHidesEntry() throws {
        let terminal = makeCommandHoverTerminal()
        let line = try #require(terminal.commandBlocks().first?.commandRange.start.line)
        let (window, view) = makeCommandHoverWindow(terminal: { terminal })
        view.mouseMoved(with: try hoverEvent(in: window, view: view, absoluteLine: line))
        let button = try #require(commandHoverButton(in: view))
        #expect(!button.isHidden)

        view.markDirty()

        #expect(button.isHidden)
    }

    @Test("开始选择和重置瞬态都隐藏入口")
    func selectionAndResetHideEntry() throws {
        let terminal = makeCommandHoverTerminal()
        let line = try #require(terminal.commandBlocks().first?.commandRange.start.line)
        let (window, view) = makeCommandHoverWindow(terminal: { terminal })
        let hover = try hoverEvent(in: window, view: view, absoluteLine: line)
        view.mouseMoved(with: hover)
        let button = try #require(commandHoverButton(in: view))

        view.mouseDown(with: try mouseDownEvent(
            in: window,
            matching: hover
        ))
        #expect(button.isHidden)

        view.mouseMoved(with: hover)
        #expect(!button.isHidden)
        view.resetTransientState()
        #expect(button.isHidden)
    }

    @Test("滚动历史隐藏入口")
    func scrollingHidesEntry() throws {
        var terminal = makeCommandHoverTerminal()
        var parser = Parser()
        parser.feed(Array("tail0\r\ntail1\r\ntail2\r\n".utf8), handler: &terminal)
        let line = try #require(terminal.commandBlocks().last?.commandRange.start.line)
        let (window, view) = makeCommandHoverWindow(terminal: { terminal })
        view.mouseMoved(with: try hoverEvent(in: window, view: view, absoluteLine: line))
        let button = try #require(commandHoverButton(in: view))
        #expect(!button.isHidden)

        view.scrollWheel(with: try scrollEvent())

        #expect(button.isHidden)
    }
}

@MainActor
private func makeCommandHoverWindow(
    terminal: @escaping () -> Terminal
) -> (NSWindow, TerminalMetalView) {
    let window = NSWindow(
        contentRect: NSRect(x: 0, y: 0, width: 720, height: 420),
        styleMask: [.titled], backing: .buffered, defer: false
    )
    window.isReleasedWhenClosed = false
    let view = TerminalMetalView(frame: window.contentView!.bounds)
    view.terminalProvider = terminal
    window.contentView = view
    view.layoutSubtreeIfNeeded()
    return (window, view)
}

@MainActor
private func commandHoverButton(in view: TerminalMetalView) -> NSButton? {
    view.subviews.compactMap { $0 as? NSButton }.first {
        $0.identifier?.rawValue == "ink.command-hover"
    }
}

@MainActor
private func hoverEvent(
    in window: NSWindow,
    view: TerminalMetalView,
    absoluteLine: Int,
    modifiers: NSEvent.ModifierFlags = [],
    column: Int = 0
) throws -> NSEvent {
    let terminal = try #require(view.terminalProvider?())
    let visualRow = absoluteLine - terminal.scrollback.count
    let oneRow = view.minimumViewportSize(columns: 10, rows: 1).height
    let twoRows = view.minimumViewportSize(columns: 10, rows: 2).height
    let cellHeight = twoRows - oneRow
    let oneColumn = view.minimumViewportSize(columns: 1, rows: 10).width
    let twoColumns = view.minimumViewportSize(columns: 2, rows: 10).width
    let cellWidth = twoColumns - oneColumn
    let x = (oneColumn - cellWidth) / 2
        + CGFloat(column) * cellWidth
        + cellWidth / 2
    let yFromTop = (oneRow - cellHeight) / 2
        + CGFloat(visualRow) * cellHeight
        + cellHeight / 2
    return try #require(NSEvent.mouseEvent(
        with: .mouseMoved,
        location: NSPoint(x: x, y: view.bounds.height - yFromTop),
        modifierFlags: modifiers,
        timestamp: 0,
        windowNumber: window.windowNumber,
        context: nil,
        eventNumber: 1,
        clickCount: 0,
        pressure: 0
    ))
}

@MainActor
private func mouseDownEvent(
    in window: NSWindow,
    matching hover: NSEvent
) throws -> NSEvent {
    try #require(NSEvent.mouseEvent(
        with: .leftMouseDown,
        location: hover.locationInWindow,
        modifierFlags: hover.modifierFlags,
        timestamp: 0,
        windowNumber: window.windowNumber,
        context: nil,
        eventNumber: 2,
        clickCount: 1,
        pressure: 0
    ))
}

@MainActor
private func scrollEvent() throws -> NSEvent {
    let event = CGEvent(
        scrollWheelEvent2Source: nil,
        units: .pixel,
        wheelCount: 1,
        wheel1: 24,
        wheel2: 0,
        wheel3: 0
    )
    return try #require(event.flatMap(NSEvent.init(cgEvent:)))
}

private func makeCommandHoverTerminal(mouseReporting: Bool = false) -> Terminal {
    var terminal = Terminal(size: .init(columns: 40, rows: 10), scrollbackCapacity: 30)
    var parser = Parser()
    let mouseMode = mouseReporting ? "\u{1B}[?1000h" : ""
    parser.feed(Array((
        mouseMode
            + commandHoverSequence("first", output: "one")
            + commandHoverSequence("second", output: "two")
            + commandHoverSequence("third", output: "three")
    ).utf8), handler: &terminal)
    return terminal
}

private func commandHoverSequence(_ command: String, output: String) -> String {
    "\u{1B}]133;A\u{07}$ \u{1B}]133;B\u{07}\(command)\r\n"
        + "\u{1B}]133;C\u{07}\(output)\r\n"
        + "\u{1B}]133;D;0\u{07}"
}
