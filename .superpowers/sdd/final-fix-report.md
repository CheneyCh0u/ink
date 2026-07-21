# Issue #60 final review fix report

## Diff 摘要

- 将 Task 3 侧边栏菜单的计划接口、测试预期和实现片段统一为
  `MainWindowController.toggleSidebarMode(_:)`。
- 增加完整 main menu、真实 `MainWindowController` 与 submenu `update()` 的 responder-chain
  回归要求，断言三个字号项及侧边栏项的 target 均为窗口控制器，且侧边栏项 enabled。
- 补充 RED/GREEN 说明：旧通用 selector 会被 `NSWindow` 截获；专属 action 是仅转调既有无参
  三态切换逻辑的极薄适配器。

## 检查

- `git diff --check`：通过。

## Commit

- `docs(plan): 纠正侧边栏菜单响应链`
