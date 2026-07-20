# Responsive Sidebar Footer Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** 让侧边栏底部入口在展开态横排、图标态竖排，并把分隔线固定在操作区上方。

**Architecture:** 在现有 `SidebarViewController` 内维护两组互斥 Auto Layout 约束，由 `updateDisplayMode()` 随显示模式切换。按钮行为和状态绘制保持不变，不新增组件或依赖。

**Tech Stack:** Swift 6、AppKit、Auto Layout、swift-testing

## Global Constraints

- 最低系统 macOS 14.0。
- 外壳 UI 使用 AppKit 系统控件，不引入第三方依赖。
- 不修改终端渲染热路径。
- 代码标识符用英文，注释和提交信息用中文。

---

### Task 1: 锁定展开态和图标态布局行为

**Files:**
- Modify: `Tests/InkShellTests/ProjectSidebarTests.swift`
- Modify: `Sources/InkShell/SidebarViewController.swift`

**Interfaces:**
- Consumes: `SidebarViewController.DisplayMode`、`updateDisplayMode()`、现有 `newButton` / `settingsButton`。
- Produces: `expandedFooterConstraints: [NSLayoutConstraint]`、`compactFooterConstraints: [NSLayoutConstraint]`。

- [ ] **Step 1: 写失败测试**

在 `ProjectSidebarLayoutTests` 中增加展开态与图标态断言：

```swift
@Test("展开态底部入口横向等宽排列")
func expandedFooterUsesOneRow() throws {
    let (_, newButton, settingsButton) = try makeController(mode: .expanded)
    #expect(abs(newButton.frame.midY - settingsButton.frame.midY) < 0.5)
    #expect(abs(newButton.frame.width - settingsButton.frame.width) < 0.5)
    #expect(newButton.frame.maxX < settingsButton.frame.minX)
}

@Test("图标态底部入口上下排列")
func compactFooterUsesTwoRows() throws {
    let (_, newButton, settingsButton) = try makeController(mode: .compact)
    #expect(abs(newButton.frame.midX - settingsButton.frame.midX) < 0.5)
    #expect(newButton.frame.minY > settingsButton.frame.maxY)
    #expect(newButton.title.isEmpty)
    #expect(settingsButton.title.isEmpty)
}
```

`makeController(mode:)` 创建 258×700 的真实 `SidebarViewController`，加入一个项目行，
返回根视图中的两个直接子级按钮，并断言不存在 `⌘N`、`⌘,` 文本字段。

- [ ] **Step 2: 验证测试失败**

Run: `swift test --filter ProjectSidebarLayoutTests`

Expected: 当前展开态仍为上下排列，因此横排断言失败。

- [ ] **Step 3: 实现最小布局切换**

在 `SidebarViewController` 中移除两个快捷键提示视图，并增加两组约束：

```swift
private var expandedFooterConstraints: [NSLayoutConstraint] = []
private var compactFooterConstraints: [NSLayoutConstraint] = []

expandedFooterConstraints = [
    footerSeparator.bottomAnchor.constraint(equalTo: newButton.topAnchor, constant: -sp.xxs),
    newButton.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: sp.xs),
    newButton.trailingAnchor.constraint(equalTo: settingsButton.leadingAnchor, constant: -sp.xxs),
    settingsButton.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -sp.xs),
    newButton.widthAnchor.constraint(equalTo: settingsButton.widthAnchor),
    newButton.centerYAnchor.constraint(equalTo: settingsButton.centerYAnchor),
]
compactFooterConstraints = [
    footerSeparator.bottomAnchor.constraint(equalTo: newButton.topAnchor, constant: -sp.xs),
    newButton.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: sp.xs),
    newButton.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -sp.xs),
    newButton.bottomAnchor.constraint(equalTo: settingsButton.topAnchor, constant: -sp.xs),
    settingsButton.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: sp.xs),
    settingsButton.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -sp.xs),
]
```

`updateDisplayMode()` 互斥切换约束，并让两种模式中的按钮内容保持居中：

```swift
NSLayoutConstraint.deactivate(compact ? expandedFooterConstraints : compactFooterConstraints)
NSLayoutConstraint.activate(compact ? compactFooterConstraints : expandedFooterConstraints)
newButton.alignment = .center
settingsButton.alignment = .center
newButton.imageHugsTitle = true
settingsButton.imageHugsTitle = true
```

- [ ] **Step 4: 验证目标测试与完整工程**

Run: `swift test --filter ProjectSidebarLayoutTests && swift test && swift build`

Expected: 目标测试通过，完整测试零失败，构建零警告。

- [ ] **Step 5: 真实界面验证**

从 Issue 分支运行 `swift run ink`，在展开态确认两个入口横排，在图标态确认上下排列，并检查 hover 与设置选中背景。

- [ ] **Step 6: 提交并建立 PR**

```bash
git add Sources/InkShell/SidebarViewController.swift \
  Tests/InkShellTests/ProjectSidebarTests.swift \
  docs/superpowers/specs/2026-07-20-responsive-sidebar-footer-design.md \
  docs/superpowers/plans/2026-07-20-responsive-sidebar-footer.md
git commit -m "feat(sidebar): 响应式排列底部操作入口"
git push -u origin agent/issue-27-responsive-sidebar-footer
```

PR 描述使用 `Closes #27`，不执行发布。
