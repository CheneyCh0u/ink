# PTY 宿主颜色环境隔离设计

Issue：#46

## 问题

Ink 从 `ProcessInfo.processInfo.environment` 构造 PTY 子进程环境，并通过
`login -p` 原样保留。若 Ink 由带有 `NO_COLOR=1` 的自动化宿主启动，
Claude Code 等终端程序会主动关闭 ANSI 配色。Ink 虽覆盖了 `TERM` 与
`COLORTERM`，但没有清理这个与终端能力声明冲突的宿主变量。

## 设计

在 `InkPTY` 内提取一个纯函数构造终端环境：

- 复制宿主环境，保留普通变量；
- 删除宿主的 `NO_COLOR`；
- 设置 `TERM=xterm-256color`、`COLORTERM=truecolor` 与
  `TERM_PROGRAM=ink`；
- 仅在缺少 `LANG` 时补上 `zh_CN.UTF-8`。

只清理 `NO_COLOR`，不扩展到 `FORCE_COLOR`、`CLICOLOR` 等变量。
用户仍可在自己的 shell 启动脚本中主动设置 `NO_COLOR`。

## 验证

单元测试直接输入包含 `NO_COLOR=1` 和自定义变量的宿主环境，验证输出移除
`NO_COLOR`、覆盖终端能力变量、保留自定义变量和既有 `LANG`。随后运行
全量测试与构建，并用安装包启动 Claude Code 做实机颜色检查。

## 范围

不修改调色板、VT/SGR 解析、Metal 渲染或 Claude Code 配置，不新增依赖。
