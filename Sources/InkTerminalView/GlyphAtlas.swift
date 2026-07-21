import AppKit
import Metal

/// 把 cell 度量转换为固定 atlas 的槽位；非法输入在任何除法或上传前失败。
struct GlyphAtlasSlotLayout: Equatable {
    let slotWidth: Int
    let slotHeight: Int
    let slotColumns: Int
    let slotCapacity: Int

    init?(cellWidth: CGFloat, cellHeight: CGFloat, textureSize: Int) {
        guard textureSize > 0,
              cellWidth.isFinite,
              cellHeight.isFinite,
              cellWidth >= 1,
              cellHeight >= 1,
              cellWidth * 2 <= CGFloat(textureSize),
              cellHeight <= CGFloat(textureSize)
        else { return nil }

        let slotWidth = Int(cellWidth) * 2
        let slotHeight = Int(cellHeight)
        let slotColumns = textureSize / slotWidth
        let slotRows = textureSize / slotHeight
        guard slotColumns > 0, slotRows > 0 else { return nil }

        self.slotWidth = slotWidth
        self.slotHeight = slotHeight
        self.slotColumns = slotColumns
        slotCapacity = slotColumns * slotRows
    }
}

/// 字形图集：CoreText 栅格化 → 定宽槽位 → 两张纹理。
///
/// - 单色字形进 A8 纹理（fragment 拿 `.r` 当 coverage）
/// - 彩色 emoji 进 BGRA 纹理（预乘 alpha 直接合成）
///
/// 所有字形统一走 `CTLine` 排版栅格化：字体回退（中文落到苹方）、emoji、
/// 组合簇一条路全通。成本只发生在首次遇到某字形，之后是字典命中。
///
/// 槽位统一为 2×cellW（容纳宽字符），2048² 的 A8 图集在 14pt@2x 下约有
/// 两千个槽——打满（极端多语言输出）就整体清空重建，缓存自然回填。
@MainActor
final class GlyphAtlas {

    struct Entry {
        var uvRect: SIMD4<Float>
        var isColor: Bool
    }

    private struct Key: Hashable {
        let text: String
        let style: UInt8 // bit0 bold, bit1 italic
    }

    // MARK: - 度量（像素）

    let cellWidth: CGFloat
    let cellHeight: CGFloat
    /// 单色字形首次栅格化时使用的 CoreGraphics 字体平滑配置。
    let fontThicken: Bool
    let fontThickenStrength: Int
    private let rasterizer: GlyphBitmapRasterizer

    // MARK: - 纹理与槽位

    private static let textureSize = 2048
    let monoTexture: MTLTexture
    /// 彩色图集懒分配：BGRA 2048² 常驻 16MB，而多数会话一个 emoji 都没有。
    private(set) var colorTexture: MTLTexture?
    private let device: MTLDevice

    private let slotWidth: Int
    private let slotHeight: Int
    private let slotColumns: Int
    private let slotCapacity: Int
    private var monoNext = 0
    private var colorNext = 0
    private var entries: [Key: Entry] = [:]

    init?(
        device: MTLDevice,
        font: NSFont,
        scale: CGFloat,
        lineHeightMultiplier: CGFloat = 1.0,
        cellHeightAdjustment: Int = 0,
        fontThicken: Bool,
        fontThickenStrength: Int
    ) {
        self.fontThicken = fontThicken
        self.fontThickenStrength = fontThickenStrength

        let metrics = FontGridMetrics(
            font: font,
            scale: scale,
            lineHeightMultiplier: lineHeightMultiplier,
            cellHeightAdjustment: cellHeightAdjustment
        )
        cellWidth = metrics.cellWidth
        cellHeight = metrics.cellHeight
        guard let slotLayout = GlyphAtlasSlotLayout(
            cellWidth: cellWidth,
            cellHeight: cellHeight,
            textureSize: Self.textureSize
        ) else { return nil }
        slotWidth = slotLayout.slotWidth
        slotHeight = slotLayout.slotHeight
        slotColumns = slotLayout.slotColumns
        slotCapacity = slotLayout.slotCapacity
        rasterizer = GlyphBitmapRasterizer(
            font: font,
            scale: scale,
            lineHeightMultiplier: lineHeightMultiplier,
            cellHeightAdjustment: cellHeightAdjustment,
            fontThicken: fontThicken,
            fontThickenStrength: fontThickenStrength
        )

        let monoDesc = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: .r8Unorm,
            width: Self.textureSize, height: Self.textureSize, mipmapped: false
        )
        guard let mono = device.makeTexture(descriptor: monoDesc) else { return nil }
        monoTexture = mono
        self.device = device
    }

    private func ensureColorTexture() -> MTLTexture? {
        if let colorTexture { return colorTexture }
        let desc = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: .bgra8Unorm,
            width: Self.textureSize, height: Self.textureSize, mipmapped: false
        )
        colorTexture = device.makeTexture(descriptor: desc)
        return colorTexture
    }

    // MARK: - 查询

    func entry(for text: String, bold: Bool, italic: Bool) -> Entry? {
        let key = Key(text: text, style: (bold ? 1 : 0) | (italic ? 2 : 0))
        if let cached = entries[key] { return cached }
        guard let made = rasterize(text: text, bold: bold, italic: italic) else { return nil }
        entries[key] = made
        return made
    }

    // MARK: - 栅格化

    private func rasterize(text: String, bold: Bool, italic: Bool) -> Entry? {
        // 块元素不走字体：字形按 em box 设计，与 cell（含行距）不重合，
        // 拼接的像素画会错位漏缝。程序化按 cell 精确填充。
        if text.unicodeScalars.count == 1,
           let scalar = text.unicodeScalars.first?.value,
           BlockElements.contains(scalar) {
            return rasterizeBlockElement(scalar)
        }
        guard let bitmap = rasterizer.rasterize(text: text, bold: bold, italic: italic) else {
            return nil
        }
        let isColor = bitmap.format == .colorBGRA

        // 槽位打满整体重置：缓存清空后按需回填，一帧内自愈。
        if (isColor ? colorNext : monoNext) >= slotCapacity {
            entries.removeAll(keepingCapacity: true)
            monoNext = 0
            colorNext = 0
        }

        let slot = isColor ? colorNext : monoNext
        let slotX = (slot % slotColumns) * slotWidth
        let slotY = (slot / slotColumns) * slotHeight

        guard let texture = isColor ? ensureColorTexture() : monoTexture else { return nil }
        texture.replace(
            region: MTLRegionMake2D(slotX, slotY, slotWidth, slotHeight),
            mipmapLevel: 0,
            withBytes: bitmap.bytes,
            bytesPerRow: bitmap.bytesPerRow
        )
        if isColor { colorNext += 1 } else { monoNext += 1 }

        let tex = Float(Self.textureSize)
        let entry = Entry(
            uvRect: SIMD4(
                Float(slotX) / tex,
                Float(slotY) / tex,
                Float(slotWidth) / tex,
                Float(slotHeight) / tex
            ),
            isColor: isColor
        )
        return entry
    }

    private func rasterizeBlockElement(_ scalar: UInt32) -> Entry? {
        if monoNext >= slotCapacity {
            entries.removeAll(keepingCapacity: true)
            monoNext = 0
            colorNext = 0
        }
        let slot = monoNext
        let slotX = (slot % slotColumns) * slotWidth
        let slotY = (slot / slotColumns) * slotHeight

        var bitmap = [UInt8](repeating: 0, count: slotWidth * slotHeight)
        BlockElements.render(
            scalar,
            width: Int(cellWidth), height: slotHeight,
            into: &bitmap, bytesPerRow: slotWidth
        )
        monoTexture.replace(
            region: MTLRegionMake2D(slotX, slotY, slotWidth, slotHeight),
            mipmapLevel: 0,
            withBytes: bitmap,
            bytesPerRow: slotWidth
        )
        monoNext += 1

        let tex = Float(Self.textureSize)
        return Entry(
            uvRect: SIMD4(
                Float(slotX) / tex, Float(slotY) / tex,
                Float(slotWidth) / tex, Float(slotHeight) / tex
            ),
            isColor: false
        )
    }

}
