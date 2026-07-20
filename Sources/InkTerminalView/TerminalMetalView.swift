import AppKit
import QuartzCore
import TerminalCore
import InkDesign

/// 终端内容区：CAMetalLayer 自绘。
///
/// 帧驱动是 `CADisplayLink`（macOS 14+ 的 NSView API，自动跟随窗口所在
/// 显示器的刷新率），只有脏帧才真正编码渲染——空闲时 GPU 零负载。
@MainActor
public final class TerminalMetalView: NSView, NSMenuItemValidation, @preconcurrency NSTextInputClient {

    /// 用户输入字节流（键盘编码后），外部接 PTY。
    public var onInput: ((Data) -> Void)?
    /// 格数变化（视图 resize / 换显示器）。外部据此调 PTY 与 Terminal 的尺寸。
    public var onGridResize: ((TerminalSize) -> Void)?
    /// 每帧取终端状态。用 pull 模式解耦：视图不持有会话。
    public var terminalProvider: (() -> Terminal)?
    /// 视图成为第一响应者，外壳据此更新当前 pane。
    public var onFocus: (() -> Void)?
    /// 搜索控制器按需提供结果，避免视图长期共享数组导致增量更新触发全量 CoW。
    public var searchResultsProvider: (() -> ([TerminalSearchMatch], Int?))?

    // MARK: - 配置项（外壳从 InkConfig 映射进来）

    /// 终端字号。变更即重建渲染器与 atlas。
    public var fontSize: CGFloat = 14 {
        didSet { if fontSize != oldValue { rebuildRenderer() } }
    }

    /// 等宽字体族。nil = 系统 SF Mono；名字无效静默回退。
    public var fontFamily: String? {
        didSet { if fontFamily != oldValue { rebuildRenderer() } }
    }

    /// 行高倍数（1.0 = 字体原生行高）。
    public var lineHeightMultiplier: CGFloat = 1.2 {
        didSet { if lineHeightMultiplier != oldValue { rebuildRenderer() } }
    }

    public var cursorStyle: TerminalCursorStyle = .block {
        didSet {
            renderer?.cursorStyle = cursorStyle
            markDirty()
        }
    }

    /// 关闭后光标恒亮。
    public var cursorBlinkEnabled = true {
        didSet {
            cursorOn = true
            markDirty()
        }
    }

    /// ⌥ 键作 Meta（发 ESC 前缀）还是留给系统输入重音字符。
    public var optionAsMeta = true

    /// 松开鼠标即把选区写进剪贴板。
    public var copyOnSelect = false

    private var renderer: TerminalRenderer?
    private var displayLink: CADisplayLink?
    private var dirty = true
    private var cursorOn = true
    private var lastBlinkFlip = CACurrentMediaTime()
    private var lastGridSize: TerminalSize?

    /// 当前按视图尺寸算出的格数（布局未就绪时为 nil）。
    public var currentGridSize: TerminalSize? { lastGridSize }

    /// 保证指定列数与行数完整可见所需的视图尺寸（point）。
    public func minimumViewportSize(columns: Int, rows: Int) -> CGSize {
        if let renderer {
            return renderer.viewportSize(columns: columns, rows: rows)
        }

        // 尚未进窗口时 renderer 还不存在，用同一套字体度量提前给布局提供约束。
        let scale = window?.backingScaleFactor ?? NSScreen.main?.backingScaleFactor ?? 2
        let font = fontFamily.flatMap { NSFont(name: $0, size: fontSize) }
            ?? InkDesignTokens.Typography.terminal(size: fontSize)
        let advance = ("0" as NSString).size(withAttributes: [.font: font]).width
        let cellWidth = ceil(advance * scale) / scale
        let naturalHeight = ceil(NSLayoutManager().defaultLineHeight(for: font) * scale)
        let cellHeight = ceil(naturalHeight * max(0.8, lineHeightMultiplier)) / scale
        let inset = InkDesignTokens.Spacing.sm * 2
        let pixelSafety = 1 / scale
        return CGSize(
            width: CGFloat(columns) * cellWidth + inset + pixelSafety,
            height: CGFloat(rows) * cellHeight + inset + pixelSafety
        )
    }

    // 滚动与选区。offset 单位是行，0 = 跟住底部。
    private var scrollOffset = 0
    private var scrollAccumulator: CGFloat = 0
    private var selectionAnchor: TextPosition?
    private var selection: SelectionRange?
    private var searchResults: [TerminalSearchMatch] = []
    private var currentSearchIndex: Int?

    /// 仅供搜索定位测试读取；搜索和普通滚轮共用同一个历史视口。
    var searchScrollOffset: Int { scrollOffset }

    // 输入法预编辑（拼音）。提交前只存在于视图层，不进终端。
    private var markedText = ""
    /// interpretKeyEvents 期间暂存的原始事件，doCommandBySelector 兜底编码用。
    private var pendingKeyEvent: NSEvent?

    private var metalLayer: CAMetalLayer { layer as! CAMetalLayer }

    /// 鼠标命中要 y 朝下，与网格行序一致。
    public override var isFlipped: Bool { true }

    public override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("代码构建，不支持 nib")
    }

    public override func makeBackingLayer() -> CALayer {
        let layer = CAMetalLayer()
        layer.pixelFormat = .bgra8Unorm
        layer.framebufferOnly = true
        // 全窗口 drawable 一块 ~16MB（2.5K@2x），默认三块。脏帧驱动下
        // 两块够用，省一块的常驻。
        layer.maximumDrawableCount = 2
        return layer
    }

    /// 切换会话时清掉视图侧的瞬态（滚动位置、选区、预编辑）。
    /// 这些状态属于"这块玻璃"而不是会话，切走就没有意义了。
    public func resetTransientState() {
        scrollOffset = 0
        scrollAccumulator = 0
        selection = nil
        selectionAnchor = nil
        markedText = ""
        searchResults.removeAll(keepingCapacity: false)
        currentSearchIndex = nil
        searchResultsProvider = nil
        markDirty()
    }

    /// 更新当前 pane 的搜索结果，不改变终端视图尺寸与 PTY grid。
    public func setSearchResults(_ results: [TerminalSearchMatch], currentIndex: Int?) {
        searchResults = results
        if let currentIndex, results.indices.contains(currentIndex) {
            currentSearchIndex = currentIndex
        } else {
            currentSearchIndex = nil
        }
        markDirty()
    }

    /// 把指定结果滚到视口中部；靠近历史首尾时自然贴边。
    public func revealSearchResult(_ result: TerminalSearchMatch) {
        guard let terminal = terminalProvider?() else { return }
        let range = result.range.normalized
        let middleLine = (range.start.line + range.end.line) / 2
        let rows = terminal.grid.size.rows
        let desiredStart = middleLine - rows / 2
        scrollOffset = max(0, min(
            terminal.scrollback.count - desiredStart,
            terminal.scrollback.count
        ))
        markDirty()
    }

    public func clearSearchResults() {
        searchResults.removeAll(keepingCapacity: false)
        currentSearchIndex = nil
        markDirty()
    }

    /// 当前历史视口覆盖的绝对行范围，供首次搜索选择最近结果。
    public func searchViewportLineRange(in terminal: Terminal) -> ClosedRange<Int> {
        let offset = min(scrollOffset, terminal.scrollback.count)
        let first = terminal.scrollback.count - offset
        let last = min(terminal.totalLines - 1, first + terminal.grid.size.rows - 1)
        return first...max(first, last)
    }

    public func markDirty() {
        dirty = true
        // 有输出时让光标立即实心，观感跟系统终端一致。
        cursorOn = true
        lastBlinkFlip = CACurrentMediaTime()
    }

    // MARK: - 生命周期

    public override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        guard window != nil else {
            displayLink?.invalidate()
            displayLink = nil
            return
        }
        rebuildRenderer()
        if displayLink == nil {
            let link = displayLink(target: self, selector: #selector(frameTick))
            link.add(to: .main, forMode: .common)
            displayLink = link
        }
    }

    public override func viewDidChangeBackingProperties() {
        super.viewDidChangeBackingProperties()
        rebuildRenderer() // 换显示器缩放率变了：atlas 里的像素全部作废，重建
    }

    public override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        renderer?.apply(palette: .current(for: effectiveAppearance))
        dirty = true
    }

    public override func layout() {
        super.layout()
        updateDrawableSize()
    }

    private func rebuildRenderer() {
        guard let window else { return }
        let scale = window.backingScaleFactor
        let font = fontFamily.flatMap { NSFont(name: $0, size: fontSize) }
            ?? InkDesignTokens.Typography.terminal(size: fontSize)
        guard let renderer = TerminalRenderer(
            font: font, scale: scale, lineHeightMultiplier: lineHeightMultiplier
        ) else { return }
        renderer.cursorStyle = cursorStyle
        renderer.apply(palette: .current(for: effectiveAppearance))
        self.renderer = renderer
        metalLayer.device = renderer.device
        lastGridSize = nil
        updateDrawableSize()
        dirty = true
    }

    private func updateDrawableSize() {
        guard let window, let renderer else { return }
        let scale = window.backingScaleFactor
        let pixelSize = CGSize(width: bounds.width * scale, height: bounds.height * scale)
        guard pixelSize.width > 0, pixelSize.height > 0 else { return }
        metalLayer.contentsScale = scale
        metalLayer.drawableSize = pixelSize

        let gridSize = renderer.gridSize(forPixelSize: pixelSize)
        if gridSize != lastGridSize {
            lastGridSize = gridSize
            onGridResize?(gridSize)
        }
        dirty = true
    }

    // MARK: - 帧循环

    @objc private func frameTick() {
        // 光标闪烁：600ms 翻转。除此之外没有脏数据就直接跳过，GPU 不动。
        let now = CACurrentMediaTime()
        if cursorBlinkEnabled, now - lastBlinkFlip > 0.6 {
            cursorOn.toggle()
            lastBlinkFlip = now
            dirty = true
        }
        guard dirty, let renderer, let terminal = terminalProvider?() else { return }
        dirty = false
        scrollOffset = min(scrollOffset, terminal.scrollback.count)
        let providedSearch = searchResultsProvider?()
        let visibleSearchResults = providedSearch?.0 ?? searchResults
        let visibleCurrentIndex = providedSearch?.1 ?? currentSearchIndex
        let searchHighlights = TerminalSearchHighlights.project(
            matches: visibleSearchResults,
            currentIndex: visibleCurrentIndex,
            scrollbackCount: terminal.scrollback.count,
            gridRows: terminal.grid.size.rows,
            scrollOffset: scrollOffset,
            columns: terminal.grid.size.columns
        )
        renderer.render(
            terminal: terminal, into: metalLayer, cursorOn: cursorOn,
            scrollOffset: scrollOffset, selection: selection,
            searchHighlights: searchHighlights,
            preedit: markedText.isEmpty ? nil : markedText
        )
    }

    // MARK: - 滚动

    public override func scrollWheel(with event: NSEvent) {
        guard let renderer, let terminal = terminalProvider?() else { return }

        scrollAccumulator += event.scrollingDeltaY
        let cellH = renderer.cellSizePoints.height
        let deltaRows = Int(scrollAccumulator / cellH)
        guard deltaRows != 0 else { return }
        scrollAccumulator -= CGFloat(deltaRows) * cellH

        // 应用要了鼠标：滚轮直接上报（vim 里滚轮滚文档）。
        if terminal.modes.mouseMode != .none, !event.modifierFlags.contains(.option) {
            reportWheel(rows: deltaRows, event: event, terminal: terminal)
            return
        }
        // 备用屏没有 scrollback：滚轮转方向键（less / man 直接能滚）。
        if terminal.modes.alternateScreen {
            if terminal.modes.alternateScroll {
                let key = deltaRows > 0 ? "\u{1B}OA" : "\u{1B}OB"
                let arrows = terminal.modes.applicationCursorKeys
                    ? key
                    : (deltaRows > 0 ? "\u{1B}[A" : "\u{1B}[B")
                for _ in 0..<abs(deltaRows) { onInput?(Data(arrows.utf8)) }
            }
            return
        }

        let target = scrollOffset + deltaRows // 向上滚 delta 为正，翻历史
        scrollOffset = max(0, min(target, terminal.scrollback.count))
        markDirty()
    }

    private func reportWheel(rows: Int, event: NSEvent, terminal: Terminal) {
        guard let cell = hitCell(event, terminal: terminal) else { return }
        let action: KeyEncoder.MouseAction = rows > 0 ? .wheelUp : .wheelDown
        for _ in 0..<abs(rows) {
            onInput?(KeyEncoder.encodeMouse(
                action: action, button: 0,
                column: cell.col + 1, row: cell.row + 1,
                flags: event.modifierFlags, sgr: terminal.modes.sgrMouse
            ))
        }
    }

    /// 命中屏上格（0 基），鼠标上报用（与选区的绝对行坐标不同）。
    private func hitCell(_ event: NSEvent, terminal: Terminal) -> (row: Int, col: Int)? {
        guard let renderer else { return nil }
        let point = convert(event.locationInWindow, from: nil)
        let cell = renderer.cellSizePoints
        let inset = InkDesignTokens.Spacing.sm
        return (
            row: max(0, min(Int((point.y - inset) / cell.height), terminal.grid.size.rows - 1)),
            col: max(0, min(Int((point.x - inset) / cell.width), terminal.grid.size.columns - 1))
        )
    }

    /// 尝试把鼠标事件上报给应用。返回 true 表示已消费（不再做本地选区）。
    /// 按住 Option 强制走本地选区——在 vim 里也能选中复制，跟 iTerm2 一致。
    private func reportMouse(
        _ event: NSEvent, action: KeyEncoder.MouseAction, button: Int
    ) -> Bool {
        guard let terminal = terminalProvider?(),
              terminal.modes.mouseMode != .none,
              !event.modifierFlags.contains(.option),
              let cell = hitCell(event, terminal: terminal)
        else { return false }
        if action == .drag, terminal.modes.mouseMode == .click { return true } // 级别不够，吞掉
        onInput?(KeyEncoder.encodeMouse(
            action: action, button: button,
            column: cell.col + 1, row: cell.row + 1,
            flags: event.modifierFlags, sgr: terminal.modes.sgrMouse
        ))
        return true
    }

    // MARK: - 选区

    private func hitPosition(_ event: NSEvent) -> TextPosition? {
        guard let renderer, let terminal = terminalProvider?() else { return nil }
        let point = convert(event.locationInWindow, from: nil)
        let cell = renderer.cellSizePoints
        let inset = InkDesignTokens.Spacing.sm
        let col = Int((point.x - inset) / cell.width)
        let visualRow = Int((point.y - inset) / cell.height)
        let cols = terminal.grid.size.columns
        let rows = terminal.grid.size.rows
        let absLine = terminal.scrollback.count - min(scrollOffset, terminal.scrollback.count)
            + max(0, min(visualRow, rows - 1))
        return TextPosition(
            line: max(0, min(absLine, terminal.totalLines - 1)),
            column: max(0, min(col, cols - 1))
        )
    }

    public override func mouseDown(with event: NSEvent) {
        window?.makeFirstResponder(self)
        if reportMouse(event, action: .press, button: 0) { return }
        guard let pos = hitPosition(event), let terminal = terminalProvider?() else { return }

        switch event.clickCount {
        case 2:
            if let cols = terminal.wordColumns(at: pos) {
                selection = SelectionRange(
                    start: TextPosition(line: pos.line, column: cols.lowerBound),
                    end: TextPosition(line: pos.line, column: cols.upperBound)
                )
            }
        case 3:
            selection = SelectionRange(
                start: TextPosition(line: pos.line, column: 0),
                end: TextPosition(line: pos.line, column: terminal.grid.size.columns - 1)
            )
        default:
            selectionAnchor = pos
            if selection != nil {
                selection = nil // 单击清掉旧选区
            }
        }
        markDirty()
    }

    public override func mouseDragged(with event: NSEvent) {
        if reportMouse(event, action: .drag, button: 0) { return }
        guard let anchor = selectionAnchor, let pos = hitPosition(event) else { return }
        selection = SelectionRange(
            start: anchor, end: pos,
            block: event.modifierFlags.contains(.option)
        )
        markDirty()
    }

    public override func mouseUp(with event: NSEvent) {
        if reportMouse(event, action: .release, button: 0) { return }
        selectionAnchor = nil
        if copyOnSelect, selection != nil {
            copy(nil)
        }
    }

    public override func rightMouseDown(with event: NSEvent) {
        _ = reportMouse(event, action: .press, button: 2)
    }

    public override func rightMouseUp(with event: NSEvent) {
        _ = reportMouse(event, action: .release, button: 2)
    }

    @objc public func copy(_ sender: Any?) {
        guard let selection, let terminal = terminalProvider?() else { return }
        let text = terminal.extractText(in: selection)
        guard !text.isEmpty else { return }
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(text, forType: .string)
    }


    // MARK: - 键盘输入

    public override var acceptsFirstResponder: Bool { true }

    public override func becomeFirstResponder() -> Bool {
        let accepted = super.becomeFirstResponder()
        if accepted { onFocus?() }
        return accepted
    }

    public override func keyDown(with event: NSEvent) {
        if event.modifierFlags.contains(.command) {
            super.keyDown(with: event)
            return
        }
        // 敲键即回到底部并清选区，跟系统终端一致。
        if scrollOffset != 0 || selection != nil {
            scrollOffset = 0
            selection = nil
            markDirty()
        }
        // ⌃ 组合键（⌃C 等）直发终端，不给输入法机会。
        if event.modifierFlags.contains(.control), markedText.isEmpty {
            if let data = encode(event) { onInput?(data) }
            return
        }
        // Option-as-Meta：⌥b/⌥f 这类发 ESC 前缀（shell 里跳词）。只拦普通
        // 字符键，⌥方向键留给编码器出 CSI 1;3 系列。
        if optionAsMeta, event.modifierFlags.contains(.option), markedText.isEmpty,
           let base = event.charactersIgnoringModifiers,
           let first = base.unicodeScalars.first, first.value < 0x80, first.value >= 0x20 {
            onInput?(Data("\u{1B}\(base)".utf8))
            return
        }
        // 其余全部路过输入法：中文拼音在这里被 IME 截走变成
        // setMarkedText / insertText；未被消费的走 doCommandBySelector 兜底。
        pendingKeyEvent = event
        interpretKeyEvents([event])
        pendingKeyEvent = nil
    }

    public override func doCommand(by selector: Selector) {
        // IME 未消费的按键（回车、退格、方向键…）：用暂存的原始事件
        // 按终端语义编码，不走 AppKit 的文本编辑命令。
        if let event = pendingKeyEvent, let data = encode(event) {
            onInput?(data)
        }
    }

    private func encode(_ event: NSEvent) -> Data? {
        KeyEncoder.encode(
            event: event,
            applicationCursorKeys: terminalProvider?().modes.applicationCursorKeys ?? false
        )
    }

    @objc public func paste(_ sender: Any?) {
        guard var text = NSPasteboard.general.string(forType: .string) else { return }
        if terminalProvider?().modes.bracketedPaste ?? false {
            // 剥掉内容里的结束标记，防转义注入（粘贴文本伪造 201~ 提前结束
            // 包裹，后续内容会被 shell 当按键执行——安全问题）。
            text = text.replacingOccurrences(of: "\u{1B}[201~", with: "")
            onInput?(Data("\u{1B}[200~\(text)\u{1B}[201~".utf8))
        } else {
            // 无包裹时换行转 CR：shell 行编辑器认 CR，直发 LF 会被吞。
            onInput?(Data(text.replacingOccurrences(of: "\n", with: "\r").utf8))
        }
    }

    public func validateMenuItem(_ menuItem: NSMenuItem) -> Bool {
        if menuItem.action == #selector(copy(_:)) { return selection != nil }
        return true
    }

    // MARK: - NSTextInputClient（中文输入法）

    public func insertText(_ string: Any, replacementRange: NSRange) {
        let text = Self.plainString(string)
        if !markedText.isEmpty {
            markedText = ""
            markDirty()
        }
        guard !text.isEmpty else { return }
        onInput?(Data(text.utf8))
    }

    public func setMarkedText(_ string: Any, selectedRange: NSRange, replacementRange: NSRange) {
        markedText = Self.plainString(string)
        markDirty()
    }

    public func unmarkText() {
        markedText = ""
        markDirty()
    }

    public func hasMarkedText() -> Bool { !markedText.isEmpty }

    public func markedRange() -> NSRange {
        markedText.isEmpty
            ? NSRange(location: NSNotFound, length: 0)
            : NSRange(location: 0, length: markedText.utf16.count)
    }

    public func selectedRange() -> NSRange {
        NSRange(location: markedText.utf16.count, length: 0)
    }

    public func attributedSubstring(
        forProposedRange range: NSRange, actualRange: NSRangePointer?
    ) -> NSAttributedString? { nil }

    public func validAttributesForMarkedText() -> [NSAttributedString.Key] {
        [.underlineStyle, .markedClauseSegment]
    }

    public func characterIndex(for point: NSPoint) -> Int { 0 }

    /// 候选窗定位：预编辑起点所在 cell 的屏幕矩形。
    public func firstRect(forCharacterRange range: NSRange, actualRange: NSRangePointer?) -> NSRect {
        guard let renderer, let terminal = terminalProvider?(), let window else { return .zero }
        let cell = renderer.cellSizePoints
        let inset = InkDesignTokens.Spacing.sm
        let rect = NSRect(
            x: inset + CGFloat(terminal.grid.cursorCol) * cell.width,
            y: inset + CGFloat(terminal.grid.cursorRow + 1) * cell.height,
            width: cell.width,
            height: cell.height
        )
        // isFlipped 视图：先转到窗口坐标（y 朝上），再转屏幕。
        let windowRect = convert(NSRect(
            x: rect.minX, y: rect.minY - cell.height, width: rect.width, height: rect.height
        ), to: nil)
        return window.convertToScreen(windowRect)
    }

    private static func plainString(_ string: Any) -> String {
        switch string {
        case let s as String: s
        case let a as NSAttributedString: a.string
        default: ""
        }
    }

}
