import AppKit
import Metal

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
    private let baselineFromBottom: CGFloat
    private let scale: CGFloat

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

    private let fonts: (regular: NSFont, bold: NSFont, italic: NSFont, boldItalic: NSFont)

    init?(
        device: MTLDevice,
        font: NSFont,
        scale: CGFloat,
        lineHeightMultiplier: CGFloat = 1.0,
        cellHeightAdjustment: Int = 0,
        fontThicken: Bool,
        fontThickenStrength: Int
    ) {
        self.scale = scale
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
        baselineFromBottom = metrics.baselineFromBottom

        slotWidth = Int(cellWidth) * 2
        slotHeight = Int(cellHeight)
        slotColumns = Self.textureSize / slotWidth
        slotCapacity = slotColumns * (Self.textureSize / slotHeight)

        let manager = NSFontManager.shared
        let bold = manager.convert(font, toHaveTrait: .boldFontMask)
        let italic = manager.convert(font, toHaveTrait: .italicFontMask)
        let boldItalic = manager.convert(bold, toHaveTrait: .italicFontMask)
        fonts = (font, bold, italic, boldItalic)

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
        let font: NSFont =
            switch (bold, italic) {
            case (false, false): fonts.regular
            case (true, false): fonts.bold
            case (false, true): fonts.italic
            case (true, true): fonts.boldItalic
            }

        let attributed = NSAttributedString(string: text, attributes: [
            .font: font,
            kCTForegroundColorFromContextAttributeName as NSAttributedString.Key: true,
        ])
        let line = CTLineCreateWithAttributedString(attributed)

        // 彩色判定：看字体的 colorGlyphs trait，不比家族名——ZWJ 序列可能
        // 落到私有变体字体（家族名不是 "Apple Color Emoji"），比名字会漏，
        // 漏了的 emoji 会被当 alpha 蒙版染成前景色的剪影。
        var isColor = false
        if let runs = CTLineGetGlyphRuns(line) as? [CTRun] {
            for run in runs {
                let attrs = CTRunGetAttributes(run) as NSDictionary
                if let runFont = attrs[kCTFontAttributeName] {
                    let traits = CTFontGetSymbolicTraits(runFont as! CTFont)
                    if traits.contains(.traitColorGlyphs) {
                        isColor = true
                        break
                    }
                }
            }
        }

        // 槽位打满整体重置：缓存清空后按需回填，一帧内自愈。
        if (isColor ? colorNext : monoNext) >= slotCapacity {
            entries.removeAll(keepingCapacity: true)
            monoNext = 0
            colorNext = 0
        }

        let slot = isColor ? colorNext : monoNext
        let slotX = (slot % slotColumns) * slotWidth
        let slotY = (slot / slotColumns) * slotHeight

        guard let bitmap = drawLine(line, isColor: isColor) else { return nil }
        guard let texture = isColor ? ensureColorTexture() : monoTexture else { return nil }
        texture.replace(
            region: MTLRegionMake2D(slotX, slotY, slotWidth, slotHeight),
            mipmapLevel: 0,
            withBytes: bitmap,
            bytesPerRow: slotWidth * (isColor ? 4 : 1)
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

    /// 把 CTLine 画进槽位大小的位图。返回行主序像素（顶行在前，可直接进纹理）。
    private func drawLine(_ line: CTLine, isColor: Bool) -> [UInt8]? {
        let width = slotWidth
        let height = slotHeight
        let bytesPerRow = width * (isColor ? 4 : 1)
        var bitmap = [UInt8](repeating: 0, count: bytesPerRow * height)

        let ok = bitmap.withUnsafeMutableBytes { raw -> Bool in
            let context: CGContext?
            if isColor {
                context = CGContext(
                    data: raw.baseAddress, width: width, height: height,
                    bitsPerComponent: 8, bytesPerRow: bytesPerRow,
                    space: CGColorSpaceCreateDeviceRGB(),
                    bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue
                        | CGBitmapInfo.byteOrder32Little.rawValue
                )
            } else {
                // alpha-only 与 .r8Unorm 图集一一对应：每像素一个 coverage byte。
                // Swift overlay 不接受 nil 色彩空间；使用 Ghostty 同样的线性灰度空间。
                let monoColorSpace = CGColorSpace(name: CGColorSpace.linearGray)
                    ?? CGColorSpaceCreateDeviceGray()
                context = CGContext(
                    data: raw.baseAddress, width: width, height: height,
                    bitsPerComponent: 8, bytesPerRow: bytesPerRow,
                    space: monoColorSpace,
                    bitmapInfo: CGImageAlphaInfo.alphaOnly.rawValue
                )
            }
            guard let ctx = context else { return false }
            // CG 原点在左下。字形按 pt 排版，整个上下文放大到物理像素。
            ctx.scaleBy(x: scale, y: scale)
            if isColor {
                ctx.setFillColor(.white)
            } else {
                ctx.setAllowsFontSmoothing(true)
                ctx.setShouldSmoothFonts(fontThicken)
                ctx.setAllowsFontSubpixelPositioning(true)
                ctx.setShouldSubpixelPositionFonts(true)
                ctx.setAllowsFontSubpixelQuantization(false)
                ctx.setShouldSubpixelQuantizeFonts(false)
                ctx.setAllowsAntialiasing(true)
                ctx.setShouldAntialias(true)
                let strength = CGFloat(fontThickenStrength) / 255
                ctx.setFillColor(gray: strength, alpha: 1)
                ctx.setStrokeColor(gray: strength, alpha: 1)
            }
            ctx.textPosition = CGPoint(x: 0, y: baselineFromBottom / scale)
            CTLineDraw(line, ctx)
            return true
        }
        guard ok else { return nil }
        // CG 位图内存顶行在前，与 Metal 纹理的行序一致，直接上传。
        // （坐标系 y 朝上只影响绘制时的定位，不影响内存行序。）
        return bitmap
    }
}
