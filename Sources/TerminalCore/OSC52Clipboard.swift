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
        let (q0, q1, q2, q3) = quartet
        guard q0 < 64, q1 < 64,
              !(q2 == 64 && q3 != 64),
              q2 == 64 ? (q1 & 0x0F) == 0 : true,
              q3 == 64 ? (q2 & 0x03) == 0 : true else {
            invalid = true; discard(); return
        }
        let outputCount = q2 == 64 ? 1 : (q3 == 64 ? 2 : 3)
        guard decoded.count <= Self.maximumDecodedBytes - outputCount else {
            invalid = true; discard(); return
        }
        decoded.append((q0 << 2) | (q1 >> 4))
        if outputCount > 1 { decoded.append((q1 << 4) | (q2 >> 2)) }
        if outputCount > 2 { decoded.append((q2 << 6) | q3) }
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

public enum TerminalEffect: Equatable, Sendable {
    case clipboardWrite(String)
}

struct OSCAccumulator: Sendable {
    enum Completion: Sendable {
        case regular(ContiguousArray<UInt8>)
        case clipboardWrite(String)
    }

    private enum State: Sendable {
        case idle
        case probing
        case regular
        case osc52
        case discarding
    }

    private var state: State = .idle
    private var regularBytes: ContiguousArray<UInt8> = []
    private var osc52Payload = OSC52PayloadAccumulator()

    mutating func start() {
        regularBytes = []
        osc52Payload = OSC52PayloadAccumulator()
        state = .probing
    }

    mutating func cancel() {
        regularBytes = []
        osc52Payload = OSC52PayloadAccumulator()
        state = .idle
    }

    mutating func put(_ byte: UInt8) {
        switch state {
        case .idle, .discarding:
            return
        case .probing:
            if byte == UInt8(ascii: ";"), regularBytes.elementsEqual("52".utf8) {
                regularBytes = []
                osc52Payload = OSC52PayloadAccumulator()
                state = .osc52
            } else {
                regularBytes.append(byte)
                if !"52".utf8.starts(with: regularBytes) || regularBytes.count > 2 {
                    state = regularBytes.count > 4_096 ? .discarding : .regular
                } else {
                    state = .probing
                }
            }
        case .regular:
            guard regularBytes.count < 4_096 else {
                regularBytes = []
                state = .discarding
                return
            }
            regularBytes.append(byte)
        case .osc52:
            osc52Payload.put(byte)
            if osc52Payload.isDiscarding { state = .discarding }
        }
    }

    mutating func finish() -> Completion? {
        defer { cancel() }
        switch state {
        case .probing, .regular: return .regular(regularBytes)
        case .osc52: return osc52Payload.finish().map(Completion.clipboardWrite)
        case .idle, .discarding: return nil
        }
    }
}

struct OSC52PayloadAccumulator: Sendable {
    private enum State: Sendable {
        case target
        case payload
        case discarding
    }

    private var state: State = .target
    private var target: ContiguousArray<UInt8> = []
    private var decoder = OSC52Base64Decoder()
    private var isFirstPayloadByte = true

    var isDiscarding: Bool {
        if case .discarding = state { return true }
        return false
    }

    mutating func put(_ byte: UInt8) {
        switch state {
        case .discarding:
            return
        case .target:
            guard byte != UInt8(ascii: ";") else {
                guard Self.accepts(target: target) else {
                    discard()
                    return
                }
                target = []
                decoder = OSC52Base64Decoder()
                isFirstPayloadByte = true
                state = .payload
                return
            }
            guard target.count < 16, Self.isKnownTarget(byte) else {
                discard()
                return
            }
            target.append(byte)
        case .payload:
            guard !(isFirstPayloadByte && byte == UInt8(ascii: "?")) else {
                discard()
                return
            }
            decoder.put(byte)
            isFirstPayloadByte = false
            if decoder.invalid { discard() }
        }
    }

    mutating func finish() -> String? {
        guard case .payload = state else { return nil }
        defer { state = .discarding }
        return decoder.finish()
    }

    private mutating func discard() {
        target = []
        decoder.discard()
        state = .discarding
    }

    private static func accepts(target: ContiguousArray<UInt8>) -> Bool {
        target.isEmpty || target.contains { byte in
            byte == UInt8(ascii: "c") || byte == UInt8(ascii: "p") || byte == UInt8(ascii: "s")
        }
    }

    private static func isKnownTarget(_ byte: UInt8) -> Bool {
        byte == UInt8(ascii: "c") || byte == UInt8(ascii: "p") || byte == UInt8(ascii: "q")
            || byte == UInt8(ascii: "s")
            || (UInt8(ascii: "0")...UInt8(ascii: "7")).contains(byte)
    }
}
