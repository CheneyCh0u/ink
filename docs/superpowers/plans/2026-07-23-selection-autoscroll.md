# Text Selection Autoscroll Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** 让本地文本选择越过终端可见网格上下边缘后持续滚动，并让选区端点跟随新视口扩展。

**Architecture:** `SelectionAutoscrollState` 是纯值类型，只计算方向、距离加速和行数累积。`TerminalMetalView` 在本地拖拽越界期间启动主线程短生命周期计时器，每个 tick 更新 `scrollOffset` 后重新计算选区端点；所有结束、重置和窗口解绑路径共用清理方法。

**Tech Stack:** Swift 6、AppKit、QuartzCore、Swift Testing、SwiftPM，最低系统 macOS 14.0。

## Global Constraints

- `TerminalCore` 不得引入 AppKit 或 Metal 依赖。
- 不修改 cell、line、scrollback 存储或 renderer instance，不增加 per-cell 或 per-line 常驻开销。
- 不把自动滚动判断放进 `CADisplayLink` 或 Metal 渲染热路径。
- TUI 鼠标上报优先；按住 Option 时继续强制本地块选择。
- 计时器只在本地拖拽越界期间存在，回到网格、松开、重置或窗口解绑后必须失效。
- 注释和文档用中文，代码标识符用英文；不新增第三方依赖。
- Issue 为 `#89`，提交正文使用 `Refs #89`，不创建版本标签或发布。

---

## 文件结构

- 新建 `Sources/InkTerminalView/SelectionAutoscroll.swift`：纯值速度模型和小数行累积。
- 新建 `Tests/InkTerminalViewTests/SelectionAutoscrollTests.swift`：验证方向、速度、封顶和累积。
- 修改 `Sources/InkTerminalView/TerminalMetalView.swift`：管理拖拽瞬态、Timer、视口和选区。
- 新建 `Tests/InkTerminalViewTests/TerminalSelectionAutoscrollTests.swift`：验证窗口事件、生命周期和路由。

### Task 1: 实现纯值滚动节奏

**Files:**
- Create: `Sources/InkTerminalView/SelectionAutoscroll.swift`
- Create: `Tests/InkTerminalViewTests/SelectionAutoscrollTests.swift`

**Interfaces:**
- Consumes: 指针纵坐标、网格上下边界、cell 高度和经过时间。
- Produces: `SelectionAutoscrollState.rowsToScroll(pointerY:gridTop:gridBottom:cellHeight:elapsed:) -> Int`、`direction(...)` 和 `reset()`。

- [ ] **Step 1: 写失败测试**

创建 `Tests/InkTerminalViewTests/SelectionAutoscrollTests.swift`，覆盖以下完整输入输出：

```swift
import CoreGraphics
import Testing
@testable import InkTerminalView

@Suite("选择越界滚动节奏")
struct SelectionAutoscrollTests {
    @Test("网格内不滚动且清除旧余量")
    func insideGridStops() {
        var state = SelectionAutoscrollState()
        _ = state.rowsToScroll(
            pointerY: -10, gridTop: 0, gridBottom: 100,
            cellHeight: 20, elapsed: 0.1
        )
        #expect(state.rowsToScroll(
            pointerY: 50, gridTop: 0, gridBottom: 100,
            cellHeight: 20, elapsed: 1
        ) == 0)
        #expect(state.rowsToScroll(
            pointerY: -1, gridTop: 0, gridBottom: 100,
            cellHeight: 20, elapsed: 0.01
        ) == 0)
    }

    @Test("上下越界产生相反方向")
    func directions() {
        var upward = SelectionAutoscrollState()
        var downward = SelectionAutoscrollState()
        #expect(upward.rowsToScroll(
            pointerY: -20, gridTop: 0, gridBottom: 100,
            cellHeight: 20, elapsed: 0.1
        ) > 0)
        #expect(downward.rowsToScroll(
            pointerY: 120, gridTop: 0, gridBottom: 100,
            cellHeight: 20, elapsed: 0.1
        ) < 0)
    }

    @Test("越界越远越快且长间隔单次最多四行")
    func acceleratesAndCaps() {
        var near = SelectionAutoscrollState()
        var far = SelectionAutoscrollState()
        let nearRows = near.rowsToScroll(
            pointerY: -1, gridTop: 0, gridBottom: 100,
            cellHeight: 20, elapsed: 0.2
        )
        let farRows = far.rowsToScroll(
            pointerY: -1_000, gridTop: 0, gridBottom: 100,
            cellHeight: 20, elapsed: 1
        )
        #expect(nearRows == 1)
        #expect(farRows == 4)
    }

    @Test("小数行跨 tick 累积且换向时清除")
    func accumulatesAndResetsDirection() {
        var state = SelectionAutoscrollState()
        #expect(state.rowsToScroll(
            pointerY: -1, gridTop: 0, gridBottom: 100,
            cellHeight: 20, elapsed: 0.05
        ) == 0)
        #expect(state.rowsToScroll(
            pointerY: -1, gridTop: 0, gridBottom: 100,
            cellHeight: 20, elapsed: 0.08
        ) == 1)
        #expect(state.rowsToScroll(
            pointerY: 101, gridTop: 0, gridBottom: 100,
            cellHeight: 20, elapsed: 0.03
        ) == 0)
    }
}
```

- [ ] **Step 2: 运行测试并确认 RED**

Run: `swift test --filter SelectionAutoscrollTests`

Expected: 编译失败，提示找不到 `SelectionAutoscrollState`。

- [ ] **Step 3: 写最小实现**

创建 `Sources/InkTerminalView/SelectionAutoscroll.swift`：

```swift
import CoreGraphics
import Foundation

enum SelectionAutoscrollDirection: Int {
    case towardHistory = 1
    case towardLatest = -1
}

struct SelectionAutoscrollState {
    private static let baseRowsPerSecond: CGFloat = 8
    private static let addedRowsPerCell: CGFloat = 4
    private static let maximumRowsPerSecond: CGFloat = 40
    private static let maximumRowsPerTick: CGFloat = 4
    private var remainder: CGFloat = 0
    private var direction: SelectionAutoscrollDirection?

    static func direction(
        pointerY: CGFloat,
        gridTop: CGFloat,
        gridBottom: CGFloat
    ) -> SelectionAutoscrollDirection? {
        if pointerY < gridTop { return .towardHistory }
        if pointerY >= gridBottom { return .towardLatest }
        return nil
    }

    mutating func rowsToScroll(
        pointerY: CGFloat,
        gridTop: CGFloat,
        gridBottom: CGFloat,
        cellHeight: CGFloat,
        elapsed: TimeInterval
    ) -> Int {
        guard cellHeight > 0,
              elapsed > 0,
              let nextDirection = Self.direction(
                  pointerY: pointerY,
                  gridTop: gridTop,
                  gridBottom: gridBottom
              )
        else {
            reset()
            return 0
        }
        if direction != nextDirection {
            remainder = 0
            direction = nextDirection
        }
        let overflow = nextDirection == .towardHistory
            ? gridTop - pointerY
            : pointerY - gridBottom
        let rowsPerSecond = min(
            Self.maximumRowsPerSecond,
            Self.baseRowsPerSecond
                + overflow / cellHeight * Self.addedRowsPerCell
        )
        let magnitude = min(
            Self.maximumRowsPerTick,
            rowsPerSecond * CGFloat(elapsed)
        )
        remainder += CGFloat(nextDirection.rawValue) * magnitude
        let rows = Int(remainder)
        remainder -= CGFloat(rows)
        return rows
    }

    mutating func reset() {
        remainder = 0
        direction = nil
    }
}
```

- [ ] **Step 4: 运行测试并确认 GREEN**

Run: `swift test --filter SelectionAutoscrollTests`

Expected: 4 tests passed。

- [ ] **Step 5: 提交**

```bash
git add Sources/InkTerminalView/SelectionAutoscroll.swift Tests/InkTerminalViewTests/SelectionAutoscrollTests.swift
git commit -m "feat(terminal): 定义选择越界滚动节奏" -m "用纯值状态计算方向、距离加速和行数累积，避免把速度策略耦合进视图与渲染循环。

Refs #89"
```

### Task 2: 接通本地拖拽、计时器和生命周期

**Files:**
- Modify: `Sources/InkTerminalView/TerminalMetalView.swift:184-188, 258-284, 480-500, 693-727, 941-995`
- Create: `Tests/InkTerminalViewTests/TerminalSelectionAutoscrollTests.swift`

**Interfaces:**
- Consumes: Task 1 的 `SelectionAutoscrollState`，以及现有 `hitPosition`、`updateSelection` 和 `scrollOffset`。
- Produces: `advanceSelectionAutoscroll(by:)`、`selectionAutoscrollActiveForTesting`、`selectionRangeForTesting` 和真实 Timer 驱动。

- [ ] **Step 1: 写窗口级失败测试**

创建 `Tests/InkTerminalViewTests/TerminalSelectionAutoscrollTests.swift`。夹具使用 4 行视口和 16 行编号文本，并先用 `view.convert(NSPoint(x: 24, y: y), to: nil)` 把 flipped view 坐标转换成窗口坐标。测试体如下：

```swift
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
    #expect(view.selectionAutoscrollActiveForTesting)
    view.advanceSelectionAutoscroll(by: 0.25)
    #expect(view.searchScrollOffset < before)
    #expect(view.selectionRangeForTesting?.normalized.end.line > 2)
}

@Test("上边缘外持续选择历史内容")
func scrollsTowardHistory() throws {
    let terminal = makeScrollableTerminal()
    let (window, view) = makeSelectionWindow(terminal: { terminal })
    view.mouseDown(with: try mouseEvent(.leftMouseDown, in: window, y: 80))
    view.mouseDragged(with: try mouseEvent(.leftMouseDragged, in: window, y: -40))
    view.advanceSelectionAutoscroll(by: 0.25)
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
    view.advanceSelectionAutoscroll(by: 0.25)
    #expect(view.selectionRangeForTesting?.block == true)
}

@Test("结束和失效路径销毁计时器")
func lifecycleStops() throws {
    let terminal = makeScrollableTerminal()
    let (window, view) = makeSelectionWindow(terminal: { terminal })
    func start() throws {
        view.mouseDown(with: try mouseEvent(.leftMouseDown, in: window, y: 80))
        view.mouseDragged(with: try mouseEvent(.leftMouseDragged, in: window, y: -40))
        #expect(view.selectionAutoscrollActiveForTesting)
    }
    try start()
    view.resetTransientState()
    #expect(!view.selectionAutoscrollActiveForTesting)
    try start()
    view.scrollbackDidClear()
    #expect(!view.selectionAutoscrollActiveForTesting)
    try start()
    view.mouseUp(with: try mouseEvent(.leftMouseUp, in: window, y: -40))
    #expect(!view.selectionAutoscrollActiveForTesting)
    try start()
    window.contentView = NSView()
    #expect(!view.selectionAutoscrollActiveForTesting)
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
    #expect(!view.selectionAutoscrollActiveForTesting)
    input.removeAll()
    view.mouseDown(with: try mouseEvent(
        .leftMouseDown, in: window, y: 80, modifiers: [.option]
    ))
    view.mouseDragged(with: try mouseEvent(
        .leftMouseDragged, in: window, y: -40, modifiers: [.option]
    ))
    #expect(input.isEmpty)
    #expect(view.selectionAutoscrollActiveForTesting)
}

@Test("真实计时器在指针不动时继续推进")
func timerContinuesWhileStationary() throws {
    let terminal = makeScrollableTerminal()
    let (window, view) = makeSelectionWindow(terminal: { terminal })
    view.mouseDown(with: try mouseEvent(.leftMouseDown, in: window, y: 80))
    view.mouseDragged(with: try mouseEvent(.leftMouseDragged, in: window, y: -40))
    let before = view.searchScrollOffset
    RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.2))
    #expect(view.searchScrollOffset > before)
    view.mouseUp(with: try mouseEvent(.leftMouseUp, in: window, y: -40))
}
}
```

同一文件补齐这些夹具：

```swift
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
```

- [ ] **Step 2: 运行测试并确认 RED**

Run: `swift test --filter TerminalSelectionAutoscrollTests`

Expected: 编译失败，提示三个测试接口不存在。

- [ ] **Step 3: 实现视图状态与计时器**

在选区状态旁加入：

```swift
private var selectionDragPoint: NSPoint?
private var selectionDragIsBlock = false
private var selectionAutoscrollState = SelectionAutoscrollState()
private var selectionAutoscrollTimer: Timer?
private var selectionAutoscrollLastTime: CFTimeInterval?

var selectionAutoscrollActiveForTesting: Bool {
    selectionAutoscrollTimer?.isValid == true
}
var selectionRangeForTesting: SelectionRange? { selection }
```

新增以下驱动。网格边界为 `Spacing.sm...min(bounds.maxY, Spacing.sm + rows * cellHeight)`：

```swift
private func startSelectionAutoscroll() {
    guard selectionAutoscrollTimer == nil else { return }
    selectionAutoscrollState.reset()
    selectionAutoscrollLastTime = CACurrentMediaTime()
    let timer = Timer(
        timeInterval: 1.0 / 60.0,
        target: self,
        selector: #selector(selectionAutoscrollTimerFired(_:)),
        userInfo: nil,
        repeats: true
    )
    RunLoop.main.add(timer, forMode: .common)
    selectionAutoscrollTimer = timer
}

private func stopSelectionAutoscroll(clearDragState: Bool) {
    selectionAutoscrollTimer?.invalidate()
    selectionAutoscrollTimer = nil
    selectionAutoscrollLastTime = nil
    selectionAutoscrollState.reset()
    if clearDragState {
        selectionDragPoint = nil
        selectionDragIsBlock = false
    }
}

@objc private func selectionAutoscrollTimerFired(_ timer: Timer) {
    let now = CACurrentMediaTime()
    let elapsed = now - (selectionAutoscrollLastTime ?? now)
    selectionAutoscrollLastTime = now
    advanceSelectionAutoscroll(by: elapsed)
}

func advanceSelectionAutoscroll(by elapsed: TimeInterval) {
    guard let anchor = selectionAnchor,
          let point = selectionDragPoint,
          let renderer,
          let terminal = terminalProvider?()
    else {
        stopSelectionAutoscroll(clearDragState: true)
        return
    }
    let top = InkDesignTokens.Spacing.sm
    let bottom = min(
        bounds.maxY,
        top + CGFloat(terminal.grid.size.rows) * renderer.cellSizePoints.height
    )
    let delta = selectionAutoscrollState.rowsToScroll(
        pointerY: point.y, gridTop: top, gridBottom: max(top, bottom),
        cellHeight: renderer.cellSizePoints.height, elapsed: elapsed
    )
    guard delta != 0 else { return }
    let oldOffset = scrollOffset
    scrollOffset = max(0, min(oldOffset + delta, terminal.scrollback.count))
    guard scrollOffset != oldOffset else {
        stopSelectionAutoscroll(clearDragState: false)
        return
    }
    guard let position = hitPosition(
        at: point, terminal: terminal, renderer: renderer
    ) else { return }
    updateSelection(SelectionRange(
        start: anchor, end: position, block: selectionDragIsBlock
    ), in: terminal)
    commandNavigationAnchor = nil
    markDirty()
}
```

- [ ] **Step 4: 接通鼠标与失效路径**

用下面的方法替换现有三个左键方法：

```swift
public override func mouseDown(with event: NSEvent) {
    hideCommandHover()
    stopSelectionAutoscroll(clearDragState: true)
    window?.makeFirstResponder(self)
    if event.modifierFlags.contains(.command),
       let link = link(at: event),
       let url = TerminalLinkMenuPayload(target: link.target).url,
       let onOpenLink {
        onOpenLink(url)
        return
    }
    if reportMouse(event, action: .press, button: 0) { return }
    guard let pos = hitPosition(event), let terminal = terminalProvider?() else { return }

    selectionAnchor = nil
    switch event.clickCount {
    case 2:
        if let cols = terminal.wordColumns(at: pos) {
            updateSelection(SelectionRange(
                start: TextPosition(line: pos.line, column: cols.lowerBound),
                end: TextPosition(line: pos.line, column: cols.upperBound)
            ), in: terminal)
        }
    case 3:
        updateSelection(SelectionRange(
            start: TextPosition(line: pos.line, column: 0),
            end: TextPosition(line: pos.line, column: terminal.grid.size.columns - 1)
        ), in: terminal)
    default:
        selectionAnchor = pos
        if selection != nil { clearSelection() }
    }
    markDirty()
}

public override func mouseDragged(with event: NSEvent) {
    hideCommandHover()
    if reportMouse(event, action: .drag, button: 0) {
        stopSelectionAutoscroll(clearDragState: true)
        return
    }
    guard let anchor = selectionAnchor,
          let renderer,
          let terminal = terminalProvider?()
    else {
        stopSelectionAutoscroll(clearDragState: true)
        return
    }
    let point = convert(event.locationInWindow, from: nil)
    let isBlock = event.modifierFlags.contains(.option)
    selectionDragPoint = point
    selectionDragIsBlock = isBlock
    guard let position = hitPosition(
        at: point, terminal: terminal, renderer: renderer
    ) else { return }
    updateSelection(SelectionRange(
        start: anchor, end: position, block: isBlock
    ), in: terminal)

    let top = InkDesignTokens.Spacing.sm
    let bottom = min(
        bounds.maxY,
        top + CGFloat(terminal.grid.size.rows) * renderer.cellSizePoints.height
    )
    if SelectionAutoscrollState.direction(
        pointerY: point.y,
        gridTop: top,
        gridBottom: max(top, bottom)
    ) == nil {
        stopSelectionAutoscroll(clearDragState: false)
    } else {
        startSelectionAutoscroll()
    }
    markDirty()
}

public override func mouseUp(with event: NSEvent) {
    stopSelectionAutoscroll(clearDragState: true)
    let reported = reportMouse(event, action: .release, button: 0)
    selectionAnchor = nil
    if reported { return }
    if copyOnSelect, selection != nil { copy(nil) }
}
```

`resetTransientState()`、`scrollbackDidClear()` 和 `viewDidMoveToWindow()` 的 `window == nil` 分支调用：

```swift
stopSelectionAutoscroll(clearDragState: true)
```

窗口解绑时同时清空 `selectionAnchor`。所有 Timer 和选择状态访问保持在 `TerminalMetalView` 的 MainActor 隔离内。

- [ ] **Step 5: 运行聚焦和视图层测试**

```bash
swift test --filter TerminalSelectionAutoscrollTests
swift test --filter InkTerminalViewTests
```

Expected: 6 个新增窗口测试和 InkTerminalView 全部测试通过，真实 Timer 用例不超时。

- [ ] **Step 6: 提交**

```bash
git add Sources/InkTerminalView/TerminalMetalView.swift Tests/InkTerminalViewTests/TerminalSelectionAutoscrollTests.swift
git commit -m "fix(terminal): 拖拽选择越界时持续滚动" -m "用短生命周期计时器推进历史视口并重算选区端点，在结束和视图失效路径统一清理，同时保留 TUI 与 Option 输入优先级。

Refs #89"
```

### Task 3: 完整验证和交付

**Files:**
- Verify: `Sources/InkTerminalView/SelectionAutoscroll.swift`
- Verify: `Sources/InkTerminalView/TerminalMetalView.swift`
- Verify: `Tests/InkTerminalViewTests/SelectionAutoscrollTests.swift`
- Verify: `Tests/InkTerminalViewTests/TerminalSelectionAutoscrollTests.swift`

**Interfaces:**
- Consumes: 前两项任务的实现和测试。
- Produces: 构建证据、原生窗口验收结果、同类风险清单和可关闭 Issue #89 的 PR。

- [ ] **Step 1: 检查同类路径**

Run: `rg -n "mouseDragged\(with|scrollOffset\s*=|Timer\(" Sources -g "*.swift"`

Expected: 自动滚动只接入 `TerminalMetalView` 的本地选择；侧边栏拖放和 divider 不接触终端 scrollback，无需纳入本 Issue。

- [ ] **Step 2: 运行全量验证**

```bash
swift test
swift build
git diff --check origin/main...HEAD
```

Expected: 全量测试通过，build 成功且零警告，diff check 无输出。

- [ ] **Step 3: 做原生窗口验收**

运行 `swift run ink`，在 Ink 中执行 `seq -w 1 300`。滚到中间后从可见文本内按下，分别把指针停在窗口上下边缘外；视口应持续滚动，选区连续扩展，移回内容区和松开后立即停止。再在开启鼠标上报的 TUI 中确认普通拖拽交给应用，Option 拖拽走本地块选择。

- [ ] **Step 4: 完成前验证与代码评审**

调用 `superpowers:verification-before-completion`，以刚运行的命令和原生窗口结果为证据；随后调用 `superpowers:requesting-code-review` 检查需求覆盖、计时器生命周期、MainActor 隔离和性能边界。发现问题时回到对应失败测试，不叠加未经验证的修补。

- [ ] **Step 5: 完成分支**

调用 `superpowers:finishing-a-development-branch`。用户选择推送和开 PR 时，推送 `agent/issue-89-selection-autoscroll`，PR 标题为 `fix(terminal): 支持拖拽选择越界自动滚动`。PR 描述列出改动、`swift test`、`swift build`、原生窗口验收、性能边界和“不涉及发布”，并只包含一个 `Closes #89`。不合并、不打 tag、不发布。
