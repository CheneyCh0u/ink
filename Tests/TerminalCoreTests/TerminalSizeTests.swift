import Testing
@testable import TerminalCore

@Suite("TerminalSize")
struct TerminalSizeTests {
    @Test("非法尺寸约束到 1×1")
    func clampsToMinimum() {
        let size = TerminalSize(columns: 0, rows: -3)
        #expect(size.columns == 1)
        #expect(size.rows == 1)
    }

    @Test("正常尺寸原样保留")
    func keepsValidSize() {
        let size = TerminalSize(columns: 120, rows: 40)
        #expect(size.columns == 120)
        #expect(size.rows == 40)
    }
}
