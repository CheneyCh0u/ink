# Issue #80 命令块轻量悬停入口实现报告

日期：2026-07-22

分支：`agent/issue-80-command-hover`

工作树：`/Users/cheney/work/code/ink/.worktrees/issue-80`

## 完成范围

- 只在鼠标进入完整 OSC 133 命令块的命令首行时显示一个瞬态系统按钮；没有完整命令记录、坐标无效、离开首行、滚动、选择、键盘输入、终端更新或重置瞬态状态时隐藏。
- 链接命中优先于命令入口；TUI 已接管鼠标时保持原上报行为，只有按住 Option 才允许原生命令入口。
- 菜单提供“上一条命令”“下一条命令”“拷贝命令”“拷贝命令输出”，启用状态由悬停命令及其相邻命令决定。
- 菜单捕获不可变的命令身份，并在动作执行时按当前终端状态重验；reflow 或历史淘汰后旧载荷安全失效，不会误操作占用旧绝对坐标的新命令。
- 命令解析只发生在真实 `mouseMoved` 冷路径与菜单动作中。终端更新和帧刷新只使入口失效，不重新扫描命令块。

## 分层与性能边界

- `TerminalCore` 没有新增 AppKit 或 Metal 依赖，也没有命令悬停相关代码。
- 没有增加 per-cell 或 per-line 常驻字段；`Cell`、行存储与 scrollback 表示均未改变。
- 每个可见 `TerminalMetalView` 复用一个 `NSButton`，没有常驻命令工具栏，也没有每帧创建控件或菜单。
- `git diff origin/main...HEAD --check` 通过。
- `rg -n "import AppKit|import Metal" Sources/TerminalCore` 无匹配。
- `rg -n "CommandHover|commandHover" Sources/TerminalCore Sources/InkTerminalView` 的匹配均位于 `InkTerminalView`。

## 提交序列

1. `1fdd194` `docs(command): 明确命令悬停入口边界`
2. `a10b619` `docs(command): 拆解命令悬停入口实现`
3. `c6d98f3` `feat(command): 稳定悬停命令目标`
4. `32aa796` `feat(command): 按需显示命令悬停入口`
5. `9ceb1be` `feat(command): 路由悬停命令菜单动作`

以上提交均包含 `Refs #80`。

## Focused tests

2026-07-22 16:59（Asia/Singapore）在本工作树执行：

| 命令 | 结果 |
| --- | --- |
| `swift test --filter TerminalCommandHoverResolverTests` | 5 项通过 |
| `swift test --filter TerminalCommandHoverTests` | 10 项通过 |
| `swift test --filter TerminalCommandActionTests` | 5 项通过 |
| `swift test --filter TerminalLinkInteractionTests` | 8 项通过 |
| `swift test --filter CommandBlockTests` | 14 项通过 |

合计 42 项通过，0 失败。

测试覆盖稳定目标、历史淘汰、reflow、相邻命令解析、入口显隐、链接优先级、TUI 鼠标 Option 覆盖、终端更新后的帧刷新、菜单启用状态、精确拷贝和相对导航。

## 按任务边界未执行

- 未运行全量 `swift test`。
- 未单独运行全量 `swift build`。
- 未运行 Instruments Time Profiler。
- 未执行全项目代码评审或发布门禁。
- 未推送、未创建 PR、未合并、未发布。

## 并发集成提示

`Sources/InkTerminalView/TerminalMetalView.swift` 是主要潜在冲突点，特别是与原生上下文菜单、鼠标事件或链接交互的并发改动。整合时需要同时保留：

- 链接悬停和 Command 点击的优先级；
- 普通 TUI 鼠标上报与 Option 原生覆盖；
- 现有 `contextMenuPresenter` 与新增 `commandMenuPresenter` 的独立测试注入边界；
- `markDirty()` 立即隐藏命令入口，以及帧刷新不触发命令扫描的约束；
- 命令菜单动作执行时对稳定目标的重新验证。

`Sources/InkTerminalView/TerminalCommandHover.swift` 为新增隔离文件，预计冲突较低。若统一菜单模型，不能把悬停目标降级为易受 reflow 或 ring eviction 影响的裸绝对行坐标。

## 分支状态

按任务要求采用收尾流程的“保留分支”选项：工作树和分支保留，等待上层统一审查与集成。
