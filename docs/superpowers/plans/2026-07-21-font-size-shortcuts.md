# Font Size Shortcuts Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** 为 Ink 增加 `⌘+`、`⌘-`、`⌘0` 字号命令，并让变化通过现有配置链路同步设置页、所有 pane、TOML 与 iCloud。

**Architecture:** `InkConfig` 暴露字号默认值和有效范围，`InkShell` 的纯值 `FontSizeCommand` 负责计算目标值。`MainWindowController` 的菜单动作只复制当前配置、修改 `fontSize` 并复用 `saveConfig`；`AppDelegate` 只定义原生菜单和快捷键。

**Tech Stack:** Swift 6、AppKit、Swift Testing、SwiftPM、现有 `InkConfig` / `InkShell` 模块。

## Global Constraints

- 最低系统版本保持 macOS 14.0。
- 不新增第三方依赖。
- `TerminalCore` 不得引入 AppKit 或 Metal；本功能不修改 `TerminalCore`。
- 字号范围固定为 6–72 pt，默认值固定为 15 pt，步长固定为 1 pt。
- 快捷键固定为 `⌘+`、`⌘-`、`⌘0`；切换侧边栏改为 `⌃⌘S`。
- 单次命令同步所有可见 pane、设置页、TOML 和已有 iCloud 自动上传链路。
- 不增加单 pane 字号、HUD 或快捷键自定义。
- 不进入 grid、scrollback 或每帧渲染热路径，不增加 per-cell/per-line 常驻数据。
- 用户可见文案与代码注释使用中文，代码标识符使用英文。
- 关联 Issue #60；提交信息使用中文 Conventional Commit，PR 描述仅使用 `Closes #60` 关闭 Issue。

---

## File Map

- `Sources/InkConfig/InkConfig.swift`：字号默认值、有效范围及 TOML 校验的权威来源。
- `Sources/InkShell/FontSizeCommand.swift`：纯值字号命令和夹取规则。
- `Sources/InkShell/MainWindowController.swift`：AppKit action 与现有 `saveConfig` 链路接线。
- `Sources/InkShell/AppDelegate.swift`：显示菜单标题和快捷键。
- `Tests/InkConfigTests/InkConfigTests.swift`：配置常量与默认值契约。
- `Tests/InkShellTests/FontSizeCommandTests.swift`：纯命令规则、持久化、设置页、pane 和 iCloud 集成测试。
- `Tests/InkShellTests/FontSizeMenuTests.swift`：显示菜单动作与快捷键回归测试。

### Task 1: 字号配置契约与纯命令规则

**Files:**
- Modify: `Sources/InkConfig/InkConfig.swift`
- Create: `Sources/InkShell/FontSizeCommand.swift`
- Modify: `Tests/InkConfigTests/InkConfigTests.swift`
- Create: `Tests/InkShellTests/FontSizeCommandTests.swift`

**Interfaces:**
- Consumes: 现有 `InkConfig.fontSize: Double`。
- Produces: `InkConfig.defaultFontSize: Double`、`InkConfig.fontSizeRange: ClosedRange<Double>`、`FontSizeCommand.updatedValue(from:) -> Double`。

- [ ] **Step 1: 写配置常量与纯命令的失败测试**

在 `InkConfigTests` 的 `InkConfigTests` suite 中加入：

```swift
@Test("字号默认值与有效范围有单一配置契约")
func fontSizeContract() {
    #expect(InkConfig.defaultFontSize == 15)
    #expect(InkConfig.fontSizeRange == 6...72)
    #expect(InkConfig().fontSize == InkConfig.defaultFontSize)
}
```

创建 `Tests/InkShellTests/FontSizeCommandTests.swift`：

```swift
import InkConfig
import Testing
@testable import InkShell

@Suite("字号命令")
struct FontSizeCommandTests {
    @Test("按一磅步进并恢复 Ink 默认字号")
    func stepAndReset() {
        #expect(FontSizeCommand.increase.updatedValue(from: 15) == 16)
        #expect(FontSizeCommand.decrease.updatedValue(from: 15) == 14)
        #expect(FontSizeCommand.reset.updatedValue(from: 31) == 15)
    }

    @Test("字号命令不会越过配置边界")
    func clampsToRange() {
        #expect(FontSizeCommand.decrease.updatedValue(from: 6) == 6)
        #expect(FontSizeCommand.increase.updatedValue(from: 72) == 72)
    }
}
```

- [ ] **Step 2: 运行测试并确认因契约与命令尚不存在而失败**

Run:

```bash
swift test --filter 'InkConfigTests|FontSizeCommandTests'
```

Expected: FAIL，编译器报告 `InkConfig` 缺少 `defaultFontSize` / `fontSizeRange`，且找不到 `FontSizeCommand`。

- [ ] **Step 3: 实现最小配置契约与纯命令**

在 `InkConfig` 中加入并复用常量：

```swift
public static let defaultFontSize = 15.0
public static let fontSizeRange = 6.0...72.0

public var fontSize = InkConfig.defaultFontSize
```

将 TOML 读取校验改为：

```swift
if let size = values.double("font.size"), Self.fontSizeRange.contains(size) {
    config.fontSize = size
}
```

创建 `Sources/InkShell/FontSizeCommand.swift`：

```swift
import InkConfig

enum FontSizeCommand {
    case increase
    case decrease
    case reset

    func updatedValue(from current: Double) -> Double {
        switch self {
        case .increase:
            min(current + 1, InkConfig.fontSizeRange.upperBound)
        case .decrease:
            max(current - 1, InkConfig.fontSizeRange.lowerBound)
        case .reset:
            InkConfig.defaultFontSize
        }
    }
}
```

- [ ] **Step 4: 运行聚焦测试并确认通过**

Run:

```bash
swift test --filter 'InkConfigTests|FontSizeCommandTests'
```

Expected: PASS，新增两组字号命令测试和配置契约测试均无失败。

- [ ] **Step 5: 提交配置契约与纯规则**

```bash
git add Sources/InkConfig/InkConfig.swift Sources/InkShell/FontSizeCommand.swift Tests/InkConfigTests/InkConfigTests.swift Tests/InkShellTests/FontSizeCommandTests.swift
git commit -m "feat(config): 统一字号命令的默认值与边界" -m "让快捷键和配置读取共享同一份 6–72 pt 契约，避免默认值与夹取规则漂移。\n\nRefs #60"
```

### Task 2: 窗口动作接入统一配置保存链路

**Files:**
- Modify: `Sources/InkShell/MainWindowController.swift`
- Modify: `Tests/InkShellTests/FontSizeCommandTests.swift`

**Interfaces:**
- Consumes: `FontSizeCommand.updatedValue(from:) -> Double` 与现有 `MainWindowController.saveConfig(_:)`。
- Produces: `increaseFontSize(_:)`、`decreaseFontSize(_:)`、`resetFontSize(_:)` 三个 ObjC actions。

- [ ] **Step 1: 写窗口动作持久化与设置页同步的失败测试**

在 `FontSizeCommandTests` 增加 `AppKit`、`Foundation` import，并将 suite 标为 `.serialized`、`@MainActor`。加入临时配置 fixture 后添加：

```swift
@Test("窗口字号动作写回 TOML 并同步已打开的设置页")
func windowActionPersistsAndUpdatesSettings() throws {
    let fixture = try FontSizeWindowFixture(fontSize: 15)
    defer { fixture.cleanUp() }
    fixture.controller.showSettings(nil)

    let action = NSSelectorFromString("increaseFontSize:")
    #expect(fixture.controller.responds(to: action))
    #expect(NSApp.sendAction(action, to: fixture.controller, from: nil))

    #expect(InkConfig.load(from: fixture.configURL).fontSize == 16)
    let values = fixture.allSubviews().compactMap { $0.accessibilityValue() as? String }
    #expect(values.contains("16 pt"))
    let preview = try #require(fixture.allSubviews().first {
        $0.accessibilityLabel() == "终端配色预览"
    })
    let previewFont = try #require(
        fixture.allSubviews(in: preview)
            .compactMap { $0 as? NSTextField }
            .first?.attributedStringValue.attribute(
                .font,
                at: 0,
                effectiveRange: nil
            ) as? NSFont
    )
    #expect(previewFont.pointSize == 16)
}
```

在测试文件底部加入完整 fixture；同时在文件顶部 import `InkTerminalView`：

```swift
@MainActor
private struct FontSizeWindowFixture {
    let controller: MainWindowController
    let configURL: URL
    let store: FontSizeMemoryCloudStore
    let defaults: UserDefaults
    let suite: String
    let directory: URL

    init(fontSize: Double, automaticUpload: Bool = false) throws {
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("ink-font-size-\(UUID().uuidString)")
        try FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: true
        )
        configURL = directory.appendingPathComponent("config.toml")
        var config = InkConfig()
        config.fontSize = fontSize
        try config.save(to: configURL)

        suite = "ink-font-size-defaults-\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suite)!
        defaults.removePersistentDomain(forName: suite)
        defaults.set(automaticUpload, forKey: "ink.sync.automaticUpload")
        store = FontSizeMemoryCloudStore()
        controller = MainWindowController(
            initialConfig: config,
            configURL: configURL,
            configSyncService: ConfigSyncService(store: store, defaults: defaults)
        )
        controller.window?.orderFront(nil)
    }

    func send(_ selectorName: String) throws {
        let selector = NSSelectorFromString(selectorName)
        try #require(controller.responds(to: selector))
        #expect(NSApp.sendAction(selector, to: controller, from: nil))
    }

    func allSubviews() -> [NSView] {
        guard let content = controller.window?.contentView else { return [] }
        return allSubviews(in: content)
    }

    func allSubviews(in view: NSView) -> [NSView] {
        view.subviews.flatMap { [$0] + allSubviews(in: $0) }
    }

    func spinRunLoop(cycles: Int = 8) {
        for _ in 0..<cycles {
            RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.05))
        }
    }

    func cleanUp() {
        controller.window?.close()
        defaults.removePersistentDomain(forName: suite)
        try? FileManager.default.removeItem(at: directory)
    }
}

@MainActor
private final class FontSizeMemoryCloudStore: ConfigCloudStore {
    var isAvailable = true
    var setCallCount = 0
    private var values: [String: Data] = [:]

    func data(forKey key: String) -> Data? { values[key] }

    func set(_ data: Data, forKey key: String) {
        setCallCount += 1
        values[key] = data
    }

    func synchronize() -> Bool { true }
}
```

这样测试不读写用户的真实配置或 iCloud。

- [ ] **Step 2: 写 pane、iCloud、重置与边界的失败测试**

继续加入：

```swift
@Test("字号动作同步全部可见 pane 并触发自动上传")
func windowActionUpdatesAllPanesAndCloud() throws {
    let fixture = try FontSizeWindowFixture(fontSize: 15, automaticUpload: true)
    defer { fixture.cleanUp() }
    fixture.controller.newSession(nil)
    fixture.spinRunLoop()
    fixture.controller.splitRight(nil)
    fixture.spinRunLoop()

    try fixture.send("increaseFontSize:")

    let terminalViews = fixture.allSubviews().compactMap { $0 as? TerminalMetalView }
    #expect(terminalViews.count == 2)
    #expect(terminalViews.allSatisfy { $0.fontSize == 16 })
    #expect(fixture.store.setCallCount == 1)
}

@Test("恢复默认且边界上的无效动作不重复保存或上传")
func resetAndNoOpBoundaries() throws {
    let upper = try FontSizeWindowFixture(fontSize: 72, automaticUpload: true)
    defer { upper.cleanUp() }
    try upper.send("increaseFontSize:")
    #expect(InkConfig.load(from: upper.configURL).fontSize == 72)
    #expect(upper.store.setCallCount == 0)

    try upper.send("resetFontSize:")
    #expect(InkConfig.load(from: upper.configURL).fontSize == 15)
    #expect(upper.store.setCallCount == 1)

    let lower = try FontSizeWindowFixture(fontSize: 6)
    defer { lower.cleanUp() }
    try lower.send("decreaseFontSize:")
    #expect(InkConfig.load(from: lower.configURL).fontSize == 6)
}
```

- [ ] **Step 3: 运行窗口动作测试并确认因 selector 尚不存在而失败**

Run:

```bash
swift test --filter FontSizeCommandTests
```

Expected: FAIL，`responds(to:)` 为 false 或动作没有更新临时 TOML；进程不得崩溃。

- [ ] **Step 4: 实现三个 action 和共享命令入口**

在 `MainWindowController` 加入：

```swift
@objc public func increaseFontSize(_ sender: Any?) {
    performFontSizeCommand(.increase)
}

@objc public func decreaseFontSize(_ sender: Any?) {
    performFontSizeCommand(.decrease)
}

@objc public func resetFontSize(_ sender: Any?) {
    performFontSizeCommand(.reset)
}

private func performFontSizeCommand(_ command: FontSizeCommand) {
    let target = command.updatedValue(from: config.fontSize)
    guard target != config.fontSize else { return }
    var fresh = config
    fresh.fontSize = target
    saveConfig(fresh)
}
```

不得直接设置 `TerminalMetalView.fontSize`，也不得在 action 中重复 TOML、设置页或 iCloud
逻辑；同步必须完全依赖现有 `saveConfig`。

- [ ] **Step 5: 运行聚焦测试并确认通过**

Run:

```bash
swift test --filter FontSizeCommandTests
```

Expected: PASS；TOML 为 16、两个可见 pane 均为 16、设置控件和预览为 16、自动上传一次，
边界无效操作不上传，恢复默认后为 15。

- [ ] **Step 6: 提交窗口同步链路**

```bash
git add Sources/InkShell/MainWindowController.swift Tests/InkShellTests/FontSizeCommandTests.swift
git commit -m "feat(shell): 让字号动作复用配置同步链路" -m "快捷键变化先持久化，再统一刷新设置页、全部 pane 与 iCloud；边界无效操作不制造写入。\n\nRefs #60"
```

### Task 3: 原生显示菜单与快捷键

**Files:**
- Modify: `Sources/InkShell/AppDelegate.swift`
- Create: `Tests/InkShellTests/FontSizeMenuTests.swift`

**Interfaces:**
- Consumes: Task 2 的三个 `MainWindowController` ObjC actions 与现有 `NSSplitViewController.toggleSidebar(_:)`。
- Produces: “显示”菜单中的四个稳定菜单项与快捷键绑定。

- [ ] **Step 1: 写菜单绑定的失败测试**

创建 `Tests/InkShellTests/FontSizeMenuTests.swift`：

```swift
import AppKit
import Testing
@testable import InkShell

@Suite("字号菜单", .serialized)
@MainActor
struct FontSizeMenuTests {
    @Test("显示菜单提供字号命令与新的侧边栏快捷键")
    func viewMenuBindings() throws {
        let menu = AppDelegate.makeMainMenu()
        let view = try #require(menu.items.first { $0.submenu?.title == "显示" }?.submenu)
        let expected: [(String, Selector, String, NSEvent.ModifierFlags)] = [
            ("放大字号", #selector(MainWindowController.increaseFontSize(_:)), "+", [.command]),
            ("缩小字号", #selector(MainWindowController.decreaseFontSize(_:)), "-", [.command]),
            ("恢复默认字号", #selector(MainWindowController.resetFontSize(_:)), "0", [.command]),
            ("切换侧边栏", #selector(NSSplitViewController.toggleSidebar(_:)), "s", [.command, .control]),
        ]

        for (title, action, key, modifiers) in expected {
            let item = try #require(view.items.first { $0.title == title })
            #expect(item.action == action)
            #expect(item.keyEquivalent == key)
            #expect(item.keyEquivalentModifierMask == modifiers)
        }
        #expect(view.items.contains { $0.isSeparatorItem })
    }
}
```

- [ ] **Step 2: 运行菜单测试并确认因菜单项缺失与旧快捷键冲突而失败**

Run:

```bash
swift test --filter FontSizeMenuTests
```

Expected: FAIL，找不到“放大字号”等菜单项，且“切换侧边栏”仍为 `⌘0`。

- [ ] **Step 3: 实现显示菜单**

在 `AppDelegate.makeMainMenu` 的“显示”菜单中依次加入三个字号项：

```swift
viewMenu.addItem(
    withTitle: "放大字号",
    action: #selector(MainWindowController.increaseFontSize(_:)),
    keyEquivalent: "+"
)
viewMenu.addItem(
    withTitle: "缩小字号",
    action: #selector(MainWindowController.decreaseFontSize(_:)),
    keyEquivalent: "-"
)
viewMenu.addItem(
    withTitle: "恢复默认字号",
    action: #selector(MainWindowController.resetFontSize(_:)),
    keyEquivalent: "0"
)
viewMenu.addItem(.separator())
```

用显式 `NSMenuItem` 替换现有侧边栏项，以便设置修饰键：

```swift
let sidebarItem = NSMenuItem(
    title: "切换侧边栏",
    action: #selector(NSSplitViewController.toggleSidebar(_:)),
    keyEquivalent: "s"
)
sidebarItem.keyEquivalentModifierMask = [.command, .control]
viewMenu.addItem(sidebarItem)
```

- [ ] **Step 4: 运行菜单测试和字号测试并确认通过**

Run:

```bash
swift test --filter 'FontSizeMenuTests|FontSizeCommandTests'
```

Expected: PASS；四个菜单项的 selector、key equivalent 和 modifier mask 全部匹配。

- [ ] **Step 5: 提交原生菜单**

```bash
git add Sources/InkShell/AppDelegate.swift Tests/InkShellTests/FontSizeMenuTests.swift
git commit -m "feat(shell): 增加原生字号快捷键" -m "将 ⌘0 交还字号恢复，并用 ⌃⌘S 保留侧边栏切换入口。\n\nRefs #60"
```

### Task 4: 全量验证、文档核对与 PR 准备

**Files:**
- Verify: `docs/roadmap.md`
- Verify: `docs/superpowers/specs/2026-07-21-font-size-shortcuts-design.md`
- Verify: all files changed since `origin/main`

**Interfaces:**
- Consumes: Tasks 1–3 的完整实现。
- Produces: 可供代码评审和 PR 合入的已验证分支。

- [ ] **Step 1: 运行格式与差异检查**

Run:

```bash
git diff --check origin/main...HEAD
git status --short
```

Expected: `git diff --check` exit 0；工作区无未提交文件。

- [ ] **Step 2: 运行全部测试**

Run:

```bash
swift test
```

Expected: exit 0，全部 suite 和 test 通过，0 failures。

- [ ] **Step 3: 运行 debug 构建**

Run:

```bash
swift build
```

Expected: exit 0，无 warning 或 error。

- [ ] **Step 4: 对照设计逐项审计**

Run:

```bash
git diff --stat origin/main...HEAD
git diff origin/main...HEAD -- Sources/InkConfig/InkConfig.swift Sources/InkShell/FontSizeCommand.swift Sources/InkShell/MainWindowController.swift Sources/InkShell/AppDelegate.swift Tests/InkConfigTests/InkConfigTests.swift Tests/InkShellTests/FontSizeCommandTests.swift Tests/InkShellTests/FontSizeMenuTests.swift
```

Expected: 仅包含 Issue #60 范围；确认 1 pt 步进、6–72 边界、15 pt 重置、四组快捷键、
`saveConfig` 单一路径、设置页/pane/TOML/iCloud 测试证据均存在。roadmap 已包含该功能且范围
未变化，因此不修改 roadmap。

- [ ] **Step 5: 人工检查原生行为**

Run:

```bash
swift run ink
```

Expected: “显示”菜单显示四个入口；多分屏下 `⌘+`/`⌘-` 同步变化，设置页打开时控件和
预览同步，`⌘0` 回到 15 pt，`⌃⌘S` 切换侧边栏。检查完成后正常退出 Ink。

- [ ] **Step 6: 推送并创建 PR**

```bash
git push -u origin agent/issue-60-font-size-shortcuts
gh pr create --base main --head agent/issue-60-font-size-shortcuts --title "feat(shell): 支持字号快捷键与设置同步" --body $'## 改动说明\n\n- 增加字号放大、缩小与恢复默认值的原生菜单和快捷键\n- 复用配置保存链路，同步设置页、全部 pane、TOML 与 iCloud\n- 将切换侧边栏快捷键调整为 ⌃⌘S\n\n## 验证\n\n- swift test\n- swift build\n- 人工验证多分屏、设置页和显示菜单\n\n## 风险\n\n- 仅在用户触发命令时重建终端字体资源，不改变每帧渲染热路径\n\n## 文档\n\n- 新增设计说明和实施计划；roadmap 范围不变\n\n## 发布\n\n- 不涉及发布\n\nCloses #60'
```

Expected: 分支推送成功，PR 目标为 `main`，只关联并关闭 Issue #60，不创建 tag。
