/// VT 字节流状态机，按 Paul Williams 的 VT500 状态图裁剪实现。
///
/// 职责边界：本类型只做**词法**——把字节流切成动作（打印、控制、CSI、OSC、
/// ESC），不理解任何语义。语义在 `Terminal`（TerminalActionHandler 的实现）。
///
/// 热路径纪律：`feed` 是每个输出字节都要过的函数。参数缓冲复用
/// （`removeAll(keepingCapacity:)`），稳态零分配；handler 走泛型特化，
/// 没有动态派发。
public struct Parser: Sendable {

    private enum State {
        case ground
        case escape
        case escapeIntermediate
        case csiEntry
        case csiParam
        case csiIntermediate
        case csiIgnore
        case osc
        case oscEscape       // OSC 内收到 ESC，等 ST 的 '\'
        case dcsIgnore       // DCS/SOS/PM/APC：整段吞掉直到 ST
        case dcsIgnoreEscape
    }

    private var state: State = .ground
    private var utf8 = UTF8Decoder()

    // CSI 累积。参数上限 16 个足够覆盖现实序列（SGR 长链在 Terminal 端逐个消费）。
    private var params: ContiguousArray<UInt16> = []
    private var paramPending: UInt32 = 0
    private var paramHasDigit = false
    private var prefix: UInt8 = 0            // '?'、'>'、'<'、'=' 私有前缀
    private var intermediates: ContiguousArray<UInt8> = []
    private var oscBuffer: ContiguousArray<UInt8> = []

    private static let maxParams = 16
    private static let maxOSCBytes = 4096    // OSC 超长（异常输出）直接截断，防内存放大

    public init() {
        params.reserveCapacity(Self.maxParams)
        intermediates.reserveCapacity(4)
    }

    public mutating func feed<H: TerminalActionHandler>(_ data: some Sequence<UInt8>, handler: inout H) {
        for byte in data {
            consume(byte, handler: &handler)
        }
    }

    // MARK: - 状态机

    private mutating func consume<H: TerminalActionHandler>(_ byte: UInt8, handler: inout H) {
        // CAN / SUB 在任何状态下取消当前序列。
        if byte == 0x18 || byte == 0x1A {
            state = .ground
            return
        }

        switch state {
        case .ground:
            switch byte {
            case 0x1B:
                utf8.reset()
                state = .escape
            case 0x00..<0x20, 0x7F:
                handler.execute(byte)
            default:
                switch utf8.feed(byte) {
                case .scalar(let scalar): handler.print(scalar)
                case .incomplete: break
                case .invalid: handler.print(0xFFFD)
                }
            }

        case .escape:
            switch byte {
            case UInt8(ascii: "["):
                resetCSI()
                state = .csiEntry
            case UInt8(ascii: "]"):
                oscBuffer.removeAll(keepingCapacity: true)
                state = .osc
            case UInt8(ascii: "P"), UInt8(ascii: "X"), UInt8(ascii: "^"), UInt8(ascii: "_"):
                state = .dcsIgnore
            case 0x20...0x2F:
                intermediates.removeAll(keepingCapacity: true)
                intermediates.append(byte)
                state = .escapeIntermediate
            case 0x00..<0x20:
                handler.execute(byte) // ESC 序列中的 C0 照常执行
            default:
                handler.escDispatch(intermediate: 0, final: byte)
                state = .ground
            }

        case .escapeIntermediate:
            switch byte {
            case 0x20...0x2F:
                intermediates.append(byte)
            case 0x00..<0x20:
                handler.execute(byte)
            default:
                handler.escDispatch(intermediate: intermediates.first ?? 0, final: byte)
                state = .ground
            }

        case .csiEntry, .csiParam, .csiIntermediate:
            switch byte {
            case 0x00..<0x20:
                handler.execute(byte) // CSI 中的 C0 立即执行（VT 标准行为）
            case UInt8(ascii: "0")...UInt8(ascii: "9"):
                if state == .csiIntermediate {
                    state = .csiIgnore // 中间字节之后不允许再出参数
                } else {
                    paramPending = min(paramPending * 10 + UInt32(byte - 0x30), 65535)
                    paramHasDigit = true
                    state = .csiParam
                }
            case UInt8(ascii: ";"), UInt8(ascii: ":"):
                // ':' 是子参数分隔符（SGR 4:3 下划线样式等），暂按 ';' 处理，
                // 语义端自行判断。完整子参数支持等真实需求出现再加。
                pushParam()
                state = .csiParam
            case UInt8(ascii: "<")...UInt8(ascii: "?"):
                if state == .csiEntry {
                    prefix = byte
                } else {
                    state = .csiIgnore
                }
            case 0x20...0x2F:
                intermediates.append(byte)
                state = .csiIntermediate
            case 0x40...0x7E:
                pushParam()
                handler.csiDispatch(
                    prefix: prefix,
                    params: params[...],
                    intermediates: intermediates[...],
                    final: byte
                )
                state = .ground
            default:
                state = .csiIgnore
            }

        case .csiIgnore:
            if (0x40...0x7E).contains(byte) {
                state = .ground
            }

        case .osc:
            switch byte {
            case 0x07:
                handler.oscDispatch(oscBuffer[...])
                state = .ground
            case 0x1B:
                state = .oscEscape
            case 0x00..<0x07, 0x08..<0x20:
                break // OSC 内的其它控制字节丢弃
            default:
                if oscBuffer.count < Self.maxOSCBytes {
                    oscBuffer.append(byte)
                }
            }

        case .oscEscape:
            if byte == UInt8(ascii: "\\") {
                handler.oscDispatch(oscBuffer[...])
            }
            // 非 ST：整段 OSC 作废，ESC 后字节也一并丢弃，回 ground 重新同步。
            state = .ground

        case .dcsIgnore:
            if byte == 0x1B { state = .dcsIgnoreEscape }

        case .dcsIgnoreEscape:
            state = byte == UInt8(ascii: "\\") ? .ground : .dcsIgnore
        }
    }

    // MARK: - CSI 缓冲

    private mutating func resetCSI() {
        params.removeAll(keepingCapacity: true)
        paramPending = 0
        paramHasDigit = false
        prefix = 0
        intermediates.removeAll(keepingCapacity: true)
    }

    private mutating func pushParam() {
        guard params.count < Self.maxParams else { return }
        params.append(paramHasDigit ? UInt16(paramPending) : 0)
        paramPending = 0
        paramHasDigit = false
    }
}

/// Parser 的动作输出。实现者是 `Terminal`；测试里用捕获桩。
public protocol TerminalActionHandler {
    /// 打印一个已解码的 Unicode 码点。
    mutating func print(_ scalar: UInt32)
    /// C0 控制字符（LF、CR、BS、HT、BEL…）。
    mutating func execute(_ control: UInt8)
    /// CSI 序列。`params` 未出现的参数为 0，语义端自补默认值。
    mutating func csiDispatch(prefix: UInt8, params: ArraySlice<UInt16>, intermediates: ArraySlice<UInt8>, final: UInt8)
    /// 非 CSI/OSC 的 ESC 序列（ESC 7 / ESC 8 / ESC M / ESC (B …）。
    mutating func escDispatch(intermediate: UInt8, final: UInt8)
    /// OSC 完整载荷（不含终结符）。
    mutating func oscDispatch(_ bytes: ArraySlice<UInt8>)
}
