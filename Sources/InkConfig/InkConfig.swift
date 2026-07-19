import Foundation

/// ink 的用户配置。文件：`~/.config/ink/config.toml`，全部键可缺省。
///
/// ```toml
/// [font]
/// size = 14.0
///
/// [cursor]
/// style = "block"      # block | bar | underline
/// blink = true
///
/// [input]
/// option_as_meta = true
///
/// [selection]
/// copy_on_select = false
///
/// [scrollback]
/// lines = 100_000      # 改动只对新会话生效
/// ```
public struct InkConfig: Equatable, Sendable {

    public enum CursorStyle: String, Sendable {
        case block, bar, underline
    }

    public var fontSize: Double = 14
    public var cursorStyle: CursorStyle = .block
    public var cursorBlink = true
    public var optionAsMeta = true
    public var copyOnSelect = false
    public var scrollbackLines = 100_000

    public init() {}

    public static var defaultURL: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".config/ink/config.toml")
    }

    /// 读取失败（文件不存在、解析不出）一律回默认值：配置永远不该
    /// 让终端起不来。
    public static func load(from url: URL = defaultURL) -> InkConfig {
        var config = InkConfig()
        guard let text = try? String(contentsOf: url, encoding: .utf8) else {
            return config
        }
        let values = MiniTOML.parse(text)

        if let size = values.double("font.size"), (6...72).contains(size) {
            config.fontSize = size
        }
        if let style = values.string("cursor.style"), let parsed = CursorStyle(rawValue: style) {
            config.cursorStyle = parsed
        }
        if let blink = values.bool("cursor.blink") {
            config.cursorBlink = blink
        }
        if let meta = values.bool("input.option_as_meta") {
            config.optionAsMeta = meta
        }
        if let copy = values.bool("selection.copy_on_select") {
            config.copyOnSelect = copy
        }
        if let lines = values.int("scrollback.lines"), (100...2_000_000).contains(lines) {
            config.scrollbackLines = lines
        }
        return config
    }
}

/// 配置热重载：盯配置文件所在目录（编辑器多为原子写，直接盯文件
/// 会在替换后丢失 fd）。事件去抖 200ms，变化了才回调。
public final class ConfigWatcher: @unchecked Sendable {

    private let url: URL
    private let queue = DispatchQueue(label: "ink.config-watch")
    private var source: DispatchSourceFileSystemObject?
    private var directoryFD: Int32 = -1
    private var pending: DispatchWorkItem?
    private var lastConfig: InkConfig

    /// 配置变化回调，主线程。
    private let onChange: @MainActor @Sendable (InkConfig) -> Void

    public init(
        url: URL = InkConfig.defaultURL,
        onChange: @escaping @MainActor @Sendable (InkConfig) -> Void
    ) {
        self.url = url
        self.lastConfig = InkConfig.load(from: url)
        self.onChange = onChange
        start()
    }

    deinit {
        source?.cancel()
        if directoryFD >= 0 { close(directoryFD) }
    }

    private func start() {
        let dir = url.deletingLastPathComponent()
        // 目录可能还不存在（用户从未建配置），建好目录再盯。
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        directoryFD = open(dir.path, O_EVTONLY)
        guard directoryFD >= 0 else { return }

        let source = DispatchSource.makeFileSystemObjectSource(
            fileDescriptor: directoryFD,
            eventMask: [.write, .rename, .extend],
            queue: queue
        )
        source.setEventHandler { [weak self] in
            self?.scheduleReload()
        }
        source.activate()
        self.source = source
    }

    private func scheduleReload() {
        pending?.cancel()
        let work = DispatchWorkItem { [weak self] in
            guard let self else { return }
            let fresh = InkConfig.load(from: self.url)
            guard fresh != self.lastConfig else { return }
            self.lastConfig = fresh
            let handler = self.onChange
            Task { @MainActor in handler(fresh) }
        }
        pending = work
        queue.asyncAfter(deadline: .now() + 0.2, execute: work)
    }
}
