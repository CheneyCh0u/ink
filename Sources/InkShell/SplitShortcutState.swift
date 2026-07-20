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

/// 把 Command-D 的按下、方向选择和松开解释成一次分屏动作。
struct SplitShortcutState {
    private enum Phase {
        case idle
        case pending
        case consumed
    }

    private var phase = Phase.idle

    var isActive: Bool { phase != .idle }

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
}
