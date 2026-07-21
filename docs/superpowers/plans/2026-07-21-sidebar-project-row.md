# Sidebar Project Row Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** 让长目录项目以“项目名 + 可省略父路径 + 固定标签状态”显示，并把所有关闭按钮固定在项目行最右侧，保证新增、hover、点击重建和退出时布局不抖动。

**Architecture:** `Project` 负责从目录 URL 生成稳定的展示字段，`MainWindowController` 把标题、父路径、备注、状态和完整路径组装进侧边栏行模型。`ProjectRowView` 的内层文字继续使用 stack，最外层改用明确锚点：关闭按钮固定到行 trailing，文字列固定在图标与按钮之间；悬停只改变按钮透明度与交互状态，不增删或移动 Auto Layout 内容。

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

- [x] **Step 4: 推送并更新 PR 说明**

Run: `git push`

然后用 `gh pr edit 43` 更新 PR 说明，写明旧修复为何未命中、固定布局的最终方案、完整测试数量、真实进程路径和“不涉及发布”。

### Task 4: 固定右侧操作列并覆盖首次悬停

**Files:**
- Modify: `Sources/InkShell/SidebarViewController.swift`
- Test: `Tests/InkShellTests/ProjectSidebarTests.swift`

**Interfaces:**
- Consumes: `ProjectRowView` 的 `indicator`、`icon`、`textStack`、`closeButton`
- Produces: 关闭按钮相对项目行固定的 trailing 坐标；`mouseEntered(with:)` 只改变按钮状态

- [ ] **Step 1: 用失败测试替换错误的内容相邻断言**

从 `longPathUsesStableProjectNameLayout()` 删除把 X 固定在状态文字后面的错误断言：

```swift
#expect(
    closeButtonFrame.minX - initialStatusFrame.maxX
        <= InkDesignTokens.Spacing.xs + 0.5
)
```

新增测试辅助函数与两项回归测试：

```swift
private func projectRows(in controller: SidebarViewController) throws -> [NSView] {
    let stack = try #require(
        controller.view.subviews.compactMap { $0 as? NSStackView }.first
    )
    return stack.arrangedSubviews
}

private func closeButton(in row: NSView) throws -> NSButton {
    try #require(descendants(of: NSButton.self, in: row).first)
}

@Test("不同长度项目共享固定右侧关闭列")
func rowsUseFixedTrailingCloseColumn() throws {
    let controller = SidebarViewController()
    controller.view.frame = NSRect(
        x: 0,
        y: 0,
        width: InkDesignTokens.Sidebar.width,
        height: 700
    )
    controller.reload(rows: [
        .init(
            title: "~",
            detail: "",
            status: "未打开",
            fullPath: "~",
            active: false,
            pinned: false,
            label: .none
        ),
        .init(
            title: "wise-studio",
            detail: "~/work/code/very-long-parent-directory/wiselaw",
            status: "1 个标签",
            fullPath: "~/work/code/very-long-parent-directory/wiselaw/wise-studio",
            active: true,
            pinned: false,
            label: .red
        ),
    ])
    controller.view.layoutSubtreeIfNeeded()

    let rows = try projectRows(in: controller)
    let shortButton = try closeButton(in: rows[0])
    let longButton = try closeButton(in: rows[1])
    let shortFrame = shortButton.convert(shortButton.bounds, to: rows[0])
    let longFrame = longButton.convert(longButton.bounds, to: rows[1])

    #expect(abs(shortFrame.minX - longFrame.minX) < 0.5)
    #expect(abs(shortFrame.maxX - rows[0].bounds.maxX) <= InkDesignTokens.Spacing.xs + 0.5)
    #expect(abs(longFrame.maxX - rows[1].bounds.maxX) <= InkDesignTokens.Spacing.xs + 0.5)
}

@Test("新增项目第一次悬停不移动布局")
func firstHoverAfterCreatingProjectKeepsFramesStable() throws {
    let controller = SidebarViewController()
    controller.view.frame = NSRect(
        x: 0,
        y: 0,
        width: InkDesignTokens.Sidebar.width,
        height: 700
    )
    let existing = SidebarViewController.Row(
        title: "~",
        detail: "",
        status: "未打开",
        fullPath: "~",
        active: false,
        pinned: false,
        label: .none
    )
    let created = SidebarViewController.Row(
        title: "wise-studio",
        detail: "~/work/code/wiselaw",
        status: "1 个标签",
        fullPath: "~/work/code/wiselaw/wise-studio",
        active: true,
        pinned: false,
        label: .red
    )
    controller.reload(rows: [existing])
    controller.reload(rows: [existing, created])
    controller.view.layoutSubtreeIfNeeded()

    let row = try #require(try projectRows(in: controller).last)
    let title = try #require(
        descendants(of: NSTextField.self, in: row)
            .first { $0.stringValue == created.title }
    )
    let button = try closeButton(in: row)
    let titleFrame = title.convert(title.bounds, to: row)
    let buttonFrame = button.convert(button.bounds, to: row)
    let event = try #require(
        NSEvent.mouseEvent(
            with: .mouseMoved,
            location: .zero,
            modifierFlags: [],
            timestamp: 0,
            windowNumber: 0,
            context: nil,
            eventNumber: 0,
            clickCount: 0,
            pressure: 0
        )
    )

    row.mouseEntered(with: event)
    controller.view.layoutSubtreeIfNeeded()

    #expect(title.convert(title.bounds, to: row) == titleFrame)
    #expect(button.convert(button.bounds, to: row) == buttonFrame)
    #expect(button.alphaValue == 1)
}
```

- [ ] **Step 2: 运行测试确认 RED**

Run: `swift test --filter ProjectSidebarLayoutTests`

Expected: `不同长度项目共享固定右侧关闭列` FAIL；当前最外层 `NSStackView` 按每行内容
固有宽度放置关闭按钮，短标题和长标题的按钮 `minX` 不一致，按钮也不贴近行 trailing。

- [ ] **Step 3: 用明确锚点替换最外层水平栈**

保留 `metadataStack` 与 `textStack`，删除最外层 `hStack`。把四列直接加入项目行：

```swift
for subview in [indicator, icon, textStack, closeButton] {
    subview.translatesAutoresizingMaskIntoConstraints = false
    addSubview(subview)
}

NSLayoutConstraint.activate([
    indicator.leadingAnchor.constraint(equalTo: leadingAnchor, constant: sp.xs),
    indicator.centerYAnchor.constraint(equalTo: centerYAnchor),
    indicator.widthAnchor.constraint(equalToConstant: indicatorDiameter),
    indicator.heightAnchor.constraint(equalToConstant: indicatorDiameter),

    icon.leadingAnchor.constraint(equalTo: indicator.trailingAnchor, constant: sp.xs),
    icon.centerYAnchor.constraint(equalTo: centerYAnchor),
    icon.widthAnchor.constraint(equalToConstant: iconSize),
    icon.heightAnchor.constraint(equalToConstant: iconSize),

    closeButton.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -sp.xs),
    closeButton.centerYAnchor.constraint(equalTo: centerYAnchor),
    closeButton.widthAnchor.constraint(
        equalToConstant: InkDesignTokens.Sidebar.projectCloseButtonWidth
    ),

    textStack.leadingAnchor.constraint(equalTo: icon.trailingAnchor, constant: sp.xs),
    textStack.trailingAnchor.constraint(equalTo: closeButton.leadingAnchor, constant: -sp.xs),
    textStack.topAnchor.constraint(equalTo: topAnchor, constant: 6),
    textStack.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -6),
    title.widthAnchor.constraint(equalTo: textStack.widthAnchor),
    metadataStack.widthAnchor.constraint(equalTo: textStack.widthAnchor),
])
```

使用当前实现中的实际常量名：圆点直径为
`InkDesignTokens.Sidebar.labelDotDiameter`，图标尺寸为 `16`。不改变 compact 分支、按钮
透明度逻辑、点击、拖拽或菜单行为。

- [ ] **Step 4: 运行布局测试确认 GREEN**

Run: `swift test --filter ProjectSidebarLayoutTests`

Expected: 全部 PASS；两行按钮横坐标一致且贴近行右侧，新增行第一次 hover 的标题与按钮
frame 不变。

- [ ] **Step 5: 运行 Shell 测试并提交结构修复**

Run: `swift test --filter InkShellTests`

Expected: 78 项或更多 InkShell 测试全部 PASS。

```bash
git add Sources/InkShell/SidebarViewController.swift \
  Tests/InkShellTests/ProjectSidebarTests.swift
git commit -m "fix(sidebar): 将项目关闭按钮固定到行右侧" \
  -m "前两轮只固定了按钮宽度和文字对齐，最外层 stack 仍按内容宽度放置操作列。改用 trailing 锚点，并覆盖不同标题长度与新增项目首次悬停。\n\nRefs #41"
```

### Task 5: 真实 debug 进程验收与 PR 更新

**Files:**
- Verify only; no source changes expected

**Interfaces:**
- Consumes: Task 4 的提交
- Produces: PR #43 的最终验证证据与用户可检查的 debug 进程

- [ ] **Step 1: 运行完整自动验证**

Run: `swift test && swift build && git diff --check`

Expected: 169 项或更多测试全部 PASS，构建零警告，diff check 无输出。

- [ ] **Step 2: 只重启当前分支 debug 可执行文件**

先运行：

```bash
ps -axo pid=,args= | rg \
  '/Applications/Ink\.app/Contents/MacOS/ink|/Users/cheney/work/code/ink/\.build/arm64-apple-macosx/debug/ink'
```

精确退出列出的旧 debug PID；如果安装版 PID 存在，也精确退出它。然后运行：

```bash
/Users/cheney/work/code/ink/.build/arm64-apple-macosx/debug/ink
```

再次执行进程查询。Expected: 只剩一个 Ink 进程，路径精确指向上述 debug 产物。

- [ ] **Step 3: 按 PID 验证真实窗口**

不要按应用名调用会自动启动 `/Applications/Ink.app` 的工具。使用 debug PID 查询
`CGWindowListCopyWindowInfo`，取得该 PID 的窗口号后直接截图。检查：

1. 不同长度项目的 X 位于同一右侧操作列。
2. 父路径头部省略，状态完整且与 X 保持稳定间距。
3. 新建第二个项目后，第一次 hover、点击、移出均无文字或 X 横移。
4. 安装版进程未运行。

- [ ] **Step 4: 推送并更新 PR #43**

Run: `git push`

更新 PR 说明，明确前两轮测试分别误把“按钮 frame 存在”和“X 紧贴状态”当成正确结果，
最终修复使用 trailing 锚点，并附 169 项或更多测试与 debug PID 验收证据。不合并、不发布。
