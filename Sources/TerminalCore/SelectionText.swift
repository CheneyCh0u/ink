/// 选区坐标与文本提取。
///
/// 坐标用**绝对行号**：0 是 scrollback 最旧的一行，`scrollback.count + r`
/// 是屏上第 r 行。行从 grid 滚入 scrollback 时绝对行号不变，选区跟着内容
/// 走，不需要滚动补偿。（环形缓冲覆盖最旧行时会整体漂移——那是 10 万行
/// 打满之后的事，选区活不到那时候。）
public struct TextPosition: Sendable, Equatable, Comparable {
    public var line: Int
    public var column: Int

    public init(line: Int, column: Int) {
        self.line = line
        self.column = column
    }

    public static func < (lhs: TextPosition, rhs: TextPosition) -> Bool {
        (lhs.line, lhs.column) < (rhs.line, rhs.column)
    }
}

/// 一段选区。`block` 为真时是 Option 矩形选择。
public struct SelectionRange: Sendable, Equatable {
    public var start: TextPosition
    public var end: TextPosition
    public var block: Bool

    public init(start: TextPosition, end: TextPosition, block: Bool = false) {
        self.start = start
        self.end = end
        self.block = block
    }

    /// 归一化：start ≤ end。
    public var normalized: SelectionRange {
        start <= end
            ? self
            : SelectionRange(start: end, end: start, block: block)
    }

    public func contains(line: Int, column: Int) -> Bool {
        let n = normalized
        if block {
            let cols = min(n.start.column, n.end.column)...max(n.start.column, n.end.column)
            return (n.start.line...n.end.line).contains(line) && cols.contains(column)
        }
        if line < n.start.line || line > n.end.line { return false }
        if n.start.line == n.end.line {
            return column >= n.start.column && column <= n.end.column
        }
        if line == n.start.line { return column >= n.start.column }
        if line == n.end.line { return column <= n.end.column }
        return true
    }
}

extension Terminal {
    /// scrollback + 屏上的总行数。
    public var totalLines: Int { scrollback.count + grid.size.rows }

    /// 绝对行的 cell 序列（scrollback 行已裁尾，可能短于屏宽）与元数据。
    public func absoluteLine(_ index: Int) -> (cells: [Cell], info: RowInfo)? {
        guard index >= 0, index < totalLines else { return nil }
        if index < scrollback.count {
            let line = scrollback[index]
            return (Array(line.cells), line.info)
        }
        return (Array(grid.row(index - scrollback.count)), grid.info(ofRow: index - scrollback.count))
    }

    /// 提取选区文本。软折行（wrapped）的相邻行拼接时不插换行——
    /// 复制一条被折成三行的长命令，粘出来是一行，这是 trim + wrapped 位
    /// 一路留到现在换来的。
    public func extractText(in selection: SelectionRange) -> String {
        let sel = selection.normalized
        var out = ""
        let lastLine = min(sel.end.line, totalLines - 1)
        guard sel.start.line <= lastLine else { return out }

        for lineIndex in sel.start.line...lastLine {
            guard let (cells, _) = absoluteLine(lineIndex) else { continue }

            let colRange: ClosedRange<Int>
            if sel.block {
                colRange = min(sel.start.column, sel.end.column)...max(sel.start.column, sel.end.column)
            } else {
                let from = lineIndex == sel.start.line ? sel.start.column : 0
                let to = lineIndex == sel.end.line ? sel.end.column : Int.max
                guard from <= to else { continue }
                colRange = from...to
            }

            var lineText = ""
            var trailingBlanks = 0
            for col in colRange {
                guard col < cells.count else { break }
                let cell = cells[col]
                if cell.attr & Cell.Attr.wideTrailing != 0 { continue }
                if cell.isBlank {
                    trailingBlanks += 1
                    lineText.unicodeScalars.append(" ")
                    continue
                }
                trailingBlanks = 0
                if cell.isCluster {
                    for scalar in clusterTable.scalars(for: cell.scalar) {
                        lineText.unicodeScalars.append(Unicode.Scalar(scalar) ?? "\u{FFFD}")
                    }
                } else {
                    lineText.unicodeScalars.append(Unicode.Scalar(cell.scalar) ?? "\u{FFFD}")
                }
            }
            if trailingBlanks > 0 {
                lineText.removeLast(trailingBlanks)
            }
            out += lineText

            if lineIndex < lastLine {
                let nextWrapped = absoluteLine(lineIndex + 1)?.info.isWrapped ?? false
                if sel.block || !nextWrapped {
                    out += "\n"
                }
            }
        }
        return out
    }

    /// 双击选词：返回该位置所在词的列范围。词字符集偏向路径与标识符，
    /// 这样双击能整选文件路径和变量名。
    public func wordColumns(at position: TextPosition) -> ClosedRange<Int>? {
        guard let (cells, _) = absoluteLine(position.line), !cells.isEmpty else { return nil }
        let col = min(position.column, cells.count - 1)
        guard col >= 0, isWordCell(cells[col]) else { return nil }

        var lo = col
        while lo > 0, isWordCell(cells[lo - 1]) { lo -= 1 }
        var hi = col
        while hi + 1 < cells.count, isWordCell(cells[hi + 1]) { hi += 1 }
        return lo...hi
    }

    private func isWordCell(_ cell: Cell) -> Bool {
        if cell.attr & Cell.Attr.wideTrailing != 0 { return true } // 尾格跟随首格
        if cell.isCluster { return true }
        let s = cell.scalar
        switch s {
        case UInt32(UnicodeScalar("a").value)...UInt32(UnicodeScalar("z").value),
             UInt32(UnicodeScalar("A").value)...UInt32(UnicodeScalar("Z").value),
             UInt32(UnicodeScalar("0").value)...UInt32(UnicodeScalar("9").value):
            return true
        case UInt32(UnicodeScalar("_").value), UInt32(UnicodeScalar("-").value),
             UInt32(UnicodeScalar(".").value), UInt32(UnicodeScalar("/").value),
             UInt32(UnicodeScalar("~").value):
            return true
        default:
            return s > 0x7F && !(s == 0x20) // 非 ASCII（中文等）算词字符
        }
    }
}
