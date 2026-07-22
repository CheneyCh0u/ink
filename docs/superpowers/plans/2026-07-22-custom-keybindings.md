# 快捷键自定义 Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** 用一份纯配置快捷键模型统一 TOML、iCloud、设置录制、原生菜单和现有分屏前缀手势，并保持当前行为为默认值。

**Architecture:** `InkConfig` 定义无 AppKit 的 action、binding、完整 assignment set、解析和冲突消解；`InkShell` 只负责 AppKit key equivalent、菜单 descriptor、事件录制和分屏前缀适配。配置变化重建主菜单并取消旧分屏 pending 状态，不触碰 TerminalCore 或渲染路径。

**Tech Stack:** Swift 6、Swift Testing、Foundation、AppKit、SwiftPM；最低 macOS 14.0；零第三方依赖。

## Global Constraints

- Issue #79 分支开发，中文提交并使用 `Refs #79`；未经用户明确要求不发布。
- `InkConfig` 不得依赖 AppKit；TerminalCore、PTY、Metal、grid、scrollback 不得修改。
- 当前快捷键行为是默认值；非法单项回退默认，不能阻止 Ink 启动。
- 每个启用绑定至少含 `cmd` 或 `ctrl`，避免抢占普通终端输入。
- 菜单显示、实际响应、设置页和热重载必须共享同一 `KeyBindingSet`。
- `split_prefix` 只保留现有专用前缀+方向语义，不实现通用 chord、宏或脚本。
- 配置 wire schema 维持 1，旧快照缺字段必须迁移为 defaults。
- 开发阶段只跑 focused tests；完整测试、构建和总审查由所有并发功能结束后统一执行。

---

## 文件结构

- Create `Sources/InkConfig/KeyBindings.swift`：action、modifier、key、assignment、默认集合、parser、validator。
- Modify `Sources/InkConfig/InkConfig.swift`：TOML load/save 与公开配置字段。
- Modify `Sources/InkConfig/ConfigSyncSnapshot.swift`：可缺省 schema 1 wire map。
- Create `Tests/InkConfigTests/KeyBindingTests.swift`：纯模型、冲突、TOML 与 wire 测试。
- Create `Sources/InkShell/KeyBindingAppKitAdapter.swift`：AppKit 转换与 glyph。
- Create `Sources/InkShell/MenuCommandDescriptor.swift`：action 到标题/selector/menu 的单一表。
- Modify `Sources/InkShell/AppDelegate.swift`：按 binding 构造/重建菜单。
- Modify `Sources/InkShell/MainWindowController.swift`：热应用回调与 split prefix recognizer。
- Modify `Sources/InkShell/SplitShortcutState.swift`：移除硬编码 prefix keyCode/modifier。
- Modify `Sources/InkShell/TabBarView.swift`：固定会话 1～9 保持不变，不接收自定义 action。
- Create `Sources/InkShell/KeyBindingRecorderControl.swift`：原生录制、错误和清除控件。
- Modify `Sources/InkShell/SettingsViewController.swift`：快捷键 section、恢复默认和外部刷新。
- Create `Tests/InkShellTests/KeyBindingMenuTests.swift`：菜单/adapter/热重建。
- Modify `Tests/InkShellTests/SplitShortcutStateTests.swift`：可配置前缀状态机。
- Create `Tests/InkShellTests/KeyBindingSettingsTests.swift`：录制、错误、清除、恢复默认。

---

### Task 1: 纯 Swift 快捷键值模型、语法与冲突消解

**Files:**
- Create: `Sources/InkConfig/KeyBindings.swift`
- Create: `Tests/InkConfigTests/KeyBindingTests.swift`

**Interfaces:**
- Produces: `KeyBindingAction`、`KeyBindingModifiers`、`KeyBinding`、`KeyBindingAssignment`、`KeyBindingSet`、`KeyBindingValidationIssue`。
- Consumes: 无；本任务不得 import AppKit。

- [ ] **Step 1: 写默认集合与 parser 的失败测试**

```swift
import Testing
@testable import InkConfig

@Suite("快捷键配置")
struct KeyBindingTests {
    @Test("默认 action 完整且非空绑定唯一")
    func defaultsAreCompleteAndUnique() {
        let defaults = KeyBindingSet.defaults
        #expect(KeyBindingAction.allCases.allSatisfy { defaults.assignment(for: $0) != nil })
        let enabled = KeyBindingAction.allCases.compactMap { defaults.binding(for: $0) }
        #expect(Set(enabled).count == enabled.count)
        #expect(defaults.binding(for: .newTab)?.serialized == "cmd+t")
        #expect(defaults.binding(for: .splitPrefix)?.serialized == "cmd+d")
        #expect(defaults.assignment(for: .splitLeft) == .disabled)
    }

    @Test("解析别名并生成规范字符串")
    func parserNormalizesAliases() throws {
        let binding = try #require(KeyBinding.parse("Control+Option+Shift+Command+LEFT"))
        #expect(binding.serialized == "cmd+ctrl+alt+shift+left")
        #expect(KeyBinding.parse("shift+a") == nil)
        #expect(KeyBinding.parse("cmd+a+b") == nil)
        #expect(KeyBinding.parse("cmd+cmd+a") == nil)
        #expect(KeyBinding.parse("cmd+f21") == nil)
    }
}
```

- [ ] **Step 2: 确认 RED**

Run: `swift test --no-parallel --filter KeyBindingTests`

Expected: FAIL，缺少 `KeyBindingSet` / `KeyBindingAction`。

- [ ] **Step 3: 实现 action、modifier 和 key parser**

action rawValue 必须与 TOML key 完全一致，顺序也是冲突报告和设置 UI 的稳定顺序：

```swift
public enum KeyBindingAction: String, CaseIterable, Hashable, Sendable {
    case newProject = "new_project", newTab = "new_tab", closePane = "close_pane"
    case splitPrefix = "split_prefix"
    case splitLeft = "split_left", splitRight = "split_right"
    case splitUp = "split_up", splitDown = "split_down"
    case focusLeft = "focus_left", focusRight = "focus_right"
    case focusUp = "focus_up", focusDown = "focus_down"
    case find
    case fontIncrease = "font_increase", fontDecrease = "font_decrease"
    case fontReset = "font_reset"
    case previousCommand = "previous_command", nextCommand = "next_command"
    case copyCommand = "copy_command", copyOutput = "copy_output"
    case previousTab = "previous_tab", nextTab = "next_tab"
    case toggleSidebar = "toggle_sidebar"
}

public struct KeyBindingModifiers: OptionSet, Hashable, Sendable {
    public let rawValue: UInt8
    public init(rawValue: UInt8) { self.rawValue = rawValue }
    public static let command = Self(rawValue: 1 << 0)
    public static let control = Self(rawValue: 1 << 1)
    public static let option = Self(rawValue: 1 << 2)
    public static let shift = Self(rawValue: 1 << 3)
}

public struct KeyBinding: Hashable, Sendable {
    public let key: String
    public let modifiers: KeyBindingModifiers
    public static func parse(_ text: String) -> KeyBinding?
    public var serialized: String { get }
}
```

parser trim 外围空白、按 `+` 分割但不接受空 token。修饰键 alias 映射到四个 bit 并拒绝重复；最后一个 token 必须通过固定 key token validator。要求 `.command` 或 `.control` 至少一个。`serialized` 用 command/control/option/shift 的固定顺序和规范 key。

- [ ] **Step 4: 实现 assignment、defaults 与验证 issue**

```swift
public enum KeyBindingAssignment: Equatable, Sendable {
    case disabled
    case binding(KeyBinding)
}

public enum KeyBindingValidationIssue: Equatable, Sendable {
    case invalidSyntax(String)
    case reserved(KeyBinding)
    case conflict(KeyBinding, actions: [KeyBindingAction])
}

public struct KeyBindingSet: Equatable, Sendable {
    private var assignments: [KeyBindingAction: KeyBindingAssignment]
    public static let defaults: Self = Self(/* complete literal map */)
    public func assignment(for action: KeyBindingAction) -> KeyBindingAssignment?
    public func binding(for action: KeyBindingAction) -> KeyBinding?
    public func serializedValues() -> [String: String]
    public static func resolving(
        _ raw: [String: String]
    ) -> (bindings: Self, issues: [KeyBindingAction: KeyBindingValidationIssue])
    public func replacing(
        _ action: KeyBindingAction,
        with assignment: KeyBindingAssignment
    ) -> Result<Self, KeyBindingValidationIssue>
}
```

defaults 精确使用设计规格表。`resolving` 从 defaults proposal 开始，只处理已知 action raw keys；空字符串为 disabled；解析失败/保留先回退 default。对重复 proposal 找出所有 action：偏离默认者全部回退并记 conflict，循环到唯一。`replacing` 在当前完整 set 上原子验证，失败返回 issue 而不修改。

保留集合按设计规格精确覆盖 cmd+q/comma/h/alt+h/m、cmd+ctrl+f、cmd+c/v/x/a、cmd+1...9；default action 自身不应命中。

- [ ] **Step 5: 扩充冲突与系统保留测试**

```swift
@Test("禁用、保留和冲突逐项回退")
func resolutionIsAtomicPerAction() throws {
    let raw = [
        "new_tab": "",
        "find": "cmd+q",
        "copy_command": "cmd+ctrl+k",
        "copy_output": "cmd+ctrl+k",
        "focus_left": "broken",
    ]
    let resolved = KeyBindingSet.resolving(raw)
    #expect(resolved.bindings.assignment(for: .newTab) == .disabled)
    #expect(resolved.bindings.binding(for: .find) == KeyBindingSet.defaults.binding(for: .find))
    #expect(resolved.bindings.binding(for: .copyCommand) == KeyBindingSet.defaults.binding(for: .copyCommand))
    #expect(resolved.bindings.binding(for: .copyOutput) == KeyBindingSet.defaults.binding(for: .copyOutput))
    #expect(resolved.issues.keys.contains(.find))
    #expect(resolved.issues.keys.contains(.copyCommand))
    #expect(resolved.issues.keys.contains(.copyOutput))
    #expect(resolved.issues.keys.contains(.focusLeft))
}

@Test("两个 action 可以交换默认绑定")
func defaultsCanBeSwapped() {
    let resolved = KeyBindingSet.resolving([
        "new_tab": "cmd+f",
        "find": "cmd+t",
    ])
    #expect(resolved.issues.isEmpty)
    #expect(resolved.bindings.binding(for: .newTab)?.serialized == "cmd+f")
    #expect(resolved.bindings.binding(for: .find)?.serialized == "cmd+t")
}
```

- [ ] **Step 6: 跑 focused tests 并提交**

Run: `swift test --no-parallel --filter KeyBindingTests`

Expected: PASS；parser、defaults、reserved、conflict、swap 全绿。

```bash
git add Sources/InkConfig/KeyBindings.swift Tests/InkConfigTests/KeyBindingTests.swift
git commit -m "feat(config): 建立快捷键值模型" -m "用纯 Swift 完整映射、规范 parser 与原子冲突回退统一快捷键语义，避免配置错误阻止终端启动。\n\nRefs #79"
```

---

### Task 2: TOML 与 iCloud schema 1 往返

**Files:**
- Modify: `Sources/InkConfig/InkConfig.swift`
- Modify: `Sources/InkConfig/ConfigSyncSnapshot.swift`
- Modify: `Tests/InkConfigTests/InkConfigTests.swift`
- Modify: `Tests/InkConfigTests/ConfigSyncSnapshotTests.swift`
- Modify: `Tests/InkConfigTests/KeyBindingTests.swift`

**Interfaces:**
- Consumes: Task 1 的 `KeyBindingSet.resolving` / `serializedValues`。
- Produces: `InkConfig.keyBindings`、`keyBindingIssues`，TOML `[keybindings]`，wire `[String:String]?`。

- [ ] **Step 1: 写 TOML/wire RED 测试**

```swift
@Test("快捷键 TOML 缺省、覆盖、禁用与非法项往返")
func keyBindingTOMLRoundTrip() throws {
    let file = FileManager.default.temporaryDirectory
        .appendingPathComponent("ink-keybindings-\(UUID().uuidString).toml")
    try """
    [keybindings]
    new_tab = "ctrl+shift+t"
    split_left = "cmd+ctrl+left"
    split_right = ""
    find = "cmd+q"
    """.write(to: file, atomically: true, encoding: .utf8)
    let loaded = InkConfig.load(from: file)
    #expect(loaded.keyBindings.binding(for: .newTab)?.serialized == "ctrl+shift+t")
    #expect(loaded.keyBindings.assignment(for: .splitRight) == .disabled)
    #expect(loaded.keyBindings.binding(for: .find) == KeyBindingSet.defaults.binding(for: .find))
    #expect(loaded.keyBindingIssues[.find] != nil)
    try loaded.save(to: file)
    #expect(InkConfig.load(from: file).keyBindings == loaded.keyBindings)
}
```

ConfigSync 测试删除 JSON `keyBindings` 后断言 defaults；完整 config 把 newTab 改成 ctrl+shift+t 且 splitRight disabled，往返相等。

- [ ] **Step 2: 确认 RED**

Run: `swift test --no-parallel --filter InkConfigTests && swift test --no-parallel --filter ConfigSyncSnapshotTests`

Expected: FAIL，InkConfig 无 keyBindings。

- [ ] **Step 3: 接入 InkConfig TOML**

新增：

```swift
public var keyBindings: KeyBindingSet = .defaults
public private(set) var keyBindingIssues: [KeyBindingAction: KeyBindingValidationIssue] = [:]
```

load 遍历 `KeyBindingAction.allCases`，用 `values.string("keybindings.\(rawValue)")` 构造 raw map，再一次调用 resolving。save 把全部 `serializedValues()` 排成 `keybindings.<rawValue>` 的稳定 CaseIterable 顺序追加到 tomlValues。文档示例至少展示 new_tab、split_prefix、focus_left 和 disabled split_left。

为设置 UI 提供 mutating API：

```swift
public mutating func setKeyBinding(
    _ assignment: KeyBindingAssignment,
    for action: KeyBindingAction
) -> Result<Void, KeyBindingValidationIssue>
public mutating func resetKeyBindings()
```

成功替换 set 并移除 action issue；失败保持旧 set 并写 issue。

- [ ] **Step 4: 接入 WireConfig**

`WireConfig` 添加 `let keyBindings: [String:String]?`。init 写 `config.keyBindings.serializedValues()`；validatedConfig 用 `KeyBindingSet.resolving(keyBindings ?? [:])`，缺字段必须直接 defaults，不能把空字典误认为显式禁用。把 bindings 与 issues 赋给 result；若 private setter 阻止，新增 InkConfig internal initializer/helper，不扩大 public mutable issue API。

- [ ] **Step 5: focused tests 与提交**

Run: `swift test --no-parallel --filter InkConfigTests && swift test --no-parallel --filter ConfigSyncSnapshotTests && swift test --no-parallel --filter KeyBindingTests`

Expected: PASS。

```bash
git add Sources/InkConfig/InkConfig.swift Sources/InkConfig/ConfigSyncSnapshot.swift Tests/InkConfigTests/InkConfigTests.swift Tests/InkConfigTests/ConfigSyncSnapshotTests.swift Tests/InkConfigTests/KeyBindingTests.swift
git commit -m "feat(config): 持久化自定义快捷键" -m "让 TOML 与 schema 1 云端快照完整往返规范绑定，并让旧快照和非法单项安全回退默认。\n\nRefs #79"
```

---

### Task 3: AppKit adapter、菜单 descriptor 与初始菜单

**Files:**
- Create: `Sources/InkShell/KeyBindingAppKitAdapter.swift`
- Create: `Sources/InkShell/MenuCommandDescriptor.swift`
- Modify: `Sources/InkShell/AppDelegate.swift`
- Create: `Tests/InkShellTests/KeyBindingMenuTests.swift`
- Modify: `Tests/InkShellTests/TerminalCommandTests.swift`
- Modify: `Tests/InkShellTests/TerminalSearchCommandTests.swift`
- Modify: `Tests/InkShellTests/TerminalSplitCommandTests.swift`
- Modify: `Tests/InkShellTests/FontSizeMenuTests.swift`

**Interfaces:**
- Consumes: `KeyBindingSet` / `KeyBinding`。
- Produces: `KeyBindingAppKitAdapter`, `MenuCommandDescriptor`, `AppDelegate.makeMainMenu(settingsTarget:keyBindings:)`。

- [ ] **Step 1: 写 adapter 与菜单 RED 测试**

```swift
@Suite("自定义快捷键菜单")
@MainActor
struct KeyBindingMenuTests {
    @Test("adapter 映射特殊键和 glyph")
    func appKitMapping() throws {
        let binding = try #require(KeyBinding.parse("cmd+alt+left"))
        #expect(KeyBindingAppKitAdapter.keyEquivalent(for: binding) == "\u{F702}")
        #expect(KeyBindingAppKitAdapter.modifierFlags(for: binding) == [.command, .option])
        #expect(KeyBindingAppKitAdapter.displayString(for: binding) == "⌘⌥←")
    }

    @Test("自定义和禁用同步到菜单")
    func menuUsesBindings() throws {
        var config = InkConfig()
        #expect(config.setKeyBinding(.binding(try #require(.parse("ctrl+shift+t"))), for: .newTab).isSuccess)
        #expect(config.setKeyBinding(.disabled, for: .find).isSuccess)
        let menu = AppDelegate.makeMainMenu(keyBindings: config.keyBindings)
        let newTab = try #require(item(action: #selector(MainWindowController.newSession(_:)), in: menu))
        let find = try #require(item(action: #selector(MainWindowController.findInActivePane(_:)), in: menu))
        #expect(newTab.keyEquivalent == "t")
        #expect(newTab.keyEquivalentModifierMask == [.control, .shift])
        #expect(find.keyEquivalent.isEmpty)
    }
}
```

- [ ] **Step 2: 确认 RED**

Run: `swift test --no-parallel --filter KeyBindingMenuTests`

Expected: FAIL，adapter 不存在或 makeMainMenu 无参数。

- [ ] **Step 3: 实现 AppKit adapter**

adapter 用固定 switch 映射特殊 token 到 AppKit function-key Unicode，标点映射到实际 keyEquivalent 字符；字母数字直接返回。modifier 只映射四个 binding bits。`binding(from event:)` 使用 `charactersIgnoringModifiers`、function key Unicode 和过滤后的 deviceIndependentFlagsMask，忽略 capsLock/numericPad/function；无法识别返回 nil。displayString 按 `⌘⌃⌥⇧` + key glyph 输出。

- [ ] **Step 4: 建立 descriptor 单一表并重构菜单**

descriptor 至少包含 action/title/selector/menu group；直接分屏四项也进入表。`makeMainMenu(settingsTarget:keyBindings: = .defaults)` 为每个 descriptor 调用统一 helper：disabled 时 keyEquivalent `""`，否则 adapter 映射并赋 modifier。固定设置/退出/copy/paste/session1-9 保持原逻辑。

原 `TerminalCommandTests`、search、split、font tests 继续验证 defaults 与当前完全一致；direct split defaults 仍空。

- [ ] **Step 5: focused tests 与提交**

Run: `swift test --no-parallel --filter KeyBindingMenuTests && swift test --no-parallel --filter TerminalCommandTests && swift test --no-parallel --filter TerminalSearchCommandTests && swift test --no-parallel --filter TerminalSplitCommandTests && swift test --no-parallel --filter FontSizeMenuTests`

Expected: PASS。

```bash
git add Sources/InkShell/KeyBindingAppKitAdapter.swift Sources/InkShell/MenuCommandDescriptor.swift Sources/InkShell/AppDelegate.swift Tests/InkShellTests/KeyBindingMenuTests.swift Tests/InkShellTests/TerminalCommandTests.swift Tests/InkShellTests/TerminalSearchCommandTests.swift Tests/InkShellTests/TerminalSplitCommandTests.swift Tests/InkShellTests/FontSizeMenuTests.swift
git commit -m "feat(shell): 从配置构建原生菜单快捷键" -m "集中 action 与 selector 描述并统一 AppKit 映射，让菜单展示和实际响应不再依赖散落硬编码。\n\nRefs #79"
```

---

### Task 4: 配置热应用与可配置分屏前缀

**Files:**
- Modify: `Sources/InkShell/AppDelegate.swift`
- Modify: `Sources/InkShell/MainWindowController.swift`
- Modify: `Sources/InkShell/SplitShortcutState.swift`
- Modify: `Tests/InkShellTests/SplitShortcutStateTests.swift`
- Modify: `Tests/InkShellTests/SettingsWindowTests.swift`
- Modify: `Tests/InkShellTests/KeyBindingMenuTests.swift`

**Interfaces:**
- Consumes: Task 3 adapter/menu builder，Task 2 config。
- Produces: `MainWindowController.onKeyBindingsChange`、live split-prefix recognizer。

- [ ] **Step 1: 写自定义 split prefix 与热重建 RED 测试**

重构 `SplitShortcutKeyEvent` 为与 binding 匹配之后的高层事件：

```swift
enum SplitShortcutKeyEvent: Equatable {
    case prefixDown(keyCode: UInt16, isRepeat: Bool)
    case prefixUp(keyCode: UInt16)
    case direction(PaneSplitDirection)
    case modifiersChanged(matchesPrefix: Bool)
    case contextLost
    case unrelated
}
```

测试 prefix keyCode 可为任意值、错误 keyUp 不结束、tap right、四方向、repeat、modifier 失配和 contextLost。窗口测试注入 config，模拟热变化后旧 pending 被取消，callback 收到新 set。

- [ ] **Step 2: 确认 RED**

Run: `swift test --no-parallel --filter SplitShortcutStateTests && swift test --no-parallel --filter KeyBindingMenuTests`

Expected: FAIL，旧 event 仍硬编码 D。

- [ ] **Step 3: 重构 SplitShortcutState**

state pending 时保存 `prefixKeyCode`；只有相同 keyUp 才 tap splitRight。`direction` 在 pending 触发并进入 consumed；consumed 期间方向/repeat consume；modifier false/contextLost cancel。它不知道 KeyBinding 或 AppKit。

- [ ] **Step 4: 在窗口层识别当前 prefix**

`MainWindowController` 保存当前 `config.keyBindings.binding(for:.splitPrefix)`，handler 通过 adapter 判断 keyDown binding 是否精确相等；匹配后发 prefixDown。pending 时方向物理 keyCode 仍映射 direction。flagsChanged 根据当前 modifier 是否匹配；keyUp 用 state 保存的 physical code。binding disabled 时 idle 完全透传。applyConfig binding 变化时先 cancel。

- [ ] **Step 5: 启动和热重建菜单**

AppDelegate 启动先 `InkConfig.load`，用其 binding build menu，并通过 internal MainWindowController initializer 复用同一 initialConfig，避免读两次/闪现。设置 controller callback：

```swift
controller.onKeyBindingsChange = { [weak self] bindings in
    self?.buildMenu(keyBindings: bindings)
}
```

`applyConfig` 仅在 binding set 改变时触发 callback；初次菜单已正确，不重复重建。ConfigWatcher/设置保存/iCloud pull 都走现有 applyConfig 链路。

- [ ] **Step 6: focused tests 与提交**

Run: `swift test --no-parallel --filter SplitShortcutStateTests && swift test --no-parallel --filter KeyBindingMenuTests && swift test --no-parallel --filter SettingsWindowTests`

Expected: PASS。

```bash
git add Sources/InkShell/AppDelegate.swift Sources/InkShell/MainWindowController.swift Sources/InkShell/SplitShortcutState.swift Tests/InkShellTests/SplitShortcutStateTests.swift Tests/InkShellTests/SettingsWindowTests.swift Tests/InkShellTests/KeyBindingMenuTests.swift
git commit -m "feat(shell): 热应用快捷键与分屏前缀" -m "启动和配置变化共享同一绑定集合，并让现有分屏手势使用可配置前缀而不扩张为通用 chord。\n\nRefs #79"
```

---

### Task 5: 设置页录制、清除、错误和恢复默认

**Files:**
- Create: `Sources/InkShell/KeyBindingRecorderControl.swift`
- Modify: `Sources/InkShell/SettingsViewController.swift`
- Create: `Tests/InkShellTests/KeyBindingSettingsTests.swift`

**Interfaces:**
- Consumes: `InkConfig.setKeyBinding/resetKeyBindings`、AppKit adapter。
- Produces: 可访问的原生录制控件和快捷键 settings section。

- [ ] **Step 1: 写 recorder / settings RED 测试**

测试通过可直接调用的 internal `handle(candidate:)`，不要合成不稳定 CGEvent：

```swift
@Suite("快捷键设置")
@MainActor
struct KeyBindingSettingsTests {
    @Test("合法录制即时回传，冲突保留旧值并显示错误")
    func recordsAndRejectsConflict() throws {
        let controller = SettingsViewController(config: InkConfig())
        var received: [InkConfig] = []
        controller.onChange = { received.append($0) }
        controller.loadView()
        let newTab = try recorder(.newTab, in: controller.view)
        newTab.handle(candidate: try #require(.parse("cmd+ctrl+t")))
        #expect(received.last?.keyBindings.binding(for: .newTab)?.serialized == "cmd+ctrl+t")
        newTab.handle(candidate: KeyBindingSet.defaults.binding(for: .find))
        #expect(received.last?.keyBindings.binding(for: .newTab)?.serialized == "cmd+ctrl+t")
        #expect(newTab.validationMessage?.contains("查找") == true)
    }

    @Test("清除、外部刷新和全部恢复默认")
    func clearRefreshAndReset() throws {
        let controller = SettingsViewController(config: InkConfig())
        var received: InkConfig?
        controller.onChange = { received = $0 }
        controller.loadView()
        let newTab = try recorder(.newTab, in: controller.view)
        newTab.clearBinding()
        #expect(received?.keyBindings.assignment(for: .newTab) == .disabled)

        var external = InkConfig()
        _ = external.setKeyBinding(
            .binding(try #require(.parse("cmd+ctrl+t"))),
            for: .newTab
        )
        controller.update(config: external)
        #expect(newTab.assignment == external.keyBindings.assignment(for: .newTab))

        controller.resetAllKeyBindings(confirm: { true })
        #expect(received?.keyBindings == .defaults)
    }
}
```

- [ ] **Step 2: 确认 RED**

Run: `swift test --no-parallel --filter KeyBindingSettingsTests`

Expected: FAIL，recorder 不存在。

- [ ] **Step 3: 实现 KeyBindingRecorderControl**

采用 NSView 组合当前 glyph label、录制 NSButton、清除 NSButton 和错误 label；公开 internal action 标识与回调：

```swift
final class KeyBindingRecorderControl: NSView {
    let action: KeyBindingAction
    var onCandidate: ((KeyBindingAssignment) -> Result<Void, KeyBindingValidationIssue>)?
    private(set) var assignment: KeyBindingAssignment
    private(set) var validationMessage: String?
    func update(assignment: KeyBindingAssignment, issue: KeyBindingValidationIssue?)
    func handle(candidate: KeyBinding)
    func clearBinding()
}
```

录制时成为 first responder 并 override keyDown：Escape cancel；无 modifier Delete/Backspace
调用 `clearBinding()`；否则 adapter event conversion，无法转换时显示 syntax error。成功停止
录制并刷新 glyph；失败保留旧 assignment。错误 label 有 accessibility label/value，控件
button 有 action 名称。

- [ ] **Step 4: 设置页构造 section 与状态同步**

新增 action 本地化标题/分组映射。为 `KeyBindingAction.allCases` 建 recorder，存 `[Action:Control]`。onCandidate 拷贝当前 config，调用 set；成功赋回、updateControls/onChange；失败只更新控件 issue。section 顶部加“恢复全部默认值…”按钮，使用可注入确认 presenter 或复用 settings reset presenter，测试不弹真实 alert。

`updateControls` 同步每个 assignment/issue；外部 update 正确覆盖录制前状态。整个 section 使用现有 panel/row 系统控件，不自绘。

- [ ] **Step 5: focused tests 与提交**

Run: `swift test --no-parallel --filter KeyBindingSettingsTests && swift test --no-parallel --filter ConfigSyncSettingsTests && swift test --no-parallel --filter TerminalFontSettingsTests`

Expected: PASS；现有设置 section 仍布局有效。

```bash
git add Sources/InkShell/KeyBindingRecorderControl.swift Sources/InkShell/SettingsViewController.swift Tests/InkShellTests/KeyBindingSettingsTests.swift
git commit -m "feat(settings): 编辑和恢复快捷键" -m "用原生录制控件即时验证冲突、清除绑定并恢复默认，让错误可见且不破坏当前生效配置。\n\nRefs #79"
```

---

### Task 6: 开发完成审计（不运行批量完整门禁）

**Files:**
- Modify if needed: `docs/roadmap.md` only to mark/clarify shortcut customization behavior after code is complete.

- [ ] **Step 1: 静态边界检查**

Run: `! rg -n "import AppKit" Sources/InkConfig Sources/TerminalCore && git diff --check origin/main...HEAD`

Expected: exit 0。

- [ ] **Step 2: focused 功能集合**

Run: `swift test --no-parallel --filter 'KeyBinding|SplitShortcut|TerminalCommand|TerminalSearchCommand|TerminalSplitCommand|FontSizeMenu'`

Expected: 所有与本功能直接相关测试 PASS。不要在此阶段运行完整 suite/build；root 会在全部并发 worktree 开发完成后统一执行。

- [ ] **Step 3: roadmap 文案同步与提交**

把 P1-B “快捷键自定义”补充为已实现边界：单次原生组合键 + 现有专用 split prefix；明确不含宏/通用 chord。不要移动其它未完成条目。

```bash
git add docs/roadmap.md
git commit -m "docs(roadmap): 明确快捷键自定义边界" -m "记录原生单次组合键与专用分屏前缀范围，避免把宏和通用 chord 误纳入当前能力。\n\nRefs #79"
```

- [ ] **Step 4: 写实现报告并停止**

报告包含提交、focused RED/GREEN、未运行的完整测试/build/手工 UI 验证、已知跨分支冲突（尤其 #76 ConfigSyncSnapshot、#77/#78 AppDelegate/MainWindow/Settings）和自审结果。不要 push、PR、merge 或发布。
