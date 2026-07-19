# ink 设计系统

## 视觉方向

选定方案为 **A「雾白」**：Codex 式的克制信息架构，配合更明显的 macOS
半透明侧边栏。终端内容区保持安静、清晰，侧边栏承担材质和品牌识别。

浅色模式使用暖雾玻璃与接近白纸的终端；深色模式使用暖石墨玻璃与低眩光
墨黑终端。深色不是浅色反相，而是重新分配表面亮度层级。

## 权威实现

原生应用的全局 token 定义在 `Sources/InkDesign/`（独立 SwiftPM 模块，
外壳与渲染层都依赖它，`TerminalCore` 不依赖）：

- `InkDesignTokens.swift` — 外壳语义色、间距、圆角、字体、动效
- `InkTerminalPalette.swift` — 终端 ANSI 16 色与前景 / 背景 / 光标 / 选区

业务组件只能使用语义 token，不得直接写 RGB、圆角或间距数值。

颜色由动态 `NSColor` 提供，会随 macOS 的 effective appearance 实时解析。
SwiftUI 使用时通过 `Color(nsColor:)` 桥接，不建立第二套颜色表。

侧边栏使用：

- `NSVisualEffectView.Material.sidebar`
- `NSVisualEffectView.BlendingMode.behindWindow`
- `NSVisualEffectView.State.active`

不要用手工透明色或模糊截图模拟系统材质。`sidebarFallback` 只用于材质不可用、
Reduce Transparency 开启或测试快照。

## 色彩角色

| Token | 浅色 | 深色 | 用途 |
|---|---:|---:|---|
| `canvas` | `#F9F9F7` | `#171819` | 窗口底层 |
| `terminal` | `#FDFDFD` | `#111314` | 终端内容区 |
| `sidebarFallback` | `#EFEAE2` / 78% | `#262421` / 86% | 侧栏材质降级色 |
| `elevated` | 白 / 88% | 白 / 5% | 浮层与提升态 |
| `selected` | 白 / 72% | 白 / 8.5% | 侧边栏选中行（白色高光浮在材质上；暖褐色在真机叠壁纸透光会发闷，弃用） |
| `pill` | 黑 / 5.5% | 白 / 7.5% | 标签 pill 活动态 |
| `textPrimary` | `#303238` | `#E2E3DF` | 主文字 |
| `textSecondary` | `#777A80` | `#92969C` | 次级文字 |
| `separator` | `#70737A` / 22% | 白 / 8% | 发丝分隔线 |
| `accent` | `#168FAF` | `#58B6C9` | 品牌、焦点、光标 |
| `success` | `#228F5B` | `#67C88D` | 成功状态 |
| `warning` | `#B67F2B` | `#D9B25E` | 警告状态 |
| `branch` | `#9B67C8` | `#C29ADA` | Git 分支语义 |
| `danger` | `#D84A4A` | `#F06B68` | 错误与危险操作 |

## 终端 ANSI 调色板

两套快照，不互为反相：浅色套在 `#FDFDFD` 上整体压暗保对比（黄色压得最狠），
深色套在 `#111314` 上提亮防发虚。green / cyan / magenta 与外壳的
success / accent / branch 落在同一色相族，终端输出和外壳 UI 观感一致。

| ANSI | 浅色 | 深色 |
|---|---:|---:|
| 0 black | `#3A3C42` | `#4A4D55` |
| 1 red | `#C13B30` | `#EF7A6D` |
| 2 green | `#2E8548` | `#67C88D` |
| 3 yellow | `#9C7211` | `#D9B25E` |
| 4 blue | `#3465A8` | `#79A9E8` |
| 5 magenta | `#8A4BB4` | `#C29ADA` |
| 6 cyan | `#0E7F96` | `#58B6C9` |
| 7 white | `#C6C7CB` | `#C8CACF` |
| 8–15 高亮 | 同色相提亮一档 | 同色相提亮一档 |
| 前景 | `#303238` | `#E2E3DF` |
| 背景 | `#FDFDFD` | `#111314` |
| 光标 | `#168FAF` | `#58B6C9` |
| 选区 | `#C3E0E8` | `#2A4A54` |

完整 16 色以 `InkTerminalPalette.swift` 为准，本表是速览。

**热路径纪律**：渲染器只消费 `InkTerminalPalette` 的值快照（打包 sRGB），
外观切换时整体换快照重传 uniform。帧循环内禁止出现 `NSColor` 动态解色。
256 色索引表的 16–255 段（6×6×6 色立方 + 灰阶）按 xterm 标准公式在渲染器内
生成，不属于主题；真彩色 SGR 直接透传。

## 尺度

- 间距：`4 / 8 / 12 / 16 / 24 / 32`
- 圆角：控件 `6`、列表项 `10`、面板 `14`、窗口 `22`
- 侧边栏宽度：`258`
- 点击反馈：`140ms`
- 状态变化：`180ms`

外壳字体使用系统字体，终端使用系统等宽字体。这样既保持 macOS 原生感，也避免
额外字体常驻内存和应用体积。

## 使用约束

- 不在 `TerminalCore` 引入本文件或 AppKit。
- 侧边栏负责材质，终端内容区使用不透明背景，保证字符对比度和渲染稳定。
- 深色正文不使用纯白，避免长时间使用产生眩光。
- 只在交互元素使用强调色，强调色不铺满大面积背景。
- 外观切换不重建业务状态；视图从动态颜色重新解析即可。
- 遵守 Reduce Motion 与 Reduce Transparency 系统辅助功能设置。
