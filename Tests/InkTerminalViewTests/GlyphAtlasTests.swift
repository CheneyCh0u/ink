import AppKit
import Metal
import Testing
@testable import InkTerminalView

/// 图集测试要真 GPU 设备（CI 无头环境会跳过）。
@Suite("GlyphAtlas 彩色判定")
@MainActor
struct GlyphAtlasTests {

    private func makeAtlas(fontThicken: Bool = true, strength: Int = 128) -> GlyphAtlas? {
        guard let device = MTLCreateSystemDefaultDevice() else { return nil }
        return GlyphAtlas(
            device: device,
            font: NSFont.monospacedSystemFont(ofSize: 14, weight: .regular),
            scale: 2,
            fontThicken: fontThicken,
            fontThickenStrength: strength
        )
    }

    @Test("字体增粗参数保留在 atlas 栅格化配置中")
    func fontThickeningOptions() throws {
        let atlas = try #require(makeAtlas(fontThicken: true, strength: 128))
        #expect(atlas.fontThicken)
        #expect(atlas.fontThickenStrength == 128)
        #expect(try #require(atlas.entry(for: "A", bold: false, italic: false)).isColor == false)
        #expect(try #require(atlas.entry(for: "🚀", bold: false, italic: false)).isColor)
    }

    @Test("单 emoji、ZWJ 序列都走彩色图集；拉丁与中文走单色")
    func colorDetection() throws {
        guard let atlas = makeAtlas() else { return } // 无 GPU 环境静默跳过

        #expect(try #require(atlas.entry(for: "🚀", bold: false, italic: false)).isColor)
        // ZWJ 家庭：曾因按字体家族名判定而漏掉，渲染成深色剪影（回归测试）。
        #expect(try #require(atlas.entry(for: "👨\u{200D}👩\u{200D}👧", bold: false, italic: false)).isColor)
        #expect(try #require(atlas.entry(for: "A", bold: false, italic: false)).isColor == false)
        #expect(try #require(atlas.entry(for: "终", bold: false, italic: false)).isColor == false)
        // 组合重音（单色簇）也不该误入彩色图集。
        #expect(try #require(atlas.entry(for: "e\u{0301}", bold: false, italic: false)).isColor == false)
    }
}
