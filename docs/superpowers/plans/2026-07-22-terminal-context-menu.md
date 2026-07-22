# Terminal Context Menu Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** 为每个终端 pane 提供完整原生右键菜单，并以复用 ED 3 生命周期的本地冷路径安全清除当前 pane scrollback。

**Architecture:** `TerminalMetalView` 负责右键手势、菜单结构、复制粘贴和链接捕获；`TerminalWorkspaceViewController` 以 pane ID 注入查找、四方向分屏和清历史动作，`MainWindowController` 继续复用现有分屏实现。`Terminal.clearScrollback()` 与 CSI ED 3 共用清理主体，Workspace 在同一 MainActor 事务中重置视图瞬态并让搜索控制器推进 generation、取消旧任务、按当前 query 重扫。

**Tech Stack:** Swift 6、AppKit `NSMenu`/`NSMenuItemValidation`、SwiftPM、swift-testing、TerminalCore 值类型、Swift concurrency。

## Global Constraints

- 最低系统 macOS 14.0；不新增第三方依赖。
- `TerminalCore` 不得引入 AppKit 或 Metal。
- 不增加 Cell、RowInfo、ScrollbackLine 的字段或常驻对象。
- 不修改 Metal 帧循环或 grid 写入热路径；所有新逻辑均为用户触发冷路径。
- 用户菜单清历史不向 PTY 写 `ESC[3J`，不清 grid，不弹确认框。
- 粘贴必须进入现有 `SafePaste`；链接菜单必须捕获不可变 target。
- 开发阶段只运行本计划列出的 focused tests，不运行完整 `swift test` 或 `swift build`。
- 每项生产行为先观察对应测试因缺失功能失败，再写最小实现使其通过。
- 注释与文档用中文，标识符用英文；提交使用中文 Conventional Commit，并含 `Refs #78`。

---

## 文件结构

- `Sources/TerminalCore/Terminal.swift`：公开清除 scrollback 冷路径，并让 ED 3 调用同一主体。
- `Tests/TerminalCoreTests/TerminalTests.swift`：验证屏幕保留、ED 3 等价与 revision。
- `Tests/TerminalCoreTests/OSC8HyperlinkTests.swift`：验证历史清除后的 OSC 8 保留、重编号与回收。
- `Tests/TerminalCoreTests/CommandStatusTests.swift`：验证 OSC 133 overflow/完成记录清理与重编号。
- `Sources/InkTerminalView/TerminalLinkInteraction.swift`：定义视图层四方向上下文分屏枚举。
- `Sources/InkTerminalView/TerminalMetalView.swift`：构造完整菜单、校验、动作转发和清历史后的瞬态重置。
- `Tests/InkTerminalViewTests/TerminalLinkInteractionTests.swift`：验证普通/链接/TUI/Option/focus 菜单路径。
- `Tests/InkTerminalViewTests/SafePasteTests.swift`：保留 SafePaste 纯逻辑覆盖，不修改生产接口。
- `Sources/InkShell/TerminalSearchController.swift`：取消旧 generation 并按当前 query 重启。
- `Tests/InkShellTests/TerminalSearchWorkspaceTests.swift`：验证清历史期间旧结果不回写与当前查询重扫。
- `Sources/InkShell/TerminalSession.swift`：提供不写 PTY 的本地 Core 清理入口。
- `Sources/InkShell/TerminalWorkspaceViewController.swift`：按 pane 注入/路由菜单动作，协调清理事务。
- `Sources/InkShell/MainWindowController.swift`：接收 Workspace 分屏动作并复用现有 `splitActivePane`。
- `Tests/InkShellTests/TerminalWorkspaceTests.swift`：验证非活动 pane 聚焦和清理隔离。
- `Tests/InkShellTests/TerminalSplitCommandTests.swift`：验证上下文四方向分屏复用现有路径。
- `.superpowers/issue-78-report.md`：记录提交、RED/GREEN 命令、文件、自审和未执行验证。

---

### Task 1: TerminalCore 公共清历史 API 与 ED 3 单一主体

**Files:**
- Modify: `Tests/TerminalCoreTests/TerminalTests.swift`
- Modify: `Sources/TerminalCore/Terminal.swift`

**Interfaces:**
- Produces: `public mutating func Terminal.clearScrollback()`
- Preserves: `grid` 内容、光标、`modes`、scrollback capacity。
- Invalidates: 历史坐标和 `searchLayoutRevision`。
- Consumed by: Task 5 的 `TerminalSession.clearScrollback()`。

- [ ] **Step 1: 写屏幕保留与 revision 的失败测试**

在 `TerminalTests` 添加一个测试：用两行 grid 产生至少一行 scrollback，保存
`grid`、cursor、modes、capacity、revision，调用尚不存在的 `clearScrollback()`，
断言：

```swift
@Test("本地清历史保留当前屏幕并推进布局代次")
func clearScrollbackPreservesScreen() {
    var (parser, terminal) = makeTerminal(columns: 12, rows: 2, scrollback: 20)
    feed("old\r\nscreen one\r\nscreen two", &parser, &terminal)
    let grid = terminal.grid
    let modes = terminal.modes
    let revision = terminal.searchLayoutRevision

    terminal.clearScrollback()

    #expect(terminal.scrollback.count == 0)
    #expect(terminal.scrollback.totalAppendedLines == 0)
    #expect(terminal.scrollback.capacity == 20)
    #expect(terminal.grid == grid)
    #expect(terminal.modes == modes)
    #expect(terminal.searchLayoutRevision == revision + 1)
    #expect(terminal.takeResponses().isEmpty)
}
```

- [ ] **Step 2: 运行测试确认 RED**

Run: `swift test --filter TerminalTests.clearScrollbackPreservesScreen`

Expected: 编译失败，指出 `Terminal` 没有 `clearScrollback` 成员；失败原因必须是缺失
公共 API，而不是 fixture 或断言错误。

- [ ] **Step 3: 提取 ED 3 主体并公开冷路径**

在 `Terminal.swift` 的对外入口区增加：

```swift
public mutating func clearScrollback() {
    clearScrollbackPreservingScreen()
    pendingWrap = false
}
```

把 `eraseDisplay(mode: 3)` 当前 27 行逻辑原样移动到私有
`clearScrollbackPreservingScreen()`。`case 3` 只调用 `clearScrollback()`；其他 ED
模式不变。私有主体继续捕获 screen links、回收链接 store、重编号语义 overflow 和
completion、`scrollback.removeAll()`、重建 screen links、增加 revision。

- [ ] **Step 4: 运行 focused 测试确认 GREEN**

Run: `swift test --filter TerminalTests.clearScrollbackPreservesScreen`

Expected: PASS，且无新增 warning。

- [ ] **Step 5: 写 ED 3 与公共 API 等价失败测试**

从同一个 Terminal 值复制出 `direct` 和 `parsed`，前者调用公共 API，后者由 Parser
feed `\u{1B}[3J`，比较 scrollback、grid、revision 和模式：

```swift
@Test("公共清历史与 CSI ED 3 使用同一状态转换")
func directClearMatchesED3() {
    var (parser, terminal) = makeTerminal(columns: 12, rows: 2, scrollback: 20)
    feed("old\r\nvisible", &parser, &terminal)
    var direct = terminal
    var parsed = terminal
    var edParser = Parser()

    direct.clearScrollback()
    feed("\u{1B}[3J", &edParser, &parsed)

    #expect(direct.grid == parsed.grid)
    #expect(direct.scrollback.count == parsed.scrollback.count)
    #expect(direct.scrollback.totalAppendedLines == parsed.scrollback.totalAppendedLines)
    #expect(direct.searchLayoutRevision == parsed.searchLayoutRevision)
    #expect(direct.modes == parsed.modes)
}
```

为了证明测试能失败，先暂时让 `case 3` 保留旧内联实现但不推进同一路径中可观察的
测试计数不可取；本步应在 Step 3 前与第一个测试一并写入并观察编译 RED，随后共同
GREEN。计划执行时两条测试在同一首轮 RED 中加入，避免伪造第二次失败。

- [ ] **Step 6: 运行 Core focused suite**

Run: `swift test --filter TerminalTests`

Expected: `TerminalTests` 全部 PASS。

- [ ] **Step 7: 提交 Core API**

```bash
git add Sources/TerminalCore/Terminal.swift Tests/TerminalCoreTests/TerminalTests.swift
git commit -m "core(terminal): 统一本地与 ED 3 清历史路径" \
  -m "公开保留屏幕的冷路径，避免菜单通过 PTY 伪造终端输出。" \
  -m "Refs #78"
```

---

### Task 2: OSC 8 与 OSC 133 旁路生命周期回归

**Files:**
- Modify: `Tests/TerminalCoreTests/OSC8HyperlinkTests.swift`
- Modify: `Tests/TerminalCoreTests/CommandStatusTests.swift`
- Modify if tests expose a defect: `Sources/TerminalCore/Terminal.swift`

**Interfaces:**
- Consumes: `Terminal.clearScrollback()` from Task 1。
- Guarantees: 保留 screen 的 OSC 8/OSC 133 状态并以新 scrollback 基址重编号；删除
  仅属于历史的稀疏记录与引用。

- [ ] **Step 1: 写 OSC 8 失败回归测试**

构造历史链接和 screen 链接后调用公共 API。保存 screen link target，断言历史消失、
新绝对行 0/1 可命中 screen link、store 和 target 计数只含保留片段：

```swift
@Test("清历史回收旧 OSC 8 并把屏上链接重编号")
func clearScrollbackRebasesVisibleHyperlinks() throws {
    var terminal = Terminal(size: TerminalSize(columns: 20, rows: 2), scrollbackCapacity: 20)
    var parser = Parser()
    feedOSC8("https://old.test", text: "old\r\n", parser: &parser, terminal: &terminal)
    feedOSC8("https://screen.test", text: "screen", parser: &parser, terminal: &terminal)
    #expect(terminal.scrollback.count > 0)

    terminal.clearScrollback()

    #expect(terminal.scrollback.count == 0)
    #expect(try #require(terminal.link(at: TextPosition(line: 0, column: 0))).target
        == "https://screen.test")
    #expect(terminal.explicitHyperlinkRecordCount == 1)
}
```

- [ ] **Step 2: 写 OSC 133/completion 失败回归测试**

创建一个完整历史命令，再在 screen 区制造完整命令（用现有 `handleOSC133` 测试
helper 或 parser 字节），调用 clear，断言历史命令块消失、screen command range 从
line 0 开始、completion 仍绑定保留命令、内部 record count 没有历史项。

- [ ] **Step 3: 运行测试确认 RED 或已有主体覆盖**

Run: `swift test --filter 'OSC8HyperlinkTests.clearScrollbackRebasesVisibleHyperlinks|CommandStatusTests.clearScrollbackRebasesVisibleCommandState'`

Expected: 如果 Task 1 的既有 ED 3 主体完整，两项可以直接 PASS。此处属于对迁移主体
的特征测试：若 PASS，记录为已有生命周期的 characterization，不写多余生产代码；
若 FAIL，必须是保留/重编号计数不符，并进入下一步最小修复。

- [ ] **Step 4: 仅在 RED 时修复旁路重建**

修复限制在 `clearScrollbackPreservingScreen()`：先捕获可见片段，以旧
`gridBase` 过滤/rebase语义和完成记录，清 buffer，再重建片段。不得给 cell/line
加字段，不得遍历历史文本。若备用屏测试暴露 `savedPrimaryHyperlinks` 坐标失效，
用相同“物理 fragment 捕获 → 释放 → 基址归零后重建”处理保存的主屏 store，并保持
target 引用计数平衡。

- [ ] **Step 5: 运行旁路 focused suites**

Run: `swift test --filter 'OSC8HyperlinkTests|CommandStatusTests'`

Expected: 两个 suite 全部 PASS。

- [ ] **Step 6: 提交旁路测试/修复**

```bash
git add Sources/TerminalCore/Terminal.swift \
  Tests/TerminalCoreTests/OSC8HyperlinkTests.swift \
  Tests/TerminalCoreTests/CommandStatusTests.swift
git commit -m "test(terminal): 锁定清历史旁路重编号" \
  -m "覆盖 OSC 8、OSC 133 与命令完成记录，防止屏幕保留时遗留旧坐标。" \
  -m "Refs #78"
```

若生产代码有修复，把前缀改为 `fix(terminal)`。

---

### Task 3: TerminalMetalView 完整原生菜单与本地校验

**Files:**
- Modify: `Sources/InkTerminalView/TerminalLinkInteraction.swift`
- Modify: `Sources/InkTerminalView/TerminalMetalView.swift`
- Modify: `Tests/InkTerminalViewTests/TerminalLinkInteractionTests.swift`

**Interfaces:**
- Produces: `public enum TerminalContextSplitDirection { case left, right, up, down }`
- Produces callbacks:
  `public var onFind: (() -> Void)?`、
  `public var onSplit: ((TerminalContextSplitDirection) -> Void)?`、
  `public var onClearScrollback: (() -> Void)?`。
- Produces: `public func scrollbackDidClear()`。
- Preserves: `copy(_:)`、`paste(_:)`、`openLink(_:)`、`copyLink(_:)` selectors。

- [ ] **Step 1: 写普通位置完整菜单的失败测试**

把 `TerminalLinkInteractionTests` 的菜单辅助断言抽成 title 数组（包含 `"—"` 表示
separator），在无链接 Terminal 上 right-down，断言 presenter 收到：

```swift
["拷贝", "粘贴", "—", "查找…", "—",
 "向左分屏", "向右分屏", "向上分屏", "向下分屏",
 "—", "清除滚动缓冲区"]
```

给三个 Shell callback 赋空闭包，确保它们可启用；未设置选区时拷贝禁用。

- [ ] **Step 2: 写剪贴板与 focus 失败测试**

新增可替换 `pasteboardReader`，分别返回 nil、空字符串和 `"text"`，断言粘贴前两者
禁用、最后一个启用。给 `view.onFocus` 计数，在 `contextMenuPresenter` 内断言计数已
增加，证明菜单显示前聚焦。

- [ ] **Step 3: 扩展链接/TUI 测试期望**

修改已有 Option 链接测试：链接菜单 titles 应为链接组 + separator + 完整通用菜单；
新增无链接、mouse reporting 的 Option+右键，断言菜单出现且 down/up 都不增加
`onInput` bytes。普通 TUI right down/up 仍产生 bytes 且不显示菜单。

- [ ] **Step 4: 运行测试确认 RED**

Run: `swift test --filter TerminalLinkInteractionTests`

Expected: FAIL，普通位置 presenter 未调用、完整菜单项不存在、pasteboard reader 和
callbacks 尚未定义。

- [ ] **Step 5: 实现方向枚举和注入点**

在 `TerminalLinkInteraction.swift` 添加 public、Sendable、Equatable 枚举。在
`TerminalMetalView` 顶部输入闭包旁增加三个 public callback，并增加内部：

```swift
var pasteboardReader: () -> String? = {
    NSPasteboard.general.string(forType: .string)
}
```

`paste(_:)` 和菜单校验都用 reader；`paste(text:)` 保持不变。

- [ ] **Step 6: 提取菜单构造方法**

新增 `private func makeContextMenu(link: TerminalLink?) -> NSMenu`，设置
`autoenablesItems = false`，按设计顺序添加 items。为 Shell 项创建 view-local
selectors：

```swift
@objc private func findFromContextMenu(_ sender: Any?) { onFind?() }
@objc private func splitFromContextMenu(_ sender: NSMenuItem) { /* 读取 representedObject */ }
@objc private func clearScrollbackFromContextMenu(_ sender: Any?) { onClearScrollback?() }
```

方向用稳定 raw string 或包装值放入 representedObject；不要让 selector 动态查询
鼠标位置。链接项继续把 target 字符串放入 representedObject。

- [ ] **Step 7: 统一 right-down 路由与 down/up 状态**

先将 `rightMouseReportsToTUI = false`，计算 router action：

- report：设 true，调用 `reportMouse(... press, button: 2)` 并 return；
- menu：`window?.makeFirstResponder(self)`，捕获可选 link，构造并 present。

right-up 只在 `rightMouseReportsToTUI == true` 时上报 release，随后立即清 flag。
Option menu 分支从不置 true，因此不发孤立 release。

- [ ] **Step 8: 完整校验**

`validateMenuItem` 增加：paste 要求 reader 返回非空字符串；find/clear 要求 callback；
split 要求 callback 且当前 grid 对应轴达到 20 列/6 行；open link 要求 payload URL
和 `onOpenLink`；copy link 要求捕获字符串。构造菜单后显式给每一项
`isEnabled = validateMenuItem(item)`，因为菜单关闭 auto-enable。

- [ ] **Step 9: 运行视图 focused suite 确认 GREEN**

Run: `swift test --filter TerminalLinkInteractionTests`

Expected: 全部 PASS，普通和链接位置菜单结构稳定，TUI/Option bytes 符合预期。

- [ ] **Step 10: 提交完整菜单**

```bash
git add Sources/InkTerminalView/TerminalLinkInteraction.swift \
  Sources/InkTerminalView/TerminalMetalView.swift \
  Tests/InkTerminalViewTests/TerminalLinkInteractionTests.swift
git commit -m "feat(terminal): 补齐原生右键菜单" \
  -m "普通位置提供复制粘贴与 Shell 动作入口，同时保留 TUI mouse 和不可变链接目标。" \
  -m "Refs #78"
```

---

### Task 4: 视图清历史瞬态重置

**Files:**
- Modify: `Tests/InkTerminalViewTests/TerminalCommandActionTests.swift`
- Modify: `Tests/InkTerminalViewTests/TerminalLinkInteractionTests.swift`
- Modify: `Sources/InkTerminalView/TerminalMetalView.swift`

**Interfaces:**
- Produces: `public func TerminalMetalView.scrollbackDidClear()`。
- Resets: scrollOffset、scrollAccumulator、selection/anchor、search arrays/index、
  commandNavigationAnchor、hoveredLink/cell、right-click report state。

- [ ] **Step 1: 写命令锚点和滚动选区失败测试**

在 command action tests 先导航到历史命令，确认 anchor 存在；通过 search reveal 或
滚轮 helper 让 offset 非零；建立测试可见选区后调用 `scrollbackDidClear()`，断言
`commandNavigationLine == nil`、`searchScrollOffset == 0`、复制 selector 校验 false。

- [ ] **Step 2: 写 hover 清理失败测试**

在 link tests 先 mouseMoved 命中链接，调用 `scrollbackDidClear()`，断言
`hoveredLinkForTesting == nil`，并且下一帧允许按新 Terminal 重新命中。

- [ ] **Step 3: 运行 focused tests 确认 RED**

Run: `swift test --filter 'TerminalCommandActionTests|TerminalLinkInteractionTests'`

Expected: 编译失败，缺少 `scrollbackDidClear()`；失败点只来自新 API。

- [ ] **Step 4: 实现单一瞬态重置入口**

在 `resetTransientState()` 附近增加公共方法，明确不清 `markedText` 与 provider：

```swift
public func scrollbackDidClear() {
    scrollOffset = 0
    scrollAccumulator = 0
    selection = nil
    selectionAnchor = nil
    searchResults.removeAll(keepingCapacity: false)
    currentSearchIndex = nil
    commandNavigationAnchor = nil
    hoveredLink = nil
    hoveredCell = nil
    rightMouseReportsToTUI = false
    window?.invalidateCursorRects(for: self)
    markDirty()
}
```

注意 `markDirty()` 会把 `hoverNeedsRefresh` 设 true；这正是清理后重新按当前鼠标位置
命中的所需行为。

- [ ] **Step 5: 运行 focused tests 确认 GREEN**

Run: `swift test --filter 'TerminalCommandActionTests|TerminalLinkInteractionTests'`

Expected: 两个 suite 全部 PASS。

- [ ] **Step 6: 提交视图重置**

```bash
git add Sources/InkTerminalView/TerminalMetalView.swift \
  Tests/InkTerminalViewTests/TerminalCommandActionTests.swift \
  Tests/InkTerminalViewTests/TerminalLinkInteractionTests.swift
git commit -m "fix(terminal): 清历史时丢弃旧视图坐标" \
  -m "同步归零滚动、选区、命令锚点与链接悬停，避免旧历史坐标继续生效。" \
  -m "Refs #78"
```

---

### Task 5: 搜索 generation 重置与当前查询重扫

**Files:**
- Modify: `Tests/InkShellTests/TerminalSearchWorkspaceTests.swift`
- Modify: `Sources/InkShell/TerminalSearchController.swift`

**Interfaces:**
- Produces: `func TerminalSearchController.terminalHistoryDidClear()`。
- Preserves: private `query` 字符串和搜索栏。
- Guarantees: 旧 task 不能 publish；非空 query 从全新 index 扫清理后 snapshot。

- [ ] **Step 1: 写当前 query 自动重扫失败测试**

建立同时含历史 `hit old` 与 screen `hit visible` 的 Terminal，启动查询并等待首次
结果。调用 `terminal.clearScrollback()` 和尚不存在的
`controller.terminalHistoryDidClear()`，立即断言 matches 清空，等待 pending update，
断言只剩 screen 匹配且坐标基于零历史。

- [ ] **Step 2: 写旧 generation 不回写失败测试**

给 controller 增加仅测试可用的 scan hook 不应成为生产 API。优先用足够大的 snapshot
启动异步 query 后立即清 Terminal 并调用 history clear；等待全部 pending，断言结果
不包含历史-only 查询。若测试无法确定性制造顺序，在 controller initializer 增加
internal `searchUpdate` async 闭包，默认调用真实 index update；测试用 continuation
卡住第一代、让第二代完成，再释放第一代。该闭包只在 Shell 冷路径，不影响 Core。

- [ ] **Step 3: 运行搜索 focused suite 确认 RED**

Run: `swift test --filter TerminalSearchWorkspaceTests`

Expected: 编译失败，缺少 history clear API；或旧 generation 测试暴露陈旧结果。

- [ ] **Step 4: 实现 history clear 入口**

提取小型 `cancelPendingUpdate()` 仅在能减少重复时使用；方法执行：

```swift
func terminalHistoryDidClear() {
    updateGeneration &+= 1
    updateTask?.cancel()
    updateTask = nil
    refreshScheduled = false
    refreshRequestedWhileSearching = false
    index.clear()
    currentIndex = nil
    publish(reveal: false)
    guard !query.isEmpty else { return }
    startBackgroundUpdate(
        terminal: terminalProvider().snapshotForSearch(),
        startingIndex: TerminalSearchIndex(), query: query,
        chooseNearest: true, reveal: true, debounce: false
    )
}
```

`startBackgroundUpdate` 现有 cancellation + generation guard 保持；不得删除任何一个
guard。注意该函数自身再推进一次 generation 是允许的，最终 task 捕获最新值。

- [ ] **Step 5: 运行搜索 focused suite确认 GREEN**

Run: `swift test --filter TerminalSearchWorkspaceTests`

Expected: 全部 PASS，旧任务无回写，当前 query 自动发布 screen 匹配。

- [ ] **Step 6: 提交搜索生命周期**

```bash
git add Sources/InkShell/TerminalSearchController.swift \
  Tests/InkShellTests/TerminalSearchWorkspaceTests.swift
git commit -m "fix(search): 清历史后重启当前查询" \
  -m "推进 generation 并取消旧扫描，避免旧 snapshot 在坐标归零后回写。" \
  -m "Refs #78"
```

---

### Task 6: TerminalSession 与 Workspace 按 pane 协调动作

**Files:**
- Modify: `Sources/InkShell/TerminalSession.swift`
- Modify: `Sources/InkShell/TerminalWorkspaceViewController.swift`
- Modify: `Sources/InkShell/MainWindowController.swift`
- Modify: `Tests/InkShellTests/TerminalWorkspaceTests.swift`
- Modify: `Tests/InkShellTests/TerminalSplitCommandTests.swift`

**Interfaces:**
- Produces: `public func TerminalSession.clearScrollback()`。
- Produces Workspace callback:
  `var onSplitPane: ((PaneID, PaneSplitDirection) -> Void)?`。
- Produces Workspace methods:
  `func clearScrollback(in paneID: PaneID)` 与 menu injection helpers。
- Consumes: Tasks 1、3、4、5 的所有 API。

- [ ] **Step 1: 写多 pane 清理隔离失败测试**

创建两个 pane，各用 `session.consumeOutput` 产生不同历史和 screen；构建 Workspace。
从第一个非活动 view 的 `onClearScrollback` 触发动作，断言：

- tab.activePaneID 变成第一个；
- 第一个 scrollback count 为 0 且 grid 不变；
- 第二个 scrollback count 不变；
- 第一个 view offset/command/hover 已走 reset。

- [ ] **Step 2: 写上下文查找聚焦失败测试**

创建两个 pane，让第二个活动，调用第一个 view 的 `onFind`，断言
`activeSearchPaneID == first.id` 且搜索栏只有一个。测试不依赖真实鼠标窗口。

- [ ] **Step 3: 写四方向分屏转发失败测试**

在 Workspace 层给 `onSplitPane` 记录 `(PaneID, PaneSplitDirection)`；分别触发 view
四方向 callback，断言捕获 pane 始终是该 view 所属 pane，方向映射完整。
在 `TerminalSplitCommandTests` 增加窗口集成：触发非活动 view 的右/下菜单动作后，
pane count 增加且新分屏围绕点击 pane，而不是先前活动 pane。

- [ ] **Step 4: 运行 Shell focused tests 确认 RED**

Run: `swift test --filter 'TerminalWorkspaceTests|TerminalSplitCommandTests'`

Expected: 编译失败，Workspace 尚未注入 callbacks/session API；失败原因与缺失接口一致。

- [ ] **Step 5: 实现不写 PTY 的 Session 入口**

在 `TerminalSession` 增加：

```swift
public func clearScrollback() {
    terminal.clearScrollback()
    onUpdate?()
}
```

不调用 `write`，不访问 private `pty`。测试通过 grid/scrollback 与 onUpdate 证明行为。

- [ ] **Step 6: 注入 Workspace callbacks**

在 `makeView` leaf 分支中设置：

```swift
terminalView.onFind = { [weak self] in self?.find(in: paneID) }
terminalView.onSplit = { [weak self] direction in
    self?.requestSplit(paneID, direction: direction)
}
terminalView.onClearScrollback = { [weak self] in
    self?.clearScrollback(in: paneID)
}
```

`find` 和 `requestSplit` 先 `activate(paneID)`。方向 switch 映射到 Shell
`PaneSplitDirection` 后调用 `onSplitPane?(paneID, direction)`。clear 查当前 tab/pane，
激活后调用 session API、view reset，并在 activeSearchPaneID 相等时调用 controller
history clear。`clearViews()` 置空全部新增 callbacks 和 Workspace `onSplitPane` 的
生命周期由 owner 管理。

- [ ] **Step 7: MainWindow 复用既有分屏函数**

初始化 Workspace callbacks 的位置增加：

```swift
workspaceVC.onSplitPane = { [weak self] paneID, direction in
    guard let self else { return }
    self.workspaceVC.activate(paneID)
    self.splitActivePane(direction: direction)
}
```

不要复制 `splitActivePane` 的尺寸、cwd、失败 terminate、布局保存逻辑。上下文视图
已经激活 pane，paneID guard 是第二道防线。

- [ ] **Step 8: 运行 Shell focused tests 确认 GREEN**

Run: `swift test --filter 'TerminalWorkspaceTests|TerminalSplitCommandTests|TerminalSearchWorkspaceTests'`

Expected: 三个 suite 全部 PASS；分屏、搜索和清历史都绑定点击 pane。

- [ ] **Step 9: 运行 TerminalView 相关 focused 回归**

Run: `swift test --filter 'TerminalLinkInteractionTests|TerminalCommandActionTests|SafePasteTests'`

Expected: 全部 PASS，SafePaste 无回归。

- [ ] **Step 10: 提交 Shell 协调**

```bash
git add Sources/InkShell/TerminalSession.swift \
  Sources/InkShell/TerminalWorkspaceViewController.swift \
  Sources/InkShell/MainWindowController.swift \
  Tests/InkShellTests/TerminalWorkspaceTests.swift \
  Tests/InkShellTests/TerminalSplitCommandTests.swift
git commit -m "feat(shell): 将右键动作绑定点击 pane" \
  -m "Shell 按 pane 注入查找分屏和清历史，并在同一事务重置视图与搜索。" \
  -m "Refs #78"
```

---

### Task 7: Focused 汇总、自审与交接报告

**Files:**
- Create: `.superpowers/issue-78-report.md`
- Modify only if verification exposes defect: files from Tasks 1–6 and corresponding test first。

**Interfaces:**
- Produces: root agent 可独立核验的实现/测试/concern 记录。

- [ ] **Step 1: 运行 Core focused 汇总**

Run: `swift test --filter 'TerminalTests|OSC8HyperlinkTests|CommandStatusTests'`

Expected: 全部 PASS。

- [ ] **Step 2: 运行 TerminalView focused 汇总**

Run: `swift test --filter 'TerminalLinkInteractionTests|TerminalCommandActionTests|SafePasteTests'`

Expected: 全部 PASS。

- [ ] **Step 3: 运行 Shell focused 汇总**

Run: `swift test --filter 'TerminalWorkspaceTests|TerminalSplitCommandTests|TerminalSearchWorkspaceTests'`

Expected: 全部 PASS。

- [ ] **Step 4: 自审 diff 与格式**

Run:

```bash
git diff --check origin/main..HEAD
git diff --stat origin/main..HEAD
git log --oneline origin/main..HEAD
git diff origin/main..HEAD -- \
  Sources/TerminalCore Sources/InkTerminalView Sources/InkShell \
  Tests/TerminalCoreTests Tests/InkTerminalViewTests Tests/InkShellTests
```

逐项核对规格验收：菜单结构、禁用状态、TUI/Option、pane 聚焦、无 PTY 清理、
旁路 rebase、search generation、视图瞬态、无 cell/line/依赖/热路径变化。

- [ ] **Step 5: 写报告**

`.superpowers/issue-78-report.md` 必须包含：

- 规格与计划路径、对应提交；
- 所有阶段提交 hash/subject；
- 分层实现摘要；
- 每轮 RED 命令、实际失败原因、GREEN 命令和结果；
- 修改/新增文件列表；
- `origin/main..HEAD` 自审结论与 `git diff --check`；
- 明确未运行完整 `swift test`、`swift build`、Instruments、最终 review；
- concerns 或“无已知 concern”。

- [ ] **Step 6: 提交报告与必要测试修订**

```bash
git add .superpowers/issue-78-report.md
git commit -m "docs(terminal): 记录右键菜单验证证据" \
  -m "汇总 focused TDD、差异自审和待统一执行的最终验证。" \
  -m "Refs #78"
```

- [ ] **Step 7: 最终状态检查**

Run: `git status --short --branch`

Expected: 分支为 `agent/issue-78-terminal-context-menu`，工作树干净。不要 push、
不要创建 PR、不要 merge、不要运行完整测试或构建；把报告路径与 focused test 摘要
交给 root agent。

