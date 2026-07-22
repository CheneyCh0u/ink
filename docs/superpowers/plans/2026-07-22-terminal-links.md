# URL 与 OSC 8 超链接 Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** 为 Ink 增加 URL 自动识别、OSC 8 稀疏链接范围、Command 点击、悬停下划线及链接右键菜单，同时保持 TUI 鼠标语义和无链接热路径性能。

**Architecture:** `TerminalCore` 用可选的终端级目标表和逻辑行范围表保存显式 OSC 8，URL 只在命中冷路径扫描；所有范围通过稳定行号与逻辑 cell 偏移投影到现有 `TextPosition`。`InkTerminalView` 把单个悬停范围投影成可见 cell 下划线，并把打开动作通过闭包交给 `InkShell`；无悬停和无链接路径使用专门的空 lookup，不给逐格渲染增加动态分配。

**Tech Stack:** Swift 6、Swift Testing、AppKit、Metal、CoreText、SwiftPM；最低 macOS 14.0；零新增第三方依赖。

## Global Constraints

- `TerminalCore` 保持纯 Swift，不依赖 AppKit 或 Metal。
- `Cell` 必须保持 8 字节，`RowInfo` 必须保持 2 字节。
- 链接元数据只能使用逻辑行稀疏旁路范围表，仅在实际出现 OSC 8 时分配；禁止每 cell 字段或对象引用。
- 自动 URL 扫描只能发生在鼠标命中等冷路径，不能进入 parser、grid 更新或逐帧全屏扫描。
- 无活动 OSC 8 且当前物理行没有链接时，打印不得创建数组、字典、字符串或触发 URL 扫描。
- renderer 必须继续保持每帧一次 instanced draw call。
- 普通右键在 TUI 鼠标上报开启时继续上报；`Option + 右键` 才强制 Ink 原生菜单。
- 用户可见名称使用 `Ink`，代码模块与标识符使用英文；注释、文档、提交摘要使用中文。
- 所有提交带 `Refs #66`，PR 描述只使用 `Closes #66`；不创建发布标签。

---

## File Map

- Create `Sources/TerminalCore/TerminalLinks.swift`: 公共链接值、逻辑行快照、绝对/逻辑坐标投影和 URL 冷路径检测。
- Create `Sources/TerminalCore/HyperlinkStore.swift`: OSC 8 目标表、逻辑行范围表、区间替换和稀疏物理行索引。
- Modify `Sources/TerminalCore/Terminal.swift`: OSC 8 状态、打印/编辑同步、滚动、备用屏、清理及 reflow 接入。
- Create `Sources/InkTerminalView/TerminalLinkHighlights.swift`: 半开链接范围到当前 viewport 的有序 cell span 投影。
- Create `Sources/InkTerminalView/TerminalLinkInteraction.swift`: 可打开 URL 判定、鼠标分流和不可变菜单载荷。
- Modify `Sources/InkTerminalView/TerminalRenderer.swift`: 空/有链接两条特化 lookup 路径和下划线 flag。
- Modify `Sources/InkTerminalView/TerminalMetalView.swift`: tracking area、悬停刷新、Command 点击和链接菜单。
- Modify `Sources/InkShell/TerminalWorkspaceViewController.swift`: 注入 `NSWorkspace` 打开闭包并在解绑时清理。
- Create `Tests/TerminalCoreTests/TerminalURLLinkTests.swift`: URL 识别与逻辑坐标测试。
- Create `Tests/TerminalCoreTests/OSC8HyperlinkTests.swift`: OSC 8 解析、覆写、编辑、滚动、备用屏、淘汰测试。
- Modify `Tests/TerminalCoreTests/ReflowTests.swift`: 显式链接随 reflow 与环截断重映射。
- Create `Tests/InkTerminalViewTests/TerminalLinkHighlightTests.swift`: viewport 投影测试。
- Create `Tests/InkTerminalViewTests/TerminalLinkInteractionTests.swift`: Command/右键/TUI 分流、复制和稳定菜单目标。
- Modify `Sources/ink-bench/main.swift`: 增加可单独运行的无链接/稀疏链接采样负载。
- Modify `docs/perf.md`: 记录本机 Release benchmark 与 Time Profiler 证据。

---

### Task 1: URL 冷路径与逻辑行坐标

**Files:**
- Create: `Sources/TerminalCore/TerminalLinks.swift`
- Create: `Tests/TerminalCoreTests/TerminalURLLinkTests.swift`

**Interfaces:**
- Consumes: `Terminal.absoluteLine(_:)`, `Terminal.absoluteLineInfo(_:)`, `ClusterTable`, `TextPosition`, `SemanticTextRange`。
- Produces: `TerminalLinkSource`, `TerminalLink`, `Terminal.link(at:)`, internal `TerminalLogicalLine` used by Tasks 2–4.

- [ ] **Step 1: Write the failing URL and coordinate tests**

Create this initial suite:

```swift
import Testing
@testable import TerminalCore

@Suite("终端 URL 链接")
struct TerminalURLLinkTests {
    @Test("识别 HTTP/HTTPS 并去掉句末标点")
    func detectsURLsAndTrimsPunctuation() throws {
        var (parser, terminal) = makeTerminal(columns: 80, rows: 3)
        feed("见 https://example.test/a_(b)，以及 HTTP://EXAMPLE.TEST/x.", &parser, &terminal)

        let first = try #require(terminal.link(at: TextPosition(line: 0, column: 5)))
        #expect(first.target == "https://example.test/a_(b)")
        #expect(first.source == .detectedURL)
        #expect(first.range.start == TextPosition(line: 0, column: 3))
        let second = try #require(terminal.link(at: TextPosition(line: 0, column: 42)))
        #expect(second.target == "HTTP://EXAMPLE.TEST/x")
    }

    @Test("软折行 URL 返回跨物理行半开范围")
    func detectsWrappedURL() throws {
        var (parser, terminal) = makeTerminal(columns: 12, rows: 4)
        feed("xx https://example.test/path", &parser, &terminal)

        let link = try #require(terminal.link(at: TextPosition(line: 1, column: 3)))
        #expect(link.target == "https://example.test/path")
        #expect(link.range.start == TextPosition(line: 0, column: 3))
        #expect(link.range.end.line >= 1)
    }

    @Test("宽字符前缀不会让 cell 坐标漂移")
    func mapsWidePrefixToCellColumns() throws {
        var (parser, terminal) = makeTerminal(columns: 60, rows: 2)
        feed("终端 https://example.test", &parser, &terminal)

        let link = try #require(terminal.link(at: TextPosition(line: 0, column: 8)))
        #expect(link.range.start == TextPosition(line: 0, column: 5))
        #expect(terminal.link(at: TextPosition(line: 0, column: 4)) == nil)
    }

    @Test("硬换行、无 host 与非 HTTP scheme 不自动识别")
    func rejectsNonURLs() {
        var (parser, terminal) = makeTerminal(columns: 40, rows: 3)
        feed("https://\r\nfile:///tmp/a mailto:a@example.test", &parser, &terminal)

        #expect(terminal.link(at: TextPosition(line: 0, column: 2)) == nil)
        #expect(terminal.link(at: TextPosition(line: 1, column: 2)) == nil)
    }

    @Test("搜索结果坐标可直接查询同一链接")
    func searchCoordinatesResolveLink() throws {
        var (parser, terminal) = makeTerminal(columns: 40, rows: 3)
        feed("go https://example.test/path now", &parser, &terminal)
        let match = try #require(TerminalSearchEngine.search(in: terminal, query: "example").first)
        let link = try #require(terminal.link(at: match.range.start))
        #expect(link.target == "https://example.test/path")
        #expect(link.range.start == TextPosition(line: 0, column: 3))
    }
}
```

- [ ] **Step 2: Run the suite and verify RED**

Run `swift test --filter TerminalURLLinkTests`.

Expected: compilation fails because `Terminal.link(at:)`, `TerminalLink`, and `.detectedURL` do not exist.

- [ ] **Step 3: Add immutable link values and logical-line records**

Create `TerminalLinks.swift` with these exact public values and internal mapping records:

```swift
import Foundation

public enum TerminalLinkSource: Sendable, Equatable {
    case osc8
    case detectedURL
}

public struct TerminalLink: Sendable, Equatable {
    public let target: String
    public let range: SemanticTextRange
    public let source: TerminalLinkSource

    public init(target: String, range: SemanticTextRange, source: TerminalLinkSource) {
        self.target = target
        self.range = range
        self.source = source
    }
}

struct TerminalLogicalScalar: Sendable {
    let value: UInt32
    let startOffset: Int
    let endOffset: Int
}

struct TerminalLogicalSegment: Sendable {
    let lineID: UInt64
    let absoluteLine: Int
    let startOffset: Int
    let cellCount: Int
}

struct TerminalLogicalLine: Sendable {
    let headLineID: UInt64
    let scalars: ContiguousArray<TerminalLogicalScalar>
    let segments: ContiguousArray<TerminalLogicalSegment>

    func logicalOffset(at position: TextPosition) -> Int? {
        guard let segment = segments.first(where: { $0.absoluteLine == position.line }),
              position.column >= 0, position.column < segment.cellCount else { return nil }
        return segment.startOffset + position.column
    }

    func position(at offset: Int) -> TextPosition? {
        for index in segments.indices {
            let segment = segments[index]
            let end = segment.startOffset + segment.cellCount
            let isFinalEndpoint = index == segments.index(before: segments.endIndex) && offset == end
            if offset < end || isFinalEndpoint {
                return TextPosition(
                    line: segment.absoluteLine,
                    column: max(0, min(offset - segment.startOffset, segment.cellCount))
                )
            }
        }
        return nil
    }
}
```

Add `Terminal.logicalLine(containing:)` as an internal extension. It must reject out-of-range positions, walk backward through `RowInfo.wrapped` to the head, walk forward through wrapped continuations, trim each row exactly like reflow, skip wide trailing cells, expand cluster scalars at the same cell offset, give a wide-leading scalar a two-cell end offset, and derive stable line IDs from `oldestLineID + absoluteLine`.

- [ ] **Step 4: Implement the pure scalar URL detector and first query**

Add this interface and algorithm:

```swift
enum TerminalURLDetector {
    struct Match: Sendable, Equatable {
        let target: String
        let offsets: Range<Int>
    }

    static func match(
        in line: TerminalLogicalLine,
        containing logicalOffset: Int
    ) -> Match?
}
```

`match` scans scalar indices for ASCII case-insensitive `http://` or `https://`; stops at whitespace, controls, quotes, angle brackets, backtick, or backslash; removes English/Chinese sentence punctuation and only unmatched closing brackets. Build the candidate by appending validated Unicode scalars to a local `String`. Accept only `URLComponents` with scheme `http`/`https` and a non-empty host. Return the first candidate whose cell-offset range contains `logicalOffset`.

Add:

```swift
extension Terminal {
    public func link(at position: TextPosition) -> TerminalLink? {
        guard let line = logicalLine(containing: position),
              let offset = line.logicalOffset(at: position),
              let match = TerminalURLDetector.match(in: line, containing: offset),
              let start = line.position(at: match.offsets.lowerBound),
              let end = line.position(at: match.offsets.upperBound) else { return nil }
        return TerminalLink(
            target: match.target,
            range: SemanticTextRange(start: start, end: end),
            source: .detectedURL
        )
    }
}
```

- [ ] **Step 5: Run focused and full tests**

Run `swift test --filter TerminalURLLinkTests`, then `swift test`.

Expected: both pass; URL query work happens only when `link(at:)` is called.

- [ ] **Step 6: Commit the cold-path URL unit**

```bash
git add Sources/TerminalCore/TerminalLinks.swift Tests/TerminalCoreTests/TerminalURLLinkTests.swift
git commit -m "feat(core): 增加逻辑行 URL 冷路径识别" -m "只在命中查询时拼接逻辑行并投影 cell 坐标，避免普通输出承担 URL 扫描成本。" -m "Refs #66"
```

---

### Task 2: OSC 8 目标表与连续写入范围

**Files:**
- Create: `Sources/TerminalCore/HyperlinkStore.swift`
- Create: `Tests/TerminalCoreTests/OSC8HyperlinkTests.swift`
- Modify: `Sources/TerminalCore/Terminal.swift`
- Modify: `Sources/TerminalCore/TerminalLinks.swift`

**Interfaces:**
- Consumes: `TerminalLogicalLine`, stable physical line IDs, OSC payload bytes.
- Produces: internal `HyperlinkTargetTable`, `HyperlinkRangeStore`, and explicit-first `Terminal.link(at:)`.

- [ ] **Step 1: Write failing OSC 8 parsing and sequential-write tests**

Create:

```swift
import Testing
@testable import TerminalCore

@Suite("OSC 8 超链接")
struct OSC8HyperlinkTests {
    @Test("BEL 与 ST 终止的显式链接可查询")
    func parsesBothTerminators() throws {
        var (parser, terminal) = makeTerminal(columns: 40, rows: 3)
        feed("\u{1B}]8;;https://one.test\u{07}one\u{1B}]8;;\u{07} ", &parser, &terminal)
        feed("\u{1B}]8;id=x;https://two.test\u{1B}\\two\u{1B}]8;;\u{1B}\\", &parser, &terminal)

        #expect(try #require(terminal.link(at: .init(line: 0, column: 1))).target == "https://one.test")
        #expect(try #require(terminal.link(at: .init(line: 0, column: 5))).target == "https://two.test")
    }

    @Test("结束和替换目标会形成两个合并范围")
    func closesAndReplacesTarget() throws {
        var (parser, terminal) = makeTerminal(columns: 40, rows: 2)
        feed("\u{1B}]8;;https://a.test\u{07}abc\u{1B}]8;;https://b.test\u{07}def\u{1B}]8;;\u{07}x", &parser, &terminal)

        #expect(try #require(terminal.link(at: .init(line: 0, column: 2))).source == .osc8)
        #expect(try #require(terminal.link(at: .init(line: 0, column: 4))).target == "https://b.test")
        #expect(terminal.link(at: .init(line: 0, column: 6)) == nil)
        #expect(terminal.explicitHyperlinkRecordCount == 1)
    }

    @Test("无链接普通输出不分配旁路元数据")
    func plainOutputDoesNotAllocateMetadata() {
        var (parser, terminal) = makeTerminal()
        feed(String(repeating: "plain output ", count: 100), &parser, &terminal)
        #expect(!terminal.hyperlinkMetadataAllocated)
    }

    @Test("无效 UTF-8 OSC 8 不改变当前活动目标")
    func invalidSequenceKeepsActiveTarget() throws {
        var (parser, terminal) = makeTerminal(columns: 30, rows: 2)
        feed("\u{1B}]8;;https://safe.test\u{07}a", &parser, &terminal)
        feed([0x1B, 0x5D, 0x38, 0x3B, 0x3B, 0xFF, 0x07, 0x62], &parser, &terminal)
        #expect(try #require(terminal.link(at: .init(line: 0, column: 1))).target == "https://safe.test")
    }

    @Test("分片 OSC 8 保持解析状态，显式目标优先于可见 URL")
    func splitSequenceAndExplicitPrecedence() throws {
        var (parser, terminal) = makeTerminal(columns: 40, rows: 2)
        feed("\u{1B}]8;;https://target", &parser, &terminal)
        feed(".test\u{07}https://visible.test\u{1B}]8;;\u{07}", &parser, &terminal)
        let link = try #require(terminal.link(at: .init(line: 0, column: 10)))
        #expect(link.target == "https://target.test")
        #expect(link.source == .osc8)
    }
}
```

- [ ] **Step 2: Run RED**

Run `swift test --filter OSC8HyperlinkTests`.

Expected: compilation fails because sparse storage and test-visible allocation state do not exist.

- [ ] **Step 3: Implement target interning and logical range replacement**

Create these exact storage interfaces:

```swift
struct HyperlinkSpan: Sendable, Equatable {
    var offsets: Range<UInt32>
    var targetID: UInt32
}

struct HyperlinkLineRecord: Sendable, Equatable {
    var headLineID: UInt64
    var spans: ContiguousArray<HyperlinkSpan>
}

struct HyperlinkRowAnchor: Sendable, Equatable {
    var headLineID: UInt64
    var startOffset: UInt32
}

struct HyperlinkReferenceDelta: Sendable {
    var counts: [UInt32: Int] = [:]
}

struct HyperlinkRangeStore: Sendable {
    private(set) var lines: ContiguousArray<HyperlinkLineRecord> = []
    private(set) var rowIndex: [UInt64: HyperlinkRowAnchor] = [:]

    var isEmpty: Bool { lines.isEmpty }

    mutating func replace(
        headLineID: UInt64,
        offsets: Range<UInt32>,
        with targetID: UInt32?
    ) -> HyperlinkReferenceDelta
}
```

`replace` binary-searches lines, splits overlaps, optionally inserts the target, sorts by lower bound, and coalesces adjacent equal targets. Compute net reference changes by comparing target counts before and after. Return without allocating when no record matches and `targetID == nil`.

Add a slot-reusing target table:

```swift
struct HyperlinkTargetTable: Sendable {
    struct Entry: Sendable {
        var uri: String
        var references: Int
    }

    mutating func retain(uri: String) -> UInt32
    mutating func retain(id: UInt32, count: Int)
    mutating func release(id: UInt32, count: Int)
    func uri(for id: UInt32) -> String?
}
```

Store entries in `ContiguousArray<Entry?>`, free IDs in `ContiguousArray<UInt32>`, and URI lookup in `[String: UInt32]`. Delete/recycle a slot at zero references. Apply each net delta once, positive counts before negative counts.

- [ ] **Step 4: Parse OSC 8 and stamp printed ranges**

Add to `Terminal`:

```swift
private var hyperlinkTargets: HyperlinkTargetTable?
private var hyperlinks: HyperlinkRangeStore?
private var activeHyperlinkTargetID: UInt32?
private var savedPrimaryHyperlinks: HyperlinkRangeStore?
```

Handle OSC code 8 by locating the second semicolon, validating UTF-8/control-free URI bytes, closing on empty URI, and otherwise retaining the new active target. Invalid payload leaves the old active target unchanged. Release the previous active reference on a valid replacement/close.

Before `print(_:)` writes a visible-width cell, call:

```swift
replaceHyperlinkCells(row: row, columns: col..<(col + width), targetID: activeHyperlinkTargetID)
```

Use the stable row ID and sparse row index first. Only scan the logical line when an active target must create a record. Create `HyperlinkRangeStore` only for non-nil writes. Rebuild anchors for physical rows intersected by the updated record.

Expose internal test diagnostics:

```swift
var hyperlinkMetadataAllocated: Bool { hyperlinks != nil }
var explicitHyperlinkRecordCount: Int { hyperlinks?.lines.count ?? 0 }
```

Make `Terminal.link(at:)` query the explicit store before automatic URL detection and project the entire explicit span to a half-open `SemanticTextRange`.

- [ ] **Step 5: Run focused and full tests**

Run `swift test --filter OSC8HyperlinkTests`, `swift test --filter TerminalURLLinkTests`, then `swift test`.

Expected: all pass; the plain-output allocation assertion is false.

- [ ] **Step 6: Commit OSC 8 storage**

```bash
git add Sources/TerminalCore/HyperlinkStore.swift Sources/TerminalCore/Terminal.swift Sources/TerminalCore/TerminalLinks.swift Tests/TerminalCoreTests/OSC8HyperlinkTests.swift
git commit -m "feat(core): 用逻辑行旁路表保存 OSC 8" -m "显式链接只为实际范围分配目标和区间，并让无链接打印保持空表快速路径。" -m "Refs #66"
```

---

### Task 3: Cell 编辑与范围变换

**Files:**
- Modify: `Sources/TerminalCore/HyperlinkStore.swift`
- Modify: `Sources/TerminalCore/Terminal.swift`
- Modify: `Tests/TerminalCoreTests/OSC8HyperlinkTests.swift`

**Interfaces:**
- Consumes: Task 2 `HyperlinkRangeStore.replace`, row anchors, target reference deltas.
- Produces: `clear`, `insert`, `delete`, and centralized Terminal cell synchronization used by every editing path.

- [ ] **Step 1: Add failing overwrite, erase, insert/delete, wide and cluster tests**

Append:

```swift
@Test("无链接覆写会分裂旧范围")
func overwriteSplitsOldRange() {
    var (parser, terminal) = makeTerminal(columns: 12, rows: 2)
    feed("\u{1B}]8;;https://a.test\u{07}abcdef\u{1B}]8;;\u{07}", &parser, &terminal)
    feed("\u{1B}[1;3HX", &parser, &terminal)

    #expect(terminal.link(at: .init(line: 0, column: 2)) == nil)
    #expect(terminal.link(at: .init(line: 0, column: 0))?.target == "https://a.test")
    #expect(terminal.link(at: .init(line: 0, column: 4))?.target == "https://a.test")
}

@Test("ECH 与 EL 删除相交链接")
func eraseRemovesRanges() {
    var (parser, terminal) = makeTerminal(columns: 12, rows: 2)
    feed("\u{1B}]8;;https://a.test\u{07}abcdef\u{1B}]8;;\u{07}", &parser, &terminal)
    feed("\u{1B}[1;3H\u{1B}[2X", &parser, &terminal)
    #expect(terminal.link(at: .init(line: 0, column: 2)) == nil)
    #expect(terminal.link(at: .init(line: 0, column: 4))?.target == "https://a.test")
    feed("\u{1B}[1;5H\u{1B}[K", &parser, &terminal)
    #expect(terminal.link(at: .init(line: 0, column: 4)) == nil)
}

@Test("ICH 与 DCH 只移动当前物理行链接片段")
func insertDeleteCharactersMoveRanges() {
    var (parser, terminal) = makeTerminal(columns: 8, rows: 2)
    feed("x\u{1B}]8;;https://a.test\u{07}abc\u{1B}]8;;\u{07}yz", &parser, &terminal)
    feed("\u{1B}[1;2H\u{1B}[@", &parser, &terminal)
    #expect(terminal.link(at: .init(line: 0, column: 2))?.target == "https://a.test")
    feed("\u{1B}[P", &parser, &terminal)
    #expect(terminal.link(at: .init(line: 0, column: 1))?.target == "https://a.test")
}

@Test("宽字符两格命中，组合字符不扩张 cell 范围")
func wideAndCombiningCells() throws {
    var (parser, terminal) = makeTerminal(columns: 12, rows: 2)
    feed("\u{1B}]8;;https://a.test\u{07}终e\u{301}\u{1B}]8;;\u{07}", &parser, &terminal)
    #expect(terminal.link(at: .init(line: 0, column: 0))?.target == "https://a.test")
    #expect(terminal.link(at: .init(line: 0, column: 1))?.target == "https://a.test")
    #expect(try #require(terminal.link(at: .init(line: 0, column: 2))).range.end.column == 3)
}

@Test("ED 清理可见范围，RIS 清理目标与所有旁路状态")
func displayEraseAndResetClearMetadata() {
    var (parser, terminal) = makeTerminal(columns: 12, rows: 2)
    feed("\u{1B}]8;;https://a.test\u{07}abcdef\u{1B}]8;;\u{07}\u{1B}[2J", &parser, &terminal)
    #expect(terminal.explicitHyperlinkRecordCount == 0)
    feed("\u{1B}]8;;https://b.test\u{07}x\u{1B}c", &parser, &terminal)
    #expect(!terminal.hyperlinkMetadataAllocated)
}
```

- [ ] **Step 2: Run RED**

Run `swift test --filter OSC8HyperlinkTests`.

Expected: overwrite, erase, and ICH/DCH assertions fail because only normal print updates metadata.

- [ ] **Step 3: Add exact interval operations**

Add:

```swift
mutating func clear(
    headLineID: UInt64,
    offsets: Range<UInt32>
) -> HyperlinkReferenceDelta {
    replace(headLineID: headLineID, offsets: offsets, with: nil)
}

mutating func insert(
    headLineID: UInt64,
    at offset: UInt32,
    count: UInt32,
    segmentEnd: UInt32
) -> HyperlinkReferenceDelta

mutating func delete(
    headLineID: UInt64,
    at offset: UInt32,
    count: UInt32,
    segmentEnd: UInt32
) -> HyperlinkReferenceDelta
```

For `insert`, discard `segmentEnd - count..<segmentEnd`, shift intersections in `offset..<segmentEnd - count` right, and leave offsets at or after `segmentEnd` unchanged. For `delete`, discard `offset..<offset + count`, shift `offset + count..<segmentEnd` left, clear the newly blank tail, and leave later wrapped segments unchanged. Normalize/coalesce and return net reference changes.

- [ ] **Step 4: Route every cell mutation through one coordinate resolver**

Add:

```swift
private func hyperlinkCoordinate(row: Int, column: Int) -> (
    headLineID: UInt64,
    offset: UInt32,
    segmentEnd: UInt32
)?
```

Use it from `eraseLine`, `eraseChars`, `eraseDisplay`, `insertChars`, `deleteChars`, `clearWideOrphan`, and ordinary `print`. Apply hyperlink transforms before Grid moves/clears cells. When no active target exists and the stable physical row is absent from `rowIndex`, return before logical-line scanning. Clip a row entering scrollback to `ScrollbackLine.count` so trimmed blank cells cannot retain metadata.

- [ ] **Step 5: Run full tests and commit**

Run `swift test`. Expected: all suites pass.

```bash
git add Sources/TerminalCore/HyperlinkStore.swift Sources/TerminalCore/Terminal.swift Tests/TerminalCoreTests/OSC8HyperlinkTests.swift
git commit -m "fix(core): 让链接范围跟随终端 cell 编辑" -m "集中处理覆写、擦除和字符插删，避免 OSC 8 元数据指向已经改变的文本。" -m "Refs #66"
```

---

### Task 4: 行移动、备用屏、scrollback 与 reflow

**Files:**
- Modify: `Sources/TerminalCore/HyperlinkStore.swift`
- Modify: `Sources/TerminalCore/Terminal.swift`
- Modify: `Tests/TerminalCoreTests/OSC8HyperlinkTests.swift`
- Modify: `Tests/TerminalCoreTests/ReflowTests.swift`

**Interfaces:**
- Consumes: Tasks 2–3 sparse ranges and cell transforms.
- Produces: physical-fragment transactions, screen-specific range ownership, ring pruning/rebasing, and reflow preservation.

- [ ] **Step 1: Add failing line-move, screen, ring and reflow tests**

Append:

```swift
@Test("局部 IL/DL 搬移链接且不写入 scrollback")
func regionalLineMovesPreserveLinks() {
    var (parser, terminal) = makeTerminal(columns: 10, rows: 4)
    feed("top\r\n\u{1B}]8;;https://a.test\u{07}link\u{1B}]8;;\u{07}", &parser, &terminal)
    feed("\u{1B}[2;4r\u{1B}[2;1H\u{1B}[L", &parser, &terminal)
    #expect(terminal.link(at: .init(line: 2, column: 1))?.target == "https://a.test")
    #expect(terminal.scrollback.count == 0)
    feed("\u{1B}[M", &parser, &terminal)
    #expect(terminal.link(at: .init(line: 1, column: 1))?.target == "https://a.test")
}

@Test("主屏范围跨备用屏恢复，活动目标保持")
func alternateScreenKeepsSeparateRanges() {
    var (parser, terminal) = makeTerminal(columns: 12, rows: 3)
    feed("\u{1B}]8;;https://active.test\u{07}main\u{1B}[?1049halt\u{1B}[?1049lX\u{1B}]8;;\u{07}", &parser, &terminal)
    #expect(terminal.link(at: .init(line: 0, column: 1))?.target == "https://active.test")
    #expect(terminal.link(at: .init(line: 0, column: 4))?.target == "https://active.test")
}

@Test("环淘汰最终释放显式链接记录")
func ringEvictionPrunesRecords() {
    var (parser, terminal) = makeTerminal(columns: 5, rows: 2, scrollback: 2)
    feed("\u{1B}]8;;https://a.test\u{07}abcdefghij\u{1B}]8;;\u{07}\r\n", &parser, &terminal)
    feed("one\r\ntwo\r\nthree\r\nfour\r\n", &parser, &terminal)
    #expect(terminal.explicitHyperlinkRecordCount == 0)
}

@Test("反向索引与 CSI T 向下滚动时搬移链接")
func downwardScrollMovesLinks() {
    var (parser, terminal) = makeTerminal(columns: 10, rows: 4)
    feed("\r\n\u{1B}]8;;https://a.test\u{07}link\u{1B}]8;;\u{07}\u{1B}[1;1H\u{1B}M", &parser, &terminal)
    #expect(terminal.link(at: .init(line: 2, column: 1))?.target == "https://a.test")
    feed("\u{1B}[T", &parser, &terminal)
    #expect(terminal.link(at: .init(line: 3, column: 1))?.target == "https://a.test")
}

@Test("ED 3 清除历史链接但保留屏幕链接")
func clearScrollbackRemovesOnlyHistoryRanges() {
    var (parser, terminal) = makeTerminal(columns: 10, rows: 2)
    feed("\u{1B}]8;;https://old.test\u{07}old\u{1B}]8;;\u{07}\r\nnext\r\n", &parser, &terminal)
    feed("\u{1B}]8;;https://screen.test\u{07}screen\u{1B}]8;;\u{07}\u{1B}[3J", &parser, &terminal)
    #expect(terminal.scrollback.count == 0)
    #expect(terminal.link(at: .init(line: 1, column: 1))?.target == "https://screen.test")
}
```

Add to `ReflowTests`:

```swift
@Test("OSC 8 逻辑偏移随变窄和变宽 reflow 保持")
func hyperlinkSurvivesReflow() throws {
    var (parser, terminal) = makeTerminal(columns: 20, rows: 4)
    feed("xx\u{1B}]8;;https://a.test\u{07}abcdefghijklmnop\u{1B}]8;;\u{07}", &parser, &terminal)
    terminal.resize(to: TerminalSize(columns: 8, rows: 4))
    #expect(try #require(terminal.link(at: .init(line: 1, column: 2))).target == "https://a.test")
    terminal.resize(to: TerminalSize(columns: 30, rows: 4))
    #expect(try #require(terminal.link(at: .init(line: 0, column: 5))).target == "https://a.test")
}
```

- [ ] **Step 2: Run RED**

Run `swift test --filter OSC8HyperlinkTests` and `swift test --filter ReflowTests.hyperlinkSurvivesReflow`.

Expected: line movement, alternate restore, ring pruning, and reflow assertions fail.

- [ ] **Step 3: Implement physical-fragment transactions**

Add:

```swift
struct PhysicalHyperlinkFragment: Sendable, Equatable {
    var row: Int
    var columns: Range<Int>
    var target: String
}

private mutating func moveHyperlinkRows(
    in rows: ClosedRange<Int>,
    destinationForSource: (Int) -> Int?,
    mutateGrid: () -> Void
)
```

Return immediately when no sparse row index intersects the affected stable IDs. Otherwise project linked portions to fragments with copied targets, remove them, run `mutateGrid`, map rows through `destinationForSource`, clip columns, and reinsert using destination `RowInfo.wrapped`. Use the same mappings as Grid for partial `scrollUp`, every `scrollDown`, `insertLines`, and `deleteLines`.

Keep full-screen primary upward scroll specialized: stable content IDs do not change. After appending the evicted line, clip to its stored count and prune before the new oldest retained ID without projecting all live ranges.

- [ ] **Step 4: Implement alternate ownership and ring rebasing**

On entry, save primary ranges and start an empty alternate range store. On exit, release alternate span references and restore primary ranges; keep the active target unchanged. RIS clears target, active and both stores.

Add `pruneHyperlinks(before:)`. Drop fully evicted records. If a record head is gone but a linked wrapped fragment survives, find the new retained logical head, subtract the evicted prefix offset, update its head ID, clip spans, and rebuild anchors. Release all dropped target references and nil empty optionals.

- [ ] **Step 5: Remap records in streaming reflow**

For each existing logical-line loop, remove the record keyed by the source head ID into a local. The emitted chunks already track logical `start`/`end`; attach unchanged clipped offsets to the first emitted row ID. After assigning new `grid` and `scrollback`, apply retained-prefix rebasing and rebuild sparse anchors. If no range store exists, do not build any hyperlink locals or maps.

- [ ] **Step 6: Run full tests and commit**

Run `swift test`. Expected: all tests pass, including existing 8-byte `Cell` and 2-byte `RowInfo` assertions.

```bash
git add Sources/TerminalCore/HyperlinkStore.swift Sources/TerminalCore/Terminal.swift Tests/TerminalCoreTests/OSC8HyperlinkTests.swift Tests/TerminalCoreTests/ReflowTests.swift
git commit -m "fix(core): 在滚屏与 reflow 中保留链接坐标" -m "按物理行变换稀疏片段，并在环淘汰头行时重定位逻辑范围。" -m "Refs #66"
```

---

### Task 5: 悬停范围投影与 Metal 下划线

**Files:**
- Create: `Sources/InkTerminalView/TerminalLinkHighlights.swift`
- Modify: `Sources/InkTerminalView/TerminalRenderer.swift`
- Create: `Tests/InkTerminalViewTests/TerminalLinkHighlightTests.swift`

**Interfaces:**
- Consumes: `TerminalLink.range`, viewport offset, existing cell instance underline flag.
- Produces: `TerminalLinkHighlightSpan`, `TerminalLinkHighlights.project`, renderer parameter `hoveredLinkRange`.

- [ ] **Step 1: Write failing half-open viewport projection tests**

```swift
import Testing
import TerminalCore
@testable import InkTerminalView

@Suite("链接悬停投影")
struct TerminalLinkHighlightTests {
    @Test("半开跨行范围投影到 viewport")
    func projectsHalfOpenRange() {
        let spans = TerminalLinkHighlights.project(
            range: SemanticTextRange(
                start: TextPosition(line: 4, column: 7),
                end: TextPosition(line: 6, column: 3)
            ),
            scrollbackCount: 8,
            gridRows: 4,
            scrollOffset: 4,
            columns: 10
        )
        #expect(spans == [
            .init(visualRow: 0, columns: 7...9),
            .init(visualRow: 1, columns: 0...9),
            .init(visualRow: 2, columns: 0...2),
        ])
    }

    @Test("end 第零列不高亮下一行")
    func excludesZeroColumnEnd() {
        let spans = TerminalLinkHighlights.project(
            range: SemanticTextRange(start: .init(line: 4, column: 2), end: .init(line: 5, column: 0)),
            scrollbackCount: 4,
            gridRows: 2,
            scrollOffset: 0,
            columns: 8
        )
        #expect(spans == [.init(visualRow: 0, columns: 2...7)])
    }
}
```

- [ ] **Step 2: Run RED**

Run `swift test --filter TerminalLinkHighlightTests`.

Expected: compilation fails because the projector does not exist.

- [ ] **Step 3: Implement projection and specialized lookup**

Create:

```swift
struct TerminalLinkHighlightSpan: Sendable, Equatable {
    let visualRow: Int
    let columns: ClosedRange<Int>
}

enum TerminalLinkHighlights {
    static func project(
        range: SemanticTextRange?,
        scrollbackCount: Int,
        gridRows: Int,
        scrollOffset: Int,
        columns: Int
    ) -> [TerminalLinkHighlightSpan]
}
```

Treat `end` as exclusive: if `end.column == 0`, final line is `end.line - 1`; otherwise final column is `end.column - 1`. Clip to viewport and `0..<columns`.

In `TerminalRenderer`, add `NoLinkHighlightLookup` and `SpanLinkHighlightLookup` mirroring search lookup. Extend `render` with `hoveredLinkRange: SemanticTextRange? = nil`, project once, and dispatch to the no-link specialization when empty. In the inner loop, set the existing underline flag and keep blank linked cells from being skipped. Do not add a shader flag, pass, buffer or draw call.

- [ ] **Step 4: Run tests and commit**

Run `swift test --filter TerminalLinkHighlightTests`, then `swift test --filter InkTerminalViewTests`.

```bash
git add Sources/InkTerminalView/TerminalLinkHighlights.swift Sources/InkTerminalView/TerminalRenderer.swift Tests/InkTerminalViewTests/TerminalLinkHighlightTests.swift
git commit -m "feat(view): 为悬停链接绘制下划线" -m "把逻辑范围投影为可见 cell，并复用现有实例 flag 保持单次 draw call。" -m "Refs #66"
```

---

### Task 6: 鼠标交互、链接菜单与 Shell 打开动作

**Files:**
- Create: `Sources/InkTerminalView/TerminalLinkInteraction.swift`
- Modify: `Sources/InkTerminalView/TerminalMetalView.swift`
- Modify: `Sources/InkShell/TerminalWorkspaceViewController.swift`
- Create: `Tests/InkTerminalViewTests/TerminalLinkInteractionTests.swift`

**Interfaces:**
- Consumes: `Terminal.link(at:)`, Task 5 renderer range, existing `reportMouse` and `pasteboardWriter`.
- Produces: `TerminalMetalView.onOpenLink: ((URL) -> Void)?`, injectable menu presenter, native gesture precedence.

- [ ] **Step 1: Write failing pure decision and payload tests**

```swift
import AppKit
import Testing
import TerminalCore
@testable import InkTerminalView

@Suite("终端链接交互")
@MainActor
struct TerminalLinkInteractionTests {
    @Test("鼠标上报时普通右键上报，Option 右键开原生菜单")
    func routesContextClick() {
        #expect(LinkMouseRouter.contextAction(mouseReporting: true, optionHeld: false) == .reportToTUI)
        #expect(LinkMouseRouter.contextAction(mouseReporting: true, optionHeld: true) == .showNativeMenu)
        #expect(LinkMouseRouter.contextAction(mouseReporting: false, optionHeld: false) == .showNativeMenu)
    }

    @Test("只有绝对 URL 可打开，任意目标仍可复制")
    func validatesOpenableTargets() {
        #expect(TerminalLinkMenuPayload(target: "https://example.test").url?.scheme == "https")
        #expect(TerminalLinkMenuPayload(target: "relative/path").url == nil)
        #expect(TerminalLinkMenuPayload(target: "relative/path").target == "relative/path")
    }

    @Test("菜单载荷不随终端更新改变")
    func payloadIsStable() {
        let payload = TerminalLinkMenuPayload(target: "https://old.test")
        var terminal = Terminal(size: TerminalSize(columns: 20, rows: 2))
        var parser = Parser()
        parser.feed(Array("https://new.test".utf8), handler: &terminal)
        #expect(payload.target == "https://old.test")
    }
}
```

- [ ] **Step 2: Run RED**

Run `swift test --filter TerminalLinkInteractionTests`.

Expected: compilation fails because router and payload do not exist.

- [ ] **Step 3: Implement pure routing and immutable payload**

Create:

```swift
import Foundation

enum LinkContextAction: Sendable, Equatable {
    case reportToTUI
    case showNativeMenu
}

enum LinkMouseRouter {
    static func contextAction(mouseReporting: Bool, optionHeld: Bool) -> LinkContextAction {
        mouseReporting && !optionHeld ? .reportToTUI : .showNativeMenu
    }
}

struct TerminalLinkMenuPayload: Sendable, Equatable {
    let target: String

    var url: URL? {
        guard let url = URL(string: target), url.scheme?.isEmpty == false else { return nil }
        return url
    }
}
```

- [ ] **Step 4: Add tracking, hover refresh, Command click and link menu**

Add to `TerminalMetalView`:

```swift
public var onOpenLink: ((URL) -> Void)?
var contextMenuPresenter: (NSMenu, NSEvent, NSView) -> Void = {
    NSMenu.popUpContextMenu($0, with: $1, for: $2)
}
private var linkTrackingArea: NSTrackingArea?
private var hoveredLink: TerminalLink?
private var hoveredCell: TextPosition?
private var hoverNeedsRefresh = true
```

Override `updateTrackingAreas` with `.mouseMoved`, `.mouseEnteredAndExited`, `.activeInKeyWindow`, `.inVisibleRect`. Refactor `hitPosition` to share a point-based helper. `mouseMoved` resolves only after the cell changes; `mouseExited` clears hover. `markDirty` sets `hoverNeedsRefresh`; before each dirty render, `frameTick` re-resolves the current window mouse location and passes `hoveredLink?.range` to Task 5 renderer. Invalidate cursor rects on link changes and use `.pointingHand` only for a current link.

Before existing left-button `reportMouse`, add:

```swift
if event.modifierFlags.contains(.command),
   let link = link(at: event),
   let url = TerminalLinkMenuPayload(target: link.target).url,
   let onOpenLink {
    onOpenLink(url)
    return
}
```

For right mouse down, use `LinkMouseRouter`. The TUI branch calls existing `reportMouse` with button 2. The native branch resolves a link and creates “打开链接” plus “复制链接”; disable open for a non-absolute target. Store only the immutable target string in each `representedObject`. Action methods read that string, use `onOpenLink` or `pasteboardWriter`, and never re-query terminal coordinates. A native miss creates no menu. Right mouse up reports only for the TUI branch.

Expose an internal read-only `hoveredLinkForTesting` property, then append these window-backed tests and helpers:

```swift
@Test("Command 点击链接优先于 TUI 鼠标上报")
func commandClickOpensLink() throws {
    var terminal = linkedTerminal(mouseReporting: true)
    let (window, view) = makeWindowView(terminal: { terminal })
    var opened: URL?
    var input = Data()
    view.onOpenLink = { opened = $0 }
    view.onInput = { input.append($0) }

    view.mouseDown(with: try event(.leftMouseDown, in: window, modifiers: [.command]))
    #expect(opened?.absoluteString == "https://example.test")
    #expect(input.isEmpty)
    _ = window
}

@Test("Option 右键弹链接菜单，普通右键仍发给 TUI")
func optionContextMenuOverridesMouseReporting() throws {
    let terminal = linkedTerminal(mouseReporting: true)
    let (window, view) = makeWindowView(terminal: { terminal })
    var shownMenu: NSMenu?
    var input = Data()
    view.contextMenuPresenter = { menu, _, _ in shownMenu = menu }
    view.onInput = { input.append($0) }

    view.rightMouseDown(with: try event(.rightMouseDown, in: window, modifiers: []))
    #expect(!input.isEmpty)
    #expect(shownMenu == nil)

    view.rightMouseDown(with: try event(.rightMouseDown, in: window, modifiers: [.option]))
    #expect(shownMenu?.items.map(\.title) == ["打开链接", "复制链接"])
}

@Test("复制动作使用菜单创建时的目标")
func copyUsesCapturedTarget() throws {
    var terminal = linkedTerminal(mouseReporting: false)
    let (window, view) = makeWindowView(terminal: { terminal })
    var shownMenu: NSMenu?
    var copied = ""
    view.contextMenuPresenter = { menu, _, _ in shownMenu = menu }
    view.pasteboardWriter = { copied = $0; return true }
    view.rightMouseDown(with: try event(.rightMouseDown, in: window, modifiers: []))
    let copyItem = try #require(shownMenu?.items.last)

    var parser = Parser()
    terminal = Terminal(size: TerminalSize(columns: 40, rows: 3))
    parser.feed(Array("https://new.test".utf8), handler: &terminal)
    view.copyLink(copyItem)
    #expect(copied == "https://example.test")
}

@Test("鼠标移动解析并保存完整悬停范围")
func hoverResolvesLink() throws {
    let terminal = linkedTerminal(mouseReporting: false)
    let (window, view) = makeWindowView(terminal: { terminal })
    view.mouseMoved(with: try event(.mouseMoved, in: window, modifiers: []))
    #expect(view.hoveredLinkForTesting?.target == "https://example.test")
    #expect(view.hoveredLinkForTesting?.range.start == TextPosition(line: 0, column: 0))
}

private func linkedTerminal(mouseReporting: Bool) -> Terminal {
    var terminal = Terminal(size: TerminalSize(columns: 40, rows: 3))
    var parser = Parser()
    let mode = mouseReporting ? "\u{1B}[?1000h" : ""
    parser.feed(Array((mode + "https://example.test").utf8), handler: &terminal)
    return terminal
}

private func makeWindowView(
    terminal: @escaping () -> Terminal
) -> (NSWindow, TerminalMetalView) {
    let window = NSWindow(
        contentRect: NSRect(x: 0, y: 0, width: 640, height: 240),
        styleMask: [.titled], backing: .buffered, defer: false
    )
    let view = TerminalMetalView(frame: window.contentView!.bounds)
    view.terminalProvider = terminal
    window.contentView = view
    view.layoutSubtreeIfNeeded()
    return (window, view)
}

private func event(
    _ type: NSEvent.EventType,
    in window: NSWindow,
    modifiers: NSEvent.ModifierFlags
) throws -> NSEvent {
    try #require(NSEvent.mouseEvent(
        with: type,
        location: NSPoint(x: 12, y: 12),
        modifierFlags: modifiers,
        timestamp: 0,
        windowNumber: window.windowNumber,
        context: nil,
        eventNumber: 1,
        clickCount: 1,
        pressure: 0
    ))
}
```

- [ ] **Step 5: Inject NSWorkspace at Shell boundary**

In `TerminalWorkspaceViewController.makeView`:

```swift
terminalView.onOpenLink = { url in
    NSWorkspace.shared.open(url)
}
```

In `clearViews`, nil `onOpenLink`. Confirm `rg -n "NSWorkspace" Sources/TerminalCore Sources/InkTerminalView` prints nothing.

- [ ] **Step 6: Run tests/build and commit**

Run `swift test --filter TerminalLinkInteractionTests`, `swift test`, then `swift build`.

Expected: all tests pass and build emits no warnings.

```bash
git add Sources/InkTerminalView/TerminalLinkInteraction.swift Sources/InkTerminalView/TerminalMetalView.swift Sources/InkShell/TerminalWorkspaceViewController.swift Tests/InkTerminalViewTests/TerminalLinkInteractionTests.swift
git commit -m "feat: 增加链接点击与原生右键入口" -m "Command 点击和显式 Option 右键提供原生操作，同时保留 TUI 鼠标上报语义。" -m "Refs #66"
```

---

### Task 7: 性能采样、真实应用验证与交付

**Files:**
- Modify: `Sources/ink-bench/main.swift`
- Modify: `docs/perf.md`

**Interfaces:**
- Consumes: completed Core/View feature and existing benchmark helpers.
- Produces: reproducible plain/sparse profiles, Instruments evidence, final PR and merged main verification.

- [ ] **Step 1: Add deterministic benchmark modes**

Add:

```swift
enum LinkProfile: String {
    case plain
    case sparseOSC8 = "sparse-osc8"
}

let linkProfile = CommandLine.arguments.dropFirst().first.flatMap(LinkProfile.init(rawValue:))
```

When a profile exists, run 1,000,000 fixed-width lines and exit before existing scenarios. `plain` emits printable text without OSC. `sparse-osc8` wraps every 1,000th line with `OSC 8;;https://example.test/<line> BEL`, text, and an empty OSC 8 close. Print elapsed time, MB/s and footprint delta. Do not impose a throughput test threshold because machine load varies; the `@testable` Core test remains the authoritative zero-metadata assertion.

- [ ] **Step 2: Run Release profiles and Time Profiler**

```bash
swift build -c release
.build/release/ink-bench plain | tee /tmp/ink-links-issue66-plain.txt
.build/release/ink-bench sparse-osc8 | tee /tmp/ink-links-issue66-sparse.txt
xcrun xctrace record --template "Time Profiler" --time-limit 20s --output /tmp/ink-links-issue66-plain.trace --launch -- .build/release/ink-bench plain
xcrun xctrace export --input /tmp/ink-links-issue66-plain.trace --xpath '/trace-toc/run[@number="1"]/data/table[@schema="time-profile"]' --output /tmp/ink-links-issue66-plain.xml
rg "TerminalURLDetector|logicalLine\(containing|HyperlinkRangeStore" /tmp/ink-links-issue66-plain.xml
```

Expected: both processes complete; the final `rg` returns no sampled URL detector, logical-line materialization or range-store frames for the plain profile. A missing sample is evidence only for this run, not a proof of zero cost.

- [ ] **Step 3: Record exact evidence**

Append `## URL / OSC 8 链接旁路` to `docs/perf.md`: date, hardware/macOS, exact output values, trace paths, sampled hot stacks and the `rg` result. Confirm `Cell`/`RowInfo` sizes and state that only actual OSC 8 ranges allocate metadata. Do not copy estimates or claim results not present in the artifacts.

- [ ] **Step 4: Run final automated verification**

```bash
swift test
swift build
git diff --check origin/main...HEAD
git status --short --branch
```

Expected: full test run has zero failures; build succeeds without warnings; diff check is empty; worktree is clean and only ahead of `origin/main`.

- [ ] **Step 5: Run signed real-app smoke test**

Package a temporary debug app using the established ad-hoc workflow with a unique bundle ID. In a real Ink window verify:

1. `https://example.test/a_(b)` shows pointing hand and underline.
2. Command click invokes the browser handler.
3. `printf '\e]8;;https://openai.com\aOpenAI\e]8;;\a\n'` creates an OSC 8 label.
4. Right-click copies the exact target.
5. In a mouse-reporting TUI, plain right-click reaches the TUI and `Option + 右键` opens Ink's menu.
6. Narrow/wide resize and scrolling into history preserve hover/copy.

Capture notes/screenshots, then remove only the temporary app. Do not alter the user's installed Ink app.

- [ ] **Step 6: Commit benchmark evidence**

```bash
git add Sources/ink-bench/main.swift docs/perf.md
git commit -m "perf: 记录终端链接旁路开销" -m "用独立无链接与稀疏 OSC 8 负载验证冷路径没有进入普通输出采样。" -m "Refs #66"
```

- [ ] **Step 7: Review and verify before PR**

Invoke `superpowers:verification-before-completion` and `superpowers:requesting-code-review`. Check every Issue #66 acceptance item and every design-spec section against code, tests, benchmark artifacts and real-app evidence. Fix every P0/P1 finding and rerun affected tests plus `swift test` and `swift build`.

- [ ] **Step 8: Push and create the closing PR**

```bash
git push -u origin agent/issue-66-terminal-links
gh pr create --base main --head agent/issue-66-terminal-links --title "feat: URL 与 OSC 8 超链接" --body "实现 URL/OSC 8、链接交互与稀疏范围同步；验证包含全量测试、构建、Release benchmark、Time Profiler 和真实应用 smoke test。文档已更新，不涉及发布。 Closes #66"
```

Expected: GitHub returns a PR URL targeting `main`; Issue #66 remains open until merge.

- [ ] **Step 9: Merge only after checks and owner approval**

Run `gh pr checks --watch` and `gh pr view --json state,mergeStateStatus,reviewDecision,statusCheckRollup`. After checks pass and the owner approves, squash merge and delete the remote branch. Pull `main`, confirm Issue #66 closed, rerun `swift test` and `swift build` on merged main, remove the feature worktree and local branch, then select the next roadmap item. Do not create a tag or release.
