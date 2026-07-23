import AppKit
import Foundation
import Testing
import TerminalCore
@testable import InkTerminalView

@Suite("终端文本选择越界滚动")
@MainActor
struct TerminalSelectionAutoscrollTests {
    @Test("下边缘外持续选择较新内容")
    func scrollsTowardLatest() throws {
        let terminal = makeScrollableTerminal()
        let (window, view) = makeSelectionWindow(terminal: { terminal })
        view.revealSearchResult(match(at: 2))
        let before = view.searchScrollOffset
        #expect(before > 0)
        view.mouseDown(with: try mouseEvent(.leftMouseDown, in: window, y: 80))
        view.mouseDragged(with: try mouseEvent(
            .leftMouseDragged, in: window, y: view.bounds.maxY + 40
        ))
        runLoop(for: 0.25)
        #expect(view.searchScrollOffset < before)
        let range = try #require(view.searchSelection(in: terminal))
        #expect(range.normalized.end.line > range.normalized.start.line)
    }

    @Test("上边缘外持续选择历史内容")
    func scrollsTowardHistory() throws {
        let terminal = makeScrollableTerminal()
        let (window, view) = makeSelectionWindow(terminal: { terminal })
        view.mouseDown(with: try mouseEvent(.leftMouseDown, in: window, y: 80))
        view.mouseDragged(with: try mouseEvent(.leftMouseDragged, in: window, y: -40))
        runLoop(for: 0.25)
        #expect(view.searchScrollOffset > 0)
    }

    @Test("Option 越界拖拽保持块选择")
    func preservesBlockSelection() throws {
        let terminal = makeScrollableTerminal()
        let (window, view) = makeSelectionWindow(terminal: { terminal })
        view.mouseDown(with: try mouseEvent(
            .leftMouseDown, in: window, y: 80, modifiers: [.option]
        ))
        view.mouseDragged(with: try mouseEvent(
            .leftMouseDragged, in: window, y: -40, modifiers: [.option]
        ))
        runLoop(for: 0.25)
        #expect(view.searchSelection(in: terminal)?.block == true)
    }

    @Test("指针回到网格后停止")
    func returningInsideStops() throws {
        let terminal = makeScrollableTerminal()
        let (window, view) = makeSelectionWindow(terminal: { terminal })
        view.mouseDown(with: try mouseEvent(.leftMouseDown, in: window, y: 80))
        view.mouseDragged(with: try mouseEvent(.leftMouseDragged, in: window, y: -40))
        runLoop(for: 0.2)
        view.mouseDragged(with: try mouseEvent(.leftMouseDragged, in: window, y: 80))
        let stoppedOffset = view.searchScrollOffset
        runLoop(for: 0.2)
        #expect(view.searchScrollOffset == stoppedOffset)
    }

    @Test("松开鼠标后停止")
    func mouseUpStops() throws {
        let terminal = makeScrollableTerminal()
        let (window, view) = makeSelectionWindow(terminal: { terminal })
        view.mouseDown(with: try mouseEvent(.leftMouseDown, in: window, y: 80))
        view.mouseDragged(with: try mouseEvent(.leftMouseDragged, in: window, y: -40))
        runLoop(for: 0.2)
        view.mouseUp(with: try mouseEvent(.leftMouseUp, in: window, y: -40))
        let stoppedOffset = view.searchScrollOffset
        runLoop(for: 0.2)
        #expect(view.searchScrollOffset == stoppedOffset)
    }

    @Test("重置、清历史和窗口解绑后停止")
    func invalidationStops() throws {
        let terminal = makeScrollableTerminal()
        let (window, view) = makeSelectionWindow(terminal: { terminal })
        func start() throws {
            view.mouseDown(with: try mouseEvent(.leftMouseDown, in: window, y: 80))
            view.mouseDragged(with: try mouseEvent(.leftMouseDragged, in: window, y: -40))
        }
        try start()
        view.resetTransientState()
        runLoop(for: 0.2)
        #expect(view.searchScrollOffset == 0)
        try start()
        view.scrollbackDidClear()
        runLoop(for: 0.2)
        #expect(view.searchScrollOffset == 0)
        try start()
        window.contentView = NSView()
        runLoop(for: 0.2)
        #expect(view.searchScrollOffset == 0)
    }

    @Test("上下方向都钳在 scrollback 边界")
    func clampsAtBothBoundaries() throws {
        let terminal = makeScrollableTerminal()
        let (window, view) = makeSelectionWindow(terminal: { terminal })
        view.mouseDown(with: try mouseEvent(.leftMouseDown, in: window, y: 80))
        view.mouseDragged(with: try mouseEvent(.leftMouseDragged, in: window, y: -1_000))
        runLoop(for: 0.5)
        #expect(view.searchScrollOffset == terminal.scrollback.count)

        view.mouseUp(with: try mouseEvent(.leftMouseUp, in: window, y: -1_000))
        view.mouseDown(with: try mouseEvent(.leftMouseDown, in: window, y: 80))
        view.mouseDragged(with: try mouseEvent(
            .leftMouseDragged, in: window, y: view.bounds.maxY + 1_000
        ))
        runLoop(for: 0.5)
        #expect(view.searchScrollOffset == 0)
    }

    @Test("TUI 普通拖拽优先而 Option 允许本地选择")
    func mouseReportingPriority() throws {
        let terminal = makeScrollableTerminal(mouseReporting: true)
        let (window, view) = makeSelectionWindow(terminal: { terminal })
        var input = Data()
        view.onInput = { input.append($0) }
        view.mouseDown(with: try mouseEvent(.leftMouseDown, in: window, y: 80))
        view.mouseDragged(with: try mouseEvent(.leftMouseDragged, in: window, y: -40))
        runLoop(for: 0.2)
        #expect(!input.isEmpty)
        #expect(view.searchScrollOffset == 0)
        input.removeAll()
        view.mouseDown(with: try mouseEvent(
            .leftMouseDown, in: window, y: 80, modifiers: [.option]
        ))
        view.mouseDragged(with: try mouseEvent(
            .leftMouseDragged, in: window, y: -40, modifiers: [.option]
        ))
        runLoop(for: 0.2)
        #expect(input.isEmpty)
        #expect(view.searchScrollOffset > 0)
        #expect(view.searchSelection(in: terminal)?.block == true)
    }
}

@MainActor
private func makeSelectionWindow(
    terminal: @escaping () -> Terminal
) -> (NSWindow, TerminalMetalView) {
    let window = NSWindow(
        contentRect: NSRect(x: 0, y: 0, width: 480, height: 160),
        styleMask: [.titled], backing: .buffered, defer: false
    )
    let view = TerminalMetalView(frame: window.contentView!.bounds)
    view.terminalProvider = terminal
    window.contentView = view
    view.layoutSubtreeIfNeeded()
    return (window, view)
}

private func makeScrollableTerminal(
    mouseReporting: Bool = false
) -> Terminal {
    var terminal = Terminal(
        size: TerminalSize(columns: 20, rows: 4),
        scrollbackCapacity: 40
    )
    var parser = Parser()
    let mode = mouseReporting ? "\u{1B}[?1000h" : ""
    let lines = (0..<16).map { String(format: "%02d row", $0) }
        .joined(separator: "\r\n")
    parser.feed(Array((mode + lines).utf8), handler: &terminal)
    return terminal
}

private func match(at line: Int) -> TerminalSearchMatch {
    TerminalSearchMatch(range: SelectionRange(
        start: TextPosition(line: line, column: 0),
        end: TextPosition(line: line, column: 1)
    ))
}

@MainActor
private func mouseEvent(
    _ type: NSEvent.EventType,
    in window: NSWindow,
    y: CGFloat,
    modifiers: NSEvent.ModifierFlags = []
) throws -> NSEvent {
    let view = try #require(window.contentView)
    let point = view.convert(NSPoint(x: 24, y: y), to: nil)
    return try #require(NSEvent.mouseEvent(
        with: type,
        location: point,
        modifierFlags: modifiers,
        timestamp: 0,
        windowNumber: window.windowNumber,
        context: nil,
        eventNumber: 1,
        clickCount: 1,
        pressure: 0
    ))
}

@MainActor
private func runLoop(for interval: TimeInterval) {
    RunLoop.main.run(until: Date(timeIntervalSinceNow: interval))
}
