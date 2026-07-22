import AppKit
import InkConfig

enum KeyBindingAppKitAdapter {
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
