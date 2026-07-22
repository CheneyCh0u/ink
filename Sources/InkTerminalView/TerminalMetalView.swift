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
    /// 由外壳注入系统 URL 打开动作，视图层不依赖具体系统服务。
    public var onOpenLink: ((URL) -> Void)?
    /// 由外壳按 pane 注入的冷路径菜单动作，保持视图层不依赖 Workspace。
    public var onFind: (() -> Void)?
    public var onSplit: ((TerminalContextSplitDirection) -> Void)?
    public var onClearScrollback: (() -> Void)?
    /// 搜索控制器按需提供结果，避免视图长期共享数组导致增量更新触发全量 CoW。
    public var searchResultsProvider: (() -> ([TerminalSearchMatch], Int?))?
    /// 危险粘贴确认可替换，测试不弹真实窗口。
    var safePastePresenter: any SafePastePresenting = NSAlertSafePastePresenter()
    /// 默认按需写系统剪贴板；测试替换闭包，避免创建视图就触碰全局 AppKit 状态。
    var pasteboardWriter: (String) -> Bool = { text in
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        return pasteboard.setString(text, forType: .string)
    }
    var pasteboardReader: () -> String? = {
        NSPasteboard.general.string(forType: .string)
    }
    var contextMenuPresenter: (NSMenu, NSEvent, NSView) -> Void = {
        NSMenu.popUpContextMenu($0, with: $1, for: $2)
    }
    var commandMenuPresenter: (NSMenu, NSView, NSPoint) -> Void = { menu, view, point in
        menu.popUp(positioning: nil, at: point, in: view)
    }

    // MARK: - 配置项（外壳从 InkConfig 映射进来）

    public private(set) var fontConfiguration = TerminalFontConfiguration()

    /// 终端字号。单项调用保留原有的立即重建行为。
    public var fontSize: CGFloat {
        get { fontConfiguration.fontSize }
        set {
            var next = fontConfiguration
            next.fontSize = newValue
            apply(fontConfiguration: next)
        }
    }

    /// 等宽字体族。nil = 系统 SF Mono；名字无效静默回退。
    public var fontFamily: String? {
        get { fontConfiguration.fontFamily }
        set {
            var next = fontConfiguration
            next.fontFamily = newValue
            apply(fontConfiguration: next)
        }
    }

    /// 行高倍数（1.0 = 字体原生行高）。
    public var lineHeightMultiplier: CGFloat {
        get { fontConfiguration.lineHeightMultiplier }
        set {
            var next = fontConfiguration
            next.lineHeightMultiplier = newValue
            apply(fontConfiguration: next)
        }
    }

    /// 每个 cell 额外增加的物理像素高度。
    public var cellHeightAdjustment: Int {
        get { fontConfiguration.cellHeightAdjustment }
        set {
            var next = fontConfiguration
            next.cellHeightAdjustment = newValue
            apply(fontConfiguration: next)
        }
    }

    /// 使用 CoreGraphics 字体平滑增加单色字形的视觉字重。
    public var fontThicken: Bool {
        get { fontConfiguration.fontThicken }
        set {
            var next = fontConfiguration
            next.fontThicken = newValue
            apply(fontConfiguration: next)
        }
    }

    /// 字体增粗强度。
    public var fontThickenStrength: Int {
        get { fontConfiguration.fontThickenStrength }
        set {
            var next = fontConfiguration
            next.fontThickenStrength = newValue
            apply(fontConfiguration: next)
        }
    }

    /// 一次替换全部字体配置，变化时最多重建一次 renderer 与 atlas。
    public func apply(fontConfiguration: TerminalFontConfiguration) {
        guard fontConfiguration != self.fontConfiguration else { return }
        self.fontConfiguration = fontConfiguration
        rebuildRenderer()
    }

    /// 终端配色家族。切换时只更新 renderer 的调色板 uniform，不重建 glyph atlas。
    public var terminalTheme: InkTerminalTheme = .neutral {
        didSet {
            guard terminalTheme != oldValue else { return }
            applyCurrentPalette()
        }
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
    /// 记录重建事务边界，供回归测试确认批量字体应用没有退化为多次重建。
    private(set) var rendererRebuildAttemptCount = 0

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
        let metrics = FontGridMetrics(
            font: font,
            scale: scale,
            lineHeightMultiplier: lineHeightMultiplier,
            cellHeightAdjustment: cellHeightAdjustment
        )
        let inset = InkDesignTokens.Spacing.sm * 2
        let pixelSafety = 1 / scale
        return CGSize(
            width: CGFloat(columns) * metrics.cellWidth / scale + inset + pixelSafety,
            height: CGFloat(rows) * metrics.cellHeight / scale + inset + pixelSafety
        )
    }

    // 滚动与选区。offset 单位是行，0 = 跟住底部。
    private var scrollOffset = 0
    private var scrollAccumulator: CGFloat = 0
    private var selectionAnchor: TextPosition?
    private var selection: SelectionRange?
    private var selectionCoordinateSpace: TerminalSearchCoordinateSpace?
    private var searchResults: [TerminalSearchMatch] = []
    private var currentSearchIndex: Int?
    private var commandNavigationAnchor: (lineID: UInt64, layoutRevision: UInt64)?
    private var linkTrackingArea: NSTrackingArea?
    private var hoveredLink: TerminalLink?
    private var hoveredCell: TextPosition?
    private var hoverNeedsRefresh = true
    private var rightMouseReportsToTUI = false
    private var hoveredCommandTarget: CommandHoverTarget?
    private var commandHoverExaminedLine: Int?
    private var hoveredCommandVisualRow: Int?
    private lazy var commandHoverButton: NSButton = {
        let button = NSButton(
            image: NSImage(
                systemSymbolName: "ellipsis.circle",
                accessibilityDescription: "命令操作"
            ) ?? NSImage(),
            target: self,
            action: #selector(showCommandHoverMenu(_:))
        )
        button.identifier = NSUserInterfaceItemIdentifier("ink.command-hover")
        button.imagePosition = .imageOnly
        button.bezelStyle = .accessoryBarAction
        button.toolTip = "命令操作"
        button.setAccessibilityLabel("命令操作")
        button.isHidden = true
        addSubview(button)
        return button
    }()

    var hoveredLinkForTesting: TerminalLink? { hoveredLink }

    var commandNavigationLine: Int? {
        guard let terminal = terminalProvider?() else { return nil }
        return resolvedCommandNavigationLine(in: terminal)
    }

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
        hideCommandHover()
        scrollOffset = 0
        scrollAccumulator = 0
        clearSelection()
        selectionAnchor = nil
        markedText = ""
        searchResults.removeAll(keepingCapacity: false)
        currentSearchIndex = nil
        commandNavigationAnchor = nil
        searchResultsProvider = nil
        markDirty()
    }

    /// Core 删除历史后，所有基于旧绝对行坐标的视图瞬态必须一起失效。
    /// 搜索 provider 由 Shell 保留并以新 generation 重启，输入法预编辑不受影响。
    public func scrollbackDidClear() {
        scrollOffset = 0
        scrollAccumulator = 0
        selection = nil
        selectionAnchor = nil
        searchResults.removeAll(keepingCapacity: false)
        currentSearchIndex = nil
        commandNavigationAnchor = nil
        hoveredLink = nil
        hoveredCell = nil
        rightMouseReportsToTUI = false
        window?.invalidateCursorRects(for: self)
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

    /// 外壳开启范围搜索时读取；历史环滚动可重映射，reflow 或淘汰后返回 nil。
    public func searchSelection(in terminal: Terminal) -> SelectionRange? {
        guard let selection, let selectionCoordinateSpace else { return nil }
        return selectionCoordinateSpace.resolve(selection, in: terminal)
    }

    /// 选区创建统一经过这里捕获坐标空间；internal 便于视图层回归测试。
    func updateSelection(_ range: SelectionRange, in terminal: Terminal) {
        selection = range
        selectionCoordinateSpace = TerminalSearchCoordinateSpace(in: terminal)
    }

    private func clearSelection() {
        selection = nil
        selectionCoordinateSpace = nil
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

    /// 从当前导航锚点向前跳；首次调用从终端末尾选择最近的完整命令。
    @discardableResult
    public func navigateToPreviousCommand() -> Bool {
        guard let terminal = terminalProvider?() else { return false }
        let blocks = terminal.commandBlocks()
        if commandNavigationAnchor != nil,
           resolvedCommandNavigationLine(in: terminal) == nil {
            commandNavigationAnchor = nil
        }
        let reference = resolvedCommandNavigationLine(in: terminal) ?? terminal.totalLines
        guard let block = blocks.last(where: { $0.commandRange.start.line < reference }) else {
            return false
        }
        revealCommand(block, in: terminal)
        return true
    }

    /// 从当前导航锚点向后跳；首次调用以当前视口顶部为起点。
    @discardableResult
    public func navigateToNextCommand() -> Bool {
        guard let terminal = terminalProvider?() else { return false }
        let blocks = terminal.commandBlocks()
        if commandNavigationAnchor != nil,
           resolvedCommandNavigationLine(in: terminal) == nil {
            commandNavigationAnchor = nil
        }
        let reference = resolvedCommandNavigationLine(in: terminal)
            ?? searchViewportLineRange(in: terminal).lowerBound
        guard let block = blocks.first(where: { $0.commandRange.start.line > reference }) else {
            return false
        }
        revealCommand(block, in: terminal)
        return true
    }

    @discardableResult
    public func copyCurrentCommand() -> Bool {
        copyCommandPart(\.commandRange)
    }

    @discardableResult
    public func copyCurrentCommandOutput() -> Bool {
        guard let terminal = terminalProvider?(),
              let block = currentCommandBlock(in: terminal),
              let range = block.outputRange else { return false }
        return writeToPasteboard(terminal.extractText(in: range))
    }

    public func canCopyCommandOutput(
        containing range: SelectionRange,
        in terminal: Terminal
    ) -> Bool {
        terminal.commandOutputRange(containing: range) != nil
    }

    @discardableResult
    public func copyCommandOutput(
        containing range: SelectionRange,
        in terminal: Terminal
    ) -> Bool {
        guard let output = terminal.commandOutputRange(containing: range) else { return false }
        return writeToPasteboard(terminal.extractText(in: output))
    }

    public var hasCommandBlocks: Bool {
        !(terminalProvider?().commandBlocks().isEmpty ?? true)
    }

    private func copyCommandPart(_ keyPath: KeyPath<CommandBlock, SemanticTextRange>) -> Bool {
        guard let terminal = terminalProvider?(),
              let block = currentCommandBlock(in: terminal) else { return false }
        return writeToPasteboard(terminal.extractText(in: block[keyPath: keyPath]))
    }

    private func currentCommandBlock(in terminal: Terminal) -> CommandBlock? {
        let blocks = terminal.commandBlocks()
        if commandNavigationAnchor != nil {
            guard let line = resolvedCommandNavigationLine(in: terminal) else {
                commandNavigationAnchor = nil
                return nil
            }
            return blocks.first { $0.commandRange.start.line == line }
        }
        let viewportEnd = searchViewportLineRange(in: terminal).upperBound
        return blocks.last { $0.commandRange.start.line <= viewportEnd }
    }

    private func revealCommand(_ block: CommandBlock, in terminal: Terminal) {
        let line = block.commandRange.start.line
        let oldestLineID = terminal.scrollback.totalAppendedLines
            - UInt64(terminal.scrollback.count)
        commandNavigationAnchor = (
            lineID: oldestLineID + UInt64(line),
            layoutRevision: terminal.searchLayoutRevision
        )
        let desiredStart = line - terminal.grid.size.rows / 2
        scrollOffset = max(0, min(
            terminal.scrollback.count - desiredStart,
            terminal.scrollback.count
        ))
        clearSelection()
        markDirty()
    }

    private func resolvedCommandNavigationLine(in terminal: Terminal) -> Int? {
        guard let anchor = commandNavigationAnchor,
              anchor.layoutRevision == terminal.searchLayoutRevision else { return nil }
        let oldestLineID = terminal.scrollback.totalAppendedLines
            - UInt64(terminal.scrollback.count)
        guard anchor.lineID >= oldestLineID else { return nil }
        let line = Int(anchor.lineID - oldestLineID)
        return line < terminal.totalLines ? line : nil
    }

    private func writeToPasteboard(_ text: String) -> Bool {
        guard !text.isEmpty else { return false }
        return pasteboardWriter(text)
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
        hideCommandHover()
        dirty = true
        hoverNeedsRefresh = true
        // 有输出时让光标立即实心，观感跟系统终端一致。
        cursorOn = true
        lastBlinkFlip = CACurrentMediaTime()
    }

    // MARK: - 生命周期

    public override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        guard window != nil else {
            hideCommandHover()
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

    public override func updateTrackingAreas() {
        if let linkTrackingArea { removeTrackingArea(linkTrackingArea) }
        let trackingArea = NSTrackingArea(
            rect: .zero,
            options: [.mouseMoved, .mouseEnteredAndExited, .activeInKeyWindow, .inVisibleRect],
            owner: self,
            userInfo: nil
        )
        addTrackingArea(trackingArea)
        linkTrackingArea = trackingArea
        super.updateTrackingAreas()
    }

    public override func resetCursorRects() {
        addCursorRect(bounds, cursor: hoveredLink == nil ? .iBeam : .pointingHand)
    }

    public override func viewDidChangeBackingProperties() {
        super.viewDidChangeBackingProperties()
        rebuildRenderer() // 换显示器缩放率变了：atlas 里的像素全部作废，重建
    }

    public override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        applyCurrentPalette()
    }

    public override func layout() {
        super.layout()
        updateDrawableSize()
        if let visualRow = hoveredCommandVisualRow {
            positionCommandHoverButton(visualRow: visualRow)
        }
    }

    private func rebuildRenderer() {
        rendererRebuildAttemptCount &+= 1
        guard let window else { return }
        let scale = window.backingScaleFactor
        let font = fontFamily.flatMap { NSFont(name: $0, size: fontSize) }
            ?? InkDesignTokens.Typography.terminal(size: fontSize)
        guard let renderer = TerminalRenderer(
            font: font,
            scale: scale,
            lineHeightMultiplier: lineHeightMultiplier,
            cellHeightAdjustment: cellHeightAdjustment,
            fontThicken: fontThicken,
            fontThickenStrength: fontThickenStrength
        ) else { return }
        renderer.cursorStyle = cursorStyle
        renderer.apply(palette: terminalTheme.palette(for: effectiveAppearance))
        self.renderer = renderer
        metalLayer.device = renderer.device
        lastGridSize = nil
        updateDrawableSize()
        dirty = true
    }

    private func applyCurrentPalette() {
        renderer?.apply(palette: terminalTheme.palette(for: effectiveAppearance))
        markDirty()
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
        if hoverNeedsRefresh { refreshHoverFromWindow(terminal: terminal) }
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
            hoveredLinkRange: hoveredLink?.range,
            preedit: markedText.isEmpty ? nil : markedText
        )
    }

    // MARK: - 滚动

    public override func scrollWheel(with event: NSEvent) {
        hideCommandHover()
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
        commandNavigationAnchor = nil
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
        hitCell(at: convert(event.locationInWindow, from: nil), terminal: terminal)
    }

    private func hitCell(at point: NSPoint, terminal: Terminal) -> (row: Int, col: Int)? {
        guard let renderer else { return nil }
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
        _ event: NSEvent,
        action: KeyEncoder.MouseAction,
        button: Int,
        optionOverrides: Bool = true
    ) -> Bool {
        guard let terminal = terminalProvider?(),
              terminal.modes.mouseMode != .none,
              (!optionOverrides || !event.modifierFlags.contains(.option)),
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
        return hitPosition(
            at: convert(event.locationInWindow, from: nil),
            terminal: terminal,
            renderer: renderer
        )
    }

    private func hitPosition(
        at point: NSPoint,
        terminal: Terminal,
        renderer: TerminalRenderer,
        clampToGrid: Bool = true
    ) -> TextPosition? {
        let cell = renderer.cellSizePoints
        let inset = InkDesignTokens.Spacing.sm
        let col = Int((point.x - inset) / cell.width)
        let visualRow = Int((point.y - inset) / cell.height)
        let cols = terminal.grid.size.columns
        let rows = terminal.grid.size.rows
        if !clampToGrid {
            guard point.x >= inset,
                  point.y >= inset,
                  col >= 0, col < cols,
                  visualRow >= 0, visualRow < rows
            else { return nil }
        }
        let absLine = terminal.scrollback.count - min(scrollOffset, terminal.scrollback.count)
            + max(0, min(visualRow, rows - 1))
        return TextPosition(
            line: max(0, min(absLine, terminal.totalLines - 1)),
            column: max(0, min(col, cols - 1))
        )
    }

    private func link(at event: NSEvent) -> TerminalLink? {
        guard let terminal = terminalProvider?(),
              let renderer,
              let position = hitPosition(
                  at: convert(event.locationInWindow, from: nil),
                  terminal: terminal,
                  renderer: renderer,
                  clampToGrid: false
              )
        else { return nil }
        return terminal.link(at: position)
    }

    private func updateHover(
        at point: NSPoint,
        terminal: Terminal,
        modifiers: NSEvent.ModifierFlags = [],
        allowsCommandHover: Bool = true
    ) {
        guard let renderer, bounds.contains(point) else {
            setHoveredLink(nil, cell: nil)
            hideCommandHover()
            return
        }
        let position = hitPosition(
            at: point,
            terminal: terminal,
            renderer: renderer,
            clampToGrid: false
        )
        let needsLinkRefresh = position != hoveredCell || hoverNeedsRefresh
        if needsLinkRefresh {
            setHoveredLink(position.flatMap { terminal.link(at: $0) }, cell: position)
        }

        guard allowsCommandHover else {
            hideCommandHover()
            return
        }
        guard let position else {
            hideCommandHover()
            return
        }
        let nativeMouseAllowed = terminal.modes.mouseMode == .none
            || modifiers.contains(.option)
        guard hoveredLink == nil, nativeMouseAllowed else {
            hideCommandHover()
            return
        }
        guard position.line != commandHoverExaminedLine else { return }
        commandHoverExaminedLine = position.line
        guard let target = CommandHoverResolver.target(
            startingAt: position.line,
            in: terminal
        ) else {
            hideCommandHover(resetExaminedLine: false)
            return
        }
        let viewportStart = terminal.scrollback.count
            - min(scrollOffset, terminal.scrollback.count)
        showCommandHover(target: target, visualRow: position.line - viewportStart)
    }

    private func showCommandHover(target: CommandHoverTarget, visualRow: Int) {
        hoveredCommandTarget = target
        hoveredCommandVisualRow = visualRow
        positionCommandHoverButton(visualRow: visualRow)
        commandHoverButton.isHidden = false
    }

    private func hideCommandHover(resetExaminedLine: Bool = true) {
        if !commandHoverButton.isHidden {
            commandHoverButton.isHidden = true
        }
        hoveredCommandTarget = nil
        hoveredCommandVisualRow = nil
        if resetExaminedLine { commandHoverExaminedLine = nil }
    }

    private func positionCommandHoverButton(visualRow: Int) {
        guard let renderer else { return }
        let size = NSSize(width: 22, height: 22)
        let inset = InkDesignTokens.Spacing.sm
        let rowTop = inset + CGFloat(visualRow) * renderer.cellSizePoints.height
        commandHoverButton.frame = NSRect(
            x: max(inset, bounds.maxX - inset - size.width),
            y: max(0, min(
                rowTop + (renderer.cellSizePoints.height - size.height) / 2,
                bounds.maxY - size.height
            )),
            width: size.width,
            height: size.height
        )
    }

    @objc private func showCommandHoverMenu(_ sender: NSButton) {
        guard let target = hoveredCommandTarget,
              let terminal = terminalProvider?(),
              let resolution = CommandHoverResolver.resolve(target, in: terminal)
        else {
            hideCommandHover()
            return
        }

        func item(_ title: String, action: Selector?, enabled: Bool) -> NSMenuItem {
            let item = NSMenuItem(title: title, action: action, keyEquivalent: "")
            item.target = self
            item.representedObject = CommandHoverMenuPayload(target: target)
            item.isEnabled = enabled
            return item
        }

        let menu = NSMenu()
        menu.autoenablesItems = false
        menu.items = [
            item(
                "上一条命令",
                action: #selector(navigateToHoveredPreviousCommand(_:)),
                enabled: resolution.previous != nil
            ),
            item(
                "下一条命令",
                action: #selector(navigateToHoveredNextCommand(_:)),
                enabled: resolution.next != nil
            ),
            .separator(),
            item("拷贝命令", action: #selector(copyHoveredCommand(_:)), enabled: true),
            item(
                "拷贝命令输出",
                action: #selector(copyHoveredCommandOutput(_:)),
                enabled: resolution.block.outputRange != nil
            ),
        ]
        commandMenuPresenter(menu, self, NSPoint(
            x: sender.frame.minX,
            y: sender.frame.minY
        ))
    }

    @objc func navigateToHoveredPreviousCommand(_ sender: NSMenuItem) {
        guard let (terminal, resolution) = resolveHoveredCommand(from: sender),
              let previous = resolution.previous else { return }
        revealCommand(previous, in: terminal)
    }

    @objc func navigateToHoveredNextCommand(_ sender: NSMenuItem) {
        guard let (terminal, resolution) = resolveHoveredCommand(from: sender),
              let next = resolution.next else { return }
        revealCommand(next, in: terminal)
    }

    @objc func copyHoveredCommand(_ sender: NSMenuItem) {
        guard let (terminal, resolution) = resolveHoveredCommand(from: sender) else { return }
        _ = writeToPasteboard(terminal.extractText(in: resolution.block.commandRange))
    }

    @objc func copyHoveredCommandOutput(_ sender: NSMenuItem) {
        guard let (terminal, resolution) = resolveHoveredCommand(from: sender),
              let outputRange = resolution.block.outputRange else { return }
        _ = writeToPasteboard(terminal.extractText(in: outputRange))
    }

    private func resolveHoveredCommand(
        from sender: NSMenuItem
    ) -> (Terminal, CommandHoverResolution)? {
        guard let payload = sender.representedObject as? CommandHoverMenuPayload,
              let terminal = terminalProvider?(),
              let resolution = CommandHoverResolver.resolve(payload.target, in: terminal)
        else {
            hideCommandHover()
            return nil
        }
        return (terminal, resolution)
    }

    private func setHoveredLink(_ link: TerminalLink?, cell: TextPosition?) {
        let changed = link != hoveredLink
        hoveredLink = link
        hoveredCell = cell
        hoverNeedsRefresh = false
        guard changed else { return }
        dirty = true
        window?.invalidateCursorRects(for: self)
    }

    private func refreshHoverFromWindow(terminal: Terminal) {
        guard let window else {
            setHoveredLink(nil, cell: nil)
            return
        }
        updateHover(
            at: convert(window.mouseLocationOutsideOfEventStream, from: nil),
            terminal: terminal,
            allowsCommandHover: false
        )
        hoverNeedsRefresh = false
    }

    public override func mouseMoved(with event: NSEvent) {
        guard let terminal = terminalProvider?() else { return }
        updateHover(
            at: convert(event.locationInWindow, from: nil),
            terminal: terminal,
            modifiers: event.modifierFlags
        )
    }

    public override func mouseExited(with event: NSEvent) {
        setHoveredLink(nil, cell: nil)
        hideCommandHover()
    }

    public override func mouseDown(with event: NSEvent) {
        hideCommandHover()
        window?.makeFirstResponder(self)
        if event.modifierFlags.contains(.command),
           let link = link(at: event),
           let url = TerminalLinkMenuPayload(target: link.target).url,
           let onOpenLink {
            onOpenLink(url)
            return
        }
        if reportMouse(event, action: .press, button: 0) { return }
        guard let pos = hitPosition(event), let terminal = terminalProvider?() else { return }

        switch event.clickCount {
        case 2:
            if let cols = terminal.wordColumns(at: pos) {
                updateSelection(SelectionRange(
                    start: TextPosition(line: pos.line, column: cols.lowerBound),
                    end: TextPosition(line: pos.line, column: cols.upperBound)
                ), in: terminal)
            }
        case 3:
            updateSelection(SelectionRange(
                start: TextPosition(line: pos.line, column: 0),
                end: TextPosition(line: pos.line, column: terminal.grid.size.columns - 1)
            ), in: terminal)
        default:
            selectionAnchor = pos
            if selection != nil {
                clearSelection() // 单击清掉旧选区
            }
        }
        markDirty()
    }

    public override func mouseDragged(with event: NSEvent) {
        hideCommandHover()
        if reportMouse(event, action: .drag, button: 0) { return }
        guard let anchor = selectionAnchor,
              let pos = hitPosition(event),
              let terminal = terminalProvider?() else { return }
        updateSelection(SelectionRange(
            start: anchor, end: pos,
            block: event.modifierFlags.contains(.option)
        ), in: terminal)
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
        let mouseReporting = (terminalProvider?().modes.mouseMode ?? .none) != .none
        let action = LinkMouseRouter.contextAction(
            mouseReporting: mouseReporting,
            optionHeld: event.modifierFlags.contains(.option)
        )
        rightMouseReportsToTUI = action == .reportToTUI
        if rightMouseReportsToTUI {
            _ = reportMouse(event, action: .press, button: 2)
            return
        }
        window?.makeFirstResponder(self)
        let menu = makeContextMenu(link: link(at: event))
        contextMenuPresenter(menu, event, self)
    }

    private func makeContextMenu(link: TerminalLink?) -> NSMenu {
        let menu = NSMenu()
        menu.autoenablesItems = false
        if let link {
            menu.addItem(contextMenuItem(
                title: "打开链接",
                action: #selector(openLink(_:)),
                representedObject: link.target
            ))
            menu.addItem(contextMenuItem(
                title: "复制链接",
                action: #selector(copyLink(_:)),
                representedObject: link.target
            ))
            menu.addItem(.separator())
        }
        menu.addItem(contextMenuItem(title: "拷贝", action: #selector(copy(_:))))
        menu.addItem(contextMenuItem(title: "粘贴", action: #selector(paste(_:))))
        menu.addItem(.separator())
        menu.addItem(contextMenuItem(
            title: "查找…",
            action: #selector(findFromContextMenu(_:))
        ))
        menu.addItem(.separator())
        for (title, direction) in [
            ("向左分屏", TerminalContextSplitDirection.left),
            ("向右分屏", .right),
            ("向上分屏", .up),
            ("向下分屏", .down),
        ] {
            menu.addItem(contextMenuItem(
                title: title,
                action: #selector(splitFromContextMenu(_:)),
                representedObject: direction
            ))
        }
        menu.addItem(.separator())
        menu.addItem(contextMenuItem(
            title: "清除滚动缓冲区",
            action: #selector(clearScrollbackFromContextMenu(_:))
        ))
        return menu
    }

    private func contextMenuItem(
        title: String,
        action: Selector,
        representedObject: Any? = nil
    ) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: action, keyEquivalent: "")
        item.target = self
        item.representedObject = representedObject
        item.isEnabled = validateMenuItem(item)
        return item
    }

    public override func rightMouseUp(with event: NSEvent) {
        guard rightMouseReportsToTUI else { return }
        rightMouseReportsToTUI = false
        _ = reportMouse(
            event,
            action: .release,
            button: 2,
            optionOverrides: false
        )
    }

    @objc func openLink(_ sender: NSMenuItem) {
        guard let target = sender.representedObject as? String,
              let url = TerminalLinkMenuPayload(target: target).url
        else { return }
        onOpenLink?(url)
    }

    @objc func copyLink(_ sender: NSMenuItem) {
        guard let target = sender.representedObject as? String else { return }
        _ = writeToPasteboard(target)
    }

    @objc private func findFromContextMenu(_ sender: Any?) {
        onFind?()
    }

    @objc private func splitFromContextMenu(_ sender: NSMenuItem) {
        guard let direction = sender.representedObject as? TerminalContextSplitDirection else {
            return
        }
        onSplit?(direction)
    }

    @objc private func clearScrollbackFromContextMenu(_ sender: Any?) {
        onClearScrollback?()
    }

    @objc public func copy(_ sender: Any?) {
        guard let selection, let terminal = terminalProvider?() else { return }
        let text = terminal.extractText(in: selection)
        _ = writeToPasteboard(text)
    }


    // MARK: - 键盘输入

    public override var acceptsFirstResponder: Bool { true }

    public override func becomeFirstResponder() -> Bool {
        let accepted = super.becomeFirstResponder()
        if accepted { onFocus?() }
        return accepted
    }

    public override func keyDown(with event: NSEvent) {
        hideCommandHover()
        if event.modifierFlags.contains(.command) {
            super.keyDown(with: event)
            return
        }
        // 敲键即回到底部并清选区，跟系统终端一致。
        if scrollOffset != 0 || selection != nil {
            scrollOffset = 0
            clearSelection()
            commandNavigationAnchor = nil
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
        guard let text = pasteboardReader() else { return }
        paste(text: text)
    }

    func paste(text: String) {
        while true {
            let bracketedPaste = terminalProvider?().modes.bracketedPaste ?? false
            guard let assessment = SafePaste.assessment(
                for: text,
                bracketedPaste: bracketedPaste
            ) else {
                onInput?(SafePaste.encoded(text, bracketedPaste: bracketedPaste))
                return
            }

            switch safePastePresenter.choose(for: assessment) {
            case .paste:
                let currentMode = terminalProvider?().modes.bracketedPaste ?? false
                guard currentMode == bracketedPaste else { continue }
                onInput?(SafePaste.encoded(text, bracketedPaste: currentMode))
                return
            case .singleLine:
                let currentMode = terminalProvider?().modes.bracketedPaste ?? false
                onInput?(SafePaste.encoded(
                    SafePaste.singleLine(text),
                    bracketedPaste: currentMode
                ))
                return
            case .cancel:
                return
            }
        }
    }

    public func validateMenuItem(_ menuItem: NSMenuItem) -> Bool {
        if menuItem.action == #selector(copy(_:)) { return selection != nil }
        if menuItem.action == #selector(paste(_:)) {
            return pasteboardReader().map { !$0.isEmpty } ?? false
        }
        if menuItem.action == #selector(openLink(_:)) {
            guard let target = menuItem.representedObject as? String else { return false }
            return TerminalLinkMenuPayload(target: target).url != nil && onOpenLink != nil
        }
        if menuItem.action == #selector(copyLink(_:)) {
            return menuItem.representedObject is String
        }
        if menuItem.action == #selector(findFromContextMenu(_:)) { return onFind != nil }
        if menuItem.action == #selector(clearScrollbackFromContextMenu(_:)) {
            return onClearScrollback != nil
        }
        if menuItem.action == #selector(splitFromContextMenu(_:)) {
            guard onSplit != nil,
                  let direction = menuItem.representedObject as? TerminalContextSplitDirection,
                  let size = terminalProvider?().grid.size else { return false }
            return switch direction {
            case .left, .right: size.columns >= 20
            case .up, .down: size.rows >= 6
            }
        }
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
