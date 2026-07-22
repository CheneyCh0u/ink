import Foundation

public enum KeyBindingAction: String, CaseIterable, Hashable, Sendable {
    case newProject = "new_project"
    case newTab = "new_tab"
    case closePane = "close_pane"
    case splitPrefix = "split_prefix"
    case splitLeft = "split_left"
    case splitRight = "split_right"
    case splitUp = "split_up"
    case splitDown = "split_down"
    case focusLeft = "focus_left"
    case focusRight = "focus_right"
    case focusUp = "focus_up"
    case focusDown = "focus_down"
    case find
    case fontIncrease = "font_increase"
    case fontDecrease = "font_decrease"
    case fontReset = "font_reset"
    case previousCommand = "previous_command"
    case nextCommand = "next_command"
    case copyCommand = "copy_command"
    case copyOutput = "copy_output"
    case previousTab = "previous_tab"
    case nextTab = "next_tab"
    case toggleSidebar = "toggle_sidebar"
}

public struct KeyBindingModifiers: OptionSet, Hashable, Sendable {
    public let rawValue: UInt8

    public init(rawValue: UInt8) {
        self.rawValue = rawValue
    }

    public static let command = Self(rawValue: 1 << 0)
    public static let control = Self(rawValue: 1 << 1)
    public static let option = Self(rawValue: 1 << 2)
    public static let shift = Self(rawValue: 1 << 3)
}

public struct KeyBinding: Hashable, Sendable {
    public let key: String
    public let modifiers: KeyBindingModifiers

    public init(key: String, modifiers: KeyBindingModifiers) {
        self.key = key
        self.modifiers = modifiers
    }

    public static func parse(_ text: String) -> KeyBinding? {
        let tokens = text
            .split(separator: "+", omittingEmptySubsequences: false)
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() }
        guard tokens.count >= 2, !tokens.contains(where: \.isEmpty) else { return nil }

        var modifiers: KeyBindingModifiers = []
        var key: String?
        for token in tokens {
            let modifier: KeyBindingModifiers?
            switch token {
            case "cmd", "command": modifier = .command
            case "ctrl", "control": modifier = .control
            case "alt", "option": modifier = .option
            case "shift": modifier = .shift
            default: modifier = nil
            }
            if let modifier {
                guard !modifiers.contains(modifier), key == nil else { return nil }
                modifiers.insert(modifier)
            } else {
                guard key == nil, Self.validKeys.contains(token) else { return nil }
                key = token
            }
        }

        guard let key,
              modifiers.contains(.command) || modifiers.contains(.control) else { return nil }
        return KeyBinding(key: key, modifiers: modifiers)
    }

    public var serialized: String {
        var tokens: [String] = []
        if modifiers.contains(.command) { tokens.append("cmd") }
        if modifiers.contains(.control) { tokens.append("ctrl") }
        if modifiers.contains(.option) { tokens.append("alt") }
        if modifiers.contains(.shift) { tokens.append("shift") }
        tokens.append(key)
        return tokens.joined(separator: "+")
    }

    private static let validKeys: Set<String> = {
        var keys = Set("abcdefghijklmnopqrstuvwxyz0123456789".map(String.init))
        keys.formUnion([
            "plus", "minus", "comma", "period", "slash", "semicolon", "quote",
            "backslash", "left_bracket", "right_bracket", "backtick",
            "left", "right", "up", "down", "home", "end", "page_up", "page_down",
            "return", "tab", "space", "escape", "delete", "forward_delete",
        ])
        keys.formUnion((1...20).map { "f\($0)" })
        return keys
    }()
}

public enum KeyBindingAssignment: Equatable, Sendable {
    case disabled
    case binding(KeyBinding)
}

public enum KeyBindingValidationIssue: Error, Equatable, Sendable {
    case invalidSyntax(String)
    case reserved(KeyBinding)
    case conflict(KeyBinding, actions: [KeyBindingAction])
}

public struct KeyBindingSet: Equatable, Sendable {
    private var assignments: [KeyBindingAction: KeyBindingAssignment]

    private init(assignments: [KeyBindingAction: KeyBindingAssignment]) {
        self.assignments = assignments
    }

    public static let defaults = KeyBindingSet(assignments: [
        .newProject: .binding(required("cmd+n")),
        .newTab: .binding(required("cmd+t")),
        .closePane: .binding(required("cmd+w")),
        .splitPrefix: .binding(required("cmd+d")),
        .splitLeft: .disabled,
        .splitRight: .disabled,
        .splitUp: .disabled,
        .splitDown: .disabled,
        .focusLeft: .binding(required("cmd+alt+left")),
        .focusRight: .binding(required("cmd+alt+right")),
        .focusUp: .binding(required("cmd+alt+up")),
        .focusDown: .binding(required("cmd+alt+down")),
        .find: .binding(required("cmd+f")),
        .fontIncrease: .binding(required("cmd+plus")),
        .fontDecrease: .binding(required("cmd+minus")),
        .fontReset: .binding(required("cmd+0")),
        .previousCommand: .binding(required("cmd+shift+up")),
        .nextCommand: .binding(required("cmd+shift+down")),
        .copyCommand: .binding(required("cmd+shift+c")),
        .copyOutput: .binding(required("cmd+shift+o")),
        .previousTab: .binding(required("cmd+shift+left_bracket")),
        .nextTab: .binding(required("cmd+shift+right_bracket")),
        .toggleSidebar: .binding(required("cmd+ctrl+s")),
    ])

    public func assignment(for action: KeyBindingAction) -> KeyBindingAssignment? {
        assignments[action]
    }

    public func binding(for action: KeyBindingAction) -> KeyBinding? {
        guard case .binding(let binding) = assignments[action] else { return nil }
        return binding
    }

    public func serializedValues() -> [String: String] {
        Dictionary(uniqueKeysWithValues: KeyBindingAction.allCases.map { action in
            let value = switch assignments[action] {
            case .binding(let binding): binding.serialized
            case .disabled, nil: ""
            }
            return (action.rawValue, value)
        })
    }

    public static func resolving(
        _ raw: [String: String]
    ) -> (bindings: KeyBindingSet, issues: [KeyBindingAction: KeyBindingValidationIssue]) {
        var proposed = defaults.assignments
        var issues: [KeyBindingAction: KeyBindingValidationIssue] = [:]

        for action in KeyBindingAction.allCases {
            guard let value = raw[action.rawValue] else { continue }
            if value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                proposed[action] = .disabled
            } else if let binding = KeyBinding.parse(value) {
                if reservedBindings.contains(binding) {
                    issues[action] = .reserved(binding)
                    proposed[action] = defaults.assignments[action]
                } else {
                    proposed[action] = .binding(binding)
                }
            } else {
                issues[action] = .invalidSyntax(value)
                proposed[action] = defaults.assignments[action]
            }
        }

        while true {
            let duplicates = duplicateBindings(in: proposed)
            guard !duplicates.isEmpty else { break }
            var changed = false
            for (binding, actions) in duplicates {
                for action in actions
                where proposed[action] != defaults.assignments[action] {
                    issues[action] = .conflict(binding, actions: actions)
                    proposed[action] = defaults.assignments[action]
                    changed = true
                }
            }
            precondition(changed, "内置默认快捷键必须唯一")
        }

        return (KeyBindingSet(assignments: proposed), issues)
    }

    public func replacing(
        _ action: KeyBindingAction,
        with assignment: KeyBindingAssignment
    ) -> Result<KeyBindingSet, KeyBindingValidationIssue> {
        if case .binding(let binding) = assignment,
           Self.reservedBindings.contains(binding) {
            return .failure(.reserved(binding))
        }
        var proposed = assignments
        proposed[action] = assignment
        if let duplicate = Self.duplicateBindings(in: proposed).first(where: {
            $0.value.contains(action)
        }) {
            return .failure(.conflict(duplicate.key, actions: duplicate.value))
        }
        return .success(KeyBindingSet(assignments: proposed))
    }

    private static func required(_ text: String) -> KeyBinding {
        guard let binding = KeyBinding.parse(text) else {
            preconditionFailure("无效内置快捷键：\(text)")
        }
        return binding
    }

    private static func duplicateBindings(
        in assignments: [KeyBindingAction: KeyBindingAssignment]
    ) -> [KeyBinding: [KeyBindingAction]] {
        var grouped: [KeyBinding: [KeyBindingAction]] = [:]
        for action in KeyBindingAction.allCases {
            guard case .binding(let binding) = assignments[action] else { continue }
            grouped[binding, default: []].append(action)
        }
        return grouped.filter { $0.value.count > 1 }
    }

    private static let reservedBindings: Set<KeyBinding> = {
        let values = [
            "cmd+q", "cmd+comma", "cmd+h", "cmd+alt+h", "cmd+m", "cmd+ctrl+f",
            "cmd+c", "cmd+v", "cmd+x", "cmd+a",
        ] + (1...9).map { "cmd+\($0)" }
        return Set(values.compactMap(KeyBinding.parse))
    }()
}
