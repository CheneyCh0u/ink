/// 屏上网格：`rows × cols` 一整块连续内存，行主序 + **环形行索引**。
///
/// 整屏滚动是终端最热的操作（每个 LF 一次）。平铺存储下滚动要 memmove
/// 整屏（50×200 cell ≈ 80KB，`cat` 十万行就是 8GB 搬运）；环形行索引把
/// 它变成转一下 `firstRow` + 清一行，零搬运。每行内部仍然连续，渲染器
/// 逐行取 slice 无感。
///
/// 热路径纪律：subscript 与行访问是每帧调用的路径，全部 `@inline(__always)`，
/// 环形映射用加法 + 条件减，不用取模除法。
public struct Grid: Sendable {
    public private(set) var size: TerminalSize
    public var cursorRow: Int
    public var cursorCol: Int

    private var cells: ContiguousArray<Cell>
    private var rowInfo: ContiguousArray<RowInfo>
    /// 逻辑第 0 行对应的物理行。
    private var firstRow = 0

    public init(size: TerminalSize) {
        self.size = size
        self.cursorRow = 0
        self.cursorCol = 0
        self.cells = ContiguousArray(repeating: .blank, count: size.columns * size.rows)
        self.rowInfo = ContiguousArray(repeating: .none, count: size.rows)
    }

    /// 逻辑行 → 物理行。
    @inline(__always)
    private func phys(_ row: Int) -> Int {
        var r = firstRow + row
        if r >= size.rows { r -= size.rows }
        return r
    }

    // MARK: - 访问

    @inline(__always)
    public subscript(row: Int, col: Int) -> Cell {
        get { cells[phys(row) * size.columns + col] }
        set { cells[phys(row) * size.columns + col] = newValue }
    }

    @inline(__always)
    public func info(ofRow row: Int) -> RowInfo { rowInfo[phys(row)] }

    @inline(__always)
    public mutating func setInfo(_ info: RowInfo, forRow row: Int) { rowInfo[phys(row)] = info }

    /// 整行只读切片，渲染器逐行取用。行内连续。
    @inline(__always)
    public func row(_ row: Int) -> ArraySlice<Cell> {
        let start = phys(row) * size.columns
        return cells[start..<(start + size.columns)]
    }

    // MARK: - 行编辑

    public mutating func clearRow(_ row: Int) {
        let start = phys(row) * size.columns
        for i in start..<(start + size.columns) {
            cells[i] = .blank
        }
        rowInfo[phys(row)] = .none
    }

    public mutating func clearAll() {
        for i in cells.indices { cells[i] = .blank }
        for i in rowInfo.indices { rowInfo[i] = .none }
        firstRow = 0
    }

    /// 向上滚一行：整屏滚动的便捷入口。
    @discardableResult
    public mutating func scrollUp() -> ScrollbackLine {
        scrollUp(top: 0, bottom: size.rows - 1)
    }

    /// 区域内向上滚一行（`top`/`bottom` 均含）：顶行滚出返回（是否入
    /// scrollback 由调用方定）。整屏走环形快路径（零搬运）；
    /// 部分区域（vim 分屏等，低频）逐行拷。
    @discardableResult
    public mutating func scrollUp(top: Int, bottom: Int) -> ScrollbackLine {
        let evicted = ScrollbackLine(trimming: row(top), info: info(ofRow: top))
        if top == 0, bottom == size.rows - 1 {
            clearRow(0)
            firstRow = phys(1)
        } else {
            for r in top..<bottom {
                copyRow(from: r + 1, to: r)
            }
            clearRow(bottom)
        }
        return evicted
    }

    /// 区域内向下滚一行：底行丢弃，顶行清空。RI / SD / IL 用。
    public mutating func scrollDown(top: Int, bottom: Int) {
        if top == 0, bottom == size.rows - 1 {
            firstRow -= 1
            if firstRow < 0 { firstRow += size.rows }
            clearRow(0)
        } else {
            var r = bottom
            while r > top {
                copyRow(from: r - 1, to: r)
                r -= 1
            }
            clearRow(top)
        }
    }

    @inline(__always)
    private mutating func copyRow(from src: Int, to dst: Int) {
        let cols = size.columns
        let s = phys(src) * cols
        let d = phys(dst) * cols
        cells.withUnsafeMutableBufferPointer { buf in
            (buf.baseAddress! + d).update(from: buf.baseAddress! + s, count: cols)
        }
        rowInfo[phys(dst)] = rowInfo[phys(src)]
    }

    // MARK: - resize

    /// 重建缓冲逐行拷贝（顺带把环展平）。P0 语义：变窄截断、变宽补空白，
    /// 不做 reflow（roadmap：reflow 是 M6，依赖 RowInfo.wrapped）。
    public mutating func resize(to newSize: TerminalSize) {
        guard newSize != size else { return }
        var newCells = ContiguousArray<Cell>(repeating: .blank, count: newSize.columns * newSize.rows)
        var newInfo = ContiguousArray<RowInfo>(repeating: .none, count: newSize.rows)

        let copyRows = min(size.rows, newSize.rows)
        let copyCols = min(size.columns, newSize.columns)
        for r in 0..<copyRows {
            for c in 0..<copyCols {
                newCells[r * newSize.columns + c] = self[r, c]
            }
            newInfo[r] = info(ofRow: r)
        }

        cells = newCells
        rowInfo = newInfo
        size = newSize
        firstRow = 0
        cursorRow = min(cursorRow, newSize.rows - 1)
        cursorCol = min(cursorCol, newSize.columns - 1)
    }
}
