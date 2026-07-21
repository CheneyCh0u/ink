import AppKit
import Testing
@testable import InkTerminalView

@Suite("终端字体配置")
@MainActor
struct TerminalFontConfigurationTests {

    @Test("一次应用多个字体字段只尝试重建一次")
    func applyingMultipleFieldsAttemptsOneRebuild() {
        let view = TerminalMetalView(frame: .zero)
        let before = view.rendererRebuildAttemptCount

        view.apply(fontConfiguration: TerminalFontConfiguration(
            fontFamily: "Menlo",
            fontSize: 18,
            lineHeightMultiplier: 1.4,
            cellHeightAdjustment: 3,
            fontThicken: false,
            fontThickenStrength: 96
        ))

        #expect(view.rendererRebuildAttemptCount - before == 1)
        #expect(view.fontFamily == "Menlo")
        #expect(view.fontSize == 18)
        #expect(view.lineHeightMultiplier == 1.4)
        #expect(view.cellHeightAdjustment == 3)
        #expect(view.fontThicken == false)
        #expect(view.fontThickenStrength == 96)
    }

    @Test("单项属性调用仍按字段触发一次重建")
    func individualPropertyStillAttemptsOneRebuild() {
        let view = TerminalMetalView(frame: .zero)
        let before = view.rendererRebuildAttemptCount

        view.fontSize = 16

        #expect(view.rendererRebuildAttemptCount - before == 1)
        #expect(view.fontSize == 16)
    }

    @Test("视图边界规范化字体数值与空字体族")
    func normalizesUnsafeValuesAtViewBoundary() {
        let config = TerminalFontConfiguration(
            fontFamily: "",
            fontSize: 1_000,
            lineHeightMultiplier: -10,
            cellHeightAdjustment: 10_000,
            fontThicken: true,
            fontThickenStrength: -1
        )

        #expect(config.fontFamily == nil)
        #expect(config.fontSize == 72)
        #expect(config.lineHeightMultiplier == 0.8)
        #expect(config.cellHeightAdjustment == 20)
        #expect(config.fontThicken)
        #expect(config.fontThickenStrength == 0)
    }

    @Test("非有限字号与行高回退安全默认值")
    func nonFiniteMetricsUseSafeDefaults() {
        var config = TerminalFontConfiguration()
        config.fontSize = .nan
        config.lineHeightMultiplier = .infinity

        #expect(config.fontSize == 14)
        #expect(config.lineHeightMultiplier == 1.2)
    }
}
