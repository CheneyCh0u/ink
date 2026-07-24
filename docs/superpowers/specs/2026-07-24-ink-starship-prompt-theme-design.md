# Ink Starship 提示符主题设计

Issue：#94

## 背景

Ink 当前按正常登录 shell 流程读取用户启动脚本。用户在
`~/.zshrc` 启用 Starship 后，Starship 按 `~/.config/starship.toml`
生成提示符。该配置使用硬编码真彩色时，提示符不会跟随 Ink
的终端主题；直接改用户配置又会同时改变 Ghostty 等其它终端。

Ink 已为每个新 PTY 设置 `TERM_PROGRAM=ink`，并在渲染器内将 ANSI
0–15 色槽映射到当前终端主题。新功能应复用这两个边界，不修改
Metal 真彩色解析或用户的 shell 启动脚本。

## 目标

- 设置页可在“Ink 主题”与“用户配置”之间切换，默认使用 Ink 主题。
- Ink 主题保留系统、路径、Git、语言环境、时间与命令耗时分段。
- Ink 主题只使用 ANSI 0–15 语义色，由 Ink 现有调色板决定实际 RGB。
- 切换只影响之后新建的标签和分屏，不重启现有 shell。
- Ink 的环境覆盖不泄漏到宿主进程、Ghostty 或其它终端。

## 非目标

- 不安装、更新或自动启用 Starship。
- 不改写 `~/.zshrc`、`~/.zprofile` 或 `~/.config/starship.toml`。
- 不在 Ink 内重新实现 Git 状态、语言版本检测或 shell prompt hook。
- 不在渲染器中识别并偷换特定真彩色。
- 不让正在运行的 shell 热切换 Starship 配置。

## 用户体验

设置页“终端”区在“配色”之后增加“提示符主题”单选分段：

- **Ink 主题**：默认项，新会话使用 Ink 管理的 Starship 配置。
- **用户配置**：新会话不增加 Starship 环境覆盖，沿用 shell 当前的
  Starship 配置解析规则。

说明文案为“需要 shell 已启用 Starship；更改仅影响新建会话。”
未安装或未在 shell 中启用 Starship 时，`STARSHIP_CONFIG` 不会被其它
程序解释，因此 shell 保持原有提示符。Ink 不显示“Starship 未安装”
警告，避免把可选外部工具变成启动依赖。

## 配置契约

`InkConfig` 增加：

- `PromptThemeSource: String, CaseIterable, Sendable`，值为 `ink` 与 `user`。
- `promptThemeSource: PromptThemeSource = .ink`。
- TOML 键 `terminal.prompt_theme = "ink"`。

缺少或不认识的 TOML 值回退 `.ink`。设置写回继续使用现有
`MiniTOML.updating`，保留未知字段与注释。

iCloud `WireConfig` 增加可选 `promptThemeSource: String?`。新快照写入实际值；
旧 schema 1 快照缺少该字段时迁移为 `.ink`，不提升 schema 版本。存在但
值非法时拒绝整份快照，不部分应用。

## Ink Starship 配置

Ink 管理 `~/.config/ink/starship.toml`。模板作为 `InkShell` 中的确定性
字符串生成，避免 SwiftPM 运行资源与正式 `.app` 手工打包产生两套
复制规则。文件头明确标注“由 Ink 管理，会被覆盖”。Ink 在需要创建
Ink 模式新会话时确保文件存在；只在内容变化时原子写回，不为每个
pane 制造重复磁盘写入。

提示符结构为：

1. 操作系统图标。
2. 当前目录。
3. Git 分支与状态。
4. Node.js、Python、Rust、Go、Java、Conda 与 Docker 上下文（存在时）。
5. 当前时间。
6. 超过 Starship 默认显示阈值的命令耗时。
7. 独立的成功或失败输入符号。

所有 `style` 只可使用 Starship 命名 ANSI 色：`black`、`red`、
`green`、`yellow`、`blue`、`purple`、`cyan`、`white` 及对应
`bright-*`。禁止 `#RRGGBB`、`rgb(...)` 或 16–255 数字索引，确保最终
RGB 由 `InkTerminalPalette` 的 0–15 色槽决定。

## 数据流与分层

```text

设置 UI ──> InkConfig.promptThemeSource ──> MainWindowController.startPane
                                                   │
                          ink ──> 安装模板 ──> STARSHIP_CONFIG 覆盖
                                                   │
                         user ──> 空覆盖 ──> 用户 shell 环境
                                                   │
                                                   v
                                      TerminalSession ──> InkPTY
```

- `InkConfig` 只保存可同步的选择，不依赖 AppKit 或 PTY。
- `InkShell` 负责模板内容、文件安装和将配置转成新会话环境覆盖。
- `TerminalSession` 持有创建时的不可变环境覆盖，因此设置热重载不会改变
  既有会话。
- `InkPTY` 只接受通用 `[String: String]` 覆盖并在 `forkpty` 前合并，
  不出现 Starship 类型或路径。
- `TerminalCore`、`InkTerminalView` 和 Metal 渲染路径不变。

## 错误处理

- Ink 模式写入 `~/.config/ink/starship.toml` 失败时，当次新会话不覆盖
  `STARSHIP_CONFIG`，仍按用户 shell 环境启动。
- 每个窗口生命周期最多显示一次原生警告，避免新建分屏时重复弹窗。
- 用户模式不删除宿主进程本已存在的 `STARSHIP_CONFIG`；“用户配置”的
  语义是 Ink 不施加额外覆盖，与当前 PTY 环境传递行为一致。

## 性能与内存

新增工作只发生在新会话冷路径：一次小文件比较、必要时一次原子写入、
以及向子进程环境增加一个键值。不改变 cell 布局、scrollback 常驻内存、
VT 解析或每帧渲染路径，因此不需要 Instruments 热路径验收。

## 验证

### 自动化

- `InkConfigTests`：默认 `.ink`，TOML 的 `ink` / `user` 往返，未知值回退。
- `ConfigSyncSnapshotTests`：新值完整往返，旧 schema 1 缺字段迁移为
  `.ink`，非法值拒绝。
- `InkShellTests`：设置默认选中 Ink，用户选择即时写回，外部热重载同步 UI。
- `InkShellTests`：模板为确定性内容，包含约定分段，不包含真彩色字面量，
  相同内容不重写。
- `InkPTYTests`：环境覆盖只改变指定键，保留 `TERM`、`COLORTERM`、
  `TERM_PROGRAM`、`LANG` 和无关宿主变量的现有契约。
- `InkShellTests`：Ink 模式向新 `TerminalSession` 传入配置路径，用户模式传入空覆盖。
- 全量 `swift test` 通过，`swift build` 零警告。

### 手工验收

1. 默认启动 Ink，新会话显示 Ink 分段提示符。
2. 依次切换 Ink 的五套终端主题和浅色 / 深色外观，在下一次 prompt
   重绘时确认分段颜色跟随 ANSI 调色板。
3. 切换“用户配置”，确认当前会话不变，新标签恢复
   `~/.config/starship.toml` 的现有外观。
4. 再切回“Ink 主题”并新建分屏，确认分屏使用 Ink 模板。
5. 打开 Ghostty 新会话，确认仍使用原有 `~/.config/starship.toml`。
6. 在未启用 Starship 的测试 shell 中启动 Ink，确认不出现 Ink 自造提示符或
   启动失败。

## 回滚

功能没有数据迁移。回滚代码后，旧版 Ink 会忽略 TOML 的未知
`terminal.prompt_theme` 键；`~/.config/ink/starship.toml` 是无副作用的孤立文件，
可保留或由用户删除。Ghostty 配置始终未被修改。
