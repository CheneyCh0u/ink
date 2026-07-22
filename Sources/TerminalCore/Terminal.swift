struct SemanticOverflowTransition: Sendable {
    let lineID: UInt64
    let column: UInt16
    let mark: SemanticMark

    init(lineID: UInt64, column: Int, mark: SemanticMark) {
        self.lineID = lineID
        self.column = UInt16(clamping: column)
        self.mark = mark
    }
}

struct PhysicalHyperlinkFragment: Sendable, Equatable {
    var row: Int
    var columns: Range<Int>
    var target: String
}

/// 终端语义层：消费 `Parser` 的动作，维护 grid、scrollback、光标与模式。
///
/// 纯 Swift 值类型，不依赖任何 UI——VT 兼容性全部在这里用单元测试验证
/// （CLAUDE.md 分层纪律）。
public struct Terminal: Sendable {

    // MARK: - 状态

    public struct Modes: Sendable, Equatable {
        /// DECAWM（?7）：到行尾自动折行。
        public var autowrap = true
        /// DECTCEM（?25）：光标可见。
        public var showCursor = true
        /// DECCKM（?1）：方向键发 SS3 前缀（vim 等全屏应用开启）。
        public var applicationCursorKeys = false
        /// DECOM（?6）：光标定位相对滚动区域。
        public var originMode = false
        /// xterm 2004：bracketed paste。输入侧（任务 #11）读它决定是否加包裹。
        public var bracketedPaste = false
        /// 备用屏激活中（?1049 / ?47 / ?1047）。
        public var alternateScreen = false
        /// 鼠标上报级别（?1000 点击 / ?1002 拖拽 / ?1003 全部移动）。
        public var mouseMode: MouseMode = .none
        /// ?1006：SGR 鼠标编码（现代应用都请求它，无 223 列限制）。
        public var sgrMouse = false
        /// ?1007：备用屏内滚轮转方向键（less / vim 无鼠标模式也能滚）。
        public var alternateScroll = true
    }

    public enum MouseMode: Sendable, Equatable {
        case none, click, drag, any
    }

    public private(set) var grid: Grid
    public private(set) var scrollback: ScrollbackBuffer
    public private(set) var colorTable = ColorTable()
    public private(set) var clusterTable = ClusterTable()
    public private(set) var modes = Modes()
    /// reflow、备用屏切换等整体改变行坐标的代次。
    public private(set) var searchLayoutRevision: UInt64 = 0
    /// OSC 0 / 2 设置的窗口标题。
    public private(set) var title = ""
    /// OSC 133 当前段落语义，新行产生时自动继承（详见任务 #8）。
    public private(set) var currentSemantic: SemanticMark = .none
    /// 同一物理行出现多个 OSC 133 转换时，只把被覆盖且无法推导的早期点
    /// 放进稀疏旁路表；常规每行单转换仍完全落在 2 字节 RowInfo 内。
    var semanticOverflowTransitions: [SemanticOverflowTransition] = []
    var semanticOverflowStart = 0
    /// OSC 8 只为实际目标与范围分配旁路状态；普通终端保持三个 nil。
    var hyperlinkTargets: HyperlinkTargetTable?
    var hyperlinks: HyperlinkRangeStore?
    var activeHyperlinkTargetID: UInt32?
    var savedPrimaryHyperlinks: HyperlinkRangeStore?
    /// 待写回 PTY 的应答（DSR / DA 等查询的回复）。TUI 启动时会探测终端
    /// 并**等待回音**，没有应答通道它们会直接卡死。会话层每次 feed 后取走。
    private var responseBuffer: [UInt8] = []
    private var commandStartedAt: ContinuousClock.Instant?
    private var commandCompletionRecords: ContiguousArray<CommandCompletionRecord> = []
    private var commandCompletionStart = 0
    private var pendingEvents: ContiguousArray<TerminalEvent> = []

    private var currentAttr = Cell.Attr.default
    /// 延迟折行：写满最后一列后光标停在原地，下一个可打印字符才真正折行。
    /// vttest 会验这个行为，少了它满屏输出会多出空行。
    private var pendingWrap = false
    /// 刚收到 ZWJ：下一个可打印码点并入前一个簇而不是开新格。
    private var pendingJoin = false
    private var scrollTop = 0
    private var scrollBottom: Int
    private var savedCursor: (row: Int, col: Int, attr: UInt32)?
    /// 备用屏切换时保存的主屏。备用屏不入 scrollback。
    private var savedPrimaryGrid: Grid?

    public init(size: TerminalSize, scrollbackCapacity: Int = 100_000) {
        self.grid = Grid(size: size)
        self.scrollback = ScrollbackBuffer(capacity: scrollbackCapacity)
        self.scrollBottom = size.rows - 1
    }

    /// 后台搜索只读取 cell、行信息与簇表；主动剥离链接旁路，避免搜索任务持有
    /// 10 万条链接记录并让前台后续写入触发整表 COW。
    public func snapshotForSearch() -> Terminal {
        var snapshot = self
        snapshot.hyperlinkTargets = nil
        snapshot.hyperlinks = nil
        snapshot.activeHyperlinkTargetID = nil
        snapshot.savedPrimaryHyperlinks = nil
        return snapshot
    }

    // MARK: - 对外入口

    /// 尺寸变更。滚动区域重置为整屏（xterm 行为）。
    /// 主屏走 reflow（历史行按新宽度重折）；备用屏直接裁剪——vim 等
    /// 全屏应用收到 SIGWINCH 自己重画，reflow 反而画蛇添足。
    /// 喂字节的入口在调用方：`parser.feed(data, handler: &terminal)`，
    /// Parser 的词法状态跨 read 边界，必须由外部持有。
    public mutating func resize(to newSize: TerminalSize) {
        guard newSize != grid.size else { return }
        defer {
            scrollTop = 0
            scrollBottom = newSize.rows - 1
            pendingWrap = false
        }
        if modes.alternateScreen {
            resizeSavedPrimaryGridAndHyperlinks(to: newSize)
            resizeCurrentGridAndHyperlinks(to: newSize)
        } else {
            reflow(to: newSize)
        }
        searchLayoutRevision &+= 1
    }

    private mutating func resizeCurrentGridAndHyperlinks(to newSize: TerminalSize) {
        let fragments = hyperlinkFragments(in: 0...(grid.size.rows - 1))
        for row in 0..<grid.size.rows {
            clearHyperlinkCells(row: row, columns: 0..<grid.size.columns)
        }
        grid.resize(to: newSize)
        for var fragment in fragments where fragment.row < newSize.rows {
            fragment.columns = fragment.columns.clamped(to: 0..<newSize.columns)
            if !fragment.columns.isEmpty { insertHyperlinkFragment(fragment) }
        }
    }

    private mutating func resizeSavedPrimaryGridAndHyperlinks(to newSize: TerminalSize) {
        guard let primaryGrid = savedPrimaryGrid else { return }
        let alternateGrid = grid
        let alternateHyperlinks = hyperlinks
        grid = primaryGrid
        hyperlinks = savedPrimaryHyperlinks
        resizeCurrentGridAndHyperlinks(to: newSize)
        savedPrimaryGrid = grid
        savedPrimaryHyperlinks = hyperlinks
        grid = alternateGrid
        hyperlinks = alternateHyperlinks
    }

    // MARK: - Reflow

    /// 把 scrollback + 屏上行按 `wrapped` 位拼回逻辑行，按新列宽重切，
    /// 尾部 `rows` 行回屏幕、其余入 scrollback，光标按逻辑偏移映射。
    /// 流式处理：一次只持有一条逻辑行，不整体物化十万行。
    private mutating func reflow(to newSize: TerminalSize) {
        let oldGrid = grid
        let oldSb = scrollback
        let oldOverflow = semanticOverflowTransitions[semanticOverflowStart...]
        let oldCompletions = liveCommandCompletionRecords
        let sbCount = oldSb.count
        let totalRows = sbCount + oldGrid.size.rows
        let cursorAbs = sbCount + oldGrid.cursorRow
        let newCols = newSize.columns
        let newRows = newSize.rows

        var newSb = ScrollbackBuffer(capacity: oldSb.capacity)
        // 尾部滑窗：最后 newRows 行留给屏幕，更早的滑入 scrollback。
        var tailCells: [[Cell]] = []
        var tailInfo: [RowInfo] = []
        var emitted = 0
        var newCursor: (abs: Int, col: Int)?
        var newOverflow: [SemanticOverflowTransition] = []
        var newCompletions = ContiguousArray<CommandCompletionRecord>()

        let oldestOldLineID = oldSb.totalAppendedLines - UInt64(oldSb.count)
        var hyperlinkHeadMapping: [
            UInt64: (
                headLineID: UInt64,
                cellCount: UInt32,
                removedGaps: ContiguousArray<HyperlinkRemovedGap>
            )
        ]? = hyperlinks == nil ? nil : [:]
        var reflowHyperlinkLines: [UInt64: TerminalLogicalLine]? = hyperlinks == nil ? nil : [:]
        var overflowByAbsoluteLine: [Int: [SemanticOverflowTransition]] = [:]
        for transition in oldOverflow where transition.lineID >= oldestOldLineID {
            let line = Int(transition.lineID - oldestOldLineID)
            guard line < totalRows else { continue }
            overflowByAbsoluteLine[line, default: []].append(transition)
        }
        var completionsByAbsoluteLine: [Int: [CommandCompletionRecord]] = [:]
        for record in oldCompletions where record.lineID >= oldestOldLineID {
            let line = Int(record.lineID - oldestOldLineID)
            guard line < totalRows else { continue }
            completionsByAbsoluteLine[line, default: []].append(record)
        }

        func emitRow(_ cells: [Cell], _ info: RowInfo) {
            if tailCells.count == newRows {
                let cells = tailCells.removeFirst()
                let info = tailInfo.removeFirst()
                newSb.append(ScrollbackLine(trimming: cells[...], info: info))
            }
            tailCells.append(cells)
            tailInfo.append(info)
            emitted += 1
        }

        func sourceRow(_ abs: Int) -> ([Cell], RowInfo) {
            if abs < sbCount {
                let line = oldSb[abs]
                return (line.cells, line.info)
            }
            let r = abs - sbCount
            var cells = Array(oldGrid.row(r))
            while let last = cells.last, last.isBlank {
                cells.removeLast()
            }
            return (cells, oldGrid.info(ofRow: r))
        }

        // 屏幕底部光标以下的全空行只是留白，不是内容——参与 reflow 会把
        // 真内容顶进 scrollback。从尾巴往前掐掉它们（光标行必须保留）。
        var effectiveTotal = totalRows
        while effectiveTotal - 1 > cursorAbs, effectiveTotal - 1 >= sbCount {
            let r = effectiveTotal - 1 - sbCount
            let rowIsEmpty = oldGrid.row(r).allSatisfy(\.isBlank)
                && !oldGrid.info(ofRow: r).isWrapped
            guard rowIsEmpty else { break }
            effectiveTotal -= 1
        }

        var abs = 0
        while abs < effectiveTotal {
            let sourceHeadLineID = oldestOldLineID + UInt64(abs)
            let emittedHeadLineID = UInt64(emitted)
            let hasHyperlinks = hyperlinks?.record(headLineID: sourceHeadLineID) != nil
            var hyperlinkSegments: ContiguousArray<TerminalLogicalSegment>? = hasHyperlinks
                ? [] : nil
            // 聚合一条逻辑行：本行 + 后续所有带 wrapped 位的行。
            var (cells, headInfo) = sourceRow(abs)
            var cursorOffset: Int? = abs == cursorAbs ? oldGrid.cursorCol : nil
            var next = abs + 1
            while next < effectiveTotal {
                let nextInfo = next < sbCount
                    ? oldSb[next].info
                    : oldGrid.info(ofRow: next - sbCount)
                guard nextInfo.isWrapped else { break }
                if next == cursorAbs {
                    cursorOffset = cells.count + oldGrid.cursorCol
                }
                let (more, _) = sourceRow(next)
                cells += more
                next += 1
            }
            if hasHyperlinks {
                var removedGaps = ContiguousArray<HyperlinkRemovedGap>()
                var removedGapCells: UInt32 = 0
                var oldLogicalOffset = 0
                for sourceLine in abs..<next {
                    let (rowCells, _) = sourceRow(sourceLine)
                    let hasWrappedSuccessor = sourceLine + 1 < next
                    if hasWrappedSuccessor, rowCells.count < oldGrid.size.columns {
                        let gapStart = UInt32(clamping: oldLogicalOffset + rowCells.count)
                        let gapEnd = UInt32(clamping: oldLogicalOffset + oldGrid.size.columns)
                        removedGaps.append(HyperlinkRemovedGap(
                            offsets: gapStart..<gapEnd,
                            removedBefore: removedGapCells
                        ))
                        removedGapCells += gapEnd - gapStart
                        oldLogicalOffset += oldGrid.size.columns
                    } else {
                        oldLogicalOffset += rowCells.count
                    }
                }
                hyperlinkHeadMapping?[sourceHeadLineID] = (
                    headLineID: emittedHeadLineID,
                    cellCount: UInt32(clamping: cells.count),
                    removedGaps: removedGaps
                )
            }

            // 收集逻辑行内的全部语义转换。RowInfo 保存每个物理行的最后一个点，
            // 同行更早的少数点来自稀疏旁路表。
            var transitions: [(offset: Int, mark: SemanticMark, order: Int)] = []
            var start = 0
            var sourceOffset = 0
            var order = 0
            var scan = abs
            while scan < next {
                let (rowCells, info) = sourceRow(scan)
                for transition in overflowByAbsoluteLine[scan] ?? [] {
                    transitions.append((sourceOffset + Int(transition.column), transition.mark, order))
                    order += 1
                }
                if let column = info.semanticTransitionColumn {
                    transitions.append((sourceOffset + column, info.semanticMark, order))
                    order += 1
                }
                sourceOffset += rowCells.count
                scan += 1
            }
            transitions.sort {
                $0.offset == $1.offset ? $0.order < $1.order : $0.offset < $1.offset
            }
            var completions: [(offset: Int, record: CommandCompletionRecord)] = []
            sourceOffset = 0
            scan = abs
            while scan < next {
                let (rowCells, _) = sourceRow(scan)
                for record in completionsByAbsoluteLine[scan] ?? [] {
                    completions.append((sourceOffset + Int(record.column), record))
                }
                sourceOffset += rowCells.count
                scan += 1
            }
            completions.sort { $0.offset < $1.offset }

            // 按新宽度切块。
            var transitionIndex = 0
            var completionIndex = 0
            var semantic = transitions.first?.mark.predecessor ?? headInfo.semanticMark
            var isFirst = true
            var lastChunkStart = 0
            repeat {
                var end = min(start + newCols, cells.count)
                // 断点落在宽字符尾格：整个宽字符挪到下一行。
                if end < cells.count, cells[end].attr & Cell.Attr.wideTrailing != 0 {
                    end -= 1
                }
                let chunk = Array(cells[start..<end])
                let flags: UInt8 = isFirst ? headInfo.flags & ~RowInfo.wrapped : RowInfo.wrapped
                if let offset = cursorOffset, offset >= start, offset < end {
                    newCursor = (emitted, offset - start)
                }
                lastChunkStart = start
                let rowID = UInt64(emitted)
                hyperlinkSegments?.append(TerminalLogicalSegment(
                    lineID: rowID,
                    absoluteLine: emitted,
                    startOffset: start,
                    cellCount: end - start
                ))
                var rowTransitions: [(offset: Int, mark: SemanticMark)] = []
                while transitionIndex < transitions.count {
                    let transition = transitions[transitionIndex]
                    let belongsHere = transition.offset < end
                        || (transition.offset == end && end == cells.count)
                    guard belongsHere else { break }
                    if transition.offset >= start {
                        rowTransitions.append((transition.offset - start, transition.mark))
                    }
                    semantic = transition.mark
                    transitionIndex += 1
                }
                while completionIndex < completions.count {
                    let item = completions[completionIndex]
                    let belongsHere = item.offset < end
                        || (item.offset == end && end == cells.count)
                    guard belongsHere else { break }
                    if item.offset >= start {
                        newCompletions.append(CommandCompletionRecord(
                            lineID: rowID,
                            column: item.offset - start,
                            completion: item.record.completion
                        ))
                    }
                    completionIndex += 1
                }
                for transition in rowTransitions.dropLast() {
                    newOverflow.append(SemanticOverflowTransition(
                        lineID: rowID,
                        column: transition.offset,
                        mark: transition.mark
                    ))
                }
                let finalTransition = rowTransitions.last
                emitRow(chunk, RowInfo(
                    flags: flags,
                    semantic: semantic.rawValue,
                    semanticTransitionColumn: finalTransition?.offset
                ))
                isFirst = false
                start = end
            } while start < cells.count
            // 光标悬在行尾（裁掉的空白区）：贴到最后一块的末尾。
            if let offset = cursorOffset, newCursor == nil {
                newCursor = (emitted - 1, min(offset - lastChunkStart, newCols - 1))
            }
            if let hyperlinkSegments {
                reflowHyperlinkLines?[sourceHeadLineID] = TerminalLogicalLine(
                    headLineID: emittedHeadLineID,
                    scalars: [],
                    segments: hyperlinkSegments
                )
            }

            abs = next
        }

        // 尾部回屏幕。
        var newGrid = Grid(size: newSize)
        for (i, cells) in tailCells.enumerated() {
            for (c, cell) in cells.enumerated() where c < newCols {
                newGrid[i, c] = cell
            }
            newGrid.setInfo(tailInfo[i], forRow: i)
        }
        // 溢出行数（含被环形容量挤掉的），光标映射用它而不是 newSb.count。
        let overflow = emitted - tailCells.count
        if let cursor = newCursor {
            newGrid.cursorRow = max(0, min(cursor.abs - overflow, newRows - 1))
            newGrid.cursorCol = max(0, min(cursor.col, newCols - 1))
        }
        grid = newGrid
        scrollback = newSb
        let retainedRows = newSb.count + tailCells.count
        let firstRetainedID = UInt64(max(0, emitted - retainedRows))
        semanticOverflowTransitions = newOverflow.filter { $0.lineID >= firstRetainedID }
        semanticOverflowStart = 0
        commandCompletionRecords = ContiguousArray(
            newCompletions.filter { $0.lineID >= firstRetainedID }
        )
        commandCompletionStart = 0
        if var store = hyperlinks {
            let delta = store.remapHeads(hyperlinkHeadMapping ?? [:])
            applyHyperlinkReferenceDelta(delta)
            store.removeAllRowAnchors()
            if let reflowHyperlinkLines {
                for line in reflowHyperlinkLines.values {
                    store.rebuildRowIndex(for: line)
                }
            }
            hyperlinks = store.isEmpty ? nil : store
            pruneHyperlinks()
        }
        savedCursor = nil
    }

    // MARK: - TerminalActionHandler：打印

    public mutating func print(_ scalar: UInt32) {
        let width = CharWidth.width(of: scalar)

        // 零宽：组合进前格。ZWJ 额外挂起，让下一个码点也并进同一簇。
        if width == 0 {
            appendToPreviousCell(scalar)
            if scalar == 0x200D { pendingJoin = true }
            return
        }
        // ZWJ 序列的后续 emoji：并簇，不动光标（👨‍👩‍👧 整体占一个宽格）。
        if pendingJoin {
            pendingJoin = false
            appendToPreviousCell(scalar)
            return
        }

        if pendingWrap {
            pendingWrap = false
            carriageReturn()
            lineFeed(markWrapped: true)
        }

        let cols = grid.size.columns
        if width == 2, grid.cursorCol == cols - 1 {
            if modes.autowrap {
                // 行尾剩一格放不下宽字符：补空白，整字折到下一行。
                clearHyperlinkCells(
                    row: grid.cursorRow,
                    columns: grid.cursorCol..<(grid.cursorCol + 1)
                )
                grid[grid.cursorRow, grid.cursorCol] = .blank
                carriageReturn()
                lineFeed(markWrapped: true)
            } else {
                grid.cursorCol = cols - 2
            }
        }

        let row = grid.cursorRow
        let col = grid.cursorCol
        // 覆写别人的半个宽字符时，把孤儿半格清掉，不留残影。
        clearWideOrphan(row: row, col: col)
        if width == 2 { clearWideOrphan(row: row, col: col + 1) }

        grid[row, col] = Cell(
            scalar: scalar,
            attr: currentAttr | (width == 2 ? Cell.Attr.wideLeading : 0)
        )
        if width == 2 {
            grid[row, col + 1] = Cell(scalar: 0x20, attr: currentAttr | Cell.Attr.wideTrailing)
        }

        if let activeHyperlinkTargetID {
            replaceHyperlinkCells(
                row: row,
                columns: col..<(col + width),
                targetID: activeHyperlinkTargetID
            )
        } else if let hyperlinks {
            let stableLineID = scrollback.totalAppendedLines + UInt64(row)
            if hyperlinks.mayContainRow(lineID: stableLineID) {
                replaceHyperlinkCells(
                    row: row,
                    columns: col..<(col + width),
                    targetID: nil
                )
            }
        }

        if col + width < cols {
            grid.cursorCol = col + width
        } else {
            grid.cursorCol = cols - 1
            if modes.autowrap { pendingWrap = true }
        }
    }

    /// 组合标记 / 变体选择符 / ZWJ 后续码点并进光标前一个格的簇。
    private mutating func appendToPreviousCell(_ scalar: UInt32) {
        guard let (row, c) = previousCellPosition() else { return } // 行首孤立组合符：丢
        var col = c
        if grid[row, col].attr & Cell.Attr.wideTrailing != 0 {
            col -= 1 // 落在宽字符尾格上，退回首格
        }
        let cell = grid[row, col]
        var scalars: ContiguousArray<UInt32>
        if cell.isCluster {
            scalars = clusterTable.scalars(for: cell.scalar)
            scalars.append(scalar)
        } else {
            scalars = [cell.scalar, scalar]
        }
        grid[row, col] = Cell(scalar: clusterTable.encode(scalars), attr: cell.attr)
    }

    private func previousCellPosition() -> (row: Int, col: Int)? {
        if pendingWrap {
            return (grid.cursorRow, grid.cursorCol) // 光标停在刚写完的末列
        }
        guard grid.cursorCol > 0 else { return nil }
        return (grid.cursorRow, grid.cursorCol - 1)
    }

    private mutating func clearWideOrphan(row: Int, col: Int) {
        let attr = grid[row, col].attr
        if attr & Cell.Attr.wideTrailing != 0, col > 0 {
            clearHyperlinkCells(row: row, columns: (col - 1)..<col)
            grid[row, col - 1] = .blank
        } else if attr & Cell.Attr.wideLeading != 0, col + 1 < grid.size.columns {
            clearHyperlinkCells(row: row, columns: (col + 1)..<(col + 2))
            grid[row, col + 1] = .blank
        }
    }

    // MARK: - TerminalActionHandler：C0

    public mutating func execute(_ control: UInt8) {
        switch control {
        case 0x07:
            pendingEvents.append(.bell)
        case 0x0A, 0x0B, 0x0C: // LF VT FF
            lineFeed()
        case 0x0D:
            carriageReturn()
        case 0x08:
            if grid.cursorCol > 0 { grid.cursorCol -= 1 }
            pendingWrap = false
        case 0x09:
            // 固定 8 列制表位。HTS/TBC 自定义制表位极少被用到，需要时再加。
            let next = (grid.cursorCol / 8 + 1) * 8
            grid.cursorCol = min(next, grid.size.columns - 1)
        default:
            break
        }
    }

    // MARK: - TerminalActionHandler：CSI

    public mutating func csiDispatch(
        prefix: UInt8,
        params: ArraySlice<UInt16>,
        intermediates: ArraySlice<UInt8>,
        final: UInt8
    ) {
        @inline(__always)
        func param(_ i: Int, default def: Int = 1) -> Int {
            let base = params.startIndex + i
            guard base < params.endIndex, params[base] != 0 else { return def }
            return Int(params[base])
        }

        if prefix == UInt8(ascii: "?") {
            decPrivateMode(params: params, set: final == UInt8(ascii: "h"))
            return
        }
        guard prefix == 0, intermediates.isEmpty else { return } // 带修饰的序列暂不支持

        switch final {
        case UInt8(ascii: "A"): moveCursor(rowDelta: -param(0), colDelta: 0)
        case UInt8(ascii: "B"): moveCursor(rowDelta: param(0), colDelta: 0)
        case UInt8(ascii: "C"): moveCursor(rowDelta: 0, colDelta: param(0))
        case UInt8(ascii: "D"): moveCursor(rowDelta: 0, colDelta: -param(0))
        case UInt8(ascii: "E"): carriageReturn(); moveCursor(rowDelta: param(0), colDelta: 0)
        case UInt8(ascii: "F"): carriageReturn(); moveCursor(rowDelta: -param(0), colDelta: 0)
        case UInt8(ascii: "G"), UInt8(ascii: "`"):
            grid.cursorCol = clampCol(param(0) - 1)
            pendingWrap = false
        case UInt8(ascii: "d"):
            grid.cursorRow = clampRow(originOffset + param(0) - 1)
            pendingWrap = false
        case UInt8(ascii: "H"), UInt8(ascii: "f"):
            grid.cursorRow = clampRow(originOffset + param(0) - 1)
            grid.cursorCol = clampCol(param(1) - 1)
            pendingWrap = false
        case UInt8(ascii: "J"): eraseDisplay(mode: param(0, default: 0))
        case UInt8(ascii: "K"): eraseLine(mode: param(0, default: 0))
        case UInt8(ascii: "L"): insertLines(param(0))
        case UInt8(ascii: "M"): deleteLines(param(0))
        case UInt8(ascii: "@"): insertChars(param(0))
        case UInt8(ascii: "P"): deleteChars(param(0))
        case UInt8(ascii: "X"): eraseChars(param(0))
        case UInt8(ascii: "S"):
            for _ in 0..<param(0) { scrollRegionUp() }
        case UInt8(ascii: "T"):
            for _ in 0..<param(0) {
                let top = scrollTop
                let bottom = scrollBottom
                moveHyperlinkRows(
                    in: top...bottom,
                    destinationForSource: { $0 < bottom ? $0 + 1 : nil },
                    mutateGrid: { $0.scrollDown(top: top, bottom: bottom) }
                )
            }
        case UInt8(ascii: "r"):
            setScrollRegion(top: param(0) - 1, bottom: param(1, default: grid.size.rows) - 1)
        case UInt8(ascii: "m"):
            selectGraphicRendition(params)
        case UInt8(ascii: "s"):
            savedCursor = (grid.cursorRow, grid.cursorCol, currentAttr)
        case UInt8(ascii: "u"):
            restoreCursor()
        case UInt8(ascii: "n"):
            // DSR：5 报状态，6 报光标位置（1 基，origin 模式下相对区域）。
            switch param(0, default: 0) {
            case 5:
                respond("\u{1B}[0n")
            case 6:
                let row = grid.cursorRow - originOffset + 1
                let col = grid.cursorCol + 1
                respond("\u{1B}[\(row);\(col)R")
            default:
                break
            }
        case UInt8(ascii: "c"):
            // DA1：报 VT220 级 + 若干能力位，现代 TUI 认这个就够了。
            respond("\u{1B}[?62;22c")
        default:
            break // 未实现的序列静默忽略——终端的传统美德
        }
    }

    // MARK: - TerminalActionHandler：ESC

    public mutating func escDispatch(intermediate: UInt8, final: UInt8) {
        guard intermediate == 0 else { return } // ESC ( B 等字符集指定：忽略
        switch final {
        case UInt8(ascii: "7"):
            savedCursor = (grid.cursorRow, grid.cursorCol, currentAttr)
        case UInt8(ascii: "8"):
            restoreCursor()
        case UInt8(ascii: "D"): // IND
            lineFeed()
        case UInt8(ascii: "E"): // NEL
            carriageReturn()
            lineFeed()
        case UInt8(ascii: "M"): // RI：区域顶再上移即区域下滚
            if grid.cursorRow == scrollTop {
                let top = scrollTop
                let bottom = scrollBottom
                moveHyperlinkRows(
                    in: top...bottom,
                    destinationForSource: { $0 < bottom ? $0 + 1 : nil },
                    mutateGrid: { $0.scrollDown(top: top, bottom: bottom) }
                )
            } else if grid.cursorRow > 0 {
                grid.cursorRow -= 1
            }
        case UInt8(ascii: "c"): // RIS 全量重置
            let size = grid.size
            let capacity = scrollback.capacity
            let nextSearchLayoutRevision = searchLayoutRevision &+ 1
            self = Terminal(size: size, scrollbackCapacity: capacity)
            searchLayoutRevision = nextSearchLayoutRevision
        case UInt8(ascii: "Z"): // DECID，同 DA1
            respond("\u{1B}[?62;22c")
        default:
            break
        }
    }

    // MARK: - 应答通道

    private mutating func respond(_ sequence: String) {
        responseBuffer.append(contentsOf: sequence.utf8)
    }

    /// 取走积压的应答字节（调用后清空）。会话层写回 PTY。
    public mutating func takeResponses() -> [UInt8] {
        guard !responseBuffer.isEmpty else { return [] }
        defer { responseBuffer.removeAll(keepingCapacity: true) }
        return responseBuffer
    }

    // MARK: - TerminalActionHandler：OSC

    public mutating func oscDispatch(_ bytes: ArraySlice<UInt8>) {
        // 形如 "Ps;Pt"。载荷可能是 UTF-8（窗口标题带中文）。
        guard let sep = bytes.firstIndex(of: UInt8(ascii: ";")) else { return }
        guard let code = Int(String(decoding: bytes[..<sep], as: UTF8.self)) else { return }
        let payload = bytes[(sep + 1)...]

        switch code {
        case 0, 2:
            title = String(decoding: payload, as: UTF8.self)
        case 8:
            guard let uriSeparator = payload.firstIndex(of: UInt8(ascii: ";")) else { return }
            let uriBytes = payload[payload.index(after: uriSeparator)...]
            let uri = String(decoding: uriBytes, as: UTF8.self)
            guard uri.utf8.elementsEqual(uriBytes),
                  !uri.unicodeScalars.contains(where: {
                      $0.value < 0x20 || $0.value == 0x7F
                  })
            else { return }
            setActiveHyperlink(uri.isEmpty ? nil : uri)
        case 133:
            handleOSC133(payload)
        default:
            break // OSC 8 超链接、52 剪贴板是 P1（roadmap）
        }
    }

    mutating func handleOSC133(
        _ payload: ArraySlice<UInt8>,
        now: ContinuousClock.Instant = ContinuousClock().now
    ) {
        guard let code = payload.first else { return }
        let mark: SemanticMark
        switch code {
        case UInt8(ascii: "A"):
            mark = .prompt
            commandStartedAt = nil
        case UInt8(ascii: "B"):
            mark = .command
            commandStartedAt = nil
        case UInt8(ascii: "C"):
            mark = .output
            commandStartedAt = now
        case UInt8(ascii: "D"):
            mark = .none
            if let startedAt = commandStartedAt {
                let completion = CommandCompletion(
                    exitStatus: Self.osc133ExitStatus(payload),
                    duration: startedAt.duration(to: now)
                )
                let column = pendingWrap ? grid.size.columns : grid.cursorCol
                let lineID = scrollback.totalAppendedLines + UInt64(grid.cursorRow)
                appendCommandCompletion(.init(
                    lineID: lineID,
                    column: column,
                    completion: completion
                ))
                pendingEvents.append(.commandCompleted(completion))
            }
            commandStartedAt = nil
        default:
            return
        }
        currentSemantic = mark
        // DECAWM 的延迟折行状态下，光标仍停在末格，但语义边界实际位于
        // 行尾之后；下一可打印字符才会进入 wrapped 延续行。
        let transitionColumn = pendingWrap ? grid.size.columns : grid.cursorCol
        stampSemantic(mark, at: transitionColumn)
    }

    private static func osc133ExitStatus(_ payload: ArraySlice<UInt8>) -> UInt8? {
        guard payload.count >= 3 else { return nil }
        let separator = payload.index(after: payload.startIndex)
        guard payload[separator] == UInt8(ascii: ";") else { return nil }
        let digits = payload[payload.index(after: separator)...]
        guard !digits.isEmpty,
              digits.allSatisfy({ (48...57).contains($0) }),
              let value = UInt16(String(decoding: digits, as: UTF8.self)),
              value <= 255
        else { return nil }
        return UInt8(value)
    }

    public mutating func takeEvents() -> [TerminalEvent] {
        guard !pendingEvents.isEmpty else { return [] }
        defer { pendingEvents.removeAll(keepingCapacity: true) }
        return Array(pendingEvents)
    }

    var liveCommandCompletionRecords: ArraySlice<CommandCompletionRecord> {
        commandCompletionRecords[commandCompletionStart...]
    }

    var commandCompletionRecordCount: Int {
        commandCompletionRecords.count - commandCompletionStart
    }

    private mutating func appendCommandCompletion(_ record: CommandCompletionRecord) {
        if commandCompletionStart == commandCompletionRecords.count
            || commandCompletionRecords.last!.lineID <= record.lineID {
            commandCompletionRecords.append(record)
            return
        }
        let index = commandCompletionRecords[commandCompletionStart...].firstIndex {
            $0.lineID > record.lineID
        } ?? commandCompletionRecords.endIndex
        commandCompletionRecords.insert(record, at: index)
    }

    // MARK: - 行为

    private mutating func setActiveHyperlink(_ uri: String?) {
        if let oldID = activeHyperlinkTargetID, hyperlinkTargets != nil {
            hyperlinkTargets!.release(id: oldID, count: 1)
            if hyperlinkTargets!.isEmpty { hyperlinkTargets = nil }
        }
        activeHyperlinkTargetID = nil

        guard let uri else { return }
        if hyperlinkTargets == nil { hyperlinkTargets = HyperlinkTargetTable() }
        guard let targetID = hyperlinkTargets!.retain(uri: uri) else {
            if hyperlinkTargets!.isEmpty { hyperlinkTargets = nil }
            return
        }
        activeHyperlinkTargetID = targetID
    }

    private mutating func replaceHyperlinkCells(
        row: Int,
        columns: Range<Int>,
        targetID: UInt32?
    ) {
        let stableLineID = scrollback.totalAppendedLines + UInt64(row)
        let existingAnchor = hyperlinks?.anchor(for: stableLineID)
        if targetID != nil, hyperlinks?.isSpanBudgetExhausted == true {
            if existingAnchor != nil {
                replaceHyperlinkCells(row: row, columns: columns, targetID: nil)
            }
            return
        }
        if targetID == nil, existingAnchor == nil { return }
        guard let coordinate = hyperlinkCoordinate(row: row, column: columns.lowerBound) else { return }
        let lower = coordinate.offset
        let upper = lower + UInt32(clamping: columns.count)
        guard lower < upper else { return }

        if hyperlinks == nil { hyperlinks = HyperlinkRangeStore() }
        let delta = hyperlinks!.replace(
            headLineID: coordinate.headLineID,
            offsets: lower..<upper,
            with: targetID
        )
        if targetID == nil || existingAnchor == nil {
            rebuildHyperlinkRowIndex(row: row, coordinate: coordinate)
        }
        applyHyperlinkReferenceDelta(delta)
        if hyperlinks?.isEmpty == true { hyperlinks = nil }
    }

    private mutating func clearHyperlinkCells(row: Int, columns: Range<Int>) {
        let stableLineID = scrollback.totalAppendedLines + UInt64(row)
        guard !columns.isEmpty,
              hyperlinks?.anchor(for: stableLineID) != nil,
              let coordinate = hyperlinkCoordinate(row: row, column: columns.lowerBound)
        else { return }
        let upper = coordinate.offset + UInt32(clamping: columns.count)
        let delta = hyperlinks!.clear(
            headLineID: coordinate.headLineID,
            offsets: coordinate.offset..<upper
        )
        rebuildHyperlinkRowIndex(row: row, coordinate: coordinate)
        applyHyperlinkReferenceDelta(delta)
        if hyperlinks?.isEmpty == true { hyperlinks = nil }
    }

    private mutating func insertHyperlinkCells(row: Int, column: Int, count: Int) {
        let stableLineID = scrollback.totalAppendedLines + UInt64(row)
        guard hyperlinks?.anchor(for: stableLineID) != nil,
              let coordinate = hyperlinkCoordinate(row: row, column: column)
        else { return }
        let delta = hyperlinks!.insert(
            headLineID: coordinate.headLineID,
            at: coordinate.offset,
            count: UInt32(clamping: count),
            segmentEnd: coordinate.segmentEnd
        )
        rebuildHyperlinkRowIndex(row: row, coordinate: coordinate)
        applyHyperlinkReferenceDelta(delta)
        if hyperlinks?.isEmpty == true { hyperlinks = nil }
    }

    private mutating func deleteHyperlinkCells(row: Int, column: Int, count: Int) {
        let stableLineID = scrollback.totalAppendedLines + UInt64(row)
        guard hyperlinks?.anchor(for: stableLineID) != nil,
              let coordinate = hyperlinkCoordinate(row: row, column: column)
        else { return }
        let delta = hyperlinks!.delete(
            headLineID: coordinate.headLineID,
            at: coordinate.offset,
            count: UInt32(clamping: count),
            segmentEnd: coordinate.segmentEnd
        )
        rebuildHyperlinkRowIndex(row: row, coordinate: coordinate)
        applyHyperlinkReferenceDelta(delta)
        if hyperlinks?.isEmpty == true { hyperlinks = nil }
    }

    private func hyperlinkFragments(in rows: ClosedRange<Int>) -> [PhysicalHyperlinkFragment] {
        guard let hyperlinks, let targets = hyperlinkTargets else { return [] }
        var fragments: [PhysicalHyperlinkFragment] = []
        fragments.reserveCapacity(rows.count)
        for row in rows {
            let stableLineID = scrollback.totalAppendedLines + UInt64(row)
            guard hyperlinks.containsRow(lineID: stableLineID),
                  let coordinate = hyperlinkCoordinate(row: row, column: 0),
                  let record = hyperlinks.record(headLineID: coordinate.headLineID)
            else { continue }
            let rowOffsets = coordinate.offset..<coordinate.segmentEnd
            for span in record.spans where span.offsets.overlaps(rowOffsets) {
                let lower = max(span.offsets.lowerBound, rowOffsets.lowerBound)
                let upper = min(span.offsets.upperBound, rowOffsets.upperBound)
                guard lower < upper, let target = targets.uri(for: span.targetID) else { continue }
                fragments.append(PhysicalHyperlinkFragment(
                    row: row,
                    columns: Int(lower - coordinate.offset)..<Int(upper - coordinate.offset),
                    target: target
                ))
            }
        }
        return fragments
    }

    private mutating func insertHyperlinkFragment(_ fragment: PhysicalHyperlinkFragment) {
        if hyperlinkTargets == nil { hyperlinkTargets = HyperlinkTargetTable() }
        guard let temporaryID = hyperlinkTargets!.retain(uri: fragment.target) else {
            if hyperlinkTargets!.isEmpty { hyperlinkTargets = nil }
            return
        }
        replaceHyperlinkCells(
            row: fragment.row,
            columns: fragment.columns,
            targetID: temporaryID
        )
        guard hyperlinkTargets != nil else { return }
        hyperlinkTargets!.release(id: temporaryID, count: 1)
        if hyperlinkTargets!.isEmpty { hyperlinkTargets = nil }
    }

    private mutating func moveHyperlinkRows(
        in rows: ClosedRange<Int>,
        destinationForSource: (Int) -> Int?,
        mutateGrid: (inout Grid) -> Void
    ) {
        let base = scrollback.totalAppendedLines
        let hasLinks = hyperlinks.map { store in
            rows.contains { store.containsRow(lineID: base + UInt64($0)) }
        } ?? false
        guard hasLinks else {
            mutateGrid(&grid)
            return
        }

        let fragments = hyperlinkFragments(in: rows)
        for row in rows {
            clearHyperlinkCells(row: row, columns: 0..<grid.size.columns)
        }
        mutateGrid(&grid)
        for fragment in fragments {
            guard let destination = destinationForSource(fragment.row), rows.contains(destination) else { continue }
            var moved = fragment
            moved.row = destination
            moved.columns = moved.columns.clamped(to: 0..<grid.size.columns)
            if !moved.columns.isEmpty { insertHyperlinkFragment(moved) }
        }
    }

    private mutating func removeCurrentHyperlinks() {
        guard let store = hyperlinks else { return }
        applyHyperlinkReferenceDelta(store.removingAllReferenceDelta())
        hyperlinks = nil
    }

    private mutating func pruneHyperlinks() {
        let continuationRebaseInterval = UInt64(min(65_536, max(256, scrollback.capacity)))
        let oldestLineID = scrollback.totalAppendedLines - UInt64(scrollback.count)
        guard hyperlinks?.needsPrune(before: oldestLineID) == true else { return }
        let fastDelta = hyperlinks!.discardUncontinuedPrefix(before: oldestLineID)
        applyHyperlinkReferenceDelta(fastDelta)
        guard hyperlinks?.needsPrune(before: oldestLineID) == true else {
            if hyperlinks?.isEmpty == true { hyperlinks = nil }
            return
        }
        guard let distance = hyperlinks?.continuationRebaseDistance(before: oldestLineID),
              distance >= continuationRebaseInterval
        else { return }
        guard hyperlinks != nil else { return }
        var earliestRetained: [UInt64: (lineID: UInt64, anchor: HyperlinkRowAnchor)] = [:]
        earliestRetained.reserveCapacity(hyperlinks!.rowIndex.count)
        for (lineID, anchor) in hyperlinks!.rowIndex where lineID >= oldestLineID {
            if earliestRetained[anchor.headLineID]?.lineID ?? UInt64.max > lineID {
                earliestRetained[anchor.headLineID] = (lineID, anchor)
            }
        }
        var rebases: [UInt64: (headLineID: UInt64, removedPrefix: UInt32)] = [:]
        rebases.reserveCapacity(earliestRetained.count)
        for (oldHeadLineID, candidate) in earliestRetained where oldHeadLineID < oldestLineID {
            let absoluteLine = Int(candidate.lineID - oldestLineID)
            guard let line = logicalLine(
                containing: TextPosition(line: absoluteLine, column: 0),
                preserveGridTrailingBlanks: true,
                includeScalars: false
            ),
                  let segment = line.segments.first(where: { $0.lineID == candidate.lineID }),
                  candidate.anchor.startOffset >= UInt32(clamping: segment.startOffset)
            else { continue }
            rebases[oldHeadLineID] = (
                headLineID: line.headLineID,
                removedPrefix: candidate.anchor.startOffset - UInt32(clamping: segment.startOffset)
            )
        }
        let delta = hyperlinks!.prune(before: oldestLineID) { rebases[$0] }
        applyHyperlinkReferenceDelta(delta)
        if hyperlinks!.isEmpty { hyperlinks = nil }
    }

    private func hyperlinkCoordinate(row: Int, column: Int) -> (
        headLineID: UInt64,
        offset: UInt32,
        segmentEnd: UInt32
    )? {
        let stableLineID = scrollback.totalAppendedLines + UInt64(row)
        if let anchor = hyperlinks?.anchor(for: stableLineID) {
            return (
                headLineID: anchor.headLineID,
                offset: anchor.startOffset + UInt32(clamping: column),
                segmentEnd: anchor.startOffset + UInt32(clamping: grid.size.columns)
            )
        }
        if scrollback.count + row > 0,
           grid.info(ofRow: row).isWrapped,
           stableLineID > 0,
           let previous = hyperlinks?.anchor(for: stableLineID - 1) {
            let previousAbsoluteLine = scrollback.count + row - 1
            guard let previousCellCount = logicalSegmentCellCount(
                at: previousAbsoluteLine,
                preserveGridTrailingBlanks: true
            ) else { return nil }
            let start = previous.startOffset + UInt32(clamping: previousCellCount)
            return (
                headLineID: previous.headLineID,
                offset: start + UInt32(clamping: column),
                segmentEnd: start + UInt32(clamping: grid.size.columns)
            )
        }
        let absoluteLine = scrollback.count + row
        guard let line = logicalLine(
            containing: TextPosition(line: absoluteLine, column: 0),
            preserveGridTrailingBlanks: true,
            includeScalars: false
        ),
              let segment = line.segments.first(where: { $0.lineID == stableLineID })
        else { return nil }
        let start = UInt32(clamping: segment.startOffset)
        return (
            headLineID: line.headLineID,
            offset: start + UInt32(clamping: column),
            segmentEnd: start + UInt32(clamping: grid.size.columns)
        )
    }

    private mutating func rebuildHyperlinkRowIndex(
        row: Int,
        coordinate: (headLineID: UInt64, offset: UInt32, segmentEnd: UInt32)
    ) {
        let stableLineID = scrollback.totalAppendedLines + UInt64(row)
        let rowStart = coordinate.segmentEnd - UInt32(clamping: grid.size.columns)
        hyperlinks?.rebuildRowAnchor(
            lineID: stableLineID,
            headLineID: coordinate.headLineID,
            startOffset: rowStart,
            cellCount: UInt32(clamping: grid.size.columns)
        )
    }

    private mutating func applyHyperlinkReferenceDelta(_ delta: HyperlinkReferenceDelta) {
        guard !delta.counts.isEmpty, hyperlinkTargets != nil else { return }
        for (id, count) in delta.counts where count > 0 {
            hyperlinkTargets!.retain(id: id, count: count)
        }
        for (id, count) in delta.counts where count < 0 {
            hyperlinkTargets!.release(id: id, count: -count)
        }
        if hyperlinkTargets!.isEmpty { hyperlinkTargets = nil }
    }

    private mutating func lineFeed(markWrapped: Bool = false) {
        if grid.cursorRow == scrollBottom {
            scrollRegionUp()
        } else if grid.cursorRow < grid.size.rows - 1 {
            grid.cursorRow += 1
        }
        if markWrapped {
            var info = grid.info(ofRow: grid.cursorRow)
            info.flags |= RowInfo.wrapped
            grid.setInfo(info, forRow: grid.cursorRow)
        }
        stampSemantic()
    }

    private mutating func carriageReturn() {
        grid.cursorCol = 0
        pendingWrap = false
    }

    /// 区域上滚一行；只有主屏整屏滚动才把滚出的行送进 scrollback。
    private mutating func scrollRegionUp() {
        if !modes.alternateScreen, scrollTop == 0, scrollBottom == grid.size.rows - 1 {
            let retainedCount = ScrollbackLine(
                trimming: grid.row(0),
                info: grid.info(ofRow: 0)
            ).count
            clearHyperlinkCells(
                row: 0,
                columns: retainedCount..<grid.size.columns
            )
            let evicted = grid.scrollUp(top: scrollTop, bottom: scrollBottom)
            scrollback.append(evicted)
            if semanticOverflowStart < semanticOverflowTransitions.count {
                pruneSemanticOverflow()
            }
            if commandCompletionStart < commandCompletionRecords.count {
                pruneCommandCompletions()
            }
            pruneHyperlinks()
        } else {
            let top = scrollTop
            let bottom = scrollBottom
            moveHyperlinkRows(
                in: top...bottom,
                destinationForSource: { $0 > top ? $0 - 1 : nil },
                mutateGrid: { _ = $0.scrollUp(top: top, bottom: bottom) }
            )
        }
    }

    private mutating func restoreCursor() {
        guard let saved = savedCursor else { return }
        grid.cursorRow = clampRow(saved.row)
        grid.cursorCol = clampCol(saved.col)
        currentAttr = saved.attr
        pendingWrap = false
    }

    private mutating func setScrollRegion(top: Int, bottom: Int) {
        let t = max(0, top)
        let b = min(grid.size.rows - 1, bottom)
        guard b > t else { return } // 非法区域忽略
        scrollTop = t
        scrollBottom = b
        grid.cursorRow = modes.originMode ? scrollTop : 0
        grid.cursorCol = 0
        pendingWrap = false
    }

    private var originOffset: Int { modes.originMode ? scrollTop : 0 }

    private func clampRow(_ row: Int) -> Int {
        modes.originMode
            ? min(max(row, scrollTop), scrollBottom)
            : min(max(row, 0), grid.size.rows - 1)
    }

    private func clampCol(_ col: Int) -> Int {
        min(max(col, 0), grid.size.columns - 1)
    }

    private mutating func moveCursor(rowDelta: Int, colDelta: Int) {
        grid.cursorRow = clampRow(grid.cursorRow + rowDelta)
        grid.cursorCol = clampCol(grid.cursorCol + colDelta)
        pendingWrap = false
    }

    private mutating func stampSemantic(_ mark: SemanticMark? = nil, at transitionColumn: Int? = nil) {
        var info = grid.info(ofRow: grid.cursorRow)
        if let mark,
           mark == .prompt,
           info.semanticMark == .none,
           info.semanticTransitionColumn != nil {
            // D 后紧接 A 时位置相同；保留 D 作为命令块结束证据，prompt 状态
            // 仍由 currentSemantic 继承到后续行，下一次 B 会覆盖本行。
            return
        }
        let lineID = scrollback.totalAppendedLines + UInt64(grid.cursorRow)
        if let mark,
           let oldColumn = info.semanticTransitionColumn,
           (info.semanticMark == .command && mark == .output)
            || (info.semanticMark == .output && mark == .prompt)
            || (info.semanticMark == .output && mark == .none)
            || (info.semanticMark == .none && mark == .command) {
            appendSemanticOverflow(SemanticOverflowTransition(
                lineID: lineID,
                column: oldColumn,
                mark: info.semanticMark
            ))
        }
        info.semantic = currentSemantic.rawValue
        info.semanticTransitionColumn = transitionColumn
        grid.setInfo(info, forRow: grid.cursorRow)
    }

    private mutating func appendSemanticOverflow(_ transition: SemanticOverflowTransition) {
        if semanticOverflowStart == semanticOverflowTransitions.count
            || semanticOverflowTransitions.last!.lineID <= transition.lineID {
            semanticOverflowTransitions.append(transition)
            return
        }
        let index = semanticOverflowTransitions[semanticOverflowStart...].firstIndex {
            $0.lineID > transition.lineID
        } ?? semanticOverflowTransitions.endIndex
        semanticOverflowTransitions.insert(transition, at: index)
    }

    private mutating func pruneSemanticOverflow() {
        let oldestLineID = scrollback.totalAppendedLines - UInt64(scrollback.count)
        while semanticOverflowStart < semanticOverflowTransitions.count,
              semanticOverflowTransitions[semanticOverflowStart].lineID < oldestLineID {
            semanticOverflowStart += 1
        }
        // 失效前缀按批次回收，避免每次滚一行都搬数组；额外滞留最多约 255 项。
        if semanticOverflowStart >= 256,
           semanticOverflowStart * 2 >= semanticOverflowTransitions.count {
            semanticOverflowTransitions.removeFirst(semanticOverflowStart)
            semanticOverflowStart = 0
        }
    }

    private mutating func pruneCommandCompletions() {
        let oldestLineID = scrollback.totalAppendedLines - UInt64(scrollback.count)
        while commandCompletionStart < commandCompletionRecords.count,
              commandCompletionRecords[commandCompletionStart].lineID < oldestLineID {
            commandCompletionStart += 1
        }
        if commandCompletionStart >= 256,
           commandCompletionStart * 2 >= commandCompletionRecords.count {
            commandCompletionRecords.removeFirst(commandCompletionStart)
            commandCompletionStart = 0
        }
    }

    // MARK: - 擦除与编辑

    private mutating func eraseDisplay(mode: Int) {
        switch mode {
        case 0:
            eraseLine(mode: 0)
            for r in (grid.cursorRow + 1)..<grid.size.rows {
                clearHyperlinkCells(row: r, columns: 0..<grid.size.columns)
                grid.clearRow(r)
            }
        case 1:
            eraseLine(mode: 1)
            for r in 0..<grid.cursorRow {
                clearHyperlinkCells(row: r, columns: 0..<grid.size.columns)
                grid.clearRow(r)
            }
        case 2:
            for r in 0..<grid.size.rows {
                clearHyperlinkCells(row: r, columns: 0..<grid.size.columns)
            }
            grid.clearAll()
            let gridBase = scrollback.totalAppendedLines
            semanticOverflowTransitions = semanticOverflowTransitions[semanticOverflowStart...]
                .filter { $0.lineID < gridBase }
            semanticOverflowStart = 0
            commandCompletionRecords = ContiguousArray(
                liveCommandCompletionRecords.filter { $0.lineID < gridBase }
            )
            commandCompletionStart = 0
        case 3:
            let screenFragments = hyperlinkFragments(in: 0...(grid.size.rows - 1))
            removeCurrentHyperlinks()
            let gridBase = scrollback.totalAppendedLines
            semanticOverflowTransitions = semanticOverflowTransitions[semanticOverflowStart...]
                .compactMap { transition in
                guard transition.lineID >= gridBase else { return nil }
                return SemanticOverflowTransition(
                    lineID: transition.lineID - gridBase,
                    column: Int(transition.column),
                    mark: transition.mark
                )
            }
            semanticOverflowStart = 0
            commandCompletionRecords = ContiguousArray(
                liveCommandCompletionRecords.compactMap { record in
                    guard record.lineID >= gridBase else { return nil }
                    return CommandCompletionRecord(
                        lineID: record.lineID - gridBase,
                        column: Int(record.column),
                        completion: record.completion
                    )
                }
            )
            commandCompletionStart = 0
            scrollback.removeAll() // xterm 扩展：连历史一起清
            for fragment in screenFragments { insertHyperlinkFragment(fragment) }
            searchLayoutRevision &+= 1
        default:
            break
        }
        pendingWrap = false
    }

    private mutating func eraseLine(mode: Int) {
        let row = grid.cursorRow
        let range: Range<Int>
        switch mode {
        case 0: range = grid.cursorCol..<grid.size.columns
        case 1: range = 0..<(grid.cursorCol + 1)
        case 2: range = 0..<grid.size.columns
        default: return
        }
        clearHyperlinkCells(row: row, columns: range)
        for c in range { grid[row, c] = .blank }
        pendingWrap = false
    }

    private mutating func insertLines(_ n: Int) {
        guard (scrollTop...scrollBottom).contains(grid.cursorRow) else { return }
        for _ in 0..<min(n, scrollBottom - grid.cursorRow + 1) {
            let top = grid.cursorRow
            let bottom = scrollBottom
            moveHyperlinkRows(
                in: top...bottom,
                destinationForSource: { $0 < bottom ? $0 + 1 : nil },
                mutateGrid: { $0.scrollDown(top: top, bottom: bottom) }
            )
        }
        carriageReturn()
    }

    private mutating func deleteLines(_ n: Int) {
        guard (scrollTop...scrollBottom).contains(grid.cursorRow) else { return }
        for _ in 0..<min(n, scrollBottom - grid.cursorRow + 1) {
            let top = grid.cursorRow
            let bottom = scrollBottom
            moveHyperlinkRows(
                in: top...bottom,
                destinationForSource: { $0 > top ? $0 - 1 : nil },
                mutateGrid: { _ = $0.scrollUp(top: top, bottom: bottom) }
            )
        }
        carriageReturn()
    }

    private mutating func insertChars(_ n: Int) {
        let row = grid.cursorRow
        let cols = grid.size.columns
        let n = min(n, cols - grid.cursorCol)
        insertHyperlinkCells(row: row, column: grid.cursorCol, count: n)
        var c = cols - 1
        while c >= grid.cursorCol + n {
            grid[row, c] = grid[row, c - n]
            c -= 1
        }
        for c in grid.cursorCol..<(grid.cursorCol + n) { grid[row, c] = .blank }
    }

    private mutating func deleteChars(_ n: Int) {
        let row = grid.cursorRow
        let cols = grid.size.columns
        let n = min(n, cols - grid.cursorCol)
        deleteHyperlinkCells(row: row, column: grid.cursorCol, count: n)
        for c in grid.cursorCol..<(cols - n) {
            grid[row, c] = grid[row, c + n]
        }
        for c in (cols - n)..<cols { grid[row, c] = .blank }
    }

    private mutating func eraseChars(_ n: Int) {
        let row = grid.cursorRow
        let end = min(grid.cursorCol + n, grid.size.columns)
        clearHyperlinkCells(row: row, columns: grid.cursorCol..<end)
        for c in grid.cursorCol..<end { grid[row, c] = .blank }
    }

    // MARK: - DEC 私有模式

    private mutating func decPrivateMode(params: ArraySlice<UInt16>, set: Bool) {
        for p in params {
            switch p {
            case 1: modes.applicationCursorKeys = set
            case 6:
                modes.originMode = set
                grid.cursorRow = set ? scrollTop : 0
                grid.cursorCol = 0
            case 7: modes.autowrap = set
            case 25: modes.showCursor = set
            case 47, 1047:
                switchAlternateScreen(to: set, saveCursor: false)
            case 1049:
                switchAlternateScreen(to: set, saveCursor: true)
            case 1000: modes.mouseMode = set ? .click : .none
            case 1002: modes.mouseMode = set ? .drag : .none
            case 1003: modes.mouseMode = set ? .any : .none
            case 1006: modes.sgrMouse = set
            case 1007: modes.alternateScroll = set
            case 2004: modes.bracketedPaste = set
            default:
                break
            }
        }
    }

    /// 备用屏：vim / less 进出的机制。备用屏没有 scrollback，退出时主屏原样恢复。
    private mutating func switchAlternateScreen(to enter: Bool, saveCursor: Bool) {
        guard enter != modes.alternateScreen else { return }
        if enter {
            if saveCursor {
                savedCursor = (grid.cursorRow, grid.cursorCol, currentAttr)
            }
            savedPrimaryGrid = grid
            savedPrimaryHyperlinks = hyperlinks
            hyperlinks = nil
            grid = Grid(size: grid.size)
            modes.alternateScreen = true
        } else {
            removeCurrentHyperlinks()
            hyperlinks = savedPrimaryHyperlinks
            savedPrimaryHyperlinks = nil
            if let primary = savedPrimaryGrid {
                grid = primary
                savedPrimaryGrid = nil
            }
            modes.alternateScreen = false
            if saveCursor {
                restoreCursor()
            }
        }
        scrollTop = 0
        scrollBottom = grid.size.rows - 1
        pendingWrap = false
        searchLayoutRevision &+= 1
    }

    // MARK: - SGR

    private mutating func selectGraphicRendition(_ params: ArraySlice<UInt16>) {
        var i = params.startIndex
        if params.isEmpty {
            currentAttr = Cell.Attr.default
            return
        }
        while i < params.endIndex {
            let p = params[i]
            switch p {
            case 0: currentAttr = Cell.Attr.default
            case 1: currentAttr |= Cell.Attr.bold
            case 2: currentAttr |= Cell.Attr.faint
            case 3: currentAttr |= Cell.Attr.italic
            case 4: currentAttr |= Cell.Attr.underline
            case 5: currentAttr |= Cell.Attr.blink
            case 7: currentAttr |= Cell.Attr.inverse
            case 8: currentAttr |= Cell.Attr.hidden
            case 9: currentAttr |= Cell.Attr.strikethrough
            case 21, 22: currentAttr &= ~(Cell.Attr.bold | Cell.Attr.faint)
            case 23: currentAttr &= ~Cell.Attr.italic
            case 24: currentAttr &= ~Cell.Attr.underline
            case 25: currentAttr &= ~Cell.Attr.blink
            case 27: currentAttr &= ~Cell.Attr.inverse
            case 28: currentAttr &= ~Cell.Attr.hidden
            case 29: currentAttr &= ~Cell.Attr.strikethrough
            case 30...37: setForeground(UInt32(p - 30))
            case 39: setForeground(Cell.Attr.colorDefault)
            case 40...47: setBackground(UInt32(p - 40))
            case 49: setBackground(Cell.Attr.colorDefault)
            case 90...97: setForeground(UInt32(p - 90 + 8))
            case 100...107: setBackground(UInt32(p - 100 + 8))
            case 38, 48:
                let (color, consumed) = parseExtendedColor(params, from: i)
                if let color {
                    p == 38 ? setForeground(color) : setBackground(color)
                }
                i = params.index(i, offsetBy: consumed)
                continue
            default:
                break
            }
            i = params.index(after: i)
        }
    }

    /// `38;5;n` / `38;2;r;g;b`，返回（编码色，消费的参数个数）。
    private mutating func parseExtendedColor(
        _ params: ArraySlice<UInt16>, from i: ArraySlice<UInt16>.Index
    ) -> (UInt32?, Int) {
        let next = params.index(after: i)
        guard next < params.endIndex else { return (nil, 1) }
        switch params[next] {
        case 5:
            let idx = params.index(next, offsetBy: 1)
            guard idx < params.endIndex else { return (nil, 2) }
            return (UInt32(min(params[idx], 255)), 3)
        case 2:
            let r = params.index(next, offsetBy: 1)
            let g = params.index(next, offsetBy: 2)
            let b = params.index(next, offsetBy: 3)
            guard b < params.endIndex else { return (nil, 2) }
            let encoded = colorTable.encode(
                red: UInt8(min(params[r], 255)),
                green: UInt8(min(params[g], 255)),
                blue: UInt8(min(params[b], 255))
            )
            return (encoded, 5)
        default:
            return (nil, 2)
        }
    }

    @inline(__always)
    private mutating func setForeground(_ color: UInt32) {
        currentAttr = (currentAttr & ~Cell.Attr.colorMask) | (color & Cell.Attr.colorMask)
    }

    @inline(__always)
    private mutating func setBackground(_ color: UInt32) {
        currentAttr = (currentAttr & ~(Cell.Attr.colorMask << Cell.Attr.bgShift))
            | ((color & Cell.Attr.colorMask) << Cell.Attr.bgShift)
    }
}
