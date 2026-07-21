import AppKit
import Testing
@testable import InkTerminalView

@Suite("字体网格度量")
struct FontGridMetricsTests {

    @Test("cell 高度调整使用物理像素")
    func adjustmentUsesPhysicalPixels() {
        let font = NSFont.monospacedSystemFont(ofSize: 14, weight: .regular)
        let base = FontGridMetrics(
            font: font, scale: 2, lineHeightMultiplier: 1,
            cellHeightAdjustment: 0
        )
        let adjusted = FontGridMetrics(
            font: font, scale: 2, lineHeightMultiplier: 1,
            cellHeightAdjustment: 1
        )
        #expect(adjusted.cellHeight == base.cellHeight + 1)
        #expect(adjusted.cellWidth == base.cellWidth)
    }

    @Test("负调整不能把 cell 压到零")
    func adjustmentClampsCellHeight() {
        let font = NSFont.monospacedSystemFont(ofSize: 6, weight: .regular)
        let metrics = FontGridMetrics(
            font: font, scale: 2, lineHeightMultiplier: 0.8,
            cellHeightAdjustment: -10_000
        )
        #expect(metrics.cellHeight == 1)
    }
}
