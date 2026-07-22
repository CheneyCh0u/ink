# 命令块轻量悬停入口设计

关联 Issue：#80

## 背景

Ink 已解析 OSC 133，并能从终端的稀疏语义标记按需还原完整命令块。现有菜单和
快捷键支持跳转到上一条 / 下一条命令、拷贝命令及拷贝输出，但鼠标用户必须离开
当前内容才能找到这些动作。

roadmap 要求鼠标靠近命令首行时才出现轻量入口。这个入口不能成为常驻工具条，
不能永久占用终端列宽，也不能让普通终端输出承担额外的逐格或逐帧工作。

## 目标

- 鼠标进入一个完整 OSC 133 命令块的命令首行时，显示一个轻量 AppKit 按钮。
- 按钮与该物理行垂直对齐，贴近终端内容区右侧，以浮层方式出现，不改变 grid、
  PTY 尺寸或分屏布局。
- 点击按钮弹出系统 `NSMenu`，提供上一条命令、下一条命令、拷贝命令和拷贝命令
  输出。
- 所有动作以入口显示时捕获的命令身份为基准，并在执行时重新验证；终端坐标已
  失效时安全地不执行。
- 无完整命令记录、鼠标离开命令首行、终端内容更新、滚动、reflow、清除
  scrollback、历史环淘汰或切换会话后，入口立即消失。
- 保持文本选择、链接点击与悬停、TUI 鼠标上报、输入法和现有命令快捷键语义。

## 不包含

- 常驻命令工具条、命令面板、脚本、宏或快捷键自定义。
- 新的命令动作、命令编辑、重新执行命令或持久化命令历史。
- 给 `Cell`、`RowInfo`、scrollback 行或 renderer instance 增加字段。
- 在 `TerminalCore` 中引入 AppKit、Metal 或任何 UI 类型。
- 改变 OSC 133 的解析、命令块完成条件或现有命令状态通知。

## 不变量

- `Cell` 继续保持 8 字节，`RowInfo` 继续保持 2 字节。
- 入口状态只存在于当前可见的 `TerminalMetalView`，后台标签不保留按钮或菜单。
- renderer、grid 更新、PTY 消费与每帧 cell instance 生成路径不查询命令块。
- 鼠标命中只在用户跨到新的可见物理行时按需调用现有 `commandBlocks()`；同一行
  水平移动不重复构造命令块数组。
- PTY 更新调用 `markDirty()` 时只隐藏当前命令入口，不重新扫描命令记录。用户下次
  移动鼠标时再按需解析，因此高速输出不会把命令扫描带入帧循环。
- 命令入口使用 AppKit `NSButton` 与 `NSMenu`，不自绘图标、不增加 Metal draw call。

## 方案比较

### 采用：TerminalView 内的瞬态 AppKit 浮层

`TerminalMetalView` 已拥有 tracking area、可见坐标换算、链接命中和命令动作，因而
由它创建一个隐藏的 image-only `NSButton`。鼠标命中完整命令块的命令首行后显示
按钮；按钮点击时构造原生菜单。

优点：不跨 Shell 增加 pane 协调协议；可直接复用当前终端 provider、pasteboard
writer 和命令导航视口；所有瞬态状态随可见视图释放。缺点是 `TerminalMetalView`
继续承担一小段冷路径 AppKit 交互，但这与现有链接菜单和输入法职责一致。

### 否决：在 Shell 工作区叠加入口

由 `TerminalWorkspaceViewController` 在 pane container 上放按钮，可以让 Shell 负责
AppKit 控件，但 Shell 不掌握终端 cell、scrollback offset 与命令坐标换算。它必须
从 TerminalView 导出鼠标位置与布局度量，形成两套坐标真相，滚动和 reflow 时更
容易留下陈旧入口。

### 否决：在 Metal renderer 中绘制入口

renderer 可以精确贴合网格，但自绘按钮还需要重新实现命中、焦点、辅助功能和
菜单行为，并把命令入口判断带入逐帧渲染路径。这违反系统控件优先和热路径纪律。

## 命令身份

菜单不能只保存当前绝对行号。scrollback 环淘汰会让存活内容的绝对行坐标向前
平移，而 reflow 会重排所有物理行。

入口捕获如下纯值身份：

```swift
struct CommandHoverTarget: Sendable, Equatable {
    let commandStartLineID: UInt64
    let layoutRevision: UInt64
}
```

其中：

- `commandStartLineID` 等于当前最旧稳定行号加命令首行的绝对行索引。
- `layoutRevision` 取 `Terminal.searchLayoutRevision`；reflow、备用屏切换、RIS 与清除
  scrollback 等整体坐标变化都会让旧身份失效。

解析目标时先校验 revision，再用当前最旧稳定行号把稳定 ID 映回绝对行，最后在
当前 `commandBlocks()` 中寻找首行完全相等的命令块。历史环只淘汰目标之前的行时，
稳定 ID 仍能解析；目标本身被淘汰或 revision 改变时返回 nil。

菜单项的 `representedObject` 保存一个不可变 payload，四个动作不依赖菜单弹出后
可能变化的 hover 状态。动作执行时重新取当前 Terminal 并解析 payload；失败就隐藏
入口并安全返回。

## 命中规则

“靠近命令首行”定义为：鼠标位于该命令 `commandRange.start.line` 对应的可见物理
行内，且位置落在终端实际 cell 区域，而不是外侧 padding。

- 命令可以软折多行，但只有 `commandRange.start.line` 显示入口。
- 只有 B、C 边界完整、已被 `commandBlocks()` 返回的命令可命中。正在输入但尚未
  执行的命令不显示入口。
- 鼠标在同一物理行水平移动时沿用已解析结果，不重复扫描。
- 鼠标命中链接时，链接悬停优先，命令入口隐藏，确保 Command 点击和链接手型不受
  影响。
- alternate screen 中 `commandBlocks()` 为空，因此 vim、less 等不会显示入口。

## 按钮布局与生命周期

按钮使用系统 SF Symbol `ellipsis.circle`，image-only、无文字常驻。按钮具有“命令
操作”的 tooltip 和 accessibility label。

- 按钮宽高采用固定的紧凑 point 尺寸，并限制在当前可见行和 view bounds 内。
- x 坐标贴近内容区右侧 inset；y 坐标按 renderer 的 cell height 与命中 visual row
  计算。
- 按钮是 overlay subview，不参与 Auto Layout，不改变 `minimumViewportSize`、grid
  列数或 PTY resize。
- 视图 resize、滚轮滚动、开始选择、按键输入、鼠标离开、会话瞬态重置和任何
  Terminal 更新都会隐藏按钮。
- 隐藏时清空 hover target 与 visual row；按钮对象本身每个可见 TerminalView 仅
  创建一次，不随鼠标移动反复分配。

## 菜单与动作

点击按钮弹出原生 `NSMenu`：

1. 上一条命令
2. 下一条命令
3. 分隔线
4. 拷贝命令
5. 拷贝命令输出

菜单创建时基于同一份 Terminal snapshot 判断可用性：

- 当前目标之前没有完整命令时禁用“上一条命令”。
- 当前目标之后没有完整命令时禁用“下一条命令”。
- 目标无法重新解析时不弹菜单。
- “拷贝命令”只要目标有效即启用。
- `outputRange` 为 nil 时禁用“拷贝命令输出”。

跳转动作以目标首行为参照，选择严格早于或晚于目标的相邻完整命令，并复用现有
`revealCommand` 逻辑把目标滚到视口中部。拷贝动作只提取 payload 对应命令的范围，
不使用当前 viewport 最近命令，也不改变普通文本 selection。

## 鼠标、链接与选择优先级

### 普通终端模式

- 普通 mouse move 可显示入口。
- 链接命中优先于命令入口。
- 在终端内容上按下左键时先隐藏入口，再执行现有链接打开、鼠标选择、双击选词或
  三击选行逻辑。
- 只有直接点击可见按钮时由按钮消费事件并弹菜单；终端其他区域的事件路径不变。

### TUI 鼠标上报模式

- 未按 Option 时不显示命令入口，普通鼠标按下、拖拽、松开与右键继续上报 TUI。
- 按住 Option 并移动到命令首行时允许显示入口；这是与现有 Option 本地选择、
  Option 右键原生菜单一致的显式原生手势。
- 点击这个显式出现的按钮不向 TUI 发送鼠标字节。

### 输入法

按钮和菜单不成为终端的文本输入 client，不修改 marked text。菜单关闭后窗口仍可
把第一响应者交回 TerminalMetalView；现有 `NSTextInputClient` 路径不变。

## 更新与失效

以下事件统一隐藏入口，而不是尝试原地修补坐标：

- `markDirty()` 收到新的终端输出或语义状态变化。
- `scrollWheel` 改变 scrollback viewport 或向 TUI 发送滚轮。
- `resize` / reflow 使 layout revision 改变。
- clear scrollback、RIS、备用屏切换或环淘汰使目标不可解析。
- 搜索 reveal、命令导航或键盘输入改变 viewport。
- `resetTransientState()`、view 离开 window 或鼠标离开 bounds。

即使菜单已弹出，payload 也只在动作执行时重新验证；旧 target 不会错误地指向
相同绝对坐标上的另一条命令。

## 性能与内存

- 不修改 `Cell`、`RowInfo`、`ScrollbackLine`、renderer instance 或 shader。
- 不建立第二份命令索引，不缓存命令文本，不给每行保存 hover 标记。
- 每个可见 TerminalView 只增加一个隐藏 `NSButton`、一个可选 target 和一个 visual
  row 整数。后台标签没有 TerminalView，因此没有这部分开销。
- `commandBlocks()` 只在鼠标跨物理行或点击菜单的冷路径运行。高频 PTY 输出只隐藏
  已有入口，不触发扫描。
- 菜单和 payload 仅在点击入口时分配，关闭菜单后由 AppKit 释放。

## 验证策略

### 纯逻辑测试

- 完整命令首行能生成稳定 target，普通行、命令续行和无 OSC 133 记录不能命中。
- 只淘汰目标之前的历史行后 target 仍解析到同一命令。
- 目标被淘汰、reflow 或 clear scrollback 后 target 解析失败。
- 相邻命令查询严格以捕获目标为基准。

### TerminalView 测试

- 鼠标进入/离开命令首行时按钮显示/隐藏；同一行移动不改变 target。
- 链接与命令首行重叠时只保留链接反馈。
- 无鼠标上报时显示；TUI mouse 下普通移动不显示，Option 移动显示。
- 滚动、终端 `markDirty()`、选择开始和 transient reset 隐藏入口。
- 菜单结构和 enable 状态正确。
- 菜单弹出后终端 reflow/淘汰，旧 payload 动作不复制错误命令。
- 拷贝命令 / 输出使用命中的块，而不是 viewport 最近块。
- 上一条 / 下一条相对于命中块跳转。

### Focused 验证

开发阶段只运行：

```bash
swift test --filter CommandBlockTests
swift test --filter TerminalCommandActionTests
swift test --filter TerminalCommandHoverTests
swift test --filter TerminalLinkInteractionTests
```

全量 `swift test`、`swift build`、Instruments 与总评审由并发功能汇总阶段统一执行。

## 风险与回滚

- 最大性能风险是把 `commandBlocks()` 放进 `markDirty()` 或 `frameTick()`；实现必须
  保持“更新只隐藏，鼠标跨行才扫描”。
- 最大正确性风险是菜单保存绝对行号；稳定 line ID + layout revision + 执行时重验
  是强制边界。
- 最大交互风险是按钮覆盖链接或 TUI 鼠标区域；链接优先和 TUI Option gate 必须由
  focused tests 固定。
- 功能没有持久化数据与 schema 变更。回滚只需删除 TerminalView 的入口控件、纯值
  target/helper 和对应测试，不影响 OSC 133 数据格式。
