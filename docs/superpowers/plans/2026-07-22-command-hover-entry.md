# Command Hover Entry Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** 为完整 OSC 133 命令块的首行增加按需出现的原生悬停按钮与命令操作菜单，同时保持链接、选择、TUI 鼠标及热路径语义。

**Architecture:** `InkTerminalView` 新增纯值 `CommandHoverTarget` 与解析器，用稳定行号和 `searchLayoutRevision` 在动作执行时重验命令身份。`TerminalMetalView` 复用现有 tracking area，在真实鼠标跨行的冷路径按需解析命令，并用一个隐藏的 AppKit `NSButton` 弹出 `NSMenu`；终端更新只隐藏入口，不在 frame tick 中重扫。

**Tech Stack:** Swift 6、AppKit `NSButton` / `NSMenu`、TerminalCore OSC 133 命令块、swift-testing、SwiftPM。

## Global Constraints

- 最低系统保持 macOS 14.0。
- `TerminalCore` 不得引入 AppKit 或 Metal。
- `Cell` 保持 8 字节，`RowInfo` 保持 2 字节，不增加 per-cell / per-line 常驻字段。
- renderer、grid、PTY 输出和 frame tick 热路径不得调用 `commandBlocks()`。
- 入口仅在完整命令块的命令首行出现，不改变 grid 列数、PTY 尺寸或分屏布局。
- 链接反馈优先；TUI mouse mode 下只有 Option 显式手势允许显示入口。
- 所有注释、规格与计划使用中文；代码标识符使用英文。
- 每个提交使用中文 Conventional Commit，并在正文末尾写 `Refs #80`。
- 开发阶段只运行本计划列出的 focused tests；不运行完整 suite、`swift build`、Instruments、push、PR 或 merge。

---

## File Structure

- Create `Sources/InkTerminalView/TerminalCommandHover.swift`
  - 保存稳定命令目标、菜单 payload 和无 AppKit 状态依赖的命令解析逻辑。
- Modify `Sources/InkTerminalView/TerminalMetalView.swift`
  - 管理单个瞬态 `NSButton`、hover 生命周期、TUI/link 优先级、菜单与动作路由。
- Create `Tests/InkTerminalViewTests/TerminalCommandHoverResolverTests.swift`
  - 验证稳定目标、环淘汰、reflow 与邻接命令解析。
- Create `Tests/InkTerminalViewTests/TerminalCommandHoverTests.swift`
  - 通过真实 `NSEvent` 和 AppKit view 验证按钮、菜单、动作和冲突语义。
- Modify `Tests/InkTerminalViewTests/TerminalCommandActionTests.swift`
  - 仅在现有 helper 需要模块内复用时调整；不改变既有命令动作预期。
- Create `.superpowers/issue-80-report.md`
  - 最终记录提交、focused tests、未执行门禁和已知并发冲突。

---

### Task 1: 稳定命令目标与解析器

**Files:**
- Create: `Tests/InkTerminalViewTests/TerminalCommandHoverResolverTests.swift`
- Create: `Sources/InkTerminalView/TerminalCommandHover.swift`

**Interfaces:**
- Consumes: `Terminal.commandBlocks() -> [CommandBlock]`、`Terminal.scrollback.totalAppendedLines`、`Terminal.scrollback.count`、`Terminal.searchLayoutRevision`。
- Produces: `CommandHoverTarget`、`CommandHoverResolution`、`CommandHoverResolver.target(startingAt:in:)`、`CommandHoverResolver.resolve(_:in:)`、`CommandHoverMenuPayload`。

- [ ] **Step 1: 写目标命中与零命令 RED 测试**

创建测试 suite，构造两条完整 OSC 133 命令，断言只有 `commandRange.start.line` 能生成目标，普通行和无标记终端返回 nil：

```swift
import Testing
import TerminalCore
@testable import InkTerminalView

@Suite("命令悬停目标")
struct TerminalCommandHoverResolverTests {
    @Test("只有完整命令首行生成目标")
    func resolvesOnlyCommandStartLine() throws {
        let terminal = makeHoverTerminal()
        let block = try #require(terminal.commandBlocks().first)

        #expect(CommandHoverResolver.target(
            startingAt: block.commandRange.start.line,
            in: terminal
        ) != nil)
        #expect(CommandHoverResolver.target(
            startingAt: block.commandRange.start.line + 1,
            in: terminal
        ) == nil)

        var plain = Terminal(size: .init(columns: 30, rows: 4))
        var parser = Parser()
        parser.feed(Array("plain".utf8), handler: &plain)
        #expect(CommandHoverResolver.target(startingAt: 0, in: plain) == nil)
    }
}
```

- [ ] **Step 2: 运行 resolver 测试并确认因 API 缺失失败**

Run: `swift test --filter TerminalCommandHoverResolverTests`

Expected: 编译失败，明确报告找不到 `CommandHoverResolver`，而不是 fixture 或语法错误。

- [ ] **Step 3: 实现最小稳定目标解析**

创建：

```swift
import Foundation
import TerminalCore

struct CommandHoverTarget: Sendable, Equatable {
    let commandStartLineID: UInt64
    let layoutRevision: UInt64
}

struct CommandHoverResolution: Sendable, Equatable {
    let block: CommandBlock
    let previous: CommandBlock?
    let next: CommandBlock?
}

final class CommandHoverMenuPayload: NSObject {
    let target: CommandHoverTarget

    init(target: CommandHoverTarget) {
        self.target = target
    }
}

enum CommandHoverResolver {
    static func target(startingAt line: Int, in terminal: Terminal) -> CommandHoverTarget? {
        guard terminal.commandBlocks().contains(where: {
            $0.commandRange.start.line == line
        }) else { return nil }
        let oldestLineID = terminal.scrollback.totalAppendedLines
            - UInt64(terminal.scrollback.count)
        return CommandHoverTarget(
            commandStartLineID: oldestLineID + UInt64(line),
            layoutRevision: terminal.searchLayoutRevision
        )
    }

    static func resolve(
        _ target: CommandHoverTarget,
        in terminal: Terminal
    ) -> CommandHoverResolution? {
        guard target.layoutRevision == terminal.searchLayoutRevision else { return nil }
        let oldestLineID = terminal.scrollback.totalAppendedLines
            - UInt64(terminal.scrollback.count)
        guard target.commandStartLineID >= oldestLineID else { return nil }
        let line = Int(target.commandStartLineID - oldestLineID)
        guard line < terminal.totalLines else { return nil }
        let blocks = terminal.commandBlocks()
        guard let index = blocks.firstIndex(where: {
            $0.commandRange.start.line == line
        }) else { return nil }
        return CommandHoverResolution(
            block: blocks[index],
            previous: index > blocks.startIndex ? blocks[index - 1] : nil,
            next: index + 1 < blocks.endIndex ? blocks[index + 1] : nil
        )
    }
}
```

- [ ] **Step 4: 运行 resolver 测试并确认首个行为转绿**

Run: `swift test --filter TerminalCommandHoverResolverTests`

Expected: 1 test passes，0 failures。

- [ ] **Step 5: 写环淘汰与布局失效 RED 测试**

追加三个测试：目标之前的历史被淘汰后仍解析同一命令；目标本身被淘汰后返回 nil；`resize` 改变 revision 后返回 nil。每个测试都比较解析后的命令文本：

```swift
@Test("前置历史淘汰后稳定目标仍指向同一命令")
func survivesEarlierEviction() throws {
    var parser = Parser()
    var terminal = Terminal(
        size: .init(columns: 30, rows: 3),
        scrollbackCapacity: 5
    )
    parser.feed(Array("old0\r\nold1\r\nold2\r\n".utf8), handler: &terminal)
    parser.feed(Array(command("keep", output: "value").utf8), handler: &terminal)
    let block = try #require(terminal.commandBlocks().last)
    let target = try #require(CommandHoverResolver.target(
        startingAt: block.commandRange.start.line,
        in: terminal
    ))
    let oldestBefore = terminal.scrollback.totalAppendedLines
        - UInt64(terminal.scrollback.count)

    parser.feed(Array("tail0\r\ntail1\r\n".utf8), handler: &terminal)

    let oldestAfter = terminal.scrollback.totalAppendedLines
        - UInt64(terminal.scrollback.count)
    #expect(oldestAfter > oldestBefore)
    let resolved = try #require(CommandHoverResolver.resolve(target, in: terminal))
    #expect(terminal.extractText(in: resolved.block.commandRange) == "keep")
}

@Test("命令被环淘汰后目标失效")
func invalidatesEvictedTarget() throws {
    var parser = Parser()
    var terminal = Terminal(
        size: .init(columns: 30, rows: 2),
        scrollbackCapacity: 2
    )
    parser.feed(Array(command("old", output: "value").utf8), handler: &terminal)
    let block = try #require(terminal.commandBlocks().first)
    let target = try #require(CommandHoverResolver.target(
        startingAt: block.commandRange.start.line,
        in: terminal
    ))

    parser.feed(Array("a\r\nb\r\nc\r\nd\r\n".utf8), handler: &terminal)

    #expect(CommandHoverResolver.resolve(target, in: terminal) == nil)
}

@Test("reflow 后旧目标失效")
func invalidatesReflowedTarget() throws {
    var terminal = makeHoverTerminal()
    let block = try #require(terminal.commandBlocks().first)
    let target = try #require(CommandHoverResolver.target(
        startingAt: block.commandRange.start.line,
        in: terminal
    ))

    terminal.resize(to: .init(columns: 12, rows: 6))

    #expect(CommandHoverResolver.resolve(target, in: terminal) == nil)
}
```

- [ ] **Step 6: 运行并确认 RED 原因是边界 fixture 揭示的解析缺口**

Run: `swift test --filter TerminalCommandHoverResolverTests`

Expected: 新测试至少一个失败，失败值直接显示 target 生命周期不符合预期；若最小实现已自然满足某条，保留该覆盖并让下一条邻接测试承担 RED。

- [ ] **Step 7: 修正 resolver 边界并增加相邻命令断言**

保持目标只含两个整数，不缓存 `CommandBlock` 或文本。补充测试断言中间命令的
`previous` 与 `next` 分别解析到相邻命令，并让实现只调用一次 `commandBlocks()` 完成
当前、上一条和下一条解析。

- [ ] **Step 8: 运行 resolver focused tests**

Run: `swift test --filter TerminalCommandHoverResolverTests`

Expected: 全部 resolver tests pass，0 failures。

- [ ] **Step 9: 提交纯逻辑解析器**

```bash
git add Sources/InkTerminalView/TerminalCommandHover.swift \
  Tests/InkTerminalViewTests/TerminalCommandHoverResolverTests.swift
git commit -m "feat(command): 稳定悬停命令目标" \
  -m "用行 ID 与布局代次避免环淘汰和 reflow 后误操作相同绝对坐标。" \
  -m "Refs #80"
```

---

### Task 2: 瞬态 AppKit 入口与冲突优先级

**Files:**
- Create: `Tests/InkTerminalViewTests/TerminalCommandHoverTests.swift`
- Modify: `Sources/InkTerminalView/TerminalMetalView.swift`

**Interfaces:**
- Consumes: Task 1 的 `CommandHoverResolver.target(startingAt:in:)` 和 `CommandHoverTarget`。
- Produces: 标识为 `ink.command-hover` 的瞬态 `NSButton`、真实 mouse move 驱动的 show/hide 生命周期、`commandMenuPresenter` 注入点。

- [ ] **Step 1: 写普通命令首行显示、离开隐藏的 RED 测试**

测试创建真实 `NSWindow` 与 `TerminalMetalView`，发送第一行及下一行 `.mouseMoved`
事件，通过 view hierarchy 查找 identifier 为 `ink.command-hover` 的 `NSButton`：

```swift
@Test("进入和离开命令首行切换轻量入口")
func togglesEntryOnCommandStartLine() throws {
    let terminal = makeCommandHoverTerminal(mouseReporting: false)
    let (window, view) = makeCommandHoverWindow(terminal: { terminal })

    view.mouseMoved(with: try hoverEvent(in: window, row: 0))
    let button = try #require(commandHoverButton(in: view))
    #expect(!button.isHidden)

    view.mouseMoved(with: try hoverEvent(in: window, row: 1))
    #expect(button.isHidden)
}
```

- [ ] **Step 2: 运行并确认 RED**

Run: `swift test --filter TerminalCommandHoverTests`

Expected: 测试失败，因为 view 中不存在 `ink.command-hover` 按钮。

- [ ] **Step 3: 添加单例隐藏按钮与行对齐布局**

在 `TerminalMetalView` 增加 lazy `NSButton`，设置：

```swift
button.identifier = NSUserInterfaceItemIdentifier("ink.command-hover")
button.image = NSImage(systemSymbolName: "ellipsis.circle", accessibilityDescription: "命令操作")
button.imagePosition = .imageOnly
button.bezelStyle = .accessoryBarAction
button.toolTip = "命令操作"
button.setAccessibilityLabel("命令操作")
button.isHidden = true
```

增加 `hoveredCommandTarget`、`commandHoverExaminedLine`、
`hoveredCommandVisualRow`。只有 `mouseMoved` 传入 `allowCommandHover: true`；
`refreshHoverFromWindow` 仍只刷新链接并隐藏命令入口。按钮 frame 使用 renderer cell
height、visual row、view bounds 和 `InkDesignTokens.Spacing.sm` 计算。

- [ ] **Step 4: 运行并确认基础 show/hide 转绿**

Run: `swift test --filter TerminalCommandHoverTests`

Expected: 基础入口测试 pass。

- [ ] **Step 5: 写零命令、链接优先和 TUI Option gate RED 测试**

追加测试：

```swift
@Test("没有命令记录不显示入口")
func noCommandsHideEntry() throws

@Test("链接命中优先于同一命令首行入口")
func linkHoverWins() throws

@Test("TUI 鼠标模式仅 Option 显示原生入口")
func optionOverridesMouseReporting() throws
```

第三个测试先发送无 Option `.mouseMoved` 并断言隐藏，再发送 `.option` 并断言显示；
同时记录 `onInput`，mouse move 本身不得产生新输入字节。

- [ ] **Step 6: 运行并确认 RED 是优先级尚未实现**

Run: `swift test --filter TerminalCommandHoverTests`

Expected: link 或 TUI gate 测试失败，基础按钮测试仍 pass。

- [ ] **Step 7: 实现链接与 TUI 优先级**

在同一次 `updateHover` 中先解析现有链接。只有 `link == nil` 且
`terminal.modes.mouseMode == .none || modifiers.contains(.option)` 时才解析命令首行；
否则隐藏按钮并清空 examined line，使鼠标离开链接或按下 Option 后能在同一行重新
解析。

- [ ] **Step 8: 写终端更新、滚动、选择和 transient reset 失效 RED 测试**

分别显示按钮后调用 `markDirty()`、发送 `scrollWheel`、发送 `.leftMouseDown`、调用
`resetTransientState()`，断言按钮立即隐藏。另断言 `markDirty()` 后固定鼠标不触发
自动重新显示，直到下一次真实 `mouseMoved`。

- [ ] **Step 9: 运行并确认 RED**

Run: `swift test --filter TerminalCommandHoverTests`

Expected: 至少一个生命周期测试失败，证明现有更新路径未统一清理入口。

- [ ] **Step 10: 集中实现 `hideCommandHover()` 生命周期**

让 `markDirty()`、`scrollWheel`、`mouseDown`、`mouseDragged`、`keyDown`、
`resetTransientState()`、`mouseExited` 和 view 离开 window 调用同一隐藏函数。
`layout()` 只在 target 仍存在时重排按钮，不扫描 Terminal。

- [ ] **Step 11: 运行 hover 与链接 focused tests**

Run:

```bash
swift test --filter TerminalCommandHoverTests
swift test --filter TerminalLinkInteractionTests
```

Expected: 两个 suites 全部 pass；现有链接鼠标和 Option 右键行为不变。

- [ ] **Step 12: 提交瞬态入口**

```bash
git add Sources/InkTerminalView/TerminalMetalView.swift \
  Tests/InkTerminalViewTests/TerminalCommandHoverTests.swift
git commit -m "feat(command): 按需显示命令悬停入口" \
  -m "复用系统按钮并让链接与 TUI 鼠标优先，终端更新只隐藏入口而不进入扫描热路径。" \
  -m "Refs #80"
```

---

### Task 3: 捕获目标菜单与动作路由

**Files:**
- Modify: `Tests/InkTerminalViewTests/TerminalCommandHoverTests.swift`
- Modify: `Sources/InkTerminalView/TerminalMetalView.swift`
- Modify: `Tests/InkTerminalViewTests/TerminalCommandActionTests.swift` only if shared fixture visibility is needed.

**Interfaces:**
- Consumes: `CommandHoverMenuPayload`、`CommandHoverResolver.resolve(_:in:)`、现有 `revealCommand(_:in:)` 与 `pasteboardWriter`。
- Produces: `showCommandHoverMenu(_:)`、`navigateToHoveredPreviousCommand(_:)`、`navigateToHoveredNextCommand(_:)`、`copyHoveredCommand(_:)`、`copyHoveredCommandOutput(_:)`。

- [ ] **Step 1: 写菜单结构与 enable 状态 RED 测试**

注入 `commandMenuPresenter` 捕获菜单，悬停第一条和中间一条命令后点击按钮，断言标题
顺序为：

```swift
["上一条命令", "下一条命令", "", "拷贝命令", "拷贝命令输出"]
```

第一条命令的上一条禁用，中间命令的上下条均启用；无 outputRange 时“拷贝命令
输出”禁用。

- [ ] **Step 2: 运行并确认 RED**

Run: `swift test --filter TerminalCommandHoverTests`

Expected: 编译或断言失败，因为 `commandMenuPresenter` 与菜单 action 尚不存在。

- [ ] **Step 3: 实现菜单创建和不可变 payload**

增加可替换 presenter：

```swift
var commandMenuPresenter: (NSMenu, NSView, NSPoint) -> Void = { menu, view, point in
    menu.popUp(positioning: nil, at: point, in: view)
}
```

按钮 action 读取当前 `hoveredCommandTarget`，立即 resolve；失败则隐藏并返回。为每个
item 创建独立 `CommandHoverMenuPayload(target:)`，设置显式 target 为 view、关闭
`autoenablesItems`，用同一 resolution 设置 enabled。菜单 point 取按钮 frame 的左下
位置。

- [ ] **Step 4: 运行并确认菜单测试转绿**

Run: `swift test --filter TerminalCommandHoverTests`

Expected: 菜单结构和 enable tests pass。

- [ ] **Step 5: 写精确拷贝目标与陈旧 payload RED 测试**

构造至少两条命令，将鼠标悬停第一条但让 viewport 最近命令是第二条。执行捕获菜单的
“拷贝命令”和“拷贝命令输出”，断言 pasteboard writer 收到第一条内容。保存菜单项
后对 Terminal 执行 reflow，再调用旧菜单 action，断言没有新增 pasteboard write。

- [ ] **Step 6: 运行并确认 RED**

Run: `swift test --filter TerminalCommandHoverTests`

Expected: 动作 API 缺失或仍复制 viewport 最近命令，测试失败原因与目标捕获一致。

- [ ] **Step 7: 实现执行时重验的拷贝动作**

每个 action 从 sender 的 payload 取 target，调用当前 `terminalProvider` 与 resolver；
失败则隐藏并返回。成功时对 `resolution.block.commandRange` 或 outputRange 调用
`terminal.extractText` 和现有 `writeToPasteboard`，不修改普通 selection。

- [ ] **Step 8: 写相对导航 RED 测试**

悬停中间命令后执行上一条 / 下一条菜单项，断言 `commandNavigationLine` 分别落在
解析结果的 previous / next 首行，而不是以旧导航锚点或 viewport 为基准。

- [ ] **Step 9: 运行并确认 RED**

Run: `swift test --filter TerminalCommandHoverTests`

Expected: 导航 selector 缺失或位置不符，测试失败。

- [ ] **Step 10: 实现相对导航**

用 resolver 返回的 `previous` / `next`，存在时调用现有 `revealCommand`；动作执行时
仍重验 payload。不要改写 `navigateToPreviousCommand()` 与
`navigateToNextCommand()` 的现有快捷键语义。

- [ ] **Step 11: 运行全部命令入口 focused tests**

Run:

```bash
swift test --filter TerminalCommandHoverResolverTests
swift test --filter TerminalCommandHoverTests
swift test --filter TerminalCommandActionTests
swift test --filter TerminalLinkInteractionTests
swift test --filter CommandBlockTests
```

Expected: 所有命令 hover、既有命令动作、链接交互和 Core 命令块 tests pass。

- [ ] **Step 12: 提交菜单动作**

```bash
git add Sources/InkTerminalView/TerminalMetalView.swift \
  Tests/InkTerminalViewTests/TerminalCommandHoverTests.swift \
  Tests/InkTerminalViewTests/TerminalCommandActionTests.swift
git commit -m "feat(command): 路由悬停命令菜单动作" \
  -m "菜单携带不可变命令身份并在执行时重验，避免 reflow 或历史淘汰后误拷贝。" \
  -m "Refs #80"
```

若 `TerminalCommandActionTests.swift` 未实际修改，不加入 `git add`。

---

### Task 4: Focused 验证与实施报告

**Files:**
- Create: `.superpowers/issue-80-report.md`

**Interfaces:**
- Consumes: 前三项提交与 fresh focused test 输出。
- Produces: Issue #80 独立 agent 报告，供后续统一 suite、build、Instruments 和总评审使用。

- [ ] **Step 1: 检查范围和结构不变量**

Run:

```bash
git diff origin/main...HEAD --check
git diff origin/main...HEAD --stat
rg -n "AppKit|Metal" Sources/TerminalCore
rg -n "CommandHover|commandHover" Sources/TerminalCore Sources/InkTerminalView
```

Expected: diff check 无输出；TerminalCore 没有新增 AppKit/Metal 或 CommandHover；实现只
出现在 TerminalView 冷路径。

- [ ] **Step 2: Fresh 运行全部允许的 focused tests**

Run:

```bash
swift test --filter TerminalCommandHoverResolverTests
swift test --filter TerminalCommandHoverTests
swift test --filter TerminalCommandActionTests
swift test --filter TerminalLinkInteractionTests
swift test --filter CommandBlockTests
```

Expected: 每条命令 exit 0，0 failures；记录 suite/test 数和任何 warning。

- [ ] **Step 3: 核对提交与工作区状态**

Run:

```bash
git log --oneline origin/main..HEAD
git status --short --branch
```

Expected: 只有 Issue #80 的规格、计划和实现提交；报告创建前除报告外无未提交文件。

- [ ] **Step 4: 写实施报告**

报告必须包含：

```markdown
# Issue #80 独立实现报告

## 范围
## 提交
## Focused tests
## 未执行门禁
## 已知冲突与集成提示
## 性能与内存边界
```

“未执行门禁”明确列出完整 `swift test`、`swift build`、Instruments、总评审、push、PR、
merge 均按上游要求未运行。“已知冲突”列出 `TerminalMetalView.swift` 与并发原生右键
菜单工作的潜在合并冲突，以及双方必须保留的 TUI Option、链接优先和菜单 presenter
边界。

- [ ] **Step 5: 校验并提交报告**

Run: `git diff --check`

Expected: 无输出。

```bash
git add .superpowers/issue-80-report.md
git commit -m "docs(command): 记录命令悬停入口验证" \
  -m "汇总独立实现提交、focused tests 与并发集成边界，供统一门禁继续验证。" \
  -m "Refs #80"
```

- [ ] **Step 6: 最终只读核对**

Run:

```bash
git status --short --branch
git log --oneline origin/main..HEAD
```

Expected: 工作区干净，分支仍为 `agent/issue-80-command-hover`，没有 push/PR/merge。

---

## Self-Review

- Spec coverage: 命中、消失、动作路由、坐标失效、零命令、链接、TUI mouse、选择和
  热路径边界分别由 Task 1–3 覆盖。
- Placeholder scan: 计划不含待定 API；测试 fixture 的具体 OSC 133 字节、selector、
  identifier、菜单标题和 focused commands 均已锁定。
- Type consistency: `CommandHoverTarget`、`CommandHoverResolution`、
  `CommandHoverResolver` 与 `CommandHoverMenuPayload` 在 Task 1 产生，Task 2–3 只消费
  同名接口。
- Phase independence: Task 1 是可测试纯逻辑；Task 2 交付只显示/隐藏的可用入口；
  Task 3 在其上增加完整菜单动作。每项提交均可独立编译验证和回滚。
