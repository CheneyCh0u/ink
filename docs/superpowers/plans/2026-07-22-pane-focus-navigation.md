# 相邻 Pane 方向聚焦 Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** 为 Ink 增加 `⌘⌥←/→/↑/↓` 相邻 pane 聚焦，并让菜单状态、活动边框、第一响应者和工作区保存链路保持一致。

**Architecture:** `PaneLayout` 从权重树推导纯 Swift 归一化矩形并按几何评分选邻居；`TerminalTab` 负责活动 pane 状态；`TerminalWorkspaceViewController` 协调边框、回调和第一响应者；`MainWindowController` 与 AppKit 菜单只做方向路由和可用性校验。

**Tech Stack:** Swift 6、Swift Testing、AppKit、SwiftPM；最低 macOS 14.0。

## Global Constraints

- `TerminalCore` 不得引入 AppKit 或 Metal，本功能不修改 `TerminalCore`、PTY 或 Metal 渲染热路径。
- 不新增第三方依赖、设置项、动画、覆盖层、焦点历史或边界循环。
- 坐标原点位于左上，X 向右、Y 向下，与 `WorkspaceSplitContainerView.isFlipped == true` 一致。
- 候选必须位于目标方向且在正交轴上有正重叠；按轴向间距、中心偏移、DFS 顺序决胜。
- 边界、单 pane 和设置页静默无操作，不调用 `NSBeep()`，不把快捷键写入 PTY。
- 代码标识符使用英文，注释、提交信息和用户可见菜单文案使用中文。

---

## 文件结构

- `Sources/InkShell/PaneLayout.swift`：归一化矩形推导、候选过滤与稳定评分。
- `Sources/InkShell/TerminalTab.swift`：只读可聚焦查询与活动 pane 状态切换。
- `Sources/InkShell/TerminalWorkspaceViewController.swift`：边框、回调和第一响应者协调。
- `Sources/InkShell/MainWindowController.swift`：四方向 selector、设置页守卫、菜单校验。
- `Sources/InkShell/AppDelegate.swift`：窗口菜单标题和 `Command-Option-方向键` 注册。
- `Tests/InkShellTests/PaneLayoutTests.swift`：纯模型几何、边界、权重和稳定性覆盖。
- `Tests/InkShellTests/TerminalTabTests.swift`：状态切换和无目标不变性。
- `Tests/InkShellTests/TerminalWorkspaceTests.swift`：UI 协调与第一响应者覆盖。
- `Tests/InkShellTests/TerminalSplitCommandTests.swift`：菜单声明、selector 路由和验证状态。

### Task 1: 归一化几何邻居选择

**Files:**
- Modify: `Sources/InkShell/PaneLayout.swift:45-285`
- Test: `Tests/InkShellTests/PaneLayoutTests.swift`

**Interfaces:**
- Consumes: `PaneLayout`、`PaneID`、`PaneSplitAxis`、`PaneSplitDirection` 和分组权重。
- Produces: `PaneLayout.neighbor(of:direction:) -> PaneID?`；后续任务只依赖这个方法，不读取几何内部类型。

- [ ] **Step 1: 写入失败的几何行为测试**

在 `PaneLayoutTests` 增加以下测试。用显式 `.group` 构造 2×2、T 形和损坏权重布局，避免测试被 `split()` 的同轴扁平化细节绑住：

```swift
@Test("相邻 pane 按视觉方向双向选择且边界为空")
func neighborUsesVisualDirectionAndStopsAtBoundary() {
    let topLeft = PaneID()
    let bottomLeft = PaneID()
    let topRight = PaneID()
    let bottomRight = PaneID()
    let layout = PaneLayout.group(
        id: SplitID(), axis: .leftRight, weights: [0.4, 0.6],
        children: [
            .group(
                id: SplitID(), axis: .topBottom, weights: [0.7, 0.3],
                children: [.leaf(topLeft), .leaf(bottomLeft)]
            ),
            .group(
                id: SplitID(), axis: .topBottom, weights: [0.7, 0.3],
                children: [.leaf(topRight), .leaf(bottomRight)]
            ),
        ]
    )

    #expect(layout.neighbor(of: topLeft, direction: .right) == topRight)
    #expect(layout.neighbor(of: topRight, direction: .left) == topLeft)
    #expect(layout.neighbor(of: topLeft, direction: .down) == bottomLeft)
    #expect(layout.neighbor(of: bottomLeft, direction: .up) == topLeft)
    #expect(layout.neighbor(of: topLeft, direction: .left) == nil)
    #expect(layout.neighbor(of: bottomRight, direction: .down) == nil)
}

@Test("T 形候选先比中心距离再按布局顺序稳定决胜")
func tShapeUsesCenterDistanceThenDFSOrder() {
    let left = PaneID()
    let rightTop = PaneID()
    let rightBottom = PaneID()
    let tied = PaneLayout.group(
        id: SplitID(), axis: .leftRight, weights: [0.5, 0.5],
        children: [
            .leaf(left),
            .group(
                id: SplitID(), axis: .topBottom, weights: [0.5, 0.5],
                children: [.leaf(rightTop), .leaf(rightBottom)]
            ),
        ]
    )
    #expect(tied.neighbor(of: left, direction: .right) == rightTop)

    let nearBottom = PaneLayout.group(
        id: SplitID(), axis: .leftRight, weights: [0.5, 0.5],
        children: [
            .leaf(left),
            .group(
                id: SplitID(), axis: .topBottom, weights: [0.3, 0.7],
                children: [.leaf(rightTop), .leaf(rightBottom)]
            ),
        ]
    )
    #expect(nearBottom.neighbor(of: left, direction: .right) == rightBottom)
}

@Test("对角 pane 不跳转且无效权重等分回退")
func diagonalIsRejectedAndInvalidWeightsFallBackEqually() {
    let topLeft = PaneID()
    let topRight = PaneID()
    let bottomRight = PaneID()
    let diagonal = PaneLayout.group(
        id: SplitID(), axis: .topBottom, weights: [0.5, 0.5],
        children: [
            .group(
                id: SplitID(), axis: .leftRight, weights: [0.5, 0.5],
                children: [.leaf(topLeft), .leaf(topRight)]
            ),
            .group(
                id: SplitID(), axis: .leftRight, weights: [1, 0],
                children: [.leaf(PaneID()), .leaf(bottomRight)]
            ),
        ]
    )
    let unchanged = diagonal

    #expect(diagonal.neighbor(of: topLeft, direction: .down) != bottomRight)
    #expect(diagonal.neighbor(of: topRight, direction: .down) == bottomRight)
    #expect(diagonal.neighbor(of: PaneID(), direction: .right) == nil)
    #expect(diagonal == unchanged)

    let mismatched = PaneLayout.group(
        id: SplitID(), axis: .leftRight, weights: [1],
        children: [.leaf(topLeft), .leaf(topRight)]
    )
    #expect(mismatched.neighbor(of: topLeft, direction: .right) == topRight)
}
```

- [ ] **Step 2: 运行定向测试并确认红灯**

Run: `swift test --filter PaneLayoutTests --no-parallel`

Expected: 编译失败，指出 `PaneLayout` 没有 `neighbor(of:direction:)`。

- [ ] **Step 3: 实现归一化矩形、候选筛选和稳定评分**

在 `PaneLayout.swift` 中加入私有值类型和模块内部查询方法。以下代码完整定义几何表示、递归切分、候选过滤与评分：

```swift
private struct PaneNormalizedRect: Equatable, Sendable {
    let x: Double
    let y: Double
    let width: Double
    let height: Double

    var minX: Double { x }
    var maxX: Double { x + width }
    var minY: Double { y }
    var maxY: Double { y + height }
    var midX: Double { x + width / 2 }
    var midY: Double { y + height / 2 }
}

private struct PaneNavigationEntry: Sendable {
    let paneID: PaneID
    let rect: PaneNormalizedRect
    let ordinal: Int
}

private struct PaneNavigationScore {
    let axialGap: Double
    let perpendicularCenterGap: Double
    let ordinal: Int

    func isBetter(than other: Self) -> Bool {
        if axialGap != other.axialGap { return axialGap < other.axialGap }
        if perpendicularCenterGap != other.perpendicularCenterGap {
            return perpendicularCenterGap < other.perpendicularCenterGap
        }
        return ordinal < other.ordinal
    }
}
```

在 `PaneLayout` 内加入：

```swift
func neighbor(of paneID: PaneID, direction: PaneSplitDirection) -> PaneID? {
    var entries: [PaneNavigationEntry] = []
    collectNavigationEntries(
        in: PaneNormalizedRect(x: 0, y: 0, width: 1, height: 1),
        into: &entries
    )
    guard let active = entries.first(where: { $0.paneID == paneID }) else {
        return nil
    }

    var best: (entry: PaneNavigationEntry, score: PaneNavigationScore)?
    for candidate in entries where candidate.paneID != paneID {
        guard let score = Self.navigationScore(
            from: active.rect, to: candidate.rect, direction: direction
        ) else { continue }
        if best == nil || score.isBetter(than: best!.score) {
            best = (candidate, score)
        }
    }
    return best?.entry.paneID
}

private func collectNavigationEntries(
    in rect: PaneNormalizedRect,
    into entries: inout [PaneNavigationEntry]
) {
    switch self {
    case let .leaf(paneID):
        entries.append(PaneNavigationEntry(
            paneID: paneID, rect: rect, ordinal: entries.count
        ))

    case let .group(_, axis, weights, children):
        guard !children.isEmpty else { return }
        let resolved = Self.navigationWeights(weights, childCount: children.count)
        var cursor = axis == .leftRight ? rect.minX : rect.minY
        for index in children.indices {
            let isLast = index == children.index(before: children.endIndex)
            let length: Double
            let childRect: PaneNormalizedRect
            switch axis {
            case .leftRight:
                length = isLast ? rect.maxX - cursor : rect.width * resolved[index]
                childRect = PaneNormalizedRect(
                    x: cursor, y: rect.y, width: length, height: rect.height
                )
            case .topBottom:
                length = isLast ? rect.maxY - cursor : rect.height * resolved[index]
                childRect = PaneNormalizedRect(
                    x: rect.x, y: cursor, width: rect.width, height: length
                )
            }
            children[index].collectNavigationEntries(in: childRect, into: &entries)
            cursor += length
        }
    }
}

private static func navigationWeights(
    _ weights: [Double],
    childCount: Int
) -> [Double] {
    guard weights.count == childCount,
          weights.allSatisfy({ $0.isFinite && $0 > 0 }) else {
        return Array(repeating: 1 / Double(childCount), count: childCount)
    }
    let total = weights.reduce(0, +)
    guard total.isFinite, total > 0 else {
        return Array(repeating: 1 / Double(childCount), count: childCount)
    }
    return weights.map { $0 / total }
}

private static func navigationScore(
    from active: PaneNormalizedRect,
    to candidate: PaneNormalizedRect,
    direction: PaneSplitDirection
) -> PaneNavigationScore? {
    let epsilon = 1e-9
    let xOverlap = min(active.maxX, candidate.maxX) - max(active.minX, candidate.minX)
    let yOverlap = min(active.maxY, candidate.maxY) - max(active.minY, candidate.minY)
    let axialGap: Double
    let centerGap: Double

    switch direction {
    case .left:
        guard candidate.maxX <= active.minX + epsilon, yOverlap > epsilon else { return nil }
        axialGap = max(0, active.minX - candidate.maxX)
        centerGap = abs(active.midY - candidate.midY)
    case .right:
        guard candidate.minX >= active.maxX - epsilon, yOverlap > epsilon else { return nil }
        axialGap = max(0, candidate.minX - active.maxX)
        centerGap = abs(active.midY - candidate.midY)
    case .up:
        guard candidate.maxY <= active.minY + epsilon, xOverlap > epsilon else { return nil }
        axialGap = max(0, active.minY - candidate.maxY)
        centerGap = abs(active.midX - candidate.midX)
    case .down:
        guard candidate.minY >= active.maxY - epsilon, xOverlap > epsilon else { return nil }
        axialGap = max(0, candidate.minY - active.maxY)
        centerGap = abs(active.midX - candidate.midX)
    }
    return PaneNavigationScore(
        axialGap: axialGap,
        perpendicularCenterGap: centerGap,
        ordinal: candidate.ordinal
    )
}
```

- [ ] **Step 4: 运行模型测试并确认绿灯**

Run: `swift test --filter PaneLayoutTests --no-parallel`

Expected: `PaneLayoutTests` 全部通过，包括现有分屏、关闭和权重测试。

- [ ] **Step 5: 提交纯模型任务**

```bash
git add Sources/InkShell/PaneLayout.swift Tests/InkShellTests/PaneLayoutTests.swift
git commit -m "feat(shell): 按视觉几何查找相邻 pane" -m "使用归一化布局和稳定评分处理嵌套、权重与 T 形分屏。\n\nRefs #74"
```

### Task 2: TerminalTab 活动 pane 状态

**Files:**
- Modify: `Sources/InkShell/TerminalTab.swift:48-83`
- Test: `Tests/InkShellTests/TerminalTabTests.swift`

**Interfaces:**
- Consumes: `PaneLayout.neighbor(of:direction:) -> PaneID?`。
- Produces: `TerminalTab.canFocusNeighbor(direction:) -> Bool` 和 `TerminalTab.focusNeighbor(direction:) -> Bool`。

- [ ] **Step 1: 写入失败的标签状态测试**

```swift
@Test("方向聚焦更新活动 pane 且只读查询不改状态")
func focusNeighborUpdatesActivePane() {
    let left = makePane()
    let right = makePane()
    let tab = TerminalTab(initialPane: left)
    _ = tab.insertPane(right, splitting: left.id, direction: .right)
    _ = tab.activate(left.id)

    #expect(tab.canFocusNeighbor(direction: .right))
    #expect(tab.activePane === left)
    #expect(tab.focusNeighbor(direction: .right))
    #expect(tab.activePane === right)
}

@Test("方向边界保持原活动 pane")
func focusNeighborAtBoundaryIsNoOp() {
    let only = makePane()
    let tab = TerminalTab(initialPane: only)

    #expect(!tab.canFocusNeighbor(direction: .left))
    #expect(!tab.focusNeighbor(direction: .left))
    #expect(tab.activePane === only)
}
```

- [ ] **Step 2: 运行定向测试并确认红灯**

Run: `swift test --filter TerminalTabTests --no-parallel`

Expected: 编译失败，缺少 `canFocusNeighbor` 和 `focusNeighbor`。

- [ ] **Step 3: 实现标签查询与切换**

```swift
func canFocusNeighbor(direction: PaneSplitDirection) -> Bool {
    layout.neighbor(of: activePaneID, direction: direction) != nil
}

@discardableResult
func focusNeighbor(direction: PaneSplitDirection) -> Bool {
    guard let paneID = layout.neighbor(of: activePaneID, direction: direction) else {
        return false
    }
    return activate(paneID)
}
```

- [ ] **Step 4: 运行标签测试并确认绿灯**

Run: `swift test --filter TerminalTabTests --no-parallel`

Expected: `TerminalTabTests` 全部通过。

- [ ] **Step 5: 提交标签状态任务**

```bash
git add Sources/InkShell/TerminalTab.swift Tests/InkShellTests/TerminalTabTests.swift
git commit -m "feat(shell): 在标签内切换相邻 pane" -m "把视觉邻居查询收敛为活动 pane 状态变更，边界保持原状态。\n\nRefs #74"
```

### Task 3: 工作区焦点协调

**Files:**
- Modify: `Sources/InkShell/TerminalWorkspaceViewController.swift:218-228`
- Test: `Tests/InkShellTests/TerminalWorkspaceTests.swift`

**Interfaces:**
- Consumes: `TerminalTab.canFocusNeighbor(direction:)` 和 `TerminalTab.focusNeighbor(direction:)`。
- Produces: `TerminalWorkspaceViewController.canFocusNeighbor(direction:) -> Bool` 和 `focusNeighbor(direction:) -> Bool`。

- [ ] **Step 1: 写入失败的工作区测试**

```swift
@Test("方向聚焦同步边框回调和第一响应者")
func focusNeighborCoordinatesWorkspaceState() throws {
    let left = makePane()
    let right = makePane()
    let tab = TerminalTab(initialPane: left)
    _ = tab.insertPane(right, splitting: left.id, direction: .right)
    _ = tab.activate(left.id)
    let workspace = TerminalWorkspaceViewController()
    let window = NSWindow(
        contentRect: NSRect(x: 0, y: 0, width: 800, height: 600),
        styleMask: [.titled], backing: .buffered, defer: false
    )
    window.contentViewController = workspace
    defer { window.close() }
    workspace.show(tab: tab, config: InkConfig())
    var activations: [PaneID] = []
    workspace.onActivatePane = { activations.append($0) }

    #expect(workspace.canFocusNeighbor(direction: .right))
    #expect(workspace.focusNeighbor(direction: .right))

    let leftContainer = try #require(workspace.paneContainer(for: left.id))
    let rightContainer = try #require(workspace.paneContainer(for: right.id))
    let rightTerminal = try #require(workspace.terminalView(for: right.id))
    #expect(!leftContainer.isActive)
    #expect(rightContainer.isActive)
    #expect(activations == [right.id])
    #expect(window.firstResponder === rightTerminal)
}

@Test("工作区方向边界不触发回调或改变响应者")
func focusNeighborAtBoundaryDoesNotNotify() throws {
    let pane = makePane()
    let tab = TerminalTab(initialPane: pane)
    let workspace = TerminalWorkspaceViewController()
    let window = NSWindow(
        contentRect: NSRect(x: 0, y: 0, width: 800, height: 600),
        styleMask: [.titled], backing: .buffered, defer: false
    )
    window.contentViewController = workspace
    defer { window.close() }
    workspace.show(tab: tab, config: InkConfig())
    let terminal = try #require(workspace.terminalView(for: pane.id))
    _ = window.makeFirstResponder(terminal)
    var activationCount = 0
    workspace.onActivatePane = { _ in activationCount += 1 }

    #expect(!workspace.focusNeighbor(direction: .left))
    #expect(activationCount == 0)
    #expect(window.firstResponder === terminal)
}
```

- [ ] **Step 2: 运行定向测试并确认红灯**

Run: `swift test --filter TerminalWorkspaceTests --no-parallel`

Expected: 编译失败，缺少工作区方向聚焦接口。

- [ ] **Step 3: 实现工作区成功与失败路径**

在现有 `activate(_:)` 与 `focusActivePane()` 附近加入：

```swift
func canFocusNeighbor(direction: PaneSplitDirection) -> Bool {
    currentTab?.canFocusNeighbor(direction: direction) ?? false
}

@discardableResult
func focusNeighbor(direction: PaneSplitDirection) -> Bool {
    guard currentTab?.focusNeighbor(direction: direction) == true,
          let paneID = currentTab?.activePaneID else { return false }
    updateActiveBorders()
    onActivatePane?(paneID)
    focusActivePane()
    return true
}
```

- [ ] **Step 4: 运行工作区测试并确认绿灯**

Run: `swift test --filter TerminalWorkspaceTests --no-parallel`

Expected: `TerminalWorkspaceTests` 全部通过，成功路径回调一次，失败路径不改变响应者。

- [ ] **Step 5: 提交工作区协调任务**

```bash
git add Sources/InkShell/TerminalWorkspaceViewController.swift Tests/InkShellTests/TerminalWorkspaceTests.swift
git commit -m "feat(shell): 同步相邻 pane 焦点状态" -m "方向切换后统一刷新边框、工作区回调和终端第一响应者。\n\nRefs #74"
```

### Task 4: 窗口菜单、快捷键和动作校验

**Files:**
- Modify: `Sources/InkShell/AppDelegate.swift:182-205`
- Modify: `Sources/InkShell/MainWindowController.swift:795-865,1259-1283`
- Test: `Tests/InkShellTests/TerminalSplitCommandTests.swift`

**Interfaces:**
- Consumes: `TerminalWorkspaceViewController.canFocusNeighbor(direction:)` 和 `focusNeighbor(direction:)`。
- Produces: `focusPaneLeft(_:)`、`focusPaneRight(_:)`、`focusPaneUp(_:)`、`focusPaneDown(_:)` 四个 AppKit selector。

- [ ] **Step 1: 写入失败的菜单声明测试**

```swift
@Test("窗口菜单提供 Command-Option 四方向 pane 聚焦")
func windowMenuOffersPaneFocusShortcuts() throws {
    let menu = AppDelegate.makeMainMenu()
    let windowMenu = try #require(menu.items.first { $0.submenu?.title == "窗口" }?.submenu)
    let expected: [(Selector, String, String)] = [
        (#selector(MainWindowController.focusPaneLeft(_:)), "聚焦左侧 pane", "\u{F702}"),
        (#selector(MainWindowController.focusPaneRight(_:)), "聚焦右侧 pane", "\u{F703}"),
        (#selector(MainWindowController.focusPaneUp(_:)), "聚焦上方 pane", "\u{F700}"),
        (#selector(MainWindowController.focusPaneDown(_:)), "聚焦下方 pane", "\u{F701}"),
    ]

    for (action, title, key) in expected {
        let item = try #require(windowMenu.items.first { $0.action == action })
        #expect(item.title == title)
        #expect(item.keyEquivalent == key)
        #expect(item.keyEquivalentModifierMask == [.command, .option])
    }
}
```

- [ ] **Step 2: 运行菜单测试并确认红灯**

Run: `swift test --filter TerminalSplitCommandTests.windowMenuOffersPaneFocusShortcuts --no-parallel`

Expected: 编译失败，四个 selector 尚不存在。

- [ ] **Step 3: 注册四个窗口菜单项**

在 `AppDelegate.makeMainMenu()` 的“窗口”菜单开头加入，随后添加 separator，再保留现有会话切换项：

```swift
let paneFocusItems: [(String, Selector, String)] = [
    ("聚焦左侧 pane", #selector(MainWindowController.focusPaneLeft(_:)), "\u{F702}"),
    ("聚焦右侧 pane", #selector(MainWindowController.focusPaneRight(_:)), "\u{F703}"),
    ("聚焦上方 pane", #selector(MainWindowController.focusPaneUp(_:)), "\u{F700}"),
    ("聚焦下方 pane", #selector(MainWindowController.focusPaneDown(_:)), "\u{F701}"),
]
for (title, action, keyEquivalent) in paneFocusItems {
    let item = NSMenuItem(title: title, action: action, keyEquivalent: keyEquivalent)
    item.keyEquivalentModifierMask = [.command, .option]
    windowMenu.addItem(item)
}
windowMenu.addItem(.separator())
```

- [ ] **Step 4: 实现四方向 selector 与统一私有路由**

```swift
@objc public func focusPaneLeft(_ sender: Any?) { focusPane(.left) }
@objc public func focusPaneRight(_ sender: Any?) { focusPane(.right) }
@objc public func focusPaneUp(_ sender: Any?) { focusPane(.up) }
@objc public func focusPaneDown(_ sender: Any?) { focusPane(.down) }

private func focusPane(_ direction: PaneSplitDirection) {
    guard !isShowingSettings else { return }
    _ = workspaceVC.focusNeighbor(direction: direction)
}
```

在 `validateMenuItem(_:)` 中先映射 selector：

```swift
let focusDirections: [Selector: PaneSplitDirection] = [
    #selector(focusPaneLeft(_:)): .left,
    #selector(focusPaneRight(_:)): .right,
    #selector(focusPaneUp(_:)): .up,
    #selector(focusPaneDown(_:)): .down,
]
if let direction = focusDirections[action] {
    return !isShowingSettings && workspaceVC.canFocusNeighbor(direction: direction)
}
```

- [ ] **Step 5: 写入动作与菜单校验集成测试**

在 `TerminalSplitCommandTests` 使用现有 fixture，完整验证四个 selector 的方向、边界校验和设置页禁用：

```swift
@Test("窗口 pane 聚焦动作路由方向并按边界与设置页校验")
func paneFocusActionsAndValidationFollowWorkspace() throws {
    let fixture = makeController(presenter: SplitClosePresenter(result: true))
    defer { fixture.cleanUp() }
    let controller = fixture.controller
    let window = try #require(controller.window)
    window.setFrame(NSRect(x: 300, y: 200, width: 1000, height: 700), display: true)
    window.orderFront(nil)
    controller.newSession(nil)
    spinRunLoop()
    controller.splitRight(nil)
    spinRunLoop()

    let menu = AppDelegate.makeMainMenu()
    let windowMenu = try #require(menu.items.first { $0.submenu?.title == "窗口" }?.submenu)
    func item(_ action: Selector) throws -> NSMenuItem {
        try #require(windowMenu.items.first { $0.action == action })
    }
    let leftItem = try item(#selector(MainWindowController.focusPaneLeft(_:)))
    let rightItem = try item(#selector(MainWindowController.focusPaneRight(_:)))
    let upItem = try item(#selector(MainWindowController.focusPaneUp(_:)))
    let downItem = try item(#selector(MainWindowController.focusPaneDown(_:)))
    func activeContainer() throws -> TerminalPaneContainerView {
        try #require(allSubviews(in: window.contentView!).compactMap {
            $0 as? TerminalPaneContainerView
        }.first(where: \.isActive))
    }

    #expect(controller.validateMenuItem(leftItem))
    #expect(!controller.validateMenuItem(rightItem))
    let rightX = try activeContainer().frame.midX
    controller.focusPaneLeft(nil)
    #expect(try activeContainer().frame.midX < rightX)
    #expect(!controller.validateMenuItem(leftItem))
    #expect(controller.validateMenuItem(rightItem))

    controller.focusPaneRight(nil)
    #expect(try activeContainer().frame.midX == rightX)
    controller.splitDown(nil)
    spinRunLoop()
    let bottomY = try activeContainer().frame.midY
    #expect(controller.validateMenuItem(upItem))
    #expect(!controller.validateMenuItem(downItem))

    controller.focusPaneUp(nil)
    #expect(try activeContainer().frame.midY < bottomY)
    #expect(controller.validateMenuItem(downItem))
    controller.focusPaneDown(nil)
    #expect(try activeContainer().frame.midY == bottomY)

    controller.showSettings(nil)
    for item in [leftItem, rightItem, upItem, downItem] {
        #expect(!controller.validateMenuItem(item))
    }
}
```

- [ ] **Step 6: 运行菜单与窗口集成测试**

Run: `swift test --filter TerminalSplitCommandTests --no-parallel`

Expected: 菜单声明、方向路由、边界禁用、设置页禁用和既有关闭确认测试全部通过。

- [ ] **Step 7: 提交菜单任务**

```bash
git add Sources/InkShell/AppDelegate.swift Sources/InkShell/MainWindowController.swift Tests/InkShellTests/TerminalSplitCommandTests.swift
git commit -m "feat(shell): 添加相邻 pane 聚焦快捷键" -m "通过窗口菜单路由 Command-Option 方向键，并按实际邻居校验可用性。\n\nCloses #74"
```

### Task 5: 回归验证与人工验收

**Files:**
- Verify only; no production-file changes expected.

**Interfaces:**
- Consumes: Tasks 1–4 的完整功能。
- Produces: 可创建 PR 的验证证据。

- [ ] **Step 1: 运行格式和差异卫生检查**

Run: `git diff --check && rg -n "T[B]D|T[O]DO|待.{0}补|省.{0}略" docs/superpowers/plans/2026-07-22-pane-focus-navigation.md Sources/InkShell Tests/InkShellTests`

Expected: `git diff --check` 无输出；搜索只允许命中既有、与本功能无关的明确注释，不允许新增占位符。

- [ ] **Step 2: 运行完整串行测试**

Run: `swift test --no-parallel`

Expected: 全部测试通过；不得把并发 PTY 偶发失败当作功能通过证据。

- [ ] **Step 3: 运行完整构建**

Run: `swift build`

Expected: Debug 构建完成，无编译错误。

- [ ] **Step 4: 人工验证真实窗口**

运行 `swift run ink`，依次构造左右、上下、2×2、T 形和拖动后不同权重布局。对每个活动 pane 按 `⌘⌥←/→/↑/↓`，确认菜单启用状态、焦点边框和实际输入落点一致；边界按键不循环、不响铃、不在终端产生转义序列；打开设置页后四个命令不可用。

- [ ] **Step 5: 准备评审**

确认 `git status --short` 为空，汇总每个提交和测试证据，然后使用 `superpowers:requesting-code-review` 与项目 `check` skill 进行合并前评审。评审无阻塞项后推送分支、创建关闭 Issue #74 的 PR，等待检查通过并按仓库权限合入 `main`。
