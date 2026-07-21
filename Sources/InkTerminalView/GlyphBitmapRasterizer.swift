import AppKit
import CoreText

/// 可直接上传到 glyph atlas 的 CPU 位图。
struct GlyphBitmap: Equatable {
    enum Format: Equatable {
        case monochrome
        case colorBGRA
    }

    let bytes: [UInt8]
    let width: Int
    let height: Int
    let bytesPerRow: Int
    let format: Format
}

/// CoreText/CoreGraphics 栅格化边界，不依赖 Metal；只在 atlas miss 时调用。
@MainActor
struct GlyphBitmapRasterizer {
    private let scale: CGFloat
    private let baselineFromBottom: CGFloat
    private let slotWidth: Int
    private let slotHeight: Int
    private let fontThicken: Bool
    private let fontThickenStrength: Int
    private let fonts: (regular: NSFont, bold: NSFont, italic: NSFont, boldItalic: NSFont)

    init(
        font: NSFont,
        scale: CGFloat,
        lineHeightMultiplier: CGFloat = 1,
        cellHeightAdjustment: Int = 0,
        fontThicken: Bool,
        fontThickenStrength: Int
    ) {
        let metrics = FontGridMetrics(
            font: font,
            scale: scale,
            lineHeightMultiplier: lineHeightMultiplier,
            cellHeightAdjustment: cellHeightAdjustment
        )
        self.scale = scale
        baselineFromBottom = metrics.baselineFromBottom
        slotWidth = Int(metrics.cellWidth) * 2
        slotHeight = Int(metrics.cellHeight)
        self.fontThicken = fontThicken
        self.fontThickenStrength = Swift.min(Swift.max(fontThickenStrength, 0), 255)

        let manager = NSFontManager.shared
        let bold = manager.convert(font, toHaveTrait: .boldFontMask)
        let italic = manager.convert(font, toHaveTrait: .italicFontMask)
        let boldItalic = manager.convert(bold, toHaveTrait: .italicFontMask)
        fonts = (font, bold, italic, boldItalic)
    }

    func rasterize(text: String, bold: Bool, italic: Bool) -> GlyphBitmap? {
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
        let format = isColor(line) ? GlyphBitmap.Format.colorBGRA : .monochrome
        let bytesPerRow = slotWidth * (format == .colorBGRA ? 4 : 1)
        var bitmap = [UInt8](repeating: 0, count: bytesPerRow * slotHeight)

        let rendered = bitmap.withUnsafeMutableBytes { raw -> Bool in
            let context: CGContext?
            switch format {
            case .colorBGRA:
                context = CGContext(
                    data: raw.baseAddress,
                    width: slotWidth,
                    height: slotHeight,
                    bitsPerComponent: 8,
                    bytesPerRow: bytesPerRow,
                    space: CGColorSpaceCreateDeviceRGB(),
                    bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue
                        | CGBitmapInfo.byteOrder32Little.rawValue
                )
            case .monochrome:
                let colorSpace = CGColorSpace(name: CGColorSpace.linearGray)
                    ?? CGColorSpaceCreateDeviceGray()
                context = CGContext(
                    data: raw.baseAddress,
                    width: slotWidth,
                    height: slotHeight,
                    bitsPerComponent: 8,
                    bytesPerRow: bytesPerRow,
                    space: colorSpace,
                    bitmapInfo: CGImageAlphaInfo.alphaOnly.rawValue
                )
            }
            guard let context else { return false }

            context.scaleBy(x: scale, y: scale)
            switch format {
            case .colorBGRA:
                context.setFillColor(.white)
            case .monochrome:
                configureMonochromeContext(context)
            }
            context.textPosition = CGPoint(x: 0, y: baselineFromBottom / scale)
            CTLineDraw(line, context)
            return true
        }
        guard rendered else { return nil }
        return GlyphBitmap(
            bytes: bitmap,
            width: slotWidth,
            height: slotHeight,
            bytesPerRow: bytesPerRow,
            format: format
        )
    }

    private func isColor(_ line: CTLine) -> Bool {
        guard let runs = CTLineGetGlyphRuns(line) as? [CTRun] else { return false }
        return runs.contains { run in
            let attributes = CTRunGetAttributes(run) as NSDictionary
            guard let runFont = attributes[kCTFontAttributeName] else { return false }
            return CTFontGetSymbolicTraits(runFont as! CTFont).contains(.traitColorGlyphs)
        }
    }

    private func configureMonochromeContext(_ context: CGContext) {
        context.setAllowsFontSmoothing(true)
        context.setShouldSmoothFonts(fontThicken)
        context.setAllowsFontSubpixelPositioning(true)
        context.setShouldSubpixelPositionFonts(true)
        context.setAllowsFontSubpixelQuantization(false)
        context.setShouldSubpixelQuantizeFonts(false)
        context.setAllowsAntialiasing(true)
        context.setShouldAntialias(true)
        let strength = CGFloat(fontThickenStrength) / 255
        context.setFillColor(gray: strength, alpha: 1)
        context.setStrokeColor(gray: strength, alpha: 1)
    }
}
