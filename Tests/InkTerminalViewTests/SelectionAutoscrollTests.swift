import CoreGraphics
import Testing
@testable import InkTerminalView

@Suite("选择越界滚动节奏")
struct SelectionAutoscrollTests {
    @Test("网格内不滚动且清除旧余量")
    func insideGridStops() {
        var state = SelectionAutoscrollState()
        #expect(state.rowsToScroll(
            pointerY: -1, gridTop: 0, gridBottom: 100,
            cellHeight: 20, elapsed: 0.1
        ) == 0)
        #expect(state.rowsToScroll(
            pointerY: 50, gridTop: 0, gridBottom: 100,
            cellHeight: 20, elapsed: 1
        ) == 0)
        #expect(state.rowsToScroll(
            pointerY: -1, gridTop: 0, gridBottom: 100,
            cellHeight: 20, elapsed: 0.03
        ) == 0)
    }

    @Test("上下越界产生相反方向")
    func directions() {
        var upward = SelectionAutoscrollState()
        var downward = SelectionAutoscrollState()
        #expect(upward.rowsToScroll(
            pointerY: -20, gridTop: 0, gridBottom: 100,
            cellHeight: 20, elapsed: 0.1
        ) > 0)
        #expect(downward.rowsToScroll(
            pointerY: 120, gridTop: 0, gridBottom: 100,
            cellHeight: 20, elapsed: 0.1
        ) < 0)
    }

    @Test("越界越远越快")
    func accelerates() {
        var near = SelectionAutoscrollState()
        var far = SelectionAutoscrollState()
        let nearRows = near.rowsToScroll(
            pointerY: -1, gridTop: 0, gridBottom: 100,
            cellHeight: 20, elapsed: 0.2
        )
        var farRows = 0
        for _ in 0..<4 {
            farRows += far.rowsToScroll(
                pointerY: -1_000, gridTop: 0, gridBottom: 100,
                cellHeight: 20, elapsed: 0.1
            )
        }
        #expect(nearRows == 1)
        #expect(farRows == 16)
    }

    @Test("最远越界速度严格封顶每秒四十行")
    func maximumSpeedIsFortyRowsPerSecond() {
        var state = SelectionAutoscrollState()
        var rows = 0
        for _ in 0..<1_000 {
            rows += state.rowsToScroll(
                pointerY: -1_000, gridTop: 0, gridBottom: 100,
                cellHeight: 20, elapsed: 0.001
            )
        }
        #expect(rows == 40)
    }

    @Test("长间隔单次最多推进四行")
    func maximumRowsPerTickIsFour() {
        var stalled = SelectionAutoscrollState()
        let stalledRows = stalled.rowsToScroll(
            pointerY: -1_000, gridTop: 0, gridBottom: 100,
            cellHeight: 20, elapsed: 1
        )
        #expect(stalledRows == 4)
    }

    @Test("小数行跨 tick 累积")
    func accumulatesAcrossTicks() {
        var state = SelectionAutoscrollState()
        #expect(state.rowsToScroll(
            pointerY: -1, gridTop: 0, gridBottom: 100,
            cellHeight: 20, elapsed: 0.05
        ) == 0)
        #expect(state.rowsToScroll(
            pointerY: -1, gridTop: 0, gridBottom: 100,
            cellHeight: 20, elapsed: 0.08
        ) == 1)
    }

    @Test("换向时清除会干扰反向结果的旧余量")
    func directionChangeClearsRemainder() {
        var state = SelectionAutoscrollState()
        #expect(state.rowsToScroll(
            pointerY: -1, gridTop: 0, gridBottom: 100,
            cellHeight: 20, elapsed: 0.1
        ) == 0)
        #expect(state.rowsToScroll(
            pointerY: 101, gridTop: 0, gridBottom: 100,
            cellHeight: 20, elapsed: 0.1
        ) == 0)
        #expect(state.rowsToScroll(
            pointerY: 101, gridTop: 0, gridBottom: 100,
            cellHeight: 20, elapsed: 0.03
        ) == -1)
    }
}
