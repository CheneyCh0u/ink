import Darwin
import Dispatch
import Foundation

/// 一个 PTY 会话：`forkpty` 启动登录 shell，Dispatch 源驱动读端。
///
/// 线程模型：所有 I/O 在内部串行队列上进行，对外回调固定切回主线程。
/// 约定：两个回调必须在 `start()` 之前设置、之后不再改动；`start()` 只在
/// 主线程调用一次。靠这两条约定省掉锁——`@unchecked Sendable` 的依据在此。
public final class PTYSession: @unchecked Sendable {

    /// 子进程输出（原始字节，未做任何解析）。主线程回调。
    public var onOutput: (@MainActor @Sendable (Data) -> Void)?

    /// 子进程退出，参数是 `waitpid` 的 status。主线程回调。
    public var onExit: (@MainActor @Sendable (Int32) -> Void)?

    public struct SpawnError: Error {
        public let message: String
    }

    private let queue = DispatchQueue(label: "ink.pty")
    private var masterFD: Int32 = -1
    private var childPID: pid_t = -1
    private var readSource: DispatchSourceRead?
    private var exitSource: DispatchSourceProcess?

    /// `TIOCSWINSZ` 是带参宏，Swift 导入不了，按 Darwin 的 `_IOW('t', 103, winsize)` 展开写死。
    private static let ioctlSetWinsize: UInt = 0x8008_7467

    public init() {}

    deinit {
        shutdown()
    }

    // MARK: - 生命周期

    /// 启动登录 shell。与 Terminal.app / Ghostty 一致，经 `/usr/bin/login`
    /// 启动：注册 utmpx（`w`/`who` 可见）并打印 "Last login" 横幅。
    ///
    /// 旗标组合是实验验证过的：`-f` 免认证、`-p` 保留环境、`-l` 不 chdir
    /// 回家目录（项目会话要留在项目目录）。`-l` 同时会去掉 argv[0] 的
    /// 前导 `-`，登录语义用 shell 自己的 `-l` 参数补回（zsh/bash/fish 通用），
    /// `.zprofile` 照常生效。
    public func start(columns: Int, rows: Int, workingDirectory: String? = nil) throws {
        precondition(masterFD < 0, "PTYSession 只能 start 一次")

        let shellPath = ProcessInfo.processInfo.environment["SHELL"] ?? "/bin/zsh"
        let userName = NSUserName()

        // fork 之后到 exec 之间只能调 async-signal-safe 函数，Swift 运行时的
        // 分配都不行。所以 argv / envp 全部在 fork 之前备成 C 缓冲。
        var environment = ProcessInfo.processInfo.environment
        environment["TERM"] = "xterm-256color"
        environment["COLORTERM"] = "truecolor"
        environment["TERM_PROGRAM"] = "ink"
        if environment["LANG"] == nil {
            environment["LANG"] = "zh_CN.UTF-8"
        }

        let cShell = strdup("/usr/bin/login")
        let loginArgs = ["login", "-fpl", userName, shellPath, "-l"]
        let cArgv = UnsafeMutablePointer<UnsafeMutablePointer<CChar>?>.allocate(capacity: loginArgs.count + 1)
        for (i, arg) in loginArgs.enumerated() {
            cArgv[i] = strdup(arg)
        }
        cArgv[loginArgs.count] = nil

        let envPairs = environment.map { "\($0.key)=\($0.value)" }
        let cEnvp = UnsafeMutablePointer<UnsafeMutablePointer<CChar>?>.allocate(capacity: envPairs.count + 1)
        for (i, pair) in envPairs.enumerated() {
            cEnvp[i] = strdup(pair)
        }
        cEnvp[envPairs.count] = nil

        let cCwd = workingDirectory.map { strdup($0) }

        defer {
            free(cShell)
            for i in 0..<loginArgs.count { free(cArgv[i]) }
            cArgv.deallocate()
            for i in 0...envPairs.count { free(cEnvp[i]) }
            cEnvp.deallocate()
            if let cCwd { free(cCwd) }
        }

        var size = winsize(
            ws_row: UInt16(clamping: rows),
            ws_col: UInt16(clamping: columns),
            ws_xpixel: 0,
            ws_ypixel: 0
        )

        var master: Int32 = -1
        let pid = forkpty(&master, nil, nil, &size)
        switch pid {
        case -1:
            throw SpawnError(message: "forkpty 失败：errno \(errno)")
        case 0:
            // 子进程。此处起只允许 async-signal-safe 调用（chdir 在列）。
            if let cCwd {
                chdir(cCwd)
            }
            execve(cShell, cArgv, cEnvp)
            _exit(127)
        default:
            masterFD = master
            childPID = pid
            startReadSource()
            startExitSource()
        }
    }

    /// 主动结束会话：给子进程发 SIGHUP（等价于挂断终端），随后由退出源收尸。
    public func terminate() {
        if childPID > 0 {
            kill(childPID, SIGHUP)
        }
    }

    /// PTY 前台进程组组长的进程名（"zsh"、"vim"…），标签标题用。
    /// tcgetpgrp + sysctl 两次系统调用，无需 shell 配合。
    public func foregroundProcessName() -> String? {
        guard masterFD >= 0 else { return nil }
        let pgid = tcgetpgrp(masterFD)
        guard pgid > 0 else { return nil }
        var mib: [Int32] = [CTL_KERN, KERN_PROC, KERN_PROC_PID, pgid]
        var info = kinfo_proc()
        var size = MemoryLayout<kinfo_proc>.stride
        guard sysctl(&mib, 4, &info, &size, nil, 0) == 0, size > 0 else { return nil }
        return withUnsafeBytes(of: info.kp_proc.p_comm) { raw in
            guard let base = raw.bindMemory(to: CChar.self).baseAddress else { return nil }
            return String(cString: base)
        }
    }

    /// PTY 前台进程组组长的工作目录。只在创建分屏时查询一次，失败静默返回 nil。
    public func foregroundWorkingDirectory() -> String? {
        guard masterFD >= 0 else { return nil }
        let pgid = tcgetpgrp(masterFD)
        guard pgid > 0 else { return nil }

        var info = proc_vnodepathinfo()
        let expectedSize = MemoryLayout<proc_vnodepathinfo>.stride
        let actualSize = withUnsafeMutablePointer(to: &info) {
            proc_pidinfo(pgid, PROC_PIDVNODEPATHINFO, 0, $0, Int32(expectedSize))
        }
        guard actualSize == Int32(expectedSize) else { return nil }

        let path = withUnsafePointer(to: &info.pvi_cdir.vip_path) { pathPointer in
            pathPointer.withMemoryRebound(to: CChar.self, capacity: Int(MAXPATHLEN)) {
                String(cString: $0)
            }
        }
        guard !path.isEmpty else { return nil }
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: path, isDirectory: &isDirectory),
              isDirectory.boolValue else { return nil }
        return path
    }

    // MARK: - I/O

    /// 写入用户输入。小数据量场景（键盘输入），入队即可，不做写缓冲。
    /// 大粘贴的背压处理是后续任务，见 roadmap「PTY 与进程」。
    public func write(_ data: Data) {
        queue.async { [self] in
            guard masterFD >= 0 else { return }
            data.withUnsafeBytes { (raw: UnsafeRawBufferPointer) in
                var offset = 0
                while offset < raw.count {
                    let n = Darwin.write(masterFD, raw.baseAddress! + offset, raw.count - offset)
                    if n <= 0 {
                        if errno == EINTR { continue }
                        return
                    }
                    offset += n
                }
            }
        }
    }

    /// 同步窗口尺寸。内核会顺带给前台进程组发 SIGWINCH，vim 因此立刻重排。
    public func resize(columns: Int, rows: Int) {
        queue.async { [self] in
            guard masterFD >= 0 else { return }
            var size = winsize(
                ws_row: UInt16(clamping: rows),
                ws_col: UInt16(clamping: columns),
                ws_xpixel: 0,
                ws_ypixel: 0
            )
            _ = withUnsafeMutablePointer(to: &size) {
                ioctl(masterFD, Self.ioctlSetWinsize, $0)
            }
        }
    }

    // MARK: - 内部

    private func startReadSource() {
        let source = DispatchSource.makeReadSource(fileDescriptor: masterFD, queue: queue)
        source.setEventHandler { [weak self] in
            self?.drainOutput()
        }
        source.activate()
        readSource = source
    }

    private func startExitSource() {
        let source = DispatchSource.makeProcessSource(identifier: childPID, eventMask: .exit, queue: queue)
        source.setEventHandler { [weak self] in
            guard let self else { return }
            var status: Int32 = 0
            // 收尸，避免僵尸进程。
            waitpid(self.childPID, &status, WNOHANG)
            self.childPID = -1
            self.closeMaster()
            if let handler = self.onExit {
                Task { @MainActor in handler(status) }
            }
        }
        source.activate()
        exitSource = source
    }

    private func drainOutput() {
        guard masterFD >= 0 else { return }
        var buffer = [UInt8](repeating: 0, count: 64 * 1024)
        let n = read(masterFD, &buffer, buffer.count)
        if n > 0 {
            let data = Data(bytes: buffer, count: n)
            if let handler = onOutput {
                Task { @MainActor in handler(data) }
            }
        } else if n == 0 || errno == EIO {
            // EOF / EIO：slave 端全部关闭（shell 退了）。退出回调交给 exitSource。
            closeMaster()
        }
    }

    private func closeMaster() {
        readSource?.cancel()
        readSource = nil
        if masterFD >= 0 {
            close(masterFD)
            masterFD = -1
        }
    }

    private func shutdown() {
        terminate()
        exitSource?.cancel()
        exitSource = nil
        closeMaster()
    }
}
