import AppKit
import InkDesign

/// 当前 pane 右上角的搜索浮层，不参与终端内容区布局。
@MainActor
final class TerminalSearchBarView: NSVisualEffectView, NSSearchFieldDelegate {
    var onQueryChange: ((String) -> Void)?
    var onCaseSensitivityChange: ((Bool) -> Void)?
    var onSelectionScopeChange: ((Bool) -> Void)?
    var onCopyMatchCommandOutput: (() -> Void)?
    var onNext: (() -> Void)?
    var onPrevious: (() -> Void)?
    var onClose: (() -> Void)?

    private let searchField = NSSearchField(frame: .zero)
    private let resultLabel = NSTextField(labelWithString: "0 / 0")
    private let caseSensitiveButton = NSButton(frame: .zero)
    private let selectionButton = NSButton(frame: .zero)
    private let copyOutputButton = NSButton(frame: .zero)
    private let previousButton = NSButton(frame: .zero)
    private let nextButton = NSButton(frame: .zero)
    private let closeButton = NSButton(frame: .zero)

    var resultText: String { resultLabel.stringValue }
    var navigationEnabled: Bool { previousButton.isEnabled && nextButton.isEnabled }
    var caseSensitiveEnabled: Bool { caseSensitiveButton.state == .on }
    var selectionOnlyEnabled: Bool { selectionButton.state == .on }
    var selectionToggleEnabled: Bool { selectionButton.isEnabled }
    var copyOutputEnabled: Bool { copyOutputButton.isEnabled }

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

        configureToggle(
            caseSensitiveButton,
            title: "Aa",
            label: "区分大小写",
            width: 30,
            action: #selector(toggleCaseSensitivity(_:))
        )
        configureToggle(
            selectionButton,
            title: "选区",
            label: "仅搜索选区",
            width: 42,
            action: #selector(toggleSelectionScope(_:))
        )
        configure(
            copyOutputButton,
            symbol: "doc.on.doc",
            label: "拷贝匹配所在命令输出",
            action: #selector(copyMatchCommandOutput(_:))
        )

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
            searchField, resultLabel, caseSensitiveButton, selectionButton,
            copyOutputButton, previousButton, nextButton, closeButton,
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
        updateResultPosition(currentIndex: nil, total: 0)
        updateSearchModes(
            caseSensitive: false,
            selectionOnly: false,
            selectionAvailable: false,
            copyOutputAvailable: false
        )
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("代码构建，不支持 nib")
    }

    func focus() {
        window?.makeFirstResponder(searchField)
        searchField.currentEditor()?.selectAll(nil)
    }

    func ownsResponder(_ responder: NSResponder?) -> Bool {
        guard let responder else { return false }
        return responder === searchField || responder === searchField.currentEditor()
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

    func updateSearchModes(
        caseSensitive: Bool,
        selectionOnly: Bool,
        selectionAvailable: Bool,
        copyOutputAvailable: Bool
    ) {
        caseSensitiveButton.state = caseSensitive ? .on : .off
        caseSensitiveButton.setAccessibilityValue(caseSensitive ? "已开启" : "已关闭")
        selectionButton.state = selectionOnly ? .on : .off
        selectionButton.isEnabled = selectionOnly || selectionAvailable
        selectionButton.setAccessibilityValue(selectionOnly ? "已开启" : "已关闭")
        copyOutputButton.isEnabled = copyOutputAvailable
    }

    func toggleCaseSensitivity() {
        let enabled = caseSensitiveButton.state != .on
        caseSensitiveButton.state = enabled ? .on : .off
        onCaseSensitivityChange?(enabled)
    }

    func toggleSelectionScope() {
        guard selectionButton.isEnabled else { return }
        let enabled = selectionButton.state != .on
        selectionButton.state = enabled ? .on : .off
        onSelectionScopeChange?(enabled)
    }

    func performCopyMatchCommandOutput() {
        guard copyOutputButton.isEnabled else { return }
        onCopyMatchCommandOutput?()
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

    private func configureToggle(
        _ button: NSButton,
        title: String,
        label: String,
        width: CGFloat,
        action: Selector
    ) {
        button.title = title
        button.font = .systemFont(ofSize: 11, weight: .medium)
        button.setButtonType(.pushOnPushOff)
        button.bezelStyle = .texturedRounded
        button.controlSize = .small
        button.target = self
        button.action = action
        button.toolTip = label
        button.setAccessibilityLabel(label)
        button.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            button.widthAnchor.constraint(equalToConstant: width),
            button.heightAnchor.constraint(equalToConstant: 22),
        ])
    }

    @objc private func toggleCaseSensitivity(_ sender: Any?) { toggleCaseSensitivity() }
    @objc private func toggleSelectionScope(_ sender: Any?) { toggleSelectionScope() }
    @objc private func copyMatchCommandOutput(_ sender: Any?) { performCopyMatchCommandOutput() }
    @objc private func previousResult(_ sender: Any?) { onPrevious?() }
    @objc private func nextResult(_ sender: Any?) { onNext?() }
    @objc private func closeSearch(_ sender: Any?) { onClose?() }
}
