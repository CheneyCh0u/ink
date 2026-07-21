import AppKit
import Testing
@testable import InkTerminalView

@Suite("字形 CPU 位图栅格化")
@MainActor
struct GlyphBitmapRasterizerTests {

    @Test("启用增粗会改变单色字形 coverage")
    func enablingThickeningChangesMonochromeCoverage() throws {
        let disabled = try rasterize("A", thicken: false, strength: 128)
        let enabled = try rasterize("A", thicken: true, strength: 128)

        #expect(disabled.format == .monochrome)
        #expect(enabled.format == .monochrome)
        #expect(disabled.bytes.contains { $0 != 0 })
        #expect(enabled.bytes.contains { $0 != 0 })
        #expect(coverage(of: enabled) != coverage(of: disabled))
    }

    @Test("启用增粗时 strength 会影响单色 coverage")
    func strengthChangesEnabledCoverage() throws {
        let low = try rasterize("A", thicken: true, strength: 32)
        let high = try rasterize("A", thicken: true, strength: 224)

        #expect(coverage(of: high) > coverage(of: low))
    }

    @Test("关闭增粗时 strength 不影响单色输出")
    func strengthDoesNotChangeDisabledOutput() throws {
        let low = try rasterize("A", thicken: false, strength: 0)
        let high = try rasterize("A", thicken: false, strength: 255)

        #expect(low.bytes == high.bytes)
    }

    @Test("彩色 emoji 的 BGRA 输出不受增粗参数影响")
    func colorEmojiIgnoresThickeningOptions() throws {
        let disabled = try rasterize("🚀", thicken: false, strength: 0)
        let enabled = try rasterize("🚀", thicken: true, strength: 255)

        #expect(disabled.format == .colorBGRA)
        #expect(enabled.format == .colorBGRA)
        #expect(disabled.bytes.contains { $0 != 0 })
        #expect(disabled.bytes == enabled.bytes)
    }

    private func rasterize(
        _ text: String,
        thicken: Bool,
        strength: Int
    ) throws -> GlyphBitmap {
        let rasterizer = GlyphBitmapRasterizer(
            font: NSFont.monospacedSystemFont(ofSize: 14, weight: .regular),
            scale: 2,
            lineHeightMultiplier: 1,
            cellHeightAdjustment: 0,
            fontThicken: thicken,
            fontThickenStrength: strength
        )
        return try #require(rasterizer.rasterize(text: text, bold: false, italic: false))
    }

    private func coverage(of bitmap: GlyphBitmap) -> Int {
        bitmap.bytes.reduce(0) { $0 + Int($1) }
    }
}
