# Terminal Splits Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** 在一个标签内提供可递归嵌套、可拖动、按焦点关闭的左右与上下终端分屏。

**Architecture:** `TerminalTab` 保存纯数据 `PaneLayout` 和多个 `TerminalSession`，`TerminalWorkspaceViewController` 把当前标签的布局递归映射为 `NSSplitView` 与 `TerminalMetalView`。后台标签只保留 PTY 和终端状态，不保留 Metal 视图；`MainWindowController` 管理项目、标签和菜单 action。

**Tech Stack:** Swift 6、AppKit、CAMetalLayer、Swift Testing、Darwin PTY / libproc、SwiftPM。

## Global Constraints

- 最低系统 macOS 14.0。
- `TerminalCore` 不得依赖 AppKit 或 Metal。
- 不新增第三方依赖。
- 用户可见产品名使用 `Ink`，代码模块名使用 `ink`。
- 注释和文档使用中文，代码标识符使用英文。
- 常用规模按 1 到 4 个可见 pane 验收，布局结构不设置固定数量上限。
- 不修改 `TerminalRenderer.buildInstances` 等渲染热路径。
- 实现范围以 `docs/superpowers/specs/2026-07-20-terminal-splits-design.md` 为准。

---

### Task 1: PaneLayout 纯模型

**Files:**
- Create: `Sources/InkShell/PaneLayout.swift`
- Create: `Tests/InkShellTests/PaneLayoutTests.swift`

**Interfaces:**
- Produces: `PaneID`、`SplitID`、`PaneSplitAxis`、`PaneLayout.split(...)`、`PaneLayout.removing(...)`、`PaneLayout.updatingRatio(...)`、`PaneLayout.contains(...)`。
- Consumes: Foundation `UUID`，不依赖视图、PTY 或 Metal。

- [ ] **Step 1: 写分割、嵌套删除、比例更新和接替焦点的失败测试**

```swift
@Test("关闭嵌套叶节点后提升兄弟子树并选择靠近分隔线的 pane")
func removingNestedLeafPromotesSibling() throws {
    let left = PaneID()
    let top = PaneID()
    let bottom = PaneID()
    var layout = PaneLayout.leaf(left)
    layout.split(target: left, newPane: top, axis: .leftRight)
    layout.split(target: top, newPane: bottom, axis: .topBottom)

    let result = try #require(layout.removing(top))
    #expect(result.layout.contains(bottom))
    #expect(result.focusPaneID == bottom)
}
```

- [ ] **Step 2: 运行测试并确认因类型不存在而失败**

Run: `swift test --filter PaneLayoutTests`

Expected: FAIL，提示找不到 `PaneLayout` 或相关接口。

- [ ] **Step 3: 实现递归值模型**

```swift
struct PaneRemoval: Equatable {
    var layout: PaneLayout?
    var focusPaneID: PaneID?
}

indirect enum PaneLayout: Equatable {
    case leaf(PaneID)
    case split(id: SplitID, axis: PaneSplitAxis, ratio: Double,
               first: PaneLayout, second: PaneLayout)
}
```

分割只替换目标叶节点；删除叶节点时返回提升后的兄弟节点，并用兄弟子树靠近原 divider 的叶节点作为 `focusPaneID`；比例限定在 `0...1`。

- [ ] **Step 4: 运行模型测试**

Run: `swift test --filter PaneLayoutTests`

Expected: PASS。

- [ ] **Step 5: 提交模型**

```bash
git add Sources/InkShell/PaneLayout.swift Tests/InkShellTests/PaneLayoutTests.swift
git commit -m "feat(shell): 建立可递归收拢的分屏布局模型" -m "Refs #29"
```

### Task 2: 前台进程工作目录

**Files:**
- Modify: `Sources/InkPTY/PTYSession.swift`
- Modify: `Sources/InkShell/TerminalSession.swift`
- Modify: `Package.swift`
- Create: `Tests/InkPTYTests/PTYSessionTests.swift`

**Interfaces:**
- Produces: `PTYSession.foregroundWorkingDirectory() -> String?`、`TerminalSession.foregroundWorkingDirectory() -> String?`。
- Consumes: 当前 PTY master fd、`tcgetpgrp`、macOS `proc_pidinfo`。

- [ ] **Step 1: 写未启动与子进程退出后返回 nil 的失败测试**

```swift
@Test("未启动的 PTY 没有前台工作目录")
func unstartedPTYHasNoWorkingDirectory() {
    #expect(PTYSession().foregroundWorkingDirectory() == nil)
}
```

- [ ] **Step 2: 运行测试并确认缺少接口**

Run: `swift test --filter PTYSessionTests`

Expected: FAIL，提示 `PTYSession` 没有该成员。

- [ ] **Step 3: 用 libproc 实现只读查询并在 TerminalSession 透传**

```swift
public func foregroundWorkingDirectory() -> String? {
    guard masterFD >= 0 else { return nil }
    let pid = tcgetpgrp(masterFD)
    guard pid > 0 else { return nil }
    var info = proc_vnodepathinfo()
    let size = proc_pidinfo(pid, PROC_PIDVNODEPATHINFO, 0, &info,
                            Int32(MemoryLayout<proc_vnodepathinfo>.stride))
    guard size == MemoryLayout<proc_vnodepathinfo>.stride else { return nil }
    // 从 pvi_cdir.vip_path 解码，并确认仍是目录。
}
```

- [ ] **Step 4: 运行 PTY 测试和构建**

Run: `swift test --filter PTYSessionTests && swift build`

Expected: PASS，构建零警告。

- [ ] **Step 5: 提交目录查询**

```bash
git add Package.swift Sources/InkPTY/PTYSession.swift Sources/InkShell/TerminalSession.swift Tests/InkPTYTests/PTYSessionTests.swift
git commit -m "feat(pty): 允许分屏继承前台进程目录" -m "Refs #29"
```

### Task 3: TerminalTab 生命周期模型

**Files:**
- Create: `Sources/InkShell/TerminalTab.swift`
- Create: `Tests/InkShellTests/TerminalTabTests.swift`
- Modify: `Sources/InkShell/Project.swift`

**Interfaces:**
- Produces: `TerminalPane`、`TerminalTab`、`TerminalTab.activePane`、`TerminalTab.insertPane(...)`、`TerminalTab.removePane(...)`。
- Consumes: Task 1 的布局模型和现有 `TerminalSession`。

- [ ] **Step 1: 写活动 pane、插入和删除的失败测试**

测试通过可注入的 pane/session 包装避免启动真实 shell，并覆盖关闭非活动 pane 后保持焦点、关闭活动 pane 后迁移焦点、最后一个 pane 返回空标签。

- [ ] **Step 2: 运行测试并确认失败**

Run: `swift test --filter TerminalTabTests`

Expected: FAIL，提示缺少 `TerminalTab`。

- [ ] **Step 3: 实现标签与 pane 容器并把 Project.sessions 改为 Project.tabs**

```swift
@MainActor
final class TerminalTab {
    var layout: PaneLayout
    private(set) var panes: [PaneID: TerminalPane]
    var activePaneID: PaneID
    var customName: String?
}
```

删除返回被移除的 `TerminalPane`，但不自行终止 PTY，终止顺序由窗口控制器统一管理。

- [ ] **Step 4: 运行标签模型测试**

Run: `swift test --filter TerminalTabTests`

Expected: PASS。

- [ ] **Step 5: 提交标签模型**

```bash
git add Sources/InkShell/Project.swift Sources/InkShell/TerminalTab.swift Tests/InkShellTests/TerminalTabTests.swift
git commit -m "refactor(shell): 分离标签布局与终端会话" -m "Refs #29"
```

### Task 4: 递归分屏工作区

**Files:**
- Create: `Sources/InkShell/TerminalWorkspaceViewController.swift`
- Create: `Tests/InkShellTests/TerminalWorkspaceTests.swift`
- Modify: `Sources/InkTerminalView/TerminalMetalView.swift`

**Interfaces:**
- Produces: `TerminalWorkspaceViewController.show(tab:config:)`、`clear()`、`view(for:)`、`onActivatePane`、`onRatioChange`。
- Consumes: Task 1/3 的布局模型、`TerminalMetalView.onFocus`。

- [ ] **Step 1: 写左右/上下视图树、比例恢复和活动边框的失败测试**

```swift
let splitViews = allSubviews(in: workspace.view).compactMap { $0 as? NSSplitView }
#expect(splitViews.count == 2)
#expect(splitViews.contains { $0.isVertical })
#expect(splitViews.contains { !$0.isVertical })
```

- [ ] **Step 2: 运行测试并确认失败**

Run: `swift test --filter TerminalWorkspaceTests`

Expected: FAIL，提示缺少工作区控制器。

- [ ] **Step 3: 实现递归 NSSplitView 和 pane wrapper**

每个分支控制器保存 `SplitID`，在 `splitViewDidResizeSubviews` 计算实际比例并回调；每个叶节点配置 terminal provider、输入、resize、焦点和当前边框。`clear()` 必须解除所有闭包，保证旧视图树释放。

- [ ] **Step 4: 运行工作区测试**

Run: `swift test --filter TerminalWorkspaceTests`

Expected: PASS。

- [ ] **Step 5: 提交工作区**

```bash
git add Sources/InkShell/TerminalWorkspaceViewController.swift Sources/InkTerminalView/TerminalMetalView.swift Tests/InkShellTests/TerminalWorkspaceTests.swift
git commit -m "feat(shell): 用原生分隔线渲染递归终端布局" -m "Refs #29"
```

### Task 5: 主窗口命令与生命周期

**Files:**
- Modify: `Sources/InkShell/MainWindowController.swift`
- Modify: `Sources/InkShell/AppDelegate.swift`
- Modify: `Sources/InkShell/TabBarView.swift`
- Create: `Tests/InkShellTests/TerminalSplitCommandTests.swift`
- Modify: `Tests/InkShellTests/SettingsWindowTests.swift`

**Interfaces:**
- Produces: `splitRight(_:)`、`splitDown(_:)`、`closeActivePane(_:)`。
- Consumes: `TerminalTab`、工作区控制器、PTY 目录查询和当前配置。

- [ ] **Step 1: 写快捷键、关闭 pane、关闭标签和 shell 退出的失败测试**

验证菜单中 `d` 的 modifier 分别为 Command 与 Command+Shift，`w` 指向 `closeActivePane(_:)`。控制器测试覆盖分屏后 pane 数变化、最后一个 pane 删除标签、标签关闭按钮终止全部 pane。

- [ ] **Step 2: 运行 Shell 测试并确认失败**

Run: `swift test --filter InkShellTests`

Expected: FAIL，提示 action 或标签接口尚未迁移。

- [ ] **Step 3: 把 MainWindowController 从 sessions 迁移到 tabs**

`Command-T` 创建单 pane 标签；分屏先启动新 PTY，再修改布局；`Command-W` 从布局移除当前 pane 后解除回调并终止；tab bar 标题使用标签自定义名和活动 pane OSC 标题；设置页期间禁用分屏和 pane 关闭 action。

- [ ] **Step 4: 运行 Shell 测试和构建**

Run: `swift test --filter InkShellTests && swift build`

Expected: PASS，构建零警告。

- [ ] **Step 5: 提交窗口集成**

```bash
git add Sources/InkShell Sources/InkTerminalView/TerminalMetalView.swift Tests/InkShellTests
git commit -m "feat(shell): 接通标签内分屏快捷键与焦点关闭" -m "Refs #29"
```

### Task 6: 完整验证与性能记录

**Files:**
- Modify: `docs/perf.md`

**Interfaces:**
- Consumes: 完整应用和设计文档规定的 1 pane / 4 pane 验收口径。
- Produces: 可复核的测试、构建、内存和 Instruments 结果。

- [ ] **Step 1: 运行完整测试**

Run: `swift test`

Expected: 全部 PASS。

- [ ] **Step 2: 运行 release 构建**

Run: `swift build -c release`

Expected: 成功且零警告。

- [ ] **Step 3: 实机验证交互**

启动 Ink，依次验证右分屏、下分屏、嵌套分屏、双向拖动、焦点边框、目录继承、关闭非末 pane、关闭末 pane 和标签关闭按钮。

- [ ] **Step 4: 记录性能数据**

按设计文档口径采集 1 pane 和 4 pane footprint，并用 Instruments Time Profiler / Metal System Trace 验证四 pane 同时输出。把硬件、系统、窗口、负载和结果写入 `docs/perf.md`。

- [ ] **Step 5: 提交验证记录**

```bash
git add docs/perf.md
git commit -m "perf(shell): 记录四分屏资源开销" -m "Refs #29"
```

- [ ] **Step 6: 请求代码评审并修正发现**

按 `superpowers:requesting-code-review` 检查 Issue 验收标准、分层、资源生命周期、测试覆盖和 diff 范围，修正后重新运行 `swift test` 与 `swift build -c release`。

- [ ] **Step 7: 推送并创建 PR**

PR 标题：`feat(shell): 支持标签内递归终端分屏`

PR 描述包含改动说明、验证、性能数据、风险、文档与 `Closes #29`，不创建版本标签。
