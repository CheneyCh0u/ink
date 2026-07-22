# 终端原生右键菜单设计

## 背景

Ink 已经分别具备选区复制、安全粘贴、URL/OSC 8 链接、增量搜索、四方向
分屏和 VT `ED 3` 清历史能力，但这些能力尚未汇总成终端内容区的完整原生
右键入口。当前 `TerminalMetalView` 只在右键命中链接且 TUI 未接管鼠标时弹出
包含“打开链接”“复制链接”的 `NSMenu`；普通文本或空白位置没有菜单。

Issue #78 要完成 roadmap P1-A 的“原生操作入口”：任何普通终端位置都能得到
系统菜单，链接位置增加链接动作；启用鼠标上报的 TUI 仍收到正常右键，用户可用
Option+右键显式进入 Ink 菜单；菜单中的 Shell 动作严格作用于点击所在 pane。

这项工作同时补齐一个冷路径 API：用户选择清除 scrollback 时直接删除当前 pane
的历史、保留当前屏幕，并同步清理所有依赖绝对历史坐标的视图、搜索与语义旁路
状态。动作不能伪装成远端程序输出，因而绝不向 PTY 写入 `ESC[3J`。

## 目标

- 普通文本、空白、选区和链接位置都提供 AppKit `NSMenu`。
- 通用菜单包含复制、粘贴、查找、四方向分屏和清除 scrollback。
- 链接命中时在通用项之前增加打开链接、复制链接，动作使用弹出菜单瞬间捕获的
  不可变目标。
- TUI mouse 开启时，普通右键继续上报 button 2 的 press/release；
  Option+右键只打开 Ink 菜单，不发送任何 TUI mouse bytes。
- 弹出菜单前先把点击的 `TerminalMetalView` 设为第一响应者并激活对应 pane。
- 清除 scrollback 立即执行、不确认、保留 grid；OSC 8、OSC 133、命令完成记录、
  搜索结果和所有基于旧历史坐标的视图瞬态必须同步失效或重编号。
- 复用现有 `SafePaste` 和 Core `ED 3` 主体，不复制两套安全或生命周期逻辑。
- 不增加 per-cell/per-line 常驻状态，不添加第三方依赖，不触碰 Metal 渲染热路径。

## 非目标

- 不自绘菜单，不改变系统菜单跟踪、键盘导航和辅助功能行为。
- 不增加剪贴板历史，也不记录粘贴内容。
- “清除 scrollback”不清空当前屏幕，不重置 shell，不关闭搜索栏。
- 不向 PTY 写 `ESC[3J`，不要求前台 TUI 配合。
- 不新增全局主菜单命令或快捷键；本 Issue 只补终端上下文菜单入口。
- 不改变已有 Command 点击链接、左键选区、滚轮和 Option 本地选区语义。

## 已确认交互语义

### 菜单结构

菜单按功能分组，只有链接组是条件项：

1. 命中可识别链接时显示“打开链接”“复制链接”；随后是分隔线。
2. “拷贝”“粘贴”。
3. 分隔线后显示“查找…”。
4. 分隔线后显示“向左分屏”“向右分屏”“向上分屏”“向下分屏”。
5. 分隔线后显示“清除滚动缓冲区”。

普通位置从第 2 组开始，因此不会因为没有选区或剪贴板内容而完全没有菜单。
不可执行的项保留但禁用，保持菜单结构稳定：

- 没有选区时禁用“拷贝”。
- 系统剪贴板没有非空文本时禁用“粘贴”。
- 链接目标无法构造带 scheme 的绝对 `URL`，或 Shell 未注入打开动作时，禁用
  “打开链接”；“复制链接”仍可用。
- Shell 未注入对应动作时，查找、分屏或清历史项禁用。
- 当前 pane 尺寸不足以按既有最小网格约束分屏时禁用对应方向：左右要求至少
  20 列，上下要求至少 6 行，与 `MainWindowController` 的菜单校验一致。

所有项目使用 `NSMenuItem` 和分隔项；不声明新的 key equivalent。右键菜单中的
“粘贴”调用现有 `paste(_:)`，从而完整复用危险内容检测、模式二次读取、
bracketed paste 包裹和结束标记过滤。

### 链接捕获

菜单创建时把命中链接的字符串写入该菜单项的 `representedObject`。后续终端可能
继续输出、reflow、淘汰 scrollback 或清历史；“打开链接”“复制链接”仍使用捕获
值，绝不在动作触发时按旧鼠标坐标重新命中。

### TUI mouse 与 Option override

`LinkMouseRouter` 的路由语义提升为完整上下文菜单语义，但保持已有判断：

- `mouseMode == .none`：普通右键打开 Ink 菜单。
- `mouseMode != .none` 且未按 Option：right-down 上报 button 2 press，
  right-up 上报 button 2 release，不显示菜单。
- `mouseMode != .none` 且按住 Option：right-down 打开 Ink 菜单，不发送 press；
  对应 right-up 也不发送 release。

判断在 right-down 时确定并记录，避免按下和松开之间修饰键变化制造孤立 release。
打开原生菜单的分支在构造菜单前调用 `window.makeFirstResponder(self)`。如果 pane
尚未活动，`becomeFirstResponder()` 通过现有 `onFocus` 同步激活它，随后 Shell
回调的“当前 pane”即点击 pane。

## 架构选择

### 采用方案：视图拥有手势和菜单，Shell 注入跨层动作

`TerminalMetalView` 已经拥有 AppKit 事件、选区、链接命中、复制粘贴和
`NSMenuItemValidation`，因此继续负责：

- 判断右键交给 TUI 还是原生菜单；
- 聚焦点击视图；
- 生成通用 `NSMenu`、链接组和分隔结构；
- 执行复制、粘贴、打开/复制捕获链接；
- 校验视图本地状态和分屏最低尺寸。

视图新增冷路径动作注入点，由 Shell 在构造每个 pane 视图时设置：

- `onFind: (() -> Void)?`
- `onSplit: ((TerminalContextSplitDirection) -> Void)?`
- `onClearScrollback: (() -> Void)?`

`TerminalContextSplitDirection` 定义在 `InkTerminalView`，只表达菜单的四个方向；
Shell 在注入闭包中映射成自己的 `PaneSplitDirection`。这样 `InkTerminalView` 不依赖
`InkShell`，Shell 仍然依赖视图层，依赖方向不反转。

菜单项 target 保持为 `TerminalMetalView`，selector 只转调这些闭包。闭包在
`TerminalWorkspaceViewController.makeView` 中捕获 `paneID`，先确认/激活 pane，
再调用工作区查找或上层分屏/清历史回调。清理视图时置空全部闭包，避免后台标签
或已拆除视图保留控制器生命周期。

### 未采用方案一：Shell 构造整张菜单

该方案便于直接复用 `MainWindowController` selectors，却迫使 Shell 接收原始
`NSEvent`、完成链接命中和 TUI mouse 路由，或者让视图反向请求一张包含本地链接
状态的菜单。手势与链接职责会跨层拆散，测试也必须跨 `InkShell` 才能验证普通
位置菜单，不符合现有视图边界。

### 未采用方案二：视图直接调用 Workspace/MainWindowController

让 `TerminalMetalView` 持有 Workspace 或 MainWindowController 引用可以减少闭包，
但会让 `InkTerminalView` 依赖 `InkShell`，破坏 SwiftPM target 的单向层级，并让
独立视图测试必须构造完整窗口外壳，因此排除。

## Core 清历史设计

### 公共冷路径 API

`Terminal` 新增：

```swift
public mutating func clearScrollback()
```

现有 `eraseDisplay(mode: 3)` 不再内联维护清理步骤，而是调用同一个私有主体；公共
API 也调用该主体。两条入口共享以下顺序：

1. 捕获当前 grid 中的 OSC 8 物理片段。
2. 释放当前链接范围和目标引用。
3. 以清理前 `scrollback.totalAppendedLines` 作为 screen 的旧稳定行基址。
4. 丢弃基址之前的 OSC 133 overflow 转换；保留 screen 范围内转换并把 line ID
   减去旧基址。
5. 丢弃历史命令完成记录；保留 screen 范围记录并把 line ID 减去旧基址。
6. `scrollback.removeAll()`，使 count 和 `totalAppendedLines` 同时归零。
7. 把捕获的 OSC 8 片段重新插入当前 grid，使链接 head/row anchors 以新基址 0
   重建，并保持目标引用计数一致。
8. 增加 `searchLayoutRevision`，使旧搜索布局和命令导航锚点失效。
9. 清除 `pendingWrap`，与收到 `CSI 3 J` 的既有终端状态转换一致。

`ED 3` 仍只通过 parser/Terminal 执行；用户菜单直接调用公共 API。两者都不产生
PTY 输出，也不清 `grid`。实现不在 Cell、RowInfo 或 ScrollbackLine 增加字段。

### 会话入口

`TerminalSession` 新增 `clearScrollback()`：只调用
`terminal.clearScrollback()`，然后触发一次 `onUpdate`。它不调用 `write(_:)`，
所以不会向子进程发送任何转义序列。`onUpdate` 使渲染和窗口 chrome 走既有刷新
路径；工作区仍显式处理搜索重启和视图瞬态，因为它们是清理事务的一部分，不能
等待普通 PTY 更新碰巧发生。

## Shell 与搜索事务

### Workspace 路由

`TerminalWorkspaceViewController` 为每个视图注入三个动作：

- 查找：按捕获 `paneID` 激活 pane，再调用 `openSearchInActivePane()`。
- 分屏：按捕获 `paneID` 激活 pane，再把方向通过 `onSplitPane` 上抛给
  `MainWindowController`。
- 清历史：调用 `clearScrollback(in: paneID)`。

`MainWindowController` 把 Workspace 的分屏回调接到现有
`splitActivePane(direction:)`，不复制分屏尺寸、工作目录继承或失败清理逻辑。
菜单弹出前的第一响应者切换通常已完成激活；动作入口再次按 `paneID` 路由是防御
措施，避免测试调用或未来菜单延迟执行时误伤另一个 pane。

### 原子清历史顺序

Workspace 的 `clearScrollback(in:)` 按以下顺序在 MainActor 上执行：

1. 验证 `paneID` 仍属于当前可见 tab，并激活该 pane。
2. 调用 `pane.session.clearScrollback()` 修改唯一终端状态。
3. 调用对应 `TerminalMetalView.scrollbackDidClear()`，重置：
   `scrollOffset`、滚轮累计值、选区、选区锚点、命令导航锚点、悬停链接、悬停
   cell、本地搜索结果及当前结果索引，并标记 dirty/hover refresh。
4. 若搜索栏当前属于该 pane，调用搜索控制器的历史重置入口。

视图不清输入法预编辑，因为它与历史坐标无关；也不改变配置和当前 grid。

### 取消陈旧搜索并按查询重启

`TerminalSearchController` 新增 `terminalHistoryDidClear()`。它保留搜索框及当前
query，但建立新的 generation 边界：

1. `updateGeneration &+= 1`；
2. 取消 `updateTask` 并置 nil；
3. 清除已调度/执行中刷新标记；
4. 清空 index 和 currentIndex，立即发布空结果；
5. query 非空时，从清理后的 `snapshotForSearch()` 和全新的
   `TerminalSearchIndex()` 启动无 debounce 的后台扫描；query 为空则结束。

旧 detached scan 即使取消协作不及时并最终返回，也必须同时通过 Task cancellation
和 generation 相等检查；generation 已改变，因此不能覆盖新 index。新扫描使用
清理后的 snapshot，按当前查询恢复 screen 中仍存在的匹配，搜索栏保持打开。

## 数据流

### 普通右键

```text
NSEvent rightMouseDown
  -> TerminalMetalView 读取 mouse mode / Option
  -> window.makeFirstResponder(view)
  -> onFocus 激活 pane
  -> 命中可选链接并捕获 target
  -> 构造 NSMenu + 校验各项
  -> NSMenu.popUpContextMenu
  -> 本地 selector 或 Shell 注入闭包
```

### TUI 右键

```text
rightMouseDown (mouse mode, no Option)
  -> KeyEncoder button 2 press -> onInput -> PTY
rightMouseUp
  -> KeyEncoder button 2 release -> onInput -> PTY
```

### 清除 scrollback

```text
菜单项 -> TerminalMetalView.clearScrollbackAction
  -> Workspace(paneID)
  -> TerminalSession.clearScrollback
  -> Terminal.clearScrollback (复用 ED 3 主体)
  -> view.scrollbackDidClear
  -> searchController.terminalHistoryDidClear
  -> 新 generation 扫描清理后的 snapshot
```

## 错误与竞态处理

- 菜单跟踪期间 pane 被移除：注入闭包弱捕获控制器，并按 `paneID` 重新查表；找不到
  即安全返回。
- 无可打开 URL：打开项禁用，selector 内仍再次解析和 guard，复制不受影响。
- 剪贴板类型在菜单弹出后改变：菜单初始校验用于 UI；执行 `paste(_:)` 时重新读取，
  没有文本即返回。
- bracketed paste 模式在确认框期间改变：沿用 `paste(text:)` 当前循环，模式变化时
  重做风险评估，不绕过 SafePaste。
- 清理与搜索完成竞争：MainActor 先推进 generation 并取消；旧任务回写前检查
  cancellation 和 generation，不能污染新状态。
- 清理与 PTY 输出均在 `TerminalSession` 的 MainActor 串行执行，不会并发写同一个
  `Terminal` 值。清理后到达的新输出以新 scrollback 基址继续记录。
- 菜单动作不向 PTY 写数据；只有粘贴与 TUI mouse 继续走既有 `onInput`。

## 测试策略

开发只运行精确 suite/test 过滤，不运行完整 `swift test` 或 `swift build`。
每组生产代码前先提交最小失败测试，观察符合预期的 RED，再写最小实现并观察
GREEN。

### TerminalCore focused tests

- 公共 `clearScrollback()` 删除历史但逐 cell 保留 grid、光标和模式，不产生 response。
- 公共 API 与 parser 收到 `CSI 3 J` 得到等价的历史/屏幕结果。
- 清理后 OSC 8 的 screen 链接仍能命中，历史链接不可命中，目标/范围旁路计数不
  泄漏，稳定行号从 0 重建。
- 清理后 OSC 133 screen 转换与 command completion 记录重编号，历史命令块消失，
  screen 中仍完整的命令块保持可用。
- `searchLayoutRevision` 增加，使旧 snapshot/index 能识别整体布局变化。

### InkTerminalView focused tests

- 普通空白位置弹出完整通用菜单。
- 链接位置在通用菜单前追加链接组，捕获目标在终端变化后不变。
- 无选区禁用复制；建立选区后复制可用。
- 无非空文本禁用粘贴；有文本时菜单粘贴调用 SafePaste，危险内容仍经过 presenter。
- TUI mouse 普通右键只产生 button 2 press/release，不弹菜单；Option+右键弹菜单且
  输入 bytes 保持为空。
- 原生菜单分支在 presenter 被调用前已触发 focus。
- `scrollbackDidClear()` 重置滚动、选区、命令锚点和 hover。

### InkShell focused tests

- 在非活动 pane 右键并触发查找/分屏/清历史，动作只作用该 pane。
- 四方向菜单动作复用既有分屏路径和最低尺寸语义。
- 清历史不调用 `TerminalSession.write`，屏幕不变，其他 pane 历史不变。
- 搜索进行中清历史会取消旧 generation；旧 snapshot 完成后不能回写；当前 query
  自动重扫并只发布清理后仍存在的 screen 匹配。

## 性能与内存

- 菜单仅在右键时构造，是用户触发的冷路径；常规帧循环没有新分支或分配。
- 清历史是显式冷路径，释放 scrollback 页和稀疏旁路数据；重建成本只与当前 screen
  行/链接片段及保留语义记录相关，不扫描或复制完整历史文本。
- 不修改 `Cell`、`RowInfo`、`ScrollbackLine` 布局；10 万行常驻成本不增加。
- 不新增依赖；全部使用已有 AppKit、Swift concurrency 和 TerminalCore 数据结构。
- 因为没有渲染循环或 grid 写入热路径改动，本 Issue 不要求新增 Time Profiler 数据；
  最终整体验证仍由合并负责人按项目规则执行。

## 验收清单

- [ ] 普通位置始终弹原生菜单，链接位置增加链接动作。
- [ ] 无选区复制禁用，无非空文本粘贴禁用。
- [ ] 粘贴完整复用 SafePaste。
- [ ] TUI 普通右键保留 button 2，Option+右键零 TUI bytes。
- [ ] 弹菜单前聚焦点击 pane，所有 Shell 动作作用于该 pane。
- [ ] 清除当前 pane 历史而保留 screen，不确认、不写 PTY。
- [ ] ED 3 与公共 API 共用清理主体。
- [ ] OSC 8、OSC 133、command completion 清理/重编号正确。
- [ ] 旧搜索 generation 永不回写，当前 query 自动重启。
- [ ] 视图滚动、选区、命令锚点和 hover 全部重置。
- [ ] 无 cell/line 状态、第三方依赖或 Metal 热路径改动。

