import AppKit
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
}
