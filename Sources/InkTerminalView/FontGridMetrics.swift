import AppKit

/// 终端网格的物理像素字体度量。
struct FontGridMetrics {
    let cellWidth: CGFloat
    let naturalHeight: CGFloat
    let cellHeight: CGFloat
    let baselineFromBottom: CGFloat

    init(
        font: NSFont,
        scale: CGFloat,
        lineHeightMultiplier: CGFloat,
        cellHeightAdjustment: Int
    ) {
        let advance = ("0" as NSString).size(withAttributes: [.font: font]).width
        cellWidth = ceil(advance * scale)
        naturalHeight = ceil(NSLayoutManager().defaultLineHeight(for: font) * scale)
        let scaledHeight = ceil(naturalHeight * max(0.8, lineHeightMultiplier))
        cellHeight = max(1, scaledHeight + CGFloat(cellHeightAdjustment))
        let extra = cellHeight - naturalHeight
        baselineFromBottom = ceil(-font.descender * scale) + floor(extra / 2)
    }
}
