import Testing
@testable import TerminalCore

@Suite("Cell 布局")
struct CellLayoutTests {
    @Test("cell 定死 8 字节——谁改破谁修")
    func cellIsEightBytes() {
        #expect(MemoryLayout<Cell>.stride == 8)
        #expect(MemoryLayout<Cell>.size == 8)
    }

    @Test("RowInfo 定死 2 字节")
    func rowInfoIsTwoBytes() {
        #expect(MemoryLayout<RowInfo>.stride == 2)
    }

    @Test("颜色打包往返")
    func colorPackRoundtrip() {
        let attr = Cell.Attr.pack(fg: 196, bg: 2047, style: Cell.Attr.bold | Cell.Attr.underline)
        #expect(Cell.Attr.foreground(of: attr) == 196)
        #expect(Cell.Attr.background(of: attr) == 2047)
        #expect(attr & Cell.Attr.bold != 0)
        #expect(attr & Cell.Attr.underline != 0)
        #expect(attr & Cell.Attr.italic == 0)
    }

    @Test("默认属性是双默认色无样式")
    func defaultAttr() {
        #expect(Cell.Attr.foreground(of: Cell.Attr.default) == Cell.Attr.colorDefault)
        #expect(Cell.Attr.background(of: Cell.Attr.default) == Cell.Attr.colorDefault)
        #expect(Cell.blank.isBlank)
    }
}

@Suite("Grid")
struct GridTests {
    @Test("读写与行访问")
    func readWrite() {
        var grid = Grid(size: TerminalSize(columns: 10, rows: 4))
        grid[2, 3] = Cell(scalar: UInt32(UnicodeScalar("A").value))
        #expect(grid[2, 3].scalar == 65)
        #expect(grid.row(2)[2 * 10 + 3].scalar == 65)
        #expect(grid[0, 0].isBlank)
    }

    @Test("scrollUp 滚出首行、底行清空、内容上移")
    func scrollUp() {
        var grid = Grid(size: TerminalSize(columns: 4, rows: 3))
        grid[0, 0] = Cell(scalar: 65) // A
        grid[1, 0] = Cell(scalar: 66) // B
        grid.setInfo(RowInfo(flags: RowInfo.wrapped), forRow: 0)

        let evicted = grid.scrollUp()
        #expect(evicted.cells.first?.scalar == 65)
        #expect(evicted.info.isWrapped)
        #expect(grid[0, 0].scalar == 66)
        #expect(grid[2, 0].isBlank)
    }

    @Test("resize 变窄截断变宽补白，光标夹回界内")
    func resize() {
        var grid = Grid(size: TerminalSize(columns: 8, rows: 4))
        grid[1, 5] = Cell(scalar: 88) // X
        grid.cursorCol = 7
        grid.cursorRow = 3

        grid.resize(to: TerminalSize(columns: 4, rows: 2))
        #expect(grid.size.columns == 4)
        #expect(grid.cursorCol == 3)
        #expect(grid.cursorRow == 1)

        grid.resize(to: TerminalSize(columns: 10, rows: 3))
        #expect(grid[2, 9].isBlank)
    }
}

@Suite("Scrollback")
struct ScrollbackTests {
    @Test("入库裁掉尾部空白，行内容保留")
    func trimsTrailingBlank() {
        var grid = Grid(size: TerminalSize(columns: 80, rows: 2))
        grid[0, 0] = Cell(scalar: 108) // l
        grid[0, 1] = Cell(scalar: 115) // s
        let line = ScrollbackLine(trimming: grid.row(0), info: .none)
        #expect(line.cells.count == 2)
    }

    @Test("全空行裁成零长度")
    func blankRowTrimsToEmpty() {
        let grid = Grid(size: TerminalSize(columns: 80, rows: 1))
        let line = ScrollbackLine(trimming: grid.row(0), info: .none)
        #expect(line.cells.isEmpty)
    }

    @Test("带非默认属性的『空格』不算空白，不被裁掉")
    func styledSpaceSurvivesTrim() {
        var grid = Grid(size: TerminalSize(columns: 4, rows: 1))
        grid[0, 2] = Cell(scalar: 0x20, attr: Cell.Attr.pack(fg: Cell.Attr.colorDefault, bg: 1))
        let line = ScrollbackLine(trimming: grid.row(0), info: .none)
        #expect(line.cells.count == 3)
    }

    @Test("环形缓冲满员后覆盖最旧")
    func ringOverwritesOldest() {
        var buffer = ScrollbackBuffer(capacity: 3)
        for i in 0..<5 {
            let cells: ContiguousArray<Cell> = [Cell(scalar: UInt32(65 + i))]
            buffer.append(ScrollbackLine(cells: cells, info: .none))
        }
        #expect(buffer.count == 3)
        #expect(buffer[0].cells[0].scalar == 67) // C：A、B 已被覆盖
        #expect(buffer[2].cells[0].scalar == 69) // E
    }

    @Test("语义标记随行入库——OSC 133 的落点")
    func semanticSurvives() {
        var buffer = ScrollbackBuffer(capacity: 2)
        let info = RowInfo(flags: 0, semantic: SemanticMark.command.rawValue)
        buffer.append(ScrollbackLine(cells: [], info: info))
        #expect(buffer[0].info.semantic == SemanticMark.command.rawValue)
    }
}
