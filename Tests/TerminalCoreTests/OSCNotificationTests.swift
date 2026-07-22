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

    @Test("通知 code 只接受精确 ASCII", arguments: [
        "\u{1B}]+9;消息\u{7}",
        "\u{1B}]09;消息\u{7}",
        "\u{1B}]+777;notify;标题;正文\u{7}",
        "\u{1B}]0777;notify;标题;正文\u{7}",
    ])
    func exactNotificationCode(_ sequence: String) {
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

    @Test("UTF-8 与 ST 可跨任意输出 chunk")
    func chunkedFeed() {
        let bytes = Array("\u{1B}]777;notify;构建;完成\u{1B}\\".utf8)
        let chunks = bytes.map { [$0] }
        #expect(events(for: chunks) == [
            .notification(.init(title: "构建", body: "完成")),
        ])
    }

    @Test("同一 chunk 的多条通知各产生一次")
    func multipleNotifications() {
        let input = "\u{1B}]9;一\u{7}\u{1B}]777;notify;二;三\u{1B}\\"
        #expect(events(for: [Array(input.utf8)]) == [
            .notification(.init(title: nil, body: "一")),
            .notification(.init(title: "二", body: "三")),
        ])
    }

    @Test("OSC 内嵌 C0 使整段失效", arguments: [UInt8(0x00), 0x09, 0x0A])
    func embeddedC0(_ control: UInt8) {
        let prefix = Array("\u{1B}]9;前".utf8)
        let suffix = Array("后\u{7}".utf8)
        #expect(events(for: [prefix + [control] + suffix]).isEmpty)
    }

    @Test("超长 OSC 不执行截断前缀且终止后恢复")
    func oversizedSequence() {
        var parser = Parser()
        var terminal = Terminal(size: .init(columns: 80, rows: 24))
        let oversized = Array("\u{1B}]0;".utf8)
            + Array(repeating: UInt8(ascii: "a"), count: 4095)
            + [0x07]
        parser.feed(oversized, handler: &terminal)
        #expect(terminal.title.isEmpty)

        parser.feed(Array("\u{1B}]9;恢复\u{7}".utf8), handler: &terminal)
        #expect(terminal.takeEvents() == [
            .notification(.init(title: nil, body: "恢复")),
        ])
    }

    @Test("取消、非法 ST 与未终止序列不产生事件")
    func cancelledOrUnterminated() {
        #expect(events(for: [Array("\u{1B}]9;取消\u{18}".utf8)]).isEmpty)
        #expect(events(for: [Array("\u{1B}]9;取消\u{1A}".utf8)]).isEmpty)
        #expect(events(for: [Array("\u{1B}]9;坏 ST\u{1B}x".utf8)]).isEmpty)
        #expect(events(for: [Array("\u{1B}]9;未结束".utf8)]).isEmpty)
    }

    @Test("单个输出 chunk 最多积压六十四个通知事件")
    func boundedEventQueue() {
        let input = (0..<80)
            .map { "\u{1B}]9;消息\($0)\u{7}" }
            .joined()
        let received = events(for: [Array(input.utf8)])

        #expect(received.count == 64)
        #expect(received.first == .notification(.init(title: nil, body: "消息0")))
        #expect(received.last == .notification(.init(title: nil, body: "消息63")))

        #expect(events(for: [Array("\u{1B}]9;下一批\u{7}".utf8)]) == [
            .notification(.init(title: nil, body: "下一批")),
        ])
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
