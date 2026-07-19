import Foundation

/// M1 占位：把 VT 转义序列丢掉，只保留文本和最小的行内编辑语义。
///
/// **这不是 VT 解析**，是给 `NSTextView` 占位视图用的一次性 hack。真正的
/// 解析器在 `TerminalCore`（任务 #6），M2 换上 Metal 渲染器时本文件删除。
///
/// 之所以要保留 `\r` 和 `\b` 的语义：zsh 的行编辑器每次按键都通过
/// 「回到行首 + 清行 + 重画」刷新当前行，如果只是把控制字节丢掉、文本追加，
/// 屏幕上会出现每敲一键叠一层的重影（"ffrom"）。把 `\r` 映射成「重画当前
/// 行」、`\b` 映射成「删一个字符」，占位视图就能跟上 ZLE 的重画节奏。
///
/// 另外两件跨 read 边界的事必须做对：
/// - 转义序列可能被拆在两次读之间 → 状态机跨调用保持状态
/// - UTF-8 多字节字符可能被拆开 → 尾部不完整字节留到下一次
struct PlaceholderANSIStripper {

    /// 占位视图消费的最小事件流。
    enum Event {
        case text(String)
        case newline
        /// 回到行首：占位实现处理成「清掉当前行，后续文本是重画」。
        case carriageReturn
        case backspace
    }

    private enum State {
        case ground
        case escape          // 收到 ESC
        case csi             // ESC [ …
        case osc             // ESC ] …（OSC 以 BEL 或 ESC \ 结束）
        case oscEscape       // OSC 内收到 ESC，等 ST 的 '\'
        case charset         // ESC ( / ESC )，再吞一个字节
    }

    private var state: State = .ground
    private var utf8Carry: [UInt8] = []
    /// 收到 `\r` 后先挂起：紧跟 `\n` 就是普通行尾（PTY 的 ONLCR 把 `\n` 转成
    /// `\r\n`），跟其它内容才是 ZLE 的行重画。立刻发 `.carriageReturn` 会把
    /// 每一行都在行尾清掉，全屏变白。
    private var pendingCR = false

    mutating func process(_ data: Data) -> [Event] {
        var events: [Event] = []
        var pending: [UInt8] = utf8Carry
        utf8Carry = []
        pending.reserveCapacity(data.count)

        func flushText() {
            guard !pending.isEmpty else { return }
            events.append(.text(String(decoding: pending, as: UTF8.self)))
            pending.removeAll(keepingCapacity: true)
        }

        for byte in data {
            if pendingCR, state == .ground {
                pendingCR = false
                if byte == 0x0A {
                    events.append(.newline)
                    continue
                }
                events.append(.carriageReturn)
            }
            switch state {
            case .ground:
                switch byte {
                case 0x1B:
                    state = .escape
                case 0x0A:
                    flushText()
                    events.append(.newline)
                case 0x0D:
                    flushText()
                    pendingCR = true
                case 0x08:
                    flushText()
                    events.append(.backspace)
                case 0x09:
                    pending.append(byte)
                case 0x00..<0x20, 0x7F:
                    break // 其余控制字符直接丢
                default:
                    pending.append(byte)
                }
            case .escape:
                switch byte {
                case UInt8(ascii: "["): state = .csi
                case UInt8(ascii: "]"): state = .osc
                case UInt8(ascii: "("), UInt8(ascii: ")"): state = .charset
                default: state = .ground // 单字节转义（ESC M、ESC 7 等）
                }
            case .csi:
                // 0x40–0x7E 是终结字节，之前的参数与中间字节全部吞掉。
                if (0x40...0x7E).contains(byte) {
                    state = .ground
                }
            case .osc:
                if byte == 0x07 {
                    state = .ground
                } else if byte == 0x1B {
                    state = .oscEscape
                }
            case .oscEscape:
                state = .ground // ESC \ 是标准 ST；其它字节也一并结束，占位实现不较真
            case .charset:
                state = .ground
            }
        }

        holdIncompleteUTF8Tail(&pending)
        if !pending.isEmpty {
            events.append(.text(String(decoding: pending, as: UTF8.self)))
        }
        return events
    }

    /// 尾部若是截断的多字节字符，先扣下来拼到下一批，避免出现替换符。
    private mutating func holdIncompleteUTF8Tail(_ bytes: inout [UInt8]) {
        guard let last = bytes.last, last >= 0x80 else { return }

        // 从末尾往前找多字节序列的首字节（0b11xxxxxx），最多回看 3 字节。
        var start = bytes.count - 1
        var lookback = 0
        while start >= 0, lookback < 4 {
            if bytes[start] >= 0xC0 { break }
            start -= 1
            lookback += 1
        }
        guard start >= 0, bytes[start] >= 0xC0 else { return }

        let expected: Int
        switch bytes[start] {
        case 0xF0...: expected = 4
        case 0xE0...: expected = 3
        default: expected = 2
        }
        let available = bytes.count - start
        if available < expected {
            utf8Carry = Array(bytes[start...])
            bytes.removeLast(available)
        }
    }
}
