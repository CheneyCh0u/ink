import AppKit
import InkConfig
import TerminalCore
import Testing
@testable import InkShell

@Suite("终端分屏工作区")
@MainActor
struct TerminalWorkspaceTests {

    @Test("连续向下分屏并重建时每个 pane 都有可见高度")
    func repeatedTopBottomSplitsKeepEveryPaneVisible() throws {
        let first = makePane()
        let tab = TerminalTab(initialPane: first)
        let workspace = TerminalWorkspaceViewController()
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 900, height: 600),
            styleMask: [.titled, .resizable],
            backing: .buffered,
            defer: false
        )
        window.contentViewController = workspace
        window.orderFront(nil)
        workspace.view.frame = NSRect(x: 0, y: 0, width: 900, height: 600)

        workspace.show(tab: tab, config: InkConfig())
        workspace.view.layoutSubtreeIfNeeded()

        var target = first
        for _ in 0..<4 {
            let created = makePane()
            _ = tab.insertPane(created, splitting: target.id, direction: .down)
            #expect(
                splitWeights(in: tab.layout).allSatisfy { $0 > 0 && $0 < 1 },
                "插入 pane 后权重不应塌缩"
            )
            workspace.show(tab: tab, config: InkConfig())
            #expect(
                splitWeights(in: tab.layout).allSatisfy { $0 > 0 && $0 < 1 },
                "show 后、layout 前权重不应塌缩"
            )
            workspace.view.layoutSubtreeIfNeeded()
            #expect(
                splitWeights(in: tab.layout).allSatisfy { $0 > 0 && $0 < 1 },
                "首次 layout 后权重不应塌缩"
            )
            target = created
        }

        let splitView = try #require(
            allSubviews(in: workspace.view).compactMap { $0 as? WorkspaceSplitView }.first
        )
        #expect(workspace.view.frame.height > 1)
        #expect(splitView.frame.height > 1)
        #expect(splitView.subviews.count == 5)
        #expect(splitWeights(in: tab.layout).allSatisfy { $0 > 0 && $0 < 1 })
        for pane in tab.allPanes {
            let paneView = try #require(workspace.paneContainer(for: pane.id))
            #expect(paneView.frame.height > 1)
        }
    }

    @Test("递归布局创建左右与上下两种 NSSplitView")
    func buildsNestedSplitViews() {
        let first = makePane()
        let second = makePane()
        let third = makePane()
        let tab = TerminalTab(initialPane: first)
        _ = tab.insertPane(second, splitting: first.id, direction: .right)
        _ = tab.insertPane(third, splitting: second.id, direction: .down)
        let workspace = TerminalWorkspaceViewController()
        workspace.view.frame = NSRect(x: 0, y: 0, width: 900, height: 600)

        workspace.show(tab: tab, config: InkConfig())
        workspace.view.layoutSubtreeIfNeeded()

        let splitViews = allSubviews(in: workspace.view).compactMap { $0 as? WorkspaceSplitView }
        #expect(splitViews.count == 2)
        #expect(splitViews.contains { $0.isVertical })
        #expect(splitViews.contains { !$0.isVertical })
    }

    @Test("只有活动 pane 显示焦点边框")
    func marksOnlyActivePane() throws {
        let first = makePane()
        let second = makePane()
        let tab = TerminalTab(initialPane: first)
        _ = tab.insertPane(second, splitting: first.id, direction: .right)
        let workspace = TerminalWorkspaceViewController()

        workspace.show(tab: tab, config: InkConfig())

        let firstView = try #require(workspace.paneContainer(for: first.id))
        let secondView = try #require(workspace.paneContainer(for: second.id))
        #expect(!firstView.isActive)
        #expect(secondView.isActive)

        workspace.activate(first.id)
        #expect(firstView.isActive)
        #expect(!secondView.isActive)
    }

    @Test("切换标签后旧 pane 视图不再由工作区持有")
    func switchingTabsReleasesOldPaneViews() {
        let firstPane = makePane()
        let secondPane = makePane()
        let firstTab = TerminalTab(initialPane: firstPane)
        let secondTab = TerminalTab(initialPane: secondPane)
        let workspace = TerminalWorkspaceViewController()

        workspace.show(tab: firstTab, config: InkConfig())
        weak let oldContainer = workspace.paneContainer(for: firstPane.id)

        workspace.show(tab: secondTab, config: InkConfig())

        #expect(oldContainer?.superview == nil)
        #expect(workspace.paneContainer(for: firstPane.id) == nil)
        #expect(workspace.paneContainer(for: secondPane.id) != nil)
    }

    private func makePane() -> TerminalPane {
        TerminalPane(session: TerminalSession(size: TerminalSize(columns: 80, rows: 24)))
    }

    private func allSubviews(in view: NSView) -> [NSView] {
        view.subviews.flatMap { [$0] + allSubviews(in: $0) }
    }

    private func splitWeights(in layout: PaneLayout) -> [Double] {
        switch layout {
        case .leaf:
            []
        case let .group(_, _, weights, children):
            weights + children.flatMap(splitWeights)
        }
    }
}
