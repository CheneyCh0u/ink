import Foundation
import InkDesign

struct TabBarLayout: Equatable {
    let visibleRange: Range<Int>
    let hiddenIndices: [Int]
    let widths: [CGFloat]

    var showsOverflow: Bool { !hiddenIndices.isEmpty }

    static func resolve(
        preferredWidths: [CGFloat],
        activeIndex: Int,
        availableWidth: CGFloat,
        previousVisibleRange: Range<Int>? = nil
    ) -> TabBarLayout {
        let count = preferredWidths.count
        guard count > 0 else {
            return TabBarLayout(visibleRange: 0..<0, hiddenIndices: [], widths: [])
        }

        let token = InkDesignTokens.TabBar.self
        let available = availableWidth.isFinite ? max(0, availableWidth) : 0
        let active = min(max(activeIndex, 0), count - 1)
        let preferred = preferredWidths.map { value in
            guard value.isFinite else { return token.idealTabWidth }
            return min(max(value, token.idealTabWidth), token.maximumTabWidth)
        }

        if minimumTotalWidth(count: count) <= available {
            return TabBarLayout(
                visibleRange: 0..<count,
                hiddenIndices: [],
                widths: fittedWidths(preferred, availableWidth: available)
            )
        }

        let tabArea = max(
            0,
            available - token.overflowButtonWidth - token.itemSpacing
        )
        let capacity = max(
            1,
            min(
                count,
                Int(floor(
                    (tabArea + token.itemSpacing)
                        / (token.minimumTabWidth + token.itemSpacing)
                ))
            )
        )
        let maxStart = count - capacity
        var start = min(max(previousVisibleRange?.lowerBound ?? 0, 0), maxStart)
        if active < start {
            start = active
        } else if active >= start + capacity {
            start = active - capacity + 1
        }
        start = min(max(start, 0), maxStart)

        let range = start..<(start + capacity)
        let hidden = Array(0..<range.lowerBound) + Array(range.upperBound..<count)
        let visiblePreferred = Array(preferred[range])
        let usableTabArea = max(tabArea, minimumTotalWidth(count: capacity))
        return TabBarLayout(
            visibleRange: range,
            hiddenIndices: hidden,
            widths: fittedWidths(visiblePreferred, availableWidth: usableTabArea)
        )
    }

    private static func minimumTotalWidth(count: Int) -> CGFloat {
        guard count > 0 else { return 0 }
        let token = InkDesignTokens.TabBar.self
        return CGFloat(count) * token.minimumTabWidth
            + CGFloat(count - 1) * token.itemSpacing
    }

    private static func fittedWidths(
        _ preferred: [CGFloat],
        availableWidth: CGFloat
    ) -> [CGFloat] {
        guard !preferred.isEmpty else { return [] }
        let token = InkDesignTokens.TabBar.self
        let spacing = CGFloat(preferred.count - 1) * token.itemSpacing
        let contentWidth = max(0, availableWidth - spacing)
        let preferredTotal = preferred.reduce(0, +)
        guard preferredTotal > contentWidth else { return preferred }

        let shrinkable = preferred.reduce(0) {
            $0 + max(0, $1 - token.minimumTabWidth)
        }
        guard shrinkable > 0 else {
            return Array(repeating: token.minimumTabWidth, count: preferred.count)
        }
        let ratio = min(1, max(0, (preferredTotal - contentWidth) / shrinkable))
        return preferred.map {
            max(
                token.minimumTabWidth,
                $0 - ($0 - token.minimumTabWidth) * ratio
            )
        }
    }
}
