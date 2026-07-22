import AppKit
import Foundation
import InkDesign
import TerminalCore

enum TabAttention: Sendable, Equatable {
    case completed(CommandCompletion)
    case bell
    case failed(CommandCompletion)

    init(event: TerminalEvent) {
        switch event {
        case .bell, .notification:
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

@MainActor
struct AttentionPresentation {
    let symbolName: String
    let accessibilityLabel: String
    let toolTip: String
    let tintColor: NSColor
}

@MainActor
extension TabAttention {
    var presentation: AttentionPresentation {
        switch self {
        case let .failed(completion):
            let status = completion.exitStatus.map { "，退出状态 \($0)" } ?? ""
            let duration = CommandStatusFormatter.duration(completion.duration)
            return AttentionPresentation(
                symbolName: "exclamationmark.circle.fill",
                accessibilityLabel: "命令失败\(status)，\(duration)",
                toolTip: "命令失败\(status) · \(duration)",
                tintColor: InkDesignTokens.Color.danger
            )
        case .bell:
            return AttentionPresentation(
                symbolName: "bell.fill",
                accessibilityLabel: "终端响铃",
                toolTip: "终端响铃",
                tintColor: InkDesignTokens.Color.warning
            )
        case let .completed(completion):
            let duration = CommandStatusFormatter.duration(completion.duration)
            return AttentionPresentation(
                symbolName: "circle.fill",
                accessibilityLabel: "命令已完成，\(duration)",
                toolTip: "命令已完成 · \(duration)",
                tintColor: InkDesignTokens.Color.success
            )
        }
    }
}
