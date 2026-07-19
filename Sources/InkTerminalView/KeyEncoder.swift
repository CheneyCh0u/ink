import AppKit
import TerminalCore

/// 按键与鼠标事件 → 终端字节序列。纯函数，视图层只做转发。
enum KeyEncoder {

    /// xterm 修饰键参数：1 + Shift(1) + Alt(2) + Ctrl(4)。
    static func modifierParam(_ flags: NSEvent.ModifierFlags) -> Int {
        var p = 1
        if flags.contains(.shift) { p += 1 }
        if flags.contains(.option) { p += 2 }
        if flags.contains(.control) { p += 4 }
        return p
    }

    /// 功能键与字符编码。`applicationCursorKeys` 是 DECCKM（vim 等开启后
    /// 方向键要发 SS3 前缀）。
    static func encode(event: NSEvent, applicationCursorKeys: Bool) -> Data? {
        guard let characters = event.characters, let scalar = characters.unicodeScalars.first else {
            return nil
        }
        let mods = modifierParam(event.modifierFlags)

        // 方向键：无修饰时按 DECCKM 分流，带修饰统一 CSI 1;mod X。
        func arrow(_ letter: String) -> Data {
            if mods > 1 { return Data("\u{1B}[1;\(mods)\(letter)".utf8) }
            return applicationCursorKeys
                ? Data("\u{1B}O\(letter)".utf8)
                : Data("\u{1B}[\(letter)".utf8)
        }
        func tilde(_ n: Int) -> Data {
            mods > 1 ? Data("\u{1B}[\(n);\(mods)~".utf8) : Data("\u{1B}[\(n)~".utf8)
        }
        // F1–F4 历史上是 SS3 P/Q/R/S，带修饰时转 CSI 1;mod 形式。
        func fkeyLow(_ letter: String) -> Data {
            mods > 1 ? Data("\u{1B}[1;\(mods)\(letter)".utf8) : Data("\u{1B}O\(letter)".utf8)
        }

        switch scalar.value {
        case 0xF700: return arrow("A") // ↑
        case 0xF701: return arrow("B") // ↓
        case 0xF703: return arrow("C") // →
        case 0xF702: return arrow("D") // ←
        case 0xF729: return mods > 1 ? Data("\u{1B}[1;\(mods)H".utf8) : Data("\u{1B}[H".utf8) // Home
        case 0xF72B: return mods > 1 ? Data("\u{1B}[1;\(mods)F".utf8) : Data("\u{1B}[F".utf8) // End
        case 0xF72C: return tilde(5) // PageUp
        case 0xF72D: return tilde(6) // PageDown
        case 0xF728: return tilde(3) // fn⌫（前删）
        case 0xF704: return fkeyLow("P") // F1
        case 0xF705: return fkeyLow("Q")
        case 0xF706: return fkeyLow("R")
        case 0xF707: return fkeyLow("S")
        case 0xF708: return tilde(15) // F5
        case 0xF709: return tilde(17) // F6：xterm 编号从这里开始跳档
        case 0xF70A: return tilde(18)
        case 0xF70B: return tilde(19)
        case 0xF70C: return tilde(20)
        case 0xF70D: return tilde(21)
        case 0xF70E: return tilde(23) // F11 再跳一档
        case 0xF70F: return tilde(24) // F12
        case 0xF700...0xF8FF: return nil
        case 0x19: return Data("\u{1B}[Z".utf8) // ⇧Tab → CSI Z（backtab）
        case 0x0D: return Data([0x0D])
        case 0x7F: return Data([0x7F])
        default:
            return Data(characters.utf8)
        }
    }

    // MARK: - 鼠标上报

    enum MouseAction {
        case press, release, drag, motion
        case wheelUp, wheelDown
    }

    /// SGR（?1006）或 legacy X10 编码。`column`/`row` 从 1 起。
    static func encodeMouse(
        action: MouseAction, button: Int,
        column: Int, row: Int,
        flags: NSEvent.ModifierFlags, sgr: Bool
    ) -> Data {
        var code: Int
        switch action {
        case .wheelUp: code = 64
        case .wheelDown: code = 65
        default: code = button
        }
        if action == .drag || action == .motion { code += 32 }
        if flags.contains(.shift) { code += 4 }
        if flags.contains(.option) { code += 8 }
        if flags.contains(.control) { code += 16 }

        if sgr {
            let suffix = action == .release ? "m" : "M"
            return Data("\u{1B}[<\(code);\(column);\(row)\(suffix)".utf8)
        }
        // legacy：坐标 32 偏移，上限 223 列/行。
        if action == .release { code = 3 }
        let cx = UInt8(clamping: 32 + min(column, 223))
        let cy = UInt8(clamping: 32 + min(row, 223))
        return Data([0x1B, UInt8(ascii: "["), UInt8(ascii: "M"), UInt8(clamping: 32 + code), cx, cy])
    }
}
