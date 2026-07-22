import AppKit
import Testing
import TerminalCore
@testable import InkTerminalView

@Suite("终端命令块动作")
@MainActor
struct TerminalCommandActionTests {
    @Test("指定搜索匹配从 live 命令块复制输出")
    func copiesOutputContainingSearchMatch() throws {
        let terminal = makeCommandTerminal()
        let match = try #require(TerminalSearchEngine.search(
            in: terminal,
            query: "second"
        ).first)
        let view = TerminalMetalView(frame: .zero)
        var copied: String?
        view.pasteboardWriter = { copied = $0; return true }

        #expect(view.canCopyCommandOutput(containing: match.range, in: terminal))
        #expect(view.copyCommandOutput(containing: match.range, in: terminal))
        #expect(copied == "two")
    }

    @Test("块外搜索匹配不改写剪贴板")
    func searchMatchOutsideCommandDoesNotCopy() throws {
        var terminal = Terminal(size: TerminalSize(columns: 20, rows: 3))
        var parser = Parser()
        parser.feed(Array("plain needle".utf8), handler: &terminal)
        let match = try #require(TerminalSearchEngine.search(
            in: terminal,
            query: "needle"
        ).first)
        let view = TerminalMetalView(frame: .zero)
        var copied: String?
        view.pasteboardWriter = { copied = $0; return true }

        #expect(!view.canCopyCommandOutput(containing: match.range, in: terminal))
        #expect(!view.copyCommandOutput(containing: match.range, in: terminal))
        #expect(copied == nil)
    }

    @Test("上一条与下一条命令按 OSC 133 锚点移动历史视口")
    func navigatesCommands() {
        let terminal = makeCommandTerminal()
        let view = TerminalMetalView(frame: .zero)
        view.terminalProvider = { terminal }

        #expect(view.navigateToPreviousCommand())
        let latest = view.commandNavigationLine
        #expect(latest != nil)
        #expect(view.navigateToPreviousCommand())
        let earlier = view.commandNavigationLine
        #expect(earlier != nil && earlier! < latest!)
        #expect(view.navigateToNextCommand())
        #expect(view.commandNavigationLine == latest)
    }

    @Test("复制命令与输出写入指定剪贴板")
    func copiesCommandParts() {
        let terminal = makeCommandTerminal()
        let view = TerminalMetalView(frame: .zero)
        view.terminalProvider = { terminal }
        let pasteboard = NSPasteboard(name: .init("ink-command-action-tests"))
        pasteboard.clearContents()
        view.pasteboardWriter = { text in
            pasteboard.clearContents()
            return pasteboard.setString(text, forType: .string)
        }

        #expect(view.copyCurrentCommand())
        #expect(pasteboard.string(forType: .string) == "second")
        #expect(view.copyCurrentCommandOutput())
        #expect(pasteboard.string(forType: .string) == "two")
    }

    @Test("没有完整标记时动作安全失败")
    func noMarkersDoNothing() {
        var terminal = Terminal(size: TerminalSize(columns: 20, rows: 3))
        var parser = Parser()
        parser.feed(Array("plain".utf8), handler: &terminal)
        let view = TerminalMetalView(frame: .zero)
        view.terminalProvider = { terminal }

        #expect(!view.navigateToPreviousCommand())
        #expect(!view.navigateToNextCommand())
        #expect(!view.copyCurrentCommand())
        #expect(!view.copyCurrentCommandOutput())
    }

    @Test("reflow 后旧导航锚点立即失效")
    func invalidatesNavigationAfterReflow() {
        var terminal = makeCommandTerminal()
        let view = TerminalMetalView(frame: .zero)
        view.terminalProvider = { terminal }
        #expect(view.navigateToPreviousCommand())
        #expect(view.commandNavigationLine != nil)

        terminal.resize(to: TerminalSize(columns: 10, rows: 5))

        #expect(view.commandNavigationLine == nil)
        #expect(!view.copyCurrentCommand())
    }

    @Test("历史环淘汰已导航命令后不会复制占用旧坐标的新命令")
    func invalidatesEvictedNavigationAnchor() {
        var terminal = Terminal(
            size: TerminalSize(columns: 20, rows: 2),
            scrollbackCapacity: 2
        )
        var parser = Parser()
        parser.feed(Array(command("old", output: "one").utf8), handler: &terminal)
        let view = TerminalMetalView(frame: .zero)
        view.terminalProvider = { terminal }
        #expect(view.navigateToPreviousCommand())

        parser.feed(
            Array(("filler 1\r\nfiller 2\r\n" + command("new", output: "two")).utf8),
            handler: &terminal
        )

        #expect(view.commandNavigationLine == nil)
        #expect(!view.copyCurrentCommand())
    }

    @Test("清历史通知归零滚动并丢弃命令导航锚点")
    func clearScrollbackResetsCoordinateState() {
        let terminal = makeCommandTerminal()
        let view = TerminalMetalView(frame: .zero)
        view.terminalProvider = { terminal }
        #expect(view.navigateToPreviousCommand())
        #expect(view.commandNavigationLine != nil)

        view.scrollbackDidClear()

        #expect(view.searchScrollOffset == 0)
        #expect(view.commandNavigationLine == nil)
    }

    private func makeCommandTerminal() -> Terminal {
        var terminal = Terminal(
            size: TerminalSize(columns: 20, rows: 3),
            scrollbackCapacity: 30
        )
        var parser = Parser()
        let text = command("first", output: "one") + command("second", output: "two")
        parser.feed(Array(text.utf8), handler: &terminal)
        return terminal
    }

    private func command(_ command: String, output: String) -> String {
        "\u{1B}]133;A\u{07}$ \u{1B}]133;B\u{07}\(command)\r\n"
            + "\u{1B}]133;C\u{07}\(output)\r\n"
            + "\u{1B}]133;D;0\u{07}"
    }
}
