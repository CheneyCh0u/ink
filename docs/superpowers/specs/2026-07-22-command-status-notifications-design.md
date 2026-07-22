# 命令状态与安静通知设计

## 背景与目标

Ink 已解析 OSC 133 的 A/B/C/D 语义边界，并能按需扫描命令块完成跳转、复制命令和
复制输出。当前 `D;<status>` 的退出状态会被丢弃，C0 BEL 也由 Core 忽略；因此既无法
在历史命令块上查询执行结果，也无法在后台标签完成任务时提供反馈。

本项完成 roadmap 中“记录命令执行时长与退出状态”“后台命令完成、失败或 Bell 时，
在标签上显示安静的状态点”以及应用不活跃时的明确长任务通知。实现必须保持
`Cell` 8 字节和 `RowInfo` 2 字节，不建立每 cell / 每 line 对象，不保存命令文本到
通知，也不持久化任何运行态状态。

权威协议采用 iTerm2 对 FinalTerm OSC 133 的说明：只有 `C` 之后收到的
`D;<0...255>` 表示命令完成；`B` 后直接收到 `D` 表示命令取消，不能生成完成记录。
状态 0 为成功，非零为失败。缺少、越界或非十进制状态保留“结果未知”，但完整 C→D
仍可记录耗时。

## 范围

### 本次实现

- 从 OSC 133 C 到 D 使用单调时钟测量耗时，毫秒值饱和到 `UInt32.max`。
- 将退出状态与耗时附到对应 `CommandBlock`，并随 reflow、scrollback 环淘汰、
  `ED 2/3` 和 RIS 正确映射或回收。
- 把命令完成与 BEL 作为瞬时稀疏事件从 `TerminalCore` 送到 `InkShell`。
- 标签聚合多 pane 事件，并在标签栏、溢出菜单和非活动项目侧边栏显示未读状态。
- Ink 不活跃且完整命令耗时至少 10 秒时，投递不含命令文本的本地系统通知。
- 首次符合通知条件时按需申请 `.alert` 权限；拒绝、不可用或失败都静默降级为标签状态。

### 明确不做

- 不支持 OSC 9 / 777 主动通知协议；roadmap 已将它们列为后续增强。
- 不保存命令文本、输出、通知历史或未读状态到 UserDefaults / TOML / 工作区快照。
- 不恢复上次启动的状态，不为短命令、普通输出或前台可见完成发送系统通知。
- 不增加通知设置、阈值设置、声音、Dock 弹跳、通知动作或点击后精确跳转。
- 不改变 shell 集成脚本；没有 OSC 133 C/D 时不猜测命令边界或退出状态。

## 方案比较

### 方案 A：只保留每个会话最新结果

内存最小，但历史 `CommandBlock` 无法查询自己的耗时和退出状态，后续轻量命令入口也
无法显示可信结果，不满足 roadmap 的“记录”语义。

### 方案 B：稀疏完成记录 + 瞬时事件（采用）

每个完成命令保存一条 16 字节值类型记录，复用现有 OSC 133 转换点的坐标映射与回收
路径；事件队列只在 C/D 或 BEL 出现时分配并在每个 PTY 输出 chunk 后清空。它完整保留
历史结果，同时不增加普通行、cell 或渲染实例开销。

### 方案 C：轮询前台进程

无法得到 shell 退出状态和 BEL，也无法区分快速连续命令、取消与完整 C→D，且会引入
周期任务，因此不采用。

## TerminalCore 数据模型

公开只暴露语义值类型：

```swift
public struct CommandCompletion: Sendable, Equatable {
    public let exitStatus: UInt8?
    public let duration: Duration
}

public enum TerminalEvent: Sendable, Equatable {
    case commandCompleted(CommandCompletion)
    case bell
}
```

`CommandBlock` 新增可选 `completion`。不完整 A/B/C/D 仍按现有规则不制造命令块；完整
C→D 即使状态参数损坏，也可以得到 `exitStatus == nil` 的完成信息。

Core 内部使用紧凑 `CommandCompletionRecord`：

- `lineID: UInt64`
- `elapsedMilliseconds: UInt32`
- `column: UInt16`
- `exitStatus: UInt8`
- 1 字节 flags，区分是否有合法状态

字段总计并对齐为 16 字节。10 万条极端密集完成记录的裸值预算约 1.53 MiB；实际命令
通常跨多行且远少于历史行数。数组采用失效前缀和批量压缩，避免每滚一行搬移全部记录。

Terminal 只保留一个当前 C 的 `ContinuousClock.Instant?`。OSC 133 C 覆盖旧起点；D 仅在
存在起点时计算耗时、追加完成记录和事件，然后清空起点。B 后 D 没有起点，只结束现有
语义块，不追加结果。A、RIS 和新的 C 会丢弃悬空计时状态，避免损坏序列串联。

BEL 在 `execute(0x07)` 追加 `.bell`，不修改 grid。`takeEvents()` 与已有
`takeResponses()` 一样取走并清空瞬时队列；普通输出时队列为 nil 或空，不进行轮询。

## 坐标、reflow 与回收

完成记录锚定 D 转换的绝对 `lineID + column`，与命令块结束位置一致。

- `commandBlocks()` 扫描转换点时按位置合并完成记录，给对应 block 附上 completion。
- reflow 聚合旧逻辑行时，同时把完成记录转为逻辑 offset，再按新列宽映射回新的
  `lineID + column`；同行多个 B/C/D 的顺序沿用现有 transition order。
- 主屏上滚后，早于最老 scrollback lineID 的记录进入失效前缀并批量回收。
- `ED 2` 删除屏上记录、保留历史记录；`ED 3` 删除历史记录并把屏上记录重基到新 lineID。
- RIS 重建 Terminal，自然清空完成记录、计时状态和事件。
- alternate screen 继续不返回 command blocks；shell 在进入 TUI 前的 C 与离开后的 D
  仍属于主屏命令。备用屏尺寸变化不复制或持久化状态。

## Shell 事件与未读状态

`TerminalSession` 在每次 parser feed 后先取走 Core 事件，再调用新增 `onEvent`。回调与
`onUpdate`、`onExit` 一样位于 `@MainActor`，关闭 pane 时由 `detach()` 一并解除，避免
终止回调重入。

`TerminalTab` 保存一个不持久化的 `attention`：

```swift
enum TabAttention {
    case completed(CommandCompletion)
    case bell
    case failed(CommandCompletion)
}
```

聚合优先级固定为失败 > Bell > 成功；低优先级新事件不能覆盖尚未读取的高优先级状态，
同优先级保留最新详情。事件发生时：

- 标签不是当前可见标签，或 Ink 不活跃：更新 attention。
- 标签当前可见且 Ink 活跃：用户已能看到结果，不制造未读状态。
- 用户选中标签：清除该标签 attention。
- 应用重新活跃：清除当前可见标签 attention，其余后台标签保留。
- pane 删除或 shell 退出：随 pane/tab 生命周期自然停止接收；已有 tab attention 保留到
  用户查看或 tab 被删除。

非活动项目的标签不在顶部标签栏中，因此 `SidebarViewController.Row` 必须显示项目内
最高优先级 attention。切换到项目只清除它实际展示的活动标签，项目内其它未读标签继续
通过顶部标签或侧边栏聚合可见。

## UI 表达

`TabBarView.Tab` 和侧边栏 Row 接收只读 attention presentation：

- 成功：绿色实心圆点，辅助文案“命令已完成”。
- Bell：黄色铃铛图形，辅助文案“终端响铃”。
- 失败：红色感叹号圆形图形，辅助文案包含退出状态；图形与文案确保不只靠颜色。

状态图形占用标签原有左侧关闭按钮列：默认显示状态，悬停时关闭按钮覆盖该位置，因此不
扩大标签最小/理想/最大宽度。溢出菜单为对应项设置同一 SF Symbol 和辅助文本。侧边栏
在现有状态文字旁显示图形，不覆盖 Finder 项目标签色轨道。

状态 tooltip 可显示格式化耗时和退出状态，但不显示命令或输出。耗时格式采用稳定的
`<1 秒`、`12 秒`、`2 分 03 秒`，不显示机器相关的小数噪声。

## 系统通知

引入 `CommandNotificationCoordinating` 边界，生产实现封装
`UNUserNotificationCenter`，测试使用内存 fake。窗口控制器只提交已脱敏的值：标签显示
名、成功/失败、退出状态和耗时。

投递必须同时满足：

1. `NSApplication.isActive == false`；
2. 事件是完整命令完成，不是 Bell；
3. `duration >= 10 秒`。

通知标题为“命令已完成”或“命令失败”，正文只含标签名、格式化耗时和可选退出状态；不
包含命令文本、工作目录或输出。首次符合条件时才请求 `.alert` 授权，并在用户授予后投递
同一事件。后续先查询授权状态；拒绝、受限或错误只跳过通知，不弹自制错误、不影响标签
状态与 PTY。

不申请声音和 badge 权限，保持“安静通知”。通知调度不创建 Timer；阈值来自已经完成的
单调时钟耗时。

## 分层与性能

- `TerminalCore` 只依赖 Swift 标准库；不引入 AppKit、UserNotifications 或 Metal。
- `InkShell` 负责应用活跃状态、标签聚合和通知权限。
- `InkTerminalView` 只消费扩展后的 `CommandBlock`；本项不增加渲染实例或 draw call。
- 完成记录只在 OSC 133 D 出现时追加，BEL 只在控制字节 0x07 出现时追加；普通可打印
  字节、cell 写入和每帧渲染路径不变。

性能验收在 Release 下构造 10 万行高密度 C/D 命令，记录解析耗时、完成记录容量、
`MemoryLayout<CommandCompletionRecord>.stride` 和 reflow 耗时；与同字节量普通输出对比。
此外用 Time Profiler 采样 `ink-bench` 普通与高密度 OSC 133 场景，确认没有新的普通输出
热点或逐事件对象分配。所有数字写入 `docs/perf.md`，不设置机器相关绝对测试阈值。

## 测试与验收

### TerminalCore

- C→D 的 0/非零/缺失/损坏/越界状态和可控时间差。
- B→D 取消、重复 C、A/RIS 清理悬空计时、同 chunk 多个完成事件、BEL。
- `CommandBlock.completion` 与同行多个转换。
- 横纵 resize reflow 后坐标、状态和耗时不变。
- scrollback 环淘汰、ED 2、ED 3、RIS 后记录边界与批量回收。
- 16 字节 stride 与 10 万行 Release 规模记录。

### InkShell

- Session 事件逐 chunk 取走且 detach 后无回调。
- 多 pane 聚合、优先级、当前标签/后台标签、应用失焦与重新激活清除。
- 非活动项目侧边栏聚合和切换项目后的精确清除。
- 标签正常态、悬停关闭态、失败非颜色图形、辅助文案和溢出菜单状态。
- 9.999 秒不通知、10 秒通知、Ink 活跃不通知、Bell 不通知。
- 首次授权后投递、拒绝/错误静默降级、通知内容不含命令或目录。

### 回归门禁

- `swift test`
- `swift build`
- Release 高密度命令测量与 Time Profiler 记录
- `git diff --check`
- 确认 `Cell` 仍为 8 字节、`RowInfo` 仍为 2 字节、完成记录为 16 字节

## 文档与交付

同一 PR 更新 `docs/perf.md`。`docs/roadmap.md` 仍是范围权威来源，本项不改变范围；完成
进度由 Issue #70 与关闭它的 PR 记录。PR 只包含一个 `Closes #70`，不创建 release tag。
