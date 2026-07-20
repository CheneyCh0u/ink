# Current Pane Terminal Search Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add `Command-F` search for the focused terminal pane across scrollback and the current screen, with result counts, cyclic navigation, pane-local scrolling, and UI-compatible Metal highlights.

**Architecture:** `TerminalCore` owns Unicode-aware row search and an incremental suffix cache. `InkTerminalView` owns viewport projection, scrolling, and one-pass Metal highlighting. `InkShell` owns the pane overlay, focus routing, query state, and coalesced live updates. Search state is transient and exists only while one pane search bar is open.

**Tech Stack:** Swift 6, Foundation, AppKit, SwiftUI shell conventions, Metal, CoreText, Swift Testing, SwiftPM, macOS 14+

## Global Constraints

- `TerminalCore` must not import AppKit or Metal.
- Do not add third-party dependencies.
- Do not add per-cell or per-line persistent search fields.
- Closing search must release matches and remove search work from the render path.
- Keep one Metal draw call per frame.
- Search is case-insensitive literal text, not regex or fuzzy matching.
- Search scope is the focused pane's scrollback plus active grid only.
- Soft-wrapped rows form one searchable logical line; hard newlines do not.
- User selection wins over search highlight.
- The overlay must not change `TerminalMetalView` frame or PTY grid size.
- Comments and docs are Chinese; identifiers are English.
- Commits use Chinese Conventional Commit summaries and `Refs #31` in the body.
- Final UI validation belongs to the user. The agent only runs automated checks, builds, and launches a separate temporary app.

---

## File Map

- Create `Sources/TerminalCore/TerminalSearch.swift`: match model, logical-line extraction, full scan, and incremental `TerminalSearchIndex`.
- Modify `Sources/TerminalCore/ScrollbackBuffer.swift`: buffer-level append counter only.
- Modify `Sources/TerminalCore/Terminal.swift`: search layout revision for reflow/screen replacement.
- Create `Tests/TerminalCoreTests/TerminalSearchTests.swift`: search correctness and incremental invalidation.
- Modify `Sources/InkDesign/InkTerminalPalette.swift`: semantic search accent snapshots.
- Create `Sources/InkTerminalView/TerminalSearchHighlights.swift`: viewport row spans used by the renderer.
- Modify `Sources/InkTerminalView/CellInstance.swift`: current-match edge flag and uniform color.
- Modify `Sources/InkTerminalView/Shaders.metal`: one-pass current-match bottom edge.
- Modify `Sources/InkTerminalView/TerminalRenderer.swift`: row-span highlight blending and selection priority.
- Modify `Sources/InkTerminalView/TerminalMetalView.swift`: search results, viewport projection, and reveal scrolling.
- Create `Tests/InkTerminalViewTests/TerminalSearchHighlightTests.swift`: projection, scrolling, and priority seams.
- Create `Sources/InkShell/TerminalSearchBarView.swift`: AppKit overlay and keyboard/button callbacks.
- Create `Sources/InkShell/TerminalSearchController.swift`: pane-local query, incremental index, selection preservation, and coalesced refresh.
- Modify `Sources/InkShell/TerminalWorkspaceViewController.swift`: one active search overlay and lifecycle cleanup.
- Modify `Sources/InkShell/MainWindowController.swift`: menu action, active pane routing, and output refresh hook.
- Modify `Sources/InkShell/AppDelegate.swift`: Edit menu `Command-F` item.
- Create `Tests/InkShellTests/TerminalSearchBarTests.swift`: counter/button/command behavior.
- Create `Tests/InkShellTests/TerminalSearchWorkspaceTests.swift`: pane isolation, focus, cleanup, and live update.
- Modify `Sources/ink-bench/main.swift`: 100k-line search timing and transient memory output.
- Modify `docs/perf.md`: record the measured search result.

---

### Task 1: Unicode-aware TerminalCore full search

**Files:**
- Create: `Sources/TerminalCore/TerminalSearch.swift`
- Create: `Tests/TerminalCoreTests/TerminalSearchTests.swift`

**Interfaces:**
- Produces: `TerminalSearchMatch`, `TerminalSearchEngine.search(in:query:fromLine:)`.
- Consumes: `Terminal.absoluteLine(_:)`, `Cell`, `ClusterTable`, `RowInfo.isWrapped`, `TextPosition`, `SelectionRange`.

- [ ] **Step 1: Write failing full-search tests**

Add tests that build terminals through `Parser`, then assert exact cell coordinates:

```swift
@Suite("终端历史搜索")
struct TerminalSearchTests {
    @Test("忽略大小写并按旧到新返回")
    func caseInsensitiveOrdering() {
        var parser = Parser()
        var terminal = Terminal(size: TerminalSize(columns: 12, rows: 3), scrollbackCapacity: 20)
        parser.feed(Array("Alpha\r\nbeta ALPHA".utf8), handler: &terminal)

        let matches = TerminalSearchEngine.search(in: terminal, query: "alpha")

        #expect(matches.map(\.range) == [
            SelectionRange(start: TextPosition(line: 0, column: 0), end: TextPosition(line: 0, column: 4)),
            SelectionRange(start: TextPosition(line: 1, column: 5), end: TextPosition(line: 1, column: 9)),
        ])
    }

    @Test("软折行可跨行匹配但硬换行不跨越")
    func wrapBoundarySemantics() {
        var parser = Parser()
        var terminal = Terminal(size: TerminalSize(columns: 4, rows: 4), scrollbackCapacity: 20)
        parser.feed(Array("abcdef\r\nab\r\ncd".utf8), handler: &terminal)

        #expect(TerminalSearchEngine.search(in: terminal, query: "def").count == 1)
        #expect(TerminalSearchEngine.search(in: terminal, query: "abcd").isEmpty)
    }

    @Test("宽字符和组合簇映射回完整 cell")
    func unicodeCellMapping() {
        var parser = Parser()
        var terminal = Terminal(size: TerminalSize(columns: 16, rows: 2), scrollbackCapacity: 20)
        parser.feed(Array("A终e\u{0301}Z".utf8), handler: &terminal)

        let matches = TerminalSearchEngine.search(in: terminal, query: "终e\u{0301}")

        #expect(matches == [TerminalSearchMatch(range: SelectionRange(
            start: TextPosition(line: 0, column: 1),
            end: TextPosition(line: 0, column: 3)
        ))])
    }
}
```

- [ ] **Step 2: Run the focused tests and confirm red**

Run: `swift test --filter TerminalSearchTests`

Expected: compile failure because `TerminalSearchEngine` and `TerminalSearchMatch` do not exist.

- [ ] **Step 3: Implement logical-line scanning**

Create these exact public interfaces:

```swift
import Foundation

public struct TerminalSearchMatch: Sendable, Equatable {
    public let range: SelectionRange

    public init(range: SelectionRange) {
        self.range = range
    }
}

public enum TerminalSearchEngine {
    public static func search(
        in terminal: Terminal,
        query: String,
        fromLine: Int = 0
    ) -> [TerminalSearchMatch]
}
```

Inside `search`, stream one logical line at a time. For every visible cell, append its scalar or cluster text to a temporary `String` and record its UTF-16 offset with the starting and ending `TextPosition`. Skip `wideTrailing`, include internal blanks, trim only trailing blank cells, and join a following row only when that following row has `isWrapped == true`. Use `NSString.range(of:options:range:)` with `.caseInsensitive`, advance by the full result length, and map the returned UTF-16 endpoints back to cell positions. Return non-overlapping matches ordered by start position.

- [ ] **Step 4: Add empty, repeated, emoji, and scrollback coverage**

Add exact assertions for empty query returning `[]`, `aaaa` / `aa` returning columns `0...1` and `2...3`, a ZWJ emoji cluster returning its owner cell, and results spanning both a scrollback row and grid row.

- [ ] **Step 5: Run tests and commit**

Run: `swift test --filter TerminalSearchTests`

Expected: all `TerminalSearchTests` pass.

Commit:

```bash
git add Sources/TerminalCore/TerminalSearch.swift Tests/TerminalCoreTests/TerminalSearchTests.swift
git commit -m "feat(core): 增加终端历史文本搜索" -m "按逻辑行映射 Unicode 文本到 cell 坐标，支持软折行且不污染 grid 常驻结构。" -m "Refs #31"
```

---

### Task 2: Incremental search index and buffer revisions

**Files:**
- Modify: `Sources/TerminalCore/ScrollbackBuffer.swift`
- Modify: `Sources/TerminalCore/Terminal.swift`
- Modify: `Sources/TerminalCore/TerminalSearch.swift`
- Modify: `Tests/TerminalCoreTests/TerminalSearchTests.swift`

**Interfaces:**
- Produces: `ScrollbackBuffer.totalAppendedLines`, `Terminal.searchLayoutRevision`, `TerminalSearchIndex.update(in:query:)`.
- Consumes: Task 1 `TerminalSearchEngine.search(in:query:fromLine:)`.

- [ ] **Step 1: Write failing incremental tests**

Test that an unchanged query with one appended line reports `.incremental`, preserves prefix matches, finds a new suffix match, shifts coordinates after ring eviction, and reports `.full` after resize/reflow:

```swift
var index = TerminalSearchIndex()
let first = index.update(in: terminal, query: "hit")
#expect(index.lastUpdateKind == .full)
parser.feed(Array("new hit\r\n".utf8), handler: &terminal)
let second = index.update(in: terminal, query: "hit")
#expect(index.lastUpdateKind == .incremental)
#expect(second.count == first.count + 1)
terminal.resize(to: TerminalSize(columns: 6, rows: 3))
_ = index.update(in: terminal, query: "hit")
#expect(index.lastUpdateKind == .full)
```

- [ ] **Step 2: Run the focused tests and confirm red**

Run: `swift test --filter TerminalSearchTests`

Expected: compile failure because `TerminalSearchIndex` is missing.

- [ ] **Step 3: Add buffer-level counters**

Add `public private(set) var totalAppendedLines: UInt64 = 0` to `ScrollbackBuffer`; increment it once in `append`, and reset it in `removeAll`. Add `public private(set) var searchLayoutRevision: UInt64 = 0` to `Terminal`; increment it after main-screen reflow, alternate-screen resize, alternate-screen enter/leave, RIS, and any whole-buffer replacement. These are buffer-level values only.

- [ ] **Step 4: Implement the incremental suffix cache**

Create:

```swift
public struct TerminalSearchIndex: Sendable {
    enum UpdateKind: Equatable { case none, full, incremental }
    private(set) var lastUpdateKind: UpdateKind = .none
    public private(set) var matches: [TerminalSearchMatch] = []

    public init() {}

    @discardableResult
    public mutating func update(in terminal: Terminal, query: String) -> [TerminalSearchMatch]

    public mutating func clear()
}
```

On query/revision/counter reset, full scan. Otherwise calculate appended and evicted physical lines, shift surviving cached coordinates, find the earliest newly appended surviving line, rewind to the head of its logical wrapped line, remove cached matches from that line onward, and rescan that suffix through the current grid. Always include all grid rows in the rescan boundary so cursor-addressed screen rewrites are correct.

- [ ] **Step 5: Verify ring eviction and reflow**

Run: `swift test --filter TerminalSearchTests`

Expected: full-search and incremental tests pass, including capacity-3 eviction and resize cases.

- [ ] **Step 6: Commit**

```bash
git add Sources/TerminalCore/ScrollbackBuffer.swift Sources/TerminalCore/Terminal.swift Sources/TerminalCore/TerminalSearch.swift Tests/TerminalCoreTests/TerminalSearchTests.swift
git commit -m "perf(core): 增量更新终端搜索结果" -m "只重扫可变后缀与当前 grid，并用缓冲级代次处理淘汰和 reflow。" -m "Refs #31"
```

---

### Task 3: Viewport projection and one-pass Metal highlighting

**Files:**
- Modify: `Sources/InkDesign/InkTerminalPalette.swift`
- Create: `Sources/InkTerminalView/TerminalSearchHighlights.swift`
- Modify: `Sources/InkTerminalView/CellInstance.swift`
- Modify: `Sources/InkTerminalView/Shaders.metal`
- Modify: `Sources/InkTerminalView/TerminalRenderer.swift`
- Modify: `Sources/InkTerminalView/TerminalMetalView.swift`
- Create: `Tests/InkTerminalViewTests/TerminalSearchHighlightTests.swift`

**Interfaces:**
- Produces: `TerminalMetalView.setSearchResults(_:currentIndex:)`, `revealSearchResult(_:)`, and `clearSearchResults()`.
- Consumes: Task 1 `TerminalSearchMatch`.

- [ ] **Step 1: Write failing projection and scrolling tests**

Assert that a match above the viewport is absent from visible spans, a multi-row match is clipped into row spans, current result is marked, and revealing a historical result changes only `searchScrollOffset`/`scrollOffset` to center it. Add a test that applying/clearing search results does not change `currentGridSize` for a window-backed `TerminalMetalView`.

- [ ] **Step 2: Run focused tests and confirm red**

Run: `swift test --filter TerminalSearchHighlightTests`

Expected: compile failure because the search result methods and projection types are missing.

- [ ] **Step 3: Add semantic colors and visible spans**

Add `searchAccent` to `InkTerminalPalette`, using the existing light/dark accent family. Create internal value types:

```swift
struct TerminalSearchHighlightSpan: Equatable {
    let columns: ClosedRange<Int>
    let isCurrent: Bool
}

struct TerminalVisibleSearchHighlights: Equatable {
    var rows: [[TerminalSearchHighlightSpan]]
}
```

Build spans in `TerminalMetalView` only when results, current index, scroll offset, or grid size changes. Use binary search to skip matches ending before the viewport, stop after matches start below it, clip each match to visible rows and terminal columns, and sort spans by lower column.

- [ ] **Step 4: Blend search backgrounds in the renderer**

Extend `TerminalRenderer.render` and `buildInstances` with optional visible search rows. For each visual row, advance one span cursor as columns increase. Blend accent over resolved ANSI background with a weaker factor for ordinary matches and stronger factor for current. Apply user selection afterward so selection wins. Treat highlighted blank cells as drawable instances.

Add `CellInstance.searchCurrent = 1 << 7`, add `searchEdgeColor` to `Uniforms`, and draw a one-physical-pixel bottom edge in the existing fragment pass:

```metal
if (in.flags & FLAG_SEARCH_CURRENT) {
    float edge = 1.0 - 1.0 / u.cellSize.y;
    if (in.cellUV.y >= edge) { color = float4(u.searchEdgeColor.rgb, 1.0); }
}
```

- [ ] **Step 5: Add result control methods**

Implement:

```swift
public func setSearchResults(_ matches: [TerminalSearchMatch], currentIndex: Int?)
public func revealSearchResult(_ match: TerminalSearchMatch)
public func clearSearchResults()
```

`revealSearchResult` computes a centered target from the match start line and clamps to `0...scrollback.count`. It marks dirty but does not change selection or any other pane.

- [ ] **Step 6: Run tests and commit**

Run: `swift test --filter 'TerminalSearchHighlightTests|TerminalRendererTests'`

Expected: projection, priority, grid-size invariance, and renderer tests pass.

Commit:

```bash
git add Sources/InkDesign/InkTerminalPalette.swift Sources/InkTerminalView/TerminalSearchHighlights.swift Sources/InkTerminalView/CellInstance.swift Sources/InkTerminalView/Shaders.metal Sources/InkTerminalView/TerminalRenderer.swift Sources/InkTerminalView/TerminalMetalView.swift Tests/InkTerminalViewTests/TerminalSearchHighlightTests.swift
git commit -m "feat(terminal): 高亮并定位搜索结果" -m "只投影当前视口匹配，在原有 Metal pass 内绘制两级背景与当前结果底边。" -m "Refs #31"
```

---

### Task 4: Native pane search overlay and controller

**Files:**
- Create: `Sources/InkShell/TerminalSearchBarView.swift`
- Create: `Sources/InkShell/TerminalSearchController.swift`
- Modify: `Sources/InkShell/TerminalWorkspaceViewController.swift`
- Create: `Tests/InkShellTests/TerminalSearchBarTests.swift`
- Create: `Tests/InkShellTests/TerminalSearchWorkspaceTests.swift`

**Interfaces:**
- Produces: `TerminalWorkspaceViewController.showSearchForActivePane()`, `refreshSearch(for:)`, and `closeSearch()`.
- Consumes: Tasks 2 and 3 search index/result APIs.

- [ ] **Step 1: Write failing search bar tests**

Test `0 / 0`, `3 / 12`, button enablement, query callback, Enter next, Shift-Enter previous, Escape close, and `focusAndSelectQuery()`. Test that the bar's presence leaves the terminal view frame unchanged.

- [ ] **Step 2: Run focused tests and confirm red**

Run: `swift test --filter 'TerminalSearchBarTests|TerminalSearchWorkspaceTests'`

Expected: compile failure because search bar/controller types do not exist.

- [ ] **Step 3: Build the native overlay**

Create `TerminalSearchBarView` as an `NSVisualEffectView` using `.popover` and `.withinWindow`, with one `NSSearchField`, a non-editable counter label, and three borderless template-image buttons. Expose closures:

```swift
var onQueryChange: ((String) -> Void)?
var onPrevious: (() -> Void)?
var onNext: (() -> Void)?
var onClose: (() -> Void)?

func updateCounter(current: Int?, total: Int)
func focusAndSelectQuery()
```

Use `InkDesignTokens.Spacing.xs`, `Radius.control`, typography tokens, separator border, accessibility labels, and `Motion.stateDuration`. Intercept field editor commands through `NSControlTextEditingDelegate`; never forward Enter, Shift-Enter, or Escape to PTY.

- [ ] **Step 4: Implement pane search state**

Create `TerminalSearchController` with a weak pane/container reference, one `TerminalSearchIndex`, current query, matches, and current index. Query changes call `index.update`; initial selection minimizes vertical line distance from `TerminalMetalView`'s current viewport, with newer match as tie-breaker. Previous/next wrap modulo count. Refresh preserves the current range if present, otherwise selects the nearest remaining result.

Coalesce repeated terminal updates with one `DispatchQueue.main.async` pending flag, not a timeout. On refresh, update the bar counter and call `setSearchResults`; only explicit navigation calls `revealSearchResult`.

- [ ] **Step 5: Integrate one search into the workspace**

Add the bar as an overlay subview of `TerminalPaneContainerView`, top/trailing constrained by 8 points without changing terminal constraints. `TerminalWorkspaceViewController` stores at most one controller and implements:

```swift
@discardableResult func showSearchForActivePane() -> Bool
func refreshSearch(for paneID: PaneID)
func closeSearch()
```

Opening on another active pane closes the old controller first. `show`, `clear`, `clearViews`, and pane loss close search and clear Metal results.

- [ ] **Step 6: Run tests and commit**

Run: `swift test --filter 'TerminalSearchBarTests|TerminalSearchWorkspaceTests|TerminalWorkspaceTests'`

Expected: overlay, isolation, focus, cleanup, and existing workspace tests pass.

Commit:

```bash
git add Sources/InkShell/TerminalSearchBarView.swift Sources/InkShell/TerminalSearchController.swift Sources/InkShell/TerminalWorkspaceViewController.swift Tests/InkShellTests/TerminalSearchBarTests.swift Tests/InkShellTests/TerminalSearchWorkspaceTests.swift
git commit -m "feat(shell): 在当前 pane 显示搜索浮层" -m "搜索条不改变终端网格，同一标签只保留一个搜索状态并在生命周期变化时清理。" -m "Refs #31"
```

---

### Task 5: Command-F routing and live output refresh

**Files:**
- Modify: `Sources/InkShell/AppDelegate.swift`
- Modify: `Sources/InkShell/MainWindowController.swift`
- Modify: `Tests/InkShellTests/TerminalSplitCommandTests.swift`
- Modify: `Tests/InkShellTests/TerminalSearchWorkspaceTests.swift`

**Interfaces:**
- Produces: `MainWindowController.showTerminalSearch(_:)` and menu validation.
- Consumes: Task 4 workspace search methods.

- [ ] **Step 1: Write failing menu and routing tests**

Assert the Edit menu contains `搜索…`, selector `showTerminalSearch:`, key equivalent `f`, and `.command` mask. In a two-pane tab, activate the first then second pane and assert `Command-F` targets only the active pane. Assert settings mode disables search and output refresh for a non-search pane does not change the open search.

- [ ] **Step 2: Run focused tests and confirm red**

Run: `swift test --filter 'TerminalSplitCommandTests|TerminalSearchWorkspaceTests'`

Expected: selector/menu assertions fail.

- [ ] **Step 3: Add the menu action and lifecycle cleanup**

Add an Edit menu item after paste:

```swift
editMenu.addItem(.separator())
editMenu.addItem(
    withTitle: "搜索…",
    action: #selector(MainWindowController.showTerminalSearch(_:)),
    keyEquivalent: "f"
)
```

Implement `showTerminalSearch(_:)` to guard settings state and active terminal responder, then call `workspaceVC.showSearchForActivePane()`. `validateMenuItem` enables it only for an active pane. Close search before settings, tab switch, project switch, split tree reconstruction, tab/pane close, and window close.

- [ ] **Step 4: Connect live output**

In `startPane`'s `session.onUpdate`, after `markDirty`, call `workspaceVC.refreshSearch(for: pane.id)`. The workspace ignores non-search panes and coalesces repeated updates. Do not add another PTY callback or timer.

- [ ] **Step 5: Run tests and commit**

Run: `swift test --filter 'TerminalSplitCommandTests|TerminalSearchWorkspaceTests|SplitShortcutStateTests'`

Expected: Command-F routing, split shortcut coexistence, live count preservation, and cleanup tests pass.

Commit:

```bash
git add Sources/InkShell/AppDelegate.swift Sources/InkShell/MainWindowController.swift Tests/InkShellTests/TerminalSplitCommandTests.swift Tests/InkShellTests/TerminalSearchWorkspaceTests.swift
git commit -m "feat(shell): 用 Command-F 搜索聚焦 pane" -m "通过菜单路由当前终端，并把持续输出合并刷新到唯一搜索控制器。" -m "Refs #31"
```

---

### Task 6: Performance record, full verification, review, and user handoff

**Files:**
- Modify: `Sources/ink-bench/main.swift`
- Modify: `docs/perf.md`

**Interfaces:**
- Consumes all previous tasks.
- Produces measured performance evidence and a temporary user-validation app.

- [ ] **Step 1: Add a deterministic search benchmark section**

After building the existing 100k-line ASCII terminal, measure `TerminalSearchIndex.update(in:query:)` for a full query with known matches, one appended-line incremental refresh, and `clear()`. Print elapsed durations, match count, and footprint delta under the heading `Search 10 万行`.

- [ ] **Step 2: Run the Release benchmark and record facts**

Run: `swift run -c release ink-bench`

Expected: existing memory/reflow sections still print, plus non-empty search timings and match count. Copy the actual machine/date/build mode and numbers into `docs/perf.md`; do not state 120fps or latency guarantees not measured.

- [ ] **Step 3: Run all automated verification**

Run:

```bash
swift test
swift build -c release
git diff --check origin/main...HEAD
```

Expected: all tests pass, Release build succeeds without warnings, diff check is clean.

- [ ] **Step 4: Request final code review and fix blockers**

Review `origin/main...HEAD` for search coordinate correctness, hot-path work, lifecycle cleanup, AppKit focus, and Metal one-pass behavior. Fix every Critical/Important finding with a regression test, rerun focused tests, then rerun Step 3.

- [ ] **Step 5: Commit benchmark/docs changes**

```bash
git add Sources/ink-bench/main.swift docs/perf.md
git commit -m "perf(terminal): 记录十万行历史搜索开销" -m "用 Release 基准记录首次扫描、增量刷新和结果缓存，明确搜索关闭后的零成本边界。" -m "Refs #31"
```

- [ ] **Step 6: Build and launch only the temporary validation app**

Create the explicit temporary bundle `/private/tmp/ink-search-verify-31/Ink Search Verify.app`, copy `.build/debug/ink` into its `Contents/MacOS/ink`, use bundle identifier `com.cheneychou.ink.search-verify-31`, ad-hoc sign it, verify the signature, and launch that exact path. Before launch, confirm no `/Applications/Ink.app` process is started. Do not use Computer Use or press search controls; leave the clean window for the user.

- [ ] **Step 7: Commit, push, and open the PR only after user validation**

After the user reports the UI is correct, push `agent/issue-31-terminal-search`, create a PR titled `feat(terminal): 支持当前 pane 历史搜索`, include automated evidence and `Closes #31`, and leave it open unless the user separately asks to merge.
