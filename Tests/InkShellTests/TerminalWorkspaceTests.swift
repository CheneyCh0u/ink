import AppKit
import InkConfig
import TerminalCore
import Testing
@testable import InkShell
@testable import InkTerminalView

@Suite("终端分屏工作区")
@MainActor
struct TerminalWorkspaceTests {

    @Test("多子项分隔线位置恢复为权重")
    func restoresGroupWeights() throws {
        let first = makePane()
        let second = makePane()
        let third = makePane()
        let tab = TerminalTab(initialPane: first)
        _ = tab.insertPane(second, splitting: first.id, direction: .down)
        _ = tab.insertPane(third, splitting: second.id, direction: .down)
        guard case let .group(id, _, _, _) = tab.layout else {
            Issue.record("没有形成多子项分组")
            return
        }
        _ = tab.updateSplitWeights(id, weights: [0.25, 0.25, 0.5])
        let workspace = TerminalWorkspaceViewController()
        workspace.view.frame = NSRect(x: 0, y: 0, width: 900, height: 600)

        workspace.show(tab: tab, config: InkConfig())
        workspace.view.layoutSubtreeIfNeeded()

        let heights = try [first, second, third].map {
            try #require(workspace.paneContainer(for: $0.id)).frame.height
        }
        #expect(heights.allSatisfy { $0 > 1 })
        #expect(heights[2] > heights[0] * 1.9)
    }

    @Test("用户拖动结束后把整组权重写回标签")
    func dividerDragCommitsGroupWeights() throws {
        let first = makePane()
        let second = makePane()
        let tab = TerminalTab(initialPane: first)
        _ = tab.insertPane(second, splitting: first.id, direction: .right)
        let workspace = TerminalWorkspaceViewController()
        workspace.view.frame = NSRect(x: 0, y: 0, width: 800, height: 600)
        workspace.show(tab: tab, config: InkConfig())
        workspace.view.layoutSubtreeIfNeeded()
        let splitView = try #require(
            allSubviews(in: workspace.view)
                .compactMap { $0 as? WorkspaceSplitContainerView }
                .first
        )

        let dividerPoint = NSPoint(x: splitView.subviews[0].frame.maxX, y: 100)
        #expect(splitView.beginDividerDrag(at: dividerPoint))
        splitView.updateDividerDrag(to: NSPoint(x: 200, y: 100))
        splitView.endDividerDrag()

        guard case let .group(_, _, weights, _) = tab.layout else {
            Issue.record("拖动后布局不再是分组")
            return
        }
        #expect(abs(weights[0] - 0.25) < 0.02)
        #expect(abs(weights[1] - 0.75) < 0.02)
    }

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
            for splitView in allSubviews(in: workspace.view).compactMap({
                $0 as? WorkspaceSplitContainerView
            }) {
                splitView.needsLayout = true
                splitView.layoutSubtreeIfNeeded()
            }
            #expect(
                splitWeights(in: tab.layout).allSatisfy { $0 > 0 && $0 < 1 },
                "连续 layout 后权重不应塌缩"
            )
            target = created
        }

        let splitView = try #require(
            allSubviews(in: workspace.view)
                .compactMap { $0 as? WorkspaceSplitContainerView }
                .first
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

    @Test("递归布局创建左右与上下两种分屏容器")
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

        let splitViews = allSubviews(in: workspace.view).compactMap {
            $0 as? WorkspaceSplitContainerView
        }
        #expect(splitViews.count == 2)
        #expect(splitViews.contains { $0.axis == .leftRight })
        #expect(splitViews.contains { $0.axis == .topBottom })
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
        weak var oldContainer: TerminalPaneContainerView?
        oldContainer = workspace.paneContainer(for: firstPane.id)

        workspace.show(tab: secondTab, config: InkConfig())

        #expect(oldContainer?.superview == nil)
        #expect(workspace.paneContainer(for: firstPane.id) == nil)
        #expect(workspace.paneContainer(for: secondPane.id) != nil)
    }

    @Test("配色热更新应用到已有 pane")
    func themeHotReloadUpdatesExistingPane() throws {
        let pane = makePane()
        let tab = TerminalTab(initialPane: pane)
        let workspace = TerminalWorkspaceViewController()
        var config = InkConfig()
        config.terminalTheme = .warm

        workspace.show(tab: tab, config: config)
        let terminalView = try #require(workspace.terminalView(for: pane.id))
        #expect(terminalView.terminalTheme == .warm)

        config.terminalTheme = .plum
        workspace.apply(config: config)
        #expect(terminalView.terminalTheme == .plum)
    }

    @Test("字体度量配置应用到已有 pane")
    func fontMetricsHotReloadUpdatesExistingPane() throws {
        let pane = makePane()
        let tab = TerminalTab(initialPane: pane)
        let workspace = TerminalWorkspaceViewController()
        var config = InkConfig()
        config.fontCellHeightAdjustment = 3
        config.fontThicken = false
        config.fontThickenStrength = 90

        workspace.show(tab: tab, config: config)
        let terminalView = try #require(workspace.terminalView(for: pane.id))
        #expect(terminalView.cellHeightAdjustment == 3)
        #expect(terminalView.fontThicken == false)
        #expect(terminalView.fontThickenStrength == 90)
        let rebuildsBeforeHotReload = terminalView.rendererRebuildAttemptCount

        config.fontCellHeightAdjustment = -2
        config.fontThicken = true
        config.fontThickenStrength = 160
        workspace.apply(config: config)
        #expect(terminalView.rendererRebuildAttemptCount - rebuildsBeforeHotReload == 1)
        #expect(terminalView.cellHeightAdjustment == -2)
        #expect(terminalView.fontThicken)
        #expect(terminalView.fontThickenStrength == 160)
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
