import Foundation
import TerminalCore
import Testing
@testable import InkShell

@Suite("终端标签")
@MainActor
struct TerminalTabTests {

    @Test("关闭活动标签前面的后台标签时保持原活动标签")
    func removingEarlierTabKeepsActiveTab() throws {
        let first = TerminalTab(initialPane: makePane())
        let active = TerminalTab(initialPane: makePane())
        let last = TerminalTab(initialPane: makePane())
        let project = Project(directory: URL(fileURLWithPath: "/tmp"))
        project.tabs = [first, active, last]
        project.activeTabIndex = 1

        let removed = try #require(project.removeTab(at: 0))

        #expect(removed === first)
        #expect(project.activeTab === active)
        #expect(project.activeTabIndex == 0)
    }

    @Test("新标签以唯一 pane 作为活动 pane")
    func initialPaneIsActive() {
        let pane = makePane()

        let tab = TerminalTab(initialPane: pane)

        #expect(tab.paneCount == 1)
        #expect(tab.activePane === pane)
        #expect(tab.layout == .leaf(pane.id))
    }

    @Test("插入 pane 后更新布局并聚焦新 pane")
    func insertingPaneActivatesIt() {
        let original = makePane()
        let created = makePane()
        let tab = TerminalTab(initialPane: original)

        let inserted = tab.insertPane(created, splitting: original.id, axis: .leftRight)

        #expect(inserted)
        #expect(tab.paneCount == 2)
        #expect(tab.activePane === created)
        #expect(tab.layout.contains(original.id))
        #expect(tab.layout.contains(created.id))
    }

    @Test("关闭活动 pane 后迁移到兄弟 pane")
    func removingActivePaneMovesFocus() {
        let original = makePane()
        let created = makePane()
        let tab = TerminalTab(initialPane: original)
        _ = tab.insertPane(created, splitting: original.id, axis: .leftRight)

        let removed = tab.removePane(created.id)

        #expect(removed === created)
        #expect(tab.activePane === original)
        #expect(tab.layout == .leaf(original.id))
    }

    @Test("关闭非活动 pane 时保持当前焦点")
    func removingInactivePaneKeepsFocus() {
        let original = makePane()
        let created = makePane()
        let tab = TerminalTab(initialPane: original)
        _ = tab.insertPane(created, splitting: original.id, axis: .topBottom)

        let removed = tab.removePane(original.id)

        #expect(removed === original)
        #expect(tab.activePane === created)
    }

    @Test("最后一个 pane 由标签级关闭处理")
    func lastPaneCannotBeRemovedInPlace() {
        let pane = makePane()
        let tab = TerminalTab(initialPane: pane)

        #expect(tab.removePane(pane.id) == nil)
        #expect(tab.activePane === pane)
        #expect(tab.paneCount == 1)
    }

    private func makePane() -> TerminalPane {
        TerminalPane(session: TerminalSession(size: TerminalSize(columns: 80, rows: 24)))
    }
}
