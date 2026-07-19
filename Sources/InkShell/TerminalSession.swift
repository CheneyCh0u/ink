import Foundation
import TerminalCore
import InkPTY

/// 一个终端会话：PTY ↔ Parser ↔ Terminal 的粘合。
///
/// Parser 的词法状态必须跨 read 边界保持，所以由会话持有；
/// Terminal 是纯值状态，视图每帧通过闭包拉取（CoW，拷的只是引用）。
@MainActor
public final class TerminalSession {

    public private(set) var terminal: Terminal
    /// 有新输出（终端状态变了），视图标脏用。
    public var onUpdate: (() -> Void)?
    /// shell 退出。
    public var onExit: ((Int32) -> Void)?

    private let pty = PTYSession()
    private var parser = Parser()
    private let workingDirectory: String?

    public init(size: TerminalSize, workingDirectory: String? = nil, scrollbackLines: Int = 100_000) {
        terminal = Terminal(size: size, scrollbackCapacity: scrollbackLines)
        self.workingDirectory = workingDirectory
    }

    public func start() throws {
        pty.onOutput = { [weak self] data in
            guard let self else { return }
            self.parser.feed(data, handler: &self.terminal)
            // DSR/DA 等查询的应答写回，TUI 探测终端在等这个。
            let responses = self.terminal.takeResponses()
            if !responses.isEmpty {
                self.pty.write(Data(responses))
            }
            self.onUpdate?()
        }
        pty.onExit = { [weak self] status in
            self?.onExit?(status)
        }
        try pty.start(
            columns: terminal.grid.size.columns,
            rows: terminal.grid.size.rows,
            workingDirectory: workingDirectory
        )
    }

    public func write(_ data: Data) {
        pty.write(data)
    }

    public func resize(to size: TerminalSize) {
        guard size != terminal.grid.size else { return }
        terminal.resize(to: size)
        pty.resize(columns: size.columns, rows: size.rows)
        onUpdate?()
    }

    public func terminate() {
        pty.terminate()
    }

    /// 前台进程名（标签标题的兜底：OSC 标题缺席时显示 zsh / vim / claude）。
    public var foregroundProcessName: String? {
        pty.foregroundProcessName()
    }

    /// 移除会话时先解除退出回调，避免 terminate 触发的回调重入列表管理。
    public func detach() {
        onExit = nil
        onUpdate = nil
    }
}
