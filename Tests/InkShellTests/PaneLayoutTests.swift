import Testing
@testable import InkShell

@Suite("终端分屏布局")
struct PaneLayoutTests {

    @Test("左右分屏把新 pane 放在右侧并设为接替焦点")
    func splitLeftRight() {
        let original = PaneID()
        let created = PaneID()
        var layout = PaneLayout.leaf(original)

        let changed = layout.split(target: original, newPane: created, axis: .leftRight)

        #expect(changed)
        guard case let .split(_, axis, ratio, first, second) = layout else {
            Issue.record("叶节点没有变成分支")
            return
        }
        #expect(axis == .leftRight)
        #expect(ratio == 0.5)
        #expect(first == .leaf(original))
        #expect(second == .leaf(created))
    }

    @Test("可以在嵌套布局中分割任意叶节点")
    func splitNestedLeaf() {
        let left = PaneID()
        let right = PaneID()
        let bottom = PaneID()
        var layout = PaneLayout.leaf(left)
        _ = layout.split(target: left, newPane: right, axis: .leftRight)

        let changed = layout.split(target: right, newPane: bottom, axis: .topBottom)

        #expect(changed)
        #expect(layout.contains(left))
        #expect(layout.contains(right))
        #expect(layout.contains(bottom))
        #expect(layout.paneCount == 3)
    }

    @Test("关闭嵌套叶节点后提升兄弟子树")
    func removingNestedLeafPromotesSibling() throws {
        let left = PaneID()
        let top = PaneID()
        let bottom = PaneID()
        var layout = PaneLayout.leaf(left)
        _ = layout.split(target: left, newPane: top, axis: .leftRight)
        _ = layout.split(target: top, newPane: bottom, axis: .topBottom)

        let removal = try #require(layout.removing(top))

        #expect(removal.layout?.paneCount == 2)
        #expect(removal.layout?.contains(left) == true)
        #expect(removal.layout?.contains(bottom) == true)
        #expect(removal.focusPaneID == bottom)
    }

    @Test("删除非末尾 pane 时选择分隔线另一侧最近的叶节点")
    func removalFocusesNearestSiblingLeaf() throws {
        let leftTop = PaneID()
        let leftBottom = PaneID()
        let right = PaneID()
        var layout = PaneLayout.leaf(leftTop)
        _ = layout.split(target: leftTop, newPane: leftBottom, axis: .topBottom)
        let leftGroup = layout
        layout = .split(
            id: SplitID(), axis: .leftRight, ratio: 0.6,
            first: leftGroup, second: .leaf(right)
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

    @Test("拖动比例按 SplitID 更新并夹在有效范围")
    func updateRatioBySplitID() {
        let splitID = SplitID()
        var layout = PaneLayout.split(
            id: splitID, axis: .leftRight, ratio: 0.5,
            first: .leaf(PaneID()), second: .leaf(PaneID())
        )

        let changed = layout.updateRatio(for: splitID, to: 1.4)
        #expect(changed)
        guard case let .split(_, _, ratio, _, _) = layout else {
            Issue.record("布局不再是分支")
            return
        }
        #expect(ratio == 1)
    }
}
