# ink

macOS 原生终端模拟器。核心目标是**性能强、内存占用小**——这两条是项目存在的理由，任何与之冲突的改动都需要先讨论。

动手前先读：

- [docs/tech-stack.md](docs/tech-stack.md) — 技术选型与架构，含放弃方案的理由
- [docs/roadmap.md](docs/roadmap.md) — 功能范围的权威来源，P0/P1/明确不做

## 进度与范围

`docs/roadmap.md` 定义**做什么、为什么**，todolist 记录**做到哪了**。二者配套：

- 开始一项工作前先 `TaskList` 确认状态，动手时置 `in_progress`，完成置 `completed`
- 实现中发现的新工作直接建任务，不要攒着
- **范围有变动时先改 roadmap，再调 todolist**。roadmap 里列在「明确不做」的功能，要加回来需要先讨论——那张表是防范围蔓延用的，不是备选清单

## 技术栈速览

Swift 6 / AppKit + SwiftUI 外壳 / Metal 自绘终端内容区 / CoreText 字体 / SwiftPM 构建。最低系统 macOS 14.0。

## 分层与边界

```
Shell UI (SwiftUI + AppKit)   侧边栏、标签栏、工具栏
TerminalView (NSView + Metal) 渲染、输入法、选中
TerminalCore (纯 Swift)       VT 解析、grid、scrollback
PTY (forkpty + Dispatch)
```

**`TerminalCore` 不得引入 AppKit 或 Metal 依赖。** 这一层要能脱离窗口做单元测试，VT 解析的正确性全部在这里验证。如果某个功能看起来需要在 Core 里访问 UI，那是分层错了。

外壳 UI 优先用系统默认控件和样式，不自造轮子。自绘只用在系统确实没有对应物的地方。

## 热路径纪律

渲染循环和 grid 操作是性能敏感区。在这些路径上：

- cell 用 `struct`，连续内存存储；禁止 `Array<Array<T>>`
- 禁止 `class`、`String`（用 `UInt32` scalar）、隐式装箱
- 每帧一次 draw call（glyph atlas + 实例化），不要每字符一次
- 改动后必须用 Instruments Time Profiler 验证，不接受"看起来没变慢"

Swift 的 ARC 不会替我们把关这些，靠人盯。

## 内存纪律

scrollback 是内存大头，优先级高于渲染优化。单 cell 压到 8 字节以内，行内不补齐尾部空白，历史行压缩存储。任何会增加 per-cell 或 per-line 常驻开销的改动，都要先算一遍 10 万行下的总量。

## 约定

- 注释和文档用中文，代码标识符用英文
- 提交信息用中文，说清楚"为什么"而不只是"改了什么"
- 新增依赖需要理由——每个第三方库都是内存和二进制体积的潜在成本

## 文档同步

`AGENTS.md` 是指向本文件的软链接，供其他 agent 工具识别。改本文件即可，两边自动一致。**不要**把软链接替换成实体文件副本。
