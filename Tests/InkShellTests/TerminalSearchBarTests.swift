import AppKit
import Testing
@testable import InkShell

@Suite("终端搜索栏")
@MainActor
struct TerminalSearchBarTests {
    @Test("搜索模式按钮明确显示状态与可用性")
    func modeState() {
        let bar = TerminalSearchBarView()

        bar.updateSearchModes(
            caseSensitive: true,
            selectionOnly: false,
            selectionAvailable: false,
            copyOutputAvailable: true
        )

        #expect(bar.caseSensitiveEnabled)
        #expect(!bar.selectionOnlyEnabled)
        #expect(!bar.selectionToggleEnabled)
        #expect(bar.copyOutputEnabled)
    }

    @Test("大小写按钮把下一状态路由给控制器")
    func caseButtonRouting() {
        let bar = TerminalSearchBarView()
        var states: [Bool] = []
        bar.onCaseSensitivityChange = { states.append($0) }

        bar.toggleCaseSensitivity()
        bar.toggleCaseSensitivity()

        #expect(states == [true, false])
    }

    @Test("选区与复制按钮路由搜索动作")
    func scopeAndCopyButtonRouting() {
        let bar = TerminalSearchBarView()
        var scopeStates: [Bool] = []
        var copyCount = 0
        bar.onSelectionScopeChange = { scopeStates.append($0) }
        bar.onCopyMatchCommandOutput = { copyCount += 1 }
        bar.updateSearchModes(
            caseSensitive: false,
            selectionOnly: false,
            selectionAvailable: true,
            copyOutputAvailable: true
        )

        bar.toggleSelectionScope()
        bar.toggleSelectionScope()
        bar.performCopyMatchCommandOutput()

        #expect(scopeStates == [true, false])
        #expect(copyCount == 1)
    }

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
