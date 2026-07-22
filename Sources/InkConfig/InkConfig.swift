import Foundation

/// ink 的用户配置。文件：`~/.config/ink/config.toml`，全部键可缺省。
///
/// ```toml
/// [font]
/// family = "Maple Mono NF CN"  # 空字符串用系统 SF Mono
/// size = 15
/// line_height = 1
/// adjust_cell_height = 1
/// thicken = true
/// thicken_strength = 128
///
/// [terminal]
/// theme = "neutral"     # warm | graphite | pine | plum | neutral
///
/// [appearance]
/// mode = "system"       # system | light | dark
///
/// [sidebar]
/// startup_mode = "expanded"  # expanded | compact | hidden
///
/// [window]
/// remember_frame = true
/// width = 1280
/// height = 800
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
/// [clipboard]
/// osc52_write = true
///
/// [scrollback]
/// lines = 100_000      # 改动只对新会话生效
///
/// [keybindings]
/// new_tab = "cmd+t"
/// split_prefix = "cmd+d"
/// focus_left = "cmd+alt+left"
/// split_left = ""      # 空字符串禁用
/// ```
public struct InkConfig: Equatable, Sendable {

    public static let defaultFontSize = 15.0
    public static let fontSizeRange = 6.0...72.0

    public enum AppearanceMode: String, CaseIterable, Sendable {
        case system, light, dark
    }

    public enum SidebarMode: String, CaseIterable, Sendable {
        case expanded, compact, hidden
    }

    public enum CursorStyle: String, CaseIterable, Sendable {
        case block, bar, underline
    }

    public enum TerminalTheme: String, CaseIterable, Sendable {
        case warm, graphite, pine, plum, neutral
    }

    public var appearanceMode: AppearanceMode = .system
    public var startupSidebarMode: SidebarMode = .expanded
    public var rememberWindowFrame = true
    public var windowWidth = 1280
    public var windowHeight = 800
    /// 等宽字体族名。nil = 系统 SF Mono。字体不存在时静默回退系统字体。
    public var fontFamily: String? = "Maple Mono NF CN"
    public var fontSize = InkConfig.defaultFontSize
    public var lineHeight: Double = 1
    public var fontCellHeightAdjustment = 1
    public var fontThicken = true
    public var fontThickenStrength = 128
    /// 终端配色家族；浅色或深色变体跟随界面外观。
    public var terminalTheme: TerminalTheme = .neutral
    public var cursorStyle: CursorStyle = .block
    public var cursorBlink = true
    public var optionAsMeta = true
    public var copyOnSelect = false
    /// 是否允许终端程序通过 OSC 52 写入本机剪贴板（只写，不能读取）。
    public var osc52WriteEnabled = true
    public var scrollbackLines = 100_000
    public private(set) var keyBindings: KeyBindingSet = .defaults
    public private(set) var keyBindingIssues: [KeyBindingAction: KeyBindingValidationIssue] = [:]

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

        if let mode = values.string("appearance.mode"),
           let parsed = AppearanceMode(rawValue: mode) {
            config.appearanceMode = parsed
        }
        if let mode = values.string("sidebar.startup_mode"),
           let parsed = SidebarMode(rawValue: mode) {
            config.startupSidebarMode = parsed
        }
        if let remember = values.bool("window.remember_frame") {
            config.rememberWindowFrame = remember
        }
        if let width = values.int("window.width"), (640...4096).contains(width) {
            config.windowWidth = width
        }
        if let height = values.int("window.height"), (400...2160).contains(height) {
            config.windowHeight = height
        }
        if let family = values.string("font.family") {
            config.fontFamily = family.isEmpty ? nil : family
        }
        if let size = values.double("font.size"), Self.fontSizeRange.contains(size) {
            config.fontSize = size
        }
        if let lh = values.double("font.line_height"), (0.8...2.0).contains(lh) {
            config.lineHeight = lh
        }
        if let adjustment = values.int("font.adjust_cell_height"),
           (-10...20).contains(adjustment) {
            config.fontCellHeightAdjustment = adjustment
        }
        if let thicken = values.bool("font.thicken") {
            config.fontThicken = thicken
        }
        if let strength = values.int("font.thicken_strength"),
           (0...255).contains(strength) {
            config.fontThickenStrength = strength
        }
        if let theme = values.string("terminal.theme"),
           let parsed = TerminalTheme(rawValue: theme) {
            config.terminalTheme = parsed
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
        if let osc52Write = values.bool("clipboard.osc52_write") {
            config.osc52WriteEnabled = osc52Write
        }
        if let lines = values.int("scrollback.lines"), (100...2_000_000).contains(lines) {
            config.scrollbackLines = lines
        }
        var rawKeyBindings: [String: String] = [:]
        for action in KeyBindingAction.allCases {
            if let value = values.string("keybindings.\(action.rawValue)") {
                rawKeyBindings[action.rawValue] = value
            }
        }
        config.applyKeyBindingValues(rawKeyBindings)
        return config
    }

    @discardableResult
    public mutating func setKeyBinding(
        _ assignment: KeyBindingAssignment,
        for action: KeyBindingAction
    ) -> Result<Void, KeyBindingValidationIssue> {
        switch keyBindings.replacing(action, with: assignment) {
        case .success(let updated):
            keyBindings = updated
            keyBindingIssues.removeValue(forKey: action)
            return .success(())
        case .failure(let issue):
            keyBindingIssues[action] = issue
            return .failure(issue)
        }
    }

    public mutating func resetKeyBindings() {
        keyBindings = .defaults
        keyBindingIssues.removeAll(keepingCapacity: false)
    }

    mutating func applyKeyBindingValues(_ raw: [String: String]) {
        let resolved = KeyBindingSet.resolving(raw)
        keyBindings = resolved.bindings
        keyBindingIssues = resolved.issues
    }

    /// 原子写回已知设置。原文件中的注释、空行、未知 section 和未知键全部保留；
    /// 缺少的键补进对应 section，避免 UI 接管后破坏用户手写配置。
    public func save(to url: URL = defaultURL) throws {
        let original = (try? String(contentsOf: url, encoding: .utf8)) ?? ""
        let updated = MiniTOML.updating(original, values: tomlValues)
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try updated.write(to: url, atomically: true, encoding: .utf8)
    }

    private var tomlValues: [(key: String, value: String)] {
        var values = [
            ("appearance.mode", quote(appearanceMode.rawValue)),
            ("sidebar.startup_mode", quote(startupSidebarMode.rawValue)),
            ("window.remember_frame", rememberWindowFrame ? "true" : "false"),
            ("window.width", "\(windowWidth)"),
            ("window.height", "\(windowHeight)"),
            ("font.family", quote(fontFamily ?? "")),
            ("font.size", format(fontSize)),
            ("font.line_height", format(lineHeight)),
            ("font.adjust_cell_height", "\(fontCellHeightAdjustment)"),
            ("font.thicken", fontThicken ? "true" : "false"),
            ("font.thicken_strength", "\(fontThickenStrength)"),
            ("terminal.theme", quote(terminalTheme.rawValue)),
            ("cursor.style", quote(cursorStyle.rawValue)),
            ("cursor.blink", cursorBlink ? "true" : "false"),
            ("input.option_as_meta", optionAsMeta ? "true" : "false"),
            ("selection.copy_on_select", copyOnSelect ? "true" : "false"),
            ("clipboard.osc52_write", osc52WriteEnabled ? "true" : "false"),
            ("scrollback.lines", "\(scrollbackLines)"),
        ]
        let serialized = keyBindings.serializedValues()
        for action in KeyBindingAction.allCases {
            values.append(("keybindings.\(action.rawValue)", quote(serialized[action.rawValue] ?? "")))
        }
        return values
    }

    private func quote(_ value: String) -> String {
        let escaped = value
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
            .replacingOccurrences(of: "\n", with: "\\n")
            .replacingOccurrences(of: "\t", with: "\\t")
        return "\"\(escaped)\""
    }

    private func format(_ value: Double) -> String {
        value.rounded() == value ? "\(Int(value))" : "\(value)"
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
