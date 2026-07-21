# Ghostty 风格字体度量配置设计

Issue：[#44](https://github.com/CheneyCh0u/ink/issues/44)

## 背景

Ink 当前提供 `family`、`size` 和 `line_height` 三项字体配置。默认值是系统等宽字体 14pt 和 1.2 倍行高，无法表达 Ghostty 的 cell 高度微调与 macOS 字体增粗，因此相同终端程序在两边呈现出不同的字面大小、笔画粗细和行距。

本次参考的 Ghostty 配置如下：

```toml
font-family = Maple Mono NF CN
font-size = 15
font-thicken = true
font-thicken-strength = 128
adjust-cell-height = 1
```

Ink 不读取 Ghostty 配置，也不打包 Maple Mono。两边只共享参数语义与默认值。

## 目标

- Ink 的独立配置可以表达参考配置中的字体家族、字号、字体增粗和 cell 高度微调。
- 新安装或恢复默认设置后使用 Maple Mono NF CN 15pt、原生行高、cell 高度增加 1 个物理像素、字体增粗强度 128。
- Maple Mono 不存在或配置的字体无效时，继续回退系统等宽字体。
- 保留 `line_height`，现有配置文件不需要迁移即可读取和保存。
- 新增设置可以即时应用，不在逐帧渲染路径增加工作。

配色、字体打包、连字选项、字宽微调与自动读取 Ghostty 配置不在本次范围内。

## 配置

字体节扩展为：

```toml
[font]
family = "Maple Mono NF CN"
size = 15
line_height = 1.0
adjust_cell_height = 1
thicken = true
thicken_strength = 128
```

各字段语义如下：

- `line_height` 是字体原生行高的倍数，保留现有 `0.8...2.0` 范围。
- `adjust_cell_height` 在行高倍数计算后增加或减少物理像素，取值范围为 `-10...20`，默认值为 `1`。它不随 Retina backing scale 再次放大。
- `thicken` 控制 CoreGraphics 字体平滑。
- `thicken_strength` 取值范围为 `0...255`，默认值为 `128`。关闭 `thicken` 后仍保留该值，重新开启时继续使用。

非法值沿用 InkConfig 的容错规则，忽略该项并保留默认值。保存设置时使用现有 MiniTOML 更新逻辑，保留注释和未知字段。

现有配置文件可以继续读取。旧文件没有新增字段时，新增字段使用新默认值；文件中已经写明的 `family`、`size` 和 `line_height` 不会被覆盖。当前开发机器的配置文件会在实现完成后显式更新为上述六项，确保本次对比直接使用目标参数。

## 字体度量

GlyphAtlas 继续以物理像素保存 cell 尺寸。高度计算调整为：

```text
naturalHeightPx = ceil(defaultLineHeightPt * backingScale)
scaledHeightPx = ceil(naturalHeightPx * lineHeight)
cellHeightPx = max(1, scaledHeightPx + adjustCellHeightPx)
```

Maple Mono NF CN 15pt 的原生行高在当前 Retina 显示器上是 40px。`line_height = 1.0`、`adjust_cell_height = 1` 得到 41px，与 Ghostty 的调整语义一致。额外空间仍在字形上下均分，baseline 随之保持垂直居中。

字符横向间距继续取字体 `0` 字形的 advance，并按 backing scale 向上对齐到整像素。Maple Mono NF CN 15pt 在当前系统上的 advance 是 9pt，不新增独立 letter spacing 配置。

`minimumViewportSize` 与 GlyphAtlas 必须调用同一份度量函数，避免布局预估与实际 renderer 产生一像素差异。度量函数放在 InkTerminalView 内，不进入 TerminalCore。

## 字体增粗

单色字形继续在进入 atlas 时栅格化一次。位图上下文改用 8 位 alpha-only 格式，并设置以下 CoreGraphics 状态：

- 允许字体平滑，`thicken` 决定本次绘制是否启用。
- 允许亚像素定位，禁止亚像素量化，保持现有 cell 对齐。
- 保持抗锯齿开启。
- 单色字形的灰度填充与描边使用 `thicken_strength / 255`，与 Ghostty 的 CoreText 路径一致。

彩色 emoji 仍使用 BGRA atlas，不应用字体增粗。粗体与斜体继续选择真实字体字重，不用 `thicken` 代替 SGR bold。

字体配置变化会重建 renderer 与 atlas。增粗不进入 instance 构建、draw call 或 fragment shader 热路径，因此不会增加逐帧 CPU/GPU 工作。

## 数据流与界面

InkConfig 增加 `fontCellHeightAdjustment`、`fontThicken` 和 `fontThickenStrength`。TerminalWorkspaceViewController 把它们传给 TerminalMetalView，TerminalMetalView 重建 TerminalRenderer，最终由 GlyphAtlas 完成度量与栅格化。

设置页的字体区域增加：

- “Cell 高度”数值控件，单位显示为 px。
- “字体增粗”开关。
- “增粗强度”数值控件，关闭字体增粗时禁用。

字体预览继续显示字体家族、字号和行高。CoreGraphics 增粗的精确结果以实时终端为准，设置变化会立即重建当前 pane 的 atlas，因此不增加第二套预览栅格化实现。

## 兼容与错误处理

- 字体不存在时静默回退系统等宽字体，与当前行为一致。
- `adjust_cell_height` 即使为负数也不能让 cell 低于 1px。
- `thicken_strength` 越界时保留默认值，不做静默截断。
- 配置变化只影响视图与 renderer，不修改 TerminalCore、PTY 或 grid 数据。
- 设置保存失败沿用现有错误提示路径，本次不新增文件写入机制。

## 验证

自动验证包括：

- InkConfig 默认值、合法加载、非法值回退和保存往返测试。
- 字体度量测试，确认 cell 高度微调按物理像素计算，预估尺寸与 renderer 度量一致。
- GlyphAtlas 测试，确认单色 atlas 使用字体增粗参数，彩色路径不受影响。
- 设置到 TerminalMetalView 的映射测试。
- 完整运行 `swift test` 与 `swift build`。

运行时验证使用同一个 Claude Code 界面，在 Ink 与 Ghostty 中确认 Maple Mono NF CN 15pt 下的字符宽度、41px cell 高度和笔画粗细。若无法自动生成稳定的跨应用像素差异断言，保留配置与度量的回归测试，并用截图检查栅格化结果。

本次修改涉及 glyph atlas 首次填充路径。完成后用 Time Profiler 检查稳定输出阶段，确认增粗没有进入每帧调用栈；记录采样结果作为 PR 验证证据。
