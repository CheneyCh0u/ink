# Finder 项目拖入 Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** 允许用户把 Finder 中的一个或多个本地目录拖到项目侧边栏，并按稳定顺序批量加入、去重和选择，同时让文件选择器复用同一条导入路径。

**Architecture:** 在 `InkShell` 新增 Foundation-only 的导入规划器，统一目录校验、路径身份、批内去重和选择决策。侧边栏根视图只负责区分内部排序与外部文件 URL 拖入；`MainWindowController` 在落下时重新规划并一次性更新项目数组，沿用既有 `selectProject(at:)` 创建唯一首个会话。

**Tech Stack:** Swift 6、Foundation、AppKit、Swift Testing、SwiftPM。

## Global Constraints

- Issue：[#72](https://github.com/CheneyCh0u/ink/issues/72)，只在 `agent/issue-72-finder-project-drop` 分支实现。
- `TerminalCore`、PTY、Metal、grid 和 scrollback 不改动；不引入第三方依赖。
- 外部 Finder 拖入返回 `.copy`，内部项目行排序继续返回 `.move`，内部类型优先。
- 只接受仍存在的本地目录；普通文件、非文件 URL 和不存在路径静默忽略。
- URL 身份统一使用 `standardizedFileURL.path`；保留符号链接本身，不解析真实路径。
- 新项目保持未置顶并追加到普通项目末尾；不改变置顶项目顺序。
- 先选择第一个新增项目；没有新增时选择 payload 中第一个已存在项目；全部无效则无操作。
- Finder payload 顺序必须贯穿校验、去重、追加与选择。
- `ProjectDropView` 在拖动期间只做轻量校验；真正落下时控制器重新规划，防止拖动期间文件状态变化。
- 每一步先运行指定失败测试，确认失败原因，再写最小实现，再运行通过测试并提交。

---

### Task 1: 建立目录导入规划器

**Files:**

- Create: `Sources/InkShell/ProjectDirectoryImportPlanner.swift`
- Create: `Tests/InkShellTests/ProjectDirectoryImportTests.swift`

- [ ] **Step 1: 写目录校验、批内去重和新项目选择测试**

```swift
import Foundation
import Testing
@testable import InkShell

@Suite("项目目录导入规划")
struct ProjectDirectoryImportTests {
    @Test("只保留存在的本地目录并按输入顺序去重")
    func validatesDirectoriesInPayloadOrder() throws {
        let fixture = try DirectoryImportFixture()
        defer { fixture.cleanUp() }
        let first = try fixture.makeDirectory("first")
        let second = try fixture.makeDirectory("second")
        let file = try fixture.makeFile("notes.txt")

        let result = ProjectDirectoryImportPlanner.validDirectories(from: [
            first,
            URL(string: "https://example.com/project")!,
            file,
            first.appendingPathComponent("..", isDirectory: true)
                .appendingPathComponent("first", isDirectory: true),
            fixture.root.appendingPathComponent("missing", isDirectory: true),
            second,
        ])

        #expect(result == [first.standardizedFileURL, second.standardizedFileURL])
    }

    @Test("追加所有新目录并选择第一个新增项目")
    func plansNewDirectories() throws {
        let fixture = try DirectoryImportFixture()
        defer { fixture.cleanUp() }
        let existing = try fixture.makeDirectory("existing")
        let first = try fixture.makeDirectory("first")
        let second = try fixture.makeDirectory("second")

        let plan = ProjectDirectoryImportPlanner.plan(
            candidates: [existing, first, second],
            existingDirectories: [existing]
        )

        #expect(plan == ProjectDirectoryImportPlan(
            directoriesToAdd: [first.standardizedFileURL, second.standardizedFileURL],
            selectedIndex: 1
        ))
    }

    @Test("没有新增目录时选择 payload 中第一个已有项目")
    func selectsFirstExistingDuplicate() throws {
        let fixture = try DirectoryImportFixture()
        defer { fixture.cleanUp() }
        let first = try fixture.makeDirectory("first")
        let second = try fixture.makeDirectory("second")

        let plan = ProjectDirectoryImportPlanner.plan(
            candidates: [second, first],
            existingDirectories: [first, second]
        )

        #expect(plan.directoriesToAdd.isEmpty)
        #expect(plan.selectedIndex == 1)
    }

    @Test("全部无效时不追加也不选择")
    func rejectsInvalidPayload() throws {
        let fixture = try DirectoryImportFixture()
        defer { fixture.cleanUp() }
        let file = try fixture.makeFile("notes.txt")

        let plan = ProjectDirectoryImportPlanner.plan(
            candidates: [file],
            existingDirectories: []
        )

        #expect(plan == ProjectDirectoryImportPlan(
            directoriesToAdd: [],
            selectedIndex: nil
        ))
    }

    @Test("符号链接目录保留链接路径")
    func preservesDirectorySymlink() throws {
        let fixture = try DirectoryImportFixture()
        defer { fixture.cleanUp() }
        let target = try fixture.makeDirectory("target")
        let link = fixture.root.appendingPathComponent("link", isDirectory: true)
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: target)

        let result = ProjectDirectoryImportPlanner.validDirectories(from: [link])

        #expect(result == [link.standardizedFileURL])
    }
}
```

测试文件底部加入真实临时目录夹具，所有写入均限制在 UUID 临时根目录：

```swift
private struct DirectoryImportFixture {
    let root = FileManager.default.temporaryDirectory
        .appendingPathComponent("ink-directory-import-\(UUID().uuidString)", isDirectory: true)

    init() throws {
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    func makeDirectory(_ name: String) throws -> URL {
        let url = root.appendingPathComponent(name, isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    func makeFile(_ name: String) throws -> URL {
        let url = root.appendingPathComponent(name)
        try Data().write(to: url)
        return url
    }

    func cleanUp() {
        try? FileManager.default.removeItem(at: root)
    }
}
```

- [ ] **Step 2: 运行单文件测试并确认编译失败**

Run: `swift test --filter ProjectDirectoryImportTests`

Expected: FAIL，提示找不到 `ProjectDirectoryImportPlanner` 和 `ProjectDirectoryImportPlan`。

- [ ] **Step 3: 实现最小规划器**

`Sources/InkShell/ProjectDirectoryImportPlanner.swift`：

```swift
import Foundation

struct ProjectDirectoryImportPlan: Equatable {
    let directoriesToAdd: [URL]
    let selectedIndex: Int?
}

enum ProjectDirectoryImportPlanner {
    static func validDirectories(from candidates: [URL]) -> [URL] {
        var seen = Set<String>()
        return candidates.compactMap { candidate in
            guard candidate.isFileURL else { return nil }
            let directory = candidate.standardizedFileURL
            var isDirectory: ObjCBool = false
            guard FileManager.default.fileExists(
                atPath: directory.path,
                isDirectory: &isDirectory
            ), isDirectory.boolValue, seen.insert(directory.path).inserted else {
                return nil
            }
            return directory
        }
    }

    static func plan(
        candidates: [URL],
        existingDirectories: [URL]
    ) -> ProjectDirectoryImportPlan {
        let valid = validDirectories(from: candidates)
        var existingIndices: [String: Int] = [:]
        for (index, directory) in existingDirectories.enumerated() {
            let path = directory.standardizedFileURL.path
            if existingIndices[path] == nil {
                existingIndices[path] = index
            }
        }
        let additions = valid.filter { existingIndices[$0.path] == nil }
        if !additions.isEmpty {
            return ProjectDirectoryImportPlan(
                directoriesToAdd: additions,
                selectedIndex: existingDirectories.count
            )
        }
        let selectedIndex = valid.lazy.compactMap { existingIndices[$0.path] }.first
        return ProjectDirectoryImportPlan(
            directoriesToAdd: [],
            selectedIndex: selectedIndex
        )
    }
}
```

- [ ] **Step 4: 运行规划器测试**

Run: `swift test --filter ProjectDirectoryImportTests`

Expected: PASS，5 个测试通过。

- [ ] **Step 5: 检查 diff 并提交**

Run: `git diff --check && git status --short`

Commit:

```text
feat(shell): 规划批量项目导入

集中校验目录、稳定去重并计算批量导入后的选择位置，避免 UI 入口各自实现路径身份规则。

Refs #72
```

---

### Task 2: 解码侧边栏拖拽并保留内部排序

**Files:**

- Modify: `Sources/InkShell/SidebarViewController.swift:71-80, 88-100, 222-265`
- Create: `Tests/InkShellTests/SidebarProjectDropTests.swift`

- [ ] **Step 1: 写 pasteboard 解码测试**

```swift
import AppKit
import Foundation
import Testing
@testable import InkShell

@Suite("侧边栏项目拖入", .serialized)
@MainActor
struct SidebarProjectDropTests {
    @Test("内部项目拖动优先解码为排序")
    func decodesInternalReorderFirst() throws {
        let pasteboard = makePasteboard()
        pasteboard.setString("3", forType: SidebarViewController.dragType)
        pasteboard.writeObjects([NSURL(fileURLWithPath: "/tmp/project")])

        #expect(SidebarProjectDropDecoder.intent(from: pasteboard) == .reorder(3))
    }

    @Test("Finder 多目录保持 pasteboard 顺序")
    func decodesFinderDirectoriesInOrder() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("ink-sidebar-drop-\(UUID().uuidString)")
        let first = root.appendingPathComponent("first", isDirectory: true)
        let second = root.appendingPathComponent("second", isDirectory: true)
        try FileManager.default.createDirectory(at: first, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: second, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let pasteboard = makePasteboard()
        pasteboard.writeObjects([first as NSURL, second as NSURL])

        #expect(SidebarProjectDropDecoder.intent(from: pasteboard) == .importDirectories([
            first.standardizedFileURL,
            second.standardizedFileURL,
        ]))
    }

    @Test("普通文件拖入被拒绝")
    func rejectsFiles() throws {
        let file = FileManager.default.temporaryDirectory
            .appendingPathComponent("ink-sidebar-drop-\(UUID().uuidString).txt")
        try Data().write(to: file)
        defer { try? FileManager.default.removeItem(at: file) }
        let pasteboard = makePasteboard()
        pasteboard.writeObjects([file as NSURL])

        #expect(SidebarProjectDropDecoder.intent(from: pasteboard) == .reject)
    }

    private func makePasteboard() -> NSPasteboard {
        let pasteboard = NSPasteboard(name: .init("ink.sidebar-drop.\(UUID().uuidString)"))
        pasteboard.clearContents()
        return pasteboard
    }
}
```

- [ ] **Step 2: 运行测试并确认编译失败**

Run: `swift test --filter SidebarProjectDropTests`

Expected: FAIL，提示找不到 `SidebarProjectDropDecoder` 和 `SidebarProjectDropIntent`。

- [ ] **Step 3: 增加可测的拖拽意图解码器**

在 `SidebarViewController.swift` 的控制器定义之前加入：

```swift
enum SidebarProjectDropIntent: Equatable {
    case reorder(Int)
    case importDirectories([URL])
    case reject
}

enum SidebarProjectDropDecoder {
    static func intent(from pasteboard: NSPasteboard) -> SidebarProjectDropIntent {
        if let raw = pasteboard.string(forType: SidebarViewController.dragType),
           let index = Int(raw) {
            return .reorder(index)
        }
        let urls = (pasteboard.readObjects(
            forClasses: [NSURL.self],
            options: [.urlReadingFileURLsOnly: true]
        ) as? [NSURL] ?? []).map { $0 as URL }
        let directories = ProjectDirectoryImportPlanner.validDirectories(from: urls)
        return directories.isEmpty ? .reject : .importDirectories(directories)
    }
}
```

- [ ] **Step 4: 让根视图接收两类拖动**

给 `SidebarViewController` 增加：

```swift
var onImportDirectories: (([URL]) -> Void)?
```

在 `loadView()` 中接线：

```swift
root.onImportDirectories = { [weak self] in self?.onImportDirectories?($0) }
```

将 `ProjectDropView` 从 `private` 调整为模块内可见，增加回调并注册两类 pasteboard：

```swift
@MainActor
final class ProjectDropView: NSVisualEffectView {
    weak var rowStack: NSStackView?
    var onDrop: ((Int, Int) -> Void)?
    var onImportDirectories: (([URL]) -> Void)?

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        registerForDraggedTypes([SidebarViewController.dragType, .fileURL])
    }
```

用统一意图决定系统光标：

```swift
override func draggingEntered(_ sender: any NSDraggingInfo) -> NSDragOperation {
    operation(for: SidebarProjectDropDecoder.intent(from: sender.draggingPasteboard))
}

override func draggingUpdated(_ sender: any NSDraggingInfo) -> NSDragOperation {
    operation(for: SidebarProjectDropDecoder.intent(from: sender.draggingPasteboard))
}

private func operation(for intent: SidebarProjectDropIntent) -> NSDragOperation {
    switch intent {
    case .reorder: .move
    case .importDirectories: .copy
    case .reject: []
    }
}
```

`performDragOperation` 先分派外部导入，内部排序沿用现有 y 落点计算：

```swift
override func performDragOperation(_ sender: any NSDraggingInfo) -> Bool {
    switch SidebarProjectDropDecoder.intent(from: sender.draggingPasteboard) {
    case let .importDirectories(directories):
        onImportDirectories?(directories)
        return true
    case let .reorder(from):
        return performReorder(from: from, sender: sender)
    case .reject:
        return false
    }
}

private func performReorder(from: Int, sender: any NSDraggingInfo) -> Bool {
    guard let rows = rowStack?.arrangedSubviews, !rows.isEmpty else { return false }
    let point = convert(sender.draggingLocation, from: nil)
    var target = rows.count - 1
    for (index, row) in rows.enumerated() {
        let frame = row.convert(row.bounds, to: self)
        if point.y < frame.midY { continue }
        target = index
        break
    }
    if target != from { onDrop?(from, target) }
    return true
}
```

- [ ] **Step 5: 运行侧边栏和既有布局测试**

Run: `swift test --filter SidebarProjectDropTests && swift test --filter ProjectSidebar`

Expected: PASS；新增 3 个测试通过，既有侧边栏测试无回归。

- [ ] **Step 6: 检查 diff 并提交**

Run: `git diff --check && git status --short`

Commit:

```text
feat(sidebar): 接受 Finder 目录拖入

在侧边栏根视图区分内部排序与外部目录复制，并用可测试解码器保持 Finder 的批量顺序。

Refs #72
```

---

### Task 3: 窗口一次性应用导入计划

**Files:**

- Modify: `Sources/InkShell/MainWindowController.swift:330-345, 631-660`
- Create: `Tests/InkShellTests/ProjectImportWindowTests.swift`

- [ ] **Step 1: 写窗口级批量导入测试**

测试夹具创建一个已有项目、独立 `UserDefaults` 和 `WorkspaceStore`，用 `startPaneOverride` 记录 pane 创建次数。控制器初始化后先清空异步首会话任务，再记录基线：

```swift
@Suite("主窗口项目导入", .serialized)
@MainActor
struct ProjectImportWindowTests {
    @Test("批量导入只为第一个新增项目创建首个会话")
    func importsBatchAndStartsOnlySelectedProject() throws {
        let fixture = try ProjectImportWindowFixture()
        defer { fixture.cleanUp() }
        let controller = fixture.makeController(existing: [fixture.existing])
        let baseline = fixture.startedDirectories.count

        controller.importProjectDirectories([fixture.first, fixture.second])

        #expect(fixture.storedDirectories() == [
            fixture.existing.standardizedFileURL,
            fixture.first.standardizedFileURL,
            fixture.second.standardizedFileURL,
        ])
        #expect(ProjectStore.activeProjectPath(in: fixture.defaults)
            == (fixture.first.path as NSString).abbreviatingWithTildeInPath)
        #expect(fixture.startedDirectories.count == baseline + 1)
        #expect(fixture.startedDirectories.last == fixture.first.path)
    }

    @Test("全部重复时不追加并选择 payload 中第一个已有项目")
    func selectsExistingDuplicateWithoutStartingAnotherPane() throws {
        let fixture = try ProjectImportWindowFixture()
        defer { fixture.cleanUp() }
        let controller = fixture.makeController(existing: [fixture.existing, fixture.first])
        let baseline = fixture.startedDirectories.count

        controller.importProjectDirectories([fixture.first, fixture.existing])

        #expect(fixture.storedDirectories() == [
            fixture.existing.standardizedFileURL,
            fixture.first.standardizedFileURL,
        ])
        #expect(ProjectStore.activeProjectPath(in: fixture.defaults)
            == (fixture.first.path as NSString).abbreviatingWithTildeInPath)
        #expect(fixture.startedDirectories.count == baseline + 1)
    }
}
```

`ProjectImportWindowFixture` 必须：

- 在 UUID 临时根目录创建 `existing`、`first`、`second` 三个真实目录。
- `makeController(existing:)` 先 `ProjectStore.save`，并为第一个已有项目向独立 `WorkspaceStore` 写入一个 leaf tab，避免控制器安排异步首会话；再创建 `MainWindowController`。`startPaneOverride` 闭包把 `workingDirectory` 追加到 `startedDirectories` 并返回 `TerminalPane(session: TerminalSession(...))`。
- `storedDirectories()` 用 `ProjectStore.load(defaults:)` 读取并返回 `directory.standardizedFileURL`。
- `cleanUp()` 关闭窗口、移除 defaults domain 和临时根目录。

第二个测试的基线断言允许 `selectProject` 为原先空的已有项目创建一个 pane，因此应是 `baseline + 1`；核心是不创建新项目且只切换一次。

- [ ] **Step 2: 运行窗口测试并确认编译失败**

Run: `swift test --filter ProjectImportWindowTests`

Expected: FAIL，提示 `MainWindowController` 没有 `importProjectDirectories`。

- [ ] **Step 3: 接入侧边栏回调和统一导入入口**

在 `buildContent()` 的侧边栏回调区域增加：

```swift
sidebarVC.onImportDirectories = { [weak self] directories in
    self?.importProjectDirectories(directories)
}
```

在项目操作区域增加模块内方法：

```swift
func importProjectDirectories(_ candidates: [URL]) {
    let plan = ProjectDirectoryImportPlanner.plan(
        candidates: candidates,
        existingDirectories: projects.map(\.directory)
    )
    guard plan.selectedIndex != nil || !plan.directoriesToAdd.isEmpty else { return }
    projects.append(contentsOf: plan.directoriesToAdd.map { Project(directory: $0) })
    guard let selectedIndex = plan.selectedIndex else { return }
    selectProject(at: selectedIndex)
}
```

不要在追加循环中调用 `persistProjects()`、`refreshChrome()` 或 `selectProject(at:)`；最终的单次 `selectProject(at:)` 负责持久化、选择和为选中空项目创建首个会话。

- [ ] **Step 4: 让文件选择器复用统一入口并支持多选**

把 `newProject(_:)` 的 panel 设置改为：

```swift
panel.allowsMultipleSelection = true
```

完成回调只负责把 `panel.urls` 交给统一入口：

```swift
panel.beginSheetModal(for: window) { [weak self] response in
    guard let self, response == .OK else { return }
    let directories = panel.urls
    MainActor.assumeIsolated {
        self.importProjectDirectories(directories)
    }
}
```

- [ ] **Step 5: 运行窗口、规划器和侧边栏测试**

Run: `swift test --filter ProjectImportWindowTests && swift test --filter ProjectDirectoryImportTests && swift test --filter SidebarProjectDropTests`

Expected: PASS。

- [ ] **Step 6: 检查 diff 并提交**

Run: `git diff --check && git status --short`

Commit:

```text
feat(shell): 批量应用拖入项目

让 Finder 拖入与文件选择器共用一次性导入路径，只为最终选中的新项目启动首个会话。

Refs #72
```

---

### Task 4: 全量验证、手工验收和 PR

**Files:**

- Modify only if verification finds an Issue #72 regression.

- [ ] **Step 1: 运行格式与全量自动验证**

Run:

```bash
git diff --check origin/main...HEAD
swift package clean
swift test
swift build
```

Expected: `git diff --check` 无输出；全部测试和构建成功。

- [ ] **Step 2: 手工验证 AppKit 拖拽行为**

Run: `swift run ink`

依次确认：

1. 展开侧边栏时从 Finder 拖一个目录，光标为复制，项目追加并选中。
2. 图标侧边栏时拖多个目录，顺序与 Finder payload 一致，只选中第一个新增项目。
3. 同一批含目录、普通文件、重复目录时，只加入首次出现的有效目录。
4. 再拖已有目录时不新增，只切换到该项目。
5. 内部项目行拖动仍为移动光标，且不跨置顶/普通分组。
6. 文件选择器允许多选目录，并得到与拖入一致的结果。

- [ ] **Step 3: 自审范围、热路径与文档一致性**

Run:

```bash
git diff --stat origin/main...HEAD
git diff origin/main...HEAD -- Sources/InkShell Tests/InkShellTests docs/superpowers
rg -n "TODO|FIXME|待补|省略" Sources/InkShell Tests/InkShellTests docs/superpowers/plans/2026-07-22-finder-project-drop.md
```

Expected: 只有 Issue #72 文件；无 TerminalCore/PTY/Metal 改动、无新依赖、无占位内容。

- [ ] **Step 4: 推送并创建关闭 Issue 的 PR**

Run:

```bash
git push -u origin agent/issue-72-finder-project-drop
gh pr create --base main --head agent/issue-72-finder-project-drop \
  --title "feat: 支持从 Finder 拖入项目目录" \
  --body-file /tmp/ink-issue-72-pr.md
```

PR 正文必须包含：设计摘要、测试证据、手工验证结果，以及独立一行 `Closes #72`。

- [ ] **Step 5: 检查 PR、合并并清理**

Run: `gh pr checks <PR_NUMBER> --watch`

检查通过后完成自审；仅在仓库权限和保护规则允许时合并。合并后确认 Issue #72 已关闭、`main` 与 `origin/main` 同步且干净，再删除 Issue worktree 和已合并本地分支。不创建发布标签。
