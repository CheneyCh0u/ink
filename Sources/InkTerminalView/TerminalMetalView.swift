import AppKit
import QuartzCore
import TerminalCore
import InkDesign

/// 终端内容区：CAMetalLayer 自绘。
///
/// 帧驱动是 `CADisplayLink`（macOS 14+ 的 NSView API，自动跟随窗口所在
/// 显示器的刷新率），只有脏帧才真正编码渲染——空闲时 GPU 零负载。
@MainActor
public final class TerminalMetalView: NSView {

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

    private var metalLayer: CAMetalLayer { layer as! CAMetalLayer }

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
        renderer.render(terminal: terminal, into: metalLayer, cursorOn: cursorOn)
    }

    // MARK: - 键盘输入

    public override var acceptsFirstResponder: Bool { true }

    public override func mouseDown(with event: NSEvent) {
        window?.makeFirstResponder(self)
    }

    public override func keyDown(with event: NSEvent) {
        if event.modifierFlags.contains(.command) {
            super.keyDown(with: event)
            return
        }
        if let data = Self.encode(event: event) {
            onInput?(data)
        } else {
            super.keyDown(with: event)
        }
    }

    @objc public func paste(_ sender: Any?) {
        guard let text = NSPasteboard.general.string(forType: .string) else { return }
        // Bracketed paste 包裹在任务 #11 接（terminal.modes.bracketedPaste）。
        onInput?(Data(text.utf8))
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
