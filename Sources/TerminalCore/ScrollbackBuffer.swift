/// 一条历史行：裁掉尾部空白后按实际宽度存储。
///
/// 内存纪律的第一道闸：终端 200 列宽、`ls` 平均行长 40 列时，trim 直接省 5 倍，
/// 先于任何压缩生效（算账见 docs/grid-design.md）。M6 的压缩在本类型内部换
/// 存储格式，对外接口不变。
public struct ScrollbackLine: Sendable, Equatable {
    public let cells: ContiguousArray<Cell>
    public let info: RowInfo

    /// 从满宽行裁尾入库。
    public init(trimming row: ArraySlice<Cell>, info: RowInfo) {
        var end = row.endIndex
        while end > row.startIndex, row[end - 1].isBlank {
            end -= 1
        }
        self.cells = ContiguousArray(row[row.startIndex..<end])
        self.info = info
    }

    public init(cells: ContiguousArray<Cell>, info: RowInfo) {
        self.cells = cells
        self.info = info
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
    public let capacity: Int

    public init(capacity: Int) {
        precondition(capacity > 0, "scrollback 容量必须为正")
        self.capacity = capacity
        // 预留桶但不预填行——空终端不该为 10 万行上限付一分钱内存。
        self.lines = ContiguousArray(repeating: nil, count: capacity)
    }

    public mutating func append(_ line: ScrollbackLine) {
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
    }
}
