import AppKit
import InkConfig
import InkTerminalView
import TerminalCore
import Testing
@testable import InkShell

@Suite("当前 pane 终端搜索")
@MainActor
struct TerminalSearchWorkspaceTests {
    @Test("查询扫描异步执行而不阻塞主线程")
    func queryRunsOffMainActor() async {
        var terminal = Terminal(
            size: TerminalSize(columns: 12, rows: 2),
            scrollbackCapacity: 20
        )
        var parser = Parser()
        parser.feed(Array("hit".utf8), handler: &terminal)
        let terminalView = TerminalMetalView(frame: .zero)
        let controller = TerminalSearchController(
            terminalProvider: { terminal }, terminalView: terminalView
        )

        controller.updateQuery("hit")
        #expect(controller.matches.isEmpty)
        await controller.waitForPendingUpdate()
        #expect(controller.matches.count == 1)
    }

    @Test("首次结果选择当前视口最近且更新输出不跳项")
    func nearestResultAndStableRefresh() async throws {
        var parser = Parser()
        var terminal = Terminal(
            size: TerminalSize(columns: 12, rows: 2),
            scrollbackCapacity: 20
        )
        for text in ["hit old\r\n", "middle\r\n", "hit near"] {
            parser.feed(Array(text.utf8), handler: &terminal)
        }
        let terminalView = TerminalMetalView(frame: .zero)
        terminalView.terminalProvider = { terminal }
        let controller = TerminalSearchController(
            terminalProvider: { terminal },
            terminalView: terminalView
        )

        controller.updateQuery("hit")
        await controller.waitForPendingUpdate()
        let selected = try #require(controller.currentMatch)
        #expect(selected.range.start.line == terminal.totalLines - 1)

        parser.feed(Array("\r\nhit newest".utf8), handler: &terminal)
        controller.refreshForTerminalUpdate()
        await controller.waitForPendingUpdate()
        #expect(controller.currentMatch == selected)
        #expect(controller.matches.count == 3)
    }

    @Test("同一轮输出只调度一次搜索刷新")
    func coalescesTerminalUpdates() async {
        var terminal = Terminal(
            size: TerminalSize(columns: 12, rows: 2),
            scrollbackCapacity: 20
        )
        var parser = Parser()
        parser.feed(Array("hit".utf8), handler: &terminal)
        var providerReads = 0
        let terminalView = TerminalMetalView(frame: .zero)
        let controller = TerminalSearchController(
            terminalProvider: {
                providerReads += 1
                return terminal
            },
            terminalView: terminalView
        )
        controller.updateQuery("hit")
        await controller.waitForPendingUpdate()
        providerReads = 0

        controller.scheduleRefreshForTerminalUpdate()
        controller.scheduleRefreshForTerminalUpdate()
        await Task.yield()

        #expect(providerReads == 1)
    }

    @Test("历史环淘汰时仍保持同一个当前结果")
    func preservesCurrentMatchAcrossEviction() async throws {
        var parser = Parser()
        var terminal = Terminal(
            size: TerminalSize(columns: 12, rows: 2),
            scrollbackCapacity: 1
        )
        parser.feed(
            Array("hit old\r\nhit mid\r\nplain".utf8),
            handler: &terminal
        )
        let terminalView = TerminalMetalView(frame: .zero)
        terminalView.terminalProvider = { terminal }
        let controller = TerminalSearchController(
            terminalProvider: { terminal },
            terminalView: terminalView
        )
        controller.updateQuery("hit")
        await controller.waitForPendingUpdate()
        #expect(try #require(controller.currentMatch).range.start.line == 1)

        parser.feed(Array("\r\nhit new".utf8), handler: &terminal)
        controller.refreshForTerminalUpdate()
        await controller.waitForPendingUpdate()

        #expect(try #require(controller.currentMatch).range.start.line == 0)
    }

    @Test("当前结果被淘汰后可选择后续新结果")
    func recoversAfterSelectedMatchIsEvicted() async throws {
        var parser = Parser()
        var terminal = Terminal(
            size: TerminalSize(columns: 8, rows: 1),
            scrollbackCapacity: 1
        )
        parser.feed(Array("hit\r\nplain".utf8), handler: &terminal)
        let terminalView = TerminalMetalView(frame: .zero)
        terminalView.terminalProvider = { terminal }
        let controller = TerminalSearchController(
            terminalProvider: { terminal }, terminalView: terminalView
        )
        controller.updateQuery("hit")
        await controller.waitForPendingUpdate()
        #expect(controller.currentMatch != nil)

        parser.feed(Array("\r\nempty".utf8), handler: &terminal)
        controller.refreshForTerminalUpdate()
        await controller.waitForPendingUpdate()
        #expect(controller.currentIndex == nil)

        parser.feed(Array("\r\nhit new".utf8), handler: &terminal)
        controller.refreshForTerminalUpdate()
        await controller.waitForPendingUpdate()
        #expect(try #require(controller.currentMatch).range.start.line >= 0)
    }

    @Test("同一标签始终只在一个 pane 显示搜索栏")
    func oneOverlayPerTab() throws {
        let first = makeSearchPane()
        let second = makeSearchPane()
        let tab = TerminalTab(initialPane: first)
        _ = tab.insertPane(second, splitting: first.id, direction: .right)
        let workspace = TerminalWorkspaceViewController()
        workspace.show(tab: tab, config: InkConfig())

        workspace.activate(first.id)
        #expect(workspace.openSearchInActivePane())
        #expect(workspace.activeSearchPaneID == first.id)

        workspace.activate(second.id)
        #expect(workspace.openSearchInActivePane())
        #expect(workspace.activeSearchPaneID == second.id)
        #expect(allSearchBars(in: workspace.view).count == 1)

        workspace.show(tab: tab, config: InkConfig())
        #expect(workspace.activeSearchPaneID == nil)
        #expect(allSearchBars(in: workspace.view).isEmpty)
    }

    @Test("Command-F 只接受活动终端或其搜索框响应者")
    func firstResponderRouting() throws {
        let pane = makeSearchPane()
        let tab = TerminalTab(initialPane: pane)
        let workspace = TerminalWorkspaceViewController()
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 640, height: 360),
            styleMask: [.titled],
            backing: .buffered,
            defer: false
        )
        window.contentViewController = workspace
        workspace.show(tab: tab, config: InkConfig())
        let terminalView = try #require(workspace.terminalView(for: pane.id))
        window.makeFirstResponder(terminalView)

        #expect(workspace.canOpenSearch(for: window.firstResponder))

        let unrelatedField = NSTextField(string: "rename")
        workspace.view.addSubview(unrelatedField)
        window.makeFirstResponder(unrelatedField)
        #expect(!workspace.canOpenSearch(for: window.firstResponder))
    }

    private func makeSearchPane() -> TerminalPane {
        TerminalPane(session: TerminalSession(size: TerminalSize(columns: 80, rows: 24)))
    }

    private func allSearchBars(in view: NSView) -> [TerminalSearchBarView] {
        view.subviews.flatMap { subview in
            (subview as? TerminalSearchBarView).map { [$0] } ?? allSearchBars(in: subview)
        }
    }
}
