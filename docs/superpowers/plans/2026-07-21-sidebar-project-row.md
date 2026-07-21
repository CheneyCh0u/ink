# Sidebar Project Row Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** 让长目录项目以“项目名 + 可省略父路径 + 固定标签状态”显示，并保证关闭按钮 hover、点击重建和退出时文字布局不抖动。

**Architecture:** `Project` 负责从目录 URL 生成稳定的展示字段，`MainWindowController` 把标题、父路径、备注、状态和完整路径组装进侧边栏行模型。`ProjectRowView` 使用固定关闭按钮槽位和可压缩的父路径列；悬停只改变按钮透明度与交互状态，不增删 Auto Layout 内容。

**Tech Stack:** Swift 6、AppKit、SwiftPM、swift-testing；最低 macOS 14.0。

## Global Constraints

- `TerminalCore` 不得引入 AppKit 或 Metal 依赖。
- 外壳 UI 优先使用系统控件和系统字体，不新增第三方依赖。
- 用户可见产品名使用 `Ink`；代码标识符使用英文，注释和文档使用中文。
- 本改动不进入 Metal、grid 或 scrollback 热路径，无需 Instruments 采样。
- 复用 Issue #41、分支 `agent/issue-41-sidebar-long-path-jitter` 和 PR #43；不合并、不发布。

---

## File Structure

- `Sources/InkShell/Project.swift`：从项目目录派生项目名与父路径。
- `Sources/InkShell/MainWindowController.swift`：把项目展示字段和标签状态传给侧边栏。
- `Sources/InkShell/SidebarViewController.swift`：定义行展示模型和稳定的两行 AppKit 布局。
- `Sources/InkDesign/InkDesignTokens.swift`：定义关闭按钮固定槽位宽度。
- `Tests/InkShellTests/ProjectSidebarTests.swift`：覆盖路径派生、截断配置和跨状态布局稳定性。

### Task 1: 项目路径展示字段

**Files:**
- Modify: `Sources/InkShell/Project.swift`
- Test: `Tests/InkShellTests/ProjectSidebarTests.swift`

**Interfaces:**
- Consumes: `Project.directory: URL`、`Project.displayName: String`
- Produces: `Project.sidebarTitle: String`、`Project.sidebarParentPath: String`

- [x] **Step 1: 写路径派生失败测试**

在 `ProjectSidebarTests` 增加：

```swift
@Test("项目侧边栏拆分最终目录名与父路径")
@MainActor
func projectSidebarPathComponents() {
    let project = Project(
        directory: URL(fileURLWithPath: "/Users/cheney/work/code/wiselaw/wise-studio")
    )
    #expect(project.sidebarTitle == "wise-studio")
    #expect(project.sidebarParentPath == "~/work/code/wiselaw")
}

@Test("用户主目录在侧边栏继续显示波浪号")
@MainActor
func homeProjectSidebarPath() {
    let project = Project(directory: FileManager.default.homeDirectoryForCurrentUser)
    #expect(project.sidebarTitle == "~")
    #expect(project.sidebarParentPath.isEmpty)
}
```

- [x] **Step 2: 运行测试确认 RED**

Run: `swift test --filter ProjectSidebarTests`

Expected: FAIL，编译器报告 `Project` 没有 `sidebarTitle` 和 `sidebarParentPath`。

- [x] **Step 3: 实现最小路径派生**

在 `Project` 中增加：

```swift
var sidebarTitle: String {
    if directory.standardizedFileURL
        == FileManager.default.homeDirectoryForCurrentUser.standardizedFileURL {
        return "~"
    }
    return directory.lastPathComponent
}

var sidebarParentPath: String {
    guard sidebarTitle != "~" else { return "" }
    return (directory.deletingLastPathComponent().path as NSString)
        .abbreviatingWithTildeInPath
}
```

- [x] **Step 4: 运行路径测试确认 GREEN**

Run: `swift test --filter ProjectSidebarTests`

Expected: 两项新增路径测试 PASS。

- [x] **Step 5: 提交路径展示字段**

```bash
git add Sources/InkShell/Project.swift Tests/InkShellTests/ProjectSidebarTests.swift
git commit -m "fix(sidebar): 拆分项目名与父路径" \
  -m "长路径不再作为主标题参与项目行布局，为固定宽度截断提供稳定的展示字段。

Refs #41"
```

### Task 2: 固定宽度的两行项目布局

**Files:**
- Modify: `Sources/InkDesign/InkDesignTokens.swift`
- Modify: `Sources/InkShell/MainWindowController.swift`
- Modify: `Sources/InkShell/SidebarViewController.swift`
- Test: `Tests/InkShellTests/ProjectSidebarTests.swift`

**Interfaces:**
- Consumes: `Project.sidebarTitle`、`Project.sidebarParentPath`、`Project.note`、`Project.tabs.count`
- Produces: `SidebarViewController.Row(title:detail:status:fullPath:active:pinned:label:)`
- Produces: `InkDesignTokens.Sidebar.projectCloseButtonWidth: CGFloat`

- [x] **Step 1: 用真实行坐标重写长路径回归测试**

把旧测试重命名为 `longPathUsesStableProjectNameLayout`，显示名保持
`点击长目录时项目文字区域保持稳定`，并将测试模型改为：

```swift
let row = SidebarViewController.Row(
    title: "wise-studio",
    detail: "~/work/code/very-long-parent-directory/wiselaw",
    status: "1 个标签",
    fullPath: "~/work/code/very-long-parent-directory/wiselaw/wise-studio",
    active: false,
    pinned: true,
    label: .red
)
```

从项目行后代视图按字符串取得 `title`、`detail`、`status` 和关闭按钮，并使用：

```swift
func frameInRow(_ view: NSView, row: NSView) -> NSRect {
    view.convert(view.bounds, to: row)
}
```

记录初始三个文本 frame，依次调用 `mouseEntered`、以 `active: true` 的同内容 row 执行 `reload`、调用 `mouseExited`。每个阶段断言：

```swift
#expect(frameInRow(title, row: rowView) == initialTitleFrame)
#expect(frameInRow(detail, row: rowView) == initialDetailFrame)
#expect(frameInRow(status, row: rowView) == initialStatusFrame)
#expect(detail.lineBreakMode == .byTruncatingHead)
#expect(status.frame.width >= status.intrinsicContentSize.width - 0.5)
```

同时断言关闭按钮 `isHidden == false` 始终成立，初始和退出时 `alphaValue == 0`、悬停和重建后 `alphaValue == 1`。

- [x] **Step 2: 运行布局测试确认 RED**

Run: `swift test --filter ProjectSidebarLayoutTests.longPathUsesStableProjectNameLayout`

Expected: FAIL，因为 `Row` 还没有 `detail`、`status`、`fullPath`，关闭按钮也仍通过 `isHidden` 参与/退出布局。

- [x] **Step 3: 增加关闭按钮槽位 token**

在 `InkDesignTokens.Sidebar` 增加：

```swift
public static let projectCloseButtonWidth: CGFloat = 18
```

- [x] **Step 4: 扩展行模型并传入项目展示数据**

将 `SidebarViewController.Row` 改为：

```swift
struct Row {
    let title: String
    let detail: String
    let status: String
    let fullPath: String
    let active: Bool
    let pinned: Bool
    let label: InkProjectLabel
}
```

在 `MainWindowController.refreshChrome()` 中构造：

```swift
let status = project.tabs.isEmpty ? "未打开" : "\(project.tabs.count) 个标签"
return SidebarViewController.Row(
    title: project.sidebarTitle,
    detail: project.note ?? project.sidebarParentPath,
    status: status,
    fullPath: project.displayName,
    active: !isShowingSettings && index == activeProjectIndex,
    pinned: project.pinned,
    label: project.label
)
```

同步更新测试 fixture 的 `Row` 初始化参数。

- [x] **Step 5: 实现稳定的文字列与关闭按钮槽位**

展开态使用以下结构：

```swift
toolTip = row.fullPath

let title = NSTextField(labelWithString: row.title)
title.lineBreakMode = .byTruncatingTail

let detail = NSTextField(labelWithString: row.detail)
detail.lineBreakMode = .byTruncatingHead
detail.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)

let status = NSTextField(labelWithString: row.status)
status.setContentCompressionResistancePriority(.required, for: .horizontal)
status.setContentHuggingPriority(.required, for: .horizontal)

let metadataStack = NSStackView(views: [detail, status])
metadataStack.orientation = .horizontal
metadataStack.spacing = InkDesignTokens.Spacing.xs

let textStack = NSStackView(views: [title, metadataStack])
textStack.orientation = .vertical
textStack.alignment = .leading
textStack.spacing = 1
textStack.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)

closeButton.isHidden = false
closeButton.widthAnchor.constraint(
    equalToConstant: InkDesignTokens.Sidebar.projectCloseButtonWidth
).isActive = true
```

水平栈改为 `[indicator, icon, textStack, closeButton]`，移除空 spacer。增加统一按钮状态方法：

```swift
private func setCloseButtonRevealed(_ revealed: Bool) {
    closeButton.alphaValue = revealed ? 1 : 0
    closeButton.isEnabled = revealed
    closeButton.setAccessibilityHidden(!revealed)
}
```

`mouseEntered` 调用 `setCloseButtonRevealed(true)`，`mouseExited` 调用 `setCloseButtonRevealed(false)`；使用 `hoveredRowPath` 以跨 reload 恢复关闭图标本身，并避免同名项目互相影响。

- [x] **Step 6: 运行侧边栏测试确认 GREEN**

Run: `swift test --filter ProjectSidebarLayoutTests`

Expected: 布局 suite 全部 PASS；长路径测试证明三个文本 frame 跨 hover、reload、exit 不变。

- [x] **Step 7: 运行 Shell 测试并提交布局修复**

Run: `swift test --filter InkShellTests`

Expected: PASS，零失败。

```bash
git add Sources/InkDesign/InkDesignTokens.swift \
  Sources/InkShell/MainWindowController.swift \
  Sources/InkShell/SidebarViewController.swift \
  Tests/InkShellTests/ProjectSidebarTests.swift
git commit -m "fix(sidebar): 固定长路径项目行布局" \
  -m "项目名与父路径分层显示，并为标签状态和关闭按钮保留固定宽度，避免 hover 与点击重建改变可见文字。

Refs #41"
```

### Task 3: 完整验证与真实进程验收

**Files:**
- Verify only; no source changes expected

**Interfaces:**
- Consumes: Task 1、Task 2 的提交
- Produces: PR #43 的可评审验证证据

- [x] **Step 1: 运行完整自动验证**

Run: `swift test && swift build && git diff --check`

Expected: 167 项或更多测试全部 PASS，构建零警告，diff check 无输出。

- [x] **Step 2: 重启当前分支构建产物**

先用 `ps -axo pid=,args=` 定位并退出旧 Ink 进程，再运行：

```bash
/Users/cheney/work/code/ink/.build/arm64-apple-macosx/debug/ink
```

再次用 `ps` 确认进程路径精确指向上述产物。

- [x] **Step 3: 执行真实 UI 检查清单**

在 `~/work/code/wiselaw/wise-studio` 项目行验证：

1. 主标题固定为 `wise-studio`。
2. 父路径从头部显示省略号，右侧 `1 个标签` 完整可见。
3. 指针进入、点击选中、移出时，标题、父路径、状态、图标均不横移。
4. 关闭按钮只改变可见性，点击区域保持固定；不实际移除项目。
5. 紧凑侧边栏不出现关闭按钮或文字。

- [ ] **Step 4: 推送并更新 PR 说明**

Run: `git push`

然后用 `gh pr edit 43` 更新 PR 说明，写明旧修复为何未命中、固定布局的最终方案、完整测试数量、真实进程路径和“不涉及发布”。
