# 快捷键自定义设计

**Issue:** #79
**状态:** 已实现，待合并
**日期:** 2026-07-22

## 目标

让用户通过 `config.toml` 和设置中心修改 Ink 自己的原生操作快捷键，同时保持当前
快捷键作为默认值。菜单显示、菜单实际响应、分屏前缀手势和配置热重载必须来自同一份
绑定模型，不能继续在 `AppDelegate`、窗口事件 monitor 和标签展示中分别硬编码。

快捷键配置只属于 Shell/Config 冷路径，不进入 TerminalCore、PTY、grid、scrollback
或 Metal 渲染路径。配置错误不得阻止 Ink 启动，也不得抢占普通终端输入。

## 用户可见范围

首版支持以下 Ink 操作：

| 分组 | Action ID | 默认值 |
|---|---|---|
| 文件 | `new_project` | `cmd+n` |
| 文件 | `new_tab` | `cmd+t` |
| 文件 | `close_pane` | `cmd+w` |
| 分屏 | `split_prefix` | `cmd+d` |
| 分屏 | `split_left` / `split_right` / `split_up` / `split_down` | 未直接绑定 |
| 聚焦 | `focus_left` / `focus_right` / `focus_up` / `focus_down` | `cmd+alt+方向键` |
| 搜索 | `find` | `cmd+f` |
| 字号 | `font_increase` / `font_decrease` / `font_reset` | `cmd+plus` / `cmd+minus` / `cmd+0` |
| 命令块 | `previous_command` / `next_command` | `cmd+shift+up` / `cmd+shift+down` |
| 命令块 | `copy_command` / `copy_output` | `cmd+shift+c` / `cmd+shift+o` |
| 标签 | `previous_tab` / `next_tab` | `cmd+shift+left_bracket` / `cmd+shift+right_bracket` |
| 界面 | `toggle_sidebar` | `cmd+ctrl+s` |

`split_prefix` 保留现有 Ink 特有语义：按下前缀后直接松开等价于向右分屏；按住前缀
再按方向键按指定方向分屏。它是一个现存的专用手势，不扩展为通用多键 chord 系统。
四个 `split_*` action 允许用户额外配置可由菜单直接表示的单次组合键，默认关闭。

以下系统/终端约定不纳入自定义：设置 `cmd+comma`、退出 `cmd+q`、拷贝/粘贴
`cmd+c` / `cmd+v`、会话 1～9 的 `cmd+数字`、macOS 隐藏/最小化/全屏。这样避免
用户把最基本的恢复和文本操作一起改坏。

## 配置格式

本地配置使用一个扁平 TOML section，每项可独立缺省：

```toml
[keybindings]
new_tab = "cmd+t"
split_prefix = "cmd+d"
split_left = ""
focus_left = "cmd+alt+left"
previous_command = "cmd+shift+up"
```

- 缺少键：使用该 action 的内置默认值；
- 空字符串：显式禁用该 action；
- 合法字符串：覆盖默认值；
- 无法解析、系统保留或与另一 Ink action 冲突：该 action 回退内置默认，并记录
  可供设置页展示的验证问题；其它 action 继续生效。

保存配置时写出全部已知 action 的规范字符串，禁用项写空字符串。这样现有
`MiniTOML.updating` 不需要新增删除键能力，未知 section、未知键和注释仍被保留。

### 组合键语法

规范修饰键名称为 `cmd`、`ctrl`、`alt`、`shift`，保存时按
`cmd+ctrl+alt+shift+key` 的固定顺序输出。读取时同时接受完整别名
`command`、`control`、`option`，但一律规范化后保存。

key 支持：

- 单个 ASCII 字母或数字；
- `plus`、`minus`、`comma`、`period`、`slash`、`semicolon`、`quote`、
  `backslash`、`left_bracket`、`right_bracket`、`backtick`；
- `left`、`right`、`up`、`down`、`home`、`end`、`page_up`、`page_down`；
- `return`、`tab`、`space`、`escape`、`delete`、`forward_delete`；
- `f1`～`f20`。

必须恰有一个 key；修饰键不能重复。为避免抢占普通终端输入，每个可启用绑定必须至少
包含 `cmd` 或 `ctrl`。字母规范化为小写；Shift 是显式 modifier，不通过大写字母暗示。

## 纯配置模型

`InkConfig` 新增无 AppKit 依赖的值类型：

```swift
public enum KeyBindingAction: String, CaseIterable, Hashable, Sendable
public struct KeyBindingModifiers: OptionSet, Hashable, Sendable
public struct KeyBinding: Hashable, Sendable
public enum KeyBindingAssignment: Equatable, Sendable {
    case disabled
    case binding(KeyBinding)
}
public struct KeyBindingSet: Equatable, Sendable
public enum KeyBindingValidationIssue: Equatable, Sendable
```

`KeyBinding` 保存规范 key token 和四个 modifier bit，不保存 AppKit keyCode、Unicode
私用区字符或本地化显示文本。`KeyBindingSet` 对每个 `KeyBindingAction` 都有明确
assignment，因而能区分“禁用”与“字典缺项”。`KeyBindingSet.defaults` 是唯一默认
映射来源。

`InkConfig` 持有：

```swift
public var keyBindings: KeyBindingSet = .defaults
public private(set) var keyBindingIssues: [KeyBindingAction: KeyBindingValidationIssue] = [:]
```

解析、规范化、保留组合检查和冲突消解全部在 `InkConfig` 模块完成，便于 TOML、iCloud
和设置页共享规则。Shell 只负责把已经验证的 `KeyBinding` 映射到 AppKit。

### 冲突消解

解析所有已知配置值后先生成完整 proposal map，再按以下规则收敛：

1. 非法或系统保留的 proposal 回退该 action 默认，并记录 issue；
2. 同一非空 binding 被多个 action 占用时，所有偏离默认的冲突 proposal 都回退各自
   默认，并为这些 action 记录 conflict；
3. 重复检查直到无冲突。默认集合自身必须由测试证明唯一；
4. 显式 disabled 不参与冲突。

该规则允许两个 action 交换彼此默认快捷键，因为最终 proposal 没有重复；也避免配置
文件排列顺序决定谁“抢赢”。设置 UI 在提交单项前使用同一 validator，发现冲突时不
修改生效配置，并立即显示冲突 action 名称。

## 系统保留组合

首版固定拒绝：

- `cmd+q`、`cmd+comma`、`cmd+h`、`cmd+alt+h`、`cmd+m`；
- `cmd+ctrl+f`；
- `cmd+c`、`cmd+v`、`cmd+x`、`cmd+a`；
- `cmd+1`～`cmd+9`。

默认 Ink binding 即使与一般 macOS 习惯相同也有效。保留列表不是全局键盘嗅探，
只用于防止本应用内菜单/monitor 覆盖无法恢复或基础文本操作。将来新增 action 时必须
同步默认唯一性和保留表测试。

## AppKit 映射与菜单

新增 `KeyBindingAppKitAdapter`，负责双向转换：

- 配置 key token → `NSMenuItem.keyEquivalent`；
- `KeyBindingModifiers` → `NSEvent.ModifierFlags`；
- recorder 收到的 `NSEvent` → 规范 `KeyBinding`；
- 规范绑定 → 用户可读 glyph 文本，例如 `⌘⌥←`。

`AppDelegate.makeMainMenu(settingsTarget:keyBindings:)` 接受完整 `KeyBindingSet`，所有
可自定义菜单项从一张 `MenuCommandDescriptor` 表创建。descriptor 保存 action、标题、
selector、菜单分组与 tag；动态会话 1～9、设置、退出、复制、粘贴仍按固定系统约定
构造，不进入 descriptor 表。

直接分屏 action 默认 disabled，因此菜单项默认没有 key equivalent；用户配置后由
菜单自然响应。`split_prefix` 不绑定某个菜单项，由窗口 monitor 消费。

App 启动时先读取一次 `InkConfig`，用其 binding 创建菜单和窗口，避免默认菜单短暂闪现
后再重建。`MainWindowController` 提供 `onKeyBindingsChange` 回调；设置保存或配置文件
热重载改变 `keyBindings` 时，AppDelegate 在主线程重建主菜单。重建仍保留 settings
target，selector 路由和 `NSMenuItemValidation` 继续由 AppKit 完成。

## 分屏前缀 monitor

现有 `SplitShortcutState` 保留 pending/consumed 状态机，但移除硬编码 keyCode 2 和
“只判断 Command”。窗口层用当前 `split_prefix` binding 判断 keyDown：

- modifier 必须精确匹配，忽略 capsLock / numericPad 等非绑定 flag；
- key 使用 `charactersIgnoringModifiers` 经 adapter 规范化；
- prefix keyDown 时记录该事件的物理 keyCode，仅用于识别对应 keyUp；
- pending 期间方向键沿用物理方向 keyCode 123～126；
- 配置热重载、窗口失焦、设置页打开或 modifier 松开都会 cancel pending；
- prefix disabled 时 monitor 完全透传。

这样自定义语义与菜单字符串一致，同时不会把键盘布局相关 keyCode 写进配置。

## 设置中心

设置页新增“快捷键”section，按文件、分屏、聚焦、搜索、字号、命令块、标签和界面排序。
每行包含 action 名称、当前 glyph 文本、系统 `NSButton`“录制”与“清除”。section 顶部
提供“恢复全部默认值…”。

录制控件采用原生 focus ring：

1. 点击“录制”后成为 first responder，显示“请按快捷键”；
2. 下一次 keyDown 转成候选 binding；Escape 只取消录制；Delete/Backspace 单独按下
   表示清除；
3. 非法、保留或冲突时保留旧 binding，在行下显示具体错误，VoiceOver 可读；
4. 合法时立即更新 `InkConfig` 并走现有 `onChange` 保存、热应用和 iCloud 上传链路；
5. “清除”写入 disabled；“恢复全部默认值…”沿用设置页现有危险重置确认风格。

外部 TOML / iCloud 更新通过 `SettingsViewController.update(config:)` 刷新全部行。设置页
展示 `keyBindingIssues`；用户录制合法值后清除对应 issue。

## iCloud wire 兼容

保持 `ConfigSyncSnapshot.currentSchemaVersion == 1`，`WireConfig` 新增可缺省字段：

```swift
let keyBindings: [String: String]?
```

新版编码写出全部已知 action 的规范字符串或空字符串；旧 schema 1 缺字段时使用
`.defaults`。未知 action key 被忽略；已知但非法的值按本地 TOML 相同规则回退并记录
issue。同步内容只有快捷键配置，不包含录制状态或 UI 错误文本。

## 测试策略

### InkConfig

- 默认 action 集合完整、默认非空 binding 唯一；
- 语法解析、别名、规范序列化、特殊键、F1～F20；
- 缺 modifier、多 key、重复 modifier、未知 token；
- disabled、缺省、单项覆盖、系统保留和冲突的原子回退；
- 交换两个默认 binding 合法；配置项顺序不影响结果；
- TOML 往返、未知字段/注释保留、非法项不阻止其它项；
- iCloud 新字段往返与旧 schema 1 缺字段迁移。

### InkShell

- 每个 action 的 descriptor selector、默认 key equivalent 和 modifier；
- disabled 清空 menu shortcut，自定义热重建后显示与响应一致；
- 固定的设置、退出、复制、粘贴、会话 1～9 不受配置影响；
- adapter 对字母、标点、方向键、功能键和 glyph 双向映射；
- split prefix tap、prefix+四方向、repeat、modifier 松开、窗口失焦、热重载 cancel；
- recorder 合法提交、Escape 取消、Delete 清除、冲突/保留错误与 accessibility；
- 设置外部刷新、单项清除、全部恢复默认；
- 多窗口当前只存在一个主窗口，但菜单重建不持有旧 controller 或泄漏 target。

## 性能与内存

绑定解析仅在启动、设置修改和配置同步时运行，action 数固定在几十以内。事件 monitor
每次 key event 只比较一个已解析的 split prefix，不解析 TOML、不遍历菜单、不分配
String 数组。菜单重建只发生在配置变化后。

该功能不修改 TerminalCore、cell、line、scrollback 或 renderer；不需要单独做终端热
路径 Instruments 采样。最终批量验收仍运行全套性能门禁以防跨分支整合回归。

## 非目标

- 通用多键 chord、宏、命令序列或脚本；
- 修改 shell、vim、tmux 等 TUI 内部 keymap；
- 按项目、pane、应用或键盘布局 profile；
- 全局系统快捷键注册、无窗口时响应或辅助功能键盘监听；
- 自定义复制/粘贴、设置、退出、会话 1～9；
- 从菜单标题反向推导 action，或让 `InkConfig` 依赖 AppKit。

## 主要风险与取舍

- 选择“完整已解析集合 + disabled assignment”，而不是只保存 overrides，换取运行时和
  iCloud 的确定性；保存会显式写出默认值，但仍保留未知 TOML 内容。
- 保留专用 split prefix 状态机，而不构建通用 chord 引擎，避免首版范围膨胀。
- 菜单在配置变化时整体重建，action 数很小，比分散修改并追踪旧 NSMenuItem 引用更
  容易保证一致；重建频率不在交互热路径。
- 使用语义 key token 配置而非物理 keyCode，符合 macOS 菜单和不同键盘布局预期；
  split prefix 只在一次按下周期内暂存物理 keyCode 识别 keyUp。
