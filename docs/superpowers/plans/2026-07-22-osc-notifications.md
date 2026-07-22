# OSC 9 / 777 终端通知 Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** 严格解析有界的 OSC 9 / 777 主动通知，在 Ink 不活跃或来源 pane 非当前 pane 时，复用已有 Shell 授权与投递链路显示受节流的安静系统通知。

**Architecture:** `Parser` 只负责 4096-byte 有界 OSC 成帧并整段淘汰控制字符/溢出输入，`Terminal` 严格验证语法、UTF-8、字段长度并发出最多 64 个纯值事件；`TerminalSession` 沿用事件回调，`MainWindowController` 根据应用和 pane 活跃状态 gating；现有 `CommandNotificationCoordinator` 接收内容型请求并为命令完成与 OSC 统一执行懒授权、一秒节流和投递。

**Tech Stack:** Swift 6、TerminalCore、AppKit、UserNotifications、Swift Testing、SwiftPM；最低 macOS 14.0，无第三方依赖。

## Global Constraints

- 只在 `.worktrees/issue-81` 与 `agent/issue-81-osc-notifications` 分支工作。
- `TerminalCore` 不得引入 AppKit、Metal、UserNotifications 或 Foundation。
- 只支持 `9;<message>` 与 `777;notify;<title>;<body>`；其它变体静默忽略。
- BEL/ST 等价，必须支持任意 chunk 边界；非法 UTF-8、控制字符和超限输入整段忽略。
- 完整 OSC 最多 4096 bytes；标题最多 128 UTF-8 bytes；正文最多 1024 bytes；待取事件最多 64 个。
- OSC 累积器不得逐字节复制或无界增长；不增加 per-cell、per-line、scrollback 或渲染开销。
- 当前前台 pane 抑制 OSC 系统通知；后台 pane/tab/project 与应用不活跃时提交。
- 现有 OSC 133 长命令通知阈值和脱敏行为不得改变。
- 现有 UserNotifications 授权、错误降级和点击行为只复用，不复制实现。
- 严格执行 RED→GREEN→REFACTOR：每组生产代码前先运行新测试并观察预期失败。
- 每个提交主题与正文用中文，正文包含 `Refs #81`，不写 `Closes` 或 AI trailer。
- 按任务约束只跑列出的聚焦测试；不跑全量 suite、完整 build、Instruments，不推送、不建 PR、不合并、不发布。

---

## 文件结构

- 修改 `Sources/TerminalCore/CommandStatus.swift`：新增纯值 `TerminalNotification` 与事件 case。
- 修改 `Sources/TerminalCore/Terminal.swift`：严格解释 OSC 9/777、字段验证、统一有界事件入口。
- 修改 `Sources/TerminalCore/Parser.swift`：OSC 溢出/控制字符整段失效、缓冲预留与复用。
- 新建 `Tests/TerminalCoreTests/OSCNotificationTests.swift`：语法、终止符、chunk、UTF-8、控制字符与资源上限。
- 修改 `Tests/TerminalCoreTests/CommandStatusTests.swift`：事件队列上限和原有事件回归。
- 修改 `Tests/InkShellTests/TerminalSessionEventTests.swift`：Session 上送通知与 detach 回归。
- 修改 `Sources/InkShell/CommandNotificationCoordinator.swift`：内容型请求、显式策略与统一节流。
- 修改 `Tests/InkShellTests/CommandNotificationCoordinatorTests.swift`：请求转换、授权与确定性节流。
- 修改 `Sources/InkShell/TabAttention.swift`：显式通知沿用 Bell 等级 attention。
- 修改 `Sources/InkShell/MainWindowController.swift`：来源 pane 活跃计算、OSC gating 与请求提交。
- 修改 `Tests/InkShellTests/TabAttentionTests.swift`、`CommandStatusWindowTests.swift`：attention、pane/app gating 与内容回退。
- 新建 `.superpowers/issue-81-report.md`：提交、聚焦测试和已知集成冲突。

---

### Task 1: TerminalCore 通知值类型与 OSC 语义

**Files:**
- Create: `Tests/TerminalCoreTests/OSCNotificationTests.swift`
- Modify: `Sources/TerminalCore/CommandStatus.swift`
- Modify: `Sources/TerminalCore/Terminal.swift`

**Produces:** `TerminalNotification(title:body:)`、`TerminalEvent.notification`、OSC 9/777 严格语义。

- [ ] **Step 1: 写 OSC 9/777 基本语义失败测试**

创建测试 helper，以多个 chunk 依次调用 `Parser.feed`，最后 `terminal.takeEvents()`：

```swift
@Suite("OSC 主动通知")
struct OSCNotificationTests {
    @Test("OSC 9 使用 BEL 产生无标题通知")
    func osc9BEL() {
        #expect(events(for: [Array("\u{1B}]9;构建完成\u{7}".utf8)]) == [
            .notification(.init(title: nil, body: "构建完成")),
        ])
    }

    @Test("OSC 777 使用 ST 并保留正文分号")
    func osc777ST() {
        #expect(events(for: [Array("\u{1B}]777;notify;部署;节点 a;b\u{1B}\\".utf8)]) == [
            .notification(.init(title: "部署", body: "节点 a;b")),
        ])
    }

    @Test("OSC 777 空标题归一化为 nil")
    func emptyTitle() {
        #expect(events(for: [Array("\u{1B}]777;notify;;完成\u{7}".utf8)]) == [
            .notification(.init(title: nil, body: "完成")),
        ])
    }
}
```

- [ ] **Step 2: 运行测试确认 RED**

Run: `swift test --filter OSCNotificationTests`

Expected: FAIL，编译器报告 `TerminalEvent` 没有 `notification`、找不到
`TerminalNotification`。

- [ ] **Step 3: 新增公开纯值事件**

在 `CommandStatus.swift` 增加：

```swift
public struct TerminalNotification: Sendable, Equatable {
    public let title: String?
    public let body: String

    public init(title: String?, body: String) {
        self.title = title
        self.body = body
    }
}

public enum TerminalEvent: Sendable, Equatable {
    case commandCompleted(CommandCompletion)
    case notification(TerminalNotification)
    case bell
}
```

- [ ] **Step 4: 在 Terminal 实现最小严格语义**

常量：

```swift
private static let maxNotificationTitleBytes = 128
private static let maxNotificationBodyBytes = 1024
```

`oscDispatch` 的 `case 9` 调用 `handleOSC9(payload)`；`case 777` 调用
`handleOSC777(payload)`。辅助函数必须：

1. 先检查原始字段 byte count；
2. 用 `String(decoding:as:)` 解码并以 `utf8.elementsEqual` 验证无替换字符；
3. 拒绝 U+0000...001F、U+007F...009F；
4. 正文不得为空或所有 scalar 都是 whitespace；
5. 777 只认逐字节 `notify`，以第一个后续分号切标题，余下载荷全为正文；
6. 空标题归一化为 nil；
7. 通过现有事件入口暂时追加通知事件。

- [ ] **Step 5: 运行测试确认 GREEN**

Run: `swift test --filter OSCNotificationTests`

Expected: PASS 3 tests。

- [ ] **Step 6: 扩展语义拒绝测试**

加入 table-driven cases：未知 code、`777;report`、大小写错误的 `Notify`、缺标题分隔、
空正文、空白正文、非法 UTF-8、DEL、UTF-8 C1、129-byte 标题、1025-byte 正文；并加入
边界通过案例：128-byte 标题、1024-byte 正文。

- [ ] **Step 7: 运行扩展测试确认失败后补齐最小实现**

Run: `swift test --filter OSCNotificationTests`

Expected RED: 至少非法 UTF-8/控制/长度 case 失败；完成验证 helper 后再次运行，Expected GREEN。

- [ ] **Step 8: 提交 Core 语义**

```bash
git add Sources/TerminalCore/CommandStatus.swift Sources/TerminalCore/Terminal.swift Tests/TerminalCoreTests/OSCNotificationTests.swift
git commit -m "feat(core): 解析 OSC 主动通知" \
  -m "只把通过 UTF-8、控制字符与字段长度校验的 OSC 9/777 转成纯值事件，避免不可信载荷跨层传播。\n\nRefs #81"
```

---

### Task 2: Parser 有界成帧与 chunk 行为

**Files:**
- Modify: `Tests/TerminalCoreTests/OSCNotificationTests.swift`
- Modify: `Sources/TerminalCore/Parser.swift`

**Produces:** 总长上限、控制字符整段失效、BEL/ST/chunk 恢复。

- [ ] **Step 1: 写分块与终止符测试**

覆盖：

- UTF-8 三字节字符分别落入三个 chunk；
- `ESC ]`、payload、ST 的 ESC、ST 的 `\` 全部分开；
- 一个 chunk 内两条合法通知各只产生一次；
- BEL 结束后紧跟普通打印字节，grid 仍收到普通文本；
- ST 结束后下一条合法 OSC 仍被处理。

- [ ] **Step 2: 运行测试确认现有分块能力与新 case 状态**

Run: `swift test --filter OSCNotificationTests`

Expected: 新的合法 chunk tests 可通过；如有失败，先记录具体 case，不提前改生产代码。

- [ ] **Step 3: 写 malformed/oversize RED 测试**

覆盖：

- payload 中插入 NUL、TAB、LF 后整段不产生事件，而不是删除控制字符后通知；
- 4097-byte OSC 即使前 4096 bytes 构成合法前缀也不产生事件；
- oversize 终止后紧接合法 OSC，第二条能产生事件；
- ESC 后不是 `\` 时整段失效；
- CAN/SUB 取消；
- 未终止输入不产生事件。

特别构造超限 case 为 `9;` + 1024-byte 合法正文 + 大量尾随字节，确保旧实现若截断前缀
会暴露错误，而不是仅因正文自身上限碰巧被 Terminal 拒绝。

- [ ] **Step 4: 运行测试确认 RED**

Run: `swift test --filter OSCNotificationTests`

Expected: 控制字符被旧 Parser 丢弃后仍产生事件、或 oversize 前缀被 dispatch，至少一个
断言失败。

- [ ] **Step 5: 实现序列级 discarded 状态**

在 Parser 增加 `oscIsDiscarded`：

- `init()` 为 `oscBuffer` 预留合理小容量，不预分配完整 4096；
- `ESC ]` 清空 count、重置 discarded；
- OSC 中除 BEL/ESC 外的 C0 把 discarded 设为 true；
- 达到 4096 后再收到载荷字节时设 discarded，之后不再 append；
- BEL/ST 只在 `!oscIsDiscarded` 时 dispatch；
- 取消、非法 ESC 和终止后都回 ground；下一个 `ESC ]` 必须完全重置。

不要让 `oscBuffer` 逃逸或在逐字节循环复制，不新增每 byte 临时数组/String。

- [ ] **Step 6: 运行聚焦测试确认 GREEN**

Run: `swift test --filter OSCNotificationTests`

Expected: 全部通过。

- [ ] **Step 7: 静态检查热路径改动**

Run: `git diff -- Sources/TerminalCore/Parser.swift`

Expected: OSC 分支只有 bool/计数检查；普通 `.ground` printable 分支无变化；缓冲仍是
`ContiguousArray` 且使用 `removeAll(keepingCapacity:)`。

- [ ] **Step 8: 提交 Parser 边界**

```bash
git add Sources/TerminalCore/Parser.swift Tests/TerminalCoreTests/OSCNotificationTests.swift
git commit -m "fix(parser): 整段丢弃非法 OSC" \
  -m "用固定上限与序列失效标志避免截断前缀误执行，并保持跨 chunk 的 BEL/ST 成帧。\n\nRefs #81"
```

---

### Task 3: Terminal 事件队列硬上限

**Files:**
- Modify: `Tests/TerminalCoreTests/OSCNotificationTests.swift`
- Modify: `Tests/TerminalCoreTests/CommandStatusTests.swift`
- Modify: `Sources/TerminalCore/Terminal.swift`

**Produces:** 所有 `TerminalEvent` 共用 64-event 上限。

- [ ] **Step 1: 写事件洪泛 RED 测试**

一次 `Parser.feed` 送入 80 条短 OSC 9，断言第一次 `takeEvents()` 恰为前 64 条、顺序
不变，第二次为空；随后再送一条合法通知并断言可取，证明上限不是永久锁死。

在 `CommandStatusTests` 加混合事件 case：63 BEL + 1 command completion + 1 OSC notification，
断言最后一条被丢弃且原有两种事件也走同一个上限。

- [ ] **Step 2: 运行测试确认 RED**

Run: `swift test --filter 'OSCNotificationTests|CommandStatusTests'`

Expected: 当前无界数组返回 80/65 个事件，断言失败。

- [ ] **Step 3: 实现统一 emit**

在 `Terminal` 增加 `maxPendingEvents = 64` 与：

```swift
private mutating func emit(_ event: TerminalEvent) {
    guard pendingEvents.count < Self.maxPendingEvents else { return }
    pendingEvents.append(event)
}
```

替换 BEL、OSC 133 完成和 OSC 9/777 的直接 `pendingEvents.append`。`takeEvents()` 保持
取走后 `removeAll(keepingCapacity:)`，不改变事件顺序。

- [ ] **Step 4: 运行测试确认 GREEN**

Run: `swift test --filter 'OSCNotificationTests|CommandStatusTests'`

Expected: PASS。

- [ ] **Step 5: 验证结构体常驻布局回归**

Run: `swift test --filter CommandStatusTests.compactRecordLayout`

Expected: `Cell == 8`、`RowInfo == 2`、命令完成记录仍为 16 bytes。

- [ ] **Step 6: 提交事件上限**

```bash
git add Sources/TerminalCore/Terminal.swift Tests/TerminalCoreTests/OSCNotificationTests.swift Tests/TerminalCoreTests/CommandStatusTests.swift
git commit -m "perf(core): 限制瞬时事件积压" \
  -m "所有终端事件共享固定队列上限，避免单个恶意 PTY chunk 放大常驻内存。\n\nRefs #81"
```

---

### Task 4: Session 上送回归

**Files:**
- Modify: `Tests/InkShellTests/TerminalSessionEventTests.swift`
- Modify only if required: `Sources/InkShell/TerminalSession.swift`

- [ ] **Step 1: 写 Session 通知测试**

沿用现有测试 transport，喂入 OSC 9 与 OSC 777，断言 `onEvent` 按顺序收到两个纯值事件；
再次触发 update 不重复收到。另在 `detach()` 后喂入通知，断言无回调。

- [ ] **Step 2: 运行测试观察 RED/GREEN**

Run: `swift test --filter TerminalSessionEventTests`

Expected: 新事件沿现有通道可能直接 GREEN。若 GREEN，记录“现有通道已满足，无生产代码
需要修改”；不得为了制造提交而改实现。若失败，只做使事件按 chunk 取走的最小修复。

- [ ] **Step 3: 提交测试或最小修复**

```bash
git add Tests/InkShellTests/TerminalSessionEventTests.swift Sources/InkShell/TerminalSession.swift
git commit -m "test(session): 覆盖 OSC 通知上送" \
  -m "固定通知事件按输出 chunk 取走且 detach 后停止回调的既有会话边界。\n\nRefs #81"
```

若 `TerminalSession.swift` 未变化，只 stage 测试文件。

---

### Task 5: 通知请求内容化与统一节流

**Files:**
- Modify: `Tests/InkShellTests/CommandNotificationCoordinatorTests.swift`
- Modify: `Sources/InkShell/CommandNotificationCoordinator.swift`
- Modify: `Sources/InkShell/MainWindowController.swift`（只做现有 command call-site 编译迁移）
- Modify: `Tests/InkShellTests/CommandStatusWindowTests.swift`（只做 fake/request 编译迁移）

**Produces:** 内容型请求、命令 factory、OSC factory、纯 gating 策略、全局一秒节流。

- [ ] **Step 1: 写请求映射与策略 RED 测试**

测试：

- `.command(tabTitle:completion:)` 生成与原来完全一致的成功/失败标题正文；
- `.terminal(notification:fallbackTitle:)` 对 nil/空标题使用 tab 回退，对非空标题优先，正文不变；
- `ExplicitNotificationPolicy` 仅在应用活跃且 pane 活跃时返回 false，其余三种组合为 true。

- [ ] **Step 2: 运行测试确认 RED**

Run: `swift test --filter CommandNotificationCoordinatorTests`

Expected: 请求 factory 与显式策略不存在，编译失败。

- [ ] **Step 3: 把请求改为内容型值**

保留 `CommandNotificationRequest`/`CommandNotificationCoordinating` 名称以缩小接口 churn，
字段改为 `title/body`，增加两个静态 factory。把旧 `content(for:)` 的命令格式化逻辑移入
`.command` factory；`.terminal` 使用 Core title 或 fallback。

协调器只把请求转换成 `LocalNotificationContent(title:body:)`，不再理解事件来源。同步迁移
MainWindow 现有命令 call-site 和测试 fake；此步不改变命令 policy。

- [ ] **Step 4: 运行请求/授权回归确认 GREEN**

Run: `swift test --filter CommandNotificationCoordinatorTests`

Expected: 原有阈值、lazy client、授权/拒绝测试和新增 factory/policy 测试全部通过。

- [ ] **Step 5: 写确定性节流 RED 测试**

用 `ContinuousClock.now` 起点与可变注入闭包：

1. 同一 instant 提交 command 和 terminal 两个请求；等待 async drain；只投递第一个；
2. 时钟推进 999ms 再提交；仍不投递；
3. 推进到整 1s 再提交；第二次投递；
4. denied client 也只查询一次，证明节流发生在 Task/授权查询前。

- [ ] **Step 6: 运行测试确认 RED**

Run: `swift test --filter CommandNotificationCoordinatorTests`

Expected: 旧协调器投递/查询全部请求，计数断言失败。

- [ ] **Step 7: 实现 MainActor 一秒节流**

给协调器注入 `now: @MainActor () -> ContinuousClock.Instant` 与
`minimumInterval: Duration = .seconds(1)`，保存 `lastAcceptedAt`。`submit` 首先判断间隔；
不足一秒立即返回，不创建 client/Task；通过后更新时刻，再执行原有 lazy client、授权、
静默错误路径。

- [ ] **Step 8: 运行聚焦测试确认 GREEN**

Run: `swift test --filter CommandNotificationCoordinatorTests`

Expected: PASS；原有授权和内容测试行为不退化。

- [ ] **Step 9: 提交通知协调器重用**

```bash
git add Sources/InkShell/CommandNotificationCoordinator.swift Sources/InkShell/MainWindowController.swift Tests/InkShellTests/CommandNotificationCoordinatorTests.swift Tests/InkShellTests/CommandStatusWindowTests.swift
git commit -m "feat(shell): 统一通知请求与节流" \
  -m "让命令完成和 OSC 使用同一内容请求、懒授权与一秒速率窗口，避免复制系统通知通道。\n\nRefs #81"
```

---

### Task 6: pane-aware gating 与 attention

**Files:**
- Modify: `Tests/InkShellTests/TabAttentionTests.swift`
- Modify: `Tests/InkShellTests/CommandStatusWindowTests.swift`
- Modify: `Sources/InkShell/TabAttention.swift`
- Modify: `Sources/InkShell/MainWindowController.swift`

- [ ] **Step 1: 写 attention RED 测试**

断言 `TabAttention(event: .notification(...)) == .bell`，并验证它与成功/失败合并仍遵循
失败 > Bell > 成功。运行：

Run: `swift test --filter TabAttentionTests`

Expected: enum switch 不完整导致编译失败或断言失败。

- [ ] **Step 2: 最小实现 notification → bell 并确认 GREEN**

只在 `TabAttention.init(event:)` 增加 case，不新增状态类型、字段或 UI 图形。

Run: `swift test --filter TabAttentionTests`

Expected: PASS。

- [ ] **Step 3: 扩展窗口 fixture 与 gating RED 测试**

在现有 `CommandStatusWindowTests` fixture 中保留两个 tab/两个 pane 的稳定 ID，使用
`NotificationRecorder` 断言：

- 应用活跃、当前 tab 的 active pane 发 OSC：0 requests；
- 应用活跃、同 tab 非 active pane：1 request；
- 应用活跃、后台 tab：1 request；
- 应用活跃、后台 project（若 fixture 支持）：1 request；
- 应用不活跃、当前 pane：1 request；
- OSC 9 使用自定义 tab title 回退；
- OSC 777 非空 title 优先；
- 当前 pane 不生成 unread，后台来源生成 Bell attention；
- 原有短/长命令通知 gate 断言保持不变。

每个 case 建独立 fixture，避免一秒协调器状态或 attention 相互污染；Recorder 不执行系统
协调器节流，只观察窗口是否提交。

- [ ] **Step 4: 运行窗口测试确认 RED**

Run: `swift test --filter CommandStatusWindowTests`

Expected: MainWindow 尚未处理 `.notification`，非活动 pane/app case 请求计数为 0。

- [ ] **Step 5: 实现来源 pane 活跃计算和 OSC 分支**

在 `handleTerminalEvent` 定位 project/tab 后计算：

```swift
let paneIsActive = !isShowingSettings
    && project.id == activeProjectID
    && tab.id == project.activeTabID
    && tab.activePaneID == paneID
```

先沿用 `tab.receive(event:markUnread:)`，其可见条件应以 `paneIsActive && applicationActive`
为准，确保同 tab 后台 pane 也会产生 attention。switch：

- `.commandCompleted` 保持现有 `CommandNotificationPolicy`；
- `.notification` 使用 `ExplicitNotificationPolicy`，通过时提交 `.terminal(...)`；
- `.bell` 不发送系统通知。

- [ ] **Step 6: 运行窗口与协调器聚焦测试确认 GREEN**

Run: `swift test --filter 'CommandStatusWindowTests|CommandNotificationCoordinatorTests|TabAttentionTests'`

Expected: PASS；命令完成 gate 与新增 OSC gate 同时满足。

- [ ] **Step 7: 提交 pane-aware Shell 接线**

```bash
git add Sources/InkShell/TabAttention.swift Sources/InkShell/MainWindowController.swift Tests/InkShellTests/TabAttentionTests.swift Tests/InkShellTests/CommandStatusWindowTests.swift
git commit -m "feat(shell): 按来源 pane 显示 OSC 通知" \
  -m "仅抑制当前前台 pane 的主动通知，后台 pane 复用既有状态点和通知协调器。\n\nRefs #81"
```

---

### Task 7: 聚焦回归与交付报告

**Files:**
- Create: `.superpowers/issue-81-report.md`
- Modify only if focused failures reveal issue-scoped defects: files above

- [ ] **Step 1: 运行 Core 聚焦测试**

Run: `swift test --filter 'OSCNotificationTests|CommandStatusTests'`

Expected: PASS。

- [ ] **Step 2: 运行 Session 聚焦测试**

Run: `swift test --filter TerminalSessionEventTests`

Expected: PASS。

- [ ] **Step 3: 运行 Shell 聚焦测试**

Run: `swift test --filter 'CommandNotificationCoordinatorTests|CommandStatusWindowTests|TabAttentionTests'`

Expected: PASS。

- [ ] **Step 4: 检查 diff 与工作树**

Run: `git diff --check`

Expected: 无输出、exit 0。

Run: `git status --short --branch`

Expected: 只剩尚未提交的报告文件或 clean。

Run: `git log --oneline b8c3355..HEAD`

Expected: 只包含 Issue #81 的规格、计划与分阶段实现提交。

- [ ] **Step 5: 写交付报告**

`.superpowers/issue-81-report.md` 必须记录：

- Issue、branch、worktree 与 base commit；
- 设计/实现提交 hash 与主题；
- 每条实际运行的聚焦测试命令、结果和测试数量；
- 明确未运行全量 suite/build/Instruments（任务要求）；
- `Cell`/`RowInfo` 无字段变化、OSC/事件硬上限；
- cherry-pick 时最可能冲突的文件，尤其是通知协调器、MainWindowController、
  CommandStatusWindowTests；
- 未 push、未建 PR、未 merge、未 release。

- [ ] **Step 6: 提交报告**

```bash
git add .superpowers/issue-81-report.md
git commit -m "docs(notification): 记录 Issue 81 验证结果" \
  -m "汇总聚焦测试、性能边界与集成冲突，便于上层分支安全 cherry-pick。\n\nRefs #81"
```

- [ ] **Step 7: 最终只读确认**

Run: `git status --short --branch && git log --oneline b8c3355..HEAD`

Expected: 工作树 clean；报告列出的提交与实际一致。

不要运行全量测试、`swift build`、Instruments，不 push、不创建 PR。
