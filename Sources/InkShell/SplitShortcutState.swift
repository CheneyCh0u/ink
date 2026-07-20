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
    case keyDown(keyCode: UInt16, isRepeat: Bool, commandDown: Bool)
    case keyUp(keyCode: UInt16)
    case flagsChanged(commandDown: Bool)
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

    mutating func handleKeyEvent(_ event: SplitShortcutKeyEvent) -> SplitShortcutDecision {
        switch event {
        case .contextLost:
            return handle(.cancel)
        case let .flagsChanged(commandDown):
            return commandDown ? .passThrough : handle(.cancel)
        case let .keyUp(keyCode):
            return keyCode == 2 ? handle(.dUp) : .passThrough
        case let .keyDown(keyCode, isRepeat, commandDown):
            guard commandDown else { return .passThrough }
            if keyCode == 2 {
                return handle(.commandDDown(isRepeat: isRepeat))
            }
            guard let direction = Self.direction(for: keyCode) else {
                return .passThrough
            }
            return handle(.direction(direction))
        }
    }

    mutating func handle(_ event: SplitShortcutEvent) -> SplitShortcutDecision {
        if event == .cancel {
            phase = .idle
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
