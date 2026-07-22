import Testing
@testable import TerminalCore

@Suite("OSC 133 命令块")
struct CommandBlockTests {
    @Test("命令或输出中的完整匹配都解析到同一输出范围")
    func searchMatchResolvesCommandOutput() throws {
        var (parser, terminal) = makeTerminal(columns: 30, rows: 5)
        feed(
            "\u{1B}]133;A\u{07}$ \u{1B}]133;B\u{07}echo needle\r\n"
                + "\u{1B}]133;C\u{07}needle output"
                + "\u{1B}]133;D;0\u{07}",
            &parser,
            &terminal
        )
        let matches = TerminalSearchEngine.search(in: terminal, query: "needle")

        let commandOutput = try #require(
            terminal.commandOutputRange(containing: matches[0].range)
        )
        let outputOutput = try #require(
            terminal.commandOutputRange(containing: matches[1].range)
        )

        #expect(terminal.extractText(in: commandOutput) == "needle output")
        #expect(outputOutput == commandOutput)
    }

    @Test("命令块外匹配和空输出没有可复制输出")
    func searchMatchWithoutCommandOutput() throws {
        var (parser, terminal) = makeTerminal(columns: 30, rows: 5)
        feed("plain needle", &parser, &terminal)
        let plainMatch = try #require(
            TerminalSearchEngine.search(in: terminal, query: "needle").first
        )
        #expect(terminal.commandOutputRange(containing: plainMatch.range) == nil)

        var (emptyParser, emptyOutputTerminal) = makeTerminal(columns: 30, rows: 5)
        feed(
            "\u{1B}]133;A\u{07}$ \u{1B}]133;B\u{07}needle\r\n"
                + "\u{1B}]133;C\u{07}\u{1B}]133;D;0\u{07}",
            &emptyParser,
            &emptyOutputTerminal
        )
        let commandMatch = try #require(
            TerminalSearchEngine.search(in: emptyOutputTerminal, query: "needle").first
        )
        #expect(emptyOutputTerminal.commandOutputRange(containing: commandMatch.range) == nil)
    }

    @Test("命令块携带退出状态与耗时且 reflow 后不变")
    func completionSurvivesReflow() throws {
        var (parser, terminal) = makeTerminal(columns: 20, rows: 5)
        feed(
            "\u{1B}]133;A\u{07}$ \u{1B}]133;B\u{07}build\r\n",
            &parser,
            &terminal
        )
        let clock = ContinuousClock()
        let start = clock.now
        terminal.handleOSC133(ArraySlice("C".utf8), now: start)
        feed("long output", &parser, &terminal)
        terminal.handleOSC133(
            ArraySlice("D;3".utf8),
            now: start.advanced(by: .seconds(61))
        )

        let before = try #require(terminal.commandBlocks().first?.completion)
        terminal.resize(to: .init(columns: 6, rows: 8))
        let after = try #require(terminal.commandBlocks().first?.completion)
        #expect(before == .init(exitStatus: 3, duration: .seconds(61)))
        #expect(after == before)
    }

    @Test("同一位置的多个完成结果按 D 顺序关联且 reflow 后保序")
    func colocatedCompletionsKeepOrder() {
        var terminal = Terminal(size: .init(columns: 20, rows: 4))
        let clock = ContinuousClock()
        let first = clock.now

        terminal.handleOSC133(ArraySlice("B".utf8), now: first)
        terminal.handleOSC133(ArraySlice("C".utf8), now: first)
        terminal.handleOSC133(
            ArraySlice("D;1".utf8),
            now: first.advanced(by: .seconds(1))
        )
        let second = first.advanced(by: .seconds(2))
        terminal.handleOSC133(ArraySlice("B".utf8), now: second)
        terminal.handleOSC133(ArraySlice("C".utf8), now: second)
        terminal.handleOSC133(
            ArraySlice("D;2".utf8),
            now: second.advanced(by: .seconds(2))
        )

        #expect(terminal.commandBlocks().compactMap(\.completion) == [
            .init(exitStatus: 1, duration: .seconds(1)),
            .init(exitStatus: 2, duration: .seconds(2)),
        ])

        terminal.resize(to: .init(columns: 8, rows: 4))
        #expect(terminal.commandBlocks().compactMap(\.completion) == [
            .init(exitStatus: 1, duration: .seconds(1)),
            .init(exitStatus: 2, duration: .seconds(2)),
        ])
    }

    @Test("命令排除提示符，输出排除下一提示符")
    func extractsCommandAndOutput() {
        var (parser, term) = makeTerminal(columns: 30, rows: 5)
        feed(
            "\u{1B}]133;A\u{07}$ "
                + "\u{1B}]133;B\u{07}echo hi\r\n"
                + "\u{1B}]133;C\u{07}one\r\ntwo"
                + "\u{1B}]133;D;0\u{07}\u{1B}]133;A\u{07}$ ",
            &parser,
            &term
        )

        let blocks = term.commandBlocks()
        #expect(blocks.count == 1)
        #expect(blocks.first.map { term.extractText(in: $0.commandRange) } == "echo hi")
        #expect(blocks.first?.outputRange.map { term.extractText(in: $0) } == "one\ntwo")
    }

    @Test("软折命令跨入 scrollback 后仍拼成一行")
    func wrappedCommandAcrossScrollback() {
        var (parser, term) = makeTerminal(columns: 8, rows: 3)
        feed(
            "\u{1B}]133;A\u{07}$ \u{1B}]133;B\u{07}abcdefghijkl\r\n"
                + "\u{1B}]133;C\u{07}result\r\n"
                + "\u{1B}]133;D;0\u{07}\u{1B}]133;A\u{07}$ ",
            &parser,
            &term
        )

        #expect(term.scrollback.count > 0)
        let block = term.commandBlocks().first
        #expect(block.map { term.extractText(in: $0.commandRange) } == "abcdefghijkl")
        #expect(block?.outputRange.map { term.extractText(in: $0) } == "result")
    }

    @Test("缺少 B 或 C 标记时不臆造命令块")
    func incompleteMarkersAreIgnored() {
        var (parser, term) = makeTerminal()
        feed("plain\r\n\u{1B}]133;C\u{07}output", &parser, &term)
        #expect(term.commandBlocks().isEmpty)
    }

    @Test("reflow 后命令边界仍排除提示符")
    func extractsAfterReflow() {
        var (parser, term) = makeTerminal(columns: 20, rows: 5)
        feed(
            "\u{1B}]133;A\u{07}long-prompt> "
                + "\u{1B}]133;B\u{07}abcdefghij\r\n"
                + "\u{1B}]133;C\u{07}result\r\n"
                + "\u{1B}]133;D;0\u{07}",
            &parser,
            &term
        )

        term.resize(to: TerminalSize(columns: 8, rows: 6))

        let block = term.commandBlocks().first
        #expect(block.map { term.extractText(in: $0.commandRange) } == "abcdefghij")
        #expect(block?.outputRange.map { term.extractText(in: $0) } == "result")
    }

    @Test("C D A 同行覆写时仍识别无换行输出")
    func collapsedOutputMarkers() {
        var (parser, term) = makeTerminal(columns: 20, rows: 4)
        feed(
            "\u{1B}]133;A\u{07}$ \u{1B}]133;B\u{07}printf x\r\n"
                + "\u{1B}]133;C\u{07}x"
                + "\u{1B}]133;D;0\u{07}\u{1B}]133;A\u{07}$ ",
            &parser,
            &term
        )

        let block = term.commandBlocks().first
        #expect(block.map { term.extractText(in: $0.commandRange) } == "printf x")
        #expect(block?.outputRange.map { term.extractText(in: $0) } == "x")
    }

    @Test("同行覆写的输出在 reflow 后仍从逻辑行开头复制")
    func collapsedOutputMarkersAfterReflow() {
        var (parser, term) = makeTerminal(columns: 20, rows: 5)
        feed(
            "\u{1B}]133;A\u{07}$ \u{1B}]133;B\u{07}printf 123456789\r\n"
                + "\u{1B}]133;C\u{07}123456789"
                + "\u{1B}]133;D;0\u{07}\u{1B}]133;A\u{07}$ ",
            &parser,
            &term
        )
        term.resize(to: TerminalSize(columns: 4, rows: 8))

        let block = term.commandBlocks().first
        #expect(block?.outputRange.map { term.extractText(in: $0) } == "123456789")
    }

    @Test("B C 同行时保留命令与输出边界")
    func commandAndOutputStartOnSameLine() {
        var (parser, term) = makeTerminal(columns: 20, rows: 4)
        feed(
            "\u{1B}]133;A\u{07}$ \u{1B}]133;B\u{07}cmd"
                + "\u{1B}]133;C\u{07}out"
                + "\u{1B}]133;D;0\u{07}\u{1B}]133;A\u{07}",
            &parser,
            &term
        )

        let block = term.commandBlocks().first
        #expect(block.map { term.extractText(in: $0.commandRange) } == "cmd")
        #expect(block?.outputRange.map { term.extractText(in: $0) } == "out")
    }

    @Test("B C 同逻辑行的多个转换在 reflow 后都保留")
    func multipleTransitionsSurviveReflow() {
        var (parser, term) = makeTerminal(columns: 20, rows: 5)
        feed(
            "\u{1B}]133;A\u{07}$ \u{1B}]133;B\u{07}abcdefgh"
                + "\u{1B}]133;C\u{07}output"
                + "\u{1B}]133;D;0\u{07}",
            &parser,
            &term
        )
        term.resize(to: TerminalSize(columns: 4, rows: 8))

        let block = term.commandBlocks().first
        #expect(block.map { term.extractText(in: $0.commandRange) } == "abcdefgh")
        #expect(block?.outputRange.map { term.extractText(in: $0) } == "output")
    }

    @Test("B 后缺少 C D 时下一次 A 不臆造命令块")
    func missingExecutionMarkersAreIgnored() {
        var (parser, term) = makeTerminal(columns: 20, rows: 4)
        feed(
            "\u{1B}]133;A\u{07}$ \u{1B}]133;B\u{07}unfinished\r\n"
                + "\u{1B}]133;A\u{07}$ ",
            &parser,
            &term
        )
        #expect(term.commandBlocks().isEmpty)
    }

    @Test("B 后缺少 C 即使收到 D 也不臆造命令块")
    func missingOutputStartBeforeCommandEndIsIgnored() {
        var (parser, term) = makeTerminal(columns: 20, rows: 4)
        feed(
            "\u{1B}]133;A\u{07}$ \u{1B}]133;B\u{07}unfinished\r\n"
                + "ordinary text\u{1B}]133;D;1\u{07}",
            &parser,
            &term
        )
        #expect(term.commandBlocks().isEmpty)
    }

    @Test("旁路语义点随小容量 scrollback 环淘汰并批量回收")
    func overflowTransitionsAreBounded() {
        var (parser, term) = makeTerminal(columns: 20, rows: 2, scrollback: 2)
        for _ in 0..<400 {
            feed(
                "\u{1B}]133;A\u{07}$ \u{1B}]133;B\u{07}x"
                    + "\u{1B}]133;C\u{07}o\u{1B}]133;D;0\u{07}\r\n",
                &parser,
                &term
            )
        }

        #expect(term.semanticOverflowTransitions.count < 300)
        #expect(term.semanticOverflowTransitions.count - term.semanticOverflowStart <= 8)
    }

    @Test("下一提示符的 B 不覆盖上一命令的 D 边界")
    func nextCommandPreservesPreviousEnd() {
        var (parser, term) = makeTerminal(columns: 30, rows: 5)
        let first = "\u{1B}]133;A\u{07}$ \u{1B}]133;B\u{07}first\r\n"
            + "\u{1B}]133;C\u{07}one\u{1B}]133;D;0\u{07}"
        let second = "\u{1B}]133;A\u{07}$ \u{1B}]133;B\u{07}second\r\n"
            + "\u{1B}]133;C\u{07}two\u{1B}]133;D;0\u{07}"
        feed(first + second, &parser, &term)

        let blocks = term.commandBlocks()
        #expect(blocks.count == 2)
        #expect(term.extractText(in: blocks[0].commandRange) == "first")
        #expect(blocks[0].outputRange.map { term.extractText(in: $0) } == "one")
        #expect(term.extractText(in: blocks[1].commandRange) == "second")
        #expect(blocks[1].outputRange.map { term.extractText(in: $0) } == "two")
    }
}
