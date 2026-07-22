struct OSC52Base64Decoder: Sendable {
    static let maximumDecodedBytes = 1_048_576

    private var quartet: (UInt8, UInt8, UInt8, UInt8) = (0, 0, 0, 0)
    private var quartetCount = 0
    private var sawPadding = false
    private(set) var invalid = false
    private var decoded: ContiguousArray<UInt8> = []

    mutating func put(_ byte: UInt8) {
        guard !invalid, !sawPadding else { invalid = true; discard(); return }
        let slot = quartetCount
        let value: UInt8
        if byte == UInt8(ascii: "=") {
            guard slot >= 2 else { invalid = true; discard(); return }
            value = 64
        } else if let sextet = Self.sextet(byte) {
            value = sextet
        } else {
            invalid = true
            discard()
            return
        }
        withUnsafeMutableBytes(of: &quartet) { $0[slot] = value }
        quartetCount += 1
        if quartetCount == 4 { flushQuartet() }
    }

    mutating func finish() -> String? {
        guard !invalid, quartetCount == 0 else { discard(); return nil }
        let bytes = decoded
        decoded = []
        return String(bytes: bytes, encoding: .utf8)
    }

    mutating func discard() {
        decoded = []
        quartetCount = 0
    }

    private mutating func flushQuartet() {
        let q = withUnsafeBytes(of: quartet) { Array($0) }
        guard q[0] < 64, q[1] < 64,
              !(q[2] == 64 && q[3] != 64),
              q[2] == 64 ? (q[1] & 0x0F) == 0 : true,
              q[3] == 64 ? (q[2] & 0x03) == 0 : true else {
            invalid = true; discard(); return
        }
        let outputCount = q[2] == 64 ? 1 : (q[3] == 64 ? 2 : 3)
        guard decoded.count <= Self.maximumDecodedBytes - outputCount else {
            invalid = true; discard(); return
        }
        decoded.append((q[0] << 2) | (q[1] >> 4))
        if outputCount > 1 { decoded.append((q[1] << 4) | (q[2] >> 2)) }
        if outputCount > 2 { decoded.append((q[2] << 6) | q[3]) }
        sawPadding = outputCount < 3
        quartetCount = 0
    }

    private static func sextet(_ byte: UInt8) -> UInt8? {
        switch byte {
        case 65...90: byte - 65
        case 97...122: byte - 97 + 26
        case 48...57: byte - 48 + 52
        case 43: 62
        case 47: 63
        default: nil
        }
    }
}
