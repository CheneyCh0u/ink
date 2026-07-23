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
        #expect(waitUntil { view.searchScrollOffset < before })
        let range = try #require(view.searchSelection(in: terminal))
        #expect(range.normalized.end.line > range.normalized.start.line)
    }

    @Test("上边缘外持续选择历史内容")
    func scrollsTowardHistory() throws {
        let terminal = makeScrollableTerminal()
        let (window, view) = makeSelectionWindow(terminal: { terminal })
        view.mouseDown(with: try mouseEvent(.leftMouseDown, in: window, y: 80))
        view.mouseDragged(with: try mouseEvent(.leftMouseDragged, in: window, y: -40))
        #expect(waitUntil { view.searchScrollOffset > 0 })
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
        #expect(waitUntil {
            view.searchScrollOffset > 0
                && view.searchSelection(in: terminal)?.block == true
        })
    }

    @Test("指针回到网格后停止")
    func returningInsideStops() throws {
        let terminal = makeScrollableTerminal()
        let (window, view) = makeSelectionWindow(terminal: { terminal })
        view.mouseDown(with: try mouseEvent(.leftMouseDown, in: window, y: 80))
        view.mouseDragged(with: try mouseEvent(.leftMouseDragged, in: window, y: -40))
        #expect(waitUntil { view.searchScrollOffset > 0 })
        view.mouseDragged(with: try mouseEvent(.leftMouseDragged, in: window, y: 80))
        let stoppedOffset = view.searchScrollOffset
        #expect(scrollOffsetRemainsStable(in: view, at: stoppedOffset))
    }

    @Test("松开鼠标后停止")
    func mouseUpStops() throws {
        let terminal = makeScrollableTerminal()
        let (window, view) = makeSelectionWindow(terminal: { terminal })
        view.mouseDown(with: try mouseEvent(.leftMouseDown, in: window, y: 80))
        view.mouseDragged(with: try mouseEvent(.leftMouseDragged, in: window, y: -40))
        #expect(waitUntil { view.searchScrollOffset > 0 })
        view.mouseUp(with: try mouseEvent(.leftMouseUp, in: window, y: -40))
        let stoppedOffset = view.searchScrollOffset
        #expect(scrollOffsetRemainsStable(in: view, at: stoppedOffset))
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
        #expect(waitUntil { view.searchScrollOffset > 0 })
        view.resetTransientState()
        #expect(scrollOffsetRemainsStable(in: view, at: 0))
        try start()
        #expect(waitUntil { view.searchScrollOffset > 0 })
        view.scrollbackDidClear()
        #expect(scrollOffsetRemainsStable(in: view, at: 0))
        try start()
        #expect(waitUntil { view.searchScrollOffset > 0 })
        window.contentView = NSView()
        let detachedOffset = view.searchScrollOffset
        #expect(scrollOffsetRemainsStable(in: view, at: detachedOffset))
    }

    @Test("上下方向都钳在 scrollback 边界")
    func clampsAtBothBoundaries() throws {
        let terminal = makeScrollableTerminal()
        let (window, view) = makeSelectionWindow(terminal: { terminal })
        view.mouseDown(with: try mouseEvent(.leftMouseDown, in: window, y: 80))
        view.mouseDragged(with: try mouseEvent(.leftMouseDragged, in: window, y: -1_000))
        #expect(waitUntil(timeout: 1) {
            view.searchScrollOffset == terminal.scrollback.count
        })

        view.mouseUp(with: try mouseEvent(.leftMouseUp, in: window, y: -1_000))
        view.mouseDown(with: try mouseEvent(.leftMouseDown, in: window, y: 80))
        view.mouseDragged(with: try mouseEvent(
            .leftMouseDragged, in: window, y: view.bounds.maxY + 1_000
        ))
        #expect(waitUntil(timeout: 1) { view.searchScrollOffset == 0 })
    }

    @Test("TUI 普通拖拽优先而 Option 允许本地选择")
    func mouseReportingPriority() throws {
        let terminal = makeScrollableTerminal(mouseReporting: true)
        let (window, view) = makeSelectionWindow(terminal: { terminal })
        var input = Data()
        view.onInput = { input.append($0) }
        view.mouseDown(with: try mouseEvent(.leftMouseDown, in: window, y: 80))
        view.mouseDragged(with: try mouseEvent(.leftMouseDragged, in: window, y: -40))
        #expect(!input.isEmpty)
        #expect(view.searchScrollOffset == 0)
        input.removeAll()
        view.mouseDown(with: try mouseEvent(
            .leftMouseDown, in: window, y: 80, modifiers: [.option]
        ))
        view.mouseDragged(with: try mouseEvent(
            .leftMouseDragged, in: window, y: -40, modifiers: [.option]
        ))
        #expect(input.isEmpty)
        #expect(waitUntil {
            view.searchScrollOffset > 0
                && view.searchSelection(in: terminal)?.block == true
        })
    }

    @Test("历史环淘汰后存活锚点按稳定身份平移")
    func survivingAnchorRebasesAfterEviction() throws {
        var terminal = makeScrollableTerminal(scrollbackCapacity: 2)
        var parser = Parser()
        let (window, view) = makeSelectionWindow(terminal: { terminal })
        view.mouseDown(with: try mouseEvent(.leftMouseDown, in: window, y: 80))
        let drag = try mouseEvent(.leftMouseDragged, in: window, y: -40)
        view.mouseDragged(with: drag)
        let original = try #require(view.searchSelection(in: terminal))
        #expect(original.start.line > 0)

        parser.feed(Array("\r\nnext".utf8), handler: &terminal)
        view.mouseDragged(with: drag)

        let rebased = try #require(view.searchSelection(in: terminal))
        #expect(rebased.start.line == original.start.line - 1)
    }

    @Test("历史环淘汰锚点后计时器清除拖拽选择")
    func evictedAnchorInvalidatesAutoscroll() throws {
        var terminal = makeScrollableTerminal(scrollbackCapacity: 2)
        var parser = Parser()
        let (window, view) = makeSelectionWindow(terminal: { terminal })
        view.revealSearchResult(match(at: 0))
        view.mouseDown(with: try mouseEvent(.leftMouseDown, in: window, y: 8))
        view.mouseDragged(with: try mouseEvent(
            .leftMouseDragged, in: window, y: view.bounds.maxY + 40
        ))
        #expect(view.searchSelection(in: terminal)?.start.line == 0)

        parser.feed(Array("\r\nnext".utf8), handler: &terminal)
        let invalidatedOffset = view.searchScrollOffset

        #expect(autoscrollRemainsInvalidated(
            in: view,
            terminal: terminal,
            at: invalidatedOffset
        ))
    }

    @Test("键盘清选区后计时器不会恢复滚动")
    func keyDownStopsAutoscroll() throws {
        let terminal = makeScrollableTerminal()
        let (window, view) = makeSelectionWindow(terminal: { terminal })
        view.mouseDown(with: try mouseEvent(.leftMouseDown, in: window, y: 80))
        view.mouseDragged(with: try mouseEvent(.leftMouseDragged, in: window, y: -40))
        #expect(waitUntil { view.searchScrollOffset > 0 })

        view.keyDown(with: try keyEvent(in: window))

        #expect(autoscrollRemainsInvalidated(in: view, terminal: terminal, at: 0))
    }

    @Test("命令导航清选区后计时器不会恢复选择")
    func commandNavigationStopsAutoscroll() throws {
        let terminal = makeScrollableCommandTerminal()
        let (window, view) = makeSelectionWindow(terminal: { terminal })
        view.revealSearchResult(match(at: 0))
        let before = view.searchScrollOffset
        view.mouseDown(with: try mouseEvent(.leftMouseDown, in: window, y: 80))
        view.mouseDragged(with: try mouseEvent(
            .leftMouseDragged, in: window, y: view.bounds.maxY + 40
        ))
        #expect(waitUntil { view.searchScrollOffset < before })

        #expect(view.navigateToPreviousCommand())
        let navigatedOffset = view.searchScrollOffset

        #expect(autoscrollRemainsInvalidated(
            in: view,
            terminal: terminal,
            at: navigatedOffset
        ))
    }

    @Test("网格扩展包住静止指针后计时器立即失效")
    func gridExpansionStopsAutoscroll() throws {
        let terminal = makeScrollableTerminal(rows: 20, lineCount: 50)
        let (window, view) = makeSelectionWindow(terminal: { terminal }, height: 80)
        view.revealSearchResult(match(at: 0))
        let before = view.searchScrollOffset
        view.mouseDown(with: try mouseEvent(.leftMouseDown, in: window, y: 40))
        view.mouseDragged(with: try mouseEvent(.leftMouseDragged, in: window, y: 100))
        #expect(waitUntil { view.searchScrollOffset < before })

        view.setFrameSize(NSSize(width: view.frame.width, height: 400))
        view.layoutSubtreeIfNeeded()
        let expandedOffset = view.searchScrollOffset
        #expect(scrollOffsetRemainsStable(in: view, at: expandedOffset))

        view.setFrameSize(NSSize(width: view.frame.width, height: 80))
        view.layoutSubtreeIfNeeded()
        #expect(scrollOffsetRemainsStable(in: view, at: expandedOffset))
    }
}

@MainActor
private func makeSelectionWindow(
    terminal: @escaping () -> Terminal,
    height: CGFloat = 160
) -> (NSWindow, TerminalMetalView) {
    let window = NSWindow(
        contentRect: NSRect(x: 0, y: 0, width: 480, height: height),
        styleMask: [.titled], backing: .buffered, defer: false
    )
    let view = TerminalMetalView(frame: window.contentView!.bounds)
    view.terminalProvider = terminal
    window.contentView = view
    view.layoutSubtreeIfNeeded()
    return (window, view)
}

private func makeScrollableTerminal(
    mouseReporting: Bool = false,
    rows: Int = 4,
    scrollbackCapacity: Int = 40,
    lineCount: Int = 16
) -> Terminal {
    var terminal = Terminal(
        size: TerminalSize(columns: 20, rows: rows),
        scrollbackCapacity: scrollbackCapacity
    )
    var parser = Parser()
    let mode = mouseReporting ? "\u{1B}[?1000h" : ""
    let lines = (0..<lineCount).map { String(format: "%02d row", $0) }
        .joined(separator: "\r\n")
    parser.feed(Array((mode + lines).utf8), handler: &terminal)
    return terminal
}

private func makeScrollableCommandTerminal() -> Terminal {
    var terminal = Terminal(
        size: TerminalSize(columns: 20, rows: 4),
        scrollbackCapacity: 40
    )
    var parser = Parser()
    let text = command("first", output: "one")
        + command("second", output: "two")
        + (0..<8).map { "filler \($0)" }.joined(separator: "\r\n")
    parser.feed(Array(text.utf8), handler: &terminal)
    return terminal
}

private func command(_ command: String, output: String) -> String {
    "\u{1B}]133;A\u{07}$ \u{1B}]133;B\u{07}\(command)\r\n"
        + "\u{1B}]133;C\u{07}\(output)\r\n"
        + "\u{1B}]133;D;0\u{07}"
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
private func keyEvent(in window: NSWindow) throws -> NSEvent {
    try #require(NSEvent.keyEvent(
        with: .keyDown,
        location: .zero,
        modifierFlags: [.control],
        timestamp: 0,
        windowNumber: window.windowNumber,
        context: nil,
        characters: "c",
        charactersIgnoringModifiers: "c",
        isARepeat: false,
        keyCode: 8
    ))
}

@MainActor
private func waitUntil(
    timeout: TimeInterval = 0.75,
    condition: () -> Bool
) -> Bool {
    let deadline = Date(timeIntervalSinceNow: timeout)
    while !condition(), Date() < deadline {
        RunLoop.main.run(until: min(deadline, Date(timeIntervalSinceNow: 0.01)))
    }
    return condition()
}

/// “没有继续滚动”只能通过一段保守观察窗证明，正向状态变化统一使用 waitUntil。
@MainActor
private func scrollOffsetRemainsStable(
    in view: TerminalMetalView,
    at expectedOffset: Int,
    observation: TimeInterval = 0.15
) -> Bool {
    RunLoop.main.run(until: Date(timeIntervalSinceNow: observation))
    return view.searchScrollOffset == expectedOffset
}

/// 同时观察视口与选区，防止失效的 Timer 在下一 tick 复活拖拽状态。
@MainActor
private func autoscrollRemainsInvalidated(
    in view: TerminalMetalView,
    terminal: Terminal,
    at expectedOffset: Int,
    observation: TimeInterval = 0.15
) -> Bool {
    RunLoop.main.run(until: Date(timeIntervalSinceNow: observation))
    return view.searchScrollOffset == expectedOffset
        && view.searchSelection(in: terminal) == nil
}
