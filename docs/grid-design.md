# Grid 与 Scrollback 数据结构设计

任务 #4 的决策记录。约束来自 CLAUDE.md 的热路径与内存纪律：单 cell ≤ 8 字节、
连续内存、行不补齐尾部空白、为 reflow 和 OSC 133 预留位置。

## Cell：8 字节定死

```
┌──────────── scalar: UInt32 ────────────┐┌───────────── attr: UInt32 ─────────────┐
│ bit 31: 组合簇标记（低位变簇表索引）      ││ 0-10  fg（11 位）                       │
│ bit 0-20: Unicode scalar               ││ 11-21 bg（11 位）                       │
│                                        ││ 22-29 样式位：粗/淡/斜/下划线/闪烁/      │
│                                        ││       反显/隐藏/删除线                   │
│                                        ││ 30 宽字符首格   31 宽字符尾格            │
└────────────────────────────────────────┘└────────────────────────────────────────┘
```

`MemoryLayout<Cell>.stride == 8`，测试里断言，谁改破了 CI 直接红。

### 颜色：11 位编码 + 旁路表

- `0–255`：调色板索引（16 ANSI + 240 xterm 立方/灰阶）
- `256`：默认色（前景/背景各自的语义默认，渲染时才解析成主题色）
- `257–2047`：真彩色旁路表索引（容量 1791 个**去重后的** RGB）

真彩色不进 cell，进 `ColorTable`（终端级、去重）。同屏 + scrollback 超过 1791 个
不同 RGB 时（基本只有 lolcat / 渐变艺术字能做到），新颜色降级为最近的 256 色。
这是「内存优先」的明确取舍，记录在案。

### 组合字符：旁路簇表

绝大多数 cell 是单 scalar。带变音符 / ZWJ 序列的 cell 把 `scalar` 的 bit 31
置位，低位改存簇表索引，完整序列存在 `ClusterTable`。M3 字符宽度任务实现，
这里只保留标记位语义。

## 行元数据：RowInfo（2 字节 / 行）

```
bit 0       wrapped（本行是上一行的软折行延续）
bit 1...2   OSC 133 当前语义：0 无 / 1 prompt / 2 command / 3 output
bit 3...15  可选的语义转换列 + 1；0 表示整行继承当前语义
```

- **`wrapped` 就是 reflow 的预留**：真折行（用户敲了回车）与软折行（到列宽被
  折）在数据里可区分，M6 做 reflow 时把连续的 wrapped 行拼回逻辑行重新折即可。
  没有这一位，历史行拼不回去，reflow 无从谈起。
- **语义与转换列就是 OSC 133 的落点**：同一行可以精确区分提示符与命令，
  reflow 时转换列随逻辑内容映射到新的物理行。全部信息仍压在 2 字节内，10 万行
  历史不增加常驻开销。极少数同一物理行连续出现多个转换时，较早的必要转换进入
  终端级稀疏旁路表；不复制命令文本，也不给普通行增加字段。

## Grid：屏上区域

```swift
struct Grid {
    cells:   ContiguousArray<Cell>     // rows × cols，行主序，一整块
    rowInfo: ContiguousArray<RowInfo>
    size:    TerminalSize
    cursor:  (row, col)
}
```

- 单块连续内存，`(row, col)` 直接算偏移。禁 `Array<Array<T>>`（CLAUDE.md）
- resize 重建缓冲，逐行拷贝旧内容；顶部滚出的行交给 scrollback
- 屏上区域**按满宽存储**（终端语义天然如此），「不补齐尾部空白」只对
  scrollback 生效——历史行才是 10 万行的大头

## Scrollback：历史区域

```swift
struct ScrollbackLine {
    cells: ContiguousArray<Cell>   // 裁掉尾部默认 cell，按实际宽度存
    info:  RowInfo
}
struct ScrollbackBuffer   // 环形缓冲，容量固定，满了覆盖最旧
```

- 入库时 `trimTrailingDefault`：`ls` 输出平均行长 ~40 列、终端 200 列宽时，
  这一步就是 5 倍差距，比任何压缩都先赚到
- 环形缓冲手写（头索引 + 计数），不引 swift-collections——新依赖要理由，
  一个 Deque 不构成理由
- M6 的压缩（纯 ASCII 行紧凑表示）在 `ScrollbackLine` 内部换存储格式，
  对外接口不变

## 算一遍 10 万行

最坏情况（每行都是满 200 列非默认内容）：200 × 8 B × 100k = 160 MB < 200 MB ✓
真实情况（平均 40 列）：40 × 8 B × 100k ≈ 32 MB + 行头开销 ≈ 37 MB。
M6 压缩把 ASCII 行的 8 B/cell 再往下压，是锦上添花而不是达标前提——
**达标靠的是 trim，这就是它为什么在 P0 就做**。
