import Foundation
import TerminalCore

enum TabAttention: Sendable, Equatable {
    case completed(CommandCompletion)
    case bell
    case failed(CommandCompletion)

    init(event: TerminalEvent) {
        switch event {
        case .bell:
            self = .bell
        case let .commandCompleted(completion):
            if let exitStatus = completion.exitStatus, exitStatus != 0 {
                self = .failed(completion)
            } else {
                self = .completed(completion)
            }
        }
    }

    var priority: Int {
        switch self {
        case .completed: 0
        case .bell: 1
        case .failed: 2
        }
    }

    func merging(_ newer: TabAttention) -> TabAttention {
        newer.priority >= priority ? newer : self
    }
}

enum CommandStatusFormatter {
    static func duration(_ duration: Duration) -> String {
        let seconds = max(0, duration.components.seconds)
        if seconds < 1 { return "<1 秒" }
        if seconds < 60 { return "\(seconds) 秒" }
        return "\(seconds / 60) 分 \(String(format: "%02d", seconds % 60)) 秒"
    }
}
