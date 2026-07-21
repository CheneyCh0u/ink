import InkConfig
import Testing
@testable import InkShell

@Suite("字号命令")
struct FontSizeCommandTests {
    @Test("按一磅步进并恢复 Ink 默认字号")
    func stepAndReset() {
        #expect(FontSizeCommand.increase.updatedValue(from: 15) == 16)
        #expect(FontSizeCommand.decrease.updatedValue(from: 15) == 14)
        #expect(FontSizeCommand.reset.updatedValue(from: 31) == 15)
    }

    @Test("字号命令不会越过配置边界")
    func clampsToRange() {
        #expect(FontSizeCommand.decrease.updatedValue(from: 6) == 6)
        #expect(FontSizeCommand.increase.updatedValue(from: 72) == 72)
    }
}
