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

    private var renderer: TerminalRenderer?
    private var displayLink: CADisplayLink?
    private var dirty = true
    private var cursorOn = true
    private var lastBlinkFlip = CACurrentMediaTime()
    private var lastGridSize: TerminalSize?

    // 滚动与选区。offset 单位是行，0 = 跟住底部。
    private var scrollOffset = 0
    private var scrollAccumulator: CGFloat = 0
    private var selectionAnchor: TextPosition?
    private var selection: SelectionRange?

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
        return layer
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
        guard let renderer = TerminalRenderer(
            font: InkDesignTokens.Typography.terminal(), scale: scale
        ) else { return }
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
        if now - lastBlinkFlip > 0.6 {
            cursorOn.toggle()
            lastBlinkFlip = now
            dirty = true
        }
        guard dirty, let renderer, let terminal = terminalProvider?() else { return }
        dirty = false
        scrollOffset = min(scrollOffset, terminal.scrollback.count)
        renderer.render(
            terminal: terminal, into: metalLayer, cursorOn: cursorOn,
            scrollOffset: scrollOffset, selection: selection,
            preedit: markedText.isEmpty ? nil : markedText
        )
    }

    // MARK: - 滚动

    public override func scrollWheel(with event: NSEvent) {
        guard let renderer, let terminal = terminalProvider?() else { return }
        // 备用屏（vim/less）没有 scrollback，滚轮交给应用自己（任务 #11 接鼠标上报）。
        guard !terminal.modes.alternateScreen else { return }

        scrollAccumulator += event.scrollingDeltaY
        let cellH = renderer.cellSizePoints.height
        let deltaRows = Int(scrollAccumulator / cellH)
        guard deltaRows != 0 else { return }
        scrollAccumulator -= CGFloat(deltaRows) * cellH

        let target = scrollOffset + deltaRows // 向上滚 delta 为正，翻历史
        scrollOffset = max(0, min(target, terminal.scrollback.count))
        markDirty()
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
        guard let anchor = selectionAnchor, let pos = hitPosition(event) else { return }
        selection = SelectionRange(
            start: anchor, end: pos,
            block: event.modifierFlags.contains(.option)
        )
        markDirty()
    }

    public override func mouseUp(with event: NSEvent) {
        selectionAnchor = nil
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
            if let data = Self.encode(event: event) { onInput?(data) }
            return
        }
        // 其余全部路过输入法：中文拼音在这里被 IME 截走变成
        // setMarkedText / insertText；未被消费的走 doCommandBySelector 兜底。
        pendingKeyEvent = event
        interpretKeyEvents([event])
        pendingKeyEvent = nil
    }

    public override func doCommand(by selector: Selector) {
        // IME 未消费的按键（回车、退格、方向键、⌃C…）：用暂存的原始事件
        // 按终端语义编码，不走 AppKit 的文本编辑命令。
        if let event = pendingKeyEvent, let data = Self.encode(event: event) {
            onInput?(data)
        }
    }

    @objc public func paste(_ sender: Any?) {
        guard let text = NSPasteboard.general.string(forType: .string) else { return }
        // Bracketed paste 包裹在任务 #11 接（terminal.modes.bracketedPaste）。
        onInput?(Data(text.utf8))
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

    /// 键 → 终端字节。完整的功能键矩阵与 Option-as-Meta 是任务 #11；
    /// NSTextInputClient（中文输入）是任务 #10，接入后这里改走 interpretKeyEvents。
    private static func encode(event: NSEvent) -> Data? {
        guard let characters = event.characters, let scalar = characters.unicodeScalars.first else {
            return nil
        }
        switch scalar.value {
        case 0xF700: return Data("\u{1B}[A".utf8)
        case 0xF701: return Data("\u{1B}[B".utf8)
        case 0xF703: return Data("\u{1B}[C".utf8)
        case 0xF702: return Data("\u{1B}[D".utf8)
        case 0xF728: return Data("\u{1B}[3~".utf8)
        case 0xF700...0xF8FF: return nil
        case 0x0D: return Data([0x0D])
        case 0x7F: return Data([0x7F])
        default: return Data(characters.utf8)
        }
    }
}
