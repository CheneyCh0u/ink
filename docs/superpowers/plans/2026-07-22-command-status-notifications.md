# 命令状态与安静通知 Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** 为 OSC 133 命令块记录耗时与退出状态，在后台标签/项目显示可访问的未读状态，并仅为 Ink 失焦后的十秒长任务发送脱敏系统通知。

**Architecture:** `TerminalCore` 用 16 字节稀疏完成记录保存 D 转换元数据，并用瞬时事件队列上送命令完成与 BEL；`InkShell` 在 Session、Tab、Project 与窗口之间聚合未读状态，`CommandNotificationCoordinator` 单独封装 UserNotifications 权限与投递。坐标映射复用语义 reflow/scrollback 路径，UI 只消费值类型 presentation，不接触 Core 内部存储。

**Tech Stack:** Swift 6、TerminalCore、AppKit、UserNotifications、Swift Testing、SwiftPM、`ink-bench`、Instruments Time Profiler；最低 macOS 14.0，无第三方依赖。

## Global Constraints

- `TerminalCore` 不得引入 AppKit、Metal 或 UserNotifications。
- `Cell` 必须保持 8 字节，`RowInfo` 必须保持 2 字节；完成记录 stride 必须为 16 字节。
- 不增加每 cell / 每 line 字段或对象，不保存命令文本、输出、通知历史或未读状态。
- 只有 OSC 133 C 后的 D 才生成完成记录；B 后 D 是取消。
- 状态聚合优先级固定为失败 > Bell > 成功/未知完成；失败不能只靠颜色表达。
- 系统通知必须同时满足 Ink 不活跃、完整命令完成、耗时至少 10 秒；通知不得含命令、目录或输出。
- 普通可打印字节、grid 写入、scrollback cell 和每帧渲染路径不得新增对象分配。
- 代码标识符用英文，注释/文档/提交用中文；每个提交正文包含 `Refs #70`，提交信息不写 `Closes`。
- 本项不实现 OSC 9/777、不新增设置项、不发布、不创建 tag。

---

## 文件结构

- 新建 `Sources/TerminalCore/CommandStatus.swift`：公开完成/事件值类型与 16 字节内部记录。
- 修改 `Sources/TerminalCore/Terminal.swift`：OSC 133 计时、BEL、事件队列、记录生命周期、reflow/清屏回收。
- 修改 `Sources/TerminalCore/CommandBlocks.swift`：把完成记录附到对应命令块。
- 新建 `Tests/TerminalCoreTests/CommandStatusTests.swift`：协议状态、事件与记录边界。
- 修改 `Tests/TerminalCoreTests/CommandBlockTests.swift`、`ReflowTests.swift`：历史查询与坐标稳定性。
- 修改 `Sources/InkShell/TerminalSession.swift`：按 chunk 取走 Core 事件并上送。
- 新建 `Sources/InkShell/TabAttention.swift`：标签未读状态、优先级、格式化与项目聚合。
- 修改 `Sources/InkShell/TerminalTab.swift`、`Project.swift`：运行态 attention 接口。
- 新建 `Sources/InkShell/CommandNotificationCoordinator.swift`：纯策略、授权抽象与 UserNotifications 适配。
- 修改 `Sources/InkShell/TabBarView.swift`、`SidebarViewController.swift`：标签、溢出菜单、项目行状态图形。
- 修改 `Sources/InkShell/MainWindowController.swift`、`AppDelegate.swift`：事件归属、活跃状态、清除和通知接线。
- 新建 `Tests/InkShellTests/TerminalSessionEventTests.swift`、`TabAttentionTests.swift`、`CommandNotificationCoordinatorTests.swift`、`CommandStatusWindowTests.swift`。
- 修改 `Tests/InkShellTests/TabBarViewTests.swift`、`ProjectSidebarTests.swift`：视觉结构和辅助信息。
- 修改 `Sources/ink-bench/main.swift`、`docs/perf.md`：Release 与 Time Profiler 证据。

---

### Task 1: OSC 133 生命周期与瞬时事件

**Files:**
- Create: `Sources/TerminalCore/CommandStatus.swift`
- Modify: `Sources/TerminalCore/Terminal.swift:23-75, 521-536, 675-713`
- Create: `Tests/TerminalCoreTests/CommandStatusTests.swift`

**Interfaces:**
- Produces: `CommandCompletion(exitStatus:duration:)`、`TerminalEvent.commandCompleted`、`TerminalEvent.bell`、`Terminal.takeEvents()`。
- Produces internal: `CommandCompletionRecord`（16 字节）、`Terminal.handleOSC133(_:now:)`，供 Task 2 测试与坐标映射使用。

- [ ] **Step 1: 写失败测试覆盖协议与事件**

```swift
import Testing
@testable import TerminalCore

@Suite("命令完成状态")
struct CommandStatusTests {
    @Test("只有 C 后的 D 生成带耗时与退出状态的事件")
    func completedCommandEvent() throws {
        var terminal = Terminal(size: .init(columns: 80, rows: 24))
        let clock = ContinuousClock()
        let start = clock.now

        terminal.handleOSC133(ArraySlice("C".utf8), now: start)
        terminal.handleOSC133(
            ArraySlice("D;7".utf8),
            now: start.advanced(by: .seconds(12) + .milliseconds(345))
        )

        #expect(terminal.takeEvents() == [
            .commandCompleted(.init(exitStatus: 7, duration: .milliseconds(12_345))),
        ])
        #expect(terminal.takeEvents().isEmpty)
    }

    @Test("B 后 D 是取消且异常状态只丢弃状态值")
    func abortAndInvalidStatus() {
        var terminal = Terminal(size: .init(columns: 80, rows: 24))
        let clock = ContinuousClock()
        terminal.handleOSC133(ArraySlice("B".utf8), now: clock.now)
        terminal.handleOSC133(ArraySlice("D;1".utf8), now: clock.now)
        #expect(terminal.takeEvents().isEmpty)

        let start = clock.now
        terminal.handleOSC133(ArraySlice("C".utf8), now: start)
        terminal.handleOSC133(
            ArraySlice("D;999".utf8),
            now: start.advanced(by: .seconds(1))
        )
        #expect(terminal.takeEvents() == [
            .commandCompleted(.init(exitStatus: nil, duration: .seconds(1))),
        ])
    }

    @Test("重复 C 覆盖起点且 BEL 逐个上送")
    func repeatedStartAndBell() {
        var terminal = Terminal(size: .init(columns: 80, rows: 24))
        let clock = ContinuousClock()
        let first = clock.now
        let second = first.advanced(by: .seconds(5))
        terminal.handleOSC133(ArraySlice("C".utf8), now: first)
        terminal.handleOSC133(ArraySlice("C".utf8), now: second)
        terminal.execute(0x07)
        terminal.execute(0x07)
        terminal.handleOSC133(
            ArraySlice("D;0".utf8),
            now: second.advanced(by: .seconds(2))
        )
        #expect(terminal.takeEvents() == [
            .bell,
            .bell,
            .commandCompleted(.init(exitStatus: 0, duration: .seconds(2))),
        ])
    }

    @Test("紧凑完成记录固定为十六字节")
    func compactRecordLayout() {
        #expect(MemoryLayout<CommandCompletionRecord>.stride == 16)
        #expect(MemoryLayout<Cell>.stride == 8)
        #expect(MemoryLayout<RowInfo>.stride == 2)
    }
}
```

- [ ] **Step 2: 运行测试确认 RED**

Run: `swift test --filter CommandStatusTests`

Expected: FAIL，报 `cannot find 'CommandCompletionRecord' in scope`、`Terminal has no member 'handleOSC133'` 与 `takeEvents` 缺失。

- [ ] **Step 3: 新增公开值类型和紧凑内部记录**

```swift
// Sources/TerminalCore/CommandStatus.swift
public struct CommandCompletion: Sendable, Equatable {
    public let exitStatus: UInt8?
    public let duration: Duration

    public init(exitStatus: UInt8?, duration: Duration) {
        self.exitStatus = exitStatus
        self.duration = duration
    }
}

public enum TerminalEvent: Sendable, Equatable {
    case commandCompleted(CommandCompletion)
    case bell
}

struct CommandCompletionRecord: Sendable, Equatable {
    private static let hasExitStatus: UInt8 = 1
    let lineID: UInt64
    let elapsedMilliseconds: UInt32
    let column: UInt16
    private let storedExitStatus: UInt8
    private let flags: UInt8

    init(lineID: UInt64, column: Int, completion: CommandCompletion) {
        self.lineID = lineID
        self.column = UInt16(clamping: column)
        elapsedMilliseconds = UInt32(clamping: completion.duration.wholeMilliseconds)
        storedExitStatus = completion.exitStatus ?? 0
        flags = completion.exitStatus == nil ? 0 : Self.hasExitStatus
    }

    var completion: CommandCompletion {
        CommandCompletion(
            exitStatus: flags & Self.hasExitStatus == 0 ? nil : storedExitStatus,
            duration: .milliseconds(Int64(elapsedMilliseconds))
        )
    }
}

extension Duration {
    fileprivate var wholeMilliseconds: Int64 {
        let components = self.components
        let seconds = components.seconds.multipliedReportingOverflow(by: 1_000)
        if seconds.overflow { return Int64.max }
        let milliseconds = components.attoseconds / 1_000_000_000_000_000
        let total = seconds.partialValue.addingReportingOverflow(milliseconds)
        return total.overflow ? Int64.max : max(0, total.partialValue)
    }
}
```

- [ ] **Step 4: 在 Terminal 接入计时、D 参数和 BEL**

给 `Terminal` 增加：

```swift
private var commandStartedAt: ContinuousClock.Instant?
private var commandCompletionRecords: ContiguousArray<CommandCompletionRecord> = []
private var commandCompletionStart = 0
private var pendingEvents: ContiguousArray<TerminalEvent> = []

public mutating func takeEvents() -> [TerminalEvent] {
    guard !pendingEvents.isEmpty else { return [] }
    defer { pendingEvents.removeAll(keepingCapacity: true) }
    return Array(pendingEvents)
}
```

将 `oscDispatch` 的 133 分支改为调用：

```swift
mutating func handleOSC133(
    _ payload: ArraySlice<UInt8>,
    now: ContinuousClock.Instant = ContinuousClock.now
) {
    guard let code = payload.first else { return }
    let mark: SemanticMark
    switch code {
    case UInt8(ascii: "A"):
        mark = .prompt
        commandStartedAt = nil
    case UInt8(ascii: "B"):
        mark = .command
        commandStartedAt = nil
    case UInt8(ascii: "C"):
        mark = .output
        commandStartedAt = now
    case UInt8(ascii: "D"):
        mark = .none
        if let startedAt = commandStartedAt {
            let completion = CommandCompletion(
                exitStatus: Self.osc133ExitStatus(payload),
                duration: startedAt.duration(to: now)
            )
            let column = pendingWrap ? grid.size.columns : grid.cursorCol
            let lineID = scrollback.totalAppendedLines + UInt64(grid.cursorRow)
            commandCompletionRecords.append(.init(
                lineID: lineID,
                column: column,
                completion: completion
            ))
            pendingEvents.append(.commandCompleted(completion))
        }
        commandStartedAt = nil
    default:
        return
    }
    currentSemantic = mark
    stampSemantic(mark, at: pendingWrap ? grid.size.columns : grid.cursorCol)
}

private static func osc133ExitStatus(_ payload: ArraySlice<UInt8>) -> UInt8? {
    guard payload.count >= 3,
          payload[payload.index(after: payload.startIndex)] == UInt8(ascii: ";") else {
        return nil
    }
    let digits = payload.dropFirst(2)
    guard !digits.isEmpty, digits.allSatisfy({ (48...57).contains($0) }),
          let value = UInt16(String(decoding: digits, as: UTF8.self)),
          value <= 255 else { return nil }
    return UInt8(value)
}
```

在 `execute` 中增加 `case 0x07: pendingEvents.append(.bell)`；RIS 重建前不需手工清理，因为 `self = Terminal(...)` 会清空所有状态。

- [ ] **Step 5: 运行 Core 测试确认 GREEN**

Run: `swift test --filter CommandStatusTests && swift test --filter TerminalTests && git diff --check`

Expected: 新测试及既有 OSC 133/C0 测试全部 PASS，stride 断言为 16/8/2。

- [ ] **Step 6: 提交生命周期交付点**

```bash
git add Sources/TerminalCore/CommandStatus.swift Sources/TerminalCore/Terminal.swift Tests/TerminalCoreTests/CommandStatusTests.swift
git commit -m "feat(core): 捕获命令完成与终端响铃" -m "只在 OSC 133 C/D 和 BEL 稀疏事件上记录状态，保留普通输出与 cell 热路径布局。\n\nRefs #70"
```

---

### Task 2: 命令块完成信息、reflow 与回收

**Files:**
- Modify: `Sources/TerminalCore/CommandBlocks.swift:13-98`
- Modify: `Sources/TerminalCore/Terminal.swift:141-399, 1018-1180`
- Modify: `Tests/TerminalCoreTests/CommandBlockTests.swift`
- Modify: `Tests/TerminalCoreTests/ReflowTests.swift`
- Modify: `Tests/TerminalCoreTests/CommandStatusTests.swift`

**Interfaces:**
- Consumes: Task 1 的 `CommandCompletion`、`CommandCompletionRecord`。
- Produces: `CommandBlock.completion: CommandCompletion?`、记录 reflow/ED/scrollback 回收不变式。

- [ ] **Step 1: 写失败测试覆盖查询、reflow 和回收**

在 `CommandBlockTests` 增加受控时钟用例：

```swift
@Test("命令块携带退出状态与耗时且 reflow 后不变")
func completionSurvivesReflow() throws {
    var (parser, terminal) = makeTerminal(columns: 20, rows: 5)
    feed("\u{1B}]133;A\u{07}$ \u{1B}]133;B\u{07}build\r\n", &parser, &terminal)
    let clock = ContinuousClock()
    let start = clock.now
    terminal.handleOSC133(ArraySlice("C".utf8), now: start)
    feed("long output", &parser, &terminal)
    terminal.handleOSC133(
        ArraySlice("D;3".utf8),
        now: start.advanced(by: .seconds(61))
    )

    let before = try #require(terminal.commandBlocks().first?.completion)
    terminal.resize(to: .init(columns: 6, rows: 8))
    let after = try #require(terminal.commandBlocks().first?.completion)
    #expect(before == .init(exitStatus: 3, duration: .seconds(61)))
    #expect(after == before)
}
```

在 `CommandStatusTests` 增加：

```swift
@Test("scrollback 淘汰与 ED 2/3 只回收对应完成记录")
func completionRecordLifecycle() {
    var (parser, terminal) = makeTerminal(columns: 20, rows: 2, scrollback: 2)
    for index in 0..<8 {
        feed(
            "\u{1B}]133;B\u{07}c\(index)\u{1B}]133;C\u{07}o"
                + "\u{1B}]133;D;0\u{07}\r\n",
            &parser,
            &terminal
        )
    }
    #expect(terminal.commandCompletionRecordCount <= terminal.totalLines)
    #expect(terminal.commandBlocks().count <= 3)

    terminal.csiDispatch(prefix: 0, params: [2][...], intermediates: [], final: UInt8(ascii: "J"))
    #expect(terminal.commandBlocks().allSatisfy { $0.commandRange.end.line < terminal.scrollback.count })
    terminal.csiDispatch(prefix: 0, params: [3][...], intermediates: [], final: UInt8(ascii: "J"))
    #expect(terminal.commandCompletionRecordCount == 0)
}
```

- [ ] **Step 2: 运行测试确认 RED**

Run: `swift test --filter CommandBlockTests.completionSurvivesReflow && swift test --filter CommandStatusTests.completionRecordLifecycle`

Expected: FAIL，`CommandBlock` 没有 `completion`，且记录尚未随 reflow/ED 映射回收。

- [ ] **Step 3: 扩展 CommandBlock 并在冷路径按位置配对**

```swift
public struct CommandBlock: Sendable, Equatable {
    public let commandRange: SemanticTextRange
    public let outputRange: SemanticTextRange?
    public let completion: CommandCompletion?

    public init(
        commandRange: SemanticTextRange,
        outputRange: SemanticTextRange?,
        completion: CommandCompletion? = nil
    ) {
        self.commandRange = commandRange
        self.outputRange = outputRange
        self.completion = completion
    }
}
```

`commandBlocks()` 先按绝对行建立完成记录冷路径索引：

```swift
var completionsByLine: [Int: [CommandCompletionRecord]] = [:]
for record in liveCommandCompletionRecords where record.lineID >= oldestLineID {
    let line = Int(record.lineID - oldestLineID)
    guard line < totalLines else { continue }
    completionsByLine[line, default: []].append(record)
}

func completion(at position: TextPosition) -> CommandCompletion? {
    completionsByLine[position.line]?
        .last(where: { Int($0.column) == position.column })?
        .completion
}
```

在 `.none` 完成 block 时传入 `completion(at: position)`；由 `.prompt` 推导的结束继续传 nil。

- [ ] **Step 4: 在 reflow、滚动和 ED 中同步记录**

在 `reflow` 中把旧记录按绝对行分组；收集语义转换时将 D 位置对应的记录携带为
`(offset, mark, order, completion)`，切块时用新 `rowID` 与相对列重建
`CommandCompletionRecord`。reflow 完成后只保留 `lineID >= firstRetainedID` 的记录。

增加统一回收 helper：

```swift
var liveCommandCompletionRecords: ArraySlice<CommandCompletionRecord> {
    commandCompletionRecords[commandCompletionStart...]
}

var commandCompletionRecordCount: Int {
    commandCompletionRecords.count - commandCompletionStart
}

private mutating func pruneCommandCompletions() {
    let oldestLineID = scrollback.totalAppendedLines - UInt64(scrollback.count)
    while commandCompletionStart < commandCompletionRecords.count,
          commandCompletionRecords[commandCompletionStart].lineID < oldestLineID {
        commandCompletionStart += 1
    }
    if commandCompletionStart >= 256,
       commandCompletionStart * 2 >= commandCompletionRecords.count {
        commandCompletionRecords.removeFirst(commandCompletionStart)
        commandCompletionStart = 0
    }
}
```

主屏整屏上滚时与 `pruneSemanticOverflow()` 同时调用；`ED 2` 过滤掉 `lineID >= gridBase`，
`ED 3` 只保留屏上记录并减去 `gridBase`，RIS 由整体重建清空。

- [ ] **Step 5: 运行完整 Core 回归**

Run: `swift test --filter CommandStatusTests && swift test --filter CommandBlockTests && swift test --filter ReflowTests && swift test --filter TerminalTests && git diff --check`

Expected: 新增状态、既有命令复制/同行转换/reflow 测试全部 PASS。

- [ ] **Step 6: 提交历史映射交付点**

```bash
git add Sources/TerminalCore/CommandBlocks.swift Sources/TerminalCore/Terminal.swift Tests/TerminalCoreTests/CommandBlockTests.swift Tests/TerminalCoreTests/ReflowTests.swift Tests/TerminalCoreTests/CommandStatusTests.swift
git commit -m "feat(core): 保留命令块执行结果" -m "用十六字节稀疏记录跟随语义坐标 reflow 与 scrollback 回收，让历史命令结果可查询而不扩张每行元数据。\n\nRefs #70"
```

---

### Task 3: Session 事件桥与标签聚合模型

**Files:**
- Create: `Sources/InkShell/TabAttention.swift`
- Modify: `Sources/InkShell/TerminalSession.swift:8-88`
- Modify: `Sources/InkShell/TerminalTab.swift:4-98`
- Modify: `Sources/InkShell/Project.swift:5-75`
- Create: `Tests/InkShellTests/TerminalSessionEventTests.swift`
- Create: `Tests/InkShellTests/TabAttentionTests.swift`

**Interfaces:**
- Consumes: `TerminalEvent` 与 `CommandCompletion`。
- Produces: `TerminalSession.onEvent`、internal `consumeOutput(_:)`、`TabAttention`、`TerminalTab.receive(_:markUnread:)`、`clearAttention()`、`Project.attention`。

- [ ] **Step 1: 写 Session 与聚合失败测试**

```swift
@Suite("终端会话事件")
@MainActor
struct TerminalSessionEventTests {
    @Test("同一输出 chunk 的完成与 Bell 按顺序上送且只取一次")
    func forwardsEventsOnce() {
        let session = TerminalSession(size: .init(columns: 80, rows: 24))
        var events: [TerminalEvent] = []
        session.onEvent = { events.append($0) }
        session.consumeOutput(Data("\u{07}\u{1B}]133;C\u{07}\u{1B}]133;D;2\u{07}".utf8))
        #expect(events.count == 2)
        #expect(events.first == .bell)
        #expect(events.last?.completion?.exitStatus == 2)
        session.detach()
        session.consumeOutput(Data("\u{07}".utf8))
        #expect(events.count == 2)
    }
}

@Suite("标签未读状态")
@MainActor
struct TabAttentionTests {
    @Test("失败高于 Bell 和成功且同级保留最新")
    func priorityAggregation() {
        let tab = TerminalTab(initialPane: makePane())
        let success = CommandCompletion(exitStatus: 0, duration: .seconds(12))
        let failure = CommandCompletion(exitStatus: 4, duration: .seconds(3))
        tab.receive(.commandCompleted(success), markUnread: true)
        tab.receive(.bell, markUnread: true)
        tab.receive(.commandCompleted(failure), markUnread: true)
        tab.receive(.commandCompleted(success), markUnread: true)
        #expect(tab.attention == .failed(failure))
        tab.clearAttention()
        #expect(tab.attention == nil)
    }

    @Test("前台可见事件不制造未读且项目汇总最高优先级")
    func foregroundAndProjectAggregation() {
        let project = Project(directory: FileManager.default.homeDirectoryForCurrentUser)
        let first = TerminalTab(initialPane: makePane())
        let second = TerminalTab(initialPane: makePane())
        project.tabs = [first, second]
        first.receive(.bell, markUnread: false)
        second.receive(.bell, markUnread: true)
        #expect(first.attention == nil)
        #expect(project.attention == .bell)
    }
}
```

- [ ] **Step 2: 运行测试确认 RED**

Run: `swift test --filter TerminalSessionEventTests && swift test --filter TabAttentionTests`

Expected: FAIL，`onEvent`、`consumeOutput`、`TabAttention` 与聚合接口缺失。

- [ ] **Step 3: 抽取 Session 输出消费并上送事件**

```swift
public var onEvent: ((TerminalEvent) -> Void)?

func consumeOutput(_ data: Data) {
    data.withUnsafeBytes { raw in
        parser.feed(raw, handler: &terminal)
    }
    for event in terminal.takeEvents() { onEvent?(event) }
    let responses = terminal.takeResponses()
    if !responses.isEmpty { pty.write(Data(responses)) }
    onUpdate?()
}
```

PTY `onOutput` 只调用 `self?.consumeOutput(data)`；`detach()` 同时置空 `onEvent`。

- [ ] **Step 4: 实现 attention 值类型、格式化与聚合**

```swift
enum TabAttention: Equatable {
    case completed(CommandCompletion)
    case bell
    case failed(CommandCompletion)

    init(event: TerminalEvent) {
        switch event {
        case .bell: self = .bell
        case let .commandCompleted(completion):
            self = completion.exitStatus.map { $0 == 0 }
                == false ? .failed(completion) : .completed(completion)
        }
    }

    var priority: Int {
        switch self { case .completed: 0; case .bell: 1; case .failed: 2 }
    }

    func merging(_ newer: TabAttention) -> TabAttention {
        newer.priority >= priority ? newer : self
    }
}

enum CommandStatusFormatter {
    static func duration(_ duration: Duration) -> String {
        let seconds = max(0, duration.components.seconds)
        if seconds < 1 { return "<1 秒" }
        if seconds < 60 { return "\(seconds) 秒" }
        return "\(seconds / 60) 分 \(String(format: "%02d", seconds % 60)) 秒"
    }
}
```

`TerminalTab` 增加 `private(set) var attention: TabAttention?`；`receive` 只在
`markUnread` 时合并，`clearAttention` 清空。`Project.attention` 用 tabs 的 attention 按
priority 取最大值。

- [ ] **Step 5: 运行 Shell 模型回归并提交**

Run: `swift test --filter TerminalSessionEventTests && swift test --filter TabAttentionTests && swift test --filter TerminalTabTests && git diff --check`

Expected: 全部 PASS。

```bash
git add Sources/InkShell/TabAttention.swift Sources/InkShell/TerminalSession.swift Sources/InkShell/TerminalTab.swift Sources/InkShell/Project.swift Tests/InkShellTests/TerminalSessionEventTests.swift Tests/InkShellTests/TabAttentionTests.swift
git commit -m "feat(shell): 聚合后台标签状态" -m "按 pane 事件归并成功、失败与 Bell，并保持状态只存在于当前运行态。\n\nRefs #70"
```

---

### Task 4: 安静通知策略与 UserNotifications 协调器

**Files:**
- Create: `Sources/InkShell/CommandNotificationCoordinator.swift`
- Create: `Tests/InkShellTests/CommandNotificationCoordinatorTests.swift`

**Interfaces:**
- Consumes: `CommandCompletion`、`CommandStatusFormatter`。
- Produces: `CommandNotificationRequest`、`CommandNotificationPolicy.shouldNotify(isApplicationActive:completion:)`、`CommandNotificationCoordinating.submit(_:)`。
- Produces internal: `LocalNotificationClient`、`NotificationAuthorizationState`，用于无系统弹窗测试授权路径。

- [ ] **Step 1: 写失败测试覆盖阈值、脱敏与授权降级**

```swift
@Suite("命令系统通知")
@MainActor
struct CommandNotificationCoordinatorTests {
    @Test("只允许失焦后的十秒完整命令")
    func policyThreshold() {
        let short = CommandCompletion(exitStatus: 1, duration: .milliseconds(9_999))
        let long = CommandCompletion(exitStatus: 0, duration: .seconds(10))
        #expect(!CommandNotificationPolicy.shouldNotify(
            isApplicationActive: false, completion: short
        ))
        #expect(!CommandNotificationPolicy.shouldNotify(
            isApplicationActive: true, completion: long
        ))
        #expect(CommandNotificationPolicy.shouldNotify(
            isApplicationActive: false, completion: long
        ))
    }

    @Test("首次授权后投递同一条脱敏通知")
    func requestsThenDelivers() async throws {
        let client = NotificationClientFake(
            authorization: .notDetermined,
            requestResult: true
        )
        let coordinator = CommandNotificationCoordinator(client: client)
        coordinator.submit(.init(
            tabTitle: "构建",
            completion: .init(exitStatus: 2, duration: .seconds(12))
        ))
        try await waitUntil { client.delivered.count == 1 }
        let content = try #require(client.delivered.first)
        #expect(content.title == "命令失败")
        #expect(content.body.contains("构建"))
        #expect(content.body.contains("退出状态 2"))
        #expect(!content.body.contains("rm "))
        #expect(client.requestCount == 1)
    }

    @Test("拒绝与投递错误静默跳过")
    func deniedAndDeliveryFailure() async throws {
        let denied = NotificationClientFake(authorization: .denied)
        CommandNotificationCoordinator(client: denied).submit(sampleRequest)
        try await Task.sleep(for: .milliseconds(20))
        #expect(denied.delivered.isEmpty)

        let failing = NotificationClientFake(authorization: .authorized, deliveryFails: true)
        CommandNotificationCoordinator(client: failing).submit(sampleRequest)
        try await Task.sleep(for: .milliseconds(20))
        #expect(failing.deliveryAttempts == 1)
    }
}
```

- [ ] **Step 2: 运行测试确认 RED**

Run: `swift test --filter CommandNotificationCoordinatorTests`

Expected: FAIL，通知策略、请求、协调器与 client 抽象不存在。

- [ ] **Step 3: 实现纯策略与高层请求**

```swift
struct CommandNotificationRequest: Equatable {
    let tabTitle: String
    let completion: CommandCompletion
}

enum CommandNotificationPolicy {
    static let minimumDuration: Duration = .seconds(10)
    static func shouldNotify(
        isApplicationActive: Bool,
        completion: CommandCompletion
    ) -> Bool {
        !isApplicationActive && completion.duration >= minimumDuration
    }
}

@MainActor
protocol CommandNotificationCoordinating: AnyObject {
    func submit(_ request: CommandNotificationRequest)
}
```

- [ ] **Step 4: 用 async client 封装授权和投递**

```swift
enum NotificationAuthorizationState { case notDetermined, authorized, denied }

struct LocalNotificationContent: Equatable {
    let title: String
    let body: String
}

@MainActor
protocol LocalNotificationClient: AnyObject {
    func authorizationState() async -> NotificationAuthorizationState
    func requestAuthorization() async throws -> Bool
    func deliver(_ content: LocalNotificationContent) async throws
}

@MainActor
final class CommandNotificationCoordinator: CommandNotificationCoordinating {
    private let client: LocalNotificationClient
    init(client: LocalNotificationClient = UserNotificationClient()) { self.client = client }

    func submit(_ request: CommandNotificationRequest) {
        Task { @MainActor [client] in
            let state = await client.authorizationState()
            let allowed: Bool
            switch state {
            case .authorized: allowed = true
            case .denied: allowed = false
            case .notDetermined: allowed = (try? await client.requestAuthorization()) == true
            }
            guard allowed else { return }
            try? await client.deliver(Self.content(for: request))
        }
    }
}
```

`UserNotificationClient` 使用 `UNUserNotificationCenter.current()` 的 async
`notificationSettings()`、`requestAuthorization(options: [.alert])` 和 `add`；创建
`UNMutableNotificationContent` 时不设置 sound/badge，request trigger 为 nil。

- [ ] **Step 5: 运行通知测试并提交**

Run: `swift test --filter CommandNotificationCoordinatorTests && swift build && git diff --check`

Expected: 授权/拒绝/错误测试 PASS，InkShell 在 macOS 14 成功链接 UserNotifications。

```bash
git add Sources/InkShell/CommandNotificationCoordinator.swift Tests/InkShellTests/CommandNotificationCoordinatorTests.swift
git commit -m "feat(shell): 限制长任务系统通知" -m "只在应用失焦且命令满十秒时按需申请安静通知权限，拒绝和投递错误不干扰会话。\n\nRefs #70"
```

---

### Task 5: 标签、溢出菜单与侧边栏状态 UI

**Files:**
- Modify: `Sources/InkShell/TabAttention.swift`
- Modify: `Sources/InkShell/TabBarView.swift:7-225, 393-500`
- Modify: `Sources/InkShell/SidebarViewController.swift:27-205, 247-390`
- Modify: `Tests/InkShellTests/TabBarViewTests.swift`
- Modify: `Tests/InkShellTests/ProjectSidebarTests.swift`

**Interfaces:**
- Consumes: `TabAttention`、`CommandStatusFormatter`。
- Produces: `AttentionPresentation(symbolName:accessibilityLabel:toolTip:tintColor:)`、`TabBarView.Tab.attention`、`SidebarViewController.Row.attention`。

- [ ] **Step 1: 写失败 UI 结构测试**

```swift
@Test("失败状态使用独立图形且悬停关闭按钮不移动布局")
func failureAttentionIsNotColorOnly() throws {
    let failure = TabAttention.failed(.init(exitStatus: 2, duration: .seconds(12)))
    let tabBar = makeTabBar(tabs: [
        .init(title: "构建", shortcut: "⌘1", active: false, attention: failure),
    ])
    let item = try #require(visibleTabItems(in: tabBar).first)
    let image = try #require(descendants(of: NSImageView.self, in: item).first)
    let close = try #require(descendants(of: NSButton.self, in: item).first)
    let before = close.frame
    #expect(image.accessibilityLabel() == "命令失败，退出状态 2，12 秒")
    #expect(image.image?.name() == NSImage.Name("exclamationmark.circle.fill"))
    item.mouseEntered(with: mouseEvent())
    #expect(close.frame == before)
    #expect(!close.isHidden)
}

@Test("溢出菜单和项目侧边栏同步未读图形")
func overflowAndProjectAttention() throws {
    let tabBar = makeTabBar(width: 400, tabs: eightTabsWithFailureAtZero)
    let item = try #require(tabBar.overflowMenu?.items.first { $0.tag == 0 })
    #expect(item.image?.accessibilityDescription == "命令失败")

    let sidebar = SidebarViewController()
    sidebar.reload(rows: [projectRow(attention: .bell)])
    sidebar.view.layoutSubtreeIfNeeded()
    #expect(descendants(of: NSImageView.self, in: sidebar.view).contains {
        $0.accessibilityLabel() == "终端响铃"
    })
}
```

- [ ] **Step 2: 运行测试确认 RED**

Run: `swift test --filter TabBarViewTests.failureAttentionIsNotColorOnly && swift test --filter ProjectSidebarLayoutTests.overflowAndProjectAttention`

Expected: FAIL，Tab/Row 没有 attention，状态图形不存在。

- [ ] **Step 3: 实现统一 presentation**

```swift
@MainActor
struct AttentionPresentation {
    let symbolName: String
    let accessibilityLabel: String
    let toolTip: String
    let tintColor: NSColor
}

@MainActor
extension TabAttention {
    var presentation: AttentionPresentation {
        switch self {
        case let .failed(completion):
            let status = completion.exitStatus.map { "，退出状态 \($0)" } ?? ""
            let duration = CommandStatusFormatter.duration(completion.duration)
            return .init(
                symbolName: "exclamationmark.circle.fill",
                accessibilityLabel: "命令失败\(status)，\(duration)",
                toolTip: "命令失败\(status) · \(duration)",
                tintColor: InkDesignTokens.Color.danger
            )
        case .bell:
            return .init(
                symbolName: "bell.fill",
                accessibilityLabel: "终端响铃",
                toolTip: "终端响铃",
                tintColor: InkDesignTokens.Color.warning
            )
        case let .completed(completion):
            let duration = CommandStatusFormatter.duration(completion.duration)
            return .init(
                symbolName: "circle.fill",
                accessibilityLabel: "命令已完成，\(duration)",
                toolTip: "命令已完成 · \(duration)",
                tintColor: InkDesignTokens.Color.success
            )
        }
    }
}
```

- [ ] **Step 4: 在标签与侧边栏复用图形**

`TabBarView.Tab` 与 `SidebarViewController.Row` 的 initializer 给 `attention` 默认 nil，避免
无关调用点一次性破坏。`TabItemView` 在关闭按钮同一约束列放 `NSImageView`；无悬停时显示
attention，悬停时隐藏 image、显示 close，frame 不变。溢出 `NSMenuItem.image` 使用同一
symbol/tint/accessibility。`ProjectRowView` 展开态在 status 左侧、compact 态在文件夹右下角
显示 attention，且保留 Finder label indicator。

- [ ] **Step 5: 运行 UI 回归并提交**

Run: `swift test --filter TabBarViewTests && swift test --filter ProjectSidebarTests && swift test --filter ProjectSidebarLayoutTests && git diff --check`

Expected: 状态图形、辅助信息、溢出与既有宽度/悬停/项目标签测试全部 PASS。

```bash
git add Sources/InkShell/TabAttention.swift Sources/InkShell/TabBarView.swift Sources/InkShell/SidebarViewController.swift Tests/InkShellTests/TabBarViewTests.swift Tests/InkShellTests/ProjectSidebarTests.swift
git commit -m "feat(shell): 显示后台命令状态" -m "在标签、溢出菜单和项目侧边栏复用可访问图形，失败状态不再只依赖颜色。\n\nRefs #70"
```

---

### Task 6: 窗口事件归属、清除与通知接线

**Files:**
- Modify: `Sources/InkShell/MainWindowController.swift:44-120, 305-365, 647-773, 932-990, 1061-1145`
- Modify: `Sources/InkShell/AppDelegate.swift:8-35`
- Create: `Tests/InkShellTests/CommandStatusWindowTests.swift`

**Interfaces:**
- Consumes: Session `onEvent`、Tab/Project attention、notification policy/coordinator、UI attention。
- Produces: internal `applicationDidBecomeActive()`、事件归属与精确清除行为。

- [ ] **Step 1: 写窗口级失败测试**

使用隔离 UserDefaults、两个项目/三个标签、未启动 pane 和 fake notifier 的 fixture：

```swift
@Suite("主窗口命令状态", .serialized)
@MainActor
struct CommandStatusWindowTests {
    @Test("后台标签与非活动项目聚合状态，选择只清除可见标签")
    func aggregatesAndClearsVisibleTab() throws {
        let fixture = try Fixture(applicationActive: true)
        defer { fixture.cleanUp() }
        let controller = fixture.controller
        let background = try #require(controller.projects[0].tabs[safe: 1]?.activePane)
        background.session.onEvent?(.bell)
        #expect(controller.projects[0].tabs[1].attention == .bell)
        #expect(controller.projects[0].attention == .bell)

        controller.selectTabForTesting(projectIndex: 0, tabIndex: 1)
        #expect(controller.projects[0].tabs[1].attention == nil)
        #expect(controller.projects[0].tabs[0].attention == nil)
    }

    @Test("失焦活动标签标记状态且重新激活只清除当前标签")
    func applicationActivationClearsCurrentOnly() throws {
        let fixture = try Fixture(applicationActive: false)
        defer { fixture.cleanUp() }
        let current = try #require(fixture.controller.activeProjectForTesting?.activeTab?.activePane)
        current.session.onEvent?(.commandCompleted(.init(
            exitStatus: 0, duration: .seconds(3)
        )))
        #expect(fixture.controller.activeProjectForTesting?.activeTab?.attention != nil)
        fixture.applicationState.isActive = true
        fixture.controller.applicationDidBecomeActive()
        #expect(fixture.controller.activeProjectForTesting?.activeTab?.attention == nil)
    }

    @Test("只为失焦十秒命令提交脱敏通知")
    func notificationGate() throws {
        let fixture = try Fixture(applicationActive: false)
        defer { fixture.cleanUp() }
        let pane = try #require(fixture.controller.activeProjectForTesting?.activeTab?.activePane)
        pane.session.onEvent?(.bell)
        pane.session.onEvent?(.commandCompleted(.init(
            exitStatus: 1, duration: .milliseconds(9_999)
        )))
        pane.session.onEvent?(.commandCompleted(.init(
            exitStatus: 1, duration: .seconds(10)
        )))
        #expect(fixture.notifier.requests.count == 1)
        #expect(fixture.notifier.requests[0].completion.exitStatus == 1)
        #expect(!fixture.notifier.requests[0].tabTitle.contains("/"))
    }
}
```

- [ ] **Step 2: 运行测试确认 RED**

Run: `swift test --filter CommandStatusWindowTests`

Expected: FAIL，窗口尚未注入应用活跃状态/notifier，也没有事件归属与激活清除接口。

- [ ] **Step 3: 注入依赖并接线 Session 事件**

给窗口 initializer 增加：

```swift
notificationCoordinator: CommandNotificationCoordinating = CommandNotificationCoordinator(),
isApplicationActive: @escaping @MainActor () -> Bool = { NSApp.isActive }
```

`configureCallbacks(for:)` 增加：

```swift
session.onEvent = { [weak self, weak pane] event in
    guard let self, let pane else { return }
    self.handleTerminalEvent(event, paneID: pane.id)
}
```

事件 handler 查找 pane 所属 project/tab，计算
`isVisible = projectIndex == activeProjectIndex && tabIndex == project.activeTabIndex && !isShowingSettings`；
只有 `isVisible && isApplicationActive()` 时不标未读。命令完成另经 policy 判断后向 coordinator
提交 `tabTitle(tab, project:)` 与 completion。Bell 永不提交通知。最后调用
`refreshChromeIfNeeded()`。

- [ ] **Step 4: 精确清除并把状态传给 chrome**

- `selectTab(at:)` 在选中后清除该 tab。
- `selectProject(at:)` attach 当前 tab 后清除实际显示的 active tab。
- `applicationDidBecomeActive()` 只清除当前显示 tab。
- `chromeSignature()` 纳入 tab/project attention，确保事件变化触发重建。
- `refreshChrome()` 给 `TabBarView.Tab` 与 `SidebarViewController.Row` 传 attention。
- AppDelegate 实现 `applicationDidBecomeActive` 并转发给 main window controller。

- [ ] **Step 5: 运行窗口与全套 Shell 回归**

Run: `swift test --filter CommandStatusWindowTests && swift test --filter WorkspaceRestoreWindowTests && swift test --filter TerminalSplitCommandTests && swift test --filter SettingsWindowTests && swift test --filter TabBarViewTests && swift test --filter ProjectSidebarTests && git diff --check`

Expected: 命令状态用例和窗口恢复/分屏/设置/标签/侧栏回归全部 PASS。

- [ ] **Step 6: 提交窗口接线交付点**

```bash
git add Sources/InkShell/MainWindowController.swift Sources/InkShell/AppDelegate.swift Tests/InkShellTests/CommandStatusWindowTests.swift
git commit -m "feat(shell): 接通命令状态与安静通知" -m "按 pane 归属更新后台标签和项目，只清除用户已查看状态，并将失焦长任务交给脱敏通知协调器。\n\nRefs #70"
```

---

### Task 7: 性能证据、完整审查与交付

**Files:**
- Modify: `Sources/ink-bench/main.swift`
- Modify: `Tests/TerminalCoreTests/CommandStatusTests.swift`
- Modify: `docs/perf.md`

**Interfaces:**
- Consumes: 完整功能。
- Produces: `command-plain` / `command-status` Release profile、10 万行内存/reflow 数据、Time Profiler trace 与最终门禁。

- [ ] **Step 1: 增加 Release 高密度 profile 与规模测试**

给 `ink-bench` 增加两个 CLI profile，各执行 100 万条等量可见行；status 版本每行包裹
`B/C/D;0`，plain 版本用空格填充到相同字节数，打印字节、耗时、吞吐、footprint、
scrollback count。`CommandStatusTests` 增加 10 万条完成记录后断言 live count 不超过
scrollback + grid 行数，并打印记录数、stride、reflow 前后耗时，不设机器阈值。

- [ ] **Step 2: 运行 Release 测量**

Run:

```bash
swift test -c release --filter CommandStatusTests 2>&1 | tee /tmp/ink-issue70-command-status-tests.txt
swift run -c release ink-bench command-plain 2>&1 | tee /tmp/ink-issue70-command-plain.txt
swift run -c release ink-bench command-status 2>&1 | tee /tmp/ink-issue70-command-status.txt
```

Expected: 三条命令 PASS；记录 stride 16、Cell 8、RowInfo 2，10 万历史记录受容量约束。

- [ ] **Step 3: 录制 Time Profiler**

先定位 Release 可执行文件：`swift build -c release --product ink-bench --show-bin-path`。然后：

```bash
xcrun xctrace record --template "Time Profiler" --time-limit 10s --output /tmp/ink-issue70-command-plain.trace --launch -- .build/release/ink-bench command-plain
xcrun xctrace record --template "Time Profiler" --time-limit 10s --output /tmp/ink-issue70-command-status.trace --launch -- .build/release/ink-bench command-status
```

Expected: 两个 trace 成功完成；普通 profile 无新增 completion helper 栈，status profile 的记录
追加/回收只在 OSC 133 事件上出现，没有每字符对象创建或渲染栈。

- [ ] **Step 4: 记录文档并完成全量门禁**

在 `docs/perf.md` 写入硬件、系统、profile 字节数、吞吐、footprint、记录 stride、10 万行
reflow 和 trace 路径；明确系统通知不含命令文本，OSC 9/777 仍未实现。

Run:

```bash
swift test
swift build
git diff --check
git status --short
```

Expected: 基线 363 个测试加 #70 新测试全部 PASS；build 无 warning/error；status 只含 #70 文件。

- [ ] **Step 5: 提交验收记录**

```bash
git add Sources/ink-bench/main.swift Tests/TerminalCoreTests/CommandStatusTests.swift docs/perf.md
git commit -m "perf(core): 记录命令状态成本" -m "用高密度 OSC 133 与等字节普通输出对比稀疏完成记录的吞吐、内存和 reflow 成本。\n\nRefs #70"
```

- [ ] **Step 6: 评审、PR、合并与 main 复验**

执行 `superpowers:requesting-code-review`；由于当前规则禁止主动派 subagent，按同一模板在本地
逐项对照 Issue #70、设计与本计划，修复所有 Critical/Important 后重新运行全量门禁。随后：

1. 推送 `agent/issue-70-command-status-notifications`。
2. 创建标题 `feat(shell): 显示命令状态并发送安静通知` 的 PR。
3. PR 描述包含功能、测试、Release/Time Profiler 数字、隐私与通知边界、文档、无发布，且
   只有一个 `Closes #70`。
4. 检查通过且用户已授权持续合并后，管理员 squash 合入 main。
5. 确认 Issue #70 自动关闭，删除远端分支。
6. 在 main 运行 `swift test && swift build`；成功后移除 `.worktrees/issue-70` 和本地分支。
7. 重读 `docs/roadmap.md`，按相同 issue-first 节奏进入下一项，不创建 tag。
