# OSC 52 有界只写剪贴板 Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** 支持默认开启、可关闭、最多解码 1 MiB 且永不读取本地剪贴板的 OSC 52 文本写入。

**Architecture:** Parser 只把 OSC 变成 start/put/end/cancel 词法生命周期，TerminalCore 用独立状态机流式识别 OSC 52、严格增量解码 Base64，并把最后一次合法写入作为 `TerminalEffect` 上送。TerminalSession 立即消费效果，MainWindowController 根据当前配置决定是否交给可注入的 AppKit pasteboard writer；该路径不复用未读/通知事件。

**Tech Stack:** Swift 6、Swift Testing、Foundation、AppKit、SwiftPM，最低 macOS 14.0；不新增第三方依赖。

## Global Constraints

- `TerminalCore` 不得引入 AppKit 或 Metal。
- 只允许终端程序写入剪贴板；`Pd=?` 永远不读取、不返回 PTY response。
- 解码后硬上限为 1,048,576 字节；编码文本不得完整驻留。
- 同一次 feed 只保留最后一个待写效果，避免连续序列线性累积内存。
- OSC 52 默认开启并可即时关闭；设置只控制 Shell 副作用，不改变 Core 解析。
- 不给 cell、行、scrollback、grid 或每帧渲染增加状态或分配。
- 禁止记录剪贴板载荷、建立历史、发送通知或点亮标签未读状态。
- 注释和文档用中文，代码标识符用英文；提交信息用中文并关联 `#76`。

---

## 文件结构

- Create `Sources/TerminalCore/OSC52Clipboard.swift`：通用 OSC 累积器、OSC 52 头状态机与严格 Base64 解码器。
- Modify `Sources/TerminalCore/Parser.swift`：用 OSC 生命周期调用替代 Parser 内的 4 KiB 缓冲。
- Modify `Sources/TerminalCore/Terminal.swift`：持有瞬时 OSC 状态与单个 `TerminalEffect`，提供 lifecycle / take API，并从搜索快照剥离。
- Create `Tests/TerminalCoreTests/OSC52ClipboardTests.swift`：端到端解析、边界、取消、内存上界与既有 OSC 回归。
- Modify `Sources/InkShell/TerminalSession.swift`：立即上送并清理 Core 效果。
- Modify `Tests/InkShellTests/TerminalSessionEventTests.swift`：验证效果顺序、合并与 detach。
- Modify `Sources/InkConfig/InkConfig.swift`：本地 `clipboard.osc52_write` 配置。
- Modify `Sources/InkConfig/ConfigSyncSnapshot.swift`：schema 1 可缺省 wire 字段迁移。
- Modify `Tests/InkConfigTests/InkConfigTests.swift`、`Tests/InkConfigTests/ConfigSyncSnapshotTests.swift`：本地与云端往返。
- Modify `Sources/InkShell/SettingsViewController.swift`：交互区安全开关。
- Create `Tests/InkShellTests/OSC52SettingsTests.swift`：设置 UI 行为。
- Create `Sources/InkShell/OSC52PasteboardWriter.swift`：唯一 AppKit 副作用边界。
- Modify `Sources/InkShell/MainWindowController.swift`：为所有 pane 接线并执行当前策略。
- Create `Tests/InkShellTests/OSC52WindowTests.swift`：前后台 pane、关闭策略、无未读副作用。
- Modify `docs/roadmap.md`：把 OSC 52 条目明确为有界、仅写、默认开启且可关闭。
- Modify `docs/perf.md`：记录普通输出吞吐与大载荷内存验收数据。

---

### Task 1: 严格增量 Base64 解码器

**Files:**
- Create: `Sources/TerminalCore/OSC52Clipboard.swift`
- Create: `Tests/TerminalCoreTests/OSC52ClipboardTests.swift`

**Interfaces:**
- Consumes: 单个 OSC 52 payload 字节与 `finish()` 终止动作。
- Produces: `OSC52Base64Decoder.put(_ byte: UInt8)`、`finish() -> String?`、`discard()`；`static let maximumDecodedBytes = 1_048_576`。

- [ ] **Step 1: 写严格解码的失败测试**

在新测试文件先加入直接解码测试，辅助方法必须按字节调用，避免测试掩盖分片问题：

```swift
import Testing
@testable import TerminalCore

@Suite("OSC 52 剪贴板")
struct OSC52ClipboardTests {
    private func decode(_ encoded: String) -> String? {
        var decoder = OSC52Base64Decoder()
        for byte in encoded.utf8 { decoder.put(byte) }
        return decoder.finish()
    }

    @Test("严格 Base64 接受 UTF-8 与空载荷")
    func strictBase64AcceptsTextAndEmpty() {
        #expect(decode("") == "")
        #expect(decode("5L2g5aW9") == "你好")
        #expect(decode("Zg==") == "f")
        #expect(decode("Zm8=") == "fo")
    }

    @Test("严格 Base64 拒绝非规范输入和非法 UTF-8")
    func strictBase64RejectsInvalidInput() {
        for value in ["Zg", "Zg=", "Zh==", "Zm9=", "Z g==", "Zg==x", "_w==", "/w=="] {
            #expect(decode(value) == nil)
        }
    }

    @Test("解码结果恰好一 MiB 可用，下一字节触发丢弃")
    func decodedLimitIsExact() {
        let exact = String(repeating: "QUFB", count: OSC52Base64Decoder.maximumDecodedBytes / 3)
            + "QQ=="
        #expect(decode(exact)?.utf8.count == OSC52Base64Decoder.maximumDecodedBytes)
        let overflow = String(
            repeating: "QUFB",
            count: OSC52Base64Decoder.maximumDecodedBytes / 3
        ) + "QUE="
        #expect(decode(overflow) == nil)
    }
}
```

- [ ] **Step 2: 运行测试并确认因类型不存在而失败**

Run: `swift test --no-parallel --filter OSC52ClipboardTests`

Expected: FAIL，错误包含 `cannot find 'OSC52Base64Decoder' in scope`。

- [ ] **Step 3: 实现无编码文本副本的解码器**

在新 Core 文件实现以下状态。`put` 在 `invalid` 后保持常数工作；`finish` 用严格 UTF-8 初始化并通过替换 `decoded` 释放 capacity：

```swift
struct OSC52Base64Decoder: Sendable {
    static let maximumDecodedBytes = 1_048_576

    private var quartet: (UInt8, UInt8, UInt8, UInt8) = (0, 0, 0, 0)
    private var quartetCount = 0
    private var sawPadding = false
    private(set) var invalid = false
    private var decoded: ContiguousArray<UInt8> = []

    mutating func put(_ byte: UInt8) {
        guard !invalid, !sawPadding else { invalid = true; discard(); return }
        let slot = quartetCount
        let value: UInt8
        if byte == UInt8(ascii: "=") {
            guard slot >= 2 else { invalid = true; discard(); return }
            value = 64
        } else if let sextet = Self.sextet(byte) {
            value = sextet
        } else {
            invalid = true
            discard()
            return
        }
        withUnsafeMutableBytes(of: &quartet) { $0[slot] = value }
        quartetCount += 1
        if quartetCount == 4 { flushQuartet() }
    }

    mutating func finish() -> String? {
        guard !invalid, quartetCount == 0 else { discard(); return nil }
        let bytes = decoded
        decoded = []
        return String(bytes: bytes, encoding: .utf8)
    }

    mutating func discard() {
        decoded = []
        quartetCount = 0
    }

    private mutating func flushQuartet() {
        let q = withUnsafeBytes(of: quartet) { Array($0) }
        guard q[0] < 64, q[1] < 64,
              !(q[2] == 64 && q[3] != 64),
              q[2] == 64 ? (q[1] & 0x0F) == 0 : true,
              q[3] == 64 ? (q[2] & 0x03) == 0 : true else {
            invalid = true; discard(); return
        }
        let outputCount = q[2] == 64 ? 1 : (q[3] == 64 ? 2 : 3)
        guard decoded.count <= Self.maximumDecodedBytes - outputCount else {
            invalid = true; discard(); return
        }
        decoded.append((q[0] << 2) | (q[1] >> 4))
        if outputCount > 1 { decoded.append((q[1] << 4) | (q[2] >> 2)) }
        if outputCount > 2 { decoded.append((q[2] << 6) | q[3]) }
        sawPadding = outputCount < 3
        quartetCount = 0
    }

    private static func sextet(_ byte: UInt8) -> UInt8? {
        switch byte {
        case 65...90: byte - 65
        case 97...122: byte - 97 + 26
        case 48...57: byte - 48 + 52
        case 43: 62
        case 47: 63
        default: nil
        }
    }
}
```

实现时不得使用 `Data(base64Encoded:)`，因为它要求保留完整编码输入。若 Swift 对三元组的 raw-byte 写入产生诊断，改为四个命名 `UInt8` 字段与 `switch slot`，但保持相同 API 与规范检查。

- [ ] **Step 4: 运行定向测试**

Run: `swift test --no-parallel --filter OSC52ClipboardTests`

Expected: PASS，3 个 `@Test` 全部通过。

- [ ] **Step 5: 提交解码器**

```bash
git add Sources/TerminalCore/OSC52Clipboard.swift Tests/TerminalCoreTests/OSC52ClipboardTests.swift
git commit -m "feat(core): 有界解码 OSC 52 载荷" -m "流式校验标准 Base64 与 UTF-8，并在一 MiB 上限处立即释放异常输入，避免编码文本和解码文本同时常驻。\n\nRefs #76"
```

---

### Task 2: Parser 生命周期、OSC 累积器与 TerminalEffect

**Files:**
- Modify: `Sources/TerminalCore/OSC52Clipboard.swift`
- Modify: `Sources/TerminalCore/Parser.swift`
- Modify: `Sources/TerminalCore/Terminal.swift`
- Modify: `Tests/TerminalCoreTests/OSC52ClipboardTests.swift`
- Modify: `Tests/TerminalCoreTests/TerminalTests.swift`

**Interfaces:**
- Consumes: Task 1 的 `OSC52Base64Decoder`。
- Produces: `TerminalEffect.clipboardWrite(String)`、`Terminal.oscStart()`、`oscPut(_:)`、`oscEnd()`、`oscCancel()`、`takeEffects() -> [TerminalEffect]`。

- [ ] **Step 1: 写端到端失败测试**

向 `OSC52ClipboardTests` 加入辅助函数与以下覆盖：

```swift
private func sequence(target: String = "c", payload: String, terminator: String = "\u{07}") -> String {
    "\u{1B}]52;\(target);\(payload)\(terminator)"
}

@Test("BEL、ST、分片与 UTF-8 都产生写入效果")
func parsesTerminatorsAndSplitReads() {
    var (parser, terminal) = makeTerminal()
    let bytes = Array(sequence(payload: "5L2g5aW9").utf8)
    feed(bytes.prefix(7), &parser, &terminal)
    #expect(terminal.takeEffects().isEmpty)
    feed(bytes.dropFirst(7), &parser, &terminal)
    #expect(terminal.takeEffects() == [.clipboardWrite("你好")])
    feed(sequence(target: "ps", payload: "Zg==", terminator: "\u{1B}\\"), &parser, &terminal)
    #expect(terminal.takeEffects() == [.clipboardWrite("f")])
}

@Test("空目标可清空，仅不支持目标和查询无副作用")
func targetAndQueryPolicy() {
    var (parser, terminal) = makeTerminal()
    feed(sequence(target: "", payload: ""), &parser, &terminal)
    #expect(terminal.takeEffects() == [.clipboardWrite("")])
    for target in ["q", "0", "17", "x", String(repeating: "c", count: 17)] {
        feed(sequence(target: target, payload: "Zg=="), &parser, &terminal)
        #expect(terminal.takeEffects().isEmpty)
    }
    feed(sequence(payload: "?"), &parser, &terminal)
    #expect(terminal.takeEffects().isEmpty)
    #expect(terminal.takeResponses().isEmpty)
}

@Test("取消、非法载荷与超限不泄漏到屏幕")
func invalidSequencesAreAtomic() {
    var (parser, terminal) = makeTerminal()
    for bytes in [
        Array("\u{1B}]52;c;Z g==\u{07}X".utf8),
        [0x1B, 0x5D] + Array("52;c;Zg==".utf8) + [0x18, UInt8(ascii: "Y")],
        [0x1B, 0x5D] + Array("52;c;Zg==".utf8) + [0x1B, UInt8(ascii: "x"), UInt8(ascii: "Z")],
    ] {
        feed(bytes, &parser, &terminal)
        #expect(terminal.takeEffects().isEmpty)
    }
    #expect(rowText(terminal, 0).hasPrefix("XYZ"))
}

@Test("一个 feed 中只保留最后一次写入")
func coalescesEffects() {
    var (parser, terminal) = makeTerminal()
    feed(sequence(payload: "Zmlyc3Q=") + sequence(payload: "bGFzdA=="), &parser, &terminal)
    #expect(terminal.takeEffects() == [.clipboardWrite("last")])
    #expect(terminal.takeEffects().isEmpty)
}

@Test("搜索快照剥离未完成 OSC 与效果")
func searchSnapshotStripsSensitiveState() {
    var (parser, terminal) = makeTerminal()
    feed(sequence(payload: "c2VjcmV0"), &parser, &terminal)
    var snapshot = terminal.snapshotForSearch()
    #expect(snapshot.takeEffects().isEmpty)
    #expect(terminal.takeEffects() == [.clipboardWrite("secret")])
    feed("\u{1B}]52;c;c2Vj", &parser, &terminal)
    snapshot = terminal.snapshotForSearch()
    snapshot.oscEnd()
    #expect(snapshot.takeEffects().isEmpty)
}
```

向 `TerminalTests.ParserLexTests` 加入：

```swift
@Test("超长普通 OSC 整条丢弃而不是执行截断前缀")
func overlongRegularOSCDropsWholeSequence() {
    var (parser, terminal) = makeTerminal()
    feed("\u{1B}]0;before\u{07}", &parser, &terminal)
    feed("\u{1B}]0;" + String(repeating: "x", count: 4095) + "\u{07}", &parser, &terminal)
    #expect(terminal.title == "before")
}
```

- [ ] **Step 2: 运行测试并确认缺少效果 API**

Run: `swift test --no-parallel --filter OSC52ClipboardTests && swift test --no-parallel --filter ParserLexTests`

Expected: FAIL，包含 `Terminal has no member 'takeEffects'` 或 `TerminalEffect` 不存在。

- [ ] **Step 3: 实现累积状态与效果类型**

在 `OSC52Clipboard.swift` 加入：

```swift
public enum TerminalEffect: Equatable, Sendable {
    case clipboardWrite(String)
}

struct OSCAccumulator: Sendable {
    enum Completion: Sendable {
        case regular(ContiguousArray<UInt8>)
        case clipboardWrite(String)
    }
    private enum State: Sendable {
        case idle
        case probing(ContiguousArray<UInt8>)
        case regular(ContiguousArray<UInt8>)
        case osc52(OSC52PayloadAccumulator)
        case discarding
    }
    private var state: State = .idle

    mutating func start() { state = .probing([]) }
    mutating func cancel() { state = .idle }
    mutating func put(_ byte: UInt8) {
        switch state {
        case .idle, .discarding:
            return
        case .probing(var prefix):
            if byte == UInt8(ascii: ";"), prefix.elementsEqual("52".utf8) {
                state = .osc52(OSC52PayloadAccumulator())
            } else {
                prefix.append(byte)
                if !Array("52".utf8).starts(with: prefix) || prefix.count > 2 {
                    state = prefix.count > 4_096 ? .discarding : .regular(prefix)
                } else {
                    state = .probing(prefix)
                }
            }
        case .regular(var bytes):
            guard bytes.count < 4_096 else { state = .discarding; return }
            bytes.append(byte)
            state = .regular(bytes)
        case .osc52(var payload):
            payload.put(byte)
            state = payload.isDiscarding ? .discarding : .osc52(payload)
        }
    }
    mutating func finish() -> Completion? {
        defer { state = .idle }
        switch state {
        case .probing(let bytes), .regular(let bytes): return .regular(bytes)
        case .osc52(var payload): return payload.finish().map(Completion.clipboardWrite)
        case .idle, .discarding: return nil
        }
    }
}
```

同文件实现目标与 payload 状态；无效输入立刻替换 decoder，不能把已分配的大缓冲留在 discard 状态：

```swift
struct OSC52PayloadAccumulator: Sendable {
    private enum State: Sendable {
        case target(ContiguousArray<UInt8>)
        case payload(OSC52Base64Decoder, isFirstByte: Bool)
        case discarding
    }
    private var state: State = .target([])
    var isDiscarding: Bool {
        if case .discarding = state { return true }
        return false
    }

    mutating func put(_ byte: UInt8) {
        switch state {
        case .discarding:
            return
        case .target(var target):
            guard byte != UInt8(ascii: ";") else {
                state = Self.accepts(target: target)
                    ? .payload(OSC52Base64Decoder(), isFirstByte: true)
                    : .discarding
                return
            }
            guard target.count < 16, Self.isKnownTarget(byte) else {
                state = .discarding
                return
            }
            target.append(byte)
            state = .target(target)
        case .payload(var decoder, let isFirstByte):
            guard !(isFirstByte && byte == UInt8(ascii: "?")) else {
                state = .discarding
                return
            }
            decoder.put(byte)
            state = decoder.invalid
                ? .discarding
                : .payload(decoder, isFirstByte: false)
        }
    }

    mutating func finish() -> String? {
        defer { state = .discarding }
        guard case .payload(var decoder, _) = state else { return nil }
        return decoder.finish()
    }

    private static func accepts(target: ContiguousArray<UInt8>) -> Bool {
        target.isEmpty || target.contains { byte in
            byte == UInt8(ascii: "c") || byte == UInt8(ascii: "p")
                || byte == UInt8(ascii: "s")
        }
    }

    private static func isKnownTarget(_ byte: UInt8) -> Bool {
        byte == UInt8(ascii: "c") || byte == UInt8(ascii: "p")
            || byte == UInt8(ascii: "q") || byte == UInt8(ascii: "s")
            || (UInt8(ascii: "0")...UInt8(ascii: "7")).contains(byte)
    }
}
```

在 `Terminal` 增加：

```swift
var oscAccumulator = OSCAccumulator()
private var pendingEffect: TerminalEffect?

public mutating func oscStart() { oscAccumulator.start() }
public mutating func oscPut(_ byte: UInt8) { oscAccumulator.put(byte) }
public mutating func oscCancel() { oscAccumulator.cancel() }
public mutating func oscEnd() {
    switch oscAccumulator.finish() {
    case .regular(let bytes): oscDispatch(bytes[...])
    case .clipboardWrite(let text): pendingEffect = .clipboardWrite(text)
    case nil: break
    }
}
public mutating func takeEffects() -> [TerminalEffect] {
    guard let pendingEffect else { return [] }
    self.pendingEffect = nil
    return [pendingEffect]
}
```

在 `snapshotForSearch()` 最后加入：

```swift
snapshot.oscAccumulator = OSCAccumulator()
snapshot.pendingEffect = nil
```

`oscDispatch` default 注释改为只保留尚未实现的通知 OSC，不再声称 OSC 52 未实现。

- [ ] **Step 4: 把 Parser 改为生命周期调用**

删除 `oscBuffer` 与 `maxOSCBytes`。在 `ESC ]` 分支调用 `handler.oscStart()`；OSC 数据分支调用 `handler.oscPut(byte)`；BEL/ST 调用 `handler.oscEnd()`；CAN/SUB 若当前 state 为 `.osc` 或 `.oscEscape`，先调用 `handler.oscCancel()`；非法 `ESC x` 调用 `oscCancel()`。保留当前 C0 丢弃和 ground 同步语义。

- [ ] **Step 5: 运行 Core 定向与完整测试**

Run: `swift test --no-parallel --filter OSC52ClipboardTests && swift test --no-parallel --filter ParserLexTests && swift test --no-parallel --filter OSC8HyperlinkTests && swift test --no-parallel --filter CommandBlockTests`

Expected: 全部 PASS；OSC 0/2、8、133 回归无失败。

- [ ] **Step 6: 检查容量释放实现并提交**

Run: `rg -n "oscBuffer|maxOSCBytes|Data\(base64Encoded" Sources/TerminalCore && git diff --check`

Expected: 无匹配且 `git diff --check` 无输出。

```bash
git add Sources/TerminalCore/OSC52Clipboard.swift Sources/TerminalCore/Parser.swift Sources/TerminalCore/Terminal.swift Tests/TerminalCoreTests/OSC52ClipboardTests.swift Tests/TerminalCoreTests/TerminalTests.swift
git commit -m "feat(core): 流式解析 OSC 52" -m "让 Parser 只发送 OSC 词法生命周期，Terminal 有界区分普通序列与剪贴板载荷，并合并同批写入以限制敏感文本驻留。\n\nRefs #76"
```

---

### Task 3: Session 独立效果通道

**Files:**
- Modify: `Sources/InkShell/TerminalSession.swift`
- Modify: `Tests/InkShellTests/TerminalSessionEventTests.swift`

**Interfaces:**
- Consumes: `Terminal.takeEffects() -> [TerminalEffect]`。
- Produces: `TerminalSession.onEffect: ((TerminalEffect) -> Void)?`，在 `onUpdate` 前调用。

- [ ] **Step 1: 写失败测试**

```swift
@Test("OSC 52 效果在更新前上送且不进入事件通道")
func forwardsClipboardEffectBeforeUpdate() {
    let session = TerminalSession(size: .init(columns: 80, rows: 24))
    var order: [String] = []
    var effects: [TerminalEffect] = []
    var events: [TerminalEvent] = []
    session.onEffect = { effects.append($0); order.append("effect") }
    session.onEvent = { events.append($0) }
    session.onUpdate = { order.append("update") }
    session.consumeOutput(Data("\u{1B}]52;c;aGk=\u{07}".utf8))
    #expect(effects == [.clipboardWrite("hi")])
    #expect(events.isEmpty)
    #expect(order == ["effect", "update"])
    session.detach()
    session.consumeOutput(Data("\u{1B}]52;c;Ynll\u{07}".utf8))
    #expect(effects == [.clipboardWrite("hi")])
}
```

- [ ] **Step 2: 运行并确认失败**

Run: `swift test --no-parallel --filter TerminalSessionEventTests`

Expected: FAIL，`TerminalSession` 没有 `onEffect`。

- [ ] **Step 3: 实现并立即取走效果**

在 `onEvent` 邻近声明：

```swift
/// Core 产生的外部副作用请求；与未读/通知事件分离。
public var onEffect: ((TerminalEffect) -> Void)?
```

在 `consumeOutput` 的 parser.feed 后、`takeEvents()` 前加入：

```swift
for effect in terminal.takeEffects() {
    onEffect?(effect)
}
```

在 `detach()` 加 `onEffect = nil`。

- [ ] **Step 4: 运行测试并提交**

Run: `swift test --no-parallel --filter TerminalSessionEventTests`

Expected: PASS。

```bash
git add Sources/InkShell/TerminalSession.swift Tests/InkShellTests/TerminalSessionEventTests.swift
git commit -m "feat(shell): 独立上送终端剪贴板效果" -m "在搜索刷新前取走 Core 效果，并与会触发未读和通知的事件通道分离。\n\nRefs #76"
```

---

### Task 4: 本地配置、iCloud wire 与设置开关

**Files:**
- Modify: `Sources/InkConfig/InkConfig.swift`
- Modify: `Sources/InkConfig/ConfigSyncSnapshot.swift`
- Modify: `Sources/InkShell/SettingsViewController.swift`
- Modify: `Tests/InkConfigTests/InkConfigTests.swift`
- Modify: `Tests/InkConfigTests/ConfigSyncSnapshotTests.swift`
- Create: `Tests/InkShellTests/OSC52SettingsTests.swift`

**Interfaces:**
- Consumes: 现有 `InkConfig` TOML / wire / Settings 流程。
- Produces: `InkConfig.osc52WriteEnabled: Bool`，默认 true；TOML `clipboard.osc52_write`；可缺省 wire Bool。

- [ ] **Step 1: 写配置和迁移失败测试**

在 `InkConfigTests` 增加默认值、显式 false 与保存往返断言；在 `completeConfig()` 设为 false：

```swift
@Test("OSC 52 写入默认开启且可由 TOML 关闭")
func osc52WritePolicy() throws {
    #expect(InkConfig().osc52WriteEnabled)
    let file = FileManager.default.temporaryDirectory
        .appendingPathComponent("ink-osc52-config-\(UUID().uuidString).toml")
    try "[clipboard]\nosc52_write = false\n".write(to: file, atomically: true, encoding: .utf8)
    var config = InkConfig.load(from: file)
    #expect(!config.osc52WriteEnabled)
    config.osc52WriteEnabled = true
    try config.save(to: file)
    #expect(InkConfig.load(from: file).osc52WriteEnabled)
}
```

在 `ConfigSyncSnapshotTests` 用 `snapshotJSON` 删除字段：

```swift
@Test("旧 schema 1 缺少 OSC 52 字段时迁移为开启")
func oldSchemaDefaultsOSC52ToEnabled() throws {
    let data = try snapshotJSON { root in
        var config = try #require(root["config"] as? [String: Any])
        config.removeValue(forKey: "osc52WriteEnabled")
        root["config"] = config
    }
    #expect(try ConfigSyncSnapshot.decode(data).config.osc52WriteEnabled)
}
```

- [ ] **Step 2: 写设置开关失败测试**

新建 `OSC52SettingsTests.swift`：

```swift
import AppKit
import InkConfig
import Testing
@testable import InkShell

@Suite("OSC 52 设置")
@MainActor
struct OSC52SettingsTests {
    @Test("交互区开关展示只写边界并回传配置")
    func toggleUpdatesConfig() throws {
        let controller = SettingsViewController(config: InkConfig())
        var received: InkConfig?
        controller.onChange = { received = $0 }
        controller.loadView()
        let views = descendants(controller.view)
        let toggle = try #require(views.compactMap { $0 as? NSSwitch }.first {
            $0.accessibilityLabel() == "允许终端程序写入剪贴板（OSC 52）"
        })
        #expect(toggle.state == .on)
        #expect(views.compactMap { $0 as? NSTextField }.contains {
            $0.stringValue == "仅允许写入，终端程序不能读取剪贴板。"
        })
        toggle.performClick(nil)
        #expect(received?.osc52WriteEnabled == false)
    }

    private func descendants(_ view: NSView) -> [NSView] {
        view.subviews.flatMap { [$0] + descendants($0) }
    }
}
```

- [ ] **Step 3: 运行并确认字段/控件不存在**

Run: `swift test --no-parallel --filter InkConfigTests.osc52WritePolicy && swift test --no-parallel --filter ConfigSyncSnapshotTests && swift test --no-parallel --filter OSC52SettingsTests`

Expected: FAIL，缺少 `osc52WriteEnabled` 或设置开关。

- [ ] **Step 4: 实现配置和 schema 1 兼容迁移**

`InkConfig` 增加 `public var osc52WriteEnabled = true`，文档示例加入 `[clipboard]`；load 读取 `values.bool("clipboard.osc52_write")`；`tomlValues` 写出 Bool。

`WireConfig` 增加：

```swift
let osc52WriteEnabled: Bool?
```

从新配置初始化为 `config.osc52WriteEnabled`，验证生成配置时使用：

```swift
result.osc52WriteEnabled = osc52WriteEnabled ?? true
```

保持 `currentSchemaVersion = 1`。确认编码 JSON 中字段存在，删除字段的旧 JSON 仍可解码。

- [ ] **Step 5: 实现设置 UI**

`SettingsViewController` 增加 `private let osc52WriteSwitch = NSSwitch()`；交互 section 在“选中即复制”后加入：

```swift
makeRow(
    title: "允许终端程序写入剪贴板（OSC 52）",
    detail: "仅允许写入，终端程序不能读取剪贴板。",
    control: osc52WriteSwitch
)
```

把 switch 加入 `configureControls` 的 toggle 数组并设置相同 accessibility label；`updateControls` 映射配置值；`controlChanged` 回写配置值。

- [ ] **Step 6: 运行配置/UI 测试并提交**

Run: `swift test --no-parallel --filter InkConfigTests && swift test --no-parallel --filter ConfigSyncSnapshotTests && swift test --no-parallel --filter OSC52SettingsTests && swift test --no-parallel --filter ConfigSyncSettingsTests`

Expected: 全部 PASS，原 section 顺序不变。

```bash
git add Sources/InkConfig/InkConfig.swift Sources/InkConfig/ConfigSyncSnapshot.swift Sources/InkShell/SettingsViewController.swift Tests/InkConfigTests/InkConfigTests.swift Tests/InkConfigTests/ConfigSyncSnapshotTests.swift Tests/InkShellTests/OSC52SettingsTests.swift
git commit -m "feat(config): 提供 OSC 52 只写开关" -m "默认允许终端写入剪贴板，同时让 TOML、设置中心和 schema 1 云端快照完整往返并兼容旧数据。\n\nRefs #76"
```

---

### Task 5: AppKit 写入器与所有 pane 的策略接线

**Files:**
- Create: `Sources/InkShell/OSC52PasteboardWriter.swift`
- Modify: `Sources/InkShell/MainWindowController.swift`
- Create: `Tests/InkShellTests/OSC52WindowTests.swift`

**Interfaces:**
- Consumes: `TerminalSession.onEffect`、`InkConfig.osc52WriteEnabled`。
- Produces: `OSC52PasteboardWriting.write(_ text: String) -> Bool`；所有 pane 使用窗口当前策略。

- [ ] **Step 1: 写 pasteboard writer 与窗口策略失败测试**

新建测试文件。写入器测试使用命名 pasteboard，不碰 general；窗口测试注入 recorder，并通过 controller 的前后台 session 直接 `consumeOutput`：

```swift
import AppKit
import Foundation
import InkConfig
import Testing
@testable import InkShell

@Suite("OSC 52 窗口接线", .serialized)
@MainActor
struct OSC52WindowTests {
    @Test("写入器支持普通和空字符串")
    func writerWritesAndClears() {
        let pasteboard = NSPasteboard(name: .init("ink.osc52.\(UUID().uuidString)"))
        let writer = OSC52PasteboardWriter(pasteboard: pasteboard)
        #expect(writer.write("secret"))
        #expect(pasteboard.string(forType: .string) == "secret")
        #expect(writer.write(""))
        #expect(pasteboard.string(forType: .string) == "")
    }
}

@MainActor
private final class OSC52WriterRecorder: OSC52PasteboardWriting {
    var values: [String] = []
    func write(_ text: String) -> Bool { values.append(text); return true }
}

@MainActor
private final class OSC52NotificationRecorder: CommandNotificationCoordinating {
    var requests: [CommandNotificationRequest] = []
    func submit(_ request: CommandNotificationRequest) { requests.append(request) }
}

@MainActor
private final class OSC52WindowFixture {
    let root: URL
    let defaults: UserDefaults
    let controller: MainWindowController
    let panes: [TerminalPane]
    let writer = OSC52WriterRecorder()
    let notifier = OSC52NotificationRecorder()
    private let suiteName: String

    init(enabled: Bool) throws {
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("ink-osc52-window-\(UUID().uuidString)")
        let projectDirectory = root.appendingPathComponent("project")
        let configURL = root.appendingPathComponent("config.toml")
        try FileManager.default.createDirectory(
            at: projectDirectory,
            withIntermediateDirectories: true
        )
        suiteName = "ink.osc52-window.\(UUID().uuidString)"
        defaults = try #require(UserDefaults(suiteName: suiteName))
        defaults.removePersistentDomain(forName: suiteName)
        ProjectStore.save([Project(directory: projectDirectory)], defaults: defaults)

        let path = (projectDirectory.path as NSString).abbreviatingWithTildeInPath
        let workspaceStore = WorkspaceStore(defaults: defaults)
        #expect(workspaceStore.save(WorkspaceSnapshot(
            activeProjectPath: path,
            projects: [.init(
                path: path,
                activeTabIndex: 0,
                tabs: [
                    .init(customName: "前台", activePaneID: "front", layout: .leaf(
                        paneID: "front",
                        workingDirectory: projectDirectory.path
                    )),
                    .init(customName: "后台", activePaneID: "back", layout: .leaf(
                        paneID: "back",
                        workingDirectory: projectDirectory.path
                    )),
                ]
            )]
        )))

        var config = InkConfig()
        config.osc52WriteEnabled = enabled
        var created: [TerminalPane] = []
        controller = MainWindowController(
            initialConfig: config,
            configURL: configURL,
            configSyncService: ConfigSyncService(defaults: defaults),
            projectDefaults: defaults,
            workspaceStore: workspaceStore,
            startPaneOverride: { size, directory in
                let pane = TerminalPane(session: TerminalSession(
                    size: size,
                    workingDirectory: directory
                ))
                created.append(pane)
                return pane
            },
            notificationCoordinator: notifier,
            isApplicationActive: { false },
            osc52PasteboardWriter: writer
        )
        panes = created
    }

    func data(_ text: String) -> Data {
        let payload = Data(text.utf8).base64EncodedString()
        return Data("\u{1B}]52;c;\(payload)\u{07}".utf8)
    }

    func cleanUp() {
        controller.window?.close()
        defaults.removePersistentDomain(forName: suiteName)
        try? FileManager.default.removeItem(at: root)
    }
}

@Test("前后台 pane 都能写入且不发送通知")
func allPanesWriteWithoutNotification() throws {
    let fixture = try OSC52WindowFixture(enabled: true)
    defer { fixture.cleanUp() }
    for (index, pane) in fixture.panes.enumerated() {
        pane.session.consumeOutput(fixture.data("pane-\(index)"))
    }
    #expect(fixture.writer.values == ["pane-0", "pane-1"])
    #expect(fixture.notifier.requests.isEmpty)
}

@Test("关闭策略时丢弃已解析效果")
func disabledPolicyDropsEffect() throws {
    let fixture = try OSC52WindowFixture(enabled: false)
    defer { fixture.cleanUp() }
    fixture.panes[0].session.consumeOutput(fixture.data("secret"))
    #expect(fixture.writer.values.isEmpty)
    #expect(fixture.notifier.requests.isEmpty)
}
```

`TerminalSessionEventTests` 已证明 OSC 52 不进入 `onEvent`；本测试再证明前后台 session
均只触发 writer，且应用失焦时也没有通知请求。生产代码不得新增测试专用 attention API。

- [ ] **Step 2: 运行并确认缺少 writer 接口**

Run: `swift test --no-parallel --filter OSC52WindowTests`

Expected: FAIL，缺少 `OSC52PasteboardWriter` / `OSC52PasteboardWriting` / initializer 参数。

- [ ] **Step 3: 实现唯一 AppKit 副作用边界**

```swift
import AppKit

@MainActor
protocol OSC52PasteboardWriting: AnyObject {
    @discardableResult func write(_ text: String) -> Bool
}

@MainActor
final class OSC52PasteboardWriter: OSC52PasteboardWriting {
    private let pasteboard: NSPasteboard
    init(pasteboard: NSPasteboard = .general) { self.pasteboard = pasteboard }
    @discardableResult func write(_ text: String) -> Bool {
        pasteboard.clearContents()
        return pasteboard.setString(text, forType: .string)
    }
}
```

该类型不得提供读取方法。

- [ ] **Step 4: 注入窗口并接线所有 Session**

在 `MainWindowController` 增加 `private let osc52PasteboardWriter: any OSC52PasteboardWriting`；内部 initializer 追加默认参数 `osc52PasteboardWriter: any OSC52PasteboardWriting = OSC52PasteboardWriter()` 并赋值。

`configureCallbacks(for:)` 增加：

```swift
session.onEffect = { [weak self] effect in
    guard let self else { return }
    switch effect {
    case .clipboardWrite(let text):
        guard self.config.osc52WriteEnabled else { return }
        _ = self.osc52PasteboardWriter.write(text)
    }
}
```

不要调用 `handleTerminalEvent`、`tab.receive`、notification coordinator 或视图的 `pasteboardWriter`。

- [ ] **Step 5: 运行 Shell 定向测试并提交**

Run: `swift test --no-parallel --filter OSC52WindowTests && swift test --no-parallel --filter CommandStatusWindowTests && swift test --no-parallel --filter TabAttentionTests`

Expected: 全部 PASS。

```bash
git add Sources/InkShell/OSC52PasteboardWriter.swift Sources/InkShell/MainWindowController.swift Tests/InkShellTests/OSC52WindowTests.swift
git commit -m "feat(shell): 执行 OSC 52 剪贴板写入" -m "窗口按当前配置处理所有前后台 pane 的独立效果，不读取剪贴板也不触发标签未读或通知。\n\nRefs #76"
```

---

### Task 6: Roadmap、回归、性能与内存验收

**Files:**
- Modify: `docs/roadmap.md`
- Modify: `docs/perf.md`

**Interfaces:**
- Consumes: Tasks 1–5 完整实现。
- Produces: 权威范围同步、构建/测试证据、普通热路径与大载荷内存证据。

- [ ] **Step 1: 同步 roadmap 文案**

把 P1-B 条目精确改为：

```markdown
- OSC 52 剪贴板（SSH 中复制回本地）：解码后最多 1 MiB，仅允许终端程序写入；
  默认开启并可在设置中关闭，永不支持读取或 PTY 查询响应
```

- [ ] **Step 2: 运行静态边界检查**

Run: `! rg -n "import (AppKit|Metal)" Sources/TerminalCore && ! rg -n "string\(forType:|data\(forType:" Sources/InkShell/OSC52PasteboardWriter.swift && git diff --check`

Expected: exit 0，无输出；Core 无 UI 依赖，writer 无读取 API。

- [ ] **Step 3: 运行完整测试与构建**

Run: `swift test --no-parallel`

Expected: exit 0，全部 tests PASS。

Run: `swift build`

Expected: exit 0，Build complete。

- [ ] **Step 4: 做普通输出吞吐与大载荷内存验收**

先记录当前 main 基线 `swift run -c release ink-bench` 的普通文本端到端结果，再在分支执行同一命令三次取中位数。用 Instruments Time Profiler 对普通输出场景采样，确认新增 OSC lifecycle 不出现在显著普通文本栈中。启动 Ink 后分别发送：1 MiB 合法 OSC 52、1 MiB+1 字节、2 MiB 无效/未终止载荷以及连续 20 条 1 MiB 合法载荷；在 Allocations/Memory Graph 确认终止或取消后大缓冲释放、连续写入不线性累积。

在 `docs/perf.md` 追加日期、硬件/macOS、构建模式、三次结果与中位数、Instruments 结论、峰值和回落值。若普通吞吐中位数回退超过 5%，或大载荷结束后仍常驻多份 1 MiB buffer，不得提交验收；回到 Task 1/2 消除分配或容量保留后重测。

- [ ] **Step 5: 手工功能验收**

在本机 shell 与 SSH 会话分别执行能输出 BEL 和 ST 终止 OSC 52 的命令，验证普通 UTF-8、空载荷清空、设置关闭后不写、重新开启后恢复、`?` 不回显本地内容。切到后台标签再触发，验证剪贴板更新而标签没有未读圆点或系统通知。

- [ ] **Step 6: 提交文档与验收记录**

```bash
git add docs/roadmap.md docs/perf.md
git commit -m "docs(terminal): 记录 OSC 52 验收边界" -m "同步有界只写范围，并记录 Parser 热路径与大载荷释放的实测证据。\n\nRefs #76"
```

- [ ] **Step 7: 最终分支审计**

Run: `git status --short --branch -uall && git diff --check origin/main...HEAD && swift test --no-parallel && swift build`

Expected: worktree clean；diff check、完整测试与构建全部 exit 0。

之后按 `git-workflow` 执行：push `agent/issue-76-osc52-clipboard`，创建带 `Closes #76` 的 PR，等待 CI 与 code review，修复所有 findings，获 code owner 批准后 squash merge；合并后在 main 再跑完整测试与构建，并清理远端分支和 worktree。未经用户明确要求不得创建 release tag。
