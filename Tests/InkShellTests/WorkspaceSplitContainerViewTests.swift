import AppKit
import InkTerminalView
import Testing
@testable import InkShell

@Suite("稳定分屏容器")
@MainActor
struct WorkspaceSplitContainerViewTests {

    @Test("连续布局不会把子视图压到零")
    func repeatedLayoutKeepsEveryChildVisible() {
        let container = WorkspaceSplitContainerView(
            splitID: SplitID(), axis: .topBottom,
            weights: [0.5, 0.25, 0.125, 0.0625, 0.0625]
        )
        container.frame = NSRect(x: 0, y: 0, width: 900, height: 600)
        let children = (0..<5).map { _ in NSView() }
        children.forEach(container.addPaneSubview)

        for _ in 0..<3 {
            container.needsLayout = true
            container.layoutSubtreeIfNeeded()
        }

        #expect(children.allSatisfy { $0.frame.height > 1 })
    }

    @Test("纵向布局从上到下并按权重分配")
    func verticalLayoutUsesFlippedCoordinatesAndWeights() {
        let container = WorkspaceSplitContainerView(
            splitID: SplitID(), axis: .topBottom, weights: [0.25, 0.75]
        )
        container.frame = NSRect(x: 0, y: 0, width: 800, height: 400)
        let first = NSView()
        let second = NSView()
        container.addPaneSubview(first)
        container.addPaneSubview(second)

        container.layoutSubtreeIfNeeded()

        #expect(container.isFlipped)
        #expect(first.frame.minY == 0)
        #expect(second.frame.minY > first.frame.maxY)
        #expect(second.frame.height > first.frame.height * 2.9)
    }

    @Test("窗口缩放后保持横向权重")
    func resizePreservesHorizontalWeights() {
        let container = WorkspaceSplitContainerView(
            splitID: SplitID(), axis: .leftRight, weights: [0.3, 0.7]
        )
        let first = NSView()
        let second = NSView()
        container.addPaneSubview(first)
        container.addPaneSubview(second)
        container.frame = NSRect(x: 0, y: 0, width: 500, height: 300)
        container.layoutSubtreeIfNeeded()

        container.frame.size.width = 1_000
        container.needsLayout = true
        container.layoutSubtreeIfNeeded()

        #expect(first.frame.width > 290 && first.frame.width < 310)
        #expect(second.frame.width > 690 && second.frame.width < 710)
        #expect(first.frame.height == 300)
        #expect(second.frame.height == 300)
    }

    @Test("拖动只改变 divider 两侧并在结束时提交一次")
    func dragChangesAdjacentPairAndCommitsOnce() {
        let splitID = SplitID()
        let container = WorkspaceSplitContainerView(
            splitID: splitID, axis: .leftRight, weights: [0.25, 0.25, 0.5]
        )
        container.frame = NSRect(x: 0, y: 0, width: 800, height: 500)
        (0..<3).forEach { _ in container.addPaneSubview(NSView()) }
        container.layoutSubtreeIfNeeded()
        var submissions: [(SplitID, [Double])] = []
        container.onWeightsChange = { id, weights in submissions.append((id, weights)) }

        #expect(container.beginDividerDrag(at: NSPoint(x: 200, y: 250)))
        container.updateDividerDrag(to: NSPoint(x: 280, y: 250))
        #expect(container.weights[0] > 0.25)
        #expect(container.weights[1] < 0.25)
        #expect(abs(container.weights[2] - 0.5) < 0.001)
        #expect(submissions.isEmpty)

        container.endDividerDrag()
        #expect(submissions.count == 1)
        #expect(submissions.first?.0 == splitID)
        #expect(abs((submissions.first?.1.reduce(0, +) ?? 0) - 1) < 0.0001)
    }

    @Test("拖动不能把相邻 pane 压到零")
    func dragPreservesMinimumPaneLength() {
        let container = WorkspaceSplitContainerView(
            splitID: SplitID(), axis: .topBottom, weights: [0.5, 0.5]
        )
        container.frame = NSRect(x: 0, y: 0, width: 300, height: 200)
        let first = NSView()
        let second = NSView()
        container.addPaneSubview(first)
        container.addPaneSubview(second)
        container.layoutSubtreeIfNeeded()

        #expect(container.beginDividerDrag(at: NSPoint(x: 150, y: 100)))
        container.updateDividerDrag(to: NSPoint(x: 150, y: -1_000))
        container.layoutSubtreeIfNeeded()

        #expect(first.frame.height >= 48)
        #expect(second.frame.height >= 48)
    }

    @Test("大字号终端拖动后仍保留十列三行")
    func dragPreservesMinimumGridAtLargeFont() {
        let container = WorkspaceSplitContainerView(
            splitID: SplitID(), axis: .leftRight, weights: [0.5, 0.5]
        )
        container.frame = NSRect(x: 0, y: 0, width: 1_600, height: 700)
        let first = terminalPane(fontSize: 72)
        let second = terminalPane(fontSize: 72)
        container.addPaneSubview(first)
        container.addPaneSubview(second)
        container.layoutSubtreeIfNeeded()

        #expect(container.beginDividerDrag(at: NSPoint(x: 800, y: 350)))
        container.updateDividerDrag(to: NSPoint(x: 0, y: 350))
        container.layoutSubtreeIfNeeded()

        #expect(first.frame.width + 0.001 >= first.minimumSplitSize.width)
        #expect(second.frame.width + 0.001 >= second.minimumSplitSize.width)
        #expect(first.minimumSplitSize.width > 80)
        #expect(first.minimumSplitSize.height > 48)
    }

    @Test("嵌套子树的最小尺寸会递归约束外层 divider")
    func dragPreservesNestedSubtreeMinimum() {
        let nested = WorkspaceSplitContainerView(
            splitID: SplitID(), axis: .leftRight, weights: [0.5, 0.5]
        )
        nested.addPaneSubview(FixedMinimumView(width: 250, height: 60))
        nested.addPaneSubview(FixedMinimumView(width: 250, height: 60))

        let root = WorkspaceSplitContainerView(
            splitID: SplitID(), axis: .leftRight, weights: [0.5, 0.5]
        )
        root.frame = NSRect(x: 0, y: 0, width: 800, height: 400)
        root.addPaneSubview(nested)
        root.addPaneSubview(FixedMinimumView(width: 100, height: 60))
        root.layoutSubtreeIfNeeded()

        #expect(root.beginDividerDrag(at: NSPoint(x: 400, y: 200)))
        root.updateDividerDrag(to: NSPoint(x: 0, y: 200))
        root.layoutSubtreeIfNeeded()

        #expect(nested.frame.width >= 501)
        #expect(root.subviews[1].frame.width >= 100)
    }

    @Test("分隔线命中区域外不开始拖动")
    func dragRequiresDividerHit() {
        let container = WorkspaceSplitContainerView(
            splitID: SplitID(), axis: .leftRight, weights: [0.5, 0.5]
        )
        container.frame = NSRect(x: 0, y: 0, width: 600, height: 400)
        container.addPaneSubview(NSView())
        container.addPaneSubview(NSView())
        container.layoutSubtreeIfNeeded()

        #expect(!container.beginDividerDrag(at: NSPoint(x: 50, y: 200)))
    }

    @Test("扩展命中区域由容器接收鼠标事件")
    func expandedDividerHitAreaRoutesToContainer() {
        let container = WorkspaceSplitContainerView(
            splitID: SplitID(), axis: .leftRight, weights: [0.5, 0.5]
        )
        container.frame = NSRect(x: 0, y: 0, width: 600, height: 400)
        container.addPaneSubview(NSView())
        container.addPaneSubview(NSView())
        container.layoutSubtreeIfNeeded()
        let pointInsideSecondPane = NSPoint(
            x: container.subviews[0].frame.maxX + 2,
            y: 200
        )

        #expect(container.hitTest(pointInsideSecondPane) === container)
    }

    private func terminalPane(fontSize: CGFloat) -> TerminalPaneContainerView {
        let terminalView = TerminalMetalView(frame: .zero)
        terminalView.fontSize = fontSize
        terminalView.lineHeightMultiplier = 1.2
        return TerminalPaneContainerView(paneID: PaneID(), terminalView: terminalView)
    }
}

@MainActor
private final class FixedMinimumView: NSView, WorkspaceSplitMinimumSizing {
    let minimumSplitSize: NSSize

    init(width: CGFloat, height: CGFloat) {
        minimumSplitSize = NSSize(width: width, height: height)
        super.init(frame: .zero)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("代码构建，不支持 nib")
    }
}
