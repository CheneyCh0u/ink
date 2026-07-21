# Active Session Close Confirmation Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** 在关闭范围内仍有非 shell 前台程序时，用一次 macOS 原生确认阻止误终止，并让空闲 shell 继续直接关闭。

**Architecture:** InkPTY 在关闭时生成一次前台进程快照，以启动 shell 的进程身份而非名称白名单区分空闲 shell 与前台作业。InkShell 用纯值模型聚合快照并生成文案，由可注入的协调器统一执行或取消关闭；`MainWindowController` 只负责收集目标 pane，`AppDelegate` 只负责把 Command-Q 结果映射为 AppKit 终止答复。

**Tech Stack:** Swift 6 strict concurrency、AppKit `NSAlert`、SwiftPM、swift-testing；最低 macOS 14.0；不新增第三方依赖。

## Global Constraints

- `TerminalCore` 不得引入 AppKit 或 Metal 依赖。
- 不修改 grid、scrollback、Metal 渲染或终端热路径。
- 前台进程查询只在用户发起关闭时执行，不增加轮询、定时器或常驻缓存。
- UI 使用系统 `NSAlert`，跟随 Ink 的 system、light、dark appearance，并支持 Escape 取消。
- 空闲自定义 shell 必须直接关闭；非 shell 前台程序和查询失败必须安全确认。
- 一次用户动作最多弹一个确认框；Command-Q 后的窗口关闭不得重复确认。
- 注释与文档使用中文，代码标识符使用英文，提交信息使用中文并包含 `Refs #52`。
- 完成标准为 `swift test` 全绿且 `swift build` 零警告；本改动不要求 Instruments 采样。

---

## File Structure

- Modify `Sources/InkPTY/PTYSession.swift`: 保存实际 shell 身份并提供前台进程快照。
- Modify `Tests/InkPTYTests/PTYSessionTests.swift`: 覆盖空闲 shell、前台作业、`exec` 替换、退出和查询失败。
- Create `Sources/InkShell/SessionCloseConfirmation.swift`: 关闭目标、风险文案、原生 presenter 与一次性退出许可协调器。
- Create `Tests/InkShellTests/SessionCloseConfirmationTests.swift`: 纯逻辑文案和协调器行为测试。
- Modify `Sources/InkShell/TerminalSession.swift`: 把 InkPTY 快照暴露给外壳关闭流程。
- Modify `Sources/InkShell/MainWindowController.swift`: 对分屏、标签、项目、窗口和全应用范围统一收集 pane 并延迟破坏性变更。
- Modify `Sources/InkShell/AppDelegate.swift`: 将 Command-Q 接入应用终止许可。
- Modify `Tests/InkShellTests/TerminalSplitCommandTests.swift`: 保留空闲 shell 无提示关闭的回归覆盖。

---

### Task 1: InkPTY 前台进程快照

**Files:**
- Modify: `Sources/InkPTY/PTYSession.swift`
- Test: `Tests/InkPTYTests/PTYSessionTests.swift`

**Interfaces:**
- Consumes: `childPID`、`masterFD`、启动时的 `SHELL` 路径、`tcgetpgrp(3)` 和现有 `sysctl` 进程名查询。
- Produces: `PTYSession.ForegroundProcess` 和 `public func foregroundProcess() -> ForegroundProcess`，供 `TerminalSession` 使用；现有 `foregroundProcessName()` 保持兼容。

- [ ] **Step 1: 写出分类器失败测试**

在 `PTYSessionTests` 中加入不启动真实 PTY 的确定性测试：

```swift
@Test("前台进程按实际 shell 身份分类")
func classifiesForegroundProcessBySpawnedShellIdentity() {
    #expect(PTYSession.classifyForegroundProcess(
        childPID: 42,
        shellName: "nu",
        masterIsOpen: true,
        foregroundPGID: 42,
        foregroundName: "nu"
    ) == .shell(name: "nu"))

    #expect(PTYSession.classifyForegroundProcess(
        childPID: 42,
        shellName: "nu",
        masterIsOpen: true,
        foregroundPGID: 99,
        foregroundName: "claude"
    ) == .program(name: "claude"))

    #expect(PTYSession.classifyForegroundProcess(
        childPID: 42,
        shellName: "nu",
        masterIsOpen: true,
        foregroundPGID: 42,
        foregroundName: "vim"
    ) == .program(name: "vim"))
}

@Test("退出与查询失败采用安全分类")
func classifiesExitedAndUnknownForegroundProcess() {
    #expect(PTYSession.classifyForegroundProcess(
        childPID: -1,
        shellName: "zsh",
        masterIsOpen: false,
        foregroundPGID: nil,
        foregroundName: nil
    ) == .exited)

    #expect(PTYSession.classifyForegroundProcess(
        childPID: 42,
        shellName: "zsh",
        masterIsOpen: true,
        foregroundPGID: nil,
        foregroundName: nil
    ) == .program(name: nil))
}
```

- [ ] **Step 2: 运行定向测试并确认失败**

Run:

```bash
swift test --filter PTYSessionTests
```

Expected: 编译失败，提示 `PTYSession.classifyForegroundProcess` 和 `ForegroundProcess` 尚不存在。

- [ ] **Step 3: 实现最小快照类型与分类器**

在 `PTYSession` 内加入类型和 shell 名称状态：

```swift
public enum ForegroundProcess: Equatable, Sendable {
    case exited
    case shell(name: String)
    case program(name: String?)
}

private var shellName: String?
```

在 `start` 取得 `shellPath` 后、`forkpty` 前记录：

```swift
shellName = URL(fileURLWithPath: shellPath).lastPathComponent
```

加入纯分类器：

```swift
static func classifyForegroundProcess(
    childPID: pid_t,
    shellName: String?,
    masterIsOpen: Bool,
    foregroundPGID: pid_t?,
    foregroundName: String?
) -> ForegroundProcess {
    guard childPID > 0, masterIsOpen else { return .exited }
    guard let foregroundPGID, foregroundPGID > 0 else {
        return .program(name: nil)
    }
    if foregroundPGID == childPID,
       let shellName,
       foregroundName == shellName {
        return .shell(name: shellName)
    }
    return .program(name: foregroundName)
}
```

把现有进程名读取抽成以下函数，再实现一次快照：

```swift
private func processName(for pid: pid_t) -> String? {
    var mib: [Int32] = [CTL_KERN, KERN_PROC, KERN_PROC_PID, pid]
    var info = kinfo_proc()
    var size = MemoryLayout<kinfo_proc>.stride
    guard sysctl(&mib, 4, &info, &size, nil, 0) == 0, size > 0 else {
        return nil
    }
    return withUnsafeBytes(of: info.kp_proc.p_comm) { raw in
        guard let base = raw.bindMemory(to: CChar.self).baseAddress else {
            return nil
        }
        return String(cString: base)
    }
}
```

快照实现为：

```swift
public func foregroundProcess() -> ForegroundProcess {
    guard childPID > 0, masterFD >= 0 else { return .exited }
    let pgid = tcgetpgrp(masterFD)
    let validPGID: pid_t? = pgid > 0 ? pgid : nil
    return Self.classifyForegroundProcess(
        childPID: childPID,
        shellName: shellName,
        masterIsOpen: masterFD >= 0,
        foregroundPGID: validPGID,
        foregroundName: validPGID.flatMap(processName(for:))
    )
}

public func foregroundProcessName() -> String? {
    switch foregroundProcess() {
    case .exited:
        nil
    case let .shell(name), let .program(.some(name)):
        name
    case .program(nil):
        nil
    }
}
```

- [ ] **Step 4: 加入真实 PTY 的前台作业回归测试**

在 `.serialized` suite 中启动 shell，等待其稳定为空闲 shell，然后运行 `sleep` 并等待前台程序出现：

```swift
@Test("真实 PTY 区分空闲 shell 与前台作业")
func foregroundProcessTracksJobControl() throws {
    let session = PTYSession()
    try session.start(columns: 80, rows: 24)
    defer { session.terminate() }

    let shellDeadline = ContinuousClock.now + .seconds(3)
    var sawShell = false
    while ContinuousClock.now < shellDeadline {
        if case .shell = session.foregroundProcess() {
            sawShell = true
            break
        }
        Thread.sleep(forTimeInterval: 0.02)
    }
    #expect(sawShell)

    session.write(Data("sleep 2\n".utf8))
    let jobDeadline = ContinuousClock.now + .seconds(1)
    var jobName: String?
    while ContinuousClock.now < jobDeadline {
        if case let .program(name) = session.foregroundProcess() {
            jobName = name
            break
        }
        Thread.sleep(forTimeInterval: 0.02)
    }
    #expect(jobName == "sleep")
}
```

- [ ] **Step 5: 运行 InkPTY 测试并提交**

Run:

```bash
swift test --filter PTYSessionTests
```

Expected: `PTYSessionTests` 全部 PASS。

Commit:

```bash
git add Sources/InkPTY/PTYSession.swift Tests/InkPTYTests/PTYSessionTests.swift
git commit -m "feat(pty): 识别非 shell 前台进程" -m "用启动 shell 的进程身份区分空闲提示符与前台作业，并在查询失败时返回安全的未知状态。\n\nRefs #52"
```

---

### Task 2: 关闭确认模型与原生 Presenter

**Files:**
- Create: `Sources/InkShell/SessionCloseConfirmation.swift`
- Create: `Tests/InkShellTests/SessionCloseConfirmationTests.swift`

**Interfaces:**
- Consumes: `PTYSession.ForegroundProcess`（Task 1）。
- Produces: `SessionCloseTarget`、`SessionCloseAlertContent`、`SessionCloseConfirmation.content(target:processes:)`、`SessionClosePresenting`、`NSAlertSessionClosePresenter` 和 `SessionCloseCoordinator`。

- [ ] **Step 1: 写文案聚合失败测试**

创建 `SessionCloseConfirmationTests.swift`：

```swift
import Testing
import InkPTY
@testable import InkShell

@Suite("活跃会话关闭确认")
@MainActor
struct SessionCloseConfirmationTests {
    @Test("空闲 shell 和已退出会话无需确认")
    func idleSessionsNeedNoConfirmation() {
        let content = SessionCloseConfirmation.content(
            target: .tab,
            processes: [.shell(name: "nu"), .exited]
        )
        #expect(content == nil)
    }

    @Test("单会话显示进程和目标动作")
    func singleProgramUsesSpecificCopy() {
        let content = SessionCloseConfirmation.content(
            target: .pane,
            processes: [.program(name: "claude")]
        )
        #expect(content == SessionCloseAlertContent(
            messageText: "关闭正在运行的会话？",
            informativeText: "claude 仍在运行。关闭后，该进程会被终止。",
            destructiveButtonTitle: "关闭分屏"
        ))
    }

    @Test("退出 Ink 聚合所有活跃会话且限制名称摘要")
    func applicationQuitAggregatesPrograms() {
        let content = SessionCloseConfirmation.content(
            target: .application,
            processes: [
                .program(name: "claude"),
                .shell(name: "zsh"),
                .program(name: "vim"),
                .program(name: "ssh"),
                .program(name: "htop"),
            ]
        )
        #expect(content?.messageText == "退出 Ink 并结束 4 个活跃会话？")
        #expect(content?.informativeText == "claude、vim、ssh 等 4 个会话仍在运行。未保存的工作可能丢失。")
        #expect(content?.destructiveButtonTitle == "退出 Ink")
    }

    @Test("未知前台程序使用通用安全文案")
    func unknownProgramUsesGenericCopy() {
        let content = SessionCloseConfirmation.content(
            target: .window,
            processes: [.program(name: nil)]
        )
        #expect(content?.messageText == "关闭窗口并结束 1 个活跃会话？")
        #expect(content?.informativeText == "有会话仍在运行。关闭后，前台进程会被终止。")
    }
}
```

- [ ] **Step 2: 运行模型测试并确认失败**

Run:

```bash
swift test --filter SessionCloseConfirmationTests
```

Expected: 编译失败，提示确认模型类型尚不存在。

- [ ] **Step 3: 实现目标、内容和纯文案模型**

创建 `SessionCloseConfirmation.swift`，先加入：

```swift
import AppKit
import InkPTY

enum SessionCloseTarget: Equatable {
    case pane
    case tab
    case project
    case window
    case application

    var destructiveButtonTitle: String {
        switch self {
        case .pane: "关闭分屏"
        case .tab: "关闭标签"
        case .project: "移除项目"
        case .window: "关闭窗口"
        case .application: "退出 Ink"
        }
    }
}

struct SessionCloseAlertContent: Equatable {
    let messageText: String
    let informativeText: String
    let destructiveButtonTitle: String
}

enum SessionCloseConfirmation {
    static func content(
        target: SessionCloseTarget,
        processes: [PTYSession.ForegroundProcess]
    ) -> SessionCloseAlertContent? {
        let programs = processes.compactMap { process -> String?? in
            guard case let .program(name) = process else { return nil }
            return .some(name)
        }
        guard !programs.isEmpty else { return nil }

        let count = programs.count
        let messageText: String = switch target {
        case .window:
            "关闭窗口并结束 \(count) 个活跃会话？"
        case .application:
            "退出 Ink 并结束 \(count) 个活跃会话？"
        case .pane, .tab, .project:
            count == 1 ? "关闭正在运行的会话？" : "关闭 \(count) 个正在运行的会话？"
        }

        let knownNames = programs.compactMap { $0 }
        let informativeText: String
        if count == 1, let name = knownNames.first {
            informativeText = "\(name) 仍在运行。关闭后，该进程会被终止。"
        } else if knownNames.isEmpty {
            informativeText = "有会话仍在运行。关闭后，前台进程会被终止。"
        } else {
            let names = Array(knownNames.prefix(3)).joined(separator: "、")
            let suffix = count > 3 ? " 等 \(count) 个会话" : ""
            informativeText = "\(names)\(suffix)仍在运行。未保存的工作可能丢失。"
        }

        return SessionCloseAlertContent(
            messageText: messageText,
            informativeText: informativeText,
            destructiveButtonTitle: target.destructiveButtonTitle
        )
    }
}
```

实现时若 Swift 的双层 Optional 推断需要显式类型，保持测试规定的外部行为不变，不改成 shell 名称白名单。

- [ ] **Step 4: 写协调器失败测试**

在同一测试文件追加可控 presenter：

```swift
@Test("取消不执行关闭，确认只执行一次")
func coordinatorGuardsDestructiveAction() {
    let presenter = RecordingClosePresenter(result: false)
    let coordinator = SessionCloseCoordinator(presenter: presenter)
    var closeCount = 0

    #expect(!coordinator.perform(
        target: .tab,
        processes: [.program(name: "vim")]
    ) { closeCount += 1 })
    #expect(closeCount == 0)
    #expect(presenter.contents.count == 1)

    presenter.result = true
    #expect(coordinator.perform(
        target: .tab,
        processes: [.program(name: "vim")]
    ) { closeCount += 1 })
    #expect(closeCount == 1)
}

@Test("Command-Q 许可只消费一次窗口确认")
func applicationApprovalAvoidsDuplicateWindowPrompt() {
    let presenter = RecordingClosePresenter(result: true)
    let coordinator = SessionCloseCoordinator(presenter: presenter)
    let processes: [PTYSession.ForegroundProcess] = [.program(name: "claude")]

    #expect(coordinator.requestApplicationTermination(processes: processes))
    #expect(coordinator.allowWindowClose(processes: processes))
    #expect(presenter.contents.count == 1)
}

@MainActor
private final class RecordingClosePresenter: SessionClosePresenting {
    var result: Bool
    var contents: [SessionCloseAlertContent] = []

    init(result: Bool) { self.result = result }

    func confirm(_ content: SessionCloseAlertContent) -> Bool {
        contents.append(content)
        return result
    }
}
```

- [ ] **Step 5: 实现原生 presenter 和协调器**

在实现文件追加：

```swift
@MainActor
protocol SessionClosePresenting: AnyObject {
    func confirm(_ content: SessionCloseAlertContent) -> Bool
}

@MainActor
final class NSAlertSessionClosePresenter: SessionClosePresenting {
    func confirm(_ content: SessionCloseAlertContent) -> Bool {
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = content.messageText
        alert.informativeText = content.informativeText
        let destructive = alert.addButton(withTitle: content.destructiveButtonTitle)
        destructive.hasDestructiveAction = true
        let cancel = alert.addButton(withTitle: "取消")
        cancel.keyEquivalent = "\u{1b}"
        return alert.runModal() == .alertFirstButtonReturn
    }
}

@MainActor
final class SessionCloseCoordinator {
    private let presenter: any SessionClosePresenting
    private var applicationTerminationApproved = false

    init(presenter: any SessionClosePresenting = NSAlertSessionClosePresenter()) {
        self.presenter = presenter
    }

    @discardableResult
    func perform(
        target: SessionCloseTarget,
        processes: [PTYSession.ForegroundProcess],
        action: () -> Void
    ) -> Bool {
        if let content = SessionCloseConfirmation.content(
            target: target,
            processes: processes
        ), !presenter.confirm(content) {
            return false
        }
        action()
        return true
    }

    func requestApplicationTermination(
        processes: [PTYSession.ForegroundProcess]
    ) -> Bool {
        let approved: Bool
        if let content = SessionCloseConfirmation.content(
            target: .application,
            processes: processes
        ) {
            approved = presenter.confirm(content)
        } else {
            approved = true
        }
        applicationTerminationApproved = approved
        return approved
    }

    func allowWindowClose(processes: [PTYSession.ForegroundProcess]) -> Bool {
        if applicationTerminationApproved { return true }
        guard let content = SessionCloseConfirmation.content(
            target: .window,
            processes: processes
        ) else { return true }
        return presenter.confirm(content)
    }
}
```

- [ ] **Step 6: 运行模型测试并提交**

Run:

```bash
swift test --filter SessionCloseConfirmationTests
```

Expected: suite 全部 PASS；若多进程文案的空格与测试不一致，只修实现使其精确等于批准文案。

Commit:

```bash
git add Sources/InkShell/SessionCloseConfirmation.swift Tests/InkShellTests/SessionCloseConfirmationTests.swift
git commit -m "feat(shell): 建立会话关闭确认策略" -m "集中生成原生警告文案并通过可注入协调器保证取消不改变状态、退出确认不重复。\n\nRefs #52"
```

---

### Task 3: 接入分屏、标签与项目关闭

**Files:**
- Modify: `Sources/InkShell/TerminalSession.swift`
- Modify: `Sources/InkShell/MainWindowController.swift`
- Modify: `Tests/InkShellTests/TerminalSplitCommandTests.swift`

**Interfaces:**
- Consumes: `PTYSession.ForegroundProcess`、`SessionCloseCoordinator.perform(target:processes:action:)`（Tasks 1–2）。
- Produces: `TerminalSession.foregroundProcess`、窗口控制器的 pane 范围收集与局部关闭保护；Task 4 复用 `allPanes`、`foregroundProcesses(in:)` 和同一协调器。

- [ ] **Step 1: 为 TerminalSession 暴露只读快照**

在现有 `foregroundProcessName` 附近加入：

```swift
var foregroundProcess: PTYSession.ForegroundProcess {
    pty.foregroundProcess()
}
```

保留现有 `foregroundProcessName`，避免标签标题行为变化。

- [ ] **Step 2: 给 MainWindowController 注入协调器并加入范围辅助函数**

增加属性：

```swift
private let sessionCloseCoordinator: SessionCloseCoordinator
```

让内部初始化器接收默认参数并赋值：

```swift
init(
    initialConfig: InkConfig,
    configURL: URL,
    configSyncService: ConfigSyncService,
    sessionCloseCoordinator: SessionCloseCoordinator = SessionCloseCoordinator()
) {
    // 现有窗口构造保持不变
    self.sessionCloseCoordinator = sessionCloseCoordinator
    // 其余现有初始化保持不变
}
```

加入集中收集与执行辅助函数：

```swift
private var allPanes: [TerminalPane] {
    projects.flatMap(\.tabs).flatMap(\.allPanes)
}

private func foregroundProcesses(
    in panes: [TerminalPane]
) -> [PTYSession.ForegroundProcess] {
    panes.map { $0.session.foregroundProcess }
}

private func confirmClose(
    target: SessionCloseTarget,
    panes: [TerminalPane],
    action: () -> Void
) {
    sessionCloseCoordinator.perform(
        target: target,
        processes: foregroundProcesses(in: panes),
        action: action
    )
}
```

若 `PTYSession` 类型在该文件不可见，显式加入 `import InkPTY`；不要把快照重新包装成字符串。

- [ ] **Step 3: 把项目移除改成确认前不变更状态**

将现有 `removeProject(at:)` 拆成保护入口和原实现：

```swift
func removeProject(at index: Int) {
    guard projects.indices.contains(index) else { return }
    let project = projects[index]
    let panes = project.tabs.flatMap(\.allPanes)
    confirmClose(target: .project, panes: panes) { [weak self] in
        self?.removeProjectWithoutConfirmation(at: index)
    }
}

private func removeProjectWithoutConfirmation(at index: Int) {
    guard projects.indices.contains(index) else { return }
    let project = projects[index]
    for tab in project.tabs { terminate(tab: tab) }
    project.tabs.removeAll()
    projects.remove(at: index)
    if projects.isEmpty {
        projects = [Project(directory: FileManager.default.homeDirectoryForCurrentUser)]
    }
    if activeProjectIndex >= projects.count {
        activeProjectIndex = projects.count - 1
    }
    persistProjects()
    selectProject(at: activeProjectIndex)
}
```

- [ ] **Step 4: 把分屏与标签关闭改成确认前不移除 pane**

保留最后一个 pane 走标签关闭的现有语义。多 pane 路径先捕获目标 pane，再确认：

```swift
@objc public func closeActivePane(_ sender: Any?) {
    guard !isShowingSettings,
          let project = activeProject,
          let tab = project.activeTab else { return }
    if tab.paneCount == 1 {
        closeTab(at: project.activeTabIndex)
        return
    }
    let paneID = tab.activePaneID
    guard let pane = tab.panes[paneID] else { return }
    confirmClose(target: .pane, panes: [pane]) { [weak self, weak tab] in
        guard let self, let tab, let removed = tab.removePane(paneID) else { return }
        removed.session.detach()
        removed.session.terminate()
        self.attachActiveTab()
        self.refreshChrome()
    }
}
```

标签路径同样延迟 `removeTab`：

```swift
private func closeTab(at index: Int) {
    guard let project = activeProject,
          project.tabs.indices.contains(index) else { return }
    let tab = project.tabs[index]
    confirmClose(target: .tab, panes: tab.allPanes) { [weak self, weak project] in
        guard let self, let project,
              let removed = project.removeTab(at: index) else { return }
        self.terminate(tab: removed)
        self.normalizeAfterTabRemoval()
    }
}
```

Swift 不允许对非 class 的弱引用；这里 `Project` 和 `TerminalTab` 均为 class。若编译器对闭包的 actor 隔离提出错误，让 `confirmClose` 明确保持 `@MainActor` 上下文，不添加 `Task` 或异步延迟。

- [ ] **Step 5: 加强空闲 shell 的现有 Command-W 回归断言**

在 `TerminalSplitCommandTests.closeCommandRemovesOnlyActivePane` 中，关闭前断言没有 sheet 或 modal window；关闭后继续断言 pane 数量从 2 变 1：

```swift
#expect(window.attachedSheet == nil)
controller.closeActivePane(nil)
spinRunLoop()
#expect(window.attachedSheet == nil)
#expect(terminalViews(in: window).count == 1)
```

该测试使用真实空闲 shell；若启动横幅尚未完成导致安全确认，先在测试辅助函数中等待 `TerminalMetalView` 稳定，不得在生产代码中加入延时或 shell 名称例外。

- [ ] **Step 6: 运行局部关闭测试并提交**

Run:

```bash
swift test --filter TerminalSplitCommandTests
swift test --filter SessionCloseConfirmationTests
```

Expected: 两个 suites 全部 PASS；测试进程结束后没有遗留 `sleep`、shell 或 Ink 窗口。

Commit:

```bash
git add Sources/InkShell/TerminalSession.swift Sources/InkShell/MainWindowController.swift Tests/InkShellTests/TerminalSplitCommandTests.swift
git commit -m "feat(shell): 保护局部活跃会话关闭" -m "在改变标签、分屏或项目状态前统一检查目标 pane，取消确认时完整保留界面与进程。\n\nRefs #52"
```

---

### Task 4: 接入窗口关闭与 Command-Q

**Files:**
- Modify: `Sources/InkShell/MainWindowController.swift`
- Modify: `Sources/InkShell/AppDelegate.swift`
- Test: `Tests/InkShellTests/SessionCloseConfirmationTests.swift`
- Test: `Tests/InkShellTests/TerminalSplitCommandTests.swift`

**Interfaces:**
- Consumes: `SessionCloseCoordinator.requestApplicationTermination(processes:)`、`allowWindowClose(processes:)` 和 Task 3 的 `allPanes`/`foregroundProcesses(in:)`。
- Produces: `MainWindowController.requestApplicationTermination() -> Bool`、`windowShouldClose(_:) -> Bool` 和 `AppDelegate.applicationShouldTerminate(_:) -> NSApplication.TerminateReply`。

- [ ] **Step 1: 写一次性退出许可的补充失败测试**

在 `SessionCloseConfirmationTests` 增加取消不会留下许可的断言：

```swift
@Test("取消 Command-Q 后窗口关闭仍需重新确认")
func cancelledApplicationTerminationDoesNotApproveWindowClose() {
    let presenter = RecordingClosePresenter(result: false)
    let coordinator = SessionCloseCoordinator(presenter: presenter)
    let processes: [PTYSession.ForegroundProcess] = [.program(name: "claude")]

    #expect(!coordinator.requestApplicationTermination(processes: processes))
    presenter.result = true
    #expect(coordinator.allowWindowClose(processes: processes))
    #expect(presenter.contents.count == 2)
}
```

Run:

```bash
swift test --filter SessionCloseConfirmationTests.cancelledApplicationTerminationDoesNotApproveWindowClose
```

Expected: 如果 Task 2 正确实现则直接 PASS；若失败，修正协调器只在批准时设置一次性许可。

- [ ] **Step 2: 在窗口控制器接入全范围许可**

在 `MainWindowController` 增加 AppDelegate 可调用的内部方法：

```swift
func requestApplicationTermination() -> Bool {
    sessionCloseCoordinator.requestApplicationTermination(
        processes: foregroundProcesses(in: allPanes)
    )
}
```

在现有 `windowWillClose` 前实现 delegate 判断：

```swift
public func windowShouldClose(_ sender: NSWindow) -> Bool {
    sessionCloseCoordinator.allowWindowClose(
        processes: foregroundProcesses(in: allPanes)
    )
}
```

`windowWillClose` 保持唯一的全量 PTY 终止位置；不要在 `windowShouldClose` 中提前 detach 或 terminate。

- [ ] **Step 3: 将 Command-Q 映射到 AppKit 终止答复**

在 `AppDelegate` 中加入：

```swift
public func applicationShouldTerminate(
    _ sender: NSApplication
) -> NSApplication.TerminateReply {
    guard let mainWindowController else { return .terminateNow }
    return mainWindowController.requestApplicationTermination()
        ? .terminateNow
        : .terminateCancel
}
```

保留 `applicationShouldTerminateAfterLastWindowClosed`；红色关闭按钮先通过 `windowShouldClose`，最后一个窗口关闭后因会话已在 `windowWillClose` 清空，应用终止阶段不会再弹风险确认。

- [ ] **Step 4: 运行外壳与完整测试**

Run:

```bash
swift test --filter SessionCloseConfirmationTests
swift test --filter TerminalSplitCommandTests
swift test
swift build
```

Expected: 212 项基线测试加新增测试全部 PASS，构建完成且没有 warning。

- [ ] **Step 5: 做深浅色与真实程序人工验收**

依次用 `swift run ink` 启动调试版，并完成以下矩阵：

```text
appearance: system / light / dark
program: 空闲 shell / claude / vim / ssh
action: 关闭分屏 / 关闭标签 / 移除项目 / 红色关闭窗口 / Command-Q
```

Expected:

- 空闲 shell 直接关闭；
- 非 shell 前台程序显示一个原生警告，标题和按钮与目标动作一致；
- Escape 取消后程序继续响应输入；
- 确认后只结束目标范围；
- 多 pane 或多项目只弹一次并显示汇总；
- Command-Q 确认后不再出现窗口关闭警告；
- system、light、dark 下文字和 destructive 按钮均清晰可读。

在人工验收结束后正常退出调试版，不使用 `killall`，避免影响用户其他终端或 Claude Code 会话。

- [ ] **Step 6: 提交应用退出接线**

```bash
git add Sources/InkShell/MainWindowController.swift Sources/InkShell/AppDelegate.swift Tests/InkShellTests/SessionCloseConfirmationTests.swift Tests/InkShellTests/TerminalSplitCommandTests.swift
git commit -m "feat(app): 退出前确认活跃会话" -m "汇总窗口内全部前台程序，并用一次性许可避免 Command-Q 与窗口关闭重复提示。\n\nRefs #52"
```

---

### Task 5: 最终验证与交付检查

**Files:**
- Verify: all files changed since `origin/main`

**Interfaces:**
- Consumes: Tasks 1–4 的完整实现与测试。
- Produces: 可评审、可推送的 Issue #52 分支；不在本任务中发布或打 tag。

- [ ] **Step 1: 检查范围与工作区**

Run:

```bash
git status --short
git diff --check origin/main...HEAD
git diff --stat origin/main...HEAD
git log --oneline origin/main..HEAD
```

Expected: 工作区干净；无 whitespace error；diff 仅包含 Issue #52 的设计、计划、PTY 快照、关闭确认、接线和测试。

- [ ] **Step 2: 重新运行最终验证**

Run:

```bash
swift test
swift build
```

Expected: 所有测试 PASS，`swift build` 零警告。记录最终测试总数和耗时用于交付说明。

- [ ] **Step 3: 核对 Issue 与发布边界**

Run:

```bash
gh issue view 52 --json number,state,title,url
git tag --points-at HEAD
```

Expected: Issue #52 仍为 OPEN；HEAD 没有发布 tag。除非用户之后明确要求，不创建版本标签、不发布。

- [ ] **Step 4: 进入分支完成流程**

实现完成后调用 `superpowers:verification-before-completion`，再调用 `superpowers:requesting-code-review` 检查需求符合性和代码质量。审查无阻塞项后调用 `superpowers:finishing-a-development-branch`，由用户选择是否推送、创建 PR 或暂留本地；不要自行合并或发布。
