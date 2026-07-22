import Testing
@testable import TerminalCore

@Suite("OSC 主动通知")
struct OSCNotificationTests {
    @Test("OSC 9 使用 BEL 产生无标题通知")
    func osc9BEL() {
        #expect(events(for: [Array("\u{1B}]9;构建完成\u{7}".utf8)]) == [
            .notification(.init(title: nil, body: "构建完成")),
        ])
    }

    @Test("OSC 777 使用 ST 并保留正文分号")
    func osc777ST() {
        #expect(events(for: [Array("\u{1B}]777;notify;部署;节点 a;b\u{1B}\\".utf8)]) == [
            .notification(.init(title: "部署", body: "节点 a;b")),
        ])
    }

    @Test("OSC 777 空标题归一化为 nil")
    func emptyTitle() {
        #expect(events(for: [Array("\u{1B}]777;notify;;完成\u{7}".utf8)]) == [
            .notification(.init(title: nil, body: "完成")),
        ])
    }

    @Test("未知或不完整语法静默忽略", arguments: [
        "\u{1B}]10;消息\u{7}",
        "\u{1B}]777;report;标题;正文\u{7}",
        "\u{1B}]777;Notify;标题;正文\u{7}",
        "\u{1B}]777;notify;只有标题\u{7}",
        "\u{1B}]9;\u{7}",
        "\u{1B}]9;   \u{7}",
    ])
    func invalidSyntax(_ sequence: String) {
        #expect(events(for: [Array(sequence.utf8)]).isEmpty)
    }

    @Test("非法 UTF-8 和显示控制字符静默忽略")
    func invalidText() {
        let prefix = Array("\u{1B}]9;".utf8)
        #expect(events(for: [prefix + [0xFF, 0x07]]).isEmpty)
        #expect(events(for: [prefix + Array("前\u{7F}后\u{7}".utf8)]).isEmpty)
        #expect(events(for: [prefix + Array("前\u{0085}后\u{7}".utf8)]).isEmpty)
    }

    @Test("标题和正文使用原始 UTF-8 字节上限")
    func fieldLimits() {
        let acceptedTitle = String(repeating: "t", count: 128)
        let rejectedTitle = String(repeating: "t", count: 129)
        let acceptedBody = String(repeating: "b", count: 1024)
        let rejectedBody = String(repeating: "b", count: 1025)

        #expect(events(for: [Array("\u{1B}]777;notify;\(acceptedTitle);好\u{7}".utf8)]) == [
            .notification(.init(title: acceptedTitle, body: "好")),
        ])
        #expect(events(for: [Array("\u{1B}]777;notify;\(rejectedTitle);好\u{7}".utf8)]).isEmpty)
        #expect(events(for: [Array("\u{1B}]9;\(acceptedBody)\u{7}".utf8)]) == [
            .notification(.init(title: nil, body: acceptedBody)),
        ])
        #expect(events(for: [Array("\u{1B}]9;\(rejectedBody)\u{7}".utf8)]).isEmpty)
    }
}

private func events(for chunks: [[UInt8]]) -> [TerminalEvent] {
    var parser = Parser()
    var terminal = Terminal(size: .init(columns: 80, rows: 24))
    for chunk in chunks {
        parser.feed(chunk, handler: &terminal)
    }
    return terminal.takeEvents()
}
