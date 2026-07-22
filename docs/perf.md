# 性能与内存验收记录

指标定义见 [tech-stack.md](tech-stack.md)。本文记录实测数字与达成手段，
数字会随硬件变化，趋势和结论不会。

测试环境：Apple Silicon（arm64e）/ macOS 26.5 / 2x 缩放 / 窗口 1280×800。
基准程序：`swift run -c release ink-bench`（端到端：字节流 → Parser →
Terminal → scrollback，10 万行 × 200 列）。

## Scrollback 内存（目标 10 万行 < 200MB）

| 负载 | 实测增量 | 每行 | 说明 |
|---|---:|---:|---|
| ASCII 均值 40 列（ls 类） | **9.3 MB** | 97 B | 裁尾 + ASCII 1B/格压缩双重生效 |
| ASCII 满 200 列 | **24.5 MB** | 257 B | 压缩后 1B/格 + 行对象开销 |
| 彩色输出 ~80 列 | **49.0 MB** | 513 B | 带属性走 8B/格完整 Cell |
| 中文为主 80 列 | **74.7 MB** | 783 B | 最坏路径，仍不足目标一半 |

**结论：达标，最坏负载余量 2.7 倍。** 依赖两道闸：入库裁尾（P0 就有）
和纯 ASCII 行 1 字节/格紧凑存储（`ScrollbackLine` 内部格式，对外接口不变）。

## 解析吞吐

修复前 10–14 MB/s，修复后 **47–82 MB/s**。两个采样定位的真凶：

1. **跨模块泛型未特化**：`Parser.feed` 曾对 handler 与字节序列都取泛型，
   从别的模块调用时每字节走 protocol witness 动态派发加装箱。协议只有
   `Terminal` 一个实现——已具体化，抽象一分钱没买到还搭进一个数量级。
2. **CJK 每字符查 generalCategory**（运行时 Unicode 属性调用）：宽表
   二分更便宜且与零宽码点无交集，已调整判定顺序，CJK 不再触碰它。

另外 grid 滚动从整屏 memmove（每个 LF 搬 80KB）改成环形行索引（转指针
+ 清一行）。单独看吞吐提升不大，但它把滚动从 O(屏) 降到 O(行)，
高速输出下的 CPU 占用实质下降。

教训记录：**性能问题先采样再动手**。memmove 是"显然"的嫌疑人，真凶
却是泛型派发——猜测会浪费一轮重构。

## 空闲内存（目标单窗口 < 50MB）

实测 **63 MB**（debug 与 release 相同——大头不在代码）。构成：

- 2 × 全窗口 drawable（2560×1600 BGRA）≈ 33 MB —— 已从默认 3 块降到
  2 块（脏帧驱动够用），这是 CAMetalLayer 方案的地板，随窗口面积走
- 单色字形图集（2048² A8）4 MB；**彩色图集懒分配**（BGRA 16MB，
  出现第一个 emoji 才创建）
- AppKit / 运行时 / CA 合成 ≈ 20 MB

**结论：2x 高分屏 + 大窗口下 63MB，1x 或小窗口可低于 50。** swap-chain
是不可再压的部分，任何 Metal 终端同理。指标出发点（不为 scrollback
和渲染无谓买单）已达成。

## Reflow

10 万行满载下改列宽：**29ms**（变窄与变宽相当）。流式实现——按
`wrapped` 位拼逻辑行、重切、尾部回屏，一次只持有一条逻辑行，无整体
物化。拖拽窗口每档列宽变化付一次，交互无感。

## 当前 pane 历史搜索

2026-07-20 在 Apple M4 Pro / arm64 / macOS 27.0 上使用 Release 构建测量。
终端包含 10 万行 ASCII 历史，每 1,000 行放一个固定命中，共 100 个结果；
首次扫描后再追加一行新命中，测量增量索引更新。

| 操作 | 实测 | 结果 |
|---|---:|---:|
| 首次扫描 10 万行 | **75.4 ms** | 100 个命中 |
| 追加一行后的增量刷新 | **0.252 ms** | 101 个命中 |
| 结果坐标缓存 footprint 增量 | **0.1 MB** | 仅搜索打开期间存在 |
| 清空索引 | **0.5 µs** | 匹配数组逻辑释放 |

清空后的进程 footprint 仍比搜索前高约 0.1 MB，这是 Swift 分配器保留已申请
页供后续复用，并不表示搜索结果仍由控制器持有。搜索关闭后，视图会同时清除
高亮数组，渲染器收到空区间，不再为搜索做逐格判断。以上数字只说明本机这次
Release 基准结果，不外推为固定延迟保证。

首次扫描和需要整体坐标平移的更新使用 `Terminal` 的只读值快照在后台任务
执行，并用 30ms 输入合并与代次令牌丢弃过期结果；普通新增输出只在主线程
原地重扫可变后缀，本次为 0.252ms。视图按需读取控制器结果，避免两个数组
所有者触发增量更新的全量 CoW。可见高亮通过有序结果二分定位，不逐帧遍历
全部历史命中；搜索关闭时选择泛型特化的无搜索 cell 构建路径。

scrollback 槽表采用惰性 256 行分页 COW。后台值快照与主终端共享未改页；
持续输出时只复制当前写入页与约 391 个引用的页目录，不复制 10 万槽整环。
后台任务取消会传递到扫描任务，扫描每 128 行/匹配检查一次取消状态，避免
快速改查询时积压过期全量扫描。超长软折逻辑行的增量重扫也会转入后台。

## OSC 133 命令块语义旁路

2026-07-21 在 Apple M4 Pro、macOS 27.0 上对 Release `ink-bench` 运行
Time Profiler。采样覆盖各 10 万行的 reflow、搜索、ASCII 短行、ASCII 满宽、
彩色与中文场景，进程正常退出；trace 时长 1.915 秒，位于
`/tmp/ink-osc133-issue58.trace`，导出表位于
`/tmp/ink-osc133-issue58-time-profile.xml`。

采样仍集中在 `Parser.feed`、`Grid.scrollUp` 与 `ScrollbackBuffer.append`；
没有采到 `pruneSemanticOverflow` 或 `appendSemanticOverflow`。普通输出的语义
旁路表为空，整屏滚动只增加一次空表快速判断。Release 基准的 ASCII 吞吐为
73–82 MB/s，彩色 99 MB/s，中文 125 MB/s；内存数字与既有基线一致。

同行多 OSC 转换才分配旁路项。scrollback 环淘汰用头索引推进，每累计约 256 个
失效项才批量压缩，避免逐行搬数组；小容量环反复 400 次的回归测试同时约束活动
项与滞留前缀，不允许内存随会话时长无限增长。

## 字体度量与增粗

2026-07-21 在 Apple M4 Pro、macOS 27.0、2x 缩放下，对 debug 构建运行
15 秒 Time Profiler。场景为启动 Ink 后保持终端提示符静止，由光标闪烁触发
后续帧；trace 位于 `/tmp/ink-font-metrics.trace`，导出的聚合调用栈位于
`/tmp/ink-font-metrics-time-profile.xml`。

采样在 1.408 秒和 1.940 秒捕获到 `GlyphAtlas.rasterize`，均属于启动后的
字形图集首次填充。2.540 秒至 15.864 秒持续捕获到 `TerminalMetalView.frameTick`
和 `TerminalRenderer.render`，这些稳定帧的调用栈没有再出现
`GlyphAtlas.rasterize` 或 glyph 绘制。整段采样没有出现 `CTLineDraw` 和
`CGContextSetShouldSmoothFonts`。本次证据支持增粗停留在 atlas 未命中的首次
栅格化路径，没有进入稳定帧循环。

`xctrace record` 在达到时限并保存 trace 后返回 54；trace 的目录、TOC 和
`time-profile` 表均可正常导出。TOC 记录的时长为 15.884850 秒，结束原因为
`Time limit reached`。

同日将当前 `.build/arm64-apple-macosx/debug/ink` 原样放入临时 `.app`，使用
ad-hoc 签名和 bundle id `com.cheneychou.ink.font-verify-44` 后通过
Computer Use 启动。终端显示 `/tmp/ink-emoji-44.txt` 时，Maple Mono 文字正常，
🚀、😀 和 👨‍👩‍👧 保持彩色。截图位于 `/tmp/ink-font-verify-44.png`。这次检查只
确认当前 debug 二进制的真实界面与彩色 emoji 路径，不代表和 Ghostty 像素级一致。

## 未完成项

- **120fps 稳定性**：需要 Instruments（Metal System Trace / Time
  Profiler）在真实交互下跑，无法无头验证。步骤：`instruments -t
  "Metal System Trace"` 附加运行中的 ink，全屏 `yes` / `cat` 大文件，
  看帧间隔与 `buildInstances` 耗时。
- 热路径 ARC 抽查：`sample` 显示核心循环无 retain/release 热点，
  正式结论等 Time Profiler。

## URL / OSC 8 链接旁路

2026-07-22 在 Apple M4 Pro、macOS 27.0（26A5388g）上，以 Release
`ink-bench` 连续写入 100 万行、保留 10 万行 scrollback。普通文本共
82,000,000 字节，耗时 1.241378917 秒、吞吐 63.0 MB/s、footprint 增量
12.8 MB；每 1,000 行插入一段 OSC 8 的稀疏场景共 82,041,000 字节，耗时
1.315516666 秒、吞吐 59.5 MB/s、footprint 增量 13.2 MB。原始输出分别位于
`/tmp/ink-links-issue66-plain-final.txt` 和
`/tmp/ink-links-issue66-sparse-osc8-final.txt`。

普通输出仍不创建链接旁路表；只有实际出现 OSC 8 时才保存目标和范围。稀疏
场景相对普通文本耗时增加约 6.0%，1000 个带链接逻辑行增加约 0.4 MB footprint。
链接信息没有进入 cell 或 row 常驻布局，`Cell` 仍为 8 字节，`RowInfo` 仍为
2 字节。

合并前审查另加了同一目标覆盖每一行的 `dense-osc8` 压力场景，专门把 10 万条
范围写满 scrollback 后继续淘汰 90 万行。100 万行共 120,000,000 字节，耗时
9.163607291 秒、吞吐 12.5 MB/s、footprint 增量 44.8 MB，原始输出位于
`/tmp/ink-links-issue66-dense-osc8-final.txt`。该场景验证密集硬换行淘汰使用可推进前缀，
不会每行重建 10 万条记录。基准还提供 `fragmented-osc8`，覆盖同一软折逻辑行
逐 cell 交替两个目标；100 万 cell 耗时 0.714801167 秒、吞吐 46.7 MB/s、
footprint 增量 14.3 MB，顺序追加不会反复复制已有 spans。链接/普通行交替的
`alternating-osc8` 耗时 5.141251416 秒、footprint 增量 27.8 MB；每行唯一目标的
`dense-unique-osc8` 耗时 7.914581833 秒、footprint 增量 42.0 MB，原始输出分别位于
`/tmp/ink-links-issue66-fragmented-osc8-final.txt`、
`/tmp/ink-links-issue66-alternating-osc8-final.txt` 与
`/tmp/ink-links-issue66-dense-unique-osc8-final.txt`。OSC 8 URI
本体另设 8 MB / 65,536 个唯一目标的终端级预算，范围表最多 131,072 条逻辑行记录
和 262,144 个 span。自动 URL 同步查询最多物化 65,536 cells / 2,048 行；显式
OSC 8 先查稀疏索引并有界投影范围端点，超长逻辑行仍能命中且不会构造
cell/scalar 快照；持续软折超出 scrollback 容量时，物理 anchor 单调淘汰并延迟
批量 rebase，不再每行扫描整条保留逻辑行。

同日对普通文本场景运行 Time Profiler，trace 位于
`/tmp/ink-links-issue66-plain.trace`，导出表位于
`/tmp/ink-links-issue66-plain.xml`，TOC 位于
`/tmp/ink-links-issue66-toc.xml`。trace 时长 2.088875 秒，结束原因为
`Target app exited`。采样热点仍集中在 `Terminal.print`、`Parser.feed`、
`ScrollbackLine.init(trimming:)`、`Terminal.scrollRegionUp`、
`ScrollbackBuffer.append` 与 `Grid.scrollUp` / `clearRow`；普通输出采样中没有
出现 `TerminalURLDetector`、`logicalLine(containing:)` 或
`HyperlinkRangeStore`。现有 scrollback 路径仍能看到 retain/release 采样，
本次不据此宣称 ARC 热点已经消失。

同日将当前 debug 二进制放入 bundle id
`com.cheneychou.ink.links-verify-66` 的临时 ad-hoc 签名 App 做真实窗口冒烟。
普通 URL 悬停显示下划线；系统打开处理器收到完整的
`https://example.test/a_(b)`；OSC 8 标签右键复制得到精确目标
`https://openai.com`。窗口放大触发 reflow、追加 200 行再滚回历史后，两个链接
仍可命中并弹出原生菜单。SGR mouse 探针收到普通右键按下序列
`ESC[<2;70;32M`；Option 右键分流由交互路由测试覆盖。截图位于
`/tmp/ink-links-issue66-smoke.jpeg`。临时 App 与探针已移入废纸篓，没有改动已
安装的 Ink。

## 标签内分屏

Issue #29 引入递归权重分屏容器，每个可见 pane 使用独立的
`TerminalMetalView`。2026-07-20 在 MacBook Pro、macOS 27.0、2x 缩放、
1280 × 800 窗口下做了第一次对比。测试应用为当前分支的 debug 构建，经过
临时 ad-hoc 签名，并由 Computer Use 持续截图；下面的绝对值不能与 release
基线直接比较，只看同一进程内增加 pane 前后的差值。

| 场景 | Footprint | 相对 1 pane | Graphics unmapped | IOSurface |
|---|---:|---:|---:|---:|
| 1 pane 空闲 | 157 MB | - | 98 MB | 16 MB |
| 4 pane 空闲 | 193 MB | +36 MB | 99 MB | 16 MB |

窗口 surface 总量没有随 pane 数量成倍增长。增量主要来自三套额外的 glyph
atlas、renderer 和 Metal 驱动对象：Malloc Small 从 16 MB 增至 30 MB，
IOAccelerator 从 8 MB 增至 20 MB，其余 owned physical footprint 约增加
5.5 MB。三个额外 pane 平均约 12 MB，符合最多四个常用 pane 的设计预算。

交互验证覆盖了左右分屏、在右侧继续向下分屏、四 pane 嵌套、可拖动
divider，以及连续 `Command-W` 从 3 pane 收拢到 2、1，最后关闭标签和窗口。

性能采样在四 pane 可见、活动 pane 运行 `yes` 的条件下各记录 5 秒：

- Time Profiler 采样的主要栈仍在 `Parser.feed`、`Grid.scrollUp` 和
  `ScrollbackBuffer.append`，没有分屏布局函数进入输出热路径。
- Metal System Trace 成功记录完整区间，trace 大小 180 MB。此次没有同时给
  四个 pane 注入高速输出，因此不能据此宣称四路输出稳定 120 fps；四路压力
  测试仍属于未完成项。
