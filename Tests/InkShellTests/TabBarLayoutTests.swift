import Foundation
import InkDesign
import Testing
@testable import InkShell

@Suite("标签栏溢出布局")
struct TabBarLayoutTests {
    @Test("全部标签可见时保留首选宽度")
    func allTabsUsePreferredWidths() {
        let result = TabBarLayout.resolve(
            preferredWidths: [168, 200],
            activeIndex: 0,
            availableWidth: 374
        )

        #expect(result.visibleRange == 0..<2)
        #expect(result.hiddenIndices.isEmpty)
        #expect(result.widths == [168, 200])
        #expect(!result.showsOverflow)
    }

    @Test("首选宽度放不下时公平压缩但不低于最小值")
    func compressesTowardMinimum() {
        let result = TabBarLayout.resolve(
            preferredWidths: [240, 240],
            activeIndex: 0,
            availableWidth: 330
        )

        #expect(result.visibleRange == 0..<2)
        #expect(abs(result.widths[0] - 162) < 0.001)
        #expect(abs(result.widths[1] - 162) < 0.001)
        #expect(result.widths.allSatisfy { $0 >= InkDesignTokens.TabBar.minimumTabWidth })
    }

    @Test("刚好达到最小总宽时不溢出，少一磅时进入菜单")
    func thresholdIncludesSpacing() {
        let fits = TabBarLayout.resolve(
            preferredWidths: [168, 168, 168],
            activeIndex: 1,
            availableWidth: 348
        )
        let overflows = TabBarLayout.resolve(
            preferredWidths: [168, 168, 168],
            activeIndex: 1,
            availableWidth: 347
        )

        #expect(fits.visibleRange == 0..<3)
        #expect(!fits.showsOverflow)
        #expect(overflows.visibleRange == 0..<2)
        #expect(overflows.hiddenIndices == [2])
        #expect(overflows.showsOverflow)
    }

    @Test("活动标签留在区间内时不移动，越界时只移动一格")
    func minimallyMovesVisibleRange() {
        let stable = TabBarLayout.resolve(
            preferredWidths: Array(repeating: 168, count: 6),
            activeIndex: 2,
            availableWidth: 347,
            previousVisibleRange: 2..<4
        )
        let moved = TabBarLayout.resolve(
            preferredWidths: Array(repeating: 168, count: 6),
            activeIndex: 4,
            availableWidth: 347,
            previousVisibleRange: 2..<4
        )

        #expect(stable.visibleRange == 2..<4)
        #expect(moved.visibleRange == 3..<5)
        #expect(moved.hiddenIndices == [0, 1, 2, 5])
    }

    @Test("容量为一时首中尾活动标签都可见")
    func oneVisibleTabContainsActiveIndex() {
        for active in [0, 2, 4] {
            let result = TabBarLayout.resolve(
                preferredWidths: Array(repeating: 168, count: 5),
                activeIndex: active,
                availableWidth: 160
            )
            #expect(result.visibleRange == active..<(active + 1))
            #expect(!result.hiddenIndices.contains(active))
        }
    }

    @Test("放大窗口优先向右扩展并在尾部向左补齐")
    func growingWindowFillsContiguousRange() {
        let result = TabBarLayout.resolve(
            preferredWidths: Array(repeating: 168, count: 6),
            activeIndex: 4,
            availableWidth: 465,
            previousVisibleRange: 3..<5
        )

        #expect(result.visibleRange == 3..<6)
        #expect(result.hiddenIndices == [0, 1, 2])
    }

    @Test("空标签和异常输入得到确定结果")
    func normalizesInvalidInput() {
        let empty = TabBarLayout.resolve(
            preferredWidths: [],
            activeIndex: 9,
            availableWidth: .nan
        )
        let invalid = TabBarLayout.resolve(
            preferredWidths: [.nan, .infinity, -3],
            activeIndex: -4,
            availableWidth: -.infinity
        )

        #expect(empty.visibleRange.isEmpty)
        #expect(empty.widths.isEmpty)
        #expect(!empty.showsOverflow)
        #expect(invalid.visibleRange == 0..<1)
        #expect(invalid.widths == [InkDesignTokens.TabBar.minimumTabWidth])
        #expect(invalid.hiddenIndices == [1, 2])
    }

    @Test("任一方向越界的活动索引都回退到第一个标签")
    func invalidActiveIndexFallsBackToFirstTab() {
        for active in [-1, 3, 99] {
            let result = TabBarLayout.resolve(
                preferredWidths: Array(repeating: 168, count: 3),
                activeIndex: active,
                availableWidth: 160
            )

            #expect(result.visibleRange == 0..<1)
        }
    }
}
