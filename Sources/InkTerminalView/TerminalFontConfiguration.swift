import Foundation

/// 终端视图在一次 renderer 事务中使用的完整字体配置。
public struct TerminalFontConfiguration: Equatable, Sendable {
    public static let fontSizeRange: ClosedRange<CGFloat> = 6...72
    public static let lineHeightRange: ClosedRange<CGFloat> = 0.8...2
    public static let cellHeightAdjustmentRange: ClosedRange<Int> = -10...20
    public static let fontThickenStrengthRange: ClosedRange<Int> = 0...255

    public var fontFamily: String? {
        didSet { fontFamily = Self.normalizedFamily(fontFamily) }
    }
    public var fontSize: CGFloat {
        didSet { fontSize = Self.normalizedFinite(fontSize, in: Self.fontSizeRange, fallback: 14) }
    }
    public var lineHeightMultiplier: CGFloat {
        didSet {
            lineHeightMultiplier = Self.normalizedFinite(
                lineHeightMultiplier,
                in: Self.lineHeightRange,
                fallback: 1.2
            )
        }
    }
    public var cellHeightAdjustment: Int {
        didSet { cellHeightAdjustment = Self.cellHeightAdjustmentRange.clamped(cellHeightAdjustment) }
    }
    public var fontThicken: Bool
    public var fontThickenStrength: Int {
        didSet { fontThickenStrength = Self.fontThickenStrengthRange.clamped(fontThickenStrength) }
    }

    public init(
        fontFamily: String? = nil,
        fontSize: CGFloat = 14,
        lineHeightMultiplier: CGFloat = 1.2,
        cellHeightAdjustment: Int = 1,
        fontThicken: Bool = true,
        fontThickenStrength: Int = 128
    ) {
        self.fontFamily = Self.normalizedFamily(fontFamily)
        self.fontSize = Self.normalizedFinite(fontSize, in: Self.fontSizeRange, fallback: 14)
        self.lineHeightMultiplier = Self.normalizedFinite(
            lineHeightMultiplier,
            in: Self.lineHeightRange,
            fallback: 1.2
        )
        self.cellHeightAdjustment = Self.cellHeightAdjustmentRange.clamped(cellHeightAdjustment)
        self.fontThicken = fontThicken
        self.fontThickenStrength = Self.fontThickenStrengthRange.clamped(fontThickenStrength)
    }

    private static func normalizedFamily(_ family: String?) -> String? {
        guard let family, !family.isEmpty else { return nil }
        return family
    }

    private static func normalizedFinite(
        _ value: CGFloat,
        in range: ClosedRange<CGFloat>,
        fallback: CGFloat
    ) -> CGFloat {
        guard value.isFinite else { return fallback }
        return range.clamped(value)
    }
}

private extension ClosedRange where Bound: Comparable {
    func clamped(_ value: Bound) -> Bound {
        Swift.min(Swift.max(value, lowerBound), upperBound)
    }
}
