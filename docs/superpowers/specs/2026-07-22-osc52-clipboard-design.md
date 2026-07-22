# OSC 52 有界只写剪贴板设计

**Issue:** #76  
**状态:** 待确认  
**日期:** 2026-07-22

## 目标

让终端程序通过 `OSC 52` 将 UTF-8 文本写入本机通用剪贴板，覆盖 SSH、tmux
等远端程序复制回本地的常见场景。该能力默认开启，但用户可在设置中关闭。

这是单向能力：Ink 永远不读取剪贴板来回答终端程序，也不会向 PTY 返回剪贴板
内容。实现必须把单条载荷、同一批输出产生的待处理效果以及异常序列的内存占用
同时约束住，且不能给 cell、行、scrollback 或每帧渲染增加常驻状态。

## 用户可见行为

- 支持 `OSC 52 ; Pc ; Pd`，接受 BEL 与 ST（`ESC \\`）终止，并允许序列跨多次
  PTY read。
- `Pc` 为空，或目标列表中含 `c`、`p`、`s` 任一字符时，写入
  `NSPasteboard.general`。仅含其它目标（`q`、`0`～`7` 等）时忽略整条序列。
- `Pd` 必须是严格 RFC 4648 标准 Base64，解码结果必须是合法 UTF-8；空载荷
  合法，并清空通用剪贴板中的旧内容。
- 解码后最多 1 MiB（1,048,576 字节）。超过上限、Base64 非法、UTF-8 非法、
  目标非法、序列被取消或未正确终止时，整条序列不产生任何效果。
- `Pd` 为 `?` 时始终忽略，不读取剪贴板、不写 PTY、不产生提示。
- 设置中心“交互”区域新增“允许终端程序写入剪贴板（OSC 52）”，默认开启；
  说明文字明确“仅允许写入，终端程序不能读取剪贴板”。关闭后 Core 仍完整消费
  序列以保持解析同步，但 Shell 丢弃写入效果。
- 后台标签或 pane 即使没有挂载视图也能写入剪贴板；该动作不点亮标签未读状态、
  不发送系统通知、不记录载荷。

## 范围外

- 剪贴板查询、`OSC 52 ... ?` 响应、任何本地剪贴板内容回传。
- 写入确认弹窗、来源白名单、按主机授权或一次性授权。
- 富文本、图片、文件、MIME、多剪贴板历史和 Kitty `OSC 5522`。
- 对系统剪贴板变更做监听、同步或审计。
- 将设置下沉到 `TerminalCore`，或让 Core 依赖 AppKit。

## 分层与数据流

```text
PTY 字节
  → Parser：只识别 OSC 开始 / 字节 / 完成 / 取消
  → Terminal：区分通用 OSC 与 OSC 52，并有界解码
  → TerminalEffect.clipboardWrite(String)：同一批只保留最后一次
  → TerminalSession.onEffect
  → MainWindowController：读取当前 InkConfig 策略
  → OSC52PasteboardWriter
  → NSPasteboard.general
```

`Parser` 只负责词法生命周期，不理解 `52`、目标、Base64 或剪贴板。`Terminal`
保持纯 Swift；AppKit 只出现在 `InkShell`。剪贴板效果与现有 `TerminalEvent` 分开，
因为 BEL 和命令完成事件会驱动标签未读状态与通知，而剪贴板写入不应产生这些 UI
副作用。

## Parser 的 OSC 生命周期

现有 Parser 自己累积最多 4096 字节，再一次性调用 `oscDispatch`。这无法支持
约 1.4 MiB 的 Base64 文本；直接提高上限会让所有 OSC 都具备大额常驻容量。
改为向具体化的 `Terminal` 发送四类词法动作：

- `oscStart()`：读到 `ESC ]` 时重置上一条未完成 OSC 并开始新序列；
- `oscPut(_:)`：仅对 OSC 数据字节逐字节调用；
- `oscEnd()`：读到 BEL 或 ST 时提交；
- `oscCancel()`：CAN、SUB、OSC 内 `ESC` 后不是 `\\`，或被新控制路径中止时丢弃。

C0 控制字节沿用当前行为：OSC 内除 BEL 与 ESC 外均忽略，不交给语义层。生命周期
状态必须跨 `feed` 保留。CAN/SUB 的全局取消逻辑在处于 OSC/OSC-escape 时先调用
`oscCancel()`，其它状态保持原行为。非法 `ESC x` 取消整条 OSC，并丢弃 `x` 后回到
ground。

Parser 不再持有 `oscBuffer`，所以普通文本热路径不增加分支以外的分配；新增调用只
发生在 OSC 内。泛型特化与无动态派发的现有约束保持不变。

## Terminal 的 OSC 累积器

Terminal 持有一个仅在未完成 OSC 期间存在的旁路枚举：

- `probing`：最多暂存识别控制号所需的短前缀；第一个 `;` 到来后判断是否为精确
  ASCII `52`；
- `regular`：现有 OSC 0/2、8、133 等通用载荷，最多 4096 字节；
- `osc52`：小型头状态机加增量 Base64 解码器；
- `discarding`：已知无效、超限或不支持，直到终止符只做常数工作。

如果控制号不是 `52`，前缀与后续字节进入 `regular`。通用 OSC 一旦超过 4096
字节就切换到 `discarding`，终止时整条丢弃；不再像当前实现那样把超长序列截成
合法前缀后误执行。没有分号的短 OSC 仍在 `oscEnd()` 时交给现有语义分派。

`oscStart()` 总会先释放上一条未完成序列的存储。`oscCancel()` 与 `oscEnd()` 后把
累积器恢复为空，并用 `removeAll(keepingCapacity: false)` 或替换值释放大容量，避免
一次大复制让终端永久保留 1 MiB capacity。

### OSC 52 头部

识别出 `52;` 后，只缓存 `Pc`，上限 16 个 ASCII 字节。遇到第二个 `;` 时完成目标
判断：

- 为空，或所有字符均为 xterm 目标字符且至少包含 `c`、`p`、`s` 之一：接受；
- 仅含 `q` 或 `0`～`7`：目标受 Ink 当前单剪贴板模型不支持，丢弃；
- 含其它字节、非 ASCII、控制字符或超过 16 字节：非法，丢弃。

目标字符列表的顺序与重复不影响结果。Ink 不尝试维护 primary、select 或编号
cut buffer；`c`、`p`、`s` 均映射到 macOS 通用剪贴板。

## 严格增量 Base64 解码

新增纯 Swift `OSC52ClipboardDecoder`，每四个输入字符组成一组并立刻输出最多三个
字节，不保存完整编码文本。规则如下：

- 只接受 `A-Z`、`a-z`、`0-9`、`+`、`/` 与结尾 `=`；拒绝空白、换行、URL-safe
  `-`/`_` 和其它字符；
- `=` 只能出现在最后一组，数量和尾部未使用位必须符合规范；padding 后再出现任何
  数据即整条无效；
- 终止时必须没有不完整四元组。空 `Pd` 是唯一不含四元组的合法情况；
- 在追加字节前检查解码后总数不会超过 1,048,576。超限时立即释放解码缓冲并进入
  `discarding`，后续输入不再解码；
- `Pd` 的第一个且唯一有效载荷字符为 `?` 时进入 query-discard 状态；任何 query
  都不产生 TerminalEffect 或 PTY response。

完成后用 `String(bytes: decoded, encoding: .utf8)` 做严格 UTF-8 校验。成功才创建
效果；失败释放字节缓冲。编码文本从不完整驻留，峰值至多为 1 MiB 解码缓冲加最终
String 的短暂重叠，约 2 MiB，不随 Base64 输入长度继续增长。

## 效果队列与内存上界

新增值类型：

```swift
public enum TerminalEffect: Equatable, Sendable {
    case clipboardWrite(String)
}
```

Terminal 不用无界数组保存效果，而是持有 `pendingEffect: TerminalEffect?`。一条
合法 OSC 52 完成时覆盖旧值；同一次 `Parser.feed` 即使含多条 1 MiB 写入，也只保留
最后一次，符合剪贴板最终状态语义，并立即释放旧载荷。空字符串仍是有效枚举值，
与 `nil` 可区分。

`takeEffects()` 取走并清空该值。`snapshotForSearch()` 必须同时清空未完成 OSC 累积器
和 `pendingEffect`，避免后台搜索快照复制或延长最多 1 MiB 敏感文本的生命周期。
效果不进入 Equatable 的持久模型、工作区快照、日志、scrollback 或渲染快照。

## Session 与 Shell

`TerminalSession` 增加 `onEffect: ((TerminalEffect) -> Void)?`。`consumeOutput` 在
Parser 返回后立即 `takeEffects()` 并调用该闭包，再处理现有 response 与
`onUpdate`；这样搜索刷新不会先创建仍共享大载荷的 Terminal 快照。`detach()` 清除
此闭包。

`MainWindowController.configureCallbacks(for:)` 为每个 pane（含后台 pane）连接效果
回调。处理时读取控制器当前的 `config.osc52WriteEnabled`，为 false 时立即丢弃；
为 true 时交给注入的 `OSC52PasteboardWriting`。不要求 pane 当前可见或存在
`TerminalMetalView`。

新增的 Shell 写入器负责：

1. `clearContents()`；
2. `setString(text, forType: .string)`；
3. 不读取旧值，不把内容写入日志或错误消息。

空字符串必须仍执行以上两步，从而清空旧文本。协议或闭包可在测试中替换，避免单元
测试污染全局剪贴板。视图现有用户主动复制闭包暂不重构；OSC 52 走独立的窗口级路径。

## 配置与同步

`InkConfig` 新增 `osc52WriteEnabled = true`，本地键为：

```toml
[clipboard]
osc52_write = true
```

缺少或无法解析时使用默认 true。保存沿用 MiniTOML 的已知字段合并，保留未知字段与
注释。设置开关即时生效：已完成并已派发的写入无法撤回，之后收到的效果按新值处理。

iCloud wire schema 保持版本 1，把 `osc52WriteEnabled` 作为可缺省 Bool 编码。新版
编码始终写出该字段；解码旧 schema 1 快照时字段缺失按 true 迁移。这样是向后兼容的
增量字段，不需要拒绝现存快照，也不声称旧客户端能理解新版设置。同步往返测试必须
覆盖 true、false 和旧快照缺字段三种情况。

## Roadmap 同步

实现时把 `docs/roadmap.md` 的 “OSC 52 剪贴板（SSH 中复制回本地）”补充为“有界、
仅写、默认开启且可关闭”，只澄清已经确认的安全范围，不扩张到读取、授权或富内容。

## 错误与恢复

所有输入错误都静默丢弃当前 OSC 52，不弹窗、不响铃、不发送通知，也不写 PTY。
丢弃状态持续到本条 BEL/ST，保证载荷中的可打印字节不会泄漏到终端屏幕。CAN/SUB 与
非法 `ESC x` 立即取消并回 ground，后续普通字节按现有 VT 同步规则处理。

剪贴板 API 返回失败时仅结束该次效果，不重试、不缓存载荷，也不影响 PTY 或终端更新。
设置关闭时的行为与失败相同，但仍已完整验证和消费序列。

## 测试策略

### TerminalCore

- BEL、ST、跨 read 分片与同一 read 多条序列；
- `Pc` 为空、`c`、`p`、`s`、组合目标、仅不支持目标、非法与超长目标；
- 空载荷清空、ASCII、多字节 UTF-8、恰好 1 MiB、超过 1 MiB；
- 标准 padding、缺 padding、错位 padding、非零尾位、空白、URL-safe 字符、非法
  UTF-8；
- `?` 查询不产生效果或 response；
- CAN、SUB、非法 `ESC x`、未终止序列、新 OSC 覆盖未完成序列均释放状态；
- OSC 0/2、8、133 回归，普通 OSC 恰好 4096 字节与 4097 字节整条丢弃；
- 连续多条大载荷只返回最后一次效果；取走后状态和容量释放；
- `snapshotForSearch()` 不包含未完成解码缓冲或待处理效果。

### InkConfig / InkShell

- TOML 缺省为 true、显式 false、保存往返和未知字段保留；
- iCloud schema 1 新字段往返、旧快照字段缺失迁移为 true；
- 设置开关展示、修改回调、外部配置刷新与恢复默认值；
- Session 在 `onUpdate` 前派发效果，detach 后不再回调；
- 前台与后台 pane 均走窗口级写入器，关闭设置时不写，且不产生未读状态或通知；
- 写入器对普通字符串和空字符串均先清空再写入，测试使用命名 pasteboard 或 spy。

### 验收

- 完整 `swift test --no-parallel` 与 `swift build`；
- 在本地 shell 和 SSH 会话手工验证复制、关闭开关、空载荷与超限载荷；
- 用 1 MiB 合法载荷和更大无终止/无效载荷观察进程内存，确认结束或取消后回落，连续
  序列不线性累积；
- 用 Time Profiler 对比普通文本吞吐。实现不改 grid/scrollback/Metal 路径，但
  Parser 是每字节热路径，必须确认 OSC 生命周期改造没有造成普通输出的可见回退。

## 取舍

没有采用“把 Parser 的通用 OSC 缓冲提高到约 1.4 MiB”，因为它会把少见功能的容量
成本扩散到每个 Parser，且必须完整保留编码文本。没有让 Parser 识别 `52`，因为这会
破坏词法与语义边界。没有复用 `TerminalEvent`，因为其 UI 语义会制造未读和通知噪声。
没有在设置关闭时跳过 Core 解码，因为把用户配置注入纯 Core 会增加耦合，并让序列
消费行为随 UI 状态变化；策略只决定最终副作用。
