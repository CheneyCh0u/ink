import AppKit
import InkConfig
import InkTerminalView
import TerminalCore
import Testing
@testable import InkShell

@Suite("当前 pane 终端搜索")
@MainActor
struct TerminalSearchWorkspaceTests {
    @Test("大小写切换重新计算当前会话并同步按钮")
    func caseToggleRestartsSearch() async {
        var terminal = Terminal(
            size: TerminalSize(columns: 20, rows: 2),
            scrollbackCapacity: 20
        )
        var parser = Parser()
        parser.feed(Array("Alpha alpha".utf8), handler: &terminal)
        let terminalView = TerminalMetalView(frame: .zero)
        terminalView.terminalProvider = { terminal }
        let controller = TerminalSearchController(
            terminalProvider: { terminal }, terminalView: terminalView
        )

        controller.updateQuery("alpha")
        await controller.waitForPendingUpdate()
        #expect(controller.matches.count == 2)

        controller.setCaseSensitive(true)
        await controller.waitForPendingUpdate()

        #expect(controller.matches.count == 1)
        #expect(controller.searchBar.caseSensitiveEnabled)
    }

    @Test("快速切换大小写时旧 generation 不覆盖新结果")
    func staleCaseGenerationCannotWriteBack() async {
        var terminal = Terminal(
            size: TerminalSize(columns: 40, rows: 4),
            scrollbackCapacity: 2_000
        )
        var parser = Parser()
        parser.feed(
            Array(String(repeating: "Alpha alpha\r\n", count: 1_000).utf8),
            handler: &terminal
        )
        let terminalView = TerminalMetalView(frame: .zero)
        terminalView.terminalProvider = { terminal }
        let controller = TerminalSearchController(
            terminalProvider: { terminal }, terminalView: terminalView
        )

        controller.updateQuery("alpha")
        controller.setCaseSensitive(true)
        await controller.waitForPendingUpdate()

        #expect(controller.matches.count == 1_000)
        #expect(controller.searchBar.caseSensitiveEnabled)
    }

    @Test("仅搜索选区冻结开启瞬间范围")
    func selectionScopeIsFrozen() async {
        var terminal = Terminal(
            size: TerminalSize(columns: 24, rows: 2),
            scrollbackCapacity: 20
        )
        var parser = Parser()
        parser.feed(Array("hit outside hit inside".utf8), handler: &terminal)
        var provided = SelectionRange(
            start: TextPosition(line: 0, column: 8),
            end: TextPosition(line: 0, column: 21)
        )
        let terminalView = TerminalMetalView(frame: .zero)
        terminalView.terminalProvider = { terminal }
        let controller = TerminalSearchController(
            terminalProvider: { terminal },
            terminalView: terminalView,
            selectionProvider: { _ in provided }
        )

        controller.updateQuery("hit")
        controller.setSelectionOnly(true)
        provided = SelectionRange(
            start: TextPosition(line: 0, column: 0),
            end: TextPosition(line: 0, column: 2)
        )
        await controller.waitForPendingUpdate()

        #expect(controller.matches.count == 1)
        #expect(controller.matches.first?.range.start.column == 12)
        #expect(controller.searchBar.selectionOnlyEnabled)
    }

    @Test("空选区不能开启范围搜索")
    func emptySelectionCannotEnableScope() {
        var terminal = Terminal(
            size: TerminalSize(columns: 12, rows: 2),
            scrollbackCapacity: 20
        )
        var parser = Parser()
        parser.feed(Array("hit".utf8), handler: &terminal)
        let empty = SelectionRange(
            start: TextPosition(line: 0, column: 5),
            end: TextPosition(line: 0, column: 5)
        )
        let terminalView = TerminalMetalView(frame: .zero)
        let controller = TerminalSearchController(
            terminalProvider: { terminal },
            terminalView: terminalView,
            selectionProvider: { _ in empty }
        )

        controller.setSelectionOnly(true)

        #expect(!controller.selectionOnly)
        #expect(!controller.searchBar.selectionToggleEnabled)
    }

    @Test("打开搜索时非空选区立即启用范围按钮")
    func selectionIsAvailableWhenSearchOpens() {
        var terminal = Terminal(
            size: TerminalSize(columns: 12, rows: 2),
            scrollbackCapacity: 20
        )
        var parser = Parser()
        parser.feed(Array("hit".utf8), handler: &terminal)
        let selected = SelectionRange(
            start: TextPosition(line: 0, column: 0),
            end: TextPosition(line: 0, column: 2)
        )
        let terminalView = TerminalMetalView(frame: .zero)

        let controller = TerminalSearchController(
            terminalProvider: { terminal },
            terminalView: terminalView,
            selectionProvider: { _ in selected }
        )

        #expect(controller.searchBar.selectionToggleEnabled)
    }

    @Test("reflow 使冻结范围自动退出并恢复全终端结果")
    func selectionScopeExitsAfterReflow() async {
        var terminal = Terminal(
            size: TerminalSize(columns: 24, rows: 2),
            scrollbackCapacity: 20
        )
        var parser = Parser()
        parser.feed(Array("hit first hit second".utf8), handler: &terminal)
        let selected = SelectionRange(
            start: TextPosition(line: 0, column: 0),
            end: TextPosition(line: 0, column: 8)
        )
        let terminalView = TerminalMetalView(frame: .zero)
        terminalView.terminalProvider = { terminal }
        let controller = TerminalSearchController(
            terminalProvider: { terminal },
            terminalView: terminalView,
            selectionProvider: { _ in selected }
        )
        controller.updateQuery("hit")
        controller.setSelectionOnly(true)
        await controller.waitForPendingUpdate()
        #expect(controller.matches.count == 1)

        terminal.resize(to: TerminalSize(columns: 12, rows: 2))
        controller.refreshForTerminalUpdate()
        await controller.waitForPendingUpdate()

        #expect(!controller.selectionOnly)
        #expect(controller.matches.count == 2)
    }

    @Test("冻结范围随存活历史平移并在端点淘汰后退出")
    func selectionScopeTracksEviction() async {
        var terminal = Terminal(
            size: TerminalSize(columns: 12, rows: 1),
            scrollbackCapacity: 2
        )
        var parser = Parser()
        parser.feed(Array("drop\r\nhit keep\r\nplain".utf8), handler: &terminal)
        let selected = SelectionRange(
            start: TextPosition(line: 1, column: 0),
            end: TextPosition(line: 1, column: 7)
        )
        let terminalView = TerminalMetalView(frame: .zero)
        terminalView.terminalProvider = { terminal }
        let controller = TerminalSearchController(
            terminalProvider: { terminal },
            terminalView: terminalView,
            selectionProvider: { _ in selected }
        )
        controller.updateQuery("hit")
        controller.setSelectionOnly(true)
        await controller.waitForPendingUpdate()

        parser.feed(Array("\r\nnew".utf8), handler: &terminal)
        controller.refreshForTerminalUpdate()
        await controller.waitForPendingUpdate()
        #expect(controller.selectionOnly)
        #expect(controller.matches.first?.range.start.line == 0)

        parser.feed(Array("\r\nnewer".utf8), handler: &terminal)
        controller.refreshForTerminalUpdate()
        await controller.waitForPendingUpdate()
        #expect(!controller.selectionOnly)
        #expect(controller.matches.isEmpty)
    }

    @Test("清除 scrollback 使冻结范围自动退出")
    func selectionScopeExitsAfterClearingScrollback() async {
        var terminal = Terminal(
            size: TerminalSize(columns: 12, rows: 1),
            scrollbackCapacity: 20
        )
        var parser = Parser()
        parser.feed(Array("hit old\r\nplain".utf8), handler: &terminal)
        let selected = SelectionRange(
            start: TextPosition(line: 0, column: 0),
            end: TextPosition(line: 0, column: 6)
        )
        let terminalView = TerminalMetalView(frame: .zero)
        let controller = TerminalSearchController(
            terminalProvider: { terminal },
            terminalView: terminalView,
            selectionProvider: { _ in selected }
        )
        controller.updateQuery("hit")
        controller.setSelectionOnly(true)
        await controller.waitForPendingUpdate()
        #expect(controller.selectionOnly)

        terminal.csiDispatch(
            prefix: 0,
            params: [3][...],
            intermediates: [],
            final: UInt8(ascii: "J")
        )
        controller.refreshForTerminalUpdate()
        await controller.waitForPendingUpdate()

        #expect(!controller.selectionOnly)
    }

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

    @Test("淘汰后旧坐标被其他结果占用也保持原结果")
    func rebasesBeforeCoordinateEquality() async throws {
        var parser = Parser()
        var terminal = Terminal(
            size: TerminalSize(columns: 8, rows: 1),
            scrollbackCapacity: 2
        )
        parser.feed(Array("hit 0\r\nhit 1\r\nhit 2".utf8), handler: &terminal)
        let terminalView = TerminalMetalView(frame: .zero)
        terminalView.terminalProvider = { terminal }
        let controller = TerminalSearchController(
            terminalProvider: { terminal }, terminalView: terminalView
        )
        controller.updateQuery("hit")
        await controller.waitForPendingUpdate()
        controller.selectPrevious()
        #expect(try #require(controller.currentMatch).range.start.line == 1)

        parser.feed(Array("\r\nhit 3".utf8), handler: &terminal)
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
