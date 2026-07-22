# Terminal Search Enhancements Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** 为当前 pane 的增量终端搜索增加大小写切换、冻结选区范围，以及从 live OSC 133 命令块复制当前匹配所在命令输出。

**Architecture:** `TerminalCore` 用 `TerminalSearchOptions` 扩展现有搜索器，并用每批一份的 `TerminalSearchCoordinateSpace` 在 scrollback 环坐标与稳定行 ID 之间重映射。`TerminalSearchController` 继续拥有异步任务、generation 和当前结果，只增加会话级模式、冻结范围与结果坐标空间；`TerminalMetalView` 只暴露经过坐标校验的当前选区和冷路径剪贴板动作。搜索快照继续剥离 OSC 133 旁路，命令块只在 live Terminal 上解析。

**Tech Stack:** Swift 6 strict concurrency、Foundation NSString 搜索、AppKit 系统控件、swift-testing、SwiftPM；最低 macOS 14.0。

## Global Constraints

- `TerminalCore` 不得引入 AppKit 或 Metal。
- 默认搜索忽略大小写；模式只活在当前 pane 的当前搜索会话，关闭即释放。
- 仅搜索选区冻结开启瞬间的非空选区；layout revision 变化或端点淘汰后自动退出。
- 复制匹配所在命令输出必须从 live Terminal 的 OSC 133 命令块解析，禁止让搜索快照保留命令旁路。
- 保持增量后缀更新、后台取消、generation 防旧回写和当前匹配保持。
- 不增加 per-cell / per-line 常驻状态，不给每个匹配增加稳定 ID，不引入依赖。
- 不实现 regex、fuzzy、整词、跨 pane、搜索历史或新全局快捷键。
- 开发中只运行当前修改对应的 focused tests；不运行完整 `swift test`、完整 build、push、PR、merge 或发布。
- 每个可独立回滚阶段提交一次，中文 Conventional Commit，并在正文写 `Refs #77`。

---

## File Map

- `Sources/TerminalCore/TerminalSearch.swift`：搜索 options、坐标空间、范围过滤与索引身份。
- `Sources/TerminalCore/CommandBlocks.swift`：按搜索匹配范围定位 live OSC 133 命令输出范围。
- `Sources/InkTerminalView/TerminalMetalView.swift`：稳定选区来源和复制指定命令输出到现有剪贴板入口。
- `Sources/InkShell/TerminalSearchController.swift`：大小写、冻结范围、异步重启、live 匹配解析与按钮状态。
- `Sources/InkShell/TerminalSearchBarView.swift`：三个紧凑系统按钮及其状态 / callback。
- `Tests/TerminalCoreTests/TerminalSearchTests.swift`：大小写、范围、索引失效与稳定坐标测试。
- `Tests/TerminalCoreTests/CommandBlockTests.swift`：匹配到命令块输出范围的边界测试。
- `Tests/InkShellTests/TerminalSearchWorkspaceTests.swift`：搜索会话、取消、冻结范围、自动失效与 live 复制集成测试。
- `Tests/InkShellTests/TerminalSearchBarTests.swift`：模式显示、enabled 状态和按钮路由测试。
- `Tests/InkTerminalViewTests/TerminalCommandActionTests.swift`：指定匹配范围复制输出及安全失败测试。

---

### Task 1: 大小写选项进入搜索核心与索引身份

**Files:**
- Modify: `Tests/TerminalCoreTests/TerminalSearchTests.swift`
- Modify: `Sources/TerminalCore/TerminalSearch.swift`

**Interfaces:**
- Produces: `TerminalSearchOptions.init(caseSensitive:selection:)`
- Produces: `TerminalSearchEngine.search(in:query:options:fromLine:)`
- Produces: `TerminalSearchIndex.requiresBackgroundUpdate(in:query:options:)`
- Produces: `TerminalSearchIndex.update(in:query:options:)`
- Preserves: all existing call sites through `.init()` default options

- [ ] **Step 1: Write the failing case-sensitive engine test**

在 `TerminalSearchTests` 添加：

```swift
@Test("大小写敏感模式只接受完全相同的字面值")
func caseSensitiveMode() {
    var (parser, terminal) = makeTerminal(columns: 20, rows: 2)
    feed("Alpha alpha ALPHA", &parser, &terminal)

    let matches = TerminalSearchEngine.search(
        in: terminal,
        query: "Alpha",
        options: TerminalSearchOptions(caseSensitive: true)
    )

    #expect(matches.map(\.range.start.column) == [0])
}
```

- [ ] **Step 2: Run RED for the missing options API**

Run:

```bash
swift test --filter TerminalSearchTests.caseSensitiveMode
```

Expected: compile failure stating that `TerminalSearchOptions` or the `options` argument is missing. Record the command, exit status and diagnostic in `.superpowers/issue-77-tdd.log`.

- [ ] **Step 3: Add the minimal option and engine comparison**

在 `TerminalSearch.swift` 的 match 类型后增加：

```swift
public struct TerminalSearchOptions: Sendable, Equatable {
    public var caseSensitive: Bool
    public var selection: SelectionRange?

    public init(caseSensitive: Bool = false, selection: SelectionRange? = nil) {
        self.caseSensitive = caseSensitive
        self.selection = selection
    }
}
```

由于 options 需要 `Equatable`，把 `SelectionRange` 的声明改为 `Sendable, Equatable`（它已经具备可综合比较的字段）。扩展搜索入口：

```swift
public static func search(
    in terminal: Terminal,
    query: String,
    options: TerminalSearchOptions = TerminalSearchOptions(),
    fromLine: Int = 0
) -> [TerminalSearchMatch]
```

把 options 传给逻辑行匹配：

```swift
matches.append(contentsOf: logicalLine.matches(for: query, options: options))
```

并把 NSString 搜索 options 改为：

```swift
let compareOptions: NSString.CompareOptions = options.caseSensitive
    ? []
    : [.caseInsensitive]
let result = source.range(
    of: query,
    options: compareOptions,
    range: NSRange(location: searchLocation, length: searchableLength - searchLocation)
)
```

- [ ] **Step 4: Run GREEN for engine behavior**

Run:

```bash
swift test --filter TerminalSearchTests.caseSensitiveMode
```

Expected: selected test passes with zero failures. Append output to `.superpowers/issue-77-tdd.log`.

- [ ] **Step 5: Write the failing index identity test**

```swift
@Test("大小写选项变化强制索引全量重建")
func caseOptionInvalidatesIndex() {
    var (parser, terminal) = makeTerminal(columns: 20, rows: 2)
    feed("Alpha alpha", &parser, &terminal)
    var index = TerminalSearchIndex()

    _ = index.update(in: terminal, query: "alpha")
    _ = index.update(
        in: terminal,
        query: "alpha",
        options: TerminalSearchOptions(caseSensitive: true)
    )

    #expect(index.lastUpdateKind == .full)
    #expect(index.matches.count == 1)
}
```

- [ ] **Step 6: Run RED for index option identity**

Run `swift test --filter TerminalSearchTests.caseOptionInvalidatesIndex`.

Expected: compile failure because index methods do not yet accept options, or behavioral failure because the cached insensitive result remains. Append evidence to the TDD log.

- [ ] **Step 7: Include options in index cache identity**

给 `TerminalSearchIndex` 增加：

```swift
private var options = TerminalSearchOptions()
```

把两个方法签名扩为带默认值：

```swift
public func requiresBackgroundUpdate(
    in terminal: Terminal,
    query newQuery: String,
    options newOptions: TerminalSearchOptions = TerminalSearchOptions()
) -> Bool

public mutating func update(
    in terminal: Terminal,
    query newQuery: String,
    options newOptions: TerminalSearchOptions = TerminalSearchOptions()
) -> [TerminalSearchMatch]
```

所有 `query != newQuery` 全量条件同时加入 `options != newOptions`。全量和后缀扫描都把 `newOptions` 传给 engine。`remember` 接收并保存 options；`clear()` 把 options 恢复为默认值。

- [ ] **Step 8: Run GREEN and focused core regression**

Run:

```bash
swift test --filter TerminalSearchTests
```

Expected: the entire `TerminalSearchTests` suite passes. Save output in the TDD log.

---

### Task 2: 搜索会话大小写切换与明确 UI

**Files:**
- Modify: `Tests/InkShellTests/TerminalSearchBarTests.swift`
- Modify: `Tests/InkShellTests/TerminalSearchWorkspaceTests.swift`
- Modify: `Sources/InkShell/TerminalSearchBarView.swift`
- Modify: `Sources/InkShell/TerminalSearchController.swift`

**Interfaces:**
- Consumes: `TerminalSearchOptions(caseSensitive:)`
- Produces: `TerminalSearchBarView.updateSearchModes(caseSensitive:selectionOnly:selectionAvailable:copyOutputAvailable:)`
- Produces: `TerminalSearchController.setCaseSensitive(_:)`
- Preserves: query debounce, task cancellation, generation check and nearest-result selection

- [ ] **Step 1: Write failing search bar state and routing tests**

添加两个测试：

```swift
@Test("搜索模式按钮明确显示状态与可用性")
func modeState() {
    let bar = TerminalSearchBarView()

    bar.updateSearchModes(
        caseSensitive: true,
        selectionOnly: false,
        selectionAvailable: false,
        copyOutputAvailable: true
    )

    #expect(bar.caseSensitiveEnabled)
    #expect(!bar.selectionOnlyEnabled)
    #expect(!bar.selectionToggleEnabled)
    #expect(bar.copyOutputEnabled)
}

@Test("大小写按钮把下一状态路由给控制器")
func caseButtonRouting() {
    let bar = TerminalSearchBarView()
    var states: [Bool] = []
    bar.onCaseSensitivityChange = { states.append($0) }

    bar.toggleCaseSensitivity()
    bar.toggleCaseSensitivity()

    #expect(states == [true, false])
}
```

- [ ] **Step 2: Run RED for missing search bar controls**

Run `swift test --filter TerminalSearchBarTests`.

Expected: compile failures for the new state API and callback. Record evidence.

- [ ] **Step 3: Add compact AppKit buttons and state API**

在 `TerminalSearchBarView` 增加 callbacks 与按钮：

```swift
var onCaseSensitivityChange: ((Bool) -> Void)?
var onSelectionScopeChange: ((Bool) -> Void)?
var onCopyMatchCommandOutput: (() -> Void)?

private let caseSensitiveButton = NSButton(frame: .zero)
private let selectionButton = NSButton(frame: .zero)
private let copyOutputButton = NSButton(frame: .zero)

var caseSensitiveEnabled: Bool { caseSensitiveButton.state == .on }
var selectionOnlyEnabled: Bool { selectionButton.state == .on }
var selectionToggleEnabled: Bool { selectionButton.isEnabled }
var copyOutputEnabled: Bool { copyOutputButton.isEnabled }
```

用系统按钮配置：`Aa` 和“选区”使用 `.pushOnPushOff`，复制按钮使用 `doc.on.doc`，三者都设置中文 accessibility label 与 toolTip。把它们插入结果计数与导航按钮之间；`Aa` 宽 30 pt，“选区”宽 42 pt，图标宽 22 pt，继续保持高度 34 pt。

实现：

```swift
func updateSearchModes(
    caseSensitive: Bool,
    selectionOnly: Bool,
    selectionAvailable: Bool,
    copyOutputAvailable: Bool
) {
    caseSensitiveButton.state = caseSensitive ? .on : .off
    selectionButton.state = selectionOnly ? .on : .off
    selectionButton.isEnabled = selectionOnly || selectionAvailable
    copyOutputButton.isEnabled = copyOutputAvailable
}

func toggleCaseSensitivity() {
    let enabled = caseSensitiveButton.state != .on
    caseSensitiveButton.state = enabled ? .on : .off
    onCaseSensitivityChange?(enabled)
}
```

对应 selector 调 `toggleCaseSensitivity()`；选区 selector 发送下一状态，复制 selector 调 callback。

- [ ] **Step 4: Run GREEN for bar tests**

Run `swift test --filter TerminalSearchBarTests`.

Expected: all search bar tests pass. Record output.

- [ ] **Step 5: Write failing controller case toggle test**

在 `TerminalSearchWorkspaceTests` 添加：

```swift
@Test("大小写切换重新计算当前会话并同步按钮")
func caseToggleRestartsSearch() async {
    var terminal = Terminal(size: .init(columns: 20, rows: 2), scrollbackCapacity: 20)
    var parser = Parser()
    parser.feed(Array("Alpha alpha".utf8), handler: &terminal)
    let view = TerminalMetalView(frame: .zero)
    view.terminalProvider = { terminal }
    let controller = TerminalSearchController(terminalProvider: { terminal }, terminalView: view)

    controller.updateQuery("alpha")
    await controller.waitForPendingUpdate()
    #expect(controller.matches.count == 2)

    controller.setCaseSensitive(true)
    await controller.waitForPendingUpdate()

    #expect(controller.matches.count == 1)
    #expect(controller.searchBar.caseSensitiveEnabled)
}
```

- [ ] **Step 6: Run RED for controller session state**

Run `swift test --filter TerminalSearchWorkspaceTests.caseToggleRestartsSearch`.

Expected: compile failure because `setCaseSensitive` is missing. Record evidence.

- [ ] **Step 7: Refactor query restart without weakening cancellation**

在 controller 增加 `private(set) var caseSensitive = false` 和：

```swift
func setCaseSensitive(_ enabled: Bool) {
    guard caseSensitive != enabled else { return }
    caseSensitive = enabled
    restartSearch(chooseNearest: true)
}
```

把 `updateQuery` 改为先赋 query，再调用 `restartSearch(chooseNearest: true)`。`restartSearch` 必须按现有顺序：递增 generation、取消并清空 updateTask、清延迟刷新、清 index / current / result coordinate state、发布空结果；查询非空时读取 live Terminal、生成 options、创建 snapshot，再调用现有 `startBackgroundUpdate`。`requiresBackgroundUpdate`、同步 `update` 和后台 `update` 全部传：

```swift
TerminalSearchOptions(caseSensitive: caseSensitive)
```

init 连接 `searchBar.onCaseSensitivityChange`，close 断开 callback。每次 publish 都调用 `updateSearchModes`，确保 UI 与 controller 状态一致。

- [ ] **Step 8: Add stale-generation regression for mode changes**

添加快速连续切换测试：构造同时含 `Alpha` / `alpha` 的大终端，调用 `updateQuery` 后立即 `setCaseSensitive(true)`，等待 pending update，断言最终只有敏感结果且按钮为 on。这个测试的生产断言必须依赖最终 generation，不用 sleep 猜完成顺序。

- [ ] **Step 9: Run GREEN and commit the size-case phase**

Run:

```bash
swift test --filter TerminalSearchTests
swift test --filter TerminalSearchBarTests
swift test --filter TerminalSearchWorkspaceTests
git diff --check
```

Expected: all three focused suites pass and diff check exits 0.

Commit:

```bash
git add Sources/TerminalCore/TerminalSearch.swift Sources/TerminalCore/SelectionText.swift \
  Sources/InkShell/TerminalSearchBarView.swift Sources/InkShell/TerminalSearchController.swift \
  Tests/TerminalCoreTests/TerminalSearchTests.swift \
  Tests/InkShellTests/TerminalSearchBarTests.swift \
  Tests/InkShellTests/TerminalSearchWorkspaceTests.swift
git commit -m "feat(search): 支持区分大小写" \
  -m "把大小写模式纳入搜索索引身份，切换时复用 generation 取消与后台重建，避免旧结果回写。" \
  -m "Refs #77"
```

---

### Task 3: 搜索范围过滤与稳定坐标空间

**Files:**
- Modify: `Tests/TerminalCoreTests/TerminalSearchTests.swift`
- Modify: `Sources/TerminalCore/TerminalSearch.swift`

**Interfaces:**
- Consumes: `TerminalSearchOptions.selection`
- Produces: `TerminalSearchCoordinateSpace.init(in:)`
- Produces: `TerminalSearchCoordinateSpace.resolve(_:in:) -> SelectionRange?`
- Invariant: coordinate space is one small value per scope/result batch, never one per match

- [ ] **Step 1: Write failing linear and block scope tests**

```swift
@Test("线性选区只接纳完全包含的匹配")
func linearSelectionScope() {
    var (parser, terminal) = makeTerminal(columns: 20, rows: 2)
    feed("hit one hit two", &parser, &terminal)
    let scope = SelectionRange(
        start: .init(line: 0, column: 4),
        end: .init(line: 0, column: 14)
    )

    let matches = TerminalSearchEngine.search(
        in: terminal,
        query: "hit",
        options: .init(selection: scope)
    )

    #expect(matches.map(\.range.start.column) == [8])
}

@Test("矩形选区拒绝经过未选行尾的软折匹配")
func blockSelectionRejectsUnselectedWrappedCells() {
    var (parser, terminal) = makeTerminal(columns: 6, rows: 3)
    feed("abcdefghi", &parser, &terminal)
    let scope = SelectionRange(
        start: .init(line: 0, column: 2),
        end: .init(line: 1, column: 3),
        block: true
    )

    #expect(TerminalSearchEngine.search(
        in: terminal,
        query: "defg",
        options: .init(selection: scope)
    ).isEmpty)
    #expect(TerminalSearchEngine.search(
        in: terminal,
        query: "cde",
        options: .init(selection: scope)
    ).count == 1)
}
```

- [ ] **Step 2: Run RED for ignored selection scope**

Run `swift test --filter TerminalSearchTests.linearSelectionScope` and `swift test --filter TerminalSearchTests.blockSelectionRejectsUnselectedWrappedCells`.

Expected: linear test returns both matches and block test accepts the cross-boundary match. Record both failures.

- [ ] **Step 3: Filter candidates using actual CellMappings**

搜索行边界先夹到 normalized selection 的行：

```swift
let scopedFirst = options.selection.map { max(firstLine, $0.normalized.start.line) }
    ?? firstLine
let scopedEnd = options.selection.map {
    min(terminal.totalLines, $0.normalized.end.line + 1)
} ?? terminal.totalLines
guard scopedFirst < scopedEnd else { return [] }
```

`LogicalLine.matches` 得到 firstIndex / lastIndex 后，调用：

```swift
guard candidateIsInsideSelection(
    firstIndex...lastIndex,
    selection: options.selection
) else {
    searchLocation = resultEnd
    matchCount += 1
    continue
}
```

helper 的完整判定：nil 返回 true；否则遍历 candidate mapping，要求 selection 对 mapping.start 与 mapping.end 都 `contains`。这会让宽字符尾格、矩形范围与跨软折 mapping 一起接受同一规则。

- [ ] **Step 4: Run GREEN for scope semantics**

Run `swift test --filter TerminalSearchTests`.

Expected: all core search tests pass. Record output.

- [ ] **Step 5: Write failing coordinate-space tests**

```swift
@Test("坐标空间在存活淘汰后平移并在端点淘汰后失效")
func coordinateSpaceRebasesSurvivingRange() throws {
    var (parser, terminal) = makeTerminal(columns: 8, rows: 1, scrollback: 2)
    feed("old\r\nkeep\r\nlive", &parser, &terminal)
    let space = TerminalSearchCoordinateSpace(in: terminal)
    let frozen = SelectionRange(
        start: .init(line: 1, column: 0),
        end: .init(line: 1, column: 3)
    )

    feed("\r\nnew", &parser, &terminal)
    #expect(space.resolve(frozen, in: terminal) == SelectionRange(
        start: .init(line: 0, column: 0),
        end: .init(line: 0, column: 3)
    ))

    feed("\r\nnewer", &parser, &terminal)
    #expect(space.resolve(frozen, in: terminal) == nil)
}

@Test("layout revision 改变使坐标空间失效")
func coordinateSpaceRejectsReflow() {
    var (parser, terminal) = makeTerminal(columns: 12, rows: 2)
    feed("selected", &parser, &terminal)
    let space = TerminalSearchCoordinateSpace(in: terminal)
    let frozen = SelectionRange(start: .init(line: 0, column: 0), end: .init(line: 0, column: 3))

    terminal.resize(to: .init(columns: 6, rows: 2))

    #expect(space.resolve(frozen, in: terminal) == nil)
}
```

- [ ] **Step 6: Run RED for the missing coordinate type**

Run `swift test --filter TerminalSearchTests.coordinateSpace`.

Expected: compile failure for missing `TerminalSearchCoordinateSpace`. Record evidence.

- [ ] **Step 7: Implement one-per-batch coordinate capture and resolution**

```swift
public struct TerminalSearchCoordinateSpace: Sendable, Equatable {
    public let layoutRevision: UInt64
    public let oldestLineID: UInt64

    public init(in terminal: Terminal) {
        layoutRevision = terminal.searchLayoutRevision
        oldestLineID = terminal.scrollback.totalAppendedLines
            - UInt64(terminal.scrollback.count)
    }

    public func resolve(_ range: SelectionRange, in terminal: Terminal) -> SelectionRange? {
        guard terminal.searchLayoutRevision == layoutRevision else { return nil }
        let currentOldest = terminal.scrollback.totalAppendedLines
            - UInt64(terminal.scrollback.count)

        func position(_ source: TextPosition) -> TextPosition? {
            guard source.line >= 0, source.column >= 0 else { return nil }
            let lineID = oldestLineID + UInt64(source.line)
            guard lineID >= currentOldest else { return nil }
            let line = Int(lineID - currentOldest)
            guard line < terminal.totalLines,
                  source.column < terminal.grid.size.columns else { return nil }
            return TextPosition(line: line, column: source.column)
        }

        guard let start = position(range.start), let end = position(range.end) else { return nil }
        return SelectionRange(start: start, end: end, block: range.block)
    }
}
```

- [ ] **Step 8: Run GREEN and core focused regression**

Run `swift test --filter TerminalSearchTests` and `git diff --check`.

Expected: suite passes; no whitespace errors. Do not commit yet because the user-visible range mode needs this core API in the same independently useful phase.

---

### Task 4: 冻结选区会话、重映射与自动退出

**Files:**
- Modify: `Tests/InkTerminalViewTests/TerminalSearchHighlightTests.swift`
- Modify: `Tests/InkShellTests/TerminalSearchWorkspaceTests.swift`
- Modify: `Tests/InkShellTests/TerminalSearchBarTests.swift`
- Modify: `Sources/InkTerminalView/TerminalMetalView.swift`
- Modify: `Sources/InkShell/TerminalSearchController.swift`
- Modify: `Sources/InkShell/TerminalSearchBarView.swift`

**Interfaces:**
- Consumes: `TerminalSearchCoordinateSpace.resolve`
- Produces: `TerminalMetalView.searchSelection(in:) -> SelectionRange?`
- Produces: controller initializer optional `selectionProvider: ((Terminal) -> SelectionRange?)?`
- Produces: `TerminalSearchController.setSelectionOnly(_:)`

- [ ] **Step 1: Write failing bar selection callback test**

```swift
@Test("选区按钮只在可用时发送下一模式")
func selectionButtonRouting() {
    let bar = TerminalSearchBarView()
    var states: [Bool] = []
    bar.onSelectionScopeChange = { states.append($0) }
    bar.updateSearchModes(
        caseSensitive: false,
        selectionOnly: false,
        selectionAvailable: true,
        copyOutputAvailable: false
    )

    bar.toggleSelectionScope()
    bar.toggleSelectionScope()

    #expect(states == [true, false])
}
```

Run `swift test --filter TerminalSearchBarTests.selectionButtonRouting`.

Expected RED: missing `toggleSelectionScope`. Implement it symmetrically with case toggle, route selector to it, then rerun and expect PASS.

- [ ] **Step 2: Write failing frozen-selection controller test**

```swift
@Test("仅搜索选区冻结开启瞬间范围")
func selectionScopeIsFrozen() async throws {
    var terminal = Terminal(size: .init(columns: 24, rows: 2), scrollbackCapacity: 20)
    var parser = Parser()
    parser.feed(Array("hit outside hit inside".utf8), handler: &terminal)
    var provided = SelectionRange(
        start: .init(line: 0, column: 8),
        end: .init(line: 0, column: 21)
    )
    let view = TerminalMetalView(frame: .zero)
    view.terminalProvider = { terminal }
    let controller = TerminalSearchController(
        terminalProvider: { terminal },
        terminalView: view,
        selectionProvider: { _ in provided }
    )

    controller.updateQuery("hit")
    controller.setSelectionOnly(true)
    provided = SelectionRange(start: .init(line: 0, column: 0), end: .init(line: 0, column: 2))
    await controller.waitForPendingUpdate()

    #expect(controller.matches.count == 1)
    #expect(controller.matches.first?.range.start.column == 12)
    #expect(controller.searchBar.selectionOnlyEnabled)
}
```

- [ ] **Step 3: Run RED for missing controller range mode**

Run `swift test --filter TerminalSearchWorkspaceTests.selectionScopeIsFrozen`.

Expected: compile failure for initializer argument and `setSelectionOnly`. Record evidence.

- [ ] **Step 4: Add stable selection capture in TerminalMetalView**

增加：

```swift
private var selectionCoordinateSpace: TerminalSearchCoordinateSpace?

public func searchSelection(in terminal: Terminal) -> SelectionRange? {
    guard let selection, let selectionCoordinateSpace else { return nil }
    return selectionCoordinateSpace.resolve(selection, in: terminal)
}

private func setSelection(_ range: SelectionRange?, in terminal: Terminal?) {
    selection = range
    if range != nil, let terminal {
        selectionCoordinateSpace = TerminalSearchCoordinateSpace(in: terminal)
    } else {
        selectionCoordinateSpace = nil
    }
}
```

双击、三击、拖动建立选区都通过 helper 并传 live terminal；单击清旧选区、reset、命令跳转和键盘输入清选区都通过 helper 置 nil。渲染继续读取 `selection`，不改变热循环结构。

在 `TerminalSearchHighlightTests` 通过实际 mouse event 或已有可测试入口验证：选择捕获后 reflow 导致 `searchSelection(in:) == nil`。若 event 构造使测试脆弱，优先把“当前范围 + 坐标空间解析”保持在 core 测试，Shell controller 用注入 provider 验证，不添加 test-only public setter。

- [ ] **Step 5: Add frozen state and option resolution in controller**

内部值类型：

```swift
private struct FrozenSelection {
    let range: SelectionRange
    let coordinateSpace: TerminalSearchCoordinateSpace
}
```

initializer 新增可选 provider；默认闭包调用 `terminalView.searchSelection(in:)`。增加 `private(set) var selectionOnly = false`、`private var frozenSelection: FrozenSelection?`。

开启实现：读取 live Terminal 与 provider；要求范围可解析且 `!terminal.extractText(in: range).isEmpty`；捕获范围和 coordinate space，置 `selectionOnly = true`，统一 restart。关闭则清冻结范围、置 false 并 restart。

生成 options 时：

```swift
private func options(in terminal: Terminal) -> TerminalSearchOptions? {
    var selection: SelectionRange?
    if selectionOnly {
        guard let frozenSelection,
              let resolved = frozenSelection.coordinateSpace.resolve(
                  frozenSelection.range,
                  in: terminal
              ) else { return nil }
        selection = resolved
    }
    return TerminalSearchOptions(
        caseSensitive: caseSensitive,
        selection: selection
    )
}
```

query restart 和 PTY refresh 都必须先获得 options。refresh 得到 nil 时清 scope、更新按钮，并以全终端 options 调 restart；不要继续应用旧范围 index。同步 / 后台 index 方法都传同一 options。

- [ ] **Step 6: Add failing invalidation and availability tests**

分别添加：

1. provider 返回 nil 或提取为空时，`setSelectionOnly(true)` 保持 false，bar disabled；
2. 开启后 `terminal.resize`，`refreshForTerminalUpdate()` 自动退出且全终端结果恢复；
3. 小 scrollback 中冻结尚存行，发生一次环淘汰后范围重映射、模式保持；再淘汰端点后自动退出；
4. 开启后 provider 改到另一范围，刷新仍使用冻结范围。

每个测试先单独运行并确认因为缺少自动退出 / 重映射行为而 RED，再实现对应最小分支，随后单独 GREEN。所有 RED/GREEN 输出追加到 TDD log。

- [ ] **Step 7: Avoid extra provider reads in coalescing path**

把 `publish` 扩为可接收本轮已经读取的 Terminal：

```swift
private func publish(reveal: Bool, terminal: Terminal? = nil)
```

模式 availability 与之后的复制 availability 优先使用传入值；仅没有 live 值时读取 provider。同步 refresh 必须把已经取得的 terminal 传给 publish，确保现有 `coalescesTerminalUpdates` 仍断言一次 provider read，不因按钮刷新退化。

- [ ] **Step 8: Run focused range suites and commit**

Run:

```bash
swift test --filter TerminalSearchTests
swift test --filter TerminalSearchBarTests
swift test --filter TerminalSearchWorkspaceTests
swift test --filter TerminalSearchHighlightTests
git diff --check
```

Expected: all selected suites pass, including coalescing regression.

Commit:

```bash
git add Sources/TerminalCore/TerminalSearch.swift \
  Sources/InkTerminalView/TerminalMetalView.swift \
  Sources/InkShell/TerminalSearchBarView.swift Sources/InkShell/TerminalSearchController.swift \
  Tests/TerminalCoreTests/TerminalSearchTests.swift \
  Tests/InkTerminalViewTests/TerminalSearchHighlightTests.swift \
  Tests/InkShellTests/TerminalSearchBarTests.swift \
  Tests/InkShellTests/TerminalSearchWorkspaceTests.swift
git commit -m "feat(search): 支持冻结选区范围" \
  -m "用会话级稳定坐标重映射选区，范围被 reflow、清历史或环淘汰失效时自动回到全终端搜索。" \
  -m "Refs #77"
```

---

### Task 5: 从 live OSC 133 解析匹配所在命令输出

**Files:**
- Modify: `Tests/TerminalCoreTests/CommandBlockTests.swift`
- Modify: `Tests/InkTerminalViewTests/TerminalCommandActionTests.swift`
- Modify: `Tests/InkShellTests/TerminalSearchWorkspaceTests.swift`
- Modify: `Tests/InkShellTests/TerminalSearchBarTests.swift`
- Modify: `Sources/TerminalCore/CommandBlocks.swift`
- Modify: `Sources/InkTerminalView/TerminalMetalView.swift`
- Modify: `Sources/InkShell/TerminalSearchController.swift`
- Modify: `Sources/InkShell/TerminalSearchBarView.swift`

**Interfaces:**
- Produces: `Terminal.commandOutputRange(containing:) -> SemanticTextRange?`
- Produces: `TerminalMetalView.canCopyCommandOutput(containing:in:) -> Bool`
- Produces: `TerminalMetalView.copyCommandOutput(containing:in:) -> Bool`
- Produces: `TerminalSearchController.copyCurrentMatchCommandOutput() -> Bool`
- Invariant: command lookup always receives a live Terminal, never `snapshotForSearch()`

- [ ] **Step 1: Write failing command block containment tests**

在 `CommandBlockTests` 增加：

```swift
@Test("命令或输出中的完整匹配都解析到同一输出范围")
func searchMatchResolvesCommandOutput() throws {
    var (parser, terminal) = makeTerminal(columns: 30, rows: 5)
    feed(
        "\u{1B}]133;A\u{07}$ \u{1B}]133;B\u{07}echo needle\r\n"
            + "\u{1B}]133;C\u{07}needle output"
            + "\u{1B}]133;D;0\u{07}",
        &parser,
        &terminal
    )
    let matches = TerminalSearchEngine.search(in: terminal, query: "needle")

    let commandOutput = try #require(terminal.commandOutputRange(containing: matches[0].range))
    let outputOutput = try #require(terminal.commandOutputRange(containing: matches[1].range))

    #expect(terminal.extractText(in: commandOutput) == "needle output")
    #expect(outputOutput == commandOutput)
}

@Test("跨命令块边界或块外匹配没有命令输出")
func searchMatchOutsideCommandHasNoOutput() {
    var (parser, terminal) = makeTerminal(columns: 30, rows: 5)
    feed("plain needle", &parser, &terminal)
    let match = TerminalSearchEngine.search(in: terminal, query: "needle")[0]

    #expect(terminal.commandOutputRange(containing: match.range) == nil)
}
```

- [ ] **Step 2: Run RED for missing OSC containment API**

Run `swift test --filter CommandBlockTests.searchMatch`.

Expected: compile failure for `commandOutputRange`. Record evidence.

- [ ] **Step 3: Implement half-open command-span containment**

在 `CommandBlocks.swift` 的 extension 中增加：

```swift
public func commandOutputRange(containing match: SelectionRange) -> SemanticTextRange? {
    let match = match.normalized
    return commandBlocks().first { block in
        guard let output = block.outputRange,
              block.commandRange.start <= match.start,
              match.end < output.end,
              !extractText(in: output).isEmpty else { return false }
        return true
    }?.outputRange
}
```

如果 Swift 的 optional key path 推导使最后一行不能编译，改用显式 loop 返回 output；不要改变半开边界与非空要求。

- [ ] **Step 4: Run GREEN for command core tests**

Run `swift test --filter CommandBlockTests`.

Expected: all OSC 133 command block tests pass. Record output.

- [ ] **Step 5: Write failing view copy-by-match test**

在 `TerminalCommandActionTests` 添加：

```swift
@Test("指定搜索匹配从 live 命令块复制输出")
func copiesOutputContainingSearchMatch() throws {
    let terminal = makeCommandTerminal()
    let match = try #require(TerminalSearchEngine.search(
        in: terminal,
        query: "second"
    ).first)
    let view = TerminalMetalView(frame: .zero)
    var copied: String?
    view.pasteboardWriter = { copied = $0; return true }

    #expect(view.canCopyCommandOutput(containing: match.range, in: terminal))
    #expect(view.copyCommandOutput(containing: match.range, in: terminal))
    #expect(copied == "two")
}
```

Run `swift test --filter TerminalCommandActionTests.copiesOutputContainingSearchMatch`.

Expected RED: missing view APIs. Record evidence.

- [ ] **Step 6: Add view availability and copy methods**

```swift
public func canCopyCommandOutput(
    containing range: SelectionRange,
    in terminal: Terminal
) -> Bool {
    terminal.commandOutputRange(containing: range) != nil
}

@discardableResult
public func copyCommandOutput(
    containing range: SelectionRange,
    in terminal: Terminal
) -> Bool {
    guard let output = terminal.commandOutputRange(containing: range) else { return false }
    return writeToPasteboard(terminal.extractText(in: output))
}
```

Run the focused view test again and expect PASS.

- [ ] **Step 7: Write failing controller live-coordinate copy tests**

在 workspace suite 添加：

1. OSC 133 命令中含查询时，搜索完成后 bar copy enabled，调用 controller 动作写入该命令输出；
2. 查询只存在于普通块外文本时 disabled 且动作返回 false；
3. 搜索完成后让 scrollback 淘汰但不先 refresh，旧匹配坐标无法复制占用旧位置的新命令；
4. reflow 后不先 refresh，layout revision 校验使动作立即失败；
5. 构造 `snapshotForSearch().commandBlocks().isEmpty` 但 live Terminal 有命令块，动作仍成功，明确证明命令解析来自 live Terminal。

测试给 view 注入 `pasteboardWriter` 捕获字符串，不触碰系统剪贴板。逐个运行并记录 RED；预期 controller 缺少动作、按钮一直 disabled 或 stale 坐标错误复制。

- [ ] **Step 8: Store one coordinate space per result batch**

controller 增加：

```swift
private var resultCoordinateSpace: TerminalSearchCoordinateSpace?
```

清索引 / 空查询时置 nil；同步 index update 和后台 apply 成功时都设置为对应 Terminal snapshot 的坐标空间。不要把空间复制进 `TerminalSearchMatch`。

解析 helper：

```swift
private func liveCurrentMatch() -> (terminal: Terminal, range: SelectionRange)? {
    guard let currentMatch, let resultCoordinateSpace else { return nil }
    let terminal = terminalProvider()
    guard let range = resultCoordinateSpace.resolve(currentMatch.range, in: terminal) else {
        return nil
    }
    return (terminal, range)
}
```

动作：

```swift
@discardableResult
func copyCurrentMatchCommandOutput() -> Bool {
    guard let resolved = liveCurrentMatch() else { return false }
    return terminalView?.copyCommandOutput(
        containing: resolved.range,
        in: resolved.terminal
    ) ?? false
}
```

publish 用同一 helper 计算 `copyOutputAvailable`，连接 / 断开 `searchBar.onCopyMatchCommandOutput`。点击时再次验证 live 坐标与命令块，不能信任此前 enabled 状态。

- [ ] **Step 9: Complete bar copy routing test**

```swift
@Test("复制匹配命令输出按钮路由动作")
func copyOutputRouting() {
    let bar = TerminalSearchBarView()
    var count = 0
    bar.onCopyMatchCommandOutput = { count += 1 }
    bar.performCopyMatchCommandOutput()
    #expect(count == 1)
}
```

先运行观察 missing helper RED，再实现 helper 由 selector 共用，运行 GREEN。

- [ ] **Step 10: Run focused command/search suites and commit**

Run:

```bash
swift test --filter CommandBlockTests
swift test --filter TerminalCommandActionTests
swift test --filter TerminalSearchBarTests
swift test --filter TerminalSearchWorkspaceTests
git diff --check
```

Expected: all selected suites pass; stale-coordinate tests prove no clipboard write.

Commit:

```bash
git add Sources/TerminalCore/CommandBlocks.swift \
  Sources/InkTerminalView/TerminalMetalView.swift \
  Sources/InkShell/TerminalSearchBarView.swift Sources/InkShell/TerminalSearchController.swift \
  Tests/TerminalCoreTests/CommandBlockTests.swift \
  Tests/InkTerminalViewTests/TerminalCommandActionTests.swift \
  Tests/InkShellTests/TerminalSearchBarTests.swift \
  Tests/InkShellTests/TerminalSearchWorkspaceTests.swift
git commit -m "feat(search): 复制匹配所在命令输出" \
  -m "只用整批搜索结果的稳定坐标映射到 live Terminal，再按 OSC 133 边界提取输出，避免搜索快照持有命令旁路。" \
  -m "Refs #77"
```

---

### Task 6: 范围失效细节、异步回归与交付报告

**Files:**
- Modify if a regression is found: files already listed above
- Create: `.superpowers/issue-77-report.md`
- Maintain: `.superpowers/issue-77-tdd.log` as local evidence; do not commit unless repository policy requires it

**Interfaces:**
- Verifies: every spec requirement is represented by a focused test or an explicit unverified item
- Produces: controller report required by the root task

- [ ] **Step 1: Re-read the design requirement by requirement**

对照 `docs/superpowers/specs/2026-07-22-terminal-search-enhancements-design.md` 建立检查表，逐项指向一个测试：大小写会话、切换取消、范围冻结、非空 gate、存活重映射、reflow / clear / 淘汰失效、live OSC、无块禁用、无 current 禁用、旧 generation 防回写、无 per-cell 状态。

- [ ] **Step 2: Run only the authorized focused suites fresh**

```bash
swift test --filter TerminalSearchTests
swift test --filter CommandBlockTests
swift test --filter TerminalSearchHighlightTests
swift test --filter TerminalCommandActionTests
swift test --filter TerminalSearchBarTests
swift test --filter TerminalSearchWorkspaceTests
```

Expected: each command exits 0 with zero failures. Do not claim full repository test or build coverage.

- [ ] **Step 3: Inspect memory-sensitive layouts and forbidden dependencies**

```bash
rg -n "TerminalSearch|Selection" Sources/TerminalCore/Cell.swift Sources/TerminalCore/Grid.swift Sources/TerminalCore/ScrollbackBuffer.swift
rg -n "import (AppKit|Metal|MetalKit)" Sources/TerminalCore
git diff origin/main...HEAD -- Sources/TerminalCore/Cell.swift Sources/TerminalCore/Grid.swift Sources/TerminalCore/ScrollbackBuffer.swift Package.swift
```

Expected: no new search field in cell / line / scrollback types, no UI import in TerminalCore, no dependency change.

- [ ] **Step 4: Self-audit the complete branch diff**

```bash
git diff --stat origin/main...HEAD
git diff origin/main...HEAD
git diff --check origin/main...HEAD
git status --short
```

Read the full diff for accidental scope, stale callbacks, force unwraps, extra Terminal provider reads, snapshot OSC assumptions, option omissions and missing Chinese comments. Fix findings with a failing regression test first; rerun only affected focused suites.

- [ ] **Step 5: Write the required report**

Create `.superpowers/issue-77-report.md` with exact sections:

```markdown
# Issue #77 开发报告

## 状态
## 规格与计划
## 提交列表
## 实现摘要
## Focused tests
## TDD RED / GREEN 证据
## 变更文件
## 自审
## 未验证项
## Concerns
```

列出每个提交 hash / subject、每条 focused command 与结果、RED 的预期失败原因、GREEN 输出摘要、所有变更文件、`git diff --check` 结果。未验证项必须明确写“未运行完整 swift test、完整 build、Instruments、最终 code review、push / PR / merge”，不要暗示这些已经通过。

- [ ] **Step 6: Commit report only if `.superpowers` is tracked by project convention**

先运行 `git check-ignore -v .superpowers/issue-77-report.md`. 若被忽略，保留本地报告不提交；若未忽略，按用户要求报告路径即可，不把运行日志夹进实现提交。无论哪种情况，都不得 push 或创建 PR。

- [ ] **Step 7: Send the constrained handoff**

最终只报告：Status、提交列表、focused test 摘要、concerns、绝对报告路径。不要声称完整测试或 build 已通过。
