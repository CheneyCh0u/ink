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

## 未完成项

- **120fps 稳定性**：需要 Instruments（Metal System Trace / Time
  Profiler）在真实交互下跑，无法无头验证。步骤：`instruments -t
  "Metal System Trace"` 附加运行中的 ink，全屏 `yes` / `cat` 大文件，
  看帧间隔与 `buildInstances` 耗时。
- 热路径 ARC 抽查：`sample` 显示核心循环无 retain/release 热点，
  正式结论等 Time Profiler。
