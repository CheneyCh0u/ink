# 四方向分屏与同向布局修复实施计划

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** 修复连续上下分屏尺寸塌缩，并支持按住 `Command-D` 加方向键选择上、下、左、右分屏。

**Architecture:** `PaneLayout` 改为多子项分组，同方向分屏插入现有分组，方向变化时才递归嵌套。快捷键由纯状态机解释，再由窗口级事件监视器转成四方向分屏命令。

**Tech Stack:** Swift 6、AppKit、Swift Testing、SwiftPM，最低 macOS 14.0。

## Global Constraints

- `TerminalCore` 不引入 AppKit 或 Metal。
- 不新增第三方依赖。
- 常用规模按 1 到 4 个可见 pane 验收，不设置固定 pane 数量上限。
- 自动布局和窗口缩放不得把临时的 0 或 1 写回分组权重。
- `Command-W` 仍只关闭活动 pane，最后一个 pane 才关闭标签。
- 用户可见产品名使用 `Ink`，代码标识符使用英文，注释和文档使用中文。

---

### Task 1: 多子项 PaneLayout

**Files:**
- Modify: `Sources/InkShell/PaneLayout.swift`
- Modify: `Tests/InkShellTests/PaneLayoutTests.swift`

**Interfaces:**
- Produces: `PaneSplitDirection`、`PaneLayout.group(id:axis:weights:children:)`、`split(target:newPane:direction:)`、`updateWeights(for:to:)`。
- Consumes: 现有 `PaneID`、`SplitID` 和 `PaneSplitAxis`。

- [ ] **Step 1: 写多子项分组和四方向插入的失败测试**

```swift
@Test("连续向下分屏复用同一个多子项分组")
func repeatedDownSplitsReuseGroup() {
    let first = PaneID()
    let second = PaneID()
    let third = PaneID()
    var layout = PaneLayout.leaf(first)
    _ = layout.split(target: first, newPane: second, direction: .down)
    _ = layout.split(target: second, newPane: third, direction: .down)

    guard case let .group(_, axis, weights, children) = layout else {
        Issue.record("没有形成分组")
        return
    }
    #expect(axis == .topBottom)
    #expect(children == [.leaf(first), .leaf(second), .leaf(third)])
    #expect(weights == [0.5, 0.25, 0.25])
}

@Test("左侧和上方分屏把新 pane 插在目标前面")
func leadingDirectionsInsertBeforeTarget() {
    let original = PaneID()
    let left = PaneID()
    var layout = PaneLayout.leaf(original)
    _ = layout.split(target: original, newPane: left, direction: .left)
    guard case let .group(_, _, _, children) = layout else { return }
    #expect(children == [.leaf(left), .leaf(original)])
}
```

- [ ] **Step 2: 运行模型测试并确认旧二叉接口导致失败**

Run: `swift test --filter PaneLayoutTests`

Expected: FAIL，缺少 `PaneSplitDirection`、`.group` 或新 `split` 接口。

- [ ] **Step 3: 实现多子项分组、删除收拢和权重更新**

```swift
enum PaneSplitDirection: Equatable, Sendable {
    case left, right, up, down

    var axis: PaneSplitAxis {
        switch self {
        case .left, .right: .leftRight
        case .up, .down: .topBottom
        }
    }

    var insertsBefore: Bool {
        self == .left || self == .up
    }
}

indirect enum PaneLayout: Equatable, Sendable {
    case leaf(PaneID)
    case group(id: SplitID, axis: PaneSplitAxis, weights: [Double], children: [PaneLayout])
}
```

同方向父分组中，把目标权重平分并在目标前后插入新叶节点。方向变化时，用 `[0.5, 0.5]` 创建新分组。删除后同步移除权重并归一化，只剩一个子节点时提升该节点。

- [ ] **Step 4: 运行模型测试**

Run: `swift test --filter PaneLayoutTests`

Expected: PASS。

- [ ] **Step 5: 提交模型改动**

```bash
git add Sources/InkShell/PaneLayout.swift Tests/InkShellTests/PaneLayoutTests.swift
git commit -m "refactor(shell): 用多子项分组表示同向分屏" -m "Refs #29"
```

### Task 2: 标签模型与多子项 NSSplitView

**Files:**
- Modify: `Sources/InkShell/TerminalTab.swift`
- Modify: `Sources/InkShell/TerminalWorkspaceViewController.swift`
- Modify: `Tests/InkShellTests/TerminalTabTests.swift`
- Modify: `Tests/InkShellTests/TerminalWorkspaceTests.swift`

**Interfaces:**
- Consumes: `PaneLayout.split(target:newPane:direction:)` 和 `updateWeights(for:to:)`。
- Produces: `TerminalTab.insertPane(_:splitting:direction:)`、多子项 `WorkspaceSplitView` 和 `onWeightsChange`。

- [ ] **Step 1: 保留尺寸塌缩回归测试并补权重恢复测试**

现有失败测试 `repeatedTopBottomSplitsKeepEveryPaneVisible()` 更新为四次 `.down` 分屏，断言所有 pane 高度大于 1，所有权重位于 0 到 1 之间。

```swift
@Test("多子项分隔线位置恢复为权重")
func restoresGroupWeights() throws {
    let first = makePane()
    let second = makePane()
    let third = makePane()
    let tab = TerminalTab(initialPane: first)
    _ = tab.insertPane(second, splitting: first.id, direction: .down)
    _ = tab.insertPane(third, splitting: second.id, direction: .down)
    guard case let .group(id, _, _, _) = tab.layout else {
        Issue.record("没有形成多子项分组")
        return
    }
    _ = tab.updateSplitWeights(id, weights: [0.25, 0.25, 0.5])

    let workspace = TerminalWorkspaceViewController()
    workspace.view.frame = NSRect(x: 0, y: 0, width: 900, height: 600)
    workspace.show(tab: tab, config: InkConfig())
    workspace.view.layoutSubtreeIfNeeded()

    let heights = [first, second, third].map {
        workspace.paneContainer(for: $0.id)?.frame.height ?? 0
    }
    #expect(heights[2] > heights[0])
    #expect(heights.allSatisfy { $0 > 1 })
}
```

- [ ] **Step 2: 运行工作区测试并确认回归测试失败**

Run: `swift test --filter TerminalWorkspaceTests`

Expected: FAIL，连续上下分屏中至少一个 pane 高度为 0，或旧二叉接口无法编译。

- [ ] **Step 3: 渲染多子项分组**

`makeView(for:tab:config:)` 遍历 `children` 并逐个调用 `addArrangedSubview`。`WorkspaceSplitView` 保存整组 `modelWeights`，首次有效 layout 时按累计权重依次设置 divider。

```swift
final class WorkspaceSplitView: NSSplitView {
    let splitID: SplitID
    let modelWeights: [Double]
    private(set) var isTrackingDivider = false
}
```

`mouseDown(with:)` 只负责标记 divider 跟踪区间。拖动结束后读取全部子视图长度，扣除 divider 总厚度并归一化，再通过 `onWeightsChange` 写回模型。构建期和窗口自动布局不回写。

- [ ] **Step 4: 运行标签与工作区测试**

Run: `swift test --filter 'TerminalTabTests|TerminalWorkspaceTests'`

Expected: PASS，连续四次向下分屏后五个 pane 都有可见高度。

- [ ] **Step 5: 提交工作区改动**

```bash
git add Sources/InkShell/TerminalTab.swift Sources/InkShell/TerminalWorkspaceViewController.swift Tests/InkShellTests/TerminalTabTests.swift Tests/InkShellTests/TerminalWorkspaceTests.swift
git commit -m "fix(shell): 保持连续同向分屏可见" -m "Refs #29"
```

### Task 3: 四方向菜单与窗口命令

**Files:**
- Modify: `Sources/InkShell/AppDelegate.swift`
- Modify: `Sources/InkShell/MainWindowController.swift`
- Modify: `Tests/InkShellTests/TerminalSplitCommandTests.swift`

**Interfaces:**
- Consumes: `PaneSplitDirection` 和 `TerminalTab.insertPane(_:splitting:direction:)`。
- Produces: `splitLeft(_:)`、`splitRight(_:)`、`splitUp(_:)`、`splitDown(_:)`。

- [ ] **Step 1: 写四方向菜单和插入位置的失败测试**

```swift
@Test("文件菜单提供四方向分屏且不声明复合快捷键")
func menuOffersFourDirectionsWithoutKeyEquivalent() throws {
    let menu = AppDelegate.makeMainMenu()
    let file = try #require(menu.items.first { $0.submenu?.title == "文件" }?.submenu)
    let actions = [
        #selector(MainWindowController.splitLeft(_:)),
        #selector(MainWindowController.splitRight(_:)),
        #selector(MainWindowController.splitUp(_:)),
        #selector(MainWindowController.splitDown(_:)),
    ]
    for action in actions {
        let item = try #require(file.items.first { $0.action == action })
        #expect(item.keyEquivalent.isEmpty)
    }
}
```

- [ ] **Step 2: 运行命令测试并确认缺少左右、上下完整动作**

Run: `swift test --filter TerminalSplitCommandTests`

Expected: FAIL，缺少 `splitLeft`、`splitUp`，或菜单仍绑定 `Command-D`。

- [ ] **Step 3: 实现四方向命令和尺寸校验**

四个 selector 调用统一的 `splitActivePane(direction:)`。左右方向检查列数，上下方向检查行数。预计网格尺寸只依赖 axis，插入顺序依赖 direction。

- [ ] **Step 4: 运行命令测试**

Run: `swift test --filter TerminalSplitCommandTests`

Expected: PASS。

- [ ] **Step 5: 提交四方向命令**

```bash
git add Sources/InkShell/AppDelegate.swift Sources/InkShell/MainWindowController.swift Tests/InkShellTests/TerminalSplitCommandTests.swift
git commit -m "feat(shell): 增加四方向分屏命令" -m "Refs #29"
```

### Task 4: Command-D 复合快捷键状态机

**Files:**
- Create: `Sources/InkShell/SplitShortcutState.swift`
- Modify: `Sources/InkShell/MainWindowController.swift`
- Create: `Tests/InkShellTests/SplitShortcutStateTests.swift`

**Interfaces:**
- Produces: `SplitShortcutState.handle(_:) -> SplitShortcutDecision`。
- Consumes: `PaneSplitDirection` 和 `splitActivePane(direction:)`。

- [ ] **Step 1: 写按下、方向、松开和取消的失败测试**

```swift
@Test("单独 Command-D 在 D 松开时默认向右")
func plainCommandDDefaultsRightOnKeyUp() {
    var state = SplitShortcutState()
    #expect(state.handle(.commandDDown(isRepeat: false)) == .consume)
    #expect(state.handle(.dUp) == .split(.right))
}

@Test("Command-D 加方向键只执行对应方向一次")
func chordUsesFirstDirectionOnce() {
    var state = SplitShortcutState()
    _ = state.handle(.commandDDown(isRepeat: false))
    #expect(state.handle(.direction(.up)) == .split(.up))
    #expect(state.handle(.direction(.left)) == .consume)
    #expect(state.handle(.dUp) == .consume)
}
```

- [ ] **Step 2: 运行状态机测试并确认类型不存在**

Run: `swift test --filter SplitShortcutStateTests`

Expected: FAIL，缺少状态机类型。

- [ ] **Step 3: 实现纯状态机**

```swift
enum SplitShortcutEvent: Equatable {
    case commandDDown(isRepeat: Bool)
    case direction(PaneSplitDirection)
    case dUp
    case cancel
}

enum SplitShortcutDecision: Equatable {
    case passThrough
    case consume
    case split(PaneSplitDirection)
}

struct SplitShortcutState {
    private enum Phase { case idle, pending, consumed }
    private var phase = Phase.idle

    mutating func handle(_ event: SplitShortcutEvent) -> SplitShortcutDecision {
        if event == .cancel {
            phase = .idle
            return .passThrough
        }
        switch (phase, event) {
        case (.idle, .commandDDown(isRepeat: false)):
            phase = .pending
            return .consume
        case (.pending, .commandDDown), (.consumed, .commandDDown):
            return .consume
        case let (.pending, .direction(direction)):
            phase = .consumed
            return .split(direction)
        case (.consumed, .direction):
            return .consume
        case (.pending, .dUp):
            phase = .idle
            return .split(.right)
        case (.consumed, .dUp):
            phase = .idle
            return .consume
        default:
            return .passThrough
        }
    }
}
```

- [ ] **Step 4: 把状态机接入窗口事件监视器**

窗口安装只处理本窗口的 `.keyDown`、`.keyUp` 和 `.flagsChanged` 本地监视器。D 的 keyCode 为 2，方向键为 123 到 126。只有第一响应者是当前 `TerminalMetalView`、设置页未显示且事件窗口匹配时才接管；窗口失焦、Command 提前松开和设置页打开时发送 `.cancel`。窗口关闭或控制器释放时移除监视器。

```swift
splitShortcutMonitor = NSEvent.addLocalMonitorForEvents(
    matching: [.keyDown, .keyUp, .flagsChanged]
) { [weak self] event in
    MainActor.assumeIsolated {
        self?.handleSplitShortcut(event) ?? event
    }
}
```

- [ ] **Step 5: 运行状态机与命令测试**

Run: `swift test --filter 'SplitShortcutStateTests|TerminalSplitCommandTests'`

Expected: PASS。

- [ ] **Step 6: 提交复合快捷键**

```bash
git add Sources/InkShell/SplitShortcutState.swift Sources/InkShell/MainWindowController.swift Tests/InkShellTests/SplitShortcutStateTests.swift
git commit -m "feat(shell): 用 Command-D 组合选择分屏方向" -m "Refs #29"
```

### Task 5: 完整验证与验证包

**Files:**
- Verify: `/private/tmp/ink-split-verify-30/Ink Split Verify.app`

**Interfaces:**
- Consumes: 完整四方向分屏实现。
- Produces: 可供用户验证的独立临时应用和更新后的 PR。

- [ ] **Step 1: 运行完整测试和 release 构建**

Run: `swift test && swift build -c release && git diff --check`

Expected: 全部测试通过，release 构建成功，diff 无空白错误。

- [ ] **Step 2: 重建独立验证包**

用当前分支 debug 二进制替换 `Ink Split Verify.app` 内的可执行文件，保持 bundle id `com.cheneychou.ink.split-verify-30`，重新 ad-hoc 签名并通过 `codesign --verify --deep --strict`。

- [ ] **Step 3: 做真实窗口检查**

从单 pane 开始依次验证：松开 `Command-D` 向右；按住 `Command-D` 加四个方向键；连续四次向下分屏全部可见；混合方向嵌套；拖动每条 divider；点击不同 pane 后用 `Command-W` 逐个收拢。

- [ ] **Step 4: 复核性能文档边界**

检查 `docs/perf.md` 仍明确区分单路高速输出和未完成的四路压力测试。本次不改性能口径，也不新增未经测量的数据。

- [ ] **Step 5: 推送并刷新 PR #30**

```bash
git push origin agent/issue-29-terminal-splits
gh pr view 30 --json state,mergeable,statusCheckRollup,url
```
