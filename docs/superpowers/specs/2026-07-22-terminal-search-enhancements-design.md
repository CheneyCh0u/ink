# 终端搜索增强设计

## 背景与目标

Ink 已有当前 pane 内的增量 scrollback 搜索：输入查询后在后台扫描搜索快照，结果按
终端坐标高亮，后续 PTY 输出优先只重扫可变后缀；查询变化、reflow 或历史环淘汰需要
全量工作时切到后台，并用取消与 generation 阻止旧任务回写。

roadmap 的 P1-B 要在这条基线上增加三项能力：大小写模式、仅搜索选区，以及复制当前
匹配所在命令的输出。本项的目标不是建立第二套搜索器，而是让三项能力继续共享现有
索引、坐标、高亮与 OSC 133 语义边界，并保持 Ink 的性能与内存纪律。

## 范围

### 本次实现

- 每个 pane 的当前搜索会话持有独立大小写模式，默认忽略大小写。
- 搜索浮层以紧凑系统按钮明确显示大小写模式，切换后取消旧任务并重新计算。
- 搜索浮层可把开启瞬间的非空选区冻结为搜索范围；后续鼠标选区变化不改变该范围。
- 冻结范围在历史滚动时按稳定行 ID 重映射；reflow、清历史、备用屏切换、RIS 或历史
  环淘汰掉范围端点时自动退出“仅搜索选区”并刷新 UI 与结果。
- 当前匹配属于一个带输出的 OSC 133 命令块时，搜索浮层可从 live Terminal 复制该
  命令块的输出；没有当前匹配、匹配坐标失效、没有命令块或命令块没有输出时禁用。
- 大小写、范围和查询都参与索引身份；现有增量后缀更新、后台取消、generation 防旧
  回写、当前结果保持和就近选中语义继续成立。
- 新状态只存在于搜索会话、视图浮层或每份搜索索引中，不给 cell、RowInfo、历史行或
  OSC 133 行数据增加字段。

### 明确不做

- 不实现正则表达式、模糊搜索、整词匹配、跨 pane / 标签搜索或搜索历史。
- 不把选区文本复制到另一份长期字符串缓存，也不持久化搜索选项。
- 不让搜索快照保留 OSC 133 完成记录、事件、超链接或命令旁路。
- 不给每个匹配增加稳定行 ID；一批结果只共享一份坐标空间。
- 不修改通用“拷贝命令输出”菜单的视口 / 命令导航语义。
- 不增加第三方依赖，不修改渲染 draw call、cell 布局或 scrollback 存储格式。

## 既有实现约束

`TerminalSearchEngine` 按逻辑行搜索，软折行可跨物理行匹配，硬换行不可跨越。它把
NSString 的 UTF-16 匹配范围映射回实际 cell，宽字符、组合簇和 ZWJ emoji 都依赖这层
映射。`TerminalSearchIndex` 只缓存匹配坐标和最近终端版本，查询或 layout revision
变化时全量重建；普通输出只重扫 grid / 新增历史后缀。

`TerminalSearchController` 在 MainActor 上拥有一个搜索会话。全量扫描使用剥离旁路的
`snapshotForSearch()` 和 detached task，查询输入有 30 ms debounce。每次开始后台工作
都会递增 generation，取消旧父任务与子扫描；只有 generation 仍匹配的结果才能应用。

`TerminalMetalView` 持有鼠标选区、显示搜索高亮并负责剪贴板写入。`Terminal.commandBlocks()`
只在用户动作时扫描 live Terminal 的 OSC 133 行元数据和稀疏旁路，搜索快照故意删除
命令完成记录等状态。因此复制匹配命令输出不能在后台搜索结果上直接解析命令块。

## 方案比较

### 方案 A：每个结果携带 layout revision 与稳定行 ID

结果可独立重映射，但每一处匹配都增加至少两个 machine word。高频单字符查询可能产生
几十万结果，这会把冷路径元数据按匹配数放大，违背“只保留必要匹配坐标”的内存目标。

### 方案 B：开启选区模式时复制选区文本并独立搜索

实现直观，但会建立第二份可能很大的字符串，丢失终端 cell 坐标，必须另写 Unicode、
软折行和矩形选区映射，且新 PTY 输出无法复用增量索引。复制命令输出也无法可靠回到
OSC 133 坐标，因此不采用。

### 方案 C：一批结果共享坐标空间，索引继续搜索 Terminal（采用）

搜索会话为冻结选区和当前结果各保存一份轻量坐标空间：layout revision 与当时最旧历史
行的稳定 ID。范围或结果需要用于 live Terminal 时统一重映射。搜索引擎仍读取 Terminal
cell，只增加大小写选项与可选范围过滤；结果结构不变。

这一方案让内存开销与 cell、line、匹配数无关，保留现有 Unicode / 软折行 / 高亮路径，
并能在复制时明确跨越“无 OSC 旁路的快照”与“有 OSC 旁路的 live Terminal”边界。

## 核心搜索接口

### `TerminalSearchOptions`

在 `TerminalCore/TerminalSearch.swift` 增加 Sendable、Equatable 值类型：

- `caseSensitive: Bool`，默认 `false`；
- `selection: SelectionRange?`，nil 表示全部终端，非 nil 表示只接纳完全位于选区内的
  匹配。

`TerminalSearchEngine.search` 与 `TerminalSearchIndex` 的更新 / 后台判定都接收 options，
并提供默认值保持现有调用方语义。索引把 options 作为缓存身份的一部分：查询文本或任一
选项变化都全量扫描，绝不把不同大小写 / 范围模式的结果混入增量后缀。

大小写敏感时 NSString 搜索不传 `.caseInsensitive`；默认模式保持当前行为。匹配仍按
不重叠、旧到新顺序返回，空查询仍立即得到空数组。

### 选区过滤

引擎先把扫描行夹到选区覆盖的行区间，避免遍历与范围无关的历史。逻辑行组装和 UTF-16
映射保持不变；找到候选后，以该候选实际覆盖的 `CellMapping` 判断是否完全包含：

- 普通线性选区按归一化起止位置包含；
- Option 矩形选区要求候选覆盖的每个实际 cell 都在矩形行列内；
- 候选碰到选区外 cell 时整体拒绝，不返回截断匹配；
- 软折行候选仍可跨物理行，但矩形范围不会把行尾未选列当成连续选中文本；
- 硬换行继续切断逻辑行，选区不会改变这一语义。

过滤发生在匹配映射完成时，不给 cell 增加标志，也不复制选区文本。搜索源仍包含完整
逻辑行，但任何借助选区外字符形成的候选都会因 mapping 未全部包含而拒绝。

## 稳定坐标空间

新增 `TerminalSearchCoordinateSpace` 值类型，捕获：

- `layoutRevision = terminal.searchLayoutRevision`；
- `oldestLineID = totalAppendedLines - scrollback.count`。

`resolve(range:in:)` 首先要求 live Terminal 的 layout revision 未变，再把原绝对行转换为
稳定行 ID，减去当前 oldestLineID 得到新绝对行。若任一端点已早于当前最旧行、超出
当前 `totalLines`，或列为负数，则返回 nil。这样：

- grid 行滚入未满的 scrollback 时 oldestLineID 不变，范围自然保持；
- 环淘汰发生但冻结范围仍存活时，范围整体向前平移并继续搜索；
- 任一端点被淘汰时范围失效；
- reflow、清历史、RIS、主 / 备用屏切换已递增 layout revision，直接失效；
- 不需要给每个匹配保存 line ID，也不依赖搜索快照中的 OSC 133 旁路。

坐标空间是搜索功能的冷路径小值类型，不进入渲染循环、Grid 或 ScrollbackBuffer。

## 搜索会话状态与异步数据流

`TerminalSearchController` 增加：

- 当前 `caseSensitive`；
- 可选的冻结选区（原始范围 + 捕获坐标空间）；
- 当前索引结果对应的坐标空间；
- 从 `TerminalMetalView` 读取当前选区的 provider，测试可注入固定范围。

查询、大小写或选区模式变化统一走一次 restart：

1. 在 MainActor 读取 live Terminal；
2. 若选区模式开启，把冻结范围重映射到 live Terminal；失败则先退出该模式；
3. 生成 `TerminalSearchOptions`，再创建剥离旁路的搜索快照；
4. 递增 generation、取消旧任务、清除旧索引与当前结果并立即发布空状态；
5. 查询非空时后台用“查询 + options + snapshot”全量构建；
6. 仅当前 generation 应用结果，同时保存该 snapshot 的坐标空间；
7. 选择离当前视口最近的结果并刷新高亮、计数与复制按钮。

PTY 刷新时先验证冻结范围。范围失效会取消任何在途 generation、关闭选区模式并按全
终端重新搜索；范围仍有效则把重映射后的范围交给索引。若索引判定是短后缀工作，继续
在 MainActor 原地增量更新；否则保持现有后台路径。后台期间到来的刷新继续合并为一次
`refreshRequestedWhileSearching`，旧 generation 仍不能回写。

大小写或范围切换属于当前 pane 的搜索会话，关闭浮层即释放；重新打开回到忽略大小写
且全终端搜索。不同 pane 的搜索浮层不会共享状态。

## 冻结选区语义

“仅搜索选区”按钮仅在当前 `TerminalMetalView` 能提供非空范围时可开启。非空的定义是
范围可在 live Terminal 中解析，且 `extractText(in:)` 不是空字符串；只有空白、越界或
零内容的范围不可用。

开启时立即复制范围值并捕获坐标空间。之后用户清除或改变视图选区，不改变已冻结范围。
关闭再开启会重新读取当时的视图选区。搜索浮层仍可在用户点击终端后保留，因而按钮的
可用性在每次发布和终端刷新时重新计算。

冻结范围失效时，控制器自动：

1. 清除冻结范围；
2. 把按钮状态切回关闭；
3. 重新计算按钮可用性；
4. 取消旧 generation；
5. 使用全终端 options 刷新当前查询。

自动退出不弹 alert、不发声；按钮视觉状态与结果计数的立即变化已经表达原因。若视图
仍持有一个因 layout revision 失效的旧选区，它不能再次启用范围模式；选区 provider
同时校验坐标空间，用户需要重新选择。

## 复制匹配所在命令输出

搜索控制器不向搜索快照添加 OSC 133 状态。当前结果应用时，只保存整批结果的坐标空间。
按钮状态和点击动作都执行同样的 live 解析：

1. 读取当前匹配和该批结果的坐标空间；
2. 把匹配范围重映射到当前 live Terminal；
3. 若 layout revision 不同或匹配已被淘汰，判定不可用；
4. 调用 live Terminal 的 `commandBlocks()`；
5. 寻找完整包含匹配范围的命令块文本跨度（从 commandRange.start 到 outputRange.end）；
6. 要求该命令块有非空 `outputRange`；
7. 用 live Terminal 的 `extractText(in:)` 提取并经 TerminalMetalView 现有剪贴板写入口复制。

匹配可以位于命令文本或输出文本中；二者都属于同一个命令块。提示符、块外普通输出、
只有 B/C 未形成完整块、没有输出范围或空输出均不可复制。若 OSC 133 不存在，不根据
屏幕行、提示符字符或相邻换行猜测命令边界。

按钮的 enabled 状态只是即时 UI 反馈；点击时必须再次从 live Terminal 验证，避免按钮
显示后到点击前发生输出、淘汰或 layout 改变。动作失败不覆盖剪贴板。

## 搜索浮层 UI

沿用右上角 `NSVisualEffectView` 系统 popover 材质和 34 pt 高度，不增加独立面板。水平
排列为：搜索框、结果计数、`Aa` 大小写按钮、“选区”按钮、复制输出图标、上一个、下一
个、关闭。

- `Aa` 使用 push-on/push-off 系统状态，accessibility label / tooltip 明确为“区分大小写”；
- “选区”按钮同样显示开 / 关状态；没有可冻结的非空选区且当前未开启时 disabled；
- 复制按钮使用系统 `doc.on.doc` 图标，accessibility label / tooltip 为“拷贝匹配所在命令输出”；
- 上 / 下结果按钮继续只在有结果时启用；
- 当前模式由按钮按下态直接表达，不依赖颜色，VoiceOver 可读 value / label；
- 搜索栏略增宽但仍悬浮，不改变终端 grid、PTY 尺寸或 pane 最小尺寸。

键盘回车、Shift-回车、上下方向和 Escape 路由保持不变。本项不分配新的全局快捷键，
避免与 roadmap 中尚未实现的快捷键自定义提前耦合。

## 错误、竞态与边界处理

- 空查询：索引和当前结果清空，选项状态保留；复制按钮禁用。
- 切换选项时旧任务：先递增 generation 再取消，旧结果即使扫描完成也无法应用。
- 扫描中有 PTY 输出：记录一次延迟刷新；当前 generation 应用后再按 live Terminal 更新。
- 范围在扫描中失效：后续终端刷新取消该 generation 并退出选区模式；若失效发生后没有
  PTY 回调，复制动作仍通过 live 坐标验证安全失败。
- 环淘汰但范围仍存活：重映射后 options 坐标变化，索引按 options 身份全量后台重建；
  不尝试把受限范围套入原有全终端结果。
- reflow / 清历史 / RIS / 备用屏：layout revision 不同，冻结范围和结果坐标都失效。
- 当前匹配在命令块边界上：要求整个 inclusive 搜索范围落在命令 + 输出半开跨度内；
  跨越下一个 prompt 或两个命令块的匹配不归属于任一块。
- 矩形选择：每个候选 cell 都必须在矩形内；不把行尾到下一行开头隐式选中。
- Unicode：大小写比较继续使用 Foundation NSString；cell 映射、宽字符与组合簇逻辑不变。

## 测试与 TDD 切分

### TerminalCore 搜索

- 默认模式继续匹配 `Alpha` / `alpha`，敏感模式只匹配完全相同大小写。
- options 改变让索引走 full update；相同 options 保持 incremental。
- 线性选区只返回完全包含的匹配，跨边界候选被拒绝。
- 矩形选区逐 mapping 限制列范围，软折行经过未选 cell 的候选被拒绝。
- 坐标空间在普通滚动与存活淘汰后正确重映射；端点淘汰和 layout revision 改变返回 nil。
- 既有 Unicode、软折行、重复结果和环淘汰测试继续通过。

### 搜索控制器

- 切换大小写后结果变化，搜索栏按下态同步。
- 快速切换大小写 / 查询时旧 generation 不覆盖新结果。
- 无非空选区时范围按钮禁用；开启时冻结当时范围，provider 后续变化不影响结果。
- 冻结范围随存活历史重映射；reflow、清历史或端点淘汰时自动退出并回到全终端结果。
- 当前匹配保持与最近结果选择在带 options 的刷新后仍成立。
- 匹配在 OSC 133 命令 / 输出中可复制对应输出；匹配在块外、无当前匹配、无输出或坐标
  失效时禁用且不写剪贴板。
- 测试明确构造 live Terminal 与搜索 snapshot 旁路差异，证明复制没有错误依赖 snapshot。

### 搜索栏

- 模式更新能正确显示按下态、availability 与复制按钮 enabled 状态。
- 按钮动作路由大小写、选区和复制回调。
- 原有计数、导航按钮和键盘路由保持。

开发中按任务只运行 `TerminalSearchTests`、`TerminalSearchWorkspaceTests` 和
`TerminalSearchBarTests` 等 focused suites，逐项保留 RED / GREEN 输出。按 controller
指令不运行完整 `swift test`、完整 build 或最终 code review；交付前运行 focused tests、
`git diff --check` 并审计 `origin/main..HEAD`。本项不改热路径，不需要 Instruments。

## 文档与交付

- roadmap 已明确列出这三项 P1-B，本项不改变范围或优先级。
- Issue #77、设计、计划、代码与测试位于 `agent/issue-77-search-enhancements` 分支。
- 设计、计划和每个可独立回滚的实现阶段分别提交，提交信息用中文并含 `Refs #77`。
- 本任务不 push、不创建 PR、不合并、不打 tag、不发布；由并发功能汇总后统一处理。
