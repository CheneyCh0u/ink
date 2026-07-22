public struct CommandCompletion: Sendable, Equatable {
    public let exitStatus: UInt8?
    public let duration: Duration

    public init(exitStatus: UInt8?, duration: Duration) {
        self.exitStatus = exitStatus
        self.duration = duration
    }
}

/// 终端程序通过 OSC 请求显示的通知内容。
///
/// 构造只由 `Terminal` 在完成协议校验后进行；Shell 只消费纯值，不接触原始字节。
public struct TerminalNotification: Sendable, Equatable {
    public let title: String?
    public let body: String

    public init(title: String?, body: String) {
        self.title = title
        self.body = body
    }
}

public enum TerminalEvent: Sendable, Equatable {
    case commandCompleted(CommandCompletion)
    case notification(TerminalNotification)
    case bell
}

struct CommandCompletionRecord: Sendable, Equatable {
    private static let hasExitStatus: UInt8 = 1

    let lineID: UInt64
    let elapsedMilliseconds: UInt32
    let column: UInt16
    private let storedExitStatus: UInt8
    private let flags: UInt8

    init(lineID: UInt64, column: Int, completion: CommandCompletion) {
        self.lineID = lineID
        self.elapsedMilliseconds = UInt32(clamping: completion.duration.wholeMilliseconds)
        self.column = UInt16(clamping: column)
        self.storedExitStatus = completion.exitStatus ?? 0
        self.flags = completion.exitStatus == nil ? 0 : Self.hasExitStatus
    }

    var completion: CommandCompletion {
        CommandCompletion(
            exitStatus: flags & Self.hasExitStatus == 0 ? nil : storedExitStatus,
            duration: .milliseconds(Int64(elapsedMilliseconds))
        )
    }
}

private extension Duration {
    var wholeMilliseconds: Int64 {
        let components = components
        let seconds = components.seconds.multipliedReportingOverflow(by: 1_000)
        if seconds.overflow { return Int64.max }
        let milliseconds = components.attoseconds / 1_000_000_000_000_000
        let total = seconds.partialValue.addingReportingOverflow(milliseconds)
        return total.overflow ? Int64.max : max(0, total.partialValue)
    }
}
