import AppKit
import InkDesign

/// M1 占位终端视图：`NSTextView` 只读展示 + 键盘直通 PTY。
///
/// 存在的唯一目的是验证 PTY 与 shell 交互正常（roadmap M1）。M2 上 Metal
/// 渲染器后整个文件删除，不要在这上面做任何优化或功能叠加。
///
/// 按键处理必须放在 `NSTextView` 子类里：点击后成为 first responder 的是
/// 文本视图本身，外层容器的 `keyDown` 收不到事件。
@MainActor
public final class PlaceholderTerminalView: NSView {

    /// 用户输入的字节流（含控制键编码）。由外部接到 `PTYSession.write`。
    public var onInput: ((Data) -> Void)? {
        get { textView.onInput }
        set { textView.onInput = newValue }
    }

    private let scrollView = NSScrollView()
    private let textView = KeyForwardingTextView()
    private var stripper = PlaceholderANSIStripper()
    private let font = InkDesignTokens.Typography.terminal()

    public override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)

        textView.isEditable = false
        textView.isSelectable = true
        textView.font = font
        textView.drawsBackground = true
        textView.backgroundColor = InkDesignTokens.Color.terminal
        textView.textColor = InkDesignTokens.Color.textPrimary
        textView.insertionPointColor = .clear
        textView.textContainerInset = NSSize(width: InkDesignTokens.Spacing.sm, height: InkDesignTokens.Spacing.sm)
        textView.autoresizingMask = [.width]
        textView.isVerticallyResizable = true
        textView.textContainer?.widthTracksTextView = true

        scrollView.documentView = textView
        scrollView.hasVerticalScroller = true
        scrollView.drawsBackground = true
        scrollView.backgroundColor = InkDesignTokens.Color.terminal
        scrollView.translatesAutoresizingMaskIntoConstraints = false
        addSubview(scrollView)
        NSLayoutConstraint.activate([
            scrollView.topAnchor.constraint(equalTo: topAnchor),
            scrollView.bottomAnchor.constraint(equalTo: bottomAnchor),
            scrollView.leadingAnchor.constraint(equalTo: leadingAnchor),
            scrollView.trailingAnchor.constraint(equalTo: trailingAnchor),
        ])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("代码构建，不支持 nib")
    }

    /// 让窗口把焦点直接交给文本视图。
    public func focus() {
        window?.makeFirstResponder(textView)
    }

    // MARK: - 输出

    public func append(_ data: Data) {
        guard let storage = textView.textStorage else { return }
        let events = stripper.process(data)
        guard !events.isEmpty else { return }

        storage.beginEditing()
        for event in events {
            switch event {
            case .text(let text):
                storage.append(NSAttributedString(string: text, attributes: [
                    .font: font,
                    .foregroundColor: InkDesignTokens.Color.textPrimary,
                ]))
            case .newline:
                storage.append(NSAttributedString(string: "\n", attributes: [.font: font]))
            case .carriageReturn:
                // ZLE 重画：清掉当前行，等着接收重画后的文本。
                let string = storage.string as NSString
                let lineStart: Int
                let newlineRange = string.range(of: "\n", options: .backwards)
                lineStart = newlineRange.location == NSNotFound ? 0 : newlineRange.location + 1
                storage.deleteCharacters(in: NSRange(location: lineStart, length: string.length - lineStart))
            case .backspace:
                let string = storage.string as NSString
                guard string.length > 0 else { break }
                let lastRange = string.rangeOfComposedCharacterSequence(at: string.length - 1)
                if string.substring(with: lastRange) != "\n" {
                    storage.deleteCharacters(in: lastRange)
                }
            }
        }
        storage.endEditing()
        textView.scrollToEndOfDocument(nil)
    }

    public func appendNotice(_ message: String) {
        append(Data("\n\(message)\n".utf8))
    }

    // MARK: - 网格尺寸

    /// 按当前字体估算可容纳的列 × 行，给 PTY 的 TIOCSWINSZ 用。
    public func gridSize() -> (columns: Int, rows: Int) {
        let cellWidth = ("0" as NSString).size(withAttributes: [.font: font]).width
        let cellHeight = NSLayoutManager().defaultLineHeight(for: font)
        let inset = InkDesignTokens.Spacing.sm * 2
        let usable = NSSize(width: bounds.width - inset, height: bounds.height - inset)
        return (
            columns: max(20, Int(usable.width / cellWidth)),
            rows: max(5, Int(usable.height / cellHeight))
        )
    }
}

/// 只读展示但拦截按键转发给 PTY 的文本视图。
@MainActor
final class KeyForwardingTextView: NSTextView {

    var onInput: ((Data) -> Void)?

    override var acceptsFirstResponder: Bool { true }

    override func keyDown(with event: NSEvent) {
        // ⌘ 组合键留给菜单（⌘Q、⌘C 复制选中等）。
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

    /// 只读模式下 NSTextView 默认禁用 paste，这里接管：粘贴内容发给 shell。
    @objc override func paste(_ sender: Any?) {
        guard let text = NSPasteboard.general.string(forType: .string) else { return }
        // Bracketed paste 是 M4 的事，占位阶段直接透传。
        onInput?(Data(text.utf8))
    }

    /// 让「粘贴」菜单项在只读文本视图上仍然可用。
    override func validateUserInterfaceItem(_ item: any NSValidatedUserInterfaceItem) -> Bool {
        if item.action == #selector(paste(_:)) { return true }
        return super.validateUserInterfaceItem(item)
    }

    /// 把按键编成终端字节。占位实现只覆盖日常导航键；完整的功能键与
    /// Option-as-Meta 编码是任务 #11。
    private static func encode(event: NSEvent) -> Data? {
        guard let characters = event.characters, let scalar = characters.unicodeScalars.first else {
            return nil
        }
        switch scalar.value {
        case 0xF700: return Data("\u{1B}[A".utf8) // ↑
        case 0xF701: return Data("\u{1B}[B".utf8) // ↓
        case 0xF703: return Data("\u{1B}[C".utf8) // →
        case 0xF702: return Data("\u{1B}[D".utf8) // ←
        case 0xF728: return Data("\u{1B}[3~".utf8) // fn⌫
        case 0xF700...0xF8FF: return nil // 其余功能键先不管
        case 0x0D: return Data([0x0D]) // 回车统一发 CR
        case 0x7F: return Data([0x7F]) // ⌫
        default:
            // 含控制字符（⌃C → 0x03）与普通字符，直接按 UTF-8 发。
            return Data(characters.utf8)
        }
    }
}
