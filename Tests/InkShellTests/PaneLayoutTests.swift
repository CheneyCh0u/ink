import Testing
@testable import InkShell

@Suite("终端分屏布局")
struct PaneLayoutTests {

    @Test("向右分屏创建左右分组并聚焦新 pane")
    func splitRight() {
        let original = PaneID()
        let created = PaneID()
        var layout = PaneLayout.leaf(original)

        let changed = layout.split(target: original, newPane: created, direction: .right)

        #expect(changed)
        guard case let .group(_, axis, weights, children) = layout else {
            Issue.record("叶节点没有变成分组")
            return
        }
        #expect(axis == .leftRight)
        #expect(weights == [0.5, 0.5])
        #expect(children == [.leaf(original), .leaf(created)])
    }

    @Test("左侧和上方分屏把新 pane 插在目标前面")
    func leadingDirectionsInsertBeforeTarget() {
        let original = PaneID()
        let left = PaneID()
        var horizontal = PaneLayout.leaf(original)
        _ = horizontal.split(target: original, newPane: left, direction: .left)

        let top = PaneID()
        var vertical = PaneLayout.leaf(original)
        _ = vertical.split(target: original, newPane: top, direction: .up)

        guard case let .group(_, horizontalAxis, _, horizontalChildren) = horizontal,
              case let .group(_, verticalAxis, _, verticalChildren) = vertical else {
            Issue.record("没有形成四方向分组")
            return
        }
        #expect(horizontalAxis == .leftRight)
        #expect(horizontalChildren == [.leaf(left), .leaf(original)])
        #expect(verticalAxis == .topBottom)
        #expect(verticalChildren == [.leaf(top), .leaf(original)])
    }

    @Test("连续向下分屏复用同一个多子项分组")
    func repeatedDownSplitsReuseGroup() {
        let first = PaneID()
        let second = PaneID()
        let third = PaneID()
        var layout = PaneLayout.leaf(first)
        _ = layout.split(target: first, newPane: second, direction: .down)

        let changed = layout.split(target: second, newPane: third, direction: .down)

        #expect(changed)
        guard case let .group(_, axis, weights, children) = layout else {
            Issue.record("没有形成多子项分组")
            return
        }
        #expect(axis == .topBottom)
        #expect(weights == [0.5, 0.25, 0.25])
        #expect(children == [.leaf(first), .leaf(second), .leaf(third)])
    }

    @Test("方向变化时嵌套分组")
    func changingDirectionNestsGroup() {
        let left = PaneID()
        let right = PaneID()
        let bottom = PaneID()
        var layout = PaneLayout.leaf(left)
        _ = layout.split(target: left, newPane: right, direction: .right)

        let changed = layout.split(target: right, newPane: bottom, direction: .down)

        #expect(changed)
        #expect(layout.contains(left))
        #expect(layout.contains(right))
        #expect(layout.contains(bottom))
        #expect(layout.paneCount == 3)
        guard case let .group(_, .leftRight, _, children) = layout,
              case .group(_, .topBottom, _, _) = children[1] else {
            Issue.record("方向变化没有形成嵌套分组")
            return
        }
    }

    @Test("关闭多子项分组中间 pane 后选择后一个 pane")
    func removingMiddlePaneFocusesFollowingPane() throws {
        let first = PaneID()
        let middle = PaneID()
        let last = PaneID()
        var layout = PaneLayout.leaf(first)
        _ = layout.split(target: first, newPane: middle, direction: .right)
        _ = layout.split(target: middle, newPane: last, direction: .right)

        let removal = try #require(layout.removing(middle))

        #expect(removal.layout?.paneCount == 2)
        #expect(removal.layout?.contains(first) == true)
        #expect(removal.layout?.contains(last) == true)
        #expect(removal.focusPaneID == last)
    }

    @Test("关闭嵌套叶节点后收拢分组")
    func removingNestedLeafPromotesSibling() throws {
        let left = PaneID()
        let top = PaneID()
        let bottom = PaneID()
        var layout = PaneLayout.leaf(left)
        _ = layout.split(target: left, newPane: top, direction: .right)
        _ = layout.split(target: top, newPane: bottom, direction: .down)

        let removal = try #require(layout.removing(top))

        #expect(removal.layout?.paneCount == 2)
        #expect(removal.layout?.contains(left) == true)
        #expect(removal.layout?.contains(bottom) == true)
        #expect(removal.focusPaneID == bottom)
    }

    @Test("删除末尾 pane 时选择前一个子树最末叶节点")
    func removalFocusesPreviousSiblingLeaf() throws {
        let leftTop = PaneID()
        let leftBottom = PaneID()
        let right = PaneID()
        var layout = PaneLayout.leaf(leftTop)
        _ = layout.split(target: leftTop, newPane: leftBottom, direction: .down)
        let leftGroup = layout
        layout = .group(
            id: SplitID(), axis: .leftRight, weights: [0.6, 0.4],
            children: [leftGroup, .leaf(right)]
        )

        let removal = try #require(layout.removing(right))

        #expect(removal.focusPaneID == leftBottom)
        #expect(removal.layout == leftGroup)
    }

    @Test("删除唯一 pane 后布局为空")
    func removingOnlyPaneReturnsEmptyLayout() throws {
        let only = PaneID()

        let removal = try #require(PaneLayout.leaf(only).removing(only))

        #expect(removal.layout == nil)
        #expect(removal.focusPaneID == nil)
    }

    @Test("权重按 SplitID 更新并归一化")
    func updateWeightsBySplitID() {
        let splitID = SplitID()
        var layout = PaneLayout.group(
            id: splitID, axis: .leftRight, weights: [0.5, 0.5],
            children: [.leaf(PaneID()), .leaf(PaneID())]
        )

        let changed = layout.updateWeights(for: splitID, to: [1, 3])

        #expect(changed)
        guard case let .group(_, _, weights, _) = layout else {
            Issue.record("布局不再是分组")
            return
        }
        #expect(weights == [0.25, 0.75])
    }

    @Test("拒绝数量不匹配或非正的权重")
    func rejectsInvalidWeights() {
        let splitID = SplitID()
        var layout = PaneLayout.group(
            id: splitID, axis: .leftRight, weights: [0.5, 0.5],
            children: [.leaf(PaneID()), .leaf(PaneID())]
        )

        let acceptedMismatchedCount = layout.updateWeights(for: splitID, to: [1])
        let acceptedZeroWeight = layout.updateWeights(for: splitID, to: [0, 1])

        #expect(!acceptedMismatchedCount)
        #expect(!acceptedZeroWeight)
    }

    @Test("相邻 pane 按视觉方向双向选择且边界为空")
    func neighborUsesVisualDirectionAndStopsAtBoundary() {
        let topLeft = PaneID()
        let bottomLeft = PaneID()
        let topRight = PaneID()
        let bottomRight = PaneID()
        let layout = PaneLayout.group(
            id: SplitID(), axis: .leftRight, weights: [0.4, 0.6],
            children: [
                .group(
                    id: SplitID(), axis: .topBottom, weights: [0.7, 0.3],
                    children: [.leaf(topLeft), .leaf(bottomLeft)]
                ),
                .group(
                    id: SplitID(), axis: .topBottom, weights: [0.7, 0.3],
                    children: [.leaf(topRight), .leaf(bottomRight)]
                ),
            ]
        )

        #expect(layout.neighbor(of: topLeft, direction: .right) == topRight)
        #expect(layout.neighbor(of: topRight, direction: .left) == topLeft)
        #expect(layout.neighbor(of: topLeft, direction: .down) == bottomLeft)
        #expect(layout.neighbor(of: bottomLeft, direction: .up) == topLeft)
        #expect(layout.neighbor(of: topLeft, direction: .left) == nil)
        #expect(layout.neighbor(of: bottomRight, direction: .down) == nil)
    }

    @Test("T 形候选先比中心距离再按布局顺序稳定决胜")
    func tShapeUsesCenterDistanceThenDFSOrder() {
        let left = PaneID()
        let rightTop = PaneID()
        let rightBottom = PaneID()
        let tied = PaneLayout.group(
            id: SplitID(), axis: .leftRight, weights: [0.5, 0.5],
            children: [
                .leaf(left),
                .group(
                    id: SplitID(), axis: .topBottom, weights: [0.5, 0.5],
                    children: [.leaf(rightTop), .leaf(rightBottom)]
                ),
            ]
        )
        #expect(tied.neighbor(of: left, direction: .right) == rightTop)

        let nearBottom = PaneLayout.group(
            id: SplitID(), axis: .leftRight, weights: [0.5, 0.5],
            children: [
                .leaf(left),
                .group(
                    id: SplitID(), axis: .topBottom, weights: [0.3, 0.7],
                    children: [.leaf(rightTop), .leaf(rightBottom)]
                ),
            ]
        )
        #expect(nearBottom.neighbor(of: left, direction: .right) == rightBottom)
    }

    @Test("嵌套偏移中的数学同分仍按布局顺序决胜")
    func nestedOffsetTieUsesDFSOrderDespiteRounding() {
        let spacer = PaneID()
        let left = PaneID()
        let rightTop = PaneID()
        let rightBottom = PaneID()
        let layout = PaneLayout.group(
            id: SplitID(), axis: .topBottom, weights: [0.002, 0.998],
            children: [
                .leaf(spacer),
                .group(
                    id: SplitID(), axis: .leftRight, weights: [0.5, 0.5],
                    children: [
                        .leaf(left),
                        .group(
                            id: SplitID(), axis: .topBottom, weights: [0.5, 0.5],
                            children: [.leaf(rightTop), .leaf(rightBottom)]
                        ),
                    ]
                ),
            ]
        )

        #expect(layout.neighbor(of: left, direction: .right) == rightTop)
    }

    @Test("运行时几何计入分隔线后选择屏幕中心更近的 pane")
    func viewportGeometryAccountsForDividers() {
        let topLeft = PaneID()
        let bottomLeft = PaneID()
        let topRight = PaneID()
        let bottomRight = PaneID()
        let layout = PaneLayout.group(
            id: SplitID(), axis: .leftRight, weights: [0.5, 0.5],
            children: [
                .group(
                    id: SplitID(), axis: .topBottom,
                    weights: [299.0 / 399.0, 100.0 / 399.0],
                    children: [.leaf(topLeft), .leaf(bottomLeft)]
                ),
                .group(
                    id: SplitID(), axis: .topBottom,
                    weights: [99.0 / 399.0, 300.0 / 399.0],
                    children: [.leaf(topRight), .leaf(bottomRight)]
                ),
            ]
        )

        #expect(layout.neighbor(of: topLeft, direction: .right) == bottomRight)
        #expect(layout.neighbor(
            of: topLeft,
            direction: .right,
            geometry: PaneNavigationGeometry(
                width: 800,
                height: 400,
                dividerThickness: 1
            )
        ) == topRight)
    }

    @Test("零面积 active 可沿压缩轴逃到可见 pane")
    func zeroAreaActiveCanEscapeToVisiblePane() {
        let collapsedActive = PaneID()
        let collapsedSibling = PaneID()
        let visible = PaneID()
        let layout = PaneLayout.group(
            id: SplitID(), axis: .leftRight, weights: [0.01, 0.99],
            children: [
                .group(
                    id: SplitID(), axis: .leftRight, weights: [0.5, 0.5],
                    children: [.leaf(collapsedActive), .leaf(collapsedSibling)]
                ),
                .leaf(visible),
            ]
        )

        #expect(layout.neighbor(
            of: collapsedActive,
            direction: .right,
            geometry: PaneNavigationGeometry(
                width: 100,
                height: 400,
                dividerThickness: 1
            )
        ) == visible)
    }

    @Test("可见 active 不会进入零面积目标")
    func zeroAreaCandidateIsRejected() {
        let visibleActive = PaneID()
        let collapsedLeft = PaneID()
        let collapsedRight = PaneID()
        let layout = PaneLayout.group(
            id: SplitID(), axis: .leftRight, weights: [0.99, 0.01],
            children: [
                .leaf(visibleActive),
                .group(
                    id: SplitID(), axis: .leftRight, weights: [0.5, 0.5],
                    children: [.leaf(collapsedLeft), .leaf(collapsedRight)]
                ),
            ]
        )

        #expect(layout.neighbor(
            of: visibleActive,
            direction: .right,
            geometry: PaneNavigationGeometry(
                width: 100,
                height: 400,
                dividerThickness: 1
            )
        ) == nil)
    }

    @Test("对角 pane 不跳转且无效权重等分回退")
    func diagonalIsRejectedAndInvalidWeightsFallBackEqually() {
        let topLeft = PaneID()
        let topRight = PaneID()
        let bottomRight = PaneID()
        let diagonal = PaneLayout.group(
            id: SplitID(), axis: .topBottom, weights: [0.5, 0.5],
            children: [
                .group(
                    id: SplitID(), axis: .leftRight, weights: [0.5, 0.5],
                    children: [.leaf(topLeft), .leaf(topRight)]
                ),
                .group(
                    id: SplitID(), axis: .leftRight, weights: [1, 0],
                    children: [.leaf(PaneID()), .leaf(bottomRight)]
                ),
            ]
        )
        let unchanged = diagonal

        #expect(diagonal.neighbor(of: topLeft, direction: .down) != bottomRight)
        #expect(diagonal.neighbor(of: topRight, direction: .down) == bottomRight)
        #expect(diagonal.neighbor(of: PaneID(), direction: .right) == nil)
        #expect(diagonal == unchanged)

        let mismatched = PaneLayout.group(
            id: SplitID(), axis: .leftRight, weights: [1],
            children: [.leaf(topLeft), .leaf(topRight)]
        )
        #expect(mismatched.neighbor(of: topLeft, direction: .right) == topRight)
    }
}
