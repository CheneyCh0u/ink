# OSC 9 / 777 终端通知设计

## 背景与目标

Ink 已有一条完整的本地通知链路：`TerminalCore` 产生命令完成事件，
`TerminalSession` 把事件送到 Shell，窗口控制器根据应用活跃状态决定是否提交，
`CommandNotificationCoordinator` 负责通知授权和 `UNUserNotificationCenter` 投递。
这条链路目前只接受 OSC 133 推导出的长命令完成事件，终端程序无法通过常见的
OSC 9 / OSC 777 主动请求通知。

本项实现 roadmap P1-B 的“通知（OSC 9 / 777）”。核心目标是让受信任的终端字节流
能够请求一条有界、安静的系统通知，同时保持 TerminalCore 的纯 Swift 分层、OSC
累积器的常量内存上限以及现有通知授权行为。协议输入始终视为不可信：不完整、未知、
非法 UTF-8、嵌入控制字符或超限序列都必须静默丢弃，不能显示部分内容。

## 范围

### 本次实现

- 支持 `OSC 9 ; message`，以 BEL 或 ST 结束。
- 支持 `OSC 777 ; notify ; title ; body`，以 BEL 或 ST 结束。
- 支持 OSC 在任意 PTY 输出 chunk 边界处分段，包括 ESC 与 ST 的 `\` 分开到达。
- TerminalCore 只产生有界的 `Sendable + Equatable` 值事件，不依赖 AppKit、Metal 或
  UserNotifications。
- 应用不活跃，或发出事件的 pane 不是当前活跃 pane 时，才向现有通知协调器提交。
- 复用现有懒授权、静默投递与错误降级行为，并在同一协调器内统一限制投递速率。
- 后台事件继续走现有 tab attention 聚合，不增加 cell、line、scrollback 或渲染实例
  的常驻字段。

### 明确不做

- 不支持 OSC 9 的桌面扩展、OSC 777 的 `report` 等其它子命令或任意厂商私有变体。
- 不支持图标、图片、声音、badge、通知动作、下载、脚本、任意参数透传或通知历史。
- 不持久化通知，不新增设置项，不把通知内容写入 scrollback、日志或工作区快照。
- 不改变系统通知点击行为，不实现点击后跳到精确 pane。
- 不为前台当前 pane 显示系统通知；终端内容本身已是即时反馈。
- 不改变 OSC 0/2 标题、OSC 8 超链接或 OSC 133 命令语义。

## 方案比较

### 方案 A：Parser 直接识别 OSC 9 / 777

Parser 能最早拒绝非法字节，但会把协议语义放进逐字节词法状态机，破坏现有
Parser/Terminal 边界，也使语义测试必须经过完整状态机。Parser 仍需为其它 OSC 保留
字节载荷，因此并不能省掉累积器。

### 方案 B：Parser 负责有界成帧，Terminal 负责语义（采用）

Parser 只累积一个最多 4096 字节的完整 OSC，并记录序列是否因控制字符或溢出失效；
收到 BEL/ST 后，只有完整且有效的字节切片才交给 `Terminal.oscDispatch`。Terminal
识别 9/777、严格解码 UTF-8 并构造值事件。这个方案保持现有分层，复用标题、超链接和
OSC 133 的分发入口，也能单独测试成帧和语义。

### 方案 C：把原始 OSC 上送 Shell

Shell 可以灵活解释厂商变体，但会让不可信协议字节跨层传播，使 Core 不再是终端协议
的唯一语义边界；Shell 还必须重复实现 UTF-8、控制字符和长度验证。因此不采用。

### 通知链路选择

为 OSC 另建一个 UserNotifications 客户端会复制授权、错误处理和测试 fake。采用扩展
现有 `CommandNotificationCoordinator` 的请求值，让命令完成和显式 OSC 事件都先变成
标题/正文，再进入同一个授权、节流和投递入口。协调器名称暂不因本项扩大而重命名，
避免无价值的跨仓库接口 churn；请求模型改为内容型值对象即可。

## 协议定义

### OSC 9

唯一接受的形式是：

```text
ESC ] 9 ; <message> BEL
ESC ] 9 ; <message> ESC \
```

`<message>` 是通知正文，可以包含普通分号。它必须是非空、非纯空白的合法 UTF-8，
且 UTF-8 长度不超过 1024 字节。OSC 9 没有标题；Shell 使用事件所属 tab 的显示名作为
回退标题，自定义 tab 名优先，否则沿用“终端任务”。

不接受 `OSC 9`、`OSC 9;`、额外的命令前缀或其它参数约定。

### OSC 777

唯一接受的形式是：

```text
ESC ] 777 ; notify ; <title> ; <body> BEL
ESC ] 777 ; notify ; <title> ; <body> ESC \
```

子命令必须逐字节等于小写 ASCII `notify`。第一个后续分号结束标题，余下全部字节都是
正文，因此正文可以包含普通分号。标题允许为空；为空时 Shell 使用 tab 显示名。非空
标题 UTF-8 长度不超过 128 字节，正文规则与 OSC 9 相同且不超过 1024 字节。

未知子命令、缺少标题/正文分隔符、空正文或多余的结构变体全部静默忽略。标题和正文
都保留发送方原始 Unicode 与空格，不进行裁剪；“纯空白”只用于合法性判断。

### 终止符与分块

BEL `0x07` 与 ST `ESC 0x5C` 都结束序列，二者语义完全相同。Parser 的状态跨 `feed`
调用保存，因此有效载荷、UTF-8 多字节字符、ESC 和反斜杠都可跨 chunk。

- 在 OSC 中收到 ESC 后，只有紧接的 `\` 构成 ST。
- ESC 后为其它字节时，整段 OSC 失效并回到 ground，不把 ESC 后字节重新解释为正文。
- CAN/SUB 取消当前序列，不产生事件。
- 缺少终止符时不产生事件；后续数据继续受 4096 字节总上限约束。

## 输入验证与资源上限

### OSC 累积器

Parser 继续使用复用的 `ContiguousArray<UInt8>`，并在初始化时预留小容量。逐字节追加只
发生在唯一持有的值缓冲上，不创建每字节数组或切片，也不发生有意的 COW 复制。

- 一个 OSC 最多累积 4096 字节，包括数值 code 与分隔符，不包括 ESC `]` 和终止符。
- 第 4097 个载荷字节把当前序列标记为 discarded，之后只扫描 BEL/ST，不再追加。
- discarded 序列终止时整段丢弃，绝不把 4096 字节前缀当成合法通知。
- 缓冲容量有 4096 字节硬上限并跨序列复用；普通输出、grid 与渲染热路径不新增分配。

### 控制字符

OSC 内除 BEL 终止符与组成 ST 的 ESC 外，任何 C0 控制字节都使整个序列失效。Terminal
语义验证还拒绝 U+007F 和 U+0080...U+009F，覆盖 UTF-8 编码的 DEL/C1。这样不会出现
“删除控制字符后继续通知”的内容变形，也不会把换行、方向控制通道或终端控制内容带进
系统 UI。

普通 Unicode 格式字符不在本项额外黑名单中；系统通知框架负责字形与双向文本布局。

### UTF-8 与字段长度

字段先按原始字节长度检查，再严格解码 UTF-8；`String(decoding:)` 产生替换字符的情况
通过回编码逐字节比较拒绝。限制如下：

| 边界 | 上限 | 超限策略 |
| --- | ---: | --- |
| 完整 OSC 累积 | 4096 bytes | 丢弃整个 OSC |
| OSC 777 标题 | 128 UTF-8 bytes | 不产生事件 |
| 通知正文 | 1024 UTF-8 bytes | 不产生事件 |
| Terminal 待取事件 | 64 个 | 丢弃新的事件 |

不截断标题或正文。截断可能切断 UTF-8、多字素簇或改变安全语义；拒绝整个事件更可预测。

## TerminalCore 数据模型

公开事件新增纯值载荷：

```swift
public struct TerminalNotification: Sendable, Equatable {
    public let title: String?
    public let body: String
}

public enum TerminalEvent: Sendable, Equatable {
    case commandCompleted(CommandCompletion)
    case notification(TerminalNotification)
    case bell
}
```

OSC 9 产生 `title == nil`；OSC 777 空标题同样归一化为 nil。正文始终已通过长度、UTF-8、
空白和控制字符验证。值类型不含闭包、引用到 Parser 缓冲的切片或 UI 类型。

`Terminal.pendingEvents` 统一限制为 64 个，BEL、命令完成和显式通知全部通过一个
`emit(_:)` 入口追加。达到上限后丢弃新事件，`takeEvents()` 仍一次取走并复用底层容量。
这使单个巨大 PTY chunk 即使包含成千上万个短 OSC/BEL，也不能让 Core 事件队列无界
增长。上限只占 Terminal 已存在的稀疏瞬时队列，不增加每 cell/per-line 开销。

## Shell gating 与 tab attention

`TerminalSession` 沿用现有 chunk 后 `takeEvents()` 回调。窗口控制器先定位事件来源的
project、tab 和 pane，然后计算：

```text
paneIsActive =
  未显示设置页
  && project 是当前 project
  && tab 是当前 tab
  && pane 是该 tab 的 active pane
```

OSC 通知的系统投递条件固定为：

```text
!isApplicationActive || !paneIsActive
```

因此：

- Ink 活跃且事件来自当前 pane：不提交系统通知。
- Ink 活跃但事件来自分屏中的非活动 pane：提交。
- Ink 活跃但事件来自后台 tab、后台 project 或设置页后的 pane：提交。
- Ink 不活跃：无论上次激活哪个 pane都提交。

这条规则独立于命令完成的“应用不活跃且耗时至少十秒”策略，不放宽现有长命令通知。

显式 OSC 事件继续进入 `TerminalTab.receive`。当来源不可见时，它使用现有 Bell 等级的
attention，确保后台 tab/项目仍有安静状态点；当前前台 pane 不制造未读。新增 enum case
不会增加 `TerminalTab` 或 pane 的常驻字段。

Shell 把 Core 事件转换为已验证的内容请求：OSC 777 的非空标题优先，否则使用所属 tab
显示名；正文原样传递。请求不携带 pane、命令、工作目录或输出。

## 授权、节流与投递

所有请求进入现有 `CommandNotificationCoordinator`。生产客户端继续：

- 首次实际投递时才查询/申请 `.alert` 授权；
- 已拒绝、受限、查询失败或投递失败时静默返回；
- 不申请 sound/badge，不改变通知点击和生命周期行为。

协调器增加一个基于 `ContinuousClock` 的全局一秒窗口：第一次请求立即通过；距离最近
一次通过请求不足一秒的后续请求丢弃；满一秒后下一次通过。节流在启动授权异步任务前
执行，因此通知洪泛不会创建大量 Task 或授权查询。命令完成与 OSC 显式通知共享同一
窗口，避免两条来源绕开彼此的速率限制。

时钟通过初始化闭包注入以做确定性测试。协调器仍位于 `@MainActor`，节流状态没有锁或
跨线程共享。被拒绝或投递失败的通过请求仍消耗该窗口，以资源保护优先。

## 分层与性能

- `TerminalCore` 不引入 AppKit、Metal、UserNotifications 或 Foundation 依赖。
- Parser 只增加一个序列级布尔状态，Terminal 只复用已有事件队列；`Cell`、`RowInfo`、
  历史行、glyph 实例和 draw call 均不变化。
- OSC 是控制序列冷路径；普通 printable byte、grid 写入和 Metal 渲染循环不增加分支。
- OSC 累积器总容量硬上限 4096，事件队列硬上限 64，通知字段分别为 128/1024 bytes。
- Shell 只在有效事件出现时创建 String 请求；节流拒绝发生在异步授权任务创建之前。
- 本项不新增第三方依赖。

按任务约束，本分支只运行聚焦单元测试，不运行全量 suite、完整 build 或 Instruments。
最终集成分支仍应在合入前执行这些项目级门禁。

## 测试与验收

### TerminalCore 协议

- OSC 9 与 OSC 777 分别使用 BEL/ST，只产生一次等值事件。
- 字节、UTF-8 多字节字符、ESC 与 ST 反斜杠跨 chunk 后仍只产生一次事件。
- OSC 777 正文中的分号被保留；空标题归一化为 nil。
- 未知 OSC code、未知 777 子命令、缺少字段、空/纯空白正文均不产生事件。
- 非法 UTF-8、嵌入 C0、DEL、C1、标题超过 128 bytes、正文超过 1024 bytes 均忽略。
- 完整 OSC 第 4097 字节使整个序列失效；终止后 Parser 能处理下一条合法 OSC。
- 非 ST 的 ESC、CAN/SUB 和未终止序列不产生事件。
- 一个 chunk 内制造超过 64 个事件时，队列只返回前 64 个，并能在取走后继续使用。
- `MemoryLayout<Cell>.stride` 与 `MemoryLayout<RowInfo>.stride` 保持现值。

### InkShell

- Session 按 chunk 上送 notification，detach 后不回调。
- 应用活跃 + 当前 pane 抑制；非活动 pane、后台 tab/project 和应用不活跃均提交。
- OSC 9/空标题 777 使用 tab 标题回退，非空 777 标题优先，正文不变。
- 显式事件映射到既有 tab attention，前台可见时不制造未读。
- 协调器对 OSC 复用首次授权、已授权、拒绝与投递失败路径。
- 一秒内多个混合请求只投递第一个，推进注入时钟后下一请求可投递。
- 现有命令通知的十秒阈值、前台抑制和脱敏内容保持不变。

### 聚焦验证

- `swift test --filter OSCNotificationTests`
- `swift test --filter TerminalSessionEventTests`
- `swift test --filter CommandNotificationCoordinatorTests`
- `swift test --filter CommandStatusWindowTests`
- `git diff --check`

## 文档与交付

`docs/roadmap.md` 已把 OSC 9 / 777 列为 P1-B，本项不改变范围，因此无需修改 roadmap。
本分支不发布、不打 tag、不推送、不建 PR；提交正文使用 `Refs #81`，由上层集成工作流
创建唯一关闭 Issue #81 的 PR。
