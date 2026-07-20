# 终端分屏容器重构实施计划

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** 用轻量自定义 `NSView` 容器替换会在后续布局周期中压缩 pane 的 `NSSplitView`，恢复稳定的多 pane 展示和 divider 拖动。

**Architecture:** 新建 `WorkspaceSplitContainerView`，每次布局都从归一化权重计算直接子视图 frame，并在容器内绘制和拖动 divider。`TerminalWorkspaceViewController` 只负责递归构建视图树，并把拖动完成后的权重写回 `TerminalTab`。

**Tech Stack:** Swift 6、AppKit、Swift Testing、SwiftPM，最低 macOS 14.0。

## Global Constraints

- 不修改 `TerminalCore`、grid、scrollback 或 Metal 渲染路径。
- 不新增第三方依赖。
- 常用规模按 1 到 4 个 pane 验收，不设置固定 pane 数量上限。
- 横向子视图按从左到右排列，纵向子视图按从上到下排列。
- divider 视觉宽度为 1 pt，鼠标命中区域为 7 pt。
- 左右拖动优先保留每侧 80 pt，上下拖动优先保留每侧 48 pt。
- 自动布局和窗口缩放不写回模型权重，只有鼠标松开才提交一次。

---

### Task 1: 稳定的权重布局容器

**Files:**
- Create: `Sources/InkShell/WorkspaceSplitContainerView.swift`
- Create: `Tests/InkShellTests/WorkspaceSplitContainerViewTests.swift`

**Interfaces:**
- Consumes: `SplitID`、`PaneSplitAxis`。
- Produces: `WorkspaceSplitContainerView.init(splitID:axis:weights:)`、`addPaneSubview(_:)`、只读 `weights`。

- [ ] **Step 1: 写重复布局、权重恢复和缩放的失败测试**

```swift
@Suite("稳定分屏容器")
@MainActor
struct WorkspaceSplitContainerViewTests {
    @Test("连续布局不会把子视图压到零")
    func repeatedLayoutKeepsEveryChildVisible() {
        let container = WorkspaceSplitContainerView(
            splitID: SplitID(), axis: .topBottom,
            weights: [0.5, 0.25, 0.125, 0.0625, 0.0625]
        )
        container.frame = NSRect(x: 0, y: 0, width: 900, height: 600)
        let children = (0..<5).map { _ in NSView() }
        children.forEach(container.addPaneSubview)

        for _ in 0..<3 {
            container.needsLayout = true
            container.layoutSubtreeIfNeeded()
        }

        #expect(children.allSatisfy { $0.frame.height > 1 })
    }

    @Test("纵向布局从上到下并按权重分配")
    func verticalLayoutUsesFlippedCoordinatesAndWeights() {
        let container = WorkspaceSplitContainerView(
            splitID: SplitID(), axis: .topBottom, weights: [0.25, 0.75]
        )
        container.frame = NSRect(x: 0, y: 0, width: 800, height: 400)
        let first = NSView()
        let second = NSView()
        container.addPaneSubview(first)
        container.addPaneSubview(second)
        container.layoutSubtreeIfNeeded()

        #expect(container.isFlipped)
        #expect(first.frame.minY == 0)
        #expect(second.frame.minY > first.frame.maxY)
        #expect(second.frame.height > first.frame.height * 2.9)
    }
}
```

- [ ] **Step 2: 运行测试并确认容器类型不存在**

Run: `swift test --filter WorkspaceSplitContainerViewTests`

Expected: FAIL，提示找不到 `WorkspaceSplitContainerView`。

- [ ] **Step 3: 实现最小权重布局**

```swift
@MainActor
final class WorkspaceSplitContainerView: NSView {
    let splitID: SplitID
    let axis: PaneSplitAxis
    private(set) var weights: [Double]

    override var isFlipped: Bool { true }

    init(splitID: SplitID, axis: PaneSplitAxis, weights: [Double]) {
        self.splitID = splitID
        self.axis = axis
        self.weights = weights
        super.init(frame: .zero)
    }

    func addPaneSubview(_ view: NSView) {
        addSubview(view)
        needsLayout = true
    }

    override func layout() {
        super.layout()
        let count = subviews.count
        guard count > 0 else { return }
        let resolved = normalizedWeights(for: count)
        weights = resolved
        let available = max(0, axisLength - CGFloat(count - 1))
        var origin: CGFloat = 0
        for index in subviews.indices {
            let length = index == count - 1
                ? axisLength - origin
                : available * CGFloat(resolved[index])
            setFrame(of: subviews[index], origin: origin, length: length)
            origin += length + 1
        }
    }
}
```

辅助方法使用以下规则：

```swift
private var axisLength: CGFloat {
    axis == .leftRight ? bounds.width : bounds.height
}

private func normalizedWeights(for count: Int) -> [Double] {
    guard weights.count == count,
          weights.allSatisfy({ $0.isFinite && $0 > 0 }) else {
        return Array(repeating: 1 / Double(count), count: count)
    }
    let total = weights.reduce(0, +)
    guard total.isFinite, total > 0 else {
        return Array(repeating: 1 / Double(count), count: count)
    }
    return weights.map { $0 / total }
}

private func setFrame(of view: NSView, origin: CGFloat, length: CGFloat) {
    view.frame = axis == .leftRight
        ? NSRect(x: origin, y: 0, width: length, height: bounds.height)
        : NSRect(x: 0, y: origin, width: bounds.width, height: length)
}
```

- [ ] **Step 4: 运行容器测试**

Run: `swift test --filter WorkspaceSplitContainerViewTests`

Expected: PASS。

- [ ] **Step 5: 提交布局容器**

```bash
git add Sources/InkShell/WorkspaceSplitContainerView.swift Tests/InkShellTests/WorkspaceSplitContainerViewTests.swift
git commit -m "feat(shell): 增加稳定的权重分屏容器" -m "Refs #29"
```

### Task 2: Divider 绘制与拖动

**Files:**
- Modify: `Sources/InkShell/WorkspaceSplitContainerView.swift`
- Modify: `Tests/InkShellTests/WorkspaceSplitContainerViewTests.swift`

**Interfaces:**
- Consumes: Task 1 的 `weights`、轴向 frame 计算。
- Produces: `onWeightsChange: ((SplitID, [Double]) -> Void)?`、`beginDividerDrag(at:) -> Bool`、`updateDividerDrag(to:)`、`endDividerDrag()`。

- [ ] **Step 1: 写相邻权重、最小尺寸和单次提交的失败测试**

```swift
@Test("拖动只改变 divider 两侧并在结束时提交一次")
func dragChangesAdjacentPairAndCommitsOnce() {
    let container = WorkspaceSplitContainerView(
        splitID: SplitID(), axis: .leftRight, weights: [0.25, 0.25, 0.5]
    )
    container.frame = NSRect(x: 0, y: 0, width: 800, height: 500)
    (0..<3).forEach { _ in container.addPaneSubview(NSView()) }
    container.layoutSubtreeIfNeeded()
    var submissions: [[Double]] = []
    container.onWeightsChange = { _, weights in submissions.append(weights) }

    #expect(container.beginDividerDrag(at: NSPoint(x: 200, y: 250)))
    container.updateDividerDrag(to: NSPoint(x: 280, y: 250))
    #expect(container.weights[0] > 0.25)
    #expect(container.weights[1] < 0.25)
    #expect(abs(container.weights[2] - 0.5) < 0.001)
    #expect(submissions.isEmpty)

    container.endDividerDrag()
    #expect(submissions.count == 1)
    #expect(abs(submissions[0].reduce(0, +) - 1) < 0.0001)
}

@Test("拖动不能把相邻 pane 压到零")
func dragPreservesMinimumPaneLength() {
    let container = WorkspaceSplitContainerView(
        splitID: SplitID(), axis: .topBottom, weights: [0.5, 0.5]
    )
    container.frame = NSRect(x: 0, y: 0, width: 300, height: 200)
    let first = NSView()
    let second = NSView()
    container.addPaneSubview(first)
    container.addPaneSubview(second)
    container.layoutSubtreeIfNeeded()

    #expect(container.beginDividerDrag(at: NSPoint(x: 150, y: 100)))
    container.updateDividerDrag(to: NSPoint(x: 150, y: -1_000))
    container.layoutSubtreeIfNeeded()

    #expect(first.frame.height >= 48)
    #expect(second.frame.height >= 48)
}
```

- [ ] **Step 2: 运行拖动测试并确认接口不存在**

Run: `swift test --filter WorkspaceSplitContainerViewTests`

Expected: FAIL，缺少拖动接口或回调。

- [ ] **Step 3: 实现 divider 与拖动状态**

```swift
private struct DividerDrag {
    let index: Int
    let startCoordinate: CGFloat
    let firstLength: CGFloat
    let secondLength: CGFloat
}

private var drag: DividerDrag?
var onWeightsChange: ((SplitID, [Double]) -> Void)?

private func axisCoordinate(of point: NSPoint) -> CGFloat {
    axis == .leftRight ? point.x : point.y
}

private func childLength(at index: Int) -> CGFloat {
    axis == .leftRight ? subviews[index].frame.width : subviews[index].frame.height
}

func beginDividerDrag(at point: NSPoint) -> Bool {
    guard let index = dividerHitIndex(at: point) else { return false }
    drag = DividerDrag(
        index: index,
        startCoordinate: axisCoordinate(of: point),
        firstLength: childLength(at: index),
        secondLength: childLength(at: index + 1)
    )
    return true
}
```

`updateDividerDrag(to:)` 用鼠标增量计算相邻两项长度。有效下限为 `min(preferredMinimum, pairLength / 2)`，左右的 `preferredMinimum` 为 80， 上下为 48。两项总权重保持不变，其他权重不变。`endDividerDrag()` 只在拖动存在时归一化并调用一次回调。

```swift
func updateDividerDrag(to point: NSPoint) {
    guard let drag else { return }
    let delta = axisCoordinate(of: point) - drag.startCoordinate
    let pairLength = drag.firstLength + drag.secondLength
    let preferredMinimum: CGFloat = axis == .leftRight ? 80 : 48
    let minimum = min(preferredMinimum, pairLength / 2)
    let firstLength = min(pairLength - minimum, max(minimum, drag.firstLength + delta))
    let pairWeight = weights[drag.index] + weights[drag.index + 1]
    weights[drag.index] = pairWeight * Double(firstLength / pairLength)
    weights[drag.index + 1] = pairWeight - weights[drag.index]
    needsLayout = true
}

func endDividerDrag() {
    guard drag != nil else { return }
    drag = nil
    let total = weights.reduce(0, +)
    weights = weights.map { $0 / total }
    onWeightsChange?(splitID, weights)
}

override func mouseDown(with event: NSEvent) {
    if !beginDividerDrag(at: convert(event.locationInWindow, from: nil)) {
        super.mouseDown(with: event)
    }
}

override func mouseDragged(with event: NSEvent) {
    updateDividerDrag(to: convert(event.locationInWindow, from: nil))
}

override func mouseUp(with event: NSEvent) {
    endDividerDrag()
}
```

divider 矩形和光标使用同一组位置：

```swift
private var dividerRects: [NSRect] {
    guard subviews.count > 1 else { return [] }
    return subviews.dropLast().map { child in
        axis == .leftRight
            ? NSRect(x: child.frame.maxX, y: 0, width: 1, height: bounds.height)
            : NSRect(x: 0, y: child.frame.maxY, width: bounds.width, height: 1)
    }
}

private func dividerHitIndex(at point: NSPoint) -> Int? {
    dividerRects.firstIndex { rect in
        let hitRect = axis == .leftRight
            ? rect.insetBy(dx: -3, dy: 0)
            : rect.insetBy(dx: 0, dy: -3)
        return hitRect.contains(point)
    }
}

override func draw(_ dirtyRect: NSRect) {
    super.draw(dirtyRect)
    NSColor.separatorColor.setFill()
    for rect in dividerRects where rect.intersects(dirtyRect) {
        rect.fill()
    }
}

override func resetCursorRects() {
    super.resetCursorRects()
    let cursor = axis == .leftRight ? NSCursor.resizeLeftRight : NSCursor.resizeUpDown
    for rect in dividerRects {
        let hitRect = axis == .leftRight
            ? rect.insetBy(dx: -3, dy: 0)
            : rect.insetBy(dx: 0, dy: -3)
        addCursorRect(hitRect, cursor: cursor)
    }
}
```

- [ ] **Step 4: 运行容器测试**

Run: `swift test --filter WorkspaceSplitContainerViewTests`

Expected: PASS，拖动期间不提交，松开后提交一次。

- [ ] **Step 5: 提交 divider 交互**

```bash
git add Sources/InkShell/WorkspaceSplitContainerView.swift Tests/InkShellTests/WorkspaceSplitContainerViewTests.swift
git commit -m "feat(shell): 支持分屏分隔线拖动" -m "Refs #29"
```

### Task 3: 接入终端工作区

**Files:**
- Modify: `Sources/InkShell/TerminalWorkspaceViewController.swift`
- Modify: `Tests/InkShellTests/TerminalWorkspaceTests.swift`

**Interfaces:**
- Consumes: `WorkspaceSplitContainerView`、`TerminalTab.updateSplitWeights(_:weights:)`。
- Produces: 递归自定义容器视图树和稳定的权重回写。

- [ ] **Step 1: 保留并运行第二轮布局回归测试**

现有 `repeatedTopBottomSplitsKeepEveryPaneVisible()` 已在每次 `show` 后强制所有分组再布局一次。它必须继续断言五个 pane 的高度都大于 1。

Run: `swift test --filter TerminalWorkspaceTests.repeatedTopBottomSplitsKeepEveryPaneVisible`

Expected: FAIL，当前 `NSSplitView` 会把后续 pane 高度压到 0。

- [ ] **Step 2: 用自定义容器构建分组节点**

```swift
case let .group(id, axis, weights, children):
    let container = WorkspaceSplitContainerView(
        splitID: id, axis: axis, weights: weights
    )
    for child in children {
        container.addPaneSubview(makeView(for: child, tab: tab, config: config))
    }
    container.onWeightsChange = { [weak self] splitID, weights in
        _ = self?.currentTab?.updateSplitWeights(splitID, weights: weights)
        self?.onWeightsChange?(splitID, weights)
    }
    return container
```

删除 `WorkspaceSplitView` 和 `commitWeights(from:)`。工作区不再读取临时 frame 推导权重，容器只在拖动结束时传入已归一化结果。

- [ ] **Step 3: 更新工作区测试的容器查询和拖动调用**

把 `WorkspaceSplitView` 查询改为 `WorkspaceSplitContainerView`。拖动测试调用 `beginDividerDrag`、`updateDividerDrag` 和 `endDividerDrag`，不再使用 `NSSplitView.setPosition`。

```swift
let container = try #require(
    allSubviews(in: workspace.view)
        .compactMap { $0 as? WorkspaceSplitContainerView }
        .first
)
let dividerPoint = NSPoint(x: container.subviews[0].frame.maxX, y: 100)
#expect(container.beginDividerDrag(at: dividerPoint))
container.updateDividerDrag(to: NSPoint(x: dividerPoint.x + 80, y: 100))
container.endDividerDrag()
```

- [ ] **Step 4: 运行标签与工作区测试**

Run: `swift test --filter 'TerminalTabTests|TerminalWorkspaceTests|WorkspaceSplitContainerViewTests'`

Expected: PASS，五个连续向下分屏经过多轮布局后仍全部可见。

- [ ] **Step 5: 提交工作区迁移**

```bash
git add Sources/InkShell/TerminalWorkspaceViewController.swift Tests/InkShellTests/TerminalWorkspaceTests.swift
git commit -m "fix(shell): 用显式布局保持分屏可见" -m "Refs #29"
```

### Task 4: 完整验证与临时应用

**Files:**
- Verify: `docs/perf.md`
- Rebuild: `/private/tmp/ink-split-verify-30/Ink Split Verify.app`

**Interfaces:**
- Consumes: 完整自定义分屏容器。
- Produces: 更新后的验证应用和 PR #30。

- [ ] **Step 1: 运行完整自动验证**

Run: `swift test && swift build -c release && git diff --check`

Expected: 全部测试通过，release 构建成功，无空白错误。

- [ ] **Step 2: 检查性能边界未扩大**

Run: `git diff origin/main...HEAD -- Sources/TerminalCore Sources/InkTerminalView docs/perf.md`

Expected: 本次重构不修改 `TerminalCore` 或 Metal 渲染热路径，`docs/perf.md` 不新增未经测量的数据。

- [ ] **Step 3: 重建同一个临时验证应用**

用 `.build/debug/ink` 替换 `/private/tmp/ink-split-verify-30/Ink Split Verify.app/Contents/MacOS/ink`，保持 bundle id `com.cheneychou.ink.split-verify-30`，重新 ad-hoc 签名并运行 `codesign --verify --deep --strict`。

- [ ] **Step 4: 做真实窗口检查**

只启动 `Ink Split Verify.app`，依次检查：`Command-D` 默认向右；四方向组合；连续向下分到四个 pane；横向与纵向混合嵌套；拖动每条 divider；点击 pane 后连续 `Command-W` 收拢。

- [ ] **Step 5: 评审、推送并刷新 PR**

Run:

```bash
git push origin agent/issue-29-terminal-splits
gh pr view 30 --json state,headRefOid,mergeable,statusCheckRollup,url
```

Expected: 远端 head 与本地 `HEAD` 一致，PR 保持 open 和 mergeable。
