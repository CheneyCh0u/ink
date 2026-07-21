# Tab Width And Overflow Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** 为 Ink 顶部标签栏增加 112/168/240 pt 宽度约束、连续可见区间和原生溢出菜单，并保证活动标签始终可见。

**Architecture:** `InkDesignTokens.TabBar` 保存视觉常量，纯值 `TabBarLayout` 根据首选宽度、活动索引、可用空间和旧区间计算可见范围及最终宽度。`TabBarView` 负责测量标题、映射原始索引、布置 AppKit 子视图并构建 `NSMenu`；`MainWindowController` 和 `Project` 的现有标签接口保持不变。

**Tech Stack:** Swift 6、AppKit、Swift Testing、SwiftPM、现有 `InkDesign` 与 `InkShell` 模块。

## Global Constraints

- 最低系统版本保持 macOS 14.0。
- 不新增第三方依赖，不使用 macOS 15 才提供的 `NSPopUpButton` 便利构造器。
- 标签最小宽度固定为 112 pt，理想宽度固定为 168 pt，最大宽度固定为 240 pt。
- 溢出按钮点击区域固定为 28 pt，标签间距固定为 6 pt。
- 可见标签必须是连续区间，活动标签必须始终可见，区间只做包含活动标签所需的最小移动。
- 菜单只列隐藏标签，保持原始顺序并使用原始数组索引。
- 不实现横向滚动、最近使用排序、标签拖动、菜单内关闭或重命名、宽度设置项和会话恢复。
- 不修改 `TerminalCore`、PTY、Metal、配置格式或持久化数据。
- 布局只在标签模型或窗口边界变化时运行，不进入输出回调和逐帧渲染热路径。
- 用户可见文案与代码注释使用中文，代码标识符使用英文。
- 关联 Issue #64；提交信息使用中文 Conventional Commit，PR 描述仅使用 `Closes #64` 关闭 Issue。

---

## File Map

- `Sources/InkDesign/InkDesignTokens.swift`：标签宽度、间距和按钮尺寸的权威来源。
- `Sources/InkShell/TabBarLayout.swift`：不持有 AppKit 视图的 O(n) 布局计算。
- `Sources/InkShell/TabBarView.swift`：标题测量、可见标签布置、溢出按钮和 `NSMenu`。
- `Tests/InkShellTests/TabBarLayoutTests.swift`：宽度、阈值、连续区间和异常输入测试。
- `Tests/InkShellTests/TabBarViewTests.swift`：真实 AppKit 视图、菜单、索引与现有按钮回归测试。
- `docs/design-system.md`：顶部标签栏的稳定视觉与交互规范。
- `docs/superpowers/specs/2026-07-22-tab-overflow-design.md`：已批准的行为与边界来源。

### Task 1: 标签宽度 Token 与纯布局模型

**Files:**
- Modify: `Sources/InkDesign/InkDesignTokens.swift`
- Create: `Sources/InkShell/TabBarLayout.swift`
- Create: `Tests/InkShellTests/TabBarLayoutTests.swift`

**Interfaces:**
- Consumes: `InkDesignTokens.TabBar` 中的最小、理想、最大宽度、间距和溢出按钮宽度。
- Produces: `TabBarLayout.resolve(preferredWidths:activeIndex:availableWidth:previousVisibleRange:) -> TabBarLayout`。
- Produces: `visibleRange: Range<Int>`、`hiddenIndices: [Int]`、`widths: [CGFloat]`、`showsOverflow: Bool`。

- [ ] **Step 1: 写纯布局失败测试**

创建 `Tests/InkShellTests/TabBarLayoutTests.swift`：

```swift
import Foundation
import InkDesign
import Testing
@testable import InkShell

@Suite("标签栏溢出布局")
struct TabBarLayoutTests {
    @Test("全部标签可见时保留首选宽度")
    func allTabsUsePreferredWidths() {
        let result = TabBarLayout.resolve(
            preferredWidths: [168, 200],
            activeIndex: 0,
            availableWidth: 374
        )

        #expect(result.visibleRange == 0..<2)
        #expect(result.hiddenIndices.isEmpty)
        #expect(result.widths == [168, 200])
        #expect(!result.showsOverflow)
    }

    @Test("首选宽度放不下时公平压缩但不低于最小值")
    func compressesTowardMinimum() {
        let result = TabBarLayout.resolve(
            preferredWidths: [240, 240],
            activeIndex: 0,
            availableWidth: 330
        )

        #expect(result.visibleRange == 0..<2)
        #expect(abs(result.widths[0] - 162) < 0.001)
        #expect(abs(result.widths[1] - 162) < 0.001)
        #expect(result.widths.allSatisfy { $0 >= InkDesignTokens.TabBar.minimumTabWidth })
    }

    @Test("刚好达到最小总宽时不溢出，少一磅时进入菜单")
    func thresholdIncludesSpacing() {
        let fits = TabBarLayout.resolve(
            preferredWidths: [168, 168, 168],
            activeIndex: 1,
            availableWidth: 348
        )
        let overflows = TabBarLayout.resolve(
            preferredWidths: [168, 168, 168],
            activeIndex: 1,
            availableWidth: 347
        )

        #expect(fits.visibleRange == 0..<3)
        #expect(!fits.showsOverflow)
        #expect(overflows.visibleRange == 0..<2)
        #expect(overflows.hiddenIndices == [2])
        #expect(overflows.showsOverflow)
    }

    @Test("活动标签留在区间内时不移动，越界时只移动一格")
    func minimallyMovesVisibleRange() {
        let stable = TabBarLayout.resolve(
            preferredWidths: Array(repeating: 168, count: 6),
            activeIndex: 2,
            availableWidth: 347,
            previousVisibleRange: 2..<4
        )
        let moved = TabBarLayout.resolve(
            preferredWidths: Array(repeating: 168, count: 6),
            activeIndex: 4,
            availableWidth: 347,
            previousVisibleRange: 2..<4
        )

        #expect(stable.visibleRange == 2..<4)
        #expect(moved.visibleRange == 3..<5)
        #expect(moved.hiddenIndices == [0, 1, 2, 5])
    }

    @Test("容量为一时首中尾活动标签都可见")
    func oneVisibleTabContainsActiveIndex() {
        for active in [0, 2, 4] {
            let result = TabBarLayout.resolve(
                preferredWidths: Array(repeating: 168, count: 5),
                activeIndex: active,
                availableWidth: 160
            )
            #expect(result.visibleRange == active..<(active + 1))
            #expect(!result.hiddenIndices.contains(active))
        }
    }

    @Test("放大窗口优先向右扩展并在尾部向左补齐")
    func growingWindowFillsContiguousRange() {
        let result = TabBarLayout.resolve(
            preferredWidths: Array(repeating: 168, count: 6),
            activeIndex: 4,
            availableWidth: 465,
            previousVisibleRange: 3..<5
        )

        #expect(result.visibleRange == 3..<6)
        #expect(result.hiddenIndices == [0, 1, 2])
    }

    @Test("空标签和异常输入得到确定结果")
    func normalizesInvalidInput() {
        let empty = TabBarLayout.resolve(
            preferredWidths: [],
            activeIndex: 9,
            availableWidth: .nan
        )
        let invalid = TabBarLayout.resolve(
            preferredWidths: [.nan, .infinity, -3],
            activeIndex: -4,
            availableWidth: -.infinity
        )

        #expect(empty.visibleRange.isEmpty)
        #expect(empty.widths.isEmpty)
        #expect(!empty.showsOverflow)
        #expect(invalid.visibleRange == 0..<1)
        #expect(invalid.widths == [InkDesignTokens.TabBar.minimumTabWidth])
        #expect(invalid.hiddenIndices == [1, 2])
    }
}
```

- [ ] **Step 2: 运行测试并确认类型与 Token 尚不存在**

Run:

```bash
swift test --filter TabBarLayoutTests
```

Expected: FAIL，编译器报告找不到 `TabBarLayout` 和 `InkDesignTokens.TabBar`。

- [ ] **Step 3: 增加标签栏设计 Token**

在 `InkDesignTokens` 的 `Sidebar` 之前加入：

```swift
public enum TabBar {
    public static let minimumTabWidth: CGFloat = 112
    public static let idealTabWidth: CGFloat = 168
    public static let maximumTabWidth: CGFloat = 240
    public static let itemSpacing: CGFloat = 6
    public static let overflowButtonWidth: CGFloat = 28
    public static let closeButtonWidth: CGFloat = 18
}
```

- [ ] **Step 4: 实现纯布局模型**

创建 `Sources/InkShell/TabBarLayout.swift`：

```swift
import Foundation
import InkDesign

struct TabBarLayout: Equatable {
    let visibleRange: Range<Int>
    let hiddenIndices: [Int]
    let widths: [CGFloat]

    var showsOverflow: Bool { !hiddenIndices.isEmpty }

    static func resolve(
        preferredWidths: [CGFloat],
        activeIndex: Int,
        availableWidth: CGFloat,
        previousVisibleRange: Range<Int>? = nil
    ) -> TabBarLayout {
        let count = preferredWidths.count
        guard count > 0 else {
            return TabBarLayout(visibleRange: 0..<0, hiddenIndices: [], widths: [])
        }

        let token = InkDesignTokens.TabBar.self
        let available = availableWidth.isFinite ? max(0, availableWidth) : 0
        let active = min(max(activeIndex, 0), count - 1)
        let preferred = preferredWidths.map { value in
            guard value.isFinite else { return token.idealTabWidth }
            return min(max(value, token.idealTabWidth), token.maximumTabWidth)
        }

        if minimumTotalWidth(count: count) <= available {
            return TabBarLayout(
                visibleRange: 0..<count,
                hiddenIndices: [],
                widths: fittedWidths(preferred, availableWidth: available)
            )
        }

        let tabArea = max(
            0,
            available - token.overflowButtonWidth - token.itemSpacing
        )
        let capacity = max(
            1,
            min(
                count,
                Int(floor(
                    (tabArea + token.itemSpacing)
                        / (token.minimumTabWidth + token.itemSpacing)
                ))
            )
        )
        let maxStart = count - capacity
        var start = min(max(previousVisibleRange?.lowerBound ?? 0, 0), maxStart)
        if active < start {
            start = active
        } else if active >= start + capacity {
            start = active - capacity + 1
        }
        start = min(max(start, 0), maxStart)

        let range = start..<(start + capacity)
        let hidden = Array(0..<range.lowerBound) + Array(range.upperBound..<count)
        let visiblePreferred = Array(preferred[range])
        let usableTabArea = max(tabArea, minimumTotalWidth(count: capacity))
        return TabBarLayout(
            visibleRange: range,
            hiddenIndices: hidden,
            widths: fittedWidths(visiblePreferred, availableWidth: usableTabArea)
        )
    }

    private static func minimumTotalWidth(count: Int) -> CGFloat {
        guard count > 0 else { return 0 }
        let token = InkDesignTokens.TabBar.self
        return CGFloat(count) * token.minimumTabWidth
            + CGFloat(count - 1) * token.itemSpacing
    }

    private static func fittedWidths(
        _ preferred: [CGFloat],
        availableWidth: CGFloat
    ) -> [CGFloat] {
        guard !preferred.isEmpty else { return [] }
        let token = InkDesignTokens.TabBar.self
        let spacing = CGFloat(preferred.count - 1) * token.itemSpacing
        let contentWidth = max(0, availableWidth - spacing)
        let preferredTotal = preferred.reduce(0, +)
        guard preferredTotal > contentWidth else { return preferred }

        let shrinkable = preferred.reduce(0) {
            $0 + max(0, $1 - token.minimumTabWidth)
        }
        guard shrinkable > 0 else {
            return Array(repeating: token.minimumTabWidth, count: preferred.count)
        }
        let ratio = min(1, max(0, (preferredTotal - contentWidth) / shrinkable))
        return preferred.map {
            max(
                token.minimumTabWidth,
                $0 - ($0 - token.minimumTabWidth) * ratio
            )
        }
    }
}
```

- [ ] **Step 5: 运行聚焦测试并确认通过**

Run:

```bash
swift test --filter TabBarLayoutTests
```

Expected: PASS，7 个布局测试无失败。

- [ ] **Step 6: 提交纯布局模型**

```bash
git add Sources/InkDesign/InkDesignTokens.swift Sources/InkShell/TabBarLayout.swift Tests/InkShellTests/TabBarLayoutTests.swift
git commit -m "feat(tabbar): 定义标签溢出的纯布局模型" -m "把宽度夹取、连续可见区间和原始隐藏索引从 AppKit 视图中分离，确保窗口缩放边界可独立验证。\n\nRefs #64"
```

### Task 2: AppKit 标签布置与原生溢出菜单

**Files:**
- Modify: `Sources/InkShell/TabBarView.swift`
- Modify: `Tests/InkShellTests/TabBarViewTests.swift`

**Interfaces:**
- Consumes: `TabBarLayout.resolve(...)` 与 `InkDesignTokens.TabBar`。
- Preserves: `reload(tabs:)`、`onSelect`、`onClose`、`onRename`、`onNewTab`、`onToggleSidebar`、`onSettings`。
- Produces: `visibleTabIndices: [Int]` 与 `overflowMenu: NSMenu?` 作为可观察视图状态。

- [ ] **Step 1: 扩展视图测试，先固定溢出与索引行为**

将现有“设置齿轮固定在最右侧”测试中的按钮计数改为只统计可见按钮：

```swift
#expect(
    buttons.filter { !$0.isHidden && $0.frame.maxX < settings.frame.minX }.count == 2
)
```

在 `TabBarViewTests` 中加入：

```swift
@Test("空间不足时活动标签可见且菜单保留原始索引")
func overflowKeepsActiveTabVisible() throws {
    let tabBar = makeTabBar(width: 520, count: 8, active: 6)
    let overflow = try #require(
        tabBar.subviews.compactMap { $0 as? NSButton }
            .first { $0.toolTip == "更多标签" }
    )
    let menu = try #require(tabBar.overflowMenu)

    #expect(!overflow.isHidden)
    #expect(tabBar.visibleTabIndices.contains(6))
    #expect(!menu.items.map(\.tag).contains(6))
    #expect(menu.items.map(\.tag) == menu.items.map(\.tag).sorted())

    let stack = try #require(tabBar.subviews.first { $0 is NSStackView } as? NSStackView)
    let frames = stack.arrangedSubviews.map(\.frame)
    #expect(frames.allSatisfy { $0.width >= InkDesignTokens.TabBar.minimumTabWidth })
    #expect(zip(frames, frames.dropFirst()).allSatisfy { pair in
        pair.0.maxX <= pair.1.minX
    })
}

@Test("重复标题的菜单项仍选择原始标签") throws {
    let tabs = (0..<8).map {
        TabBarView.Tab(title: $0 == 2 || $0 == 7 ? "重复" : "标签 \($0)", shortcut: "", active: $0 == 0)
    }
    let tabBar = makeTabBar(width: 520, tabs: tabs)
    var selected: Int?
    tabBar.onSelect = { selected = $0 }
    let menu = try #require(tabBar.overflowMenu)
    let itemIndex = try #require(menu.items.firstIndex { $0.tag == 7 })

    menu.performActionForItem(at: itemIndex)

    #expect(selected == 7)
}

@Test("窗口放大后显示更多标签并隐藏空溢出入口") throws {
    let tabs = (0..<4).map {
        TabBarView.Tab(title: "标签 \($0)", shortcut: "⌘\($0 + 1)", active: $0 == 2)
    }
    let tabBar = makeTabBar(width: 520, tabs: tabs)
    let narrowCount = tabBar.visibleTabIndices.count
    #expect(tabBar.overflowMenu != nil)

    tabBar.setFrameSize(NSSize(width: 1000, height: 38))
    tabBar.layoutSubtreeIfNeeded()

    #expect(tabBar.visibleTabIndices.count > narrowCount)
    #expect(tabBar.visibleTabIndices == [0, 1, 2, 3])
    #expect(tabBar.overflowMenu == nil)
    let overflow = try #require(
        tabBar.subviews.compactMap { $0 as? NSButton }
            .first { $0.toolTip == "更多标签" }
    )
    #expect(overflow.isHidden)
}

@Test("活动标签变化只做最小区间移动") {
    let tabBar = makeTabBar(width: 520, count: 8, active: 2)
    let before = tabBar.visibleTabIndices
    tabBar.reload(tabs: makeTabs(count: 8, active: before.last! + 1))
    tabBar.layoutSubtreeIfNeeded()

    #expect(tabBar.visibleTabIndices.dropLast() == before.dropFirst())
    #expect(tabBar.visibleTabIndices.last == before.last! + 1)
}
```

把测试 fixture 替换为：

```swift
private func makeTabBar(
    width: CGFloat = 800,
    count: Int = 1,
    active: Int = 0
) -> TabBarView {
    makeTabBar(width: width, tabs: makeTabs(count: count, active: active))
}

private func makeTabBar(width: CGFloat, tabs: [TabBarView.Tab]) -> TabBarView {
    let tabBar = TabBarView(frame: NSRect(x: 0, y: 0, width: width, height: 38))
    tabBar.reload(tabs: tabs)
    tabBar.layoutSubtreeIfNeeded()
    return tabBar
}

private func makeTabs(count: Int, active: Int) -> [TabBarView.Tab] {
    (0..<count).map {
        TabBarView.Tab(
            title: "标签 \($0)",
            shortcut: $0 < 9 ? "⌘\($0 + 1)" : "",
            active: $0 == active
        )
    }
}
```

- [ ] **Step 2: 运行视图测试并确认溢出接口尚不存在**

Run:

```bash
swift test --filter TabBarViewTests
```

Expected: FAIL，编译器报告 `visibleTabIndices` 和 `overflowMenu` 不存在，或运行时找不到“更多标签”按钮。

- [ ] **Step 3: 保存完整标签模型并配置溢出按钮**

在 `TabBarView` 中增加状态：

```swift
private let overflowButton = TabBarOverflowButton()
private var tabs: [Tab] = []
private var tabItems: [TabItemView] = []
private var widthConstraints: [NSLayoutConstraint] = []
private var previousVisibleRange: Range<Int>?
private var appliedLayout: TabBarLayout?
private(set) var visibleTabIndices: [Int] = []
var overflowMenu: NSMenu? { overflowButton.menu }
```

在 `init` 中配置按钮，并把标签栈改为手动 frame、内部仍由 `NSStackView` 排列：

```swift
overflowButton.isBordered = false
overflowButton.image = NSImage(
    systemSymbolName: "chevron.down",
    accessibilityDescription: nil
)
overflowButton.contentTintColor = InkDesignTokens.Color.textSecondary
overflowButton.toolTip = "更多标签"
overflowButton.setAccessibilityLabel("更多标签")
overflowButton.target = self
overflowButton.action = #selector(showOverflowMenu)
overflowButton.isHidden = true
addSubview(overflowButton)

stack.orientation = .horizontal
stack.distribution = .fill
stack.spacing = InkDesignTokens.TabBar.itemSpacing
stack.alignment = .centerY
addSubview(stack)
```

删除 `stack.translatesAutoresizingMaskIntoConstraints = false` 以及原有的四条 stack
位置和尺寸约束；侧边栏、新建和设置按钮约束保持原样。

- [ ] **Step 4: 让 reload 保留原始索引并触发布局**

用以下实现替换 `reload(tabs:)`：

```swift
func reload(tabs: [Tab]) {
    stack.arrangedSubviews.forEach {
        stack.removeArrangedSubview($0)
        $0.removeFromSuperview()
    }
    tabItems.forEach { $0.removeFromSuperview() }
    widthConstraints.forEach { $0.isActive = false }
    widthConstraints.removeAll(keepingCapacity: true)

    self.tabs = tabs
    tabItems = tabs.enumerated().map { index, tab in
        let item = TabItemView(tab: tab)
        item.translatesAutoresizingMaskIntoConstraints = false
        item.onSelect = { [weak self] in self?.onSelect?(index) }
        item.onClose = { [weak self] in self?.onClose?(index) }
        item.onRename = { [weak self] name in self?.onRename?(index, name) }
        return item
    }
    visibleTabIndices = []
    appliedLayout = nil
    needsLayout = true
}
```

- [ ] **Step 5: 测量标签并应用纯布局结果**

在 `TabItemView` 中增加：

```swift
var preferredWidth: CGFloat {
    let token = InkDesignTokens.TabBar.self
    let fixedWidth = InkDesignTokens.Spacing.xs * 2
        + token.closeButtonWidth
        + 8
        + shortcutLabel.intrinsicContentSize.width
    let measured = titleLabel.intrinsicContentSize.width + fixedWidth
    return min(max(measured, token.idealTabWidth), token.maximumTabWidth)
}
```

并在 `TabItemView` 的约束数组中加入：

```swift
closeButton.widthAnchor.constraint(equalToConstant: InkDesignTokens.TabBar.closeButtonWidth)
```

在 `TabBarView` 中实现：

```swift
override func layout() {
    super.layout()
    let leading = toggleButton.frame.maxX + 10
    let trailing = plusButton.frame.minX - 8
    let availableWidth = max(0, trailing - leading)
    let activeIndex = tabs.firstIndex(where: \.active) ?? 0
    let result = TabBarLayout.resolve(
        preferredWidths: tabItems.map(\.preferredWidth),
        activeIndex: activeIndex,
        availableWidth: availableWidth,
        previousVisibleRange: previousVisibleRange
    )

    if result != appliedLayout {
        apply(result)
        appliedLayout = result
    }
    positionTabRegion(
        result,
        leading: leading,
        trailing: trailing
    )
}

private func apply(_ result: TabBarLayout) {
    stack.arrangedSubviews.forEach {
        stack.removeArrangedSubview($0)
        $0.removeFromSuperview()
    }
    widthConstraints.forEach { $0.isActive = false }
    widthConstraints.removeAll(keepingCapacity: true)

    visibleTabIndices = Array(result.visibleRange)
    for (offset, index) in visibleTabIndices.enumerated() {
        let item = tabItems[index]
        stack.addArrangedSubview(item)
        let constraint = item.widthAnchor.constraint(equalToConstant: result.widths[offset])
        constraint.isActive = true
        widthConstraints.append(constraint)
    }
    previousVisibleRange = result.visibleRange
    rebuildOverflowMenu(hiddenIndices: result.hiddenIndices)
}

private func positionTabRegion(
    _ result: TabBarLayout,
    leading: CGFloat,
    trailing: CGFloat
) {
    let token = InkDesignTokens.TabBar.self
    let height: CGFloat = 28
    let y = (bounds.height - height) / 2
    let stackWidth = result.widths.reduce(0, +)
        + CGFloat(max(0, result.widths.count - 1)) * token.itemSpacing
    stack.frame = NSRect(x: leading, y: y, width: stackWidth, height: height)

    overflowButton.isHidden = !result.showsOverflow
    if result.showsOverflow {
        overflowButton.frame = NSRect(
            x: trailing - token.overflowButtonWidth,
            y: y,
            width: token.overflowButtonWidth,
            height: height
        )
    } else {
        overflowButton.frame = .zero
    }
}
```

- [ ] **Step 6: 构建原生菜单并按 tag 回调原始索引**

在 `TabBarView` 中加入：

```swift
private func rebuildOverflowMenu(hiddenIndices: [Int]) {
    guard !hiddenIndices.isEmpty else {
        overflowButton.menu = nil
        return
    }

    let menu = NSMenu(title: "更多标签")
    menu.autoenablesItems = false
    for index in hiddenIndices where tabs.indices.contains(index) {
        let tab = tabs[index]
        let item = NSMenuItem(
            title: tab.title,
            action: #selector(selectOverflowTab(_:)),
            keyEquivalent: ""
        )
        item.target = self
        item.tag = index
        item.isEnabled = true
        if index < 9 {
            item.keyEquivalent = String(index + 1)
            item.keyEquivalentModifierMask = .command
        }
        menu.addItem(item)
    }
    overflowButton.menu = menu
}

@objc private func showOverflowMenu() {
    guard let menu = overflowButton.menu else { return }
    menu.popUp(
        positioning: nil,
        at: NSPoint(x: 0, y: overflowButton.bounds.minY),
        in: overflowButton
    )
}

@objc private func selectOverflowTab(_ sender: NSMenuItem) {
    guard tabs.indices.contains(sender.tag) else { return }
    onSelect?(sender.tag)
}
```

在 `TabBarView.swift` 末尾增加与设置按钮相同视觉语言、但不持有选中态的按钮：

```swift
@MainActor
private final class TabBarOverflowButton: NSButton {
    private var isHovered = false

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layer?.cornerRadius = InkDesignTokens.Radius.item
        layer?.cornerCurve = .continuous
        addTrackingArea(NSTrackingArea(
            rect: .zero,
            options: [.mouseEnteredAndExited, .activeInKeyWindow, .inVisibleRect],
            owner: self
        ))
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("代码构建") }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        updateLayerColors()
    }

    override func mouseEntered(with event: NSEvent) {
        isHovered = true
        updateLayerColors()
    }

    override func mouseExited(with event: NSEvent) {
        isHovered = false
        updateLayerColors()
    }

    private func updateLayerColors() {
        effectiveAppearance.performAsCurrentDrawingAppearance {
            layer?.backgroundColor = isHovered
                ? InkDesignTokens.Color.pill.cgColor
                : nil
        }
    }
}
```

- [ ] **Step 7: 运行布局与视图测试并确认通过**

Run:

```bash
swift test --filter 'TabBarLayoutTests|TabBarViewTests|SettingsWindowTests'
```

Expected: PASS，新增布局和溢出视图测试通过，设置页顶部栏测试无回归。

- [ ] **Step 8: 提交 AppKit 溢出菜单**

```bash
git add Sources/InkShell/TabBarView.swift Tests/InkShellTests/TabBarViewTests.swift
git commit -m "feat(tabbar): 在空间不足时收纳隐藏标签" -m "用连续可见区间保留活动标签，并通过原生菜单按原始索引切换隐藏标签，避免窄窗口继续压扁所有标签。\n\nRefs #64"
```

### Task 3: 设计系统规范与完整回归

**Files:**
- Modify: `docs/design-system.md`

**Interfaces:**
- Consumes: 已实现的 112/168/240 pt 宽度、连续区间和“更多标签”菜单。
- Produces: 顶部标签栏的长期视觉、交互、辅助功能和性能约束。

- [ ] **Step 1: 同步设计系统**

在 `docs/design-system.md` 的“尺度”之后加入：

```markdown
## 顶部标签栏

标签最小宽度为 112pt，理想宽度为 168pt，最大宽度为 240pt。短标题使用理想
宽度，长标题最多扩展到最大宽度；空间不足时可压缩到最小宽度，但不得继续压扁。

所有标签以最小宽度仍放不下时，顶部栏只显示包含活动标签的连续区间，并在新建标签
按钮左侧显示 28pt 的“更多标签”原生菜单。活动标签始终可见；区间只做包含活动标签
所需的最小移动。菜单只列隐藏标签，保持原始顺序和原始索引。

标签栏剩余空间继续作为窗口拖动区域。标签、溢出、新建和设置按钮不触发窗口拖动。
溢出入口使用 SF Symbol、tooltip 和“更多标签”辅助功能标签，不自绘菜单，不增加横向
滚动位置，也不进入终端逐帧渲染路径。
```

- [ ] **Step 2: 运行文档与 diff 检查**

Run:

```bash
git diff --check
rg -n '112pt|168pt|240pt|更多标签|活动标签始终可见' docs/design-system.md
```

Expected: `git diff --check` 无输出；`rg` 命中新增顶部标签栏规范。

- [ ] **Step 3: 提交设计系统同步**

```bash
git add docs/design-system.md
git commit -m "docs(ui): 固定标签栏宽度与溢出规范" -m "让后续标签状态和会话恢复功能继续遵守活动标签可见、原始顺序和原生菜单边界。\n\nRefs #64"
```

## Final Verification And Runtime Acceptance

- [ ] **Step 1: 运行完整测试和构建**

Run:

```bash
swift test
swift build
git diff --check
git status --short --branch -uall
```

Expected: 全部测试通过；构建完成且无 warning；diff 检查无输出；工作区只包含计划内提交。

- [ ] **Step 2: 在干净临时 worktree 复核完整分支**

Run:

```bash
verify_dir=$(mktemp -d /tmp/ink-issue-64-verify.XXXXXX)
git worktree add --detach "$verify_dir" HEAD
(cd "$verify_dir" && swift test && swift build)
git worktree remove "$verify_dir"
```

Expected: 临时 worktree 中测试和构建均成功，随后 worktree 被移除。

- [ ] **Step 3: 生成并解压真实发布结构的临时 App**

Run:

```bash
package_dir=$(mktemp -d /tmp/ink-tab-overflow-package.XXXXXX)
scripts/package-app.sh v2026.07.22-64 "$package_dir"
mkdir "$package_dir/unpacked"
ditto -x -k "$package_dir/Ink-v2026.07.22-64.zip" "$package_dir/unpacked"
codesign --verify --deep --strict --verbose=2 "$package_dir/unpacked/Ink.app"
open "$package_dir/unpacked/Ink.app"
```

Expected: universal 临时包生成、解压和签名校验成功，启动的是临时路径下的 `Ink.app`；不创建或推送 Git tag。

- [ ] **Step 4: 完成真实窗口 smoke checklist**

在临时 App 中验证：

1. 创建至少 12 个标题长短不同的标签。
2. 在窗口最小宽度 520 pt 与常用宽度之间连续缩放，标签与尾部按钮不重叠。
3. 活动标签始终留在顶部；从菜单选择首、中、尾部隐藏标签后只做最小区间移动。
4. 重复标题选择正确，菜单顺序与标签原始顺序一致。
5. `⌘1` 到 `⌘9`、前后标签、新建、关闭、双击重命名、设置页和侧边栏三态无回归。
6. 浅色、深色和 VoiceOver 下“更多标签”按钮与菜单可识别。
7. 退出临时 App，确认测试期间没有启动 `/Applications/Ink.app`。

- [ ] **Step 5: 评审、推送和 PR**

执行合并前代码评审，修复所有 Critical 和 Important 发现。重新运行 `swift test`、
`swift build` 与真实 App smoke 后推送 `agent/issue-64-tab-overflow`，创建对准 `main`
的 PR。PR 标题使用 `feat(tabbar): 支持标签宽度与溢出菜单`，描述包含改动、验证、
风险、文档、无发布说明和唯一关闭引用 `Closes #64`。

- [ ] **Step 6: 管理员 squash 合并并验证 main**

确认 PR 可合并且 Issue #64 仍开放后，由仓库拥有者管理员 squash 合并并删除分支。
拉取最新 `main`，确认 Issue 自动关闭、远端分支删除，再运行 `swift test` 与
`swift build`。本任务不创建版本标签，也不触发发布。
