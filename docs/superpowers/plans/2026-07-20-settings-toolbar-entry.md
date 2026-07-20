# 设置入口顶部化实现计划

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** 将低频设置入口从项目侧边栏移到共用顶部标签栏最右侧，并让标签栏在设置页打开时保持可见和可交互。

**Architecture:** `TabBarView` 只呈现齿轮并发送设置意图，`MainWindowController` 继续拥有设置页状态与切换逻辑。`contentRoot` 改为共同顶部栏加内容区，终端工作区与设置页只在内容区中切换可见性；侧边栏恢复为单一“新建项目”操作。

**Tech Stack:** Swift 6、AppKit、Swift Package Manager、swift-testing、SF Symbols，最低 macOS 14.0。

## Global Constraints

- `TerminalCore` 不得引入 AppKit 或 Metal，本次只修改 `InkShell`、`InkShellTests` 与设计文档。
- 不新增第三方依赖，不改变配置文件格式、设置项、菜单命令或 `⌘,` 快捷键。
- 外壳 UI 复用系统控件、SF Symbols 与现有 `InkDesignTokens`，不新增装饰性颜色、阴影或渐变。
- 设置页继续惰性安装，切换设置不得销毁或重建 PTY、pane、标签或 Metal 视图。
- 用户可见产品名保持 `Ink`，注释与文档使用中文，代码标识符使用英文。
- 本次不进入渲染或 grid 热路径，不需要 Instruments；必须运行 `swift test` 与 `swift build`。

---

## 文件职责

- `Sources/InkShell/SidebarViewController.swift`：删除侧边栏设置按钮，只布局新建项目。
- `Sources/InkShell/TabBarView.swift`：新增全局设置齿轮、回调和选中态接口。
- `Sources/InkShell/MainWindowController.swift`：建立共同顶部栏结构，协调设置、标签与新建标签状态切换。
- `Tests/InkShellTests/ProjectSidebarTests.swift`：固定侧边栏单操作布局。
- `Tests/InkShellTests/TabBarViewTests.swift`：固定齿轮位置、可访问性、回调与选中态。
- `Tests/InkShellTests/SettingsWindowTests.swift`：固定共同顶部栏、窗口尺寸与从标签返回终端的集成行为。
- `docs/design-system.md`：同步设置入口和共同顶部栏规范。

### Task 1: 侧边栏只保留新建项目

**Files:**
- Modify: `Tests/InkShellTests/ProjectSidebarTests.swift`
- Modify: `Sources/InkShell/SidebarViewController.swift`

**Interfaces:**
- Consumes: `SidebarViewController.onNewProject: (() -> Void)?` 与 `DisplayMode`。
- Produces: 展开态单一全宽按钮、图标态单一居中按钮；删除 `onSettings` 与 `isSettingsSelected`。

- [ ] **Step 1: 将侧边栏布局测试改成单操作预期**

用以下两个测试替换现有 footer 横排和纵排测试，并让 `makeController` 只返回一个按钮和分隔线：

```swift
@Test("展开态底部只保留全宽新建项目")
func expandedFooterUsesFullWidthNewProject() throws {
    let (controller, newButton, separator) = try makeController(mode: .expanded)

    #expect(newButton.title == "新建项目")
    #expect(abs(newButton.frame.minX - InkDesignTokens.Spacing.xs) < 0.5)
    #expect(abs(controller.view.bounds.maxX - newButton.frame.maxX - InkDesignTokens.Spacing.xs) < 0.5)
    #expect(separator.frame.minY > newButton.frame.maxY)
    #expect(controller.view.subviews.compactMap { $0 as? NSButton }.count == 1)
}

@Test("图标态底部只保留居中加号")
func compactFooterUsesCenteredNewProject() throws {
    let (controller, newButton, separator) = try makeController(mode: .compact)

    #expect(newButton.title.isEmpty)
    #expect(abs(newButton.frame.midX - controller.view.bounds.midX) < 0.5)
    #expect(separator.frame.minY > newButton.frame.maxY)
    #expect(newButton.toolTip == "新建项目")
    #expect(controller.view.subviews.compactMap { $0 as? NSButton }.count == 1)
}
```

删除 `controller.isSettingsSelected = true`，并将 helper 签名改为：

```swift
private func makeController(
    mode: SidebarViewController.DisplayMode
) throws -> (SidebarViewController, NSButton, NSBox)
```

- [ ] **Step 2: 运行测试确认旧实现失败**

Run: `swift test --filter ProjectSidebarLayoutTests`

Expected: FAIL，按钮数量仍为 2，展开态新建按钮没有占满可用宽度。

- [ ] **Step 3: 删除侧边栏设置状态与回调**

从 `SidebarViewController` 删除：

```swift
var isSettingsSelected = false
var onSettings: (() -> Void)?
private let settingsButton = SidebarActionButton()
private var expandedFooterConstraints: [NSLayoutConstraint] = []
private var compactFooterConstraints: [NSLayoutConstraint] = []
@objc private func openSettings() { onSettings?() }
```

同时删除 `settingsButton` 的配置、添加子视图和显示模式更新。保留 `footerSeparator`，让
`newButton` 在两种显示模式中都使用以下水平约束：

```swift
NSLayoutConstraint.activate([
    footerSeparator.bottomAnchor.constraint(
        equalTo: newButton.topAnchor,
        constant: -InkDesignTokens.Spacing.xs
    ),
    newButton.leadingAnchor.constraint(
        equalTo: root.leadingAnchor,
        constant: InkDesignTokens.Spacing.xs
    ),
    newButton.trailingAnchor.constraint(
        equalTo: root.trailingAnchor,
        constant: -InkDesignTokens.Spacing.xs
    ),
    newButton.bottomAnchor.constraint(
        equalTo: root.bottomAnchor,
        constant: -InkDesignTokens.Spacing.sm
    ),
])
```

`updateDisplayMode()` 只切换标题、图标位置、对齐、tooltip 与辅助功能标签：

```swift
newButton.title = compact ? "" : "新建项目"
newButton.imagePosition = compact ? .imageOnly : .imageLeading
newButton.alignment = .center
newButton.toolTip = compact ? "新建项目" : nil
newButton.setAccessibilityLabel("新建项目")
```

- [ ] **Step 4: 运行侧边栏测试确认通过**

Run: `swift test --filter ProjectSidebar`

Expected: PASS，项目元数据、颜色标记与两种 footer 布局测试全部通过。

- [ ] **Step 5: 提交侧边栏改动**

```bash
git add Sources/InkShell/SidebarViewController.swift Tests/InkShellTests/ProjectSidebarTests.swift
git commit -m "refactor(sidebar): 让底部操作聚焦新建项目" -m "移除低频设置入口并让新建项目独占底部操作区，保持项目导航职责单一。\n\nRefs #37"
```

### Task 2: 在顶部标签栏增加设置齿轮

**Files:**
- Create: `Tests/InkShellTests/TabBarViewTests.swift`
- Modify: `Sources/InkShell/TabBarView.swift`

**Interfaces:**
- Consumes: `InkDesignTokens.Color.textSecondary`、`Color.pill`、`Radius.item` 与 `Motion.stateDuration`。
- Produces: `onSettings: (() -> Void)?`、`setSettingsSelected(_ selected: Bool)`，以及名为“设置”的图标按钮。

- [ ] **Step 1: 新增齿轮布局与行为失败测试**

创建 `Tests/InkShellTests/TabBarViewTests.swift`：

```swift
import AppKit
import Testing
@testable import InkShell

@Suite("顶部标签栏", .serialized)
@MainActor
struct TabBarViewTests {
    @Test("设置齿轮固定在最右侧并提供辅助信息")
    func settingsButtonUsesTrailingSlot() throws {
        let tabBar = makeTabBar()
        let buttons = tabBar.subviews.compactMap { $0 as? NSButton }
        let settings = try #require(buttons.first { $0.toolTip == "设置（⌘,）" })
        let plus = try #require(buttons.first { $0 !== settings && $0.frame.maxX < settings.frame.minX })

        #expect(settings.frame.maxX > plus.frame.maxX)
        #expect(abs(tabBar.bounds.maxX - settings.frame.maxX - 8) < 0.5)
        #expect(settings.accessibilityLabel() == "设置")
    }

    @Test("设置齿轮发送回调并同步选中态")
    func settingsButtonSelection() throws {
        let tabBar = makeTabBar()
        var opened = false
        tabBar.onSettings = { opened = true }
        let settings = try #require(
            tabBar.subviews.compactMap { $0 as? NSButton }
                .first { $0.toolTip == "设置（⌘,）" }
        )

        settings.performClick(nil)
        #expect(opened)
        tabBar.setSettingsSelected(true)
        #expect(settings.state == .on)
        tabBar.setSettingsSelected(false)
        #expect(settings.state == .off)
    }

    private func makeTabBar() -> TabBarView {
        let tabBar = TabBarView(frame: NSRect(x: 0, y: 0, width: 800, height: 38))
        tabBar.reload(tabs: [.init(title: "ink", shortcut: "⌘1", active: true)])
        tabBar.layoutSubtreeIfNeeded()
        return tabBar
    }
}
```

- [ ] **Step 2: 运行测试确认接口不存在**

Run: `swift test --filter TabBarViewTests`

Expected: FAIL to compile，`TabBarView` 尚无 `onSettings` 和 `setSettingsSelected`。

- [ ] **Step 3: 实现设置按钮和固定尾部插槽**

在 `TabBarView` 增加：

```swift
var onSettings: (() -> Void)?
private let settingsButton = NSButton()

func setSettingsSelected(_ selected: Bool) {
    settingsButton.state = selected ? .on : .off
    updateSettingsButtonAppearance()
}

@objc private func openSettings() { onSettings?() }
```

初始化时用 `gearshape` 配置无边框按钮，设置 `toolTip = "设置（⌘,）"`、
`setAccessibilityLabel("设置")`、`target/action` 和 `wantsLayer = true`。把 plus 的尾部约束
改为指向齿轮，齿轮固定在最右侧：

```swift
stack.trailingAnchor.constraint(equalTo: plusButton.leadingAnchor, constant: -8),
plusButton.centerYAnchor.constraint(equalTo: centerYAnchor),
settingsButton.leadingAnchor.constraint(equalTo: plusButton.trailingAnchor, constant: 6),
settingsButton.trailingAnchor.constraint(
    equalTo: trailingAnchor,
    constant: -InkDesignTokens.Spacing.sm
),
settingsButton.centerYAnchor.constraint(equalTo: centerYAnchor),
settingsButton.widthAnchor.constraint(equalToConstant: 28),
settingsButton.heightAnchor.constraint(equalToConstant: 28),
```

使用按钮 `state` 决定 `layer.backgroundColor`，`.on` 时取
`InkDesignTokens.Color.pill.cgColor`，`.off` 时清空；在
`viewDidChangeEffectiveAppearance()` 中重新解析动态颜色。hover 行为通过与现有外壳按钮
一致的 tracking area 切换同一 pill 背景，选中态离开 hover 后仍保留。

- [ ] **Step 4: 运行标签栏测试确认通过**

Run: `swift test --filter TabBarViewTests`

Expected: PASS，齿轮在尾部，回调、辅助信息和选中态正确。

- [ ] **Step 5: 提交标签栏改动**

```bash
git add Sources/InkShell/TabBarView.swift Tests/InkShellTests/TabBarViewTests.swift
git commit -m "feat(tabbar): 提供全局设置入口" -m "将设置放入固定的顶部尾部插槽，使入口不再依赖侧边栏可见性。\n\nRefs #37"
```

### Task 3: 让顶部栏跨终端与设置状态常驻

**Files:**
- Modify: `Tests/InkShellTests/SettingsWindowTests.swift`
- Modify: `Sources/InkShell/MainWindowController.swift`

**Interfaces:**
- Consumes: `TabBarView.onSettings`、`TabBarView.setSettingsSelected(_:)`。
- Produces: 共同顶部栏视图层级；设置中点击标签或新建标签先返回终端。

- [ ] **Step 1: 新增共同顶部栏集成失败测试**

在 `SettingsWindowTests` 增加：

```swift
@Test("设置页打开时顶部栏仍可见并显示选中齿轮")
func showingSettingsKeepsTabBarVisible() throws {
    let controller = MainWindowController()
    let window = try #require(controller.window)
    window.setFrame(NSRect(x: 640, y: 300, width: 1100, height: 700), display: true)
    window.orderFront(nil)
    controller.newSession(nil)
    spinRunLoop()

    controller.showSettings(nil)
    spinRunLoop()

    let contentView = try #require(window.contentView)
    let tabBar = try #require(allSubviews(in: contentView).first { $0 is TabBarView } as? TabBarView)
    let settings = try #require(
        tabBar.subviews.compactMap { $0 as? NSButton }
            .first { $0.toolTip == "设置（⌘,）" }
    )
    #expect(!tabBar.isHidden)
    #expect(settings.state == .on)
    window.close()
}

@Test("设置页中点击当前标签返回终端")
func selectingTabLeavesSettings() throws {
    let controller = MainWindowController()
    let window = try #require(controller.window)
    window.orderFront(nil)
    controller.newSession(nil)
    spinRunLoop()
    controller.showSettings(nil)
    spinRunLoop()

    controller.selectSessionMenu(NSMenuItem(title: "", action: nil, keyEquivalent: ""))
    spinRunLoop()

    let contentView = try #require(window.contentView)
    let settingsTitle = allSubviews(in: contentView)
        .compactMap { $0 as? NSTextField }
        .first { $0.stringValue == "设置" }
    #expect(settingsTitle?.isHidden != false)
    window.close()
}
```

在第二个测试中设置 `NSMenuItem.tag = 0` 后再调用 `selectSessionMenu(_:)`，确保使用真实公开
菜单路径触发 `selectTab(at:)`。

- [ ] **Step 2: 运行测试确认旧结构失败**

Run: `swift test --filter SettingsWindowTests`

Expected: FAIL，设置打开后旧 `terminalWorkspace` 连同 `tabBar` 被隐藏，齿轮接口也尚未接线。

- [ ] **Step 3: 重排 contentRoot 并接线设置入口**

在 `buildContent()` 中让 `tabBar` 与 hairline 直接属于 `contentRoot`，让
`terminalWorkspace` 只承载 `workspaceView`：

```swift
contentRoot.addSubview(tabBar)
contentRoot.addSubview(hairline)
contentRoot.addSubview(terminalWorkspace)
terminalWorkspace.addSubview(workspaceView)

NSLayoutConstraint.activate([
    tabBar.topAnchor.constraint(equalTo: contentRoot.topAnchor),
    tabBar.leadingAnchor.constraint(equalTo: contentRoot.leadingAnchor),
    tabBar.trailingAnchor.constraint(equalTo: contentRoot.trailingAnchor),
    tabBar.heightAnchor.constraint(equalToConstant: 38),
    hairline.topAnchor.constraint(equalTo: tabBar.bottomAnchor),
    hairline.leadingAnchor.constraint(equalTo: contentRoot.leadingAnchor),
    hairline.trailingAnchor.constraint(equalTo: contentRoot.trailingAnchor),
    terminalWorkspace.topAnchor.constraint(equalTo: hairline.bottomAnchor),
    terminalWorkspace.leadingAnchor.constraint(equalTo: contentRoot.leadingAnchor),
    terminalWorkspace.trailingAnchor.constraint(equalTo: contentRoot.trailingAnchor),
    terminalWorkspace.bottomAnchor.constraint(equalTo: contentRoot.bottomAnchor),
    workspaceView.topAnchor.constraint(equalTo: terminalWorkspace.topAnchor),
    workspaceView.leadingAnchor.constraint(equalTo: terminalWorkspace.leadingAnchor),
    workspaceView.trailingAnchor.constraint(equalTo: terminalWorkspace.trailingAnchor),
    workspaceView.bottomAnchor.constraint(equalTo: terminalWorkspace.bottomAnchor),
])
```

设置页安装约束改为顶部连接 `hairline.bottomAnchor`，其余边缘继续连接 `contentRoot`。
删除 `sidebarVC.onSettings` 接线，新增：

```swift
tabBar.onSettings = { [weak self] in self?.showSettings(nil) }
```

`showSettings(_:)` 调用 `tabBar.setSettingsSelected(true)`；`hideSettings()` 调用
`tabBar.setSettingsSelected(false)`。`selectTab(at:)` 在索引有效后先调用 `hideSettings()`，
然后更新活动标签。`newSession(_:)` 在启动 pane 前调用 `hideSettings()`，让设置状态中点击
加号能创建并聚焦新标签。

- [ ] **Step 4: 运行集成测试确认通过**

Run: `swift test --filter SettingsWindowTests`

Expected: PASS，设置页打开时顶部栏可见、齿轮选中、窗口 frame 稳定，标签可返回终端。

- [ ] **Step 5: 提交共同顶部栏改动**

```bash
git add Sources/InkShell/MainWindowController.swift Tests/InkShellTests/SettingsWindowTests.swift
git commit -m "refactor(shell): 让顶部栏贯穿设置状态" -m "把标签栏提升为内容区共同导航，并让标签与新建标签可直接结束设置状态。\n\nRefs #37"
```

### Task 4: 同步设计系统并完成验证

**Files:**
- Modify: `docs/design-system.md`

**Interfaces:**
- Consumes: Task 1 至 Task 3 已实现的最终行为。
- Produces: 与代码一致的设置入口和共同顶部栏规范。

- [ ] **Step 1: 更新内嵌设置页规范**

将 `docs/design-system.md` 的“内嵌设置页”入口描述改为：

```markdown
设置页使用主内容区替换终端工作区，不创建独立窗口。顶部标签栏在终端与设置状态中
始终保留，最右侧使用齿轮作为全局设置入口；设置打开时齿轮显示选中背景，点击任意
标签或“完成”返回终端。侧边栏底部只保留“新建项目”，展开态显示整行文字入口，
图标态只保留居中加号；侧边栏完全隐藏时仍可用顶部齿轮与 `⌘,` 进入设置。
```

保留其余设置表面层级、配置来源和即时生效规则。

- [ ] **Step 2: 运行完整自动化验证**

Run: `swift test`

Expected: 所有 suite PASS，无失败或意外跳过。

Run: `swift build`

Expected: Build complete，零 warning、零 error。

- [ ] **Step 3: 检查 diff 和范围**

Run: `git diff --check`

Expected: 无输出。

Run: `git status --short`

Expected: 只包含 Issue #37 范围内的 `InkShell`、`InkShellTests` 和设计文档变更。

- [ ] **Step 4: 提交文档同步**

```bash
git add docs/design-system.md docs/superpowers/plans/2026-07-20-settings-toolbar-entry.md
git commit -m "docs(ui): 同步顶部设置入口规范" -m "记录共同顶部栏、齿轮选中态和侧边栏单操作布局，避免实现与设计系统再次漂移。\n\nRefs #37"
```

- [ ] **Step 5: 启动真实应用验收**

Run: `swift run ink`

Expected: Ink 主窗口打开。人工检查浅色与深色外观、三种侧边栏状态、单标签与多个长标题
标签、齿轮 hover 和选中态、当前与其它标签返回、加号返回、新建项目、`⌘,`、Escape 与
“完成”。窗口不得缩放或跳动，VoiceOver 读出“设置”。
