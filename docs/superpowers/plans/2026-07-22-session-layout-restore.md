# 会话布局恢复实施计划

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** 重启 Ink 后恢复项目对应的标签、工作目录、活动位置和递归分屏比例，同时为每个 pane 启动全新 shell，绝不恢复 PTY 或终端历史。

**Architecture:** `WorkspaceSnapshot` 与 `WorkspaceStore` 负责版本化 DTO、语义校验和 UserDefaults 单值保存；`WorkspaceStateMapper` 在纯快照与运行态之间转换；`WorkspaceSaveScheduler` 合并结构变化。`MainWindowController` 只负责生命周期接线、PTY 创建和退出前 flush，`TerminalCore` 与渲染热路径不变。

**Tech Stack:** Swift 6、Foundation `Codable` / `UserDefaults` / `DispatchWorkItem`、AppKit、Swift Testing、SwiftPM，最低 macOS 14.0。

## Global Constraints

- `TerminalCore` 不得引入 AppKit、Metal、PTY 或 UserDefaults 依赖。
- 快照不得包含旧 PTY、进程、命令、环境变量、OSC 动态标题、终端内容或 scrollback。
- cell 仍为 8 字节、RowInfo 仍为 2 字节；不得增加 per-cell 或 per-line 常驻字段。
- 保存和工作目录查询不得进入终端输出、parser、grid、scrollback 或每帧渲染路径。
- 不增加第三方库；代码标识符用英文，注释与提交信息用中文。
- 分支固定为 `agent/issue-68-session-layout-restore`，PR 只用 `Closes #68`，不发布。

---

## 文件结构

- 新建 `Sources/InkShell/WorkspaceSnapshot.swift`：schema 1 DTO、递归布局编码、校验和 store。
- 新建 `Sources/InkShell/WorkspaceStateMapper.swift`：路径解析、运行态捕获、完整标签恢复。
- 新建 `Sources/InkShell/WorkspaceSaveScheduler.swift`：250 ms 合并保存和同步 flush。
- 修改 `PaneLayout.swift`、`TerminalTab.swift`、`TerminalSession.swift`：恢复不变式与目录回退。
- 修改 `MainWindowController.swift`：依赖注入、启动恢复、结构触发和退出顺序。
- 新建四组 `Workspace*Tests.swift`；修改 `docs/roadmap.md` 与 `docs/perf.md`。

### Task 1: 版本化快照与语义校验

**Files:**
- Create: `Sources/InkShell/WorkspaceSnapshot.swift`
- Create: `Tests/InkShellTests/WorkspaceSnapshotTests.swift`

**Interfaces:**
- Consumes: Foundation `Codable`、`UserDefaults`。
- Produces: `WorkspaceSnapshot`、`WorkspaceLayoutNode`、`WorkspaceLimits`、`WorkspaceStore.load()`、`WorkspaceStore.save(_:)`。

- [ ] **Step 1: 写 schema 往返、过新版本、局部坏标签和预算测试**

```swift
import Foundation
import Testing
@testable import InkShell

@Suite("会话布局快照")
struct WorkspaceSnapshotTests {
    @Test("schema 1 往返嵌套布局")
    func roundtrip() throws {
        let snapshot = WorkspaceSnapshot(
            activeProjectPath: "~/work/ink",
            projects: [.init(path: "~/work/ink", activeTabIndex: 0, tabs: [
                .init(customName: "开发", activePaneID: "left", layout: .group(
                    axis: "leftRight", weights: [2, 1], children: [
                        .leaf(paneID: "left", workingDirectory: "~/work/ink"),
                        .leaf(paneID: "right", workingDirectory: "~/work/ink/Tests"),
                    ]
                )),
            ])]
        )
        let data = try JSONEncoder().encode(snapshot)
        let decoded = try JSONDecoder().decode(WorkspaceSnapshot.self, from: data)
        let valid = try #require(decoded.validated())
        #expect(valid.projects[0].tabs[0].layout.weights == [2.0 / 3.0, 1.0 / 3.0])
    }

    @Test("过新 schema 整份拒绝，局部坏标签不拖累同项目")
    func validationScope() throws {
        var newer = WorkspaceSnapshot(activeProjectPath: nil, projects: [])
        newer.schemaVersion = 2
        #expect(newer.validated() == nil)

        let mixed = WorkspaceSnapshot(activeProjectPath: nil, projects: [
            .init(path: "~/work/ink", activeTabIndex: 1, tabs: [
                .init(customName: "坏", activePaneID: "x", layout: .group(
                    axis: "diagonal", weights: [1, 1], children: [
                        .leaf(paneID: "x", workingDirectory: "~"),
                        .leaf(paneID: "y", workingDirectory: "~"),
                    ]
                )),
                .init(customName: "好", activePaneID: "z",
                      layout: .leaf(paneID: "z", workingDirectory: "~")),
            ])
        ])
        let valid = try #require(mixed.validated())
        #expect(valid.projects[0].tabs.map(\.customName) == ["好"])
        #expect(valid.projects[0].activeTabIndex == 0)
    }
}
```

补充测试：重复/空 pane ID、空分组、权重数量不匹配、零/NaN 权重、深度 17、单标签 17
pane 均只丢当前标签；`maxTotalPanes: 2` 时只保留前两个完整单 pane 标签，活动索引夹到 1；
活动 pane ID 不存在时改成第一个叶子 ID；空路径或展开 `~` 后仍非绝对的项目/pane 路径拒绝。

- [ ] **Step 2: 运行测试确认 RED**

Run: `swift test --filter WorkspaceSnapshotTests`

Expected: FAIL，`cannot find 'WorkspaceSnapshot' in scope`。

- [ ] **Step 3: 实现 DTO、自定义递归编码和局部语义校验**

```swift
struct WorkspaceLimits: Sendable {
    var maxProjects = 64
    var maxTabsPerProject = 32
    var maxPanesPerTab = 16
    var maxLayoutDepth = 16
    var maxTotalPanes = 128
}

indirect enum WorkspaceLayoutNode: Codable, Equatable, Sendable {
    case leaf(paneID: String, workingDirectory: String)
    case group(axis: String, weights: [Double], children: [Self])

    var weights: [Double] {
        if case let .group(_, weights, _) = self { return weights }
        return []
    }

    var paneCount: Int {
        switch self {
        case .leaf: 1
        case let .group(_, _, children): children.reduce(0) { $0 + $1.paneCount }
        }
    }
}

struct WorkspaceSnapshot: Codable, Equatable, Sendable {
    var schemaVersion = 1
    var activeProjectPath: String?
    var projects: [Project]

    struct Project: Codable, Equatable, Sendable {
        var path: String
        var activeTabIndex: Int
        var tabs: [Tab]
    }
    struct Tab: Codable, Equatable, Sendable {
        var customName: String?
        var activePaneID: String
        var layout: WorkspaceLayoutNode
    }
}
```

为 enum 自定义 `kind/axis/weights/children/paneID/workingDirectory` 编解码。实现
`validated(limits:) -> WorkspaceSnapshot?`：schema 必须为 1；项目和标签按上限取前缀；
递归收集唯一非空 ID，只接受 `leftRight` / `topBottom`，分组至少两个子节点，权重数量匹配、
有限且为正并归一化；活动 ID 不在叶子集合时回退第一个 ID。项目与 pane 路径必须非空，
经 `expandingTildeInPath` 后必须是绝对路径。单标签任一语义错误返回 nil，调用方
`compactMap` 后继续其它标签。

- [ ] **Step 4: 实现 store 并测试独立 defaults suite**

```swift
struct WorkspaceStore {
    static let key = "ink.workspace.v1"
    private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) { self.defaults = defaults }

    func load(limits: WorkspaceLimits = .init()) -> WorkspaceSnapshot? {
        guard let data = defaults.data(forKey: Self.key),
              let decoded = try? JSONDecoder().decode(WorkspaceSnapshot.self, from: data) else {
            return nil
        }
        return decoded.validated(limits: limits)
    }

    @discardableResult
    func save(_ snapshot: WorkspaceSnapshot) -> Bool {
        guard let data = try? JSONEncoder().encode(snapshot) else { return false }
        defaults.set(data, forKey: Self.key)
        return true
    }
}
```

测试使用随机 `UserDefaults(suiteName:)`，保存后从新 store 读取；损坏 JSON 与 schema 2 均
返回 nil，且不会删除上次独立 suite 的其它 key。

- [ ] **Step 5: GREEN、检查并提交**

Run: `swift test --filter WorkspaceSnapshotTests && git diff --check`

Expected: PASS，diff check 无输出。

```bash
git add Sources/InkShell/WorkspaceSnapshot.swift Tests/InkShellTests/WorkspaceSnapshotTests.swift
git commit -m "feat(shell): 定义版本化工作区快照" -m "用局部语义校验和恢复预算阻止损坏状态拖垮启动。\n\nRefs #68"
```

### Task 2: 运行态捕获与完整标签恢复

**Files:**
- Modify: `Sources/InkShell/PaneLayout.swift`
- Modify: `Sources/InkShell/TerminalTab.swift`
- Modify: `Sources/InkShell/TerminalSession.swift`
- Create: `Sources/InkShell/WorkspaceStateMapper.swift`
- Create: `Tests/InkShellTests/WorkspaceStateMapperTests.swift`

**Interfaces:**
- Consumes: Task 1 的 `WorkspaceSnapshot.Tab`、`WorkspaceLayoutNode`。
- Produces: `PaneLayout.paneIDs`、恢复构造器、`snapshotWorkingDirectory`、`capture` 与 `restoreTab`。

- [ ] **Step 1: 写不变式、目录回退、嵌套比例和失败清理测试**

```swift
@Suite("工作区运行态映射")
@MainActor
struct WorkspaceStateMapperTests {
    @Test("恢复嵌套布局并生成新 pane 身份")
    func restoresNestedLayout() throws {
        let state = WorkspaceSnapshot.Tab(
            customName: "开发", activePaneID: "bottom",
            layout: .group(axis: "leftRight", weights: [1, 3], children: [
                .leaf(paneID: "left", workingDirectory: "~"),
                .group(axis: "topBottom", weights: [2, 1], children: [
                    .leaf(paneID: "top", workingDirectory: "~"),
                    .leaf(paneID: "bottom", workingDirectory: "~"),
                ]),
            ])
        )
        var created: [TerminalPane] = []
        let tab = try #require(WorkspaceStateMapper.restoreTab(
            state, projectDirectory: FileManager.default.homeDirectoryForCurrentUser
        ) { directory in
            let pane = TerminalPane(session: TerminalSession(
                size: .init(columns: 80, rows: 24), workingDirectory: directory
            ))
            created.append(pane)
            return pane
        })
        #expect(tab.customName == "开发")
        #expect(tab.paneCount == 3)
        #expect(tab.activePane === created[2])
        #expect(Set(tab.layout.paneIDs) == Set(created.map(\.id)))
    }
}
```

再测：缺失 pane 目录回退临时项目目录；项目目录也失效时回退 home；布局叶子集合与字典键
不一致时恢复构造器返回 nil；第三个 pane 创建失败时 `discardPane` 恰好收到前两个 pane。

- [ ] **Step 2: 运行测试确认 RED**

Run: `swift test --filter WorkspaceStateMapperTests`

Expected: FAIL，mapper、恢复构造器与 `paneIDs` 缺失。

- [ ] **Step 3: 增加模型不变式与会话目录回退**

```swift
extension PaneLayout {
    var paneIDs: [PaneID] {
        switch self {
        case let .leaf(id): [id]
        case let .group(_, _, _, children): children.flatMap(\.paneIDs)
        }
    }
}
```

`TerminalTab` 增加 `init?(restoredLayout:panes:activePaneID:customName:)`，要求叶子非空且唯一、
叶子集合等于字典键集合、活动 pane 存在。`TerminalSession.workingDirectory` 改为
`initialWorkingDirectory`，PTY 启动仍传原值，并增加：

```swift
var snapshotWorkingDirectory: String? {
    foregroundWorkingDirectory ?? initialWorkingDirectory
}
```

- [ ] **Step 4: 实现两阶段 mapper**

```swift
@MainActor
enum WorkspaceStateMapper {
    static func resolveWorkingDirectory(
        saved: String,
        projectDirectory: URL,
        homeDirectory: URL = FileManager.default.homeDirectoryForCurrentUser,
        fileManager: FileManager = .default
    ) -> String {
        let candidates = [
            URL(fileURLWithPath: (saved as NSString).expandingTildeInPath),
            projectDirectory, homeDirectory,
        ]
        for candidate in candidates {
            var isDirectory: ObjCBool = false
            if fileManager.fileExists(atPath: candidate.path, isDirectory: &isDirectory),
               isDirectory.boolValue { return candidate.standardizedFileURL.path }
        }
        return homeDirectory.standardizedFileURL.path
    }

    static func restoreTab(
        _ state: WorkspaceSnapshot.Tab,
        projectDirectory: URL,
        makePane: (String) -> TerminalPane?,
        discardPane: (TerminalPane) -> Void = {
            $0.session.detach()
            $0.session.terminate()
        }
    ) -> TerminalTab? {
        var panesByStoredID: [String: TerminalPane] = [:]
        for leaf in state.layout.leaves {
            let directory = resolveWorkingDirectory(
                saved: leaf.workingDirectory,
                projectDirectory: projectDirectory
            )
            guard let pane = makePane(directory) else {
                panesByStoredID.values.forEach(discardPane)
                return nil
            }
            panesByStoredID[leaf.paneID] = pane
        }
        guard let layout = state.layout.runtimeLayout(using: panesByStoredID),
              let active = panesByStoredID[state.activePaneID] else {
            panesByStoredID.values.forEach(discardPane)
            return nil
        }
        let panes = Dictionary(uniqueKeysWithValues: panesByStoredID.values.map { ($0.id, $0) })
        guard let tab = TerminalTab(
            restoredLayout: layout, panes: panes,
            activePaneID: active.id, customName: state.customName
        ) else {
            panesByStoredID.values.forEach(discardPane)
            return nil
        }
        return tab
    }

    static func capture(
        projects: [Project], activeProject: Project?
    ) -> WorkspaceSnapshot {
        WorkspaceSnapshot(
            activeProjectPath: activeProject?.displayName,
            projects: projects.map { project in
                WorkspaceSnapshot.Project(
                    path: project.displayName,
                    activeTabIndex: project.activeTabIndex,
                    tabs: project.tabs.compactMap { tab in
                        guard let layout = snapshotLayout(
                            tab.layout, panes: tab.panes,
                            fallbackDirectory: project.directory.path
                        ) else { return nil }
                        return WorkspaceSnapshot.Tab(
                            customName: tab.customName,
                            activePaneID: tab.activePaneID.rawValue.uuidString,
                            layout: layout
                        )
                    }
                )
            }
        )
    }
}

private extension WorkspaceLayoutNode {
    struct Leaf {
        let paneID: String
        let workingDirectory: String
    }

    var leaves: [Leaf] {
        switch self {
        case let .leaf(paneID, workingDirectory):
            [Leaf(paneID: paneID, workingDirectory: workingDirectory)]
        case let .group(_, _, children):
            children.flatMap(\.leaves)
        }
    }

    func runtimeLayout(using panes: [String: TerminalPane]) -> PaneLayout? {
        switch self {
        case let .leaf(paneID, _):
            guard let pane = panes[paneID] else { return nil }
            return .leaf(pane.id)
        case let .group(axis, weights, children):
            let runtimeChildren = children.compactMap { $0.runtimeLayout(using: panes) }
            guard runtimeChildren.count == children.count else { return nil }
            let runtimeAxis: PaneSplitAxis = axis == "leftRight" ? .leftRight : .topBottom
            return .group(
                id: SplitID(), axis: runtimeAxis,
                weights: weights, children: runtimeChildren
            )
        }
    }
}
```

在 `WorkspaceStateMapper` 内加入完整捕获 helper；任一子树缺 pane 时整标签返回 nil：

```swift
private static func snapshotLayout(
    _ layout: PaneLayout,
    panes: [PaneID: TerminalPane],
    fallbackDirectory: String
) -> WorkspaceLayoutNode? {
    switch layout {
    case let .leaf(id):
        guard let pane = panes[id] else { return nil }
        let path = pane.session.snapshotWorkingDirectory ?? fallbackDirectory
        return .leaf(
            paneID: id.rawValue.uuidString,
            workingDirectory: (path as NSString).abbreviatingWithTildeInPath
        )
    case let .group(_, axis, weights, children):
        let nodes = children.compactMap {
            snapshotLayout($0, panes: panes, fallbackDirectory: fallbackDirectory)
        }
        guard nodes.count == children.count else { return nil }
        let name = axis == .leftRight ? "leftRight" : "topBottom"
        return .group(axis: name, weights: weights, children: nodes)
    }
}
```

- [ ] **Step 5: GREEN、回归并提交**

Run: `swift test --filter WorkspaceStateMapperTests && swift test --filter TerminalTabTests && swift test --filter PaneLayoutTests && git diff --check`

Expected: 全部 PASS。

```bash
git add Sources/InkShell/PaneLayout.swift Sources/InkShell/TerminalTab.swift Sources/InkShell/TerminalSession.swift Sources/InkShell/WorkspaceStateMapper.swift Tests/InkShellTests/WorkspaceStateMapperTests.swift
git commit -m "feat(shell): 映射工作区快照与新会话" -m "恢复布局时重新生成运行时身份，并对失败标签执行完整清理。\n\nRefs #68"
```

### Task 3: 合并保存调度器

**Files:**
- Create: `Sources/InkShell/WorkspaceSaveScheduler.swift`
- Create: `Tests/InkShellTests/WorkspaceSaveSchedulerTests.swift`

**Interfaces:**
- Consumes: `WorkspaceStore.save(_:)`。
- Produces: `schedule(_:)`、`flush(_:)`、`cancel()`。

- [ ] **Step 1: 写合并与 flush 测试**

```swift
@Suite("工作区保存调度", .serialized)
@MainActor
struct WorkspaceSaveSchedulerTests {
    @Test("连续变化只保存最后快照")
    func coalesces() async throws {
        let defaults = UserDefaults(suiteName: UUID().uuidString)!
        let store = WorkspaceStore(defaults: defaults)
        let scheduler = WorkspaceSaveScheduler(store: store, delay: 0.01)
        scheduler.schedule(.init(activeProjectPath: "first", projects: []))
        scheduler.schedule(.init(activeProjectPath: "last", projects: []))
        try await Task.sleep(for: .milliseconds(40))
        #expect(store.load()?.activeProjectPath == "last")
    }

    @Test("flush 立即保存且旧任务不覆盖")
    func flushes() async throws {
        let defaults = UserDefaults(suiteName: UUID().uuidString)!
        let store = WorkspaceStore(defaults: defaults)
        let scheduler = WorkspaceSaveScheduler(store: store, delay: 0.03)
        scheduler.schedule(.init(activeProjectPath: "stale", projects: []))
        scheduler.flush(.init(activeProjectPath: "final", projects: []))
        try await Task.sleep(for: .milliseconds(60))
        #expect(store.load()?.activeProjectPath == "final")
    }
}
```

- [ ] **Step 2: 运行测试确认 RED**

Run: `swift test --filter WorkspaceSaveSchedulerTests`

Expected: FAIL，调度器缺失。

- [ ] **Step 3: 实现单 work item 调度器**

```swift
@MainActor
final class WorkspaceSaveScheduler {
    private let store: WorkspaceStore
    private let delay: TimeInterval
    private var pending: DispatchWorkItem?

    init(store: WorkspaceStore, delay: TimeInterval = 0.25) {
        self.store = store
        self.delay = delay
    }

    func schedule(_ snapshot: WorkspaceSnapshot) {
        pending?.cancel()
        let work = DispatchWorkItem { [store] in _ = store.save(snapshot) }
        pending = work
        DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: work)
    }

    func flush(_ snapshot: WorkspaceSnapshot) {
        pending?.cancel()
        pending = nil
        _ = store.save(snapshot)
    }

    func cancel() { pending?.cancel(); pending = nil }
}
```

work 执行后只清理属于自己的 pending；追加测试证明执行完成后再次 schedule 可保存新值。

- [ ] **Step 4: GREEN 并提交**

Run: `swift test --filter WorkspaceSaveSchedulerTests && git diff --check`

```bash
git add Sources/InkShell/WorkspaceSaveScheduler.swift Tests/InkShellTests/WorkspaceSaveSchedulerTests.swift
git commit -m "feat(shell): 合并工作区状态保存" -m "用单次延迟任务吸收连续结构变化，避免周期写入和输出热路径开销。\n\nRefs #68"
```

### Task 4: 主窗口启动恢复

**Files:**
- Modify: `Sources/InkShell/MainWindowController.swift`
- Create: `Tests/InkShellTests/WorkspaceRestoreWindowTests.swift`

**Interfaces:**
- Consumes: store、mapper、scheduler。
- Produces: 主窗口恢复活动项目/标签/pane，并为每个 pane 创建全新会话。

- [ ] **Step 1: 写无快照迁移和快照恢复集成测试**

用独立 defaults suite 和临时项目目录。测试初始化器注入 `workspaceStore` 与
`startPaneOverride: (TerminalSize, String) -> TerminalPane?`；override 返回未启动 session。
断言两标签、活动索引、嵌套 pane 数和传入目录；再测无快照回退旧 activeProjectPath、快照
不存在项目不会重新添加、`ProjectStore` 已剔除的缺失项目不会恢复、一个标签创建失败不影响
其它标签。恢复得到的每个 `TerminalSession` 都是新对象，`terminal.scrollback.count == 0`、
屏幕不含旧文本，证明快照没有复活 PTY 或终端内容。

```swift
let controller = MainWindowController(
    initialConfig: InkConfig(), configURL: configURL,
    configSyncService: ConfigSyncService(), workspaceStore: store,
    startPaneOverride: { size, directory in
        TerminalPane(session: TerminalSession(size: size, workingDirectory: directory))
    }
)
#expect(controller.workspaceTestState.tabCount == 2)
#expect(controller.workspaceTestState.activeTabIndex == 1)
#expect(controller.workspaceTestState.activePaneCount == 2)
```

- [ ] **Step 2: 运行测试确认 RED**

Run: `swift test --filter WorkspaceRestoreWindowTests`

Expected: FAIL，初始化接口与恢复状态缺失。

- [ ] **Step 3: 注入依赖并恢复**

增加 store、scheduler、override 属性；初始化顺序固定为 `loadProjects()`、
`restoreWorkspace()`、`buildContent()`。restore 只按标准化路径关联 `ProjectStore` 已加载项目，
逐标签调用 mapper；活动项目优先快照路径，无快照回退旧 active key。`startPane` 先检查
override，否则走真实 `TerminalSession.start()`。测试状态只在 `@testable` 可见范围暴露值。

```swift
private func restoreWorkspace(from snapshot: WorkspaceSnapshot) {
    for project in projects {
        guard let state = snapshot.projects.first(where: {
            URL(fileURLWithPath: ($0.path as NSString).expandingTildeInPath)
                .standardizedFileURL == project.directory.standardizedFileURL
        }) else { continue }
        project.tabs = state.tabs.compactMap { state in
            WorkspaceStateMapper.restoreTab(state, projectDirectory: project.directory) {
                [weak self] directory in
                self?.startPane(size: .init(columns: 80, rows: 24), workingDirectory: directory)
            }
        }
        project.activeTabIndex = min(max(0, state.activeTabIndex), max(0, project.tabs.count - 1))
    }
}
```

- [ ] **Step 4: GREEN、回归并提交**

Run: `swift test --filter WorkspaceRestoreWindowTests && swift test --filter ProjectSidebarTests && swift test --filter TerminalSplitCommandTests && git diff --check`

```bash
git add Sources/InkShell/MainWindowController.swift Tests/InkShellTests/WorkspaceRestoreWindowTests.swift
git commit -m "feat(shell): 启动时恢复会话布局" -m "只关联仍存在的项目，并为每个恢复 pane 创建全新会话。\n\nRefs #68"
```

### Task 5: 结构变化保存与退出顺序

**Files:**
- Modify: `Sources/InkShell/MainWindowController.swift`
- Modify: `Tests/InkShellTests/WorkspaceRestoreWindowTests.swift`

**Interfaces:**
- Consumes: mapper capture、scheduler schedule/flush。
- Produces: 所有成功结构变化均 dirty，关闭时先保存后清空。

- [ ] **Step 1: 写触发覆盖与关闭顺序测试**

fixture 依次执行新建/重命名/选择/关闭标签，分屏/激活/比例/关闭 pane，shell exit，项目
选择/重排/删除；每种操作后 flush 测试 hook 并断言快照改变。关闭测试构造两标签嵌套布局，
调用 `windowWillClose` 后断言 store 仍是关闭前结构，而运行态 pane 已为 0。

```swift
controller.windowWillClose(Notification(name: NSWindow.willCloseNotification))
let saved = try #require(store.load())
#expect(saved.projects[0].tabs.count == 2)
#expect(saved.projects[0].tabs[0].layout.paneCount == 2)
#expect(controller.workspaceTestState.totalPaneCount == 0)
```

- [ ] **Step 2: 运行测试确认 RED**

Run: `swift test --filter WorkspaceRestoreWindowTests`

Expected: FAIL，保存值未跟随变化或关闭后为空。

- [ ] **Step 3: 接入统一 dirty 与 flush**

```swift
private func workspaceDidChange() {
    guard !isClosingWorkspace else { return }
    workspaceSaveScheduler.schedule(
        WorkspaceStateMapper.capture(projects: projects, activeProject: activeProject)
    )
}

private func flushWorkspace() {
    workspaceSaveScheduler.flush(
        WorkspaceStateMapper.capture(projects: projects, activeProject: activeProject)
    )
}
```

仅在操作成功后调用：new/select/rename/close tab，split/activate/close pane，weights 回调，shell
exit，项目增删/重排/选择。`persistProjects()` 保存元数据后也 dirty。`windowWillClose` 第一项先
置 `isClosingWorkspace` 并 flush，再 detach、terminate、removeAll；回调不能覆盖最终快照。

- [ ] **Step 4: GREEN 并提交**

Run: `swift test --filter Workspace && swift test --filter TerminalSplitCommandTests && swift test --filter TerminalTabTests && swift test --filter ProjectSidebarLayoutTests && git diff --check`

```bash
git add Sources/InkShell/MainWindowController.swift Tests/InkShellTests/WorkspaceRestoreWindowTests.swift
git commit -m "feat(shell): 持续保存会话结构" -m "合并交互变化并在终止 PTY 前强制落盘，避免退出时覆盖有效布局。\n\nRefs #68"
```

### Task 6: 文档、性能证据与完整验收

**Files:**
- Modify: `Tests/InkShellTests/WorkspaceSnapshotTests.swift`
- Modify: `docs/roadmap.md`
- Modify: `docs/perf.md`

**Interfaces:**
- Consumes: 完整功能。
- Produces: roadmap 状态、快照规模证据、全量门禁。

- [ ] **Step 1: 加上限快照测量**

构造 128 个单 pane 标签，测量 100 次 JSON 编码/解码/校验。只断言数据小于 1 MiB且往返
正确，打印耗时，不设机器相关阈值。

```swift
let clock = ContinuousClock()
let duration = try clock.measure {
    for _ in 0..<100 {
        let data = try JSONEncoder().encode(snapshot)
        _ = try #require(try JSONDecoder().decode(
            WorkspaceSnapshot.self, from: data
        ).validated())
    }
}
let bytes = try JSONEncoder().encode(snapshot).count
#expect(bytes < 1_048_576)
print("workspace snapshot: \(bytes) bytes, 100 roundtrips: \(duration)")
```

- [ ] **Step 2: 运行 Release 测量并记录**

Run: `swift test -c release --filter WorkspaceSnapshotTests 2>&1 | tee /tmp/ink-issue68-workspace-perf.txt`

Expected: PASS 并输出字节数/耗时。把硬件、系统、快照字节数、单次平均、250 ms 合并策略、
128 pane 上限和“PTY 启动不属于 JSON 成本”写入 `docs/perf.md`。

- [ ] **Step 3: 同步 roadmap**

把对应条目改为：

```markdown
- [x] 会话布局恢复：项目、标签名称、工作目录、递归分屏与比例；重启后启动新 shell，
  不恢复 PTY 或 scrollback
```

Finder 拖入、多 pane 键盘操作、命令状态与通知保持未完成；下一项仍是命令状态与通知。

- [ ] **Step 4: 完整验证**

Run: `swift test`

Expected: 337 个既有测试加 Issue #68 新测试全部 PASS，0 failures。

Run: `swift build`

Expected: `Build complete!`，无 warning/error。

Run: `git diff --check && git status --short`

Expected: diff check 无输出，status 只含 #68 文件。

- [ ] **Step 5: 提交验收记录**

```bash
git add docs/roadmap.md docs/perf.md Tests/InkShellTests/WorkspaceSnapshotTests.swift
git commit -m "docs: 记录会话恢复验收结果" -m "同步 roadmap 状态并留下快照规模与编解码成本证据。\n\nRefs #68"
```

- [ ] **Step 6: 评审、PR、合并和 main 复验**

执行 `superpowers:requesting-code-review`，对照 Issue、设计和计划修复所有 P0/P1/Important
问题并复验。推送分支，创建标题 `feat(shell): 恢复会话布局` 的 PR；描述包含改动说明、
`swift test`、`swift build`、Release 测量、风险、文档、无发布，以及唯一 `Closes #68`。
checks 通过且用户已授权合并后 squash 合入 main，确认 Issue 自动关闭、删除远端分支与
worktree；main 再运行 `swift test && swift build`，不创建 tag。随后重读 roadmap 并进入
“命令状态与通知”。
