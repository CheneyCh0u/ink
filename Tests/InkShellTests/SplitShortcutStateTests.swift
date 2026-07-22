import Testing
import InkConfig
@testable import InkShell

@Suite("分屏复合快捷键状态机")
struct SplitShortcutStateTests {

    @Test("单独 Command-D 在 D 松开时默认向右")
    func plainCommandDDefaultsRightOnKeyUp() {
        var state = SplitShortcutState()

        #expect(state.handle(.commandDDown(isRepeat: false)) == .consume)
        #expect(state.handle(.dUp) == .split(.right))
    }

    @Test("Command-D 加方向键只执行对应方向一次")
    func chordUsesFirstDirectionOnce() {
        var state = SplitShortcutState()
        _ = state.handle(.commandDDown(isRepeat: false))

        #expect(state.handle(.direction(.up)) == .split(.up))
        #expect(state.handle(.direction(.left)) == .consume)
        #expect(state.handle(.dUp) == .consume)
    }

    @Test("按键重复不会重复分屏")
    func repeatDoesNotSplitAgain() {
        var state = SplitShortcutState()

        #expect(state.handle(.commandDDown(isRepeat: false)) == .consume)
        #expect(state.handle(.commandDDown(isRepeat: true)) == .consume)
        #expect(state.handle(.direction(.down)) == .split(.down))
        #expect(state.handle(.commandDDown(isRepeat: true)) == .consume)
    }

    @Test("Command 提前松开会取消待定分屏")
    func cancellationPreventsDefaultSplit() {
        var state = SplitShortcutState()
        _ = state.handle(.commandDDown(isRepeat: false))

        #expect(state.handle(.cancel) == .passThrough)
        #expect(state.handle(.dUp) == .passThrough)
    }

    @Test("空闲时不接管无关事件")
    func idlePassesThroughUnrelatedEvents() {
        var state = SplitShortcutState()

        #expect(state.handle(.direction(.right)) == .passThrough)
        #expect(state.handle(.dUp) == .passThrough)
    }

    @Test("方向键松开不结束已消费状态")
    func directionKeyUpKeepsChordConsumed() {
        var state = SplitShortcutState()

        #expect(state.handleKeyEvent(
            .keyDown(keyCode: 2, isRepeat: false, binding: KeyBinding.parse("cmd+d"))
        ) == .consume)
        #expect(state.handleKeyEvent(
            .keyDown(keyCode: 126, isRepeat: false, binding: KeyBinding.parse("cmd+up"))
        ) == .split(.up))
        #expect(state.handleKeyEvent(.keyUp(keyCode: 126)) == .passThrough)
        #expect(state.handleKeyEvent(
            .keyDown(keyCode: 123, isRepeat: false, binding: KeyBinding.parse("cmd+left"))
        ) == .consume)
        #expect(state.handleKeyEvent(.keyUp(keyCode: 2)) == .consume)
    }

    @Test("终端焦点离开后 D 松开不再默认分屏")
    func contextLossBeforeDUpCancelsChord() {
        var state = SplitShortcutState()
        _ = state.handleKeyEvent(
            .keyDown(keyCode: 2, isRepeat: false, binding: KeyBinding.parse("cmd+d"))
        )

        #expect(state.handleKeyEvent(.contextLost) == .passThrough)
        #expect(state.handleKeyEvent(.keyUp(keyCode: 2)) == .passThrough)
    }

    @Test("自定义 Control-K 前缀并在热更新时取消旧状态")
    func customPrefixAndUpdate() {
        var state = SplitShortcutState(prefix: KeyBinding.parse("ctrl+k"))
        #expect(state.handleKeyEvent(
            .keyDown(keyCode: 40, isRepeat: false, binding: KeyBinding.parse("ctrl+k"))
        ) == .consume)
        #expect(state.handleKeyEvent(
            .keyDown(keyCode: 123, isRepeat: false, binding: KeyBinding.parse("ctrl+left"))
        ) == .split(.left))

        state.updatePrefix(KeyBinding.parse("cmd+d"))
        #expect(state.handleKeyEvent(.keyUp(keyCode: 40)) == .passThrough)
    }
}
