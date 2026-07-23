import CoreGraphics
import Testing
@testable import InkTerminalView

@Suite("选择越界滚动节奏")
struct SelectionAutoscrollTests {
    @Test("网格内不滚动且清除旧余量")
    func insideGridStops() {
        var state = SelectionAutoscrollState()
        _ = state.rowsToScroll(
            pointerY: -10, gridTop: 0, gridBottom: 100,
            cellHeight: 20, elapsed: 0.1
        )
        #expect(state.rowsToScroll(
            pointerY: 50, gridTop: 0, gridBottom: 100,
            cellHeight: 20, elapsed: 1
        ) == 0)
        #expect(state.rowsToScroll(
            pointerY: -1, gridTop: 0, gridBottom: 100,
            cellHeight: 20, elapsed: 0.01
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

    @Test("越界越远越快且长间隔单次最多四行")
    func acceleratesAndCaps() {
        var near = SelectionAutoscrollState()
        var far = SelectionAutoscrollState()
        var stalled = SelectionAutoscrollState()
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
        let stalledRows = stalled.rowsToScroll(
            pointerY: -1_000, gridTop: 0, gridBottom: 100,
            cellHeight: 20, elapsed: 1
        )
        #expect(nearRows == 1)
        #expect(farRows == 16)
        #expect(stalledRows == 4)
    }

    @Test("小数行跨 tick 累积且换向时清除")
    func accumulatesAndResetsDirection() {
        var state = SelectionAutoscrollState()
        #expect(state.rowsToScroll(
            pointerY: -1, gridTop: 0, gridBottom: 100,
            cellHeight: 20, elapsed: 0.05
        ) == 0)
        #expect(state.rowsToScroll(
            pointerY: -1, gridTop: 0, gridBottom: 100,
            cellHeight: 20, elapsed: 0.08
        ) == 1)
        #expect(state.rowsToScroll(
            pointerY: 101, gridTop: 0, gridBottom: 100,
            cellHeight: 20, elapsed: 0.03
        ) == 0)
    }
}
