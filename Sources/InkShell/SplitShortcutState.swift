enum SplitShortcutEvent: Equatable {
    case commandDDown(isRepeat: Bool)
    case direction(PaneSplitDirection)
    case dUp
    case cancel
}

enum SplitShortcutDecision: Equatable {
    case passThrough
    case consume
    case split(PaneSplitDirection)
}

/// 与 AppKit 解耦的物理按键事件，便于覆盖完整的按下和松开顺序。
enum SplitShortcutKeyEvent: Equatable {
    case keyDown(keyCode: UInt16, isRepeat: Bool, binding: KeyBinding?)
    case keyUp(keyCode: UInt16)
    case flagsChanged(modifiers: KeyBindingModifiers)
    case contextLost
}

/// 把 Command-D 的按下、方向选择和松开解释成一次分屏动作。
struct SplitShortcutState {
    private enum Phase {
        case idle
        case pending
        case consumed
    }

    private var phase = Phase.idle
    private var prefix: KeyBinding?
    private var pendingKeyCode: UInt16?

    init(prefix: KeyBinding? = KeyBindingSet.defaults.binding(for: .splitPrefix)) {
        self.prefix = prefix
    }

    mutating func updatePrefix(_ prefix: KeyBinding?) {
        self.prefix = prefix
        phase = .idle
        pendingKeyCode = nil
    }

    mutating func handleKeyEvent(_ event: SplitShortcutKeyEvent) -> SplitShortcutDecision {
        switch event {
        case .contextLost:
            return handle(.cancel)
        case let .flagsChanged(modifiers):
            guard let prefix else { return handle(.cancel) }
            return modifiers == prefix.modifiers ? .passThrough : handle(.cancel)
        case let .keyUp(keyCode):
            guard keyCode == pendingKeyCode else { return .passThrough }
            pendingKeyCode = nil
            return handle(.dUp)
        case let .keyDown(keyCode, isRepeat, binding):
            guard let prefix else { return .passThrough }
            if binding == prefix {
                pendingKeyCode = keyCode
                return handle(.commandDDown(isRepeat: isRepeat))
            }
            guard phase != .idle,
                  let binding,
                  binding.modifiers == prefix.modifiers,
                  let direction = Self.direction(for: keyCode) else {
                return .passThrough
            }
            return handle(.direction(direction))
        }
    }

    mutating func handle(_ event: SplitShortcutEvent) -> SplitShortcutDecision {
        if event == .cancel {
            phase = .idle
            pendingKeyCode = nil
            return .passThrough
        }

        switch (phase, event) {
        case (.idle, .commandDDown(isRepeat: false)):
            phase = .pending
            return .consume
        case (.pending, .commandDDown), (.consumed, .commandDDown):
            return .consume
        case let (.pending, .direction(direction)):
            phase = .consumed
            return .split(direction)
        case (.consumed, .direction):
            return .consume
        case (.pending, .dUp):
            phase = .idle
            return .split(.right)
        case (.consumed, .dUp):
            phase = .idle
            return .consume
        default:
            return .passThrough
        }
    }

    private static func direction(for keyCode: UInt16) -> PaneSplitDirection? {
        switch keyCode {
        case 123: .left
        case 124: .right
        case 125: .down
        case 126: .up
        default: nil
        }
    }
}
import InkConfig
