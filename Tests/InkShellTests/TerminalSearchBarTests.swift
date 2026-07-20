import AppKit
import Testing
@testable import InkShell

@Suite("终端搜索栏")
@MainActor
struct TerminalSearchBarTests {
    @Test("结果计数按当前序号显示")
    func resultCount() {
        let bar = TerminalSearchBarView()

        #expect(!bar.navigationEnabled)

        bar.updateResultPosition(currentIndex: 1, total: 4)
        #expect(bar.resultText == "2 / 4")
        #expect(bar.navigationEnabled)

        bar.updateResultPosition(currentIndex: nil, total: 0)
        #expect(bar.resultText == "0 / 0")
    }

    @Test("回车方向键和 Escape 路由到搜索动作")
    func keyboardRouting() {
        let bar = TerminalSearchBarView()
        var actions: [String] = []
        bar.onNext = { actions.append("next") }
        bar.onPrevious = { actions.append("previous") }
        bar.onClose = { actions.append("close") }

        #expect(bar.handleCommand(#selector(NSResponder.insertNewline(_:)), shiftPressed: false))
        #expect(bar.handleCommand(#selector(NSResponder.insertNewline(_:)), shiftPressed: true))
        #expect(bar.handleCommand(#selector(NSResponder.moveDown(_:)), shiftPressed: false))
        #expect(bar.handleCommand(#selector(NSResponder.moveUp(_:)), shiftPressed: false))
        #expect(bar.handleCommand(#selector(NSResponder.cancelOperation(_:)), shiftPressed: false))

        #expect(actions == ["next", "previous", "next", "previous", "close"])
    }
}
