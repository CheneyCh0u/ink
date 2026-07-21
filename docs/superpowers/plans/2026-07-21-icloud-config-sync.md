# iCloud 配置同步实现计划

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** 为 Ink 增加事件触发的 iCloud 配置自动上传、显式手动上传与手动拉取，并在任何云端失败下保留本机 TOML 配置。

**Architecture:** `InkConfig` 提供版本化 JSON 快照；`InkShell` 中独立的 `ConfigSyncService` 通过可替换存储协议封装 `NSUbiquitousKeyValueStore`；`MainWindowController` 继续作为保存、应用和覆盖确认的唯一协调者。设置页只呈现开关、状态和两个动作，不直接访问 iCloud。

**Tech Stack:** Swift 6、Foundation `Codable`、`NSUbiquitousKeyValueStore`、AppKit、Swift Testing、SwiftPM、macOS 14.0。

## Global Constraints

- `TerminalCore` 不得引入 AppKit、Metal 或 iCloud 依赖。
- 不引入第三方依赖；配置同步不得进入渲染、grid、scrollback 或逐帧路径。
- 只在配置变化事件、开关开启或按钮点击时执行；禁止周期性定时器和轮询。
- 只自动上传，云端配置只能由用户点击“拉取云端配置”后应用。
- TOML 继续是本机权威文件；拉取必须保留本机注释、空行和未知字段。
- 用户可见产品名写作 `Ink`；注释、文档和提交信息使用中文。
- 最低系统版本保持 macOS 14.0。
- 不创建发布 tag；发布仍需用户另行明确授权。

---

## 文件结构

- `Sources/InkConfig/ConfigSyncSnapshot.swift`：schema 1 JSON DTO、完整字段校验与 `InkConfig` 映射。
- `Sources/InkShell/ConfigSyncService.swift`：KVS 存储协议、生产适配器、本机偏好、同步状态和上传/读取操作。
- `Sources/InkShell/SettingsViewController.swift`：独立 iCloud 分组及纯 UI 回调。
- `Sources/InkShell/MainWindowController.swift`：本地配置来源判定、自动上传接线、手动覆盖确认和拉取应用。
- `Resources/Ink.entitlements`：固定 KVS entitlement。
- `scripts/package-app.sh`：把 entitlement 附加到应用签名。
- `Tests/InkConfigTests/ConfigSyncSnapshotTests.swift`：JSON 往返、schema 和非法负载测试。
- `Tests/InkShellTests/ConfigSyncServiceTests.swift`：内存 KVS 上的状态与触发测试。
- `Tests/InkShellTests/ConfigSyncSettingsTests.swift`：设置分组、回调、禁用态和文案测试。
- `Tests/InkShellTests/ConfigSyncWindowTests.swift`：覆盖确认、TOML 保留和自动上传集成测试。
- `Tests/ReleaseWorkflowTests/ReleaseWorkflowTests.swift`：entitlement 与签名脚本回归测试。
- `README.md`、`docs/design-system.md`、`docs/release.md`：用户行为、界面规范和签名限制。

---

### Task 1: 版本化配置快照

**Files:**
- Create: `Sources/InkConfig/ConfigSyncSnapshot.swift`
- Create: `Tests/InkConfigTests/ConfigSyncSnapshotTests.swift`

**Interfaces:**
- Consumes: `InkConfig` 及其四个字符串枚举。
- Produces: `ConfigSyncSnapshot.currentSchemaVersion`、`init(config:modifiedAt:deviceID:)`、`encoded()`、`decode(_:)` 与 `ConfigSyncSnapshotError`。

- [ ] **Step 1: 写完整往返失败测试**

创建测试文件，构造一个每个字段都不同于默认值的 `InkConfig`，使用整秒日期避免 ISO 8601 精度歧义：

```swift
import Foundation
import Testing
@testable import InkConfig

@Suite("配置同步快照")
struct ConfigSyncSnapshotTests {
    @Test("schema 1 JSON 完整往返所有已知设置")
    func roundTripsEveryKnownSetting() throws {
        var config = InkConfig()
        config.appearanceMode = .dark
        config.startupSidebarMode = .hidden
        config.rememberWindowFrame = false
        config.windowWidth = 1440
        config.windowHeight = 900
        config.fontFamily = nil
        config.fontSize = 17
        config.lineHeight = 1.25
        config.fontCellHeightAdjustment = -2
        config.fontThicken = false
        config.fontThickenStrength = 64
        config.terminalTheme = .pine
        config.cursorStyle = .underline
        config.cursorBlink = false
        config.optionAsMeta = false
        config.copyOnSelect = true
        config.scrollbackLines = 250_000
        let date = Date(timeIntervalSince1970: 1_785_000_000)

        let original = ConfigSyncSnapshot(
            config: config,
            modifiedAt: date,
            deviceID: "mac-a"
        )
        let decoded = try ConfigSyncSnapshot.decode(original.encoded())

        #expect(decoded == original)
        #expect(decoded.schemaVersion == 1)
        #expect(decoded.config == config)
    }
}
```

- [ ] **Step 2: 运行测试并确认 RED**

Run: `swift test --filter ConfigSyncSnapshotTests`

Expected: 编译失败，提示 `ConfigSyncSnapshot` 不存在。

- [ ] **Step 3: 实现 schema 1 编解码与逐字段校验**

实现公开外壳，并在同文件用私有 `WireSnapshot` / `WireConfig` 承载固定 JSON 键：

```swift
public enum ConfigSyncSnapshotError: Error, Equatable, Sendable {
    case unsupportedSchema(Int)
    case invalidPayload
}

public struct ConfigSyncSnapshot: Equatable, Sendable {
    public static let currentSchemaVersion = 1
    public let schemaVersion: Int
    public let modifiedAt: Date
    public let deviceID: String
    public let config: InkConfig

    public init(config: InkConfig, modifiedAt: Date, deviceID: String) {
        self.schemaVersion = Self.currentSchemaVersion
        self.modifiedAt = modifiedAt
        self.deviceID = deviceID
        self.config = config
    }

    public func encoded() throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        return try encoder.encode(WireSnapshot(snapshot: self))
    }

    public static func decode(_ data: Data) throws -> Self {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let wire = try decoder.decode(WireSnapshot.self, from: data)
        guard wire.schemaVersion == currentSchemaVersion else {
            throw ConfigSyncSnapshotError.unsupportedSchema(wire.schemaVersion)
        }
        return try wire.validatedSnapshot()
    }
}
```

`WireConfig` 必须显式列出设计文档 JSON 示例中的 17 个字段。`validatedSnapshot()` 逐项执行与 TOML 加载相同的范围检查：窗口宽 `640...4096`、窗口高 `400...2160`、字号 `6...72`、行高 `0.8...2.0`、cell 高度 `-10...20`、增粗强度 `0...255`、scrollback `100...2_000_000`；枚举使用 `rawValue` 初始化。任一检查失败抛出 `.invalidPayload`，不能生成部分配置。

- [ ] **Step 4: 增加 schema 与非法负载测试**

在测试文件追加三个测试：把编码后 JSON 的 `schemaVersion` 改为 `2` 并断言 `.unsupportedSchema(2)`；把 `fontSize` 改为 `100` 并断言 `.invalidPayload`；传入 `{broken` 并断言解码抛错。测试必须同时断言 JSON 文本包含 `schemaVersion`、`modifiedAt`、`deviceID` 和 `config`。

- [ ] **Step 5: 运行配置测试并确认 GREEN**

Run: `swift test --filter ConfigSyncSnapshotTests && swift test --filter InkConfigTests`

Expected: 两组测试全部通过，0 failures。

- [ ] **Step 6: 提交快照层**

```bash
git add Sources/InkConfig/ConfigSyncSnapshot.swift Tests/InkConfigTests/ConfigSyncSnapshotTests.swift
git commit -m "feat(config): 建立可校验的同步快照" -m "用版本化 JSON 覆盖全部已知设置，并在应用云端数据前整体验证字段与 schema。" -m "Refs #50"
```

---

### Task 2: iCloud KVS 同步服务

**Files:**
- Create: `Sources/InkShell/ConfigSyncService.swift`
- Create: `Tests/InkShellTests/ConfigSyncServiceTests.swift`

**Interfaces:**
- Consumes: Task 1 的 `ConfigSyncSnapshot`。
- Produces: `ConfigCloudStore`、`UbiquitousConfigCloudStore`、`ConfigSyncStatus`、`ConfigSyncService`。

- [ ] **Step 1: 写内存存储和触发语义失败测试**

测试内定义：

```swift
@MainActor
final class MemoryConfigCloudStore: ConfigCloudStore {
    var isAvailable = true
    var values: [String: Data] = [:]
    var synchronizeCallCount = 0
    func data(forKey key: String) -> Data? { values[key] }
    func set(_ data: Data, forKey key: String) { values[key] = data }
    func synchronize() -> Bool {
        synchronizeCallCount += 1
        return isAvailable
    }
}
```

使用独立 `UserDefaults(suiteName:)` 覆盖：开关默认为关；打开时立即写一份快照；开启后 `configDidChange(_:)` 再写；关闭后变化不写；手动 `upload(_:)` 和 `readCloudSnapshot()` 不受开关影响；同一 defaults 中 `deviceID` 稳定。

- [ ] **Step 2: 运行服务测试并确认 RED**

Run: `swift test --filter ConfigSyncServiceTests`

Expected: 编译失败，提示服务与存储协议不存在。

- [ ] **Step 3: 实现协议、生产适配器与本机偏好**

在新文件定义：

```swift
@MainActor
protocol ConfigCloudStore: AnyObject {
    var isAvailable: Bool { get }
    func data(forKey key: String) -> Data?
    func set(_ data: Data, forKey key: String)
    @discardableResult func synchronize() -> Bool
}

@MainActor
final class UbiquitousConfigCloudStore: ConfigCloudStore {
    private let store: NSUbiquitousKeyValueStore
    init(store: NSUbiquitousKeyValueStore = .default) { self.store = store }
    var isAvailable: Bool { FileManager.default.ubiquityIdentityToken != nil }
    func data(forKey key: String) -> Data? { store.data(forKey: key) }
    func set(_ data: Data, forKey key: String) { store.set(data, forKey: key) }
    func synchronize() -> Bool { store.synchronize() }
}
```

固定 key 为 `ink.config.snapshot.v1`、偏好 key 为 `ink.sync.automaticUpload` 与 `ink.sync.deviceID`。`deviceID` 缺失时写入 `UUID().uuidString`。测试销毁 suite 时调用 `removePersistentDomain(forName:)`。

- [ ] **Step 4: 实现状态和同步服务**

使用以下精确接口：

```swift
enum ConfigSyncStatus: Equatable {
    case idle
    case uploading
    case reading
    case uploaded(Date)
    case cloudSnapshot(Date, isCurrentDevice: Bool)
    case cloudEmpty
    case unavailable
    case failed(String)
}

enum ConfigSyncServiceError: LocalizedError, Equatable {
    case iCloudUnavailable
    case synchronizeFailed
    case invalidSnapshot(String)
}

@MainActor
final class ConfigSyncService {
    private(set) var status: ConfigSyncStatus = .idle
    var onStatusChange: ((ConfigSyncStatus) -> Void)?
    var automaticUploadEnabled: Bool { get }

    init(
        store: ConfigCloudStore = UbiquitousConfigCloudStore(),
        defaults: UserDefaults = .standard,
        now: @escaping () -> Date = Date.init
    )

    func setAutomaticUploadEnabled(_ enabled: Bool, currentConfig: InkConfig)
    func configDidChange(_ config: InkConfig)
    func upload(_ config: InkConfig) throws
    func readCloudSnapshot() throws -> ConfigSyncSnapshot?
}
```

`setAutomaticUploadEnabled(true, ...)` 先保存偏好再调用 `upload`，失败只更新 `.unavailable` 或 `.failed`，不把开关改回关闭。`configDidChange` 仅在开关开启时上传并把错误转为状态。`upload` 检查 `isAvailable`、编码、写 KVS、调用一次 `synchronize()`，成功设 `.uploaded(now())`。`readCloudSnapshot` 调用一次 `synchronize()` 后读取；空值设 `.cloudEmpty`；有效值把快照 `deviceID` 与本机稳定 ID 比较后设 `.cloudSnapshot(date, isCurrentDevice:)`；解码错误包装为 `.invalidSnapshot`。不得注册远端变化通知，不得创建 Timer 或 `asyncAfter`。

- [ ] **Step 5: 增加错误与状态测试**

覆盖 `isAvailable == false`、`synchronize() == false`、损坏 JSON、云端空值；断言服务分别进入 `.unavailable`、`.failed`、`.failed`、`.cloudEmpty`，且本地测试配置未被修改。记录 `onStatusChange` 数组，断言上传经过 `.uploading`，读取经过 `.reading`。

- [ ] **Step 6: 运行服务测试并确认 GREEN**

Run: `swift test --filter ConfigSyncServiceTests`

Expected: 全部通过，0 failures；源码搜索不存在 `Timer`、`asyncAfter` 或远端通知注册。

- [ ] **Step 7: 提交同步服务**

```bash
git add Sources/InkShell/ConfigSyncService.swift Tests/InkShellTests/ConfigSyncServiceTests.swift
git commit -m "feat(sync): 封装事件驱动的 iCloud 存储" -m "把 KVS、设备偏好和状态转换隔离在可测试服务中，只响应本地变化与显式操作。" -m "Refs #50"
```

---

### Task 3: 设置页 iCloud 分组

**Files:**
- Modify: `Sources/InkShell/SettingsViewController.swift`
- Create: `Tests/InkShellTests/ConfigSyncSettingsTests.swift`
- Modify: `Tests/InkShellTests/SettingsWindowTests.swift`

**Interfaces:**
- Consumes: Task 2 的 `ConfigSyncStatus`。
- Produces: `onAutomaticUploadChange`、`onUploadConfig`、`onPullConfig`、`updateSync(automaticUploadEnabled:status:)`。

- [ ] **Step 1: 写布局与回调失败测试**

创建 `ConfigSyncSettingsTests`，加载 `SettingsViewController` 后递归查找控件并断言：分组标题顺序为 `外观、窗口、终端、光标、交互、iCloud、高级`；存在 accessibility label 为“自动上传配置”的 `NSSwitch`；存在标题为“上传到云端”和“拉取云端配置”的按钮；切换开关与点击按钮分别调用三个回调。更新现有 `SettingsWindowTests.settingsSectionsShareOneContentColumn()` 的标题数组，加入 `iCloud`。

- [ ] **Step 2: 运行 UI 测试并确认 RED**

Run: `swift test --filter 'ConfigSyncSettingsTests|SettingsWindowTests'`

Expected: 找不到 iCloud 分组与控件，测试失败。

- [ ] **Step 3: 增加控件、分组和纯 UI 接口**

给控制器增加：

```swift
var onAutomaticUploadChange: ((Bool) -> Void)?
var onUploadConfig: (() -> Void)?
var onPullConfig: (() -> Void)?

private let automaticUploadSwitch = NSSwitch()
private let syncStatusLabel = NSTextField(wrappingLabelWithString: "尚未上传")
private let uploadConfigButton = NSButton()
private let pullConfigButton = NSButton()
```

在“交互”和“高级”之间插入独立 `iCloud` section。第一行使用现有 `makeRow`，标题“自动上传配置”，说明“修改设置后上传到 iCloud”。第二行使用新的 `makeSyncActionsRow()`：左侧状态，右侧两个 `.rounded` 次级按钮；按钮使用 `arrow.up.to.line` / `arrow.down.to.line` SF Symbols，并设置同名 accessibility label。

三个 selector 只能发送回调，不能读写 KVS。实现：

```swift
func updateSync(automaticUploadEnabled: Bool, status: ConfigSyncStatus) {
    automaticUploadSwitch.state = automaticUploadEnabled ? .on : .off
    let busy = status == .uploading || status == .reading
    automaticUploadSwitch.isEnabled = !busy
    uploadConfigButton.isEnabled = !busy
    pullConfigButton.isEnabled = !busy
    syncStatusLabel.stringValue = syncStatusText(status)
}
```

状态文案固定为：`尚未上传`、`正在上传…`、`正在读取…`、`已上传 · <相对时间>`、`云端配置来自此 Mac/其它 Mac · <时间>`、`云端暂无配置`、`iCloud 不可用`、`同步失败：<原因>`。日期格式集中在一个 helper，测试注入固定日期时只断言稳定前缀和设备来源。

- [ ] **Step 4: 增加禁用态和错误文案测试**

分别传 `.uploading`、`.reading`、`.cloudEmpty`、`.unavailable`、`.failed("损坏数据")`，断言 busy 状态禁用三个控件，空闲状态恢复；关闭自动上传时两个手动按钮仍启用；状态 label 的 accessibility value 与可见文字一致。

- [ ] **Step 5: 运行 UI 测试并确认 GREEN**

Run: `swift test --filter 'ConfigSyncSettingsTests|SettingsWindowTests'`

Expected: 全部通过，窗口 frame 与统一内容列测试不回退。

- [ ] **Step 6: 提交设置界面**

```bash
git add Sources/InkShell/SettingsViewController.swift Tests/InkShellTests/ConfigSyncSettingsTests.swift Tests/InkShellTests/SettingsWindowTests.swift
git commit -m "feat(settings): 增加 iCloud 同步操作区" -m "用独立分组呈现自动上传、手动方向和内联状态，保持关闭开关后仍可按需同步。" -m "Refs #50"
```

---

### Task 4: 配置保存、覆盖确认与拉取应用

**Files:**
- Modify: `Sources/InkShell/MainWindowController.swift`
- Create: `Tests/InkShellTests/ConfigSyncWindowTests.swift`

**Interfaces:**
- Consumes: Task 2 的服务和 Task 3 的设置页回调。
- Produces: 本地变化自动上传、手动上传确认、手动拉取确认、云端来源保存抑制。

- [ ] **Step 1: 写自动上传集成失败测试**

为 `MainWindowController` 增加测试专用初始化入口所需的测试，使用临时 `config.toml`、内存 store 和独立 defaults。断言：打开自动上传立即写云端；设置保存成功后再次写；外部 TOML 变化经 watcher 后上传；云端拉取写回产生的 watcher 事件不再次上传。每个测试记录 store 的 `setCallCount`，不用等待网络。

- [ ] **Step 2: 写手动覆盖与 TOML 保留失败测试**

预置不同的云端快照，显示设置后点击上传按钮，断言 `window.attachedSheet` 是信息包含“本机配置将覆盖云端配置”的 `NSAlert`，且按钮顺序为“取消”“上传并覆盖”。预置带注释和未知字段的本地 TOML，点击拉取后确认“拉取并覆盖”，断言 `InkConfig.load(from:)` 等于云端配置，同时原文仍包含注释和未知键。

- [ ] **Step 3: 重构窗口初始化以支持无副作用注入**

保留 `public convenience init()`，新增内部 designated initializer：

```swift
init(
    initialConfig: InkConfig,
    configURL: URL,
    configSyncService: ConfigSyncService
)
```

它创建与当前完全相同的 `NSWindow`，保存 `configURL` 和服务，然后执行现有 `loadProjects()`、`buildContent()`、`applyConfig()` 与 watcher 安装。公开初始化读取 `InkConfig.defaultURL` 后转调。`ConfigWatcher` 必须使用注入的 URL，测试不得读写真实用户配置。

- [ ] **Step 4: 统一配置来源并接入自动上传**

增加：

```swift
private enum ConfigChangeOrigin { case local, cloud }

private func saveConfig(
    _ fresh: InkConfig,
    origin: ConfigChangeOrigin = .local
) {
    do {
        try fresh.save(to: configURL)
        config = fresh
        applyConfig(fresh)
        settingsVC.update(config: fresh)
        if origin == .local { configSyncService.configDidChange(fresh) }
    } catch {
        guard let window else { return }
        NSAlert(error: error).beginSheetModal(for: window)
    }
}
```

watcher 回调先 `guard fresh != self.config else { return }`，再应用外部变化并调用 `configDidChange`。这个相等判断让设置页保存只上传一次，也让云端拉取写回产生的 watcher 事件不回传云端。

在 `buildContent()` 接线开关与按钮，并把 `configSyncService.onStatusChange` 映射到 `settingsVC.updateSync(...)`。打开设置页时总是刷新开关和当前状态。

- [ ] **Step 5: 实现两个方向的确认 sheet**

新增 `uploadConfigToCloud()` 与 `pullConfigFromCloud()`。两者先调用 `readCloudSnapshot()`：云端为空或内容相同时直接上传/只更新状态；内容不同时创建 sheet。确认 sheet 必须先 `addButton(withTitle: "取消")`，再添加“上传并覆盖”或“拉取并覆盖”，只在 `.alertSecondButtonReturn` 执行覆盖。

拉取确认后调用 `saveConfig(snapshot.config, origin: .cloud)`；上传确认后调用 `try configSyncService.upload(config)`。所有错误只更新服务状态并刷新内联文案，不再额外弹成功或网络错误对话框；本地 TOML 写入错误仍沿用 `NSAlert(error:)`。

- [ ] **Step 6: 运行窗口集成测试并确认 GREEN**

Run: `swift test --filter 'ConfigSyncWindowTests|SettingsWindowTests'`

Expected: 自动上传次数、两个覆盖方向、无回环和 TOML 保留测试全部通过。

- [ ] **Step 7: 提交协调层**

```bash
git add Sources/InkShell/MainWindowController.swift Tests/InkShellTests/ConfigSyncWindowTests.swift
git commit -m "feat(sync): 接通配置上传与显式拉取" -m "让本地变化自动上传，并把所有云端覆盖集中到用户确认后的窗口协调流程。" -m "Refs #50"
```

---

### Task 5: Entitlement、打包、文档与完整验收

**Files:**
- Create: `Resources/Ink.entitlements`
- Modify: `scripts/package-app.sh`
- Modify: `Tests/ReleaseWorkflowTests/ReleaseWorkflowTests.swift`
- Modify: `README.md`
- Modify: `docs/design-system.md`
- Modify: `docs/release.md`

**Interfaces:**
- Consumes: 前四个任务完成的功能。
- Produces: 带 KVS entitlement 的 app 签名、用户文档和最终验证证据。

- [ ] **Step 1: 写 entitlement 打包失败测试**

在 `ReleaseWorkflowTests` 增加测试：用 `PropertyListSerialization` 读取 `Resources/Ink.entitlements`，断言 `com.apple.developer.ubiquity-kvstore-identifier == "FS3WL6385L.com.cheneychou.ink"`；读取打包脚本，断言 required paths 包含 entitlement，且 `codesign` 参数包含 `--entitlements`。此时文件不存在，测试应失败。

- [ ] **Step 2: 运行发布测试并确认 RED**

Run: `swift test --filter ReleaseWorkflowTests`

Expected: `Ink.entitlements` 不存在或脚本缺少参数，测试失败。

- [ ] **Step 3: 增加 entitlement 并接入签名**

创建标准 plist：

```xml
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "https://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>com.apple.developer.ubiquity-kvstore-identifier</key>
    <string>FS3WL6385L.com.cheneychou.ink</string>
</dict>
</plist>
```

在 `package-app.sh` 定义显式 `entitlements_path="$project_root/Resources/Ink.entitlements"`，加入 `required_paths`，并把 `--entitlements "$entitlements_path"` 加到 `signing_args`。保留现有 ad-hoc 默认和 Developer ID 分支，不添加发布凭据。

- [ ] **Step 4: 运行发布测试并确认 GREEN**

Run: `swift test --filter ReleaseWorkflowTests && plutil -lint Resources/Ink.entitlements`

Expected: 测试通过，plist 输出 `OK`。

- [ ] **Step 5: 同步三份用户文档**

更新 `README.md`：外观与配置列表增加 iCloud；修正设置入口为顶部齿轮；说明开关只自动上传、拉取必须点击按钮、`swift run`/ad-hoc 包可能显示不可用。更新 `docs/design-system.md` 的内嵌设置页：固定 iCloud 分组位于交互与高级之间、两个按钮均为次级动作、状态不用颜色单独表达。更新 `docs/release.md`：entitlement 会进入包，但当前 ad-hoc 发布缺少有效 provisioning，iCloud KVS 只在正确 Apple Development/Distribution 签名下验收。

- [ ] **Step 6: 运行全部自动验证**

Run: `swift test`

Expected: 全部测试通过，0 failures。

Run: `swift build`

Expected: 构建成功且没有新增 warning。

Run: `rg -n 'Timer|asyncAfter|didChangeExternallyNotification' Sources/InkShell/ConfigSyncService.swift`

Expected: 无输出，确认服务没有轮询、延时任务或自动远端应用监听。

- [ ] **Step 7: 验证打包签名携带 entitlement**

创建显式临时目录并打包：

```bash
package_verify_dir="$(mktemp -d "${TMPDIR:-/tmp}/ink-sync-package.XXXXXX")"
scripts/package-app.sh v2026.07.21-99 "$package_verify_dir"
ditto -x -k "$package_verify_dir/Ink-v2026.07.21-99.zip" "$package_verify_dir/unpacked"
codesign -d --entitlements :- "$package_verify_dir/unpacked/Ink.app" 2>&1 | plutil -p -
```

Expected: 输出包含 `com.apple.developer.ubiquity-kvstore-identifier` 和 `FS3WL6385L.com.cheneychou.ink`。验证完成后只删除刚刚由 `mktemp` 返回并人工核对前缀为 `ink-sync-package.` 的目录。

- [ ] **Step 8: 完成真实双 Mac 验收**

用具备对应 iCloud capability 的 Apple 签名构建，在登录同一 iCloud 账户的 Mac A/B 上逐项记录：A 开启后立即上传；A 修改设置后事件上传；B 未点击时配置不变；B 点击拉取并确认后全部已知字段变化且 TOML 注释保留；B 关闭自动上传后仍可使用两个按钮。若当前没有第二台环境或 provisioning，将此项如实写入 PR 风险，不能声称已完成端到端同步。

- [ ] **Step 9: 提交打包与文档**

```bash
git add Resources/Ink.entitlements scripts/package-app.sh Tests/ReleaseWorkflowTests/ReleaseWorkflowTests.swift README.md docs/design-system.md docs/release.md
git commit -m "build(sync): 为 iCloud KVS 配置签名" -m "把固定 KVS entitlement 接入应用打包，并说明 ad-hoc 构建的能力边界与同步交互。" -m "Refs #50"
```

- [ ] **Step 10: 最终核对并创建 PR**

```bash
git status --short
git log --oneline origin/main..HEAD
git diff --check origin/main...HEAD
git push -u origin agent/issue-50-icloud-config-sync
gh pr create --base main --title "feat(sync): 支持 iCloud 配置同步" --body "增加版本化 JSON 配置快照和 iCloud KVS 存储；本机配置变化后自动上传，云端配置仅在用户点击并确认后拉取；设置页提供独立 iCloud 分组、状态和两个手动方向；打包携带 KVS entitlement。验证：swift test、swift build、entitlement 签名检查；跨 Mac 实测结果见 PR。风险：ad-hoc 构建无法保证 iCloud 可用，正式能力依赖 Apple provisioning。文档已更新，不涉及发布。 Closes #50"
```

Expected: 工作区干净，分支推送成功，PR 只关联并关闭 Issue #50；不合并、不打 tag、不发布，等待仓库拥有者评审。
