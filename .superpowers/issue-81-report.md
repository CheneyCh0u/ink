# Issue #81 交付报告

## 工作范围

- Issue: `#81` — 支持 OSC 9 / OSC 777 主动通知
- Issue URL: <https://github.com/CheneyCh0u/ink/issues/81>
- Branch: `agent/issue-81-osc-notifications`
- Worktree: `/Users/cheney/work/code/ink/.worktrees/issue-81`
- Base commit: `b8c3355` (`feat(shell): 支持方向键聚焦相邻 pane (#75)`)
- 实施日期: 2026-07-22

本分支只实现 Issue #81：TerminalCore 有界解析 OSC 9/777，使用纯值事件上送；Shell
根据应用与来源 pane 活跃状态 gating，并复用已有系统通知授权/投递协调器和统一节流。
没有改 roadmap 范围，没有引入依赖，没有增加 cell、line、scrollback 或渲染常驻字段。

## 设计边界

- 接受 `OSC 9;<message>` 与 `OSC 777;notify;<title>;<body>`。
- BEL 与 ST 均可终止，Parser 状态支持任意 PTY chunk 分割。
- 完整 OSC 最多累积 4096 bytes；第 4097 byte 使整段失效，不能执行截断前缀。
- OSC 777 标题最多 128 UTF-8 bytes，正文最多 1024 UTF-8 bytes。
- 非法 UTF-8、C0、DEL/C1、空/纯空白正文、未知语法与超限字段均静默忽略。
- `Terminal.pendingEvents` 最多 64 个，BEL、命令完成与主动通知共用上限。
- OSC 9 与空标题 OSC 777 使用所属 tab 显示名回退。
- 只在“应用活跃且来源 pane 是当前 pane”时抑制主动系统通知；应用失焦、后台 tab 或
  同 tab 非活动 pane 都提交。
- 命令完成通知仍保持原有“应用失焦 + 至少 10 秒”的 gate 和脱敏内容。
- 命令完成与 OSC 共用 `CommandNotificationCoordinator` 的懒授权、静默失败和全局一秒
  节流窗口；节流发生在创建授权查询 Task 之前。

## 提交

按 base 到 HEAD 顺序：

1. `f5889da` `docs(notification): 定义 OSC 通知边界`
2. `b16caba` `docs(notification): 规划 OSC 通知实现`
3. `abff846` `feat(terminal): 解析 OSC 主动通知`
4. `322fb50` `fix(parser): 整段丢弃非法 OSC`
5. `cdf08e2` `perf(core): 限制瞬时事件积压`
6. `9d8fb56` `test(session): 覆盖 OSC 通知上送`
7. `51cdaed` `feat(shell): 统一通知请求与节流`
8. `3958172` `feat(shell): 按来源 pane 显示 OSC 通知`

本报告会作为第 9 个提交单独提交。所有提交正文使用 `Refs #81`，没有 `Closes`，由上层
集成分支创建唯一关闭 Issue 的 PR。

## TDD 证据

实现前实际观察到以下 RED：

- `OSCNotificationTests` 最初因 `TerminalEvent.notification` 与
  `TerminalNotification` 不存在而编译失败。
- 新事件加入后，既有 `TabAttention` 穷举 switch 因缺少 `.notification` 编译失败；补充
  映射测试后做最小 `.notification -> .bell` 接线。
- Parser malformed 测试显示旧实现会删除 NUL/TAB/LF 后继续发通知，并把 4096-byte
  截断前缀执行为 OSC 标题。
- 事件洪泛测试显示旧队列返回 80 个事件而不是 64 个。
- 通知请求测试因内容 factory 与显式 policy 不存在而编译失败。
- 节流测试因无时钟注入/节流入口而编译失败，旧协调器也会为每次提交建 Task。
- 窗口测试显示 OSC 在应用失焦、后台 tab 和同 tab 非活动 pane 下均未提交；同 tab
  非活动 pane 也未制造 attention。

每组生产改动后均运行对应聚焦测试观察 GREEN，再提交。

## 最终聚焦验证

以下命令在最终实现提交 `3958172` 后重新运行：

| 命令 | 结果 |
| --- | --- |
| `swift test --filter OSCNotificationTests` | PASS，12 tests，0 failures |
| `swift test --filter CommandStatusTests.mixedEventsStayBounded` | PASS，1 test，0 failures |
| `swift test --filter CommandStatusTests.compactRecordLayout` | PASS，1 test，0 failures |
| `swift test --filter TerminalSessionEventTests` | PASS，2 tests，0 failures |
| `swift test --filter CommandNotificationCoordinatorTests` | PASS，8 tests，0 failures |
| `swift test --filter CommandStatusWindowTests` | PASS，6 tests，0 failures |
| `swift test --filter TabAttentionTests` | PASS，4 tests，0 failures |
| `git diff --check b8c3355..HEAD` | PASS，无输出 |

布局定点测试确认：

- `MemoryLayout<Cell>.stride == 8`
- `MemoryLayout<RowInfo>.stride == 2`
- `MemoryLayout<CommandCompletionRecord>.stride == 16`

按上层任务明确要求，没有运行：

- 全量 `swift test`
- 独立完整 `swift build`
- Release benchmark
- Instruments Time Profiler

SwiftPM 的聚焦测试命令会编译其所需 package targets，但这不等于单独执行完整 build gate。

## 分层与性能审计

- `Sources/TerminalCore/CommandStatus.swift`、`Parser.swift`、`Terminal.swift` 没有新增
  AppKit、Metal、UserNotifications 或 Foundation import。
- Parser 继续使用唯一持有且跨序列复用的 `ContiguousArray<UInt8>`；OSC 分支只新增一个
  序列级 bool 和计数判断，没有 per-byte 数组/String/COW 设计。
- 普通 printable byte 的 `.ground` 分支未改。
- 新状态只存在于 Parser OSC 累积器、Terminal 已有瞬时事件队列和 Shell 已有协调器；
  cell/line/scrollback/glyph/draw call 路径没有字段变化。
- 资源硬边界为 4096-byte OSC count、128-byte title、1024-byte body、64-event queue、
  1-second Shell submission window。

## 已知 cherry-pick 冲突面

上层集成若同时接入其它 Shell/通知工作，最可能冲突的文件：

1. `Sources/InkShell/CommandNotificationCoordinator.swift`
   - `CommandNotificationRequest` 从 command 结构改为 `title/body` 内容值；现有 call-site 应
     使用 `.command(...)`，OSC 使用 `.terminal(...)`。
   - 协调器初始化器新增可选 `now` 和 `minimumInterval`，默认调用保持源码兼容。
2. `Sources/InkShell/MainWindowController.swift`
   - `handleTerminalEvent` 从 tab 可见性改为来源 `paneIsActive`，并新增 `.notification`
     switch。若其它分支也修改事件处理，应保留命令 policy 与 OSC policy 的独立 gate。
3. `Sources/InkShell/TabAttention.swift`
   - `TerminalEvent.notification` 映射到 `.bell`；任何新增 TerminalEvent case 都需合并
     穷举 switch。
4. `Tests/InkShellTests/CommandStatusWindowTests.swift`
   - fixture 增加可选 split first tab，并把通知断言迁移到 `title/body` 请求。
5. `Tests/InkShellTests/CommandNotificationCoordinatorTests.swift`
   - 内容 factory、显式 policy 与可注入时钟节流测试可能与并行通知测试冲突。
6. `Sources/TerminalCore/Terminal.swift` / `CommandStatus.swift`
   - 若并行分支新增 TerminalEvent 或改 OSC dispatch，需保持统一 `emit(_:)` 的 64-event
     上限，不能恢复直接 `pendingEvents.append`。
7. `Sources/TerminalCore/Parser.swift`
   - 若并行分支改 OSC 处理，必须保留 overflow/embedded-control 整段 discarded 语义。

`docs/superpowers/specs/2026-07-22-osc-notifications-design.md` 与
`docs/superpowers/plans/2026-07-22-osc-notifications.md` 是本实现的决策与执行依据。

## 未执行的外部动作

- 未 push
- 未创建 PR
- 未 merge
- 未创建 release tag
- 未发布
