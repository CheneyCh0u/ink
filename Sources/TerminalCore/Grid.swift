/// 屏上网格：`rows × cols` 一整块连续内存，行主序。
///
/// 热路径纪律：subscript 与行访问是每帧调用的路径，全部 `@inline(__always)`
/// 位移寻址，不做多余边界检查之外的任何工作。
public struct Grid: Sendable {
    public private(set) var size: TerminalSize
    public var cursorRow: Int
    public var cursorCol: Int

    private var cells: ContiguousArray<Cell>
    private var rowInfo: ContiguousArray<RowInfo>

    public init(size: TerminalSize) {
        self.size = size
        self.cursorRow = 0
        self.cursorCol = 0
        self.cells = ContiguousArray(repeating: .blank, count: size.columns * size.rows)
        self.rowInfo = ContiguousArray(repeating: .none, count: size.rows)
    }

    // MARK: - 访问

    @inline(__always)
    public subscript(row: Int, col: Int) -> Cell {
        get { cells[row * size.columns + col] }
        set { cells[row * size.columns + col] = newValue }
    }

    @inline(__always)
    public func info(ofRow row: Int) -> RowInfo { rowInfo[row] }

    @inline(__always)
    public mutating func setInfo(_ info: RowInfo, forRow row: Int) { rowInfo[row] = info }

    /// 整行只读切片，渲染器逐行取用。
    @inline(__always)
    public func row(_ row: Int) -> ArraySlice<Cell> {
        let start = row * size.columns
        return cells[start..<(start + size.columns)]
    }

    // MARK: - 行编辑

    public mutating func clearRow(_ row: Int) {
        let start = row * size.columns
        for i in start..<(start + size.columns) {
            cells[i] = .blank
        }
        rowInfo[row] = .none
    }

    public mutating func clearAll() {
        for i in cells.indices { cells[i] = .blank }
        for i in rowInfo.indices { rowInfo[i] = .none }
    }

    /// 向上滚一行：第 0 行滚出（返回给调用方送 scrollback），其余整体上移，
    /// 底行清空。整块 memmove，不逐 cell 拷。
    @discardableResult
    public mutating func scrollUp() -> ScrollbackLine {
        let evicted = ScrollbackLine(trimming: row(0), info: rowInfo[0])
        let cols = size.columns
        cells.withUnsafeMutableBufferPointer { buf in
            buf.baseAddress!.update(from: buf.baseAddress! + cols, count: cols * (size.rows - 1))
        }
        for i in ((size.rows - 1) * cols)..<(size.rows * cols) {
            cells[i] = .blank
        }
        rowInfo.removeFirst()
        rowInfo.append(.none)
        return evicted
    }

    // MARK: - resize

    /// 重建缓冲逐行拷贝。P0 语义：变窄截断、变宽补空白，不做 reflow
    /// （roadmap：reflow 是 M6，依赖 RowInfo.wrapped）。
    public mutating func resize(to newSize: TerminalSize) {
        guard newSize != size else { return }
        var newCells = ContiguousArray<Cell>(repeating: .blank, count: newSize.columns * newSize.rows)
        var newInfo = ContiguousArray<RowInfo>(repeating: .none, count: newSize.rows)

        let copyRows = min(size.rows, newSize.rows)
        let copyCols = min(size.columns, newSize.columns)
        for r in 0..<copyRows {
            for c in 0..<copyCols {
                newCells[r * newSize.columns + c] = cells[r * size.columns + c]
            }
            newInfo[r] = rowInfo[r]
        }

        cells = newCells
        rowInfo = newInfo
        size = newSize
        cursorRow = min(cursorRow, newSize.rows - 1)
        cursorCol = min(cursorCol, newSize.columns - 1)
    }
}
