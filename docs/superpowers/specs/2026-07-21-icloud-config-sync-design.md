# iCloud 配置同步设计

Issue：[#50](https://github.com/CheneyCh0u/ink/issues/50)

## 背景

Ink 当前以 `~/.config/ink/config.toml` 作为本机配置文件。设置页修改会立即写回该文件，
外部编辑则由 `ConfigWatcher` 热重载。多台 Mac 之间没有配置同步，用户需要重复设置或
手动复制文件。

Ink 只面向 macOS，可以使用 iCloud 同步少量配置数据。本功能必须保留 TOML 作为本机
权威文件，不能让云端变化在用户操作终端时突然覆盖当前设置，也不能引入轮询或进入
渲染、grid 等热路径。

## 目标与范围

- 将 `InkConfig` 当前认识的全部设置编码为版本化 JSON 快照，并保存到 iCloud。
- 提供本机“自动上传配置”开关。打开时立即上传当前配置，之后仅在本机配置保存成功后
  由事件触发上传。
- 提供“上传到云端”和“拉取云端配置”两个手动操作。
- 拉取配置时更新所有已知设置，同时保留本机 TOML 的注释和未知字段。
- 在设置页展示同步时间、来源、进行中状态与可恢复错误。
- iCloud 不可用或云端数据无法读取时，Ink 与本地配置仍可正常工作。

本次不自动拉取、不监听云端变化后应用设置、不运行定时器或轮询，也不同步 TOML 原文、
注释和未知字段。项目、标签、会话、窗口当前位置与其它运行时状态不属于 `InkConfig`，
因此不在本次同步范围内。

## 方案选择

采用 `NSUbiquitousKeyValueStore` 保存单个 JSON 字符串。配置体积远低于 KVS 限额，单值
快照能保持整份配置的原子语义，也不需要管理 iCloud Documents 的下载占位、文件协调
和可见文件。CloudKit 私有数据库对几十项偏好设置过度复杂，不采用。

KVS 仍由 macOS 在系统层完成传输，Ink 本身不轮询。Ink 不注册“远端变化后自动应用”
行为；只有用户点击“拉取云端配置”时，云端快照才可能写入本机 TOML。

## 模块边界

### 配置快照

`InkConfig` 模块新增可 `Codable` 的同步 DTO。它只负责稳定的 JSON 编解码、schema 校验
和 `InkConfig` 映射，不依赖 AppKit 或 iCloud API。

快照外层包含：

```json
{
  "schemaVersion": 1,
  "modifiedAt": "2026-07-21T14:32:10.123Z",
  "deviceID": "本机稳定随机标识",
  "config": {
    "appearanceMode": "system",
    "startupSidebarMode": "expanded",
    "rememberWindowFrame": true,
    "windowWidth": 1280,
    "windowHeight": 800,
    "fontFamily": "Maple Mono NF CN",
    "fontSize": 15,
    "lineHeight": 1,
    "fontCellHeightAdjustment": 1,
    "fontThicken": true,
    "fontThickenStrength": 128,
    "terminalTheme": "neutral",
    "cursorStyle": "block",
    "cursorBlink": true,
    "optionAsMeta": true,
    "copyOnSelect": false,
    "scrollbackLines": 100000
  }
}
```

JSON 使用固定键名和 ISO 8601 UTC 时间。`schemaVersion` 从 1 开始；旧 schema 由明确迁移
代码读取，遇到当前版本无法理解的更高 schema 时拒绝应用，并提示更新 Ink。无效枚举、
越界数值、缺失必需字段或损坏 JSON 均视为云端快照不可用，不能部分覆盖本机设置。

`deviceID` 首次使用时随机生成并保存在本机 `UserDefaults`，不写入同步配置。它只用于在
确认界面区分“此 Mac”与其它设备，不参与自动冲突合并。

### 同步服务

`InkShell` 新增 `ConfigSyncService`，通过一个小型存储协议封装
`NSUbiquitousKeyValueStore`。服务负责：

- 读取本机自动上传偏好和设备标识；
- 将配置快照编码后写入固定 KVS key；
- 读取并校验当前可取得的云端快照；
- 输出空闲、上传中、拉取中、成功、不可用和失败状态；
- 向窗口控制器返回配置或错误，不直接写 TOML，也不直接操作设置控件。

生产存储使用 `NSUbiquitousKeyValueStore.default`，测试使用内存实现。同步服务不依赖
`TerminalCore`、`InkTerminalView` 或 PTY。

`MainWindowController` 继续拥有配置保存与应用流程。拉取得到有效 `InkConfig` 后，仍调用
现有 `saveConfig`/`InkConfig.save` 链路写入 TOML、刷新设置控件并应用到所有 pane。由
`MiniTOML.updating` 更新已知键，因此本机注释、空行、未知 section 与未知键保持不变。

## 触发与数据流

### 开启自动上传

1. 用户打开“自动上传配置”。
2. 本机偏好立即保存。
3. 当前 `InkConfig` 生成新快照并立即上传。
4. 成功后状态显示云端修改时间；失败时开关仍保持开启，后续本机配置变化会再次尝试，
   用户也可以手动重试。

### 本机配置变化

设置页或外部 TOML 编辑产生新配置，并且本地保存或加载成功后，如果自动上传已开启，
就生成新快照并上传。触发严格依赖配置变化事件，不使用周期任务。对于步进器、文本输入
等可能连续产生的变更，可将同一轮主队列中的待上传值合并为最后一个；不得设置周期性
计时器。每次实际上传始终包含完整配置，而不是字段增量。

### 手动上传

点击“上传到云端”后读取当前本机配置并生成新快照。若云端为空或内容相同，直接上传；
若已有不同配置，先显示确认 sheet，列出云端修改时间和来源，并明确“本机配置将覆盖
云端配置”。确认后立即上传，不受自动上传开关影响。

### 手动拉取

点击“拉取云端配置”后请求 KVS 同步并读取当前可取得的快照。若没有云端配置则显示
空状态；若内容与本机相同则只更新状态；若不同则显示确认 sheet，列出云端修改时间和
来源，并明确“云端配置将覆盖此 Mac 的设置”。确认后才写入 TOML 并立即应用。

手动拉取是唯一的下行应用入口。应用不会在启动、打开自动上传开关或收到系统云端变化
时自动覆盖本机，也不根据 `modifiedAt` 执行“最后修改者胜”。

## 设置界面

设置页在“交互”和“高级”之间新增独立的“iCloud”分组：

- 第一行显示“自动上传配置”开关，说明为“修改设置后上传到 iCloud”。
- 状态区显示“尚未上传”“正在上传…”“正在读取…”“已上传 · 刚刚”
  “云端配置来自此 Mac · 14:32”“iCloud 不可用”或具体可恢复错误。
- 操作区并排显示带 SF Symbols 的“上传到云端”和“拉取云端配置”次级按钮。

关闭自动上传不会删除云端快照，两个手动按钮仍然可用。同步操作进行期间开关与两个按钮
暂时禁用，触发按钮显示进行中状态；成功只更新分组内状态，不弹成功对话框。失败不改动
当前配置，也不打断终端会话。

以下情况使用确认 sheet：

- 手动上传将覆盖不同的云端配置；
- 手动拉取将覆盖不同的本机配置。

确认 sheet 的默认按钮是取消，覆盖按钮明确写出方向。云端为空、两端内容相同或只是读取
状态时不弹确认。所有控件提供中文 accessibility label；状态不能只用颜色表达。

## 偏好、权限与打包

“自动上传配置”与 `deviceID` 使用独立的 `UserDefaults` key，只属于当前 Mac，不进入
`InkConfig` 或云端 JSON。这样一台设备打开自动上传不会改变其它设备的行为。

正式 `Ink.app` 需要 `com.apple.developer.ubiquity-kvstore-identifier` entitlement，并使用
具有对应 iCloud capability 的签名身份和 provisioning 配置。打包脚本需要将 entitlement
传给 `codesign`。当前默认 ad-hoc 签名和直接 `swift run` 环境不能保证 iCloud 可用；这些
环境必须安全降级为“iCloud 不可用”，不能影响本地设置、终端启动或测试。

本次不创建发布标签，不改变发布权限边界。真正发布前需由仓库拥有者确认 Apple Developer
侧的 App ID、Team ID 与 KVS container 配置。

## 错误处理

- iCloud 未登录、entitlement 缺失或 KVS 不可用：保留本机配置，在分组内提示并允许重试。
- 云端无快照：拉取不写本机，显示“云端暂无配置”。
- JSON 损坏、schema 过新或字段非法：整份拒绝，不做部分应用。
- 上传失败：不回滚已经成功保存的本机设置；保持自动上传开关，等待下一次事件或手动重试。
- 拉取后的 TOML 写入失败：本机内存配置与界面保持原值，沿用现有保存错误提示。
- 应用退出时不阻塞等待网络，也不增加后台常驻轮询任务。

## 验证

自动验证包括：

- `InkConfig` 与 schema 1 JSON 的完整往返，覆盖所有当前字段；
- 损坏 JSON、过新 schema、非法枚举与越界数值整份拒绝；
- 开启自动上传立即上传，本机配置变化后再次上传，关闭后不自动上传；
- 手动上传和拉取不受开关影响，方向与确认条件正确；
- 拉取写回后已知配置更新，TOML 注释与未知字段保留；
- iCloud 不可用、云端为空与存储错误不改变本机配置；
- 设置页分组顺序、文案、状态、禁用态、确认 sheet 与辅助功能标签；
- 打包产物包含预期 entitlement，签名验证测试按具备凭据与否区分执行；
- 完整运行 `swift test` 与 `swift build`。

运行时验收至少使用两个登录同一 iCloud 账户且具有正确签名 entitlement 的 macOS 环境：

1. Mac A 打开自动上传，确认当前设置立即进入云端。
2. Mac A 修改多项设置，确认由变化事件上传且没有周期请求。
3. Mac B 在不点击拉取时保持本机配置不变。
4. Mac B 手动拉取并确认后，所有已知设置更新且本机 TOML 注释仍在。
5. Mac B 关闭自动上传后仍可手动上传和拉取。

该功能不进入渲染循环、grid 或 scrollback 路径，不要求 Time Profiler 热路径采样。验收时
检查空闲状态没有 Ink 自建定时器或轮询，并观察同步服务没有明显持续 CPU 与内存开销。
