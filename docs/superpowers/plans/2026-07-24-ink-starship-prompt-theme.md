# Ink Starship Prompt Theme Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** 在设置中提供默认的 Ink Starship 提示符主题与用户配置切换，只向新建 Ink PTY 注入独立配置，并让 Ink 提示符颜色跟随现有 ANSI 调色板。

**Architecture:** `InkConfig` 保存并同步 `PromptThemeSource`；`InkShell` 用确定性字符串安装 `~/.config/ink/starship.toml`，并在新会话冷路径中解析环境覆盖；`TerminalSession` 将不可变覆盖传给 `InkPTY`。模板只使用 ANSI 0–15 命名色，不修改 `TerminalCore`、Metal 渲染或用户 Starship 文件。

**Tech Stack:** Swift 6、AppKit、SwiftPM、swift-testing、Starship TOML、`forkpty(3)`。

## Global Constraints

- Issue：#94；开发分支：`agent/issue-94-ink-starship-prompt`。
- 默认使用 Ink 主题；切换只影响之后新建的标签和分屏。
- Ink 不安装或启用 Starship，不改写用户 shell 启动脚本或 `~/.config/starship.toml`。
- Ink 模板只使用 ANSI 命名色，不得包含 `#RRGGBB`、`rgb(...)` 或 16–255 数字色索引。
- `InkPTY` 只接受通用环境覆盖，不引入 Starship 类型或路径。
- 新增工作只在新会话冷路径；不改 cell、scrollback、VT 解析或每帧渲染路径。
- 每个窗口生命周期最多显示一次 Ink Starship 文件写入失败警告；会话回退到用户 shell 环境。
- 代码标识符用英文，注释、设置文案和提交信息用中文；不新增第三方依赖。
- 本次实现预计修改或新增 14 个源码与测试文件；跨越配置、Shell UI 和 PTY 是功能边界所需，不包含无关重构。

---

### Task 1: 建立提示符来源的本地与 iCloud 配置契约

**Files:**
- Modify: `Sources/InkConfig/InkConfig.swift:3-49,55-95,148-151,219-239`
- Modify: `Sources/InkConfig/ConfigSyncSnapshot.swift:65-144`
- Modify: `Tests/InkConfigTests/InkConfigTests.swift:90-241`
- Modify: `Tests/InkConfigTests/ConfigSyncSnapshotTests.swift:7-131`

**Interfaces:**
- Produces: `InkConfig.PromptThemeSource` with `.ink` / `.user`.
- Produces: `InkConfig.promptThemeSource: PromptThemeSource`, default `.ink`.
- Produces: TOML key `terminal.prompt_theme` and optional iCloud wire field `promptThemeSource`.

- [ ] **Step 1: Write failing local-config tests**

Add these tests to `InkConfigTests` and extend the existing round-trip fixture to select `.user`:

```swift
config.promptThemeSource = .user
```

```swift
@Test("提示符主题默认由 Ink 管理")
func promptThemeSourceDefaultsToInk() {
    #expect(InkConfig().promptThemeSource == .ink)
}

@Test("提示符主题来源从 TOML 读取并完整往返")
func promptThemeSourceRoundTrips() throws {
    let directory = FileManager.default.temporaryDirectory
        .appendingPathComponent("ink-prompt-source-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }
    let file = directory.appendingPathComponent("config.toml")
    try """
    [terminal]
    prompt_theme = "user"
    """.write(to: file, atomically: true, encoding: .utf8)

    var config = InkConfig.load(from: file)
    #expect(config.promptThemeSource == .user)
    config.promptThemeSource = .ink
    try config.save(to: file)
    #expect(InkConfig.load(from: file).promptThemeSource == .ink)
}

@Test("未知提示符主题来源回退 Ink")
func invalidPromptThemeSourceUsesInk() throws {
    let directory = FileManager.default.temporaryDirectory
        .appendingPathComponent("ink-invalid-prompt-source-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }
    let file = directory.appendingPathComponent("config.toml")
    try """
    [terminal]
    prompt_theme = "missing"
    """.write(to: file, atomically: true, encoding: .utf8)

    #expect(InkConfig.load(from: file).promptThemeSource == .ink)
}
```

- [ ] **Step 2: Write failing iCloud migration tests**

In `ConfigSyncSnapshotTests`, make `completeConfig()` set `.user`, then add:

```swift
config.promptThemeSource = .user
```

```swift
@Test("旧 schema 1 缺少提示符来源时迁移为 Ink")
func oldSchemaDefaultsPromptThemeSourceToInk() throws {
    let data = try snapshotJSON { root in
        var config = try #require(root["config"] as? [String: Any])
        config.removeValue(forKey: "promptThemeSource")
        root["config"] = config
    }
    #expect(try ConfigSyncSnapshot.decode(data).config.promptThemeSource == .ink)
}

@Test("拒绝非法提示符来源快照")
func rejectsInvalidPromptThemeSource() throws {
    let data = try snapshotJSON { root in
        var config = try #require(root["config"] as? [String: Any])
        config["promptThemeSource"] = "missing"
        root["config"] = config
    }
    #expect(throws: ConfigSyncSnapshotError.invalidPayload) {
        try ConfigSyncSnapshot.decode(data)
    }
}
```

- [ ] **Step 3: Run the focused tests and verify RED**

Run:

```bash
swift test --no-parallel --filter InkConfigTests
swift test --no-parallel --filter ConfigSyncSnapshotTests
```

Expected: compilation fails because `PromptThemeSource` and `promptThemeSource` do not exist.

- [ ] **Step 4: Implement the minimum local config contract**

Add to `InkConfig`:

```swift
public enum PromptThemeSource: String, CaseIterable, Sendable {
    case ink, user
}

public var promptThemeSource: PromptThemeSource = .ink
```

Document `prompt_theme = "ink"` in the header example. In `load`, immediately after `terminal.theme`, add:

```swift
if let source = values.string("terminal.prompt_theme"),
   let parsed = PromptThemeSource(rawValue: source) {
    config.promptThemeSource = parsed
}
```

Add this entry immediately after `terminal.theme` in `tomlValues`:

```swift
("terminal.prompt_theme", quote(promptThemeSource.rawValue)),
```

- [ ] **Step 5: Implement backward-compatible iCloud encoding**

Add `let promptThemeSource: String?` to `WireConfig`, assign the raw value in `init(config:)`, and validate it without changing schema version:

```swift
let resolvedPromptThemeSource: InkConfig.PromptThemeSource
if let promptThemeSource {
    guard let parsed = InkConfig.PromptThemeSource(rawValue: promptThemeSource) else {
        throw ConfigSyncSnapshotError.invalidPayload
    }
    resolvedPromptThemeSource = parsed
} else {
    resolvedPromptThemeSource = .ink
}
```

Assign `result.promptThemeSource = resolvedPromptThemeSource` beside `terminalTheme`.

- [ ] **Step 6: Run focused tests and verify GREEN**

Run:

```bash
swift test --no-parallel --filter InkConfigTests
swift test --no-parallel --filter ConfigSyncSnapshotTests
```

Expected: both suites pass with no warnings.

- [ ] **Step 7: Commit the config contract**

```bash
git add Sources/InkConfig/InkConfig.swift Sources/InkConfig/ConfigSyncSnapshot.swift Tests/InkConfigTests/InkConfigTests.swift Tests/InkConfigTests/ConfigSyncSnapshotTests.swift
git commit -m "feat(config): 同步提示符主题来源" -m "默认选择 Ink 主题，并让旧 iCloud schema 1 快照在缺少新字段时安全迁移。

Refs #94"
```

### Task 2: 生成只使用 ANSI 语义色的 Ink Starship 模板

**Files:**
- Create: `Sources/InkShell/InkStarshipConfig.swift`
- Create: `Tests/InkShellTests/InkStarshipConfigTests.swift`

**Interfaces:**
- Produces: `InkStarshipConfig.defaultURL: URL`.
- Produces: `InkStarshipConfig.managedContents: String`.
- Produces: `InkStarshipConfig.install(at:) throws -> Bool`, where `true` means the file changed.
- Produces: `InkStarshipConfig.environmentOverrides(for:configURL:) throws -> [String: String]`.

- [ ] **Step 1: Write failing template and installation tests**

Create `InkStarshipConfigTests.swift`:

```swift
import Foundation
import InkConfig
import Testing
@testable import InkShell

@Suite("Ink Starship 配置")
struct InkStarshipConfigTests {
    @Test("模板保留约定分段且只使用 ANSI 命名色")
    func templateUsesSemanticANSIColors() throws {
        let text = InkStarshipConfig.managedContents
        for segment in [
            "$os", "$directory", "$git_branch", "$git_status",
            "$nodejs", "$python", "$rust", "$golang", "$java",
            "$conda", "$docker_context", "$time", "$cmd_duration", "$character",
        ] {
            #expect(text.contains(segment), "缺少 \(segment)")
        }
        let hex = try NSRegularExpression(pattern: #"#[0-9A-Fa-f]{6}"#)
        let range = NSRange(text.startIndex..<text.endIndex, in: text)
        #expect(hex.firstMatch(in: text, range: range) == nil)
        #expect(!text.contains("rgb("))
        #expect(text.contains("bg:bright-purple"))
        #expect(text.contains("bg:bright-black"))
    }

    @Test("首次安装原子写入，相同内容不重写")
    func installWritesOnlyWhenContentsChange() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("ink-starship-install-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("starship.toml")

        #expect(try InkStarshipConfig.install(at: url))
        #expect(try String(contentsOf: url, encoding: .utf8) == InkStarshipConfig.managedContents)
        #expect(try InkStarshipConfig.install(at: url) == false)
    }

    @Test("只有 Ink 来源写入文件并覆盖 STARSHIP_CONFIG")
    func sourceControlsEnvironmentOverride() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("ink-starship-source-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("starship.toml")

        #expect(try InkStarshipConfig.environmentOverrides(for: .user, configURL: url).isEmpty)
        #expect(!FileManager.default.fileExists(atPath: url.path))
        #expect(try InkStarshipConfig.environmentOverrides(for: .ink, configURL: url) == [
            "STARSHIP_CONFIG": url.path,
        ])
        #expect(FileManager.default.fileExists(atPath: url.path))
    }

    @Test("本机 Starship 可解析 Ink 模板")
    func installedStarshipParsesTemplate() throws {
        let executable = ["/opt/homebrew/bin/starship", "/usr/local/bin/starship"]
            .first { FileManager.default.isExecutableFile(atPath: $0) }
        guard let executable else { return }
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("ink-starship-parse-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("starship.toml")
        try InkStarshipConfig.install(at: url)

        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = ["prompt"]
        process.environment = ProcessInfo.processInfo.environment.merging([
            "TERM": "xterm-256color",
            "COLORTERM": "truecolor",
            "STARSHIP_CONFIG": url.path,
        ]) { _, override in override }
        process.standardOutput = Pipe()
        let errors = Pipe()
        process.standardError = errors
        try process.run()
        process.waitUntilExit()
        let diagnostic = String(
            data: errors.fileHandleForReading.readDataToEndOfFile(),
            encoding: .utf8
        ) ?? ""
        #expect(process.terminationStatus == 0)
        #expect(diagnostic.isEmpty)
    }
}
```

- [ ] **Step 2: Run the suite and verify RED**

Run: `swift test --no-parallel --filter InkStarshipConfigTests`

Expected: compilation fails because `InkStarshipConfig` does not exist.

- [ ] **Step 3: Implement the deterministic installer and source resolver**

Create `InkStarshipConfig.swift` with this shape:

```swift
import Foundation
import InkConfig

enum InkStarshipConfig {
    static var defaultURL: URL {
        InkConfig.defaultURL.deletingLastPathComponent()
            .appendingPathComponent("starship.toml")
    }

    static let managedContents = #"""
    # 由 Ink 管理；更新 Ink 时可能覆盖本文件。
    "$schema" = "https://starship.rs/config-schema.json"

    format = """
    [░▒▓](bright-purple)\
    $os\
    [  ](bg:bright-purple fg:black)\
    [](fg:bright-purple bg:bright-black)\
    $directory\
    [](fg:bright-black bg:purple)\
    $git_branch\
    $git_status\
    [](fg:purple bg:black)\
    $nodejs\
    $python\
    $rust\
    $golang\
    $java\
    $conda\
    $docker_context\
    $time\
    [](fg:black)\
    $cmd_duration\
    $line_break\
    $character"""

    [os]
    disabled = false
    style = "bg:bright-purple fg:black"

    [os.symbols]
    Macos = "󰀵"
    Linux = "󰌽"
    Windows = ""

    [directory]
    style = "bg:bright-black fg:bright-white"
    format = '[  $path ]($style)'
    truncation_length = 3
    truncate_to_repo = false

    [git_branch]
    symbol = ""
    style = "bg:purple fg:black"
    format = '[ $branch ]($style)'

    [git_status]
    style = "bg:purple fg:black"
    format = '[($all_status$ahead_behind )]($style)'

    [nodejs]
    symbol = ""
    style = "bg:black fg:yellow"
    format = '[  ($version) ]($style)'

    [python]
    symbol = ""
    style = "bg:black fg:yellow"
    format = '[  ($version)(\($virtualenv\)) ]($style)'

    [rust]
    symbol = ""
    style = "bg:black fg:red"
    format = '[  ($version) ]($style)'

    [golang]
    symbol = ""
    style = "bg:black fg:green"
    format = '[  ($version) ]($style)'

    [java]
    symbol = ""
    style = "bg:black fg:red"
    format = '[  ($version) ]($style)'

    [conda]
    symbol = ""
    style = "bg:black fg:yellow"
    format = '[  $environment ]($style)'
    ignore_base = false

    [docker_context]
    symbol = ""
    style = "bg:black fg:cyan"
    format = '[  $context ]($style)'

    [time]
    disabled = false
    time_format = "%H:%M"
    style = "bg:black fg:bright-white"
    format = '[ 󱑍 $time ]($style)'

    [cmd_duration]
    format = ' [took $duration](yellow)'

    [line_break]
    disabled = false

    [character]
    success_symbol = '[󱞩](bold bright-purple)'
    error_symbol = '[󱞩](bold red)'
    vimcmd_symbol = '[󱞩](bold purple)'
    """# + "\n"

    @discardableResult
    static func install(at url: URL = defaultURL) throws -> Bool {
        if try? String(contentsOf: url, encoding: .utf8) == managedContents {
            return false
        }
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try managedContents.write(to: url, atomically: true, encoding: .utf8)
        return true
    }

    static func environmentOverrides(
        for source: InkConfig.PromptThemeSource,
        configURL: URL = defaultURL
    ) throws -> [String: String] {
        guard source == .ink else { return [:] }
        try install(at: configURL)
        return ["STARSHIP_CONFIG": configURL.path]
    }
}
```

During implementation, keep all module formats shown above, but run the installed Starship parser before commit; correct syntax defects without adding truecolor literals or new modules.

- [ ] **Step 4: Run template tests**

Run:

```bash
swift test --no-parallel --filter InkStarshipConfigTests
```

Expected: the suite passes. On development machines with Homebrew Starship, the test also parses the generated temporary file and requires empty diagnostics; environments without Starship skip only that external-parser assertion.

- [ ] **Step 5: Commit the managed template**

```bash
git add Sources/InkShell/InkStarshipConfig.swift Tests/InkShellTests/InkStarshipConfigTests.swift
git commit -m "feat(shell): 生成 Ink Starship 提示符" -m "用 ANSI 语义色保留现有分段信息，让提示符跟随 Ink 调色板而不写死真彩色。

Refs #94"
```

### Task 3: 将通用环境覆盖从 TerminalSession 传到 PTY

**Files:**
- Modify: `Sources/InkPTY/PTYSession.swift:47-95`
- Modify: `Sources/InkShell/TerminalSession.swift:22-43`
- Modify: `Tests/InkPTYTests/PTYSessionTests.swift:8-24`
- Create: `Tests/InkShellTests/TerminalSessionEnvironmentTests.swift`

**Interfaces:**
- Produces: `PTYSession.childEnvironment(from:overrides:)`.
- Produces: optional `environmentOverrides` argument on `PTYSession.start`.
- Produces: `TerminalSession.environmentOverrides: [String: String]` fixed at initialization.

- [ ] **Step 1: Write failing PTY merge tests**

Extend the first `PTYSessionTests` case and add a dedicated override case:

```swift
@Test("会话覆盖只改指定键且不能破坏终端能力声明")
func childEnvironmentMergesSessionOverrides() {
    let environment = PTYSession.childEnvironment(
        from: ["TERM": "dumb", "INK_SENTINEL": "preserved"],
        overrides: ["STARSHIP_CONFIG": "/tmp/ink-starship.toml", "TERM": "bad"]
    )

    #expect(environment["STARSHIP_CONFIG"] == "/tmp/ink-starship.toml")
    #expect(environment["INK_SENTINEL"] == "preserved")
    #expect(environment["TERM"] == "xterm-256color")
    #expect(environment["COLORTERM"] == "truecolor")
    #expect(environment["TERM_PROGRAM"] == "ink")
}
```

Create `TerminalSessionEnvironmentTests.swift`:

```swift
import Testing
import TerminalCore
@testable import InkShell

@Suite("终端会话环境")
@MainActor
struct TerminalSessionEnvironmentTests {
    @Test("会话在创建时固定环境覆盖")
    func sessionKeepsEnvironmentOverrides() {
        let overrides = ["STARSHIP_CONFIG": "/tmp/ink-starship.toml"]
        let session = TerminalSession(
            size: TerminalSize(columns: 80, rows: 24),
            environmentOverrides: overrides
        )
        #expect(session.environmentOverrides == overrides)
    }
}
```

- [ ] **Step 2: Run focused tests and verify RED**

Run:

```bash
swift test --no-parallel --filter PTYSessionTests
swift test --no-parallel --filter TerminalSessionEnvironmentTests
```

Expected: compilation fails because neither initializer accepts overrides.

- [ ] **Step 3: Implement generic environment merging**

Change `PTYSession.childEnvironment` to:

```swift
static func childEnvironment(
    from hostEnvironment: [String: String],
    overrides: [String: String] = [:]
) -> [String: String] {
    var environment = hostEnvironment
    for (key, value) in overrides {
        environment[key] = value
    }
    environment.removeValue(forKey: "NO_COLOR")
    environment["TERM"] = "xterm-256color"
    environment["COLORTERM"] = "truecolor"
    environment["TERM_PROGRAM"] = "ink"
    if environment["LANG"] == nil {
        environment["LANG"] = "zh_CN.UTF-8"
    }
    return environment
}
```

Add `environmentOverrides: [String: String] = [:]` to `PTYSession.start` and pass it into `childEnvironment`.

In `TerminalSession`, add an immutable internal property, initialize it with a default empty dictionary, and pass it to `pty.start`:

```swift
let environmentOverrides: [String: String]

public init(
    size: TerminalSize,
    workingDirectory: String? = nil,
    scrollbackLines: Int = 100_000,
    environmentOverrides: [String: String] = [:]
) {
    terminal = Terminal(size: size, scrollbackCapacity: scrollbackLines)
    initialWorkingDirectory = workingDirectory
    self.environmentOverrides = environmentOverrides
}
```

- [ ] **Step 4: Run focused tests and verify GREEN**

Run:

```bash
swift test --no-parallel --filter PTYSessionTests
swift test --no-parallel --filter TerminalSessionEnvironmentTests
```

Expected: both suites pass; the existing real PTY job-control tests remain green.

- [ ] **Step 5: Commit the PTY boundary**

```bash
git add Sources/InkPTY/PTYSession.swift Sources/InkShell/TerminalSession.swift Tests/InkPTYTests/PTYSessionTests.swift Tests/InkShellTests/TerminalSessionEnvironmentTests.swift
git commit -m "feat(pty): 隔离新会话环境覆盖" -m "让 Shell 层只向指定 Ink PTY 传递 Starship 路径，同时保持 TERM 与 COLORTERM 等能力声明为 PTY 强制契约。

Refs #94"
```

### Task 4: 在设置页选择 Ink 或用户提示符主题

**Files:**
- Modify: `Sources/InkShell/SettingsViewController.swift:20-57,161-192,434-505,537-583,617-648`
- Create: `Tests/InkShellTests/PromptThemeSettingsTests.swift`

**Interfaces:**
- Produces: segmented control with accessibility label `提示符主题`.
- Consumes: `InkConfig.promptThemeSource` from Task 1.

- [ ] **Step 1: Write failing settings tests**

Create `PromptThemeSettingsTests.swift`:

```swift
import AppKit
import InkConfig
import Testing
@testable import InkShell

@Suite("提示符主题设置", .serialized)
@MainActor
struct PromptThemeSettingsTests {
    @Test("设置默认选中 Ink 并写回用户选择")
    func settingsSelectPromptThemeSource() throws {
        let controller = SettingsViewController(config: InkConfig())
        var changed: InkConfig?
        controller.onChange = { changed = $0 }
        controller.loadView()
        let control = try #require(
            allSubviews(in: controller.view)
                .compactMap { $0 as? NSSegmentedControl }
                .first { $0.accessibilityLabel() == "提示符主题" }
        )

        #expect(control.labels == ["Ink 主题", "用户配置"])
        #expect(control.selectedSegment == 0)
        control.selectedSegment = 1
        let action = try #require(control.action)
        #expect(NSApp.sendAction(action, to: control.target, from: control))
        #expect(changed?.promptThemeSource == .user)
    }

    @Test("外部配置更新同步提示符选项")
    func externalUpdateRefreshesSelection() throws {
        let controller = SettingsViewController(config: InkConfig())
        controller.loadView()
        var external = InkConfig()
        external.promptThemeSource = .user
        controller.update(config: external)
        let control = try #require(
            allSubviews(in: controller.view)
                .compactMap { $0 as? NSSegmentedControl }
                .first { $0.accessibilityLabel() == "提示符主题" }
        )
        #expect(control.selectedSegment == 1)
    }

    private func allSubviews(in view: NSView) -> [NSView] {
        view.subviews.flatMap { [$0] + allSubviews(in: $0) }
    }
}

private extension NSSegmentedControl {
    var labels: [String] {
        (0..<segmentCount).map { label(forSegment: $0) }
    }
}
```

- [ ] **Step 2: Run the suite and verify RED**

Run: `swift test --no-parallel --filter PromptThemeSettingsTests`

Expected: tests fail because no segmented control has the required accessibility label.

- [ ] **Step 3: Add the setting control and persistence binding**

Add `private let promptThemeControl = NSSegmentedControl()` next to `themePopUp`.

Insert this row immediately after terminal color theme:

```swift
makeRow(
    title: "提示符主题",
    detail: "需要 shell 已启用 Starship；更改仅影响新建会话。",
    control: promptThemeControl
),
```

Configure it with the existing helper:

```swift
configureSegmented(
    promptThemeControl,
    labels: ["Ink 主题", "用户配置"],
    action: #selector(controlChanged)
)
promptThemeControl.setAccessibilityLabel("提示符主题")
```

In `updateControls`:

```swift
promptThemeControl.selectedSegment = config.promptThemeSource == .ink ? 0 : 1
```

In `controlChanged`:

```swift
config.promptThemeSource = promptThemeControl.selectedSegment == 1 ? .user : .ink
```

- [ ] **Step 4: Run UI and config-sync settings suites**

Run:

```bash
swift test --no-parallel --filter PromptThemeSettingsTests
swift test --no-parallel --filter ConfigSyncSettingsTests
swift test --no-parallel --filter ConfigSyncWindowTests
```

Expected: all suites pass and the existing terminal section remains discoverable by accessibility labels.

- [ ] **Step 5: Commit the setting**

```bash
git add Sources/InkShell/SettingsViewController.swift Tests/InkShellTests/PromptThemeSettingsTests.swift
git commit -m "feat(settings): 切换提示符主题来源" -m "在终端设置中默认选中 Ink 主题，并明确切换只作用于之后新建的会话。

Refs #94"
```

### Task 5: 在新建标签和分屏时注入 Ink Starship 配置

**Files:**
- Modify: `Sources/InkShell/MainWindowController.swift:41-63,78-146,982-1003`
- Create: `Tests/InkShellTests/PromptThemeSessionTests.swift`

**Interfaces:**
- Produces: internal `MainWindowController.makeTerminalSession(size:workingDirectory:) -> TerminalSession` for one tested construction path.
- Produces: `inkStarshipConfigURL` init seam for temporary test destinations.
- Produces: optional `promptConfigFailureHandler` init seam; production falls back to one native warning.

- [ ] **Step 1: Write failing new-session and failure-fallback tests**

Create `PromptThemeSessionTests.swift` with these tests and a fully isolated fixture:

```swift
@Test("Ink 来源只向新会话注入管理配置")
func inkSourceInjectsManagedConfig() throws {
    let fixture = try PromptThemeWindowFixture(source: .ink)
    defer { fixture.cleanUp() }
    let session = fixture.controller.makeTerminalSession(
        size: TerminalSize(columns: 80, rows: 24),
        workingDirectory: fixture.directory.path
    )
    #expect(session.environmentOverrides == [
        "STARSHIP_CONFIG": fixture.starshipURL.path,
    ])
    #expect(FileManager.default.fileExists(atPath: fixture.starshipURL.path))
}

@Test("用户来源不注入 Starship 覆盖")
func userSourceKeepsShellEnvironment() throws {
    let fixture = try PromptThemeWindowFixture(source: .user)
    defer { fixture.cleanUp() }
    let session = fixture.controller.makeTerminalSession(
        size: TerminalSize(columns: 80, rows: 24),
        workingDirectory: fixture.directory.path
    )
    #expect(session.environmentOverrides.isEmpty)
    #expect(!FileManager.default.fileExists(atPath: fixture.starshipURL.path))
}

@Test("模板写入失败时回退且只警告一次")
func installFailureFallsBackAndWarnsOnce() throws {
    let fixture = try PromptThemeWindowFixture(source: .ink, blockStarshipDirectory: true)
    defer { fixture.cleanUp() }
    _ = fixture.controller.makeTerminalSession(
        size: TerminalSize(columns: 80, rows: 24),
        workingDirectory: fixture.directory.path
    )
    let second = fixture.controller.makeTerminalSession(
        size: TerminalSize(columns: 80, rows: 24),
        workingDirectory: fixture.directory.path
    )
    #expect(second.environmentOverrides.isEmpty)
    #expect(fixture.warningCount == 1)
}

@MainActor
private final class PromptThemeWindowFixture {
    let controller: MainWindowController
    let directory: URL
    let starshipURL: URL
    private let defaults: UserDefaults
    private let suiteName: String
    private let warningCounter: PromptWarningCounter

    var warningCount: Int { warningCounter.count }

    init(
        source: InkConfig.PromptThemeSource,
        blockStarshipDirectory: Bool = false
    ) throws {
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("ink-prompt-session-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        suiteName = "ink.prompt-session.\(UUID().uuidString)"
        defaults = try #require(UserDefaults(suiteName: suiteName))
        defaults.removePersistentDomain(forName: suiteName)

        var config = InkConfig()
        config.promptThemeSource = source
        let configURL = directory.appendingPathComponent("config.toml")
        try config.save(to: configURL)

        let project = Project(directory: directory)
        ProjectStore.save([project], defaults: defaults)
        let workspaceStore = WorkspaceStore(defaults: defaults)
        _ = workspaceStore.save(WorkspaceSnapshot(
            activeProjectPath: directory.path,
            projects: [
                .init(
                    path: directory.path,
                    activeTabIndex: 0,
                    tabs: [
                        .init(
                            customName: "初始",
                            activePaneID: "initial",
                            layout: .leaf(
                                paneID: "initial",
                                workingDirectory: directory.path
                            )
                        ),
                    ]
                ),
            ]
        ))

        if blockStarshipDirectory {
            let blockedParent = directory.appendingPathComponent("blocked")
            try Data("blocked".utf8).write(to: blockedParent)
            starshipURL = blockedParent.appendingPathComponent("starship.toml")
        } else {
            starshipURL = directory
                .appendingPathComponent("managed")
                .appendingPathComponent("starship.toml")
        }

        let warningCounter = PromptWarningCounter()
        self.warningCounter = warningCounter
        controller = MainWindowController(
            initialConfig: config,
            configURL: configURL,
            configSyncService: ConfigSyncService(defaults: defaults),
            projectDefaults: defaults,
            workspaceStore: workspaceStore,
            startPaneOverride: { size, workingDirectory in
                TerminalPane(session: TerminalSession(
                    size: size,
                    workingDirectory: workingDirectory
                ))
            },
            inkStarshipConfigURL: starshipURL,
            promptConfigFailureHandler: { _ in warningCounter.count += 1 }
        )
    }

    func cleanUp() {
        controller.window?.close()
        defaults.removePersistentDomain(forName: suiteName)
        try? FileManager.default.removeItem(at: directory)
    }
}

@MainActor
private final class PromptWarningCounter {
    var count = 0
}
```

- [ ] **Step 2: Run the suite and verify RED**

Run: `swift test --no-parallel --filter PromptThemeSessionTests`

Expected: compilation fails because the controller has no prompt seams or `makeTerminalSession` method.

- [ ] **Step 3: Add one session-construction path with one-time fallback warning**

Add controller state:

```swift
private let inkStarshipConfigURL: URL
private let promptConfigFailureHandler: (@MainActor (any Error) -> Void)?
private var didWarnPromptConfigFailure = false
```

Extend the internal initializer immediately after `startPaneOverride` with defaults, so existing callers keep source compatibility:

```swift
inkStarshipConfigURL: URL = InkStarshipConfig.defaultURL,
promptConfigFailureHandler: (@MainActor (any Error) -> Void)? = nil
```

Assign both values before `super.init`. Add:

```swift
func makeTerminalSession(
    size: TerminalSize,
    workingDirectory: String
) -> TerminalSession {
    let overrides: [String: String]
    do {
        overrides = try InkStarshipConfig.environmentOverrides(
            for: config.promptThemeSource,
            configURL: inkStarshipConfigURL
        )
    } catch {
        overrides = [:]
        if !didWarnPromptConfigFailure {
            didWarnPromptConfigFailure = true
            if let promptConfigFailureHandler {
                promptConfigFailureHandler(error)
            } else if let window {
                NSAlert(error: error).beginSheetModal(for: window)
            }
        }
    }
    return TerminalSession(
        size: size,
        workingDirectory: workingDirectory,
        scrollbackLines: config.scrollbackLines,
        environmentOverrides: overrides
    )
}
```

Replace the inline `TerminalSession` construction in `startPane` with:

```swift
let session = makeTerminalSession(size: size, workingDirectory: workingDirectory)
```

Do not move environment resolution into `startPaneOverride`; test fixtures that replace the complete pane creation path must remain isolated from user files.

- [ ] **Step 4: Run session, split, restore, and settings regressions**

Run:

```bash
swift test --no-parallel --filter PromptThemeSessionTests
swift test --no-parallel --filter TerminalSplitCommandTests
swift test --no-parallel --filter WorkspaceRestoreWindowTests
swift test --no-parallel --filter SettingsWindowTests
```

Expected: all suites pass; existing injected pane fixtures do not write the real `~/.config/ink/starship.toml`.

- [ ] **Step 5: Commit new-session wiring**

```bash
git add Sources/InkShell/MainWindowController.swift Tests/InkShellTests/PromptThemeSessionTests.swift
git commit -m "feat(shell): 为新 PTY 选择 Starship 配置" -m "只在创建新会话时解析 Ink 或用户来源，写入失败则回退现有 shell 环境并限制警告噪声。

Refs #94"
```

### Task 6: 完成验证、评审与 PR

**Files:**
- Verify: all files changed since `origin/main`
- Verify: `docs/superpowers/specs/2026-07-24-ink-starship-prompt-theme-design.md`
- Verify: `docs/roadmap.md`

**Interfaces:**
- Consumes: all prior task outputs.
- Produces: verified Issue #94 branch and a PR that closes only #94.

- [ ] **Step 1: Run focused aggregate tests**

```bash
swift test --no-parallel --filter 'InkConfigTests|ConfigSyncSnapshotTests|InkStarshipConfigTests|PTYSessionTests|TerminalSessionEnvironmentTests|PromptThemeSettingsTests|PromptThemeSessionTests|ConfigSyncSettingsTests|ConfigSyncWindowTests|TerminalSplitCommandTests|WorkspaceRestoreWindowTests|SettingsWindowTests'
```

Expected: all selected tests pass, with zero unexpected warnings.

- [ ] **Step 2: Run complete verification**

```bash
git diff --check origin/main...HEAD
swift test --no-parallel
swift build
```

Expected: clean diff check, full test pass, and warning-free debug build.

- [ ] **Step 3: Validate the generated config with Starship**

Launch the branch build once in Ink mode to create the managed file, then run:

```bash
TERM=xterm-256color COLORTERM=truecolor STARSHIP_CONFIG="$HOME/.config/ink/starship.toml" starship prompt >/dev/null
```

Expected: exit 0 without parse diagnostics. Inspect the generated file and confirm every style uses the allowed ANSI names and no six-digit hex color appears.

- [ ] **Step 4: Perform native-app manual acceptance**

Use the branch build and verify this checklist:

1. Default settings show `Ink 主题`.
2. A new tab displays OS, path, Git, optional runtime, time, duration, and character segments.
3. Each of the five Ink terminal themes recolors the prompt; light/dark appearance also changes it.
4. Switching to `用户配置` leaves the current pane unchanged and makes a new tab use `~/.config/starship.toml`.
5. Switching back makes a new split use the Ink-managed config.
6. A new Ghostty window still uses the original user Starship appearance.
7. A shell without Starship enabled starts normally and shows its own prompt.

- [ ] **Step 5: Review before completion**

Invoke `superpowers:requesting-code-review`, then run `superpowers:verification-before-completion` after addressing findings. Confirm:

- no renderer or `TerminalCore` changes;
- no user Starship or shell startup file writes;
- no per-frame or per-cell allocations;
- every setting change is backward-compatible in local TOML and schema 1 snapshots;
- failure fallback starts a usable shell and warns no more than once per window.

- [ ] **Step 6: Commit any review-only corrections**

If review changes code or docs, stage only Issue #94 files and commit:

```bash
git add Sources/InkConfig/InkConfig.swift Sources/InkConfig/ConfigSyncSnapshot.swift Sources/InkPTY/PTYSession.swift Sources/InkShell/InkStarshipConfig.swift Sources/InkShell/TerminalSession.swift Sources/InkShell/SettingsViewController.swift Sources/InkShell/MainWindowController.swift Tests/InkConfigTests/InkConfigTests.swift Tests/InkConfigTests/ConfigSyncSnapshotTests.swift Tests/InkPTYTests/PTYSessionTests.swift Tests/InkShellTests/InkStarshipConfigTests.swift Tests/InkShellTests/TerminalSessionEnvironmentTests.swift Tests/InkShellTests/PromptThemeSettingsTests.swift Tests/InkShellTests/PromptThemeSessionTests.swift docs/roadmap.md docs/superpowers/specs/2026-07-24-ink-starship-prompt-theme-design.md
git commit -m "fix(shell): 收紧提示符配置边界" -m "根据评审结果修正 Issue #94 范围内的隔离、回退或测试缺口。

Refs #94"
```

If review finds nothing, do not create an empty commit.

- [ ] **Step 7: Push and open the PR without merging or releasing**

```bash
git push -u origin agent/issue-94-ink-starship-prompt
gh pr create --base main --title "feat(shell): 支持 Ink Starship 提示符主题" --body "## 改动说明

- 默认为新建 Ink PTY 注入独立 Starship 配置
- 设置页可切换 Ink 主题与用户现有配置
- 用 ANSI 语义色让提示符跟随 Ink 主题，不影响 Ghostty

## 验证

- swift test --no-parallel
- swift build
- Starship 配置解析
- Ink / 用户配置切换、五主题明暗外观、Ghostty 隔离实机验收

## 风险

- 只修改新会话冷路径；写入失败回退用户 shell 环境
- 不修改 TerminalCore、Metal 热路径或用户 Starship 文件

## 文档与发布

- roadmap 与设计文档已更新
- 不涉及 tag 或发布

Closes #94"
```

Do not merge the PR, create a release tag, or publish an artifact unless the repository owner explicitly asks.
