/// 一条历史行：裁掉尾部空白后按实际宽度存储。
///
/// 内存纪律的两道闸（算账见 docs/grid-design.md）：
/// 1. **裁尾**：终端 200 列宽、`ls` 平均行长 40 列，先省 5 倍
/// 2. **ASCII 压缩**：全默认属性的纯 ASCII 行（历史行的绝大多数）退化成
///    1 字节/格，比 8 字节的 `Cell` 再省 8 倍
///
/// 存储格式是内部细节，读取走 `count` + `cell(at:)`，渲染器逐格取用不
/// 物化数组。
public struct ScrollbackLine: Sendable {
    private enum Storage: Sendable {
        /// 任意内容：完整 Cell。
        case plain(ContiguousArray<Cell>)
        /// 全默认属性纯 ASCII（0x20–0x7E）：只存字节。
        case ascii(ContiguousArray<UInt8>)
    }

    private let storage: Storage
    public let info: RowInfo

    /// 从满宽行裁尾入库，顺路判断能否走 ASCII 紧凑格式。
    public init(trimming row: ArraySlice<Cell>, info: RowInfo) {
        var end = row.endIndex
        while end > row.startIndex, row[end - 1].isBlank {
            end -= 1
        }
        let trimmed = row[row.startIndex..<end]

        var qualifiesASCII = true
        for cell in trimmed {
            if cell.attr != Cell.Attr.default || cell.scalar < 0x20 || cell.scalar > 0x7E {
                qualifiesASCII = false
                break
            }
        }

        if qualifiesASCII {
            var bytes = ContiguousArray<UInt8>()
            bytes.reserveCapacity(trimmed.count)
            for cell in trimmed {
                bytes.append(UInt8(cell.scalar))
            }
            storage = .ascii(bytes)
        } else {
            storage = .plain(ContiguousArray(trimmed))
        }
        self.info = info
    }

    public init(cells: ContiguousArray<Cell>, info: RowInfo) {
        storage = .plain(cells)
        self.info = info
    }

    @inline(__always)
    public var count: Int {
        switch storage {
        case .plain(let cells): cells.count
        case .ascii(let bytes): bytes.count
        }
    }

    /// 渲染热路径：逐格取，不物化数组。
    @inline(__always)
    public func cell(at index: Int) -> Cell {
        switch storage {
        case .plain(let cells): cells[index]
        case .ascii(let bytes): Cell(scalar: UInt32(bytes[index]))
        }
    }

    /// 物化整行（选区提取等冷路径用）。
    public var cells: [Cell] {
        (0..<count).map(cell(at:))
    }
}

extension ScrollbackLine: Equatable {
    public static func == (lhs: ScrollbackLine, rhs: ScrollbackLine) -> Bool {
        lhs.info == rhs.info && lhs.count == rhs.count
            && (0..<lhs.count).allSatisfy { lhs.cell(at: $0) == rhs.cell(at: $0) }
    }
}

/// 历史行环形缓冲：容量固定，满了覆盖最旧的行。
///
/// 手写环形结构而不引 swift-collections 的 Deque：新依赖需要理由（CLAUDE.md），
/// 一个头索引加计数不构成理由。
public struct ScrollbackBuffer: Sendable {
    private var lines: ContiguousArray<ScrollbackLine?>
    private var head = 0
    public private(set) var count = 0
    /// 自上次清空以来累计入库的物理行数；搜索索引用它识别可变后缀。
    public private(set) var totalAppendedLines: UInt64 = 0
    public let capacity: Int

    public init(capacity: Int) {
        precondition(capacity > 0, "scrollback 容量必须为正")
        self.capacity = capacity
        // 预留桶但不预填行——空终端不该为 10 万行上限付一分钱内存。
        self.lines = ContiguousArray(repeating: nil, count: capacity)
    }

    public mutating func append(_ line: ScrollbackLine) {
        totalAppendedLines &+= 1
        lines[(head + count) % capacity] = line
        if count < capacity {
            count += 1
        } else {
            head = (head + 1) % capacity
        }
    }

    /// 0 是最旧的一行，`count - 1` 最新。
    @inline(__always)
    public subscript(index: Int) -> ScrollbackLine {
        lines[(head + index) % capacity]!
    }

    public mutating func removeAll() {
        for i in lines.indices { lines[i] = nil }
        head = 0
        count = 0
        totalAppendedLines = 0
    }
}
