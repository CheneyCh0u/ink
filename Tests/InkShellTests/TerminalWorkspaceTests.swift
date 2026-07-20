import AppKit
import InkConfig
import TerminalCore
import Testing
@testable import InkShell

@Suite("终端分屏工作区")
@MainActor
struct TerminalWorkspaceTests {

    @Test("递归布局创建左右与上下两种 NSSplitView")
    func buildsNestedSplitViews() {
        let first = makePane()
        let second = makePane()
        let third = makePane()
        let tab = TerminalTab(initialPane: first)
        _ = tab.insertPane(second, splitting: first.id, axis: .leftRight)
        _ = tab.insertPane(third, splitting: second.id, axis: .topBottom)
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
        _ = tab.insertPane(second, splitting: first.id, axis: .leftRight)
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
}
