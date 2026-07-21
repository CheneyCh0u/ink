# Ghostty Font Metrics Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** 让 Ink 独立支持 Ghostty 风格的 cell 高度与字体增粗配置，并把默认字体度量设为 Maple Mono NF CN 15pt、原生行高、cell 高度增加 1px、增粗强度 128。

**Architecture:** InkConfig 负责配置默认值、校验与持久化；InkTerminalView 用一个共享的 `FontGridMetrics` 计算布局与 atlas 的物理像素尺寸；GlyphAtlas 只在首次栅格化字形时把字体平滑参数交给 CoreGraphics。InkShell 负责设置控件和 pane 配置映射，TerminalCore 不参与。

**Tech Stack:** Swift 6、AppKit、CoreText、CoreGraphics、Metal、Swift Testing、SwiftPM，最低 macOS 14.0。

## Global Constraints

- `TerminalCore` 不得引入 AppKit、CoreText 或 Metal。
- 不新增第三方依赖，不打包 Maple Mono，不读取 Ghostty 配置。
- `adjust_cell_height` 的单位是物理像素，不随 backing scale 再次放大。
- 字体增粗只发生在 glyph atlas 未命中的首次栅格化，不进入逐帧实例构建或 shader。
- 配色不在本次范围内。
- 注释、文档和提交信息用中文，代码标识符用英文。
- 每个行为先写失败测试并确认失败，再写最小实现。
- 完成后运行 `swift test`、`swift build`，并做真实 Ink 界面检查与 Time Profiler 采样。

---

## File Map

- `Sources/InkConfig/InkConfig.swift`：新增配置字段、默认值、范围校验和 TOML 往返。
- `Tests/InkConfigTests/InkConfigTests.swift`：覆盖默认值、合法值、非法值和保存往返。
- `Sources/InkTerminalView/FontGridMetrics.swift`：集中计算 cell 宽高、自然行高和 baseline。
- `Tests/InkTerminalViewTests/FontGridMetricsTests.swift`：验证物理像素调整与 Retina 尺度。
- `Sources/InkTerminalView/GlyphAtlas.swift`：使用共享度量，并把字体平滑参数交给 CoreGraphics。
- `Sources/InkTerminalView/TerminalRenderer.swift`：把新增参数传给 GlyphAtlas。
- `Sources/InkTerminalView/TerminalMetalView.swift`：公开新增配置属性，统一预估布局与 renderer 参数。
- `Tests/InkTerminalViewTests/GlyphAtlasTests.swift`：验证 atlas 参数和单色/彩色路径边界。
- `Sources/InkShell/TerminalWorkspaceViewController.swift`：把 InkConfig 映射到每个 pane。
- `Sources/InkShell/SettingsViewController.swift`：增加 cell 高度、字体增粗和强度控件。
- `Tests/InkShellTests/TerminalWorkspaceTests.swift`：验证 pane 初始映射和热更新。
- `Tests/InkShellTests/TerminalFontSettingsTests.swift`：验证设置页控件写回与禁用状态。
- `docs/design-system.md`：更新默认字体与字体度量说明。
- `docs/perf.md`：记录 Time Profiler 结果。
- `~/.config/ink/config.toml`：在所有代码验证通过后更新当前开发机器的六项字体配置，不纳入 Git。

---

### Task 1: 扩展 InkConfig 字体配置

**Files:**
- Modify: `Tests/InkConfigTests/InkConfigTests.swift`
- Modify: `Sources/InkConfig/InkConfig.swift`

**Interfaces:**
- Produces: `fontCellHeightAdjustment: Int`、`fontThicken: Bool`、`fontThickenStrength: Int`。
- Defaults: `fontFamily = "Maple Mono NF CN"`、`fontSize = 15`、`lineHeight = 1.0`、`fontCellHeightAdjustment = 1`、`fontThicken = true`、`fontThickenStrength = 128`。

- [ ] **Step 1: 写默认值与合法加载的失败测试**

在 `InkConfigTests` 增加断言：

```swift
@Test("默认字体度量与参考 Ghostty 配置一致")
func ghosttyCompatibleFontDefaults() {
    let config = InkConfig()
    #expect(config.fontFamily == "Maple Mono NF CN")
    #expect(config.fontSize == 15)
    #expect(config.lineHeight == 1)
    #expect(config.fontCellHeightAdjustment == 1)
    #expect(config.fontThicken)
    #expect(config.fontThickenStrength == 128)
}
```

把 `loadAndClamp()` 的 `[font]` fixture 扩展为：

```toml
[font]
size = 16
adjust_cell_height = -2
thicken = false
thicken_strength = 64
```

并断言四项都被读取。

- [ ] **Step 2: 运行配置测试并确认 RED**

Run: `swift test --filter InkConfigTests`

Expected: 编译失败，提示 `InkConfig` 没有 `fontCellHeightAdjustment`、`fontThicken` 和 `fontThickenStrength`。

- [ ] **Step 3: 实现字段、默认值与解析**

在 `InkConfig` 增加：

```swift
public var fontFamily: String? = "Maple Mono NF CN"
public var fontSize: Double = 15
public var lineHeight: Double = 1
public var fontCellHeightAdjustment = 1
public var fontThicken = true
public var fontThickenStrength = 128
```

加载时先保留空字符串代表系统等宽字体的旧语义，再使用既有的忽略非法值策略：

```swift
if let family = values.string("font.family") {
    config.fontFamily = family.isEmpty ? nil : family
}
if let adjustment = values.int("font.adjust_cell_height"),
   (-10...20).contains(adjustment) {
    config.fontCellHeightAdjustment = adjustment
}
if let thicken = values.bool("font.thicken") {
    config.fontThicken = thicken
}
if let strength = values.int("font.thicken_strength"),
   (0...255).contains(strength) {
    config.fontThickenStrength = strength
}
```

把三个键加入 `tomlValues`，并更新文件头示例。

- [ ] **Step 4: 写非法值与保存往返的失败测试**

新增 fixture，使用 `adjust_cell_height = 21` 和 `thicken_strength = 256`，断言回退为 `1` 与 `128`。在 `saveRoundtripPreservesUnknownFields()` 中设置 `-3`、`false`、`96`，断言保存后 `InkConfig.load(from:) == config`。

- [ ] **Step 5: 运行配置测试并确认 GREEN**

Run: `swift test --filter InkConfigTests`

Expected: `InkConfigTests` 全部通过，0 failures。

- [ ] **Step 6: 提交配置层**

```bash
git add Sources/InkConfig/InkConfig.swift Tests/InkConfigTests/InkConfigTests.swift
git commit -m "feat(config): 保存 Ghostty 风格字体参数" -m "让默认字体度量和新增字段可以独立持久化，同时对越界值安全回退。" -m "Refs #44"
```

---

### Task 2: 统一物理像素字体度量

**Files:**
- Create: `Sources/InkTerminalView/FontGridMetrics.swift`
- Create: `Tests/InkTerminalViewTests/FontGridMetricsTests.swift`
- Modify: `Sources/InkTerminalView/GlyphAtlas.swift`
- Modify: `Sources/InkTerminalView/TerminalMetalView.swift`

**Interfaces:**
- Produces: `FontGridMetrics.init(font:scale:lineHeightMultiplier:cellHeightAdjustment:)`。
- Produces: `cellWidth`、`naturalHeight`、`cellHeight`、`baselineFromBottom`，单位均为物理像素。
- Consumes: Task 1 的 `fontCellHeightAdjustment`，但该类型本身不依赖 InkConfig。

- [ ] **Step 1: 写 FontGridMetrics 的失败测试**

```swift
import AppKit
import Testing
@testable import InkTerminalView

@Suite("字体网格度量")
struct FontGridMetricsTests {
    @Test("cell 高度调整使用物理像素")
    func adjustmentUsesPhysicalPixels() {
        let font = NSFont.monospacedSystemFont(ofSize: 14, weight: .regular)
        let base = FontGridMetrics(
            font: font, scale: 2, lineHeightMultiplier: 1,
            cellHeightAdjustment: 0
        )
        let adjusted = FontGridMetrics(
            font: font, scale: 2, lineHeightMultiplier: 1,
            cellHeightAdjustment: 1
        )
        #expect(adjusted.cellHeight == base.cellHeight + 1)
        #expect(adjusted.cellWidth == base.cellWidth)
    }

    @Test("负调整不能把 cell 压到零")
    func adjustmentClampsCellHeight() {
        let font = NSFont.monospacedSystemFont(ofSize: 6, weight: .regular)
        let metrics = FontGridMetrics(
            font: font, scale: 2, lineHeightMultiplier: 0.8,
            cellHeightAdjustment: -10_000
        )
        #expect(metrics.cellHeight == 1)
    }
}
```

- [ ] **Step 2: 运行度量测试并确认 RED**

Run: `swift test --filter FontGridMetricsTests`

Expected: 编译失败，提示找不到 `FontGridMetrics`。

- [ ] **Step 3: 实现共享度量类型**

```swift
import AppKit

struct FontGridMetrics {
    let cellWidth: CGFloat
    let naturalHeight: CGFloat
    let cellHeight: CGFloat
    let baselineFromBottom: CGFloat

    init(
        font: NSFont,
        scale: CGFloat,
        lineHeightMultiplier: CGFloat,
        cellHeightAdjustment: Int
    ) {
        let advance = ("0" as NSString).size(withAttributes: [.font: font]).width
        cellWidth = ceil(advance * scale)
        naturalHeight = ceil(NSLayoutManager().defaultLineHeight(for: font) * scale)
        let scaledHeight = ceil(naturalHeight * max(0.8, lineHeightMultiplier))
        cellHeight = max(1, scaledHeight + CGFloat(cellHeightAdjustment))
        let extra = cellHeight - naturalHeight
        baselineFromBottom = ceil(-font.descender * scale) + floor(extra / 2)
    }
}
```

- [ ] **Step 4: 让 GlyphAtlas 与 minimumViewportSize 共用度量**

给 `GlyphAtlas.init` 增加 `cellHeightAdjustment: Int = 0`，删除重复公式并读取 `FontGridMetrics`。给 `TerminalMetalView` 增加：

```swift
public var cellHeightAdjustment = 1 {
    didSet { if cellHeightAdjustment != oldValue { rebuildRenderer() } }
}
```

在 `minimumViewportSize` 中构造同一 `FontGridMetrics`，用 `metrics.cellWidth / scale` 与 `metrics.cellHeight / scale` 计算 point 尺寸。

- [ ] **Step 5: 运行度量与 GlyphAtlas 测试并确认 GREEN**

Run: `swift test --filter 'FontGridMetricsTests|GlyphAtlasTests'`

Expected: 两个 suite 全部通过，0 failures。

- [ ] **Step 6: 提交共享度量**

```bash
git add Sources/InkTerminalView/FontGridMetrics.swift Sources/InkTerminalView/GlyphAtlas.swift Sources/InkTerminalView/TerminalMetalView.swift Tests/InkTerminalViewTests/FontGridMetricsTests.swift
git commit -m "refactor(terminal): 统一字体网格物理像素度量" -m "让布局预估和 glyph atlas 共用同一公式，避免 cell 高度调整在 Retina 下重复缩放。" -m "Refs #44"
```

---

### Task 3: 在 GlyphAtlas 实现字体增粗

**Files:**
- Modify: `Tests/InkTerminalViewTests/GlyphAtlasTests.swift`
- Modify: `Sources/InkTerminalView/GlyphAtlas.swift`
- Modify: `Sources/InkTerminalView/TerminalRenderer.swift`
- Modify: `Sources/InkTerminalView/TerminalMetalView.swift`

**Interfaces:**
- Extends: `GlyphAtlas.init(device:font:scale:lineHeightMultiplier:cellHeightAdjustment:fontThicken:fontThickenStrength:)`。
- Extends: `TerminalRenderer.init(font:scale:lineHeightMultiplier:cellHeightAdjustment:fontThicken:fontThickenStrength:)`。
- Produces on TerminalMetalView: `fontThicken: Bool` 与 `fontThickenStrength: Int`。

- [ ] **Step 1: 写 atlas 参数的失败测试**

把测试 helper 改为接收增粗参数，并新增：

```swift
@Test("字体增粗参数保留在 atlas 栅格化配置中")
func fontThickeningOptions() throws {
    let atlas = try #require(makeAtlas(fontThicken: true, strength: 128))
    #expect(atlas.fontThicken)
    #expect(atlas.fontThickenStrength == 128)
    #expect(try #require(atlas.entry(for: "A", bold: false, italic: false)).isColor == false)
    #expect(try #require(atlas.entry(for: "🚀", bold: false, italic: false)).isColor)
}
```

- [ ] **Step 2: 运行 GlyphAtlas 测试并确认 RED**

Run: `swift test --filter GlyphAtlasTests`

Expected: 编译失败，提示初始化参数或属性不存在。

- [ ] **Step 3: 扩展 atlas 与 renderer 参数**

在 `GlyphAtlas` 保存只读配置：

```swift
let fontThicken: Bool
let fontThickenStrength: Int
```

在 `TerminalMetalView` 增加会触发 `rebuildRenderer()` 的同名公开属性，并由 `rebuildRenderer()` 传给 TerminalRenderer，再传给 GlyphAtlas。

- [ ] **Step 4: 切换单色位图上下文并配置 CoreGraphics**

单色上下文改为 alpha-only：

```swift
context = CGContext(
    data: raw.baseAddress, width: width, height: height,
    bitsPerComponent: 8, bytesPerRow: bytesPerRow,
    space: nil,
    bitmapInfo: CGImageAlphaInfo.alphaOnly.rawValue
)
```

只在单色分支设置：

```swift
ctx.setAllowsFontSmoothing(true)
ctx.setShouldSmoothFonts(fontThicken)
ctx.setAllowsFontSubpixelPositioning(true)
ctx.setShouldSubpixelPositionFonts(true)
ctx.setAllowsFontSubpixelQuantization(false)
ctx.setShouldSubpixelQuantizeFonts(false)
ctx.setAllowsAntialiasing(true)
ctx.setShouldAntialias(true)
let strength = CGFloat(fontThickenStrength) / 255
ctx.setFillColor(gray: strength, alpha: 1)
ctx.setStrokeColor(gray: strength, alpha: 1)
```

彩色上下文保留白色填充与现有 BGRA 格式，不应用这些增粗参数。

- [ ] **Step 5: 运行终端视图测试并确认 GREEN**

Run: `swift test --filter InkTerminalViewTests`

Expected: `InkTerminalViewTests` 全部通过，0 failures。

- [ ] **Step 6: 提交字体增粗实现**

```bash
git add Sources/InkTerminalView/GlyphAtlas.swift Sources/InkTerminalView/TerminalRenderer.swift Sources/InkTerminalView/TerminalMetalView.swift Tests/InkTerminalViewTests/GlyphAtlasTests.swift
git commit -m "feat(terminal): 在 glyph atlas 支持字体增粗" -m "复用 macOS CoreGraphics 字体平滑路径，让增粗只发生在字形首次栅格化时。" -m "Refs #44"
```

---

### Task 4: 接通 pane 与设置界面

**Files:**
- Modify: `Tests/InkShellTests/TerminalWorkspaceTests.swift`
- Create: `Tests/InkShellTests/TerminalFontSettingsTests.swift`
- Modify: `Sources/InkShell/TerminalWorkspaceViewController.swift`
- Modify: `Sources/InkShell/SettingsViewController.swift`

**Interfaces:**
- Consumes: Task 1 的三个 InkConfig 字段。
- Consumes: Task 2 和 Task 3 的 TerminalMetalView 公开属性。

- [ ] **Step 1: 写 pane 配置映射的失败测试**

```swift
@Test("字体度量配置应用到已有 pane")
func fontMetricsHotReloadUpdatesExistingPane() throws {
    let pane = makePane()
    let tab = TerminalTab(initialPane: pane)
    let workspace = TerminalWorkspaceViewController()
    var config = InkConfig()
    config.fontCellHeightAdjustment = 3
    config.fontThicken = false
    config.fontThickenStrength = 90

    workspace.show(tab: tab, config: config)
    let terminalView = try #require(workspace.terminalView(for: pane.id))
    #expect(terminalView.cellHeightAdjustment == 3)
    #expect(terminalView.fontThicken == false)
    #expect(terminalView.fontThickenStrength == 90)

    config.fontCellHeightAdjustment = -2
    config.fontThicken = true
    config.fontThickenStrength = 160
    workspace.apply(config: config)
    #expect(terminalView.cellHeightAdjustment == -2)
    #expect(terminalView.fontThicken)
    #expect(terminalView.fontThickenStrength == 160)
}
```

- [ ] **Step 2: 写设置控件的失败测试**

创建 `TerminalFontSettingsTests`，通过 accessibility label 找到“字体增粗”“Cell 高度”“增粗强度”。断言默认值为 on、1、128；关闭开关后 `onChange` 收到 `fontThicken == false`，强度控件禁用。

- [ ] **Step 3: 运行 InkShell 测试并确认 RED**

Run: `swift test --filter 'TerminalWorkspaceTests|TerminalFontSettingsTests'`

Expected: pane 属性或设置控件不存在，测试失败。

- [ ] **Step 4: 接通 TerminalWorkspaceViewController**

在 `apply(config:to:)` 增加：

```swift
terminalView.cellHeightAdjustment = config.fontCellHeightAdjustment
terminalView.fontThicken = config.fontThicken
terminalView.fontThickenStrength = config.fontThickenStrength
```

- [ ] **Step 5: 增加设置控件与状态同步**

新增控件：

```swift
private let cellHeightControl = NumericSettingControl(
    value: 1, range: -10...20, increment: 1, decimals: 0, suffix: "px"
)
private let fontThickenSwitch = NSSwitch()
private let fontThickenStrengthControl = NumericSettingControl(
    value: 128, range: 0...255, increment: 1, decimals: 0, suffix: ""
)
```

给开关设置 accessibility label “字体增粗”，给两个数值控件分别设置 “Cell 高度” 与 “增粗强度”。把它们加入终端字体区域，接入 `configureControls()`、`updateControls()` 和 `controlChanged()`。每次状态变化后执行：

```swift
fontThickenStrengthControl.isEnabled = config.fontThicken
```

- [ ] **Step 6: 运行 InkShell 测试并确认 GREEN**

Run: `swift test --filter 'TerminalWorkspaceTests|TerminalFontSettingsTests'`

Expected: 两个 suite 全部通过，0 failures。

- [ ] **Step 7: 提交外壳配置**

```bash
git add Sources/InkShell/TerminalWorkspaceViewController.swift Sources/InkShell/SettingsViewController.swift Tests/InkShellTests/TerminalWorkspaceTests.swift Tests/InkShellTests/TerminalFontSettingsTests.swift
git commit -m "feat(settings): 暴露字体 cell 与增粗设置" -m "让新增字体参数可以即时应用到所有 pane，并在关闭增粗时保留强度值。" -m "Refs #44"
```

---

### Task 5: 文档、用户配置与完整验证

**Files:**
- Modify: `docs/design-system.md`
- Modify: `docs/perf.md`
- Modify outside Git: `~/.config/ink/config.toml`

**Interfaces:**
- Consumes: 前四个任务完成的配置、度量、栅格化和设置链路。

- [ ] **Step 1: 更新设计系统说明**

把默认字体说明改为 Maple Mono NF CN 15pt，写明缺失时回退系统等宽字体、`line_height = 1.0`、`adjust_cell_height = 1`、`thicken = true` 和 `thicken_strength = 128`。保留“不打包字体”的依赖边界。

- [ ] **Step 2: 运行全量自动验证**

Run: `swift test`

Expected: 全部测试通过，0 failures。

Run: `swift build`

Expected: exit 0，没有 compiler warning。

Run: `git diff --check`

Expected: 无输出，exit 0。

- [ ] **Step 3: 更新当前用户配置**

只更新 `[font]` 中的已知键，保留文件其他内容：

```toml
[font]
family = "Maple Mono NF CN"
size = 15
line_height = 1
adjust_cell_height = 1
thicken = true
thicken_strength = 128
```

- [ ] **Step 4: 构建并启动真实 Ink**

Run: `swift run ink`

在 Claude Code 会话中确认：Maple Mono NF CN 被选中、字符 advance 为 9pt、Retina cell 高度为 41px、字体笔画启用 strength 128，彩色 emoji 仍保持彩色。保存截图作为运行时证据。

- [ ] **Step 5: 运行 Time Profiler**

Run: `xcrun xctrace record --template 'Time Profiler' --time-limit 15s --output /tmp/ink-font-metrics.trace --launch -- .build/debug/ink`

在采样窗口中保持稳定终端画面，检查每帧调用栈不包含 `CTLineDraw`、`CGContextSetShouldSmoothFonts` 或 glyph 栅格化。把采样时长、场景和结论追加到 `docs/perf.md`；如果这些符号持续出现在帧循环中，停止提交并回查 atlas 命中路径。

- [ ] **Step 6: 再次运行验证并提交文档**

Run: `swift test && swift build && git diff --check`

Expected: exit 0，测试 0 failures，构建无 warning，diff check 无输出。

```bash
git add docs/design-system.md docs/perf.md
git commit -m "docs(terminal): 记录字体度量默认值与采样" -m "固定 Ghostty 对齐参数和 atlas 首次栅格化的性能证据，便于后续回归检查。" -m "Refs #44"
```

- [ ] **Step 7: 推送并创建 PR**

```bash
git push -u origin agent/issue-44-font-metrics
gh pr create --base main --title "feat(terminal): 支持 Ghostty 风格字体度量配置" --body "增加 cell 高度与 macOS 字体增粗配置；默认字体度量对齐当前 Ghostty 参考配置；设置页支持即时调整。验证：swift test、swift build、真实界面截图、Time Profiler。风险：CoreGraphics 输出可能随 macOS 版本细微变化。文档已更新，不涉及发布。 Closes #44"
```

Expected: 分支推送成功，PR 指向 `main`，描述只包含一个 `Closes #44`。
