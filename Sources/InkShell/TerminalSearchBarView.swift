import AppKit
import InkDesign

/// 当前 pane 右上角的搜索浮层，不参与终端内容区布局。
@MainActor
final class TerminalSearchBarView: NSVisualEffectView, NSSearchFieldDelegate {
    var onQueryChange: ((String) -> Void)?
    var onNext: (() -> Void)?
    var onPrevious: (() -> Void)?
    var onClose: (() -> Void)?

    private let searchField = NSSearchField(frame: .zero)
    private let resultLabel = NSTextField(labelWithString: "0 / 0")
    private let previousButton = NSButton(frame: .zero)
    private let nextButton = NSButton(frame: .zero)
    private let closeButton = NSButton(frame: .zero)

    var resultText: String { resultLabel.stringValue }

    init() {
        super.init(frame: .zero)
        material = .popover
        blendingMode = .withinWindow
        state = .active
        wantsLayer = true
        layer?.cornerRadius = InkDesignTokens.Radius.control
        layer?.masksToBounds = true

        searchField.placeholderString = "搜索"
        searchField.delegate = self
        searchField.sendsSearchStringImmediately = true
        searchField.translatesAutoresizingMaskIntoConstraints = false

        resultLabel.font = .monospacedDigitSystemFont(ofSize: 11, weight: .regular)
        resultLabel.textColor = InkDesignTokens.Color.textSecondary
        resultLabel.alignment = .center
        resultLabel.translatesAutoresizingMaskIntoConstraints = false

        configure(
            previousButton,
            symbol: "chevron.up",
            label: "上一个搜索结果",
            action: #selector(previousResult(_:))
        )
        configure(
            nextButton,
            symbol: "chevron.down",
            label: "下一个搜索结果",
            action: #selector(nextResult(_:))
        )
        configure(
            closeButton,
            symbol: "xmark",
            label: "关闭搜索",
            action: #selector(closeSearch(_:))
        )

        let stack = NSStackView(views: [
            searchField, resultLabel, previousButton, nextButton, closeButton,
        ])
        stack.orientation = .horizontal
        stack.alignment = .centerY
        stack.spacing = InkDesignTokens.Spacing.xxs
        stack.edgeInsets = NSEdgeInsets(top: 4, left: 6, bottom: 4, right: 6)
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)

        NSLayoutConstraint.activate([
            stack.topAnchor.constraint(equalTo: topAnchor),
            stack.leadingAnchor.constraint(equalTo: leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: trailingAnchor),
            stack.bottomAnchor.constraint(equalTo: bottomAnchor),
            searchField.widthAnchor.constraint(equalToConstant: 190),
            resultLabel.widthAnchor.constraint(equalToConstant: 52),
            heightAnchor.constraint(equalToConstant: 34),
        ])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("代码构建，不支持 nib")
    }

    func focus() {
        window?.makeFirstResponder(searchField)
        searchField.currentEditor()?.selectAll(nil)
    }

    func updateResultPosition(currentIndex: Int?, total: Int) {
        if let currentIndex, total > 0 {
            resultLabel.stringValue = "\(currentIndex + 1) / \(total)"
        } else {
            resultLabel.stringValue = "0 / \(total)"
        }
        let hasResults = total > 0
        previousButton.isEnabled = hasResults
        nextButton.isEnabled = hasResults
    }

    func controlTextDidChange(_ notification: Notification) {
        onQueryChange?(searchField.stringValue)
    }

    func control(
        _ control: NSControl,
        textView: NSTextView,
        doCommandBy commandSelector: Selector
    ) -> Bool {
        handleCommand(
            commandSelector,
            shiftPressed: NSApp.currentEvent?.modifierFlags.contains(.shift) == true
        )
    }

    func handleCommand(_ selector: Selector, shiftPressed: Bool) -> Bool {
        switch selector {
        case #selector(NSResponder.insertNewline(_:)):
            shiftPressed ? onPrevious?() : onNext?()
        case #selector(NSResponder.moveDown(_:)):
            onNext?()
        case #selector(NSResponder.moveUp(_:)):
            onPrevious?()
        case #selector(NSResponder.cancelOperation(_:)):
            onClose?()
        default:
            return false
        }
        return true
    }

    private func configure(
        _ button: NSButton,
        symbol: String,
        label: String,
        action: Selector
    ) {
        button.image = NSImage(systemSymbolName: symbol, accessibilityDescription: label)
        button.imagePosition = .imageOnly
        button.isBordered = false
        button.target = self
        button.action = action
        button.setAccessibilityLabel(label)
        button.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            button.widthAnchor.constraint(equalToConstant: 22),
            button.heightAnchor.constraint(equalToConstant: 22),
        ])
    }

    @objc private func previousResult(_ sender: Any?) { onPrevious?() }
    @objc private func nextResult(_ sender: Any?) { onNext?() }
    @objc private func closeSearch(_ sender: Any?) { onClose?() }
}
