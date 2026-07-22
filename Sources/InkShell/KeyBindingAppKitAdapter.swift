import AppKit
import InkConfig

enum KeyBindingAppKitAdapter {
    static func binding(from event: NSEvent) -> KeyBinding? {
        let flags = event.modifierFlags.intersection([.command, .control, .option, .shift])
        var modifiers: KeyBindingModifiers = []
        if flags.contains(.command) { modifiers.insert(.command) }
        if flags.contains(.control) { modifiers.insert(.control) }
        if flags.contains(.option) { modifiers.insert(.option) }
        if flags.contains(.shift) { modifiers.insert(.shift) }
        guard modifiers.contains(.command) || modifiers.contains(.control) else { return nil }
        let key: String
        if event.characters == "+" {
            // “plus” 表示生成的按键，而非物理键上的 Shift 修饰；否则默认的
            // cmd+plus 会被录制成无法与菜单 keyEquivalent 对齐的 cmd+shift+plus。
            key = "plus"
            modifiers.remove(.shift)
        } else {
            guard let characters = event.charactersIgnoringModifiers,
                  let token = keyToken(for: characters) else { return nil }
            key = token
        }
        return KeyBinding(key: key, modifiers: modifiers)
    }

    static func modifiers(from flags: NSEvent.ModifierFlags) -> KeyBindingModifiers {
        var result: KeyBindingModifiers = []
        if flags.contains(.command) { result.insert(.command) }
        if flags.contains(.control) { result.insert(.control) }
        if flags.contains(.option) { result.insert(.option) }
        if flags.contains(.shift) { result.insert(.shift) }
        return result
    }

    static func keyEquivalent(for binding: KeyBinding) -> String {
        if let equivalent = namedKeyEquivalents[binding.key] {
            return equivalent
        }
        if binding.key.first == "f",
           let number = Int(binding.key.dropFirst()),
           (1...20).contains(number),
           let scalar = UnicodeScalar(0xF703 + number) {
            return String(Character(scalar))
        }
        return binding.key
    }

    static func modifierFlags(for binding: KeyBinding) -> NSEvent.ModifierFlags {
        var flags: NSEvent.ModifierFlags = []
        if binding.modifiers.contains(.command) { flags.insert(.command) }
        if binding.modifiers.contains(.control) { flags.insert(.control) }
        if binding.modifiers.contains(.option) { flags.insert(.option) }
        if binding.modifiers.contains(.shift) { flags.insert(.shift) }
        return flags
    }

    static func displayString(for binding: KeyBinding) -> String {
        var result = ""
        if binding.modifiers.contains(.command) { result += "⌘" }
        if binding.modifiers.contains(.control) { result += "⌃" }
        if binding.modifiers.contains(.option) { result += "⌥" }
        if binding.modifiers.contains(.shift) { result += "⇧" }
        result += displayKey(binding.key)
        return result
    }

    private static func displayKey(_ key: String) -> String {
        switch key {
        case "left": "←"
        case "right": "→"
        case "up": "↑"
        case "down": "↓"
        case "return": "↩"
        case "tab": "⇥"
        case "space": "Space"
        case "escape": "Esc"
        case "delete": "⌫"
        case "forward_delete": "⌦"
        case "left_bracket": "["
        case "right_bracket": "]"
        default: key.uppercased()
        }
    }

    private static func keyToken(for characters: String) -> String? {
        if characters.count == 1, let value = characters.unicodeScalars.first?.value {
            if (0xF704...0xF717).contains(value) {
                return "f\(value - 0xF703)"
            }
            if value == 0x7F { return "delete" }
        }
        if let token = namedKeyEquivalents.first(where: { $0.value == characters })?.key {
            return token
        }
        let lowered = characters.lowercased()
        guard lowered.count == 1,
              lowered.first?.isLetter == true || lowered.first?.isNumber == true else {
            return nil
        }
        return lowered
    }

    private static let namedKeyEquivalents: [String: String] = [
        "plus": "+", "minus": "-", "comma": ",", "period": ".", "slash": "/",
        "semicolon": ";", "quote": "'", "backslash": "\\", "left_bracket": "[",
        "right_bracket": "]", "backtick": "`", "left": "\u{F702}",
        "right": "\u{F703}", "up": "\u{F700}", "down": "\u{F701}",
        "home": "\u{F729}", "end": "\u{F72B}", "page_up": "\u{F72C}",
        "page_down": "\u{F72D}", "return": "\r", "tab": "\t", "space": " ",
        "escape": "\u{1B}", "delete": "\u{8}", "forward_delete": "\u{F728}",
    ]
}
