# Expanded Sidebar Label Dot Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** 在展开侧边栏的项目行左侧显示 Finder 风格颜色圆点，并在图标态继续显示现有颜色竖条。

**Architecture:** `SidebarViewController.DisplayMode` 映射到一个明确的指示器形态，`ProjectLabelIndicator` 根据形态绘制圆点或竖条。展开态无论是否标色都把固定尺寸指示器放进水平内容栈，`.none` 只跳过绘制而不隐藏视图，从而保持文件夹图标和文字对齐。

**Tech Stack:** Swift 6、AppKit、Auto Layout、swift-testing、Swift Package Manager

## Global Constraints

- 最低系统 macOS 14.0，保持 Swift 6 strict concurrency。
- 只改 Shell UI 与设计 token，不向 `TerminalCore` 引入 AppKit 或 Metal。
- 颜色必须通过 `InkDesignTokens.ProjectLabel` 获取，业务组件不得写 RGB。
- 展开态圆点直径为 8pt；图标态继续使用 4×26pt 圆角短色条。
- `.none` 不绘制颜色，但展开态必须保留固定占位。
- 不改变项目选择、拖拽、右键菜单、辅助功能标签或持久化数据。
- 不新增第三方依赖，不涉及发布或版本标签。

---

### Task 1: 定义显示模式到指示器形态的映射

**Files:**
- Modify: `Sources/InkDesign/InkDesignTokens.swift:175-191`
- Modify: `Sources/InkShell/SidebarViewController.swift:12-20`
- Test: `Tests/InkShellTests/ProjectSidebarTests.swift:39-44`

**Interfaces:**
- Consumes: `InkDesignTokens.Sidebar.labelRailWidth`、`labelRailHeight`
- Produces: `ProjectLabelIndicatorStyle`、`SidebarViewController.DisplayMode.labelIndicatorStyle`、`InkDesignTokens.Sidebar.labelDotDiameter`

- [x] **Step 1: 写入失败的形态映射测试**

把现有“项目颜色只在图标态展示”测试替换为：

```swift
@Test("项目颜色按侧边栏状态切换形态")
func projectLabelStyle() {
    #expect(SidebarViewController.DisplayMode.expanded.labelIndicatorStyle == .dot)
    #expect(SidebarViewController.DisplayMode.compact.labelIndicatorStyle == .rail)
    #expect(InkDesignTokens.Sidebar.labelDotDiameter == 8)
}
```

- [x] **Step 2: 运行测试并确认因接口缺失而失败**

Run: `swift test --filter ProjectSidebarTests.projectLabelStyle`

Expected: FAIL，编译器报告 `labelIndicatorStyle`、`.dot` 或 `labelDotDiameter` 不存在。

- [x] **Step 3: 添加最小形态模型与 token**

在 `SidebarViewController` 前添加：

```swift
enum ProjectLabelIndicatorStyle: Equatable {
    case dot
    case rail
}
```

在现有 `DisplayMode.showsProjectLabels` 旁添加（旧属性在 Task 2 完成调用迁移后删除）：

```swift
var labelIndicatorStyle: ProjectLabelIndicatorStyle {
    switch self {
    case .expanded: .dot
    case .compact: .rail
    }
}
```

在 `InkDesignTokens.Sidebar` 的颜色标记尺寸旁添加：

```swift
public static let labelDotDiameter: CGFloat = 8
```

- [x] **Step 4: 运行形态映射测试并确认通过**

Run: `swift test --filter ProjectSidebarTests.projectLabelStyle`

Expected: PASS，目标测试无失败。

- [x] **Step 5: 提交形态模型**

```bash
git add Sources/InkDesign/InkDesignTokens.swift \
  Sources/InkShell/SidebarViewController.swift \
  Tests/InkShellTests/ProjectSidebarTests.swift
git commit -m "feat(sidebar): 定义颜色标记显示形态" -m "让展开态和图标态显式映射到圆点与竖条，为统一指示器布局提供稳定接口。\n\nRefs #33"
```

### Task 2: 用统一指示器实现圆点与竖条布局

**Files:**
- Modify: `Sources/InkShell/SidebarViewController.swift:189-229, 285-367, 510-541`
- Modify: `Tests/InkShellTests/ProjectSidebarTests.swift:53-118`

**Interfaces:**
- Consumes: `ProjectLabelIndicatorStyle`、`DisplayMode.labelIndicatorStyle`、`InkDesignTokens.Sidebar.labelDotDiameter`、`InkDesignTokens.ProjectLabel.color(for:)`
- Produces: `ProjectLabelIndicator.init(label:style:)`、`ProjectLabelIndicator.drawsColor`

- [x] **Step 1: 写入失败的展开态与图标态布局测试**

在 `ProjectSidebarLayoutTests` 增加：

```swift
@Test("展开态为所有项目保留圆点列")
func expandedRowsReserveDotColumn() {
    let controller = makeLabelController(mode: .expanded)
    let indicators = descendants(of: ProjectLabelIndicator.self, in: controller.view)

    #expect(indicators.count == 2)
    #expect(indicators.allSatisfy {
        abs($0.frame.width - InkDesignTokens.Sidebar.labelDotDiameter) < 0.5
            && abs($0.frame.height - InkDesignTokens.Sidebar.labelDotDiameter) < 0.5
    })
    #expect(abs(indicators[0].frame.minX - indicators[1].frame.minX) < 0.5)
    #expect(indicators[0].drawsColor)
    #expect(!indicators[1].drawsColor)
    #expect(!indicators[1].isHidden)
}

@Test("图标态继续使用颜色竖条")
func compactRowsUseLabelRail() {
    let controller = makeLabelController(mode: .compact)
    let indicators = descendants(of: ProjectLabelIndicator.self, in: controller.view)

    #expect(indicators.count == 2)
    #expect(indicators.allSatisfy {
        abs($0.frame.width - InkDesignTokens.Sidebar.labelRailWidth) < 0.5
            && abs($0.frame.height - InkDesignTokens.Sidebar.labelRailHeight) < 0.5
    })
}
```

并在测试 suite 中增加以下辅助方法：

```swift
private func makeLabelController(
    mode: SidebarViewController.DisplayMode
) -> SidebarViewController {
    let controller = SidebarViewController()
    controller.displayMode = mode
    let width = mode == .compact
        ? InkDesignTokens.Sidebar.compactWidth
        : InkDesignTokens.Sidebar.width
    controller.view.frame = NSRect(x: 0, y: 0, width: width, height: 700)
    controller.reload(rows: [
        .init(title: "~/ink", subtitle: "1 个会话", active: true, pinned: false, label: .red),
        .init(title: "~/notes", subtitle: "无会话", active: false, pinned: false, label: .none),
    ])
    controller.view.layoutSubtreeIfNeeded()
    return controller
}

private func descendants<T: NSView>(of type: T.Type, in view: NSView) -> [T] {
    view.subviews.flatMap { child in
        (child as? T).map { [$0] } ?? descendants(of: type, in: child)
    }
}
```

- [x] **Step 2: 运行布局测试并确认因统一指示器接口缺失而失败**

Run: `swift test --filter ProjectSidebarLayoutTests`

Expected: FAIL，编译器报告 `ProjectLabelIndicator` 不可见、缺少 `drawsColor`，或展开态找不到指示器。

- [x] **Step 3: 将项目行改为统一指示器布局**

在 `rebuildRows()` 中把 `showsLabel:` 参数替换为：

```swift
indicatorStyle: displayMode.labelIndicatorStyle
```

把 `ProjectRowView` 初始化参数改为：

```swift
init(
    row: SidebarViewController.Row,
    index: Int,
    compact: Bool,
    indicatorStyle: ProjectLabelIndicatorStyle
)
```

创建单个指示器：

```swift
let indicator = ProjectLabelIndicator(label: row.label, style: indicatorStyle)
indicator.translatesAutoresizingMaskIntoConstraints = false
```

图标态继续把它作为普通子视图放在左缘，并按竖条 token 约束：

```swift
addSubview(indicator)
NSLayoutConstraint.activate([
    indicator.leadingAnchor.constraint(
        equalTo: leadingAnchor,
        constant: InkDesignTokens.Sidebar.labelRailInset
    ),
    indicator.centerYAnchor.constraint(equalTo: centerYAnchor),
    indicator.widthAnchor.constraint(equalToConstant: InkDesignTokens.Sidebar.labelRailWidth),
    indicator.heightAnchor.constraint(equalToConstant: InkDesignTokens.Sidebar.labelRailHeight),
])
```

展开态把指示器放进水平栈最前方，并固定圆点尺寸：

```swift
let hStack = NSStackView(views: [indicator, icon, textStack, NSView(), closeButton])
NSLayoutConstraint.activate([
    indicator.widthAnchor.constraint(equalToConstant: InkDesignTokens.Sidebar.labelDotDiameter),
    indicator.heightAnchor.constraint(equalToConstant: InkDesignTokens.Sidebar.labelDotDiameter),
])
```

把指示器实现改为模块内可测试的统一组件：

```swift
@MainActor
final class ProjectLabelIndicator: NSView {
    private let label: InkProjectLabel
    private let style: ProjectLabelIndicatorStyle

    var drawsColor: Bool { label != .none }

    init(label: InkProjectLabel, style: ProjectLabelIndicatorStyle) {
        self.label = label
        self.style = style
        super.init(frame: .zero)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("代码构建") }

    override func draw(_ dirtyRect: NSRect) {
        guard let color = InkDesignTokens.ProjectLabel.color(for: label) else { return }
        color.setFill()
        switch style {
        case .dot:
            NSBezierPath(ovalIn: bounds).fill()
        case .rail:
            NSBezierPath(
                roundedRect: bounds,
                xRadius: bounds.width / 2,
                yRadius: bounds.width / 2
            ).fill()
        }
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        needsDisplay = true
    }
}
```

不要对 `.none` 设置 `isHidden = true`；`NSStackView` 会折叠隐藏 arranged subview 的占位。

- [x] **Step 4: 运行侧边栏测试并确认通过**

Run: `swift test --filter ProjectSidebarTests && swift test --filter ProjectSidebarLayoutTests`

Expected: PASS，项目侧边栏与布局 suite 无失败。

- [x] **Step 5: 提交统一指示器实现**

```bash
git add Sources/InkShell/SidebarViewController.swift \
  Tests/InkShellTests/ProjectSidebarTests.swift
git commit -m "feat(sidebar): 展开态显示项目颜色圆点" -m "为展开项目行固定预留颜色圆点列，同时让图标态继续使用现有竖条，避免标记变化导致内容跳动。\n\nRefs #33"
```

### Task 3: 同步设计系统并执行完整验证

**Files:**
- Modify: `docs/design-system.md:43-49`

**Interfaces:**
- Consumes: 已实现的展开态圆点与图标态竖条行为
- Produces: 与实际行为一致的侧边栏视觉规范

- [x] **Step 1: 更新项目颜色标记规范**

把“展开态不显示标记”一段改为：

```markdown
项目可在右键菜单选择 Finder 式红、橙、黄、绿、蓝、紫、灰七种标记或清除标记。
展开态在项目行左侧固定预留标记列：已标色项目显示 8pt 圆点，未标色项目留空，
文件夹图标与文字始终对齐。图标态在项目卡片左缘内侧显示 4×26pt 圆角短色条。
颜色只用于快速识别项目，不改变文件夹图标颜色，也不覆盖活动项目背景。标记颜色
必须通过 `InkDesignTokens.ProjectLabel` 获取，不能在侧边栏组件内写 RGB。
```

- [x] **Step 2: 运行完整测试**

Run: `swift test`

Expected: PASS，所有 test suites 无失败。

- [x] **Step 3: 运行完整构建**

Run: `swift build`

Expected: exit 0，构建输出无 warning 或 error。

- [x] **Step 4: 检查改动范围与空白错误**

Run: `git diff --check && git status --short`

Expected: `git diff --check` 无输出；状态只包含 Issue #33 范围内文件及用户已有的 `.superpowers/` 未跟踪目录。

- [x] **Step 5: 提交文档与计划状态**

```bash
git add docs/design-system.md
git commit -m "docs(sidebar): 同步项目颜色标记规范" -m "记录展开态圆点固定占位与图标态竖条的两种表现，保持设计系统与实现一致。\n\nRefs #33"
```

完成后复查 `git log --oneline origin/main..HEAD`，确认所有提交都引用 Issue #33，且未创建版本标签或发布产物。
