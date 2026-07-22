import Testing
@testable import TerminalCore

@Suite("OSC 52 剪贴板")
struct OSC52ClipboardTests {
    private func decode(_ encoded: String) -> String? {
        var decoder = OSC52Base64Decoder()
        for byte in encoded.utf8 { decoder.put(byte) }
        return decoder.finish()
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
}
