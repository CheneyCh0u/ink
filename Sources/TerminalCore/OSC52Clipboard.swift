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
        case probing(ContiguousArray<UInt8>)
        case regular(ContiguousArray<UInt8>)
        case osc52(OSC52PayloadAccumulator)
        case discarding
    }

    private var state: State = .idle

    mutating func start() { state = .probing([]) }
    mutating func cancel() { state = .idle }

    mutating func put(_ byte: UInt8) {
        switch state {
        case .idle, .discarding:
            return
        case .probing(var prefix):
            if byte == UInt8(ascii: ";"), prefix.elementsEqual("52".utf8) {
                state = .osc52(OSC52PayloadAccumulator())
            } else {
                prefix.append(byte)
                if !Array("52".utf8).starts(with: prefix) || prefix.count > 2 {
                    state = prefix.count > 4_096 ? .discarding : .regular(prefix)
                } else {
                    state = .probing(prefix)
                }
            }
        case .regular(var bytes):
            guard bytes.count < 4_096 else { state = .discarding; return }
            bytes.append(byte)
            state = .regular(bytes)
        case .osc52(var payload):
            payload.put(byte)
            state = payload.isDiscarding ? .discarding : .osc52(payload)
        }
    }

    mutating func finish() -> Completion? {
        defer { state = .idle }
        switch state {
        case .probing(let bytes), .regular(let bytes): return .regular(bytes)
        case .osc52(var payload): return payload.finish().map(Completion.clipboardWrite)
        case .idle, .discarding: return nil
        }
    }
}

struct OSC52PayloadAccumulator: Sendable {
    private enum State: Sendable {
        case target(ContiguousArray<UInt8>)
        case payload(OSC52Base64Decoder, isFirstByte: Bool)
        case discarding
    }

    private var state: State = .target([])

    var isDiscarding: Bool {
        if case .discarding = state { return true }
        return false
    }

    mutating func put(_ byte: UInt8) {
        switch state {
        case .discarding:
            return
        case .target(var target):
            guard byte != UInt8(ascii: ";") else {
                state = Self.accepts(target: target)
                    ? .payload(OSC52Base64Decoder(), isFirstByte: true)
                    : .discarding
                return
            }
            guard target.count < 16, Self.isKnownTarget(byte) else {
                state = .discarding
                return
            }
            target.append(byte)
            state = .target(target)
        case .payload(var decoder, let isFirstByte):
            guard !(isFirstByte && byte == UInt8(ascii: "?")) else {
                state = .discarding
                return
            }
            decoder.put(byte)
            state = decoder.invalid ? .discarding : .payload(decoder, isFirstByte: false)
        }
    }

    mutating func finish() -> String? {
        defer { state = .discarding }
        guard case .payload(var decoder, _) = state else { return nil }
        return decoder.finish()
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
