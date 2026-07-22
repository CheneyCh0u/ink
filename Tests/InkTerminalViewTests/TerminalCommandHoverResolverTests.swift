import Testing
import TerminalCore
@testable import InkTerminalView

@Suite("命令悬停目标")
struct TerminalCommandHoverResolverTests {
    @Test("只有完整命令首行生成目标")
    func resolvesOnlyCommandStartLine() throws {
        let terminal = makeHoverTerminal()
        let block = try #require(terminal.commandBlocks().first)

        #expect(CommandHoverResolver.target(
            startingAt: block.commandRange.start.line,
            in: terminal
        ) != nil)
        #expect(CommandHoverResolver.target(
            startingAt: block.commandRange.start.line + 1,
            in: terminal
        ) == nil)

        var plain = Terminal(size: .init(columns: 30, rows: 4))
        var parser = Parser()
        parser.feed(Array("plain".utf8), handler: &plain)
        #expect(CommandHoverResolver.target(startingAt: 0, in: plain) == nil)
    }

    @Test("目标解析同时返回相邻命令")
    func resolvesTargetAndNeighbors() throws {
        let terminal = makeHoverTerminal()
        let blocks = terminal.commandBlocks()
        let middle = try #require(blocks.dropFirst().first)
        let target = try #require(CommandHoverResolver.target(
            startingAt: middle.commandRange.start.line,
            in: terminal
        ))

        let resolution = try #require(CommandHoverResolver.resolve(target, in: terminal))

        #expect(terminal.extractText(in: resolution.block.commandRange) == "second")
        #expect(resolution.previous.map {
            terminal.extractText(in: $0.commandRange)
        } == "first")
        #expect(resolution.next.map {
            terminal.extractText(in: $0.commandRange)
        } == "third")
    }

    @Test("前置历史淘汰后稳定目标仍指向同一命令")
    func survivesEarlierEviction() throws {
        var parser = Parser()
        var terminal = Terminal(
            size: .init(columns: 30, rows: 3),
            scrollbackCapacity: 5
        )
        parser.feed(Array("old0\r\nold1\r\nold2\r\n".utf8), handler: &terminal)
        parser.feed(Array(hoverCommand("keep", output: "value").utf8), handler: &terminal)
        let block = try #require(terminal.commandBlocks().last)
        let target = try #require(CommandHoverResolver.target(
            startingAt: block.commandRange.start.line,
            in: terminal
        ))
        let oldestBefore = terminal.scrollback.totalAppendedLines
            - UInt64(terminal.scrollback.count)

        parser.feed(Array("tail0\r\ntail1\r\ntail2\r\ntail3\r\n".utf8), handler: &terminal)

        let oldestAfter = terminal.scrollback.totalAppendedLines
            - UInt64(terminal.scrollback.count)
        #expect(oldestAfter > oldestBefore)
        let resolved = try #require(CommandHoverResolver.resolve(target, in: terminal))
        #expect(terminal.extractText(in: resolved.block.commandRange) == "keep")
    }

    @Test("命令被环淘汰后目标失效")
    func invalidatesEvictedTarget() throws {
        var parser = Parser()
        var terminal = Terminal(
            size: .init(columns: 30, rows: 2),
            scrollbackCapacity: 2
        )
        parser.feed(Array(hoverCommand("old", output: "value").utf8), handler: &terminal)
        let block = try #require(terminal.commandBlocks().first)
        let target = try #require(CommandHoverResolver.target(
            startingAt: block.commandRange.start.line,
            in: terminal
        ))

        parser.feed(Array("a\r\nb\r\nc\r\nd\r\n".utf8), handler: &terminal)

        #expect(CommandHoverResolver.resolve(target, in: terminal) == nil)
    }

    @Test("reflow 后旧目标失效")
    func invalidatesReflowedTarget() throws {
        var terminal = makeHoverTerminal()
        let block = try #require(terminal.commandBlocks().first)
        let target = try #require(CommandHoverResolver.target(
            startingAt: block.commandRange.start.line,
            in: terminal
        ))

        terminal.resize(to: .init(columns: 12, rows: 8))

        #expect(CommandHoverResolver.resolve(target, in: terminal) == nil)
    }
}

private func makeHoverTerminal(
    columns: Int = 30,
    rows: Int = 6,
    scrollbackCapacity: Int = 30
) -> Terminal {
    var terminal = Terminal(
        size: .init(columns: columns, rows: rows),
        scrollbackCapacity: scrollbackCapacity
    )
    var parser = Parser()
    parser.feed(Array((
        hoverCommand("first", output: "one")
            + hoverCommand("second", output: "two")
            + hoverCommand("third", output: "three")
    ).utf8), handler: &terminal)
    return terminal
}

private func hoverCommand(_ command: String, output: String) -> String {
    "\u{1B}]133;A\u{07}$ \u{1B}]133;B\u{07}\(command)\r\n"
        + "\u{1B}]133;C\u{07}\(output)\r\n"
        + "\u{1B}]133;D;0\u{07}"
}
