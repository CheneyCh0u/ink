import Testing
@testable import TerminalCore

@Suite("终端 URL 链接")
struct TerminalURLLinkTests {
    @Test("识别 HTTP/HTTPS 并去掉句末标点")
    func detectsURLsAndTrimsPunctuation() throws {
        var (parser, terminal) = makeTerminal(columns: 80, rows: 3)
        feed("见 https://example.test/a_(b)，以及 HTTP://EXAMPLE.TEST/x.", &parser, &terminal)

        let first = try #require(terminal.link(at: TextPosition(line: 0, column: 5)))
        #expect(first.target == "https://example.test/a_(b)")
        #expect(first.source == .detectedURL)
        #expect(first.range.start == TextPosition(line: 0, column: 3))
        let second = try #require(terminal.link(at: TextPosition(line: 0, column: 42)))
        #expect(second.target == "HTTP://EXAMPLE.TEST/x")
    }

    @Test("软折行 URL 返回跨物理行半开范围")
    func detectsWrappedURL() throws {
        var (parser, terminal) = makeTerminal(columns: 12, rows: 4)
        feed("xx https://example.test/path", &parser, &terminal)

        let link = try #require(terminal.link(at: TextPosition(line: 1, column: 3)))
        #expect(link.target == "https://example.test/path")
        #expect(link.range.start == TextPosition(line: 0, column: 3))
        #expect(link.range.end.line >= 1)
    }

    @Test("宽字符前缀不会让 cell 坐标漂移")
    func mapsWidePrefixToCellColumns() throws {
        var (parser, terminal) = makeTerminal(columns: 60, rows: 2)
        feed("终端 https://example.test", &parser, &terminal)

        let link = try #require(terminal.link(at: TextPosition(line: 0, column: 8)))
        #expect(link.range.start == TextPosition(line: 0, column: 5))
        #expect(terminal.link(at: TextPosition(line: 0, column: 4)) == nil)
    }

    @Test("硬换行、无 host 与非 HTTP scheme 不自动识别")
    func rejectsNonURLs() {
        var (parser, terminal) = makeTerminal(columns: 40, rows: 3)
        feed("https://\r\nfile:///tmp/a mailto:a@example.test", &parser, &terminal)

        #expect(terminal.link(at: TextPosition(line: 0, column: 2)) == nil)
        #expect(terminal.link(at: TextPosition(line: 1, column: 2)) == nil)
    }

    @Test("搜索结果坐标可直接查询同一链接")
    func searchCoordinatesResolveLink() throws {
        var (parser, terminal) = makeTerminal(columns: 40, rows: 3)
        feed("go https://example.test/path now", &parser, &terminal)
        let match = try #require(TerminalSearchEngine.search(in: terminal, query: "example").first)
        let link = try #require(terminal.link(at: match.range.start))
        #expect(link.target == "https://example.test/path")
        #expect(link.range.start == TextPosition(line: 0, column: 3))
    }
}
