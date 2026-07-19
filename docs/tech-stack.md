# 技术栈决策

## 定位

macOS 原生终端模拟器。两个硬指标：

1. **性能** — 全屏重绘稳定 120fps，大量输出（`yes`、`cat` 大文件）不掉帧
2. **内存** — 空闲单窗口 < 50MB，10 万行 scrollback 下 < 200MB

这两条决定了所有下游选择。凡是与之冲突的方案一律排除。

## 最终选型

| 层 | 选型 |
|---|---|
| 语言 | Swift 6（strict concurrency） |
| 最低系统 | macOS 14.0 (Sonoma) |
| 窗口 / 外壳 UI | AppKit + SwiftUI 混合 |
| 终端内容渲染 | 自定义 `NSView` + `CAMetalLayer` + Metal |
| 字体栅格化 | CoreText |
| 文字整形 | CoreText（复杂文种、连字） |
| PTY | `forkpty(3)` + `Dispatch` I/O |
| VT 解析 | 自研状态机（参考 `vte` / SwiftTerm 的实现） |
| 构建 | Swift Package Manager |
| 测试 | swift-testing |

## 为什么是 Swift

**输入法是决定性因素。** 终端必须正确处理中文输入：候选窗定位、预编辑文本的下划线与光标同步、输入过程中的重绘。`NSTextInputClient` 是 macOS 上唯一的一等公民路径。跨平台窗口库（winit 等）在这里长期是二等支持，Alacritty 的中文输入体验至今被诟病。

**系统集成免费。** 原生窗口标签、菜单栏、Services、拖放、全屏行为、暗色模式跟随——AppKit 里都是既有能力。

**Metal 与 CoreText 是母语调用。** 无需穿 FFI，无需为封装不全的 binding 写 bridge。

### 放弃的方案

**Rust + winit + wgpu** — 性能上限相当，但输入法和系统集成要自己补，且补的过程实际是在写 Objective-C bridge。只做 macOS 时这些成本没有对应收益。若将来需要 Linux 版本，此决策需重新评估。

**Zig（Ghostty 路线）** — 二进制更小、启动更快，但字体、解析、窗口层全部自建。收益不足以抵消工期。

**Electron / Tauri** — 与内存指标直接冲突。单个 WebView 窗口常驻数百 MB，正好卡在本项目最在意的地方。视觉效果可以逼近，代价大一个数量级。

## Swift 的代价与应对

Swift 的 ARC 会在热路径引入 retain/release 原子操作。终端最热的循环是逐 cell 生成顶点数据，几千 cell × 120fps 下这是可观的开销。

**约束（强制）：**

- Grid cell 必须是 `struct`，存储在连续内存中（`UnsafeMutableBufferPointer` 或 `ContiguousArray`）
- 渲染热路径禁止出现 `class`、`Array<Array<T>>`、`String`（用 `UInt32` scalar）
- 热路径函数标 `@inline(__always)`，跨模块调用注意 `@usableFromInline`
- 任何热路径改动必须用 Instruments 的 Time Profiler 验证，不接受"看起来没变慢"

编译器不会替我们保证这些，靠代码审查和 profiling 盯住。

## 关键性能设计

### 渲染：glyph atlas + 实例化绘制

栅格化后的字形缓存进一张纹理图集。每帧只提交一个 instance buffer（每 cell 一条记录：网格坐标、图集 UV、前景色、背景色、属性位），单次 draw call 画完整屏。

这是 Alacritty / Ghostty 的共同做法，也是帧率能压住的前提。**不要**每个字符一次 draw call。

彩色 emoji 走 CoreText 的 `CTFontDrawGlyphs` 彩色字形路径，单独一张 atlas（RGBA，与主 atlas 的单通道分开）。

### 内存：scrollback 是主战场

朴素实现下 10 万行 × 200 列，每 cell 16 字节 = 320MB。这一项单独就会打穿内存指标。

**要求：**

- 单 cell 压缩到 8 字节以内：scalar 用 `UInt32`，前景/背景色与属性打包进剩余 4 字节（调色板索引 + 属性位；真彩色走旁路表）
- 行内按实际宽度存储，不按终端列宽补齐尾部空白
- 历史行（已滚出屏幕）做压缩存储；纯 ASCII 行是绝大多数，值得单独的紧凑表示
- scrollback 上限可配置，默认值需实测内存后确定

渲染层的优化影响帧率，这一层的设计直接决定内存指标能否达成。**优先级更高。**

## 架构分层

```
┌─────────────────────────────────────────┐
│  Shell UI (SwiftUI + AppKit)            │
│  侧边栏 / 标签栏 / 工具栏 / 设置         │
└─────────────────────────────────────────┘
┌─────────────────────────────────────────┐
│  TerminalView (NSView + CAMetalLayer)   │
│  渲染器 / glyph atlas / 输入法 / 选中     │
└─────────────────────────────────────────┘
┌─────────────────────────────────────────┐
│  TerminalCore (纯 Swift，无 UI 依赖)     │
│  VT 解析 / grid / scrollback / 光标      │
└─────────────────────────────────────────┘
┌─────────────────────────────────────────┐
│  PTY (forkpty + Dispatch I/O)           │
└─────────────────────────────────────────┘
```

`TerminalCore` 不依赖 AppKit 或 Metal，可独立单元测试。VT 解析的正确性全部通过这一层验证，不需要起窗口。

外壳 UI 与终端内容区的边界要清晰：外壳白嫖系统控件，内容区完全自绘。两者只通过明确的接口通信。

## 目标视觉

参考现代 macOS 应用的观感：无标题栏、大圆角、左侧项目/会话列表、顶部标签页、内容区占据主体。

外壳部分优先使用系统默认样式（`NavigationSplitView`、`List` 的 sidebar 样式、SF Symbols），不自造轮子。自定义只用在系统确实没有对应物的地方（如标签页的 pill 样式）。

## 里程碑

1. **M1 — 能跑** PTY 打通，`NSTextView` 占位显示输出，验证 shell 交互正常
2. **M2 — 自绘** Metal 渲染管线 + glyph atlas 替换占位视图
3. **M3 — 正确** VT 兼容性（`vttest` 通过核心项），scrollback，选中复制
4. **M4 — 输入法** `NSTextInputClient` 完整实现，中文输入可用
5. **M5 — 外壳** 侧边栏、标签页、分屏
6. **M6 — 达标** 内存与帧率实测，压缩存储落地

M1 先用占位视图而非直接上 Metal，是为了早期就能看到真实交互，避免长时间陷在渲染管线里没有可运行的东西。
