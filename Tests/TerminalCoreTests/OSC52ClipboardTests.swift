import Testing
@testable import TerminalCore

@Suite("OSC 52 剪贴板")
struct OSC52ClipboardTests {
    private func decode(_ encoded: String) -> String? {
        var decoder = OSC52Base64Decoder()
        for byte in encoded.utf8 { decoder.put(byte) }
        return decoder.finish()
    }

    private func sequence(target: String = "c", payload: String, terminator: String = "\u{07}") -> String {
        "\u{1B}]52;\(target);\(payload)\(terminator)"
    }

    @Test("严格 Base64 接受 UTF-8 与空载荷")
    func strictBase64AcceptsTextAndEmpty() {
        #expect(decode("") == "")
        #expect(decode("5L2g5aW9") == "你好")
        #expect(decode("Zg==") == "f")
        #expect(decode("Zm8=") == "fo")
    }

    @Test("严格 Base64 拒绝非规范输入和非法 UTF-8")
    func strictBase64RejectsInvalidInput() {
        for value in ["Zg", "Zg=", "Zh==", "Zm9=", "Z g==", "Zg==x", "_w==", "/w=="] {
            #expect(decode(value) == nil)
        }
    }

    @Test("解码结果恰好一 MiB 可用，下一字节触发丢弃")
    func decodedLimitIsExact() {
        let exact = String(repeating: "QUFB", count: OSC52Base64Decoder.maximumDecodedBytes / 3)
            + "QQ=="
        #expect(decode(exact)?.utf8.count == OSC52Base64Decoder.maximumDecodedBytes)
        let overflow = String(
            repeating: "QUFB",
            count: OSC52Base64Decoder.maximumDecodedBytes / 3
        ) + "QUE="
        #expect(decode(overflow) == nil)
    }

    @Test("BEL、ST、分片与 UTF-8 都产生写入效果")
    func parsesTerminatorsAndSplitReads() {
        var (parser, terminal) = makeTerminal()
        let bytes = Array(sequence(payload: "5L2g5aW9").utf8)
        feed(bytes.prefix(7), &parser, &terminal)
        #expect(terminal.takeEffects().isEmpty)
        feed(bytes.dropFirst(7), &parser, &terminal)
        #expect(terminal.takeEffects() == [.clipboardWrite("你好")])
        feed(sequence(target: "ps", payload: "Zg==", terminator: "\u{1B}\\"), &parser, &terminal)
        #expect(terminal.takeEffects() == [.clipboardWrite("f")])
    }

    @Test("空目标可清空，仅不支持目标和查询无副作用")
    func targetAndQueryPolicy() {
        var (parser, terminal) = makeTerminal()
        feed(sequence(target: "", payload: ""), &parser, &terminal)
        #expect(terminal.takeEffects() == [.clipboardWrite("")])
        for target in ["q", "0", "17", "x", String(repeating: "c", count: 17)] {
            feed(sequence(target: target, payload: "Zg=="), &parser, &terminal)
            #expect(terminal.takeEffects().isEmpty)
        }
        feed(sequence(payload: "?"), &parser, &terminal)
        #expect(terminal.takeEffects().isEmpty)
        #expect(terminal.takeResponses().isEmpty)
    }

    @Test("取消、非法载荷与超限不泄漏到屏幕")
    func invalidSequencesAreAtomic() {
        var (parser, terminal) = makeTerminal()
        for bytes in [
            Array("\u{1B}]52;c;Z g==\u{07}X".utf8),
            [0x1B, 0x5D] + Array("52;c;Zg==".utf8) + [0x18, UInt8(ascii: "Y")],
            [0x1B, 0x5D] + Array("52;c;Zg==".utf8) + [0x1B, UInt8(ascii: "x"), UInt8(ascii: "Z")],
        ] {
            feed(bytes, &parser, &terminal)
            #expect(terminal.takeEffects().isEmpty)
        }
        #expect(rowText(terminal, 0).hasPrefix("XYZ"))
    }

    @Test("一个 feed 中只保留最后一次写入")
    func coalescesEffects() {
        var (parser, terminal) = makeTerminal()
        feed(sequence(payload: "Zmlyc3Q=") + sequence(payload: "bGFzdA=="), &parser, &terminal)
        #expect(terminal.takeEffects() == [.clipboardWrite("last")])
        #expect(terminal.takeEffects().isEmpty)
    }

    @Test("搜索快照剥离未完成 OSC 与效果")
    func searchSnapshotStripsSensitiveState() {
        var (parser, terminal) = makeTerminal()
        feed(sequence(payload: "c2VjcmV0"), &parser, &terminal)
        var snapshot = terminal.snapshotForSearch()
        #expect(snapshot.takeEffects().isEmpty)
        #expect(terminal.takeEffects() == [.clipboardWrite("secret")])
        feed("\u{1B}]52;c;c2Vj", &parser, &terminal)
        snapshot = terminal.snapshotForSearch()
        snapshot.oscEnd()
        #expect(snapshot.takeEffects().isEmpty)
    }
}
