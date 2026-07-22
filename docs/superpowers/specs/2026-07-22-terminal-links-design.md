# URL 与 OSC 8 超链接设计

关联 Issue：#66

## 目标与范围

本项为 roadmap 的 P1-S「链接」能力，独立交付：

- 自动识别逻辑行内的 `http://` 与 `https://` URL。
- 解析 OSC 8 显式超链接，支持开始、结束、替换和跨软折行范围。
- Command 点击打开链接，悬停显示手型并绘制下划线反馈。
- 链接处右键提供“打开链接”和“复制链接”。
- TUI 开启鼠标上报时，普通右键保持应用语义；`Option + 右键` 强制打开
  Ink 原生菜单。

完整终端右键菜单中的普通复制、粘贴、查找、分屏和清除 scrollback 不在本
Issue 内，留给下一项独立合并。这样链接能力不依赖后续菜单功能，也能单独回滚。

## 不变量

- `TerminalCore` 保持纯 Swift，不依赖 AppKit 或 Metal。
- `Cell` 保持 8 字节，`RowInfo` 保持 2 字节；不得增加每格链接字段或对象引用。
- 链接元数据只在实际出现显式链接时分配，权威数据采用终端级逻辑行稀疏范围表。
- 无活动 OSC 8 且当前物理行没有链接时，打印路径只做常数次标量判断和一次稀疏
  行索引查询，不扫描文本、不创建数组或字符串。
- URL 自动识别只在鼠标命中等冷路径运行，不进入解析、grid 更新或逐帧全屏遍历。
- 自动 URL 的同步命中最多物化 65,536 cells / 2,048 个物理行；超过上限的单条
  软折逻辑行不做自动扫描。显式 OSC 8 先查稀疏索引，只投影已命中范围的物理端点，
  不受自动扫描预算影响；端点投影最多走 2,048 行，超出时只把悬停反馈降级到命中
  cell，目标仍可打开。
- OSC 8 URI 本体的终端级总预算为 8 MB，且最多保存 65,536 个唯一目标；范围表最多
  保存 131,072 条逻辑行记录和 262,144 个 span。达到预算后忽略新的元数据，已有目标
  与范围继续按引用计数正常工作。
- 悬停反馈复用现有实例化渲染，每帧仍只提交一次 draw call。

## 核心模型

### 逻辑行坐标

链接范围以逻辑行为单位，不直接绑定窗口当前的物理折行：

```swift
struct LogicalHyperlinkSpan {
    var startOffset: UInt32
    var endOffset: UInt32       // 半开范围
    var targetID: UInt32
}

struct LogicalHyperlinkLine {
    var headLineID: UInt64
    var spans: ContiguousArray<LogicalHyperlinkSpan>
}
```

`headLineID` 是逻辑行第一条物理行的稳定行号。当前布局中，scrollback 最旧行的
稳定行号为 `totalAppendedLines - count`；屏幕第 `r` 行为
`totalAppendedLines + r`。整屏向上滚动时，内容的稳定行号不变。

`startOffset..<endOffset` 是把同一逻辑行的所有软折行拼接后的 cell 偏移。宽字符
占两个偏移，尾格也能命中；组合字符与 ZWJ 簇不增加偏移。

终端同时维护只覆盖有链接物理行的稀疏行索引。索引把物理行号映射到逻辑行记录
及该物理行在逻辑行中的起始偏移，用于避免每次字符覆写都向前扫描 wrapped 行。
该索引是加速结构，权威数据仍是逻辑行范围；重排后可由范围表重建。

### 目标表

OSC 8 的 URI 在终端级目标表中驻留一次，范围只保存整数 `targetID`。目标表按 URI
复用条目并记录引用数；范围被删除或 scrollback 淘汰后释放引用，空槽通过 free list
复用。空终端不创建目标条目，重复链接不会重复保存字符串。逻辑行记录按
`headLineID` 排序保存；只有首个链接出现时才创建范围表、目标表和物理行索引。
scrollback 淘汰通过可推进的记录头索引删除硬换行前缀；每条记录保存当前布局最后
一个实际 anchor，密集和间隔链接都不必逐行复制整张范围表。过期物理索引按稳定
行号单调 O(1) 删除。逻辑行头被淘汰而 wrapped continuation 仍存活时延迟 rebase，
每 65,536 行（小容量测试至少 256 行）才线性整理一次，因此持续软折输出保持摊销
线性。reflow 裁掉的宽字符补白 gap 保存累计前缀，span 端点以二分压缩，不做
`spans × gaps` 扫描。

对外返回值使用不可变值类型：

```swift
public struct TerminalLink: Sendable, Equatable {
    public let target: String
    public let range: SemanticTextRange
    public let source: Source       // osc8 / detectedURL
}
```

`range` 投影到调用时的 `TextPosition`，因此视图、搜索和选区使用同一套绝对行坐标。

## OSC 8 状态与写入

OSC 8 格式为 `OSC 8 ; params ; URI ST`：

- URI 非空：设置或替换当前活动目标；参数本次只做边界解析，不赋予额外语义。
- URI 为空：关闭活动目标。
- 缺少第二个分号、UTF-8 非法、含控制字符或超过 Parser 既有 4096 字节上限：
  忽略该序列，不破坏当前终端内容。
- BEL 与 ST 终止继续复用 Parser 现有 OSC 行为。

写入一个有显示宽度的字符时，核心先移除即将覆写 cell 范围内的旧链接，再按当前
活动目标插入新范围；相邻且目标相同的范围立即合并。活动目标为空时，覆写仍会
清掉该位置可能存在的旧 OSC 8 范围。组合字符和 ZWJ 只扩充前一个 glyph，不改变
其原有链接归属。

显式 OSC 8 范围优先于同位置的自动 URL 识别。OSC 8 可使用任意合法绝对 URI；
打开动作只发生在用户明确 Command 点击或选择菜单之后，并交给 macOS
`NSWorkspace` 处理。无法构造为绝对 URL 的目标仍可复制，但禁用“打开链接”。

## 编辑、滚动与生命周期

所有改变 cell 位置或内容的操作通过集中链接同步接口处理；不允许各 CSI 分支直接
操作范围数组。

### Cell 级编辑

- 普通覆写、`ECH`、`EL`、`ED`：删除与清空区间相交的范围，必要时分裂。
- `ICH`、`DCH`：只在当前物理行对应的逻辑偏移片段内平移、裁剪范围，不影响后续
  wrapped 物理行。
- 宽字符孤儿清理同时清除被连带擦除的首格或尾格范围。
- 整行清空删除该物理片段；逻辑行不再有范围时删除记录和稀疏行索引。
- 行进入 scrollback 时，链接范围按 `ScrollbackLine` 实际保留的 cell 数同步裁剪；
  被历史行裁尾丢弃的默认空白不保留不可命中的悬空范围。

### 行级编辑

- 整屏向上滚动沿用稳定行号，只需登记新空行并批量裁剪已被 scrollback 环覆盖的
  旧记录，不搬动存活范围。
- 部分滚动区域、`IL`、`DL`、反向索引与整屏向下滚动，会按 Grid 的相同行映射移动
  稀疏记录；被挤出的范围释放目标引用。
- 行操作可能改变 wrapped 邻接关系。仅当受影响区域实际含链接时，将相关逻辑行
  投影为物理片段、执行与 Grid 相同的行变换，再按新的 `RowInfo.wrapped` 重组；
  无链接时立即返回。
- 主屏和备用屏分别持有链接旁路状态。进入备用屏不丢弃主屏范围，退出时恢复；
  备用屏不会写入主屏 scrollback。当前活动 OSC 8 目标与 `currentAttr` 一样是终端级
  状态，不因屏幕切换隐式关闭；它写出的范围进入当时活动屏幕的旁路表。
- RIS、清屏及清除 scrollback 与现有内容生命周期一致地清理目标和范围。

### Reflow

主屏 reflow 已经逐条聚合逻辑行。处理每条逻辑行时，同时取出同一 `headLineID`
下的链接偏移；cells 按新列宽切块后，范围的逻辑偏移不变，只把记录绑定到新布局的
首行 ID 并重建稀疏物理行索引。

reflow 完成后，过滤首个保留物理行之前的记录。若环容量从一条逻辑行中间截断，
保留部分会以新的最旧物理行为头，所有范围偏移减去被淘汰的前缀长度；完全落在
前缀内的范围删除。这样不会因为头行被覆盖而误删仍可见的软折行链接。

## URL 自动识别

自动识别使用 TerminalCore 内的纯 Swift 扫描器，不依赖 `NSDataDetector`：

- 大小写不敏感地识别 `http://` 与 `https://`。
- 在上述同步预算内扫描鼠标所在的完整逻辑行，并生成 Unicode scalar 到 cell 偏移
  的映射。
- 空白、控制字符和终端分隔符结束 URL。
- 去掉常见英文与中文句末标点；`)`、`]`、`}` 仅在没有匹配左括号时从尾部去掉，
  从而保留 `https://example.test/a_(b)` 一类合法地址。
- URL 构造失败或只有 scheme 而没有 host 时不返回链接。

自动 URL 不写入终端的持久 OSC 8 范围表。它在命中冷路径即时产生
`TerminalLink`；视图只缓存当前悬停结果，并在每次终端 `onUpdate` 标脏后重新解析
鼠标位置。这样无 URL 的十万行历史没有负缓存开销，reflow、环淘汰和随机编辑也
不会留下失效的自动识别坐标。

## 视图与交互

`TerminalMetalView` 增加 tracking area，并只在鼠标跨 cell 或终端内容更新后重新
解析命中：

- 命中链接：使用 pointing-hand cursor，保存当前 `TerminalLink`，请求重绘。
- 离开链接或视图：恢复 I-beam/default cursor 并清除悬停范围。
- renderer 接收一个可选半开范围。构建现有 cell instance 时，命中范围的实例增加
  underline flag；不修改 grid 属性，不增加 draw call。
- Command 左键按下时重新查询当前位置。命中可打开目标的链接就消费事件并调用
  外壳注入的 `onOpenLink`；未命中继续现有选择或 TUI 鼠标处理。

右键决策顺序：

1. TUI 鼠标上报开启且未按 Option：沿用当前按下/松开上报，不弹原生菜单。
2. 未开启鼠标上报，或按住 Option：重新查询位置。
3. 命中链接：弹出“打开链接”“复制链接”；目标不可打开时只启用复制。
4. 未命中链接：本 Issue 不构造空菜单，保持现有行为。

菜单项携带不可变的目标字符串，不依赖菜单弹出后可能已经变化的终端坐标。复制走
现有可替换 pasteboard writer；打开通过外壳注入闭包调用 `NSWorkspace`，便于测试且
保持 TerminalCore/UI 外壳边界清晰。

## 验证策略

TerminalCore 测试覆盖：

- OSC 8 的 BEL/ST、分片输入、开始/关闭/替换、无效格式和 UTF-8。
- 普通写入、覆写、宽字符、组合字符、软折行和硬换行。
- `ICH`、`DCH`、`ECH`、`EL`、`ED`、`IL`、`DL`、局部/整屏双向滚动。
- 主/备用屏切换、RIS、清屏、清除 scrollback。
- 变宽/变窄 reflow，以及环覆盖完整或部分逻辑行。
- URL 大小写、尾部标点、平衡括号、宽字符前缀、跨软折行和非法地址。
- OSC 8 对自动 URL 的优先级及绝对坐标投影。
- `MemoryLayout<Cell>.stride == 8`、`MemoryLayout<RowInfo>.stride == 2` 和空状态
  不创建链接记录。

InkTerminalView 测试覆盖：

- Command 点击只在链接命中时打开，并在 TUI 鼠标模式中作为显式原生手势优先。
- 普通右键与 Option 右键的鼠标上报/原生菜单分流。
- 菜单复制使用弹出时目标，终端随后更新不会复制错误内容。
- 悬停范围变化会标脏，renderer 为范围加下划线且维持单 draw call。

合并前运行 `swift test`、`swift build`，并用实际 Ink 窗口验证自动 URL、OSC 8、
滚屏、resize 和鼠标上报。由于打印与渲染路径都有条件分支，使用 Instruments Time
Profiler 对比无链接持续输出和包含链接输出；无链接基线不得出现可测的扫描、字符串
构造或额外分配。

## 被否决方案

### 仅在视图层维护链接

URL 自动识别容易，但 OSC 8 需要随 VT 编辑、scrollback 与 reflow 改变。视图层会
复制 TerminalCore 的坐标语义，并在后台搜索快照与主终端之间产生两套真相。

### 给 Cell 增加链接 ID

命中查询最直接，但每格即使没有链接也增加常驻空间。10 万行 scrollback 会放大该
成本，并直接违反 roadmap 与 8 字节 cell 不变量。

### 输出时扫描每一条普通文本行

可以预先建立所有 URL 范围，却把字符串构造和 URL 解析放进持续输出热路径。链接
是稀疏交互数据，不值得让普通 `cat`、构建日志和 TUI 输出承担该成本。
