/// 增量 UTF-8 解码器：字节可以在任意位置被拆开（PTY read 边界），
/// 状态跨调用保持。每字节一次函数调用，热路径，不分配。
public struct UTF8Decoder: Sendable {
    public enum Output {
        /// 凑出一个完整码点。
        case scalar(UInt32)
        /// 还差后续字节。
        case incomplete
        /// 非法序列，调用方决定替换策略。
        case invalid
    }

    private var accumulated: UInt32 = 0
    private var remaining: Int = 0

    public init() {}

    @inline(__always)
    public mutating func feed(_ byte: UInt8) -> Output {
        if remaining > 0 {
            guard byte & 0xC0 == 0x80 else {
                // 续字节缺席：当前序列作废，这个字节要由调用方重喂。
                remaining = 0
                return .invalid
            }
            accumulated = (accumulated << 6) | UInt32(byte & 0x3F)
            remaining -= 1
            if remaining == 0 {
                // 拒绝代理区与超界。宽松处理过长编码（overlong）：终端场景
                // 里把它当普通码点显示比中断流更稳。
                if accumulated >= 0xD800 && accumulated <= 0xDFFF || accumulated > 0x10FFFF {
                    return .invalid
                }
                return .scalar(accumulated)
            }
            return .incomplete
        }

        switch byte {
        case 0x00...0x7F:
            return .scalar(UInt32(byte))
        case 0xC0...0xDF:
            accumulated = UInt32(byte & 0x1F)
            remaining = 1
            return .incomplete
        case 0xE0...0xEF:
            accumulated = UInt32(byte & 0x0F)
            remaining = 2
            return .incomplete
        case 0xF0...0xF4:
            accumulated = UInt32(byte & 0x07)
            remaining = 3
            return .incomplete
        default:
            return .invalid // 孤立续字节或非法首字节
        }
    }

    public mutating func reset() {
        remaining = 0
        accumulated = 0
    }
}
