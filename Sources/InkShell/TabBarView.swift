import AppKit
import InkDesign

/// 顶部标签栏：占据标题栏那条带（fullSizeContentView 下的窗口顶部）。
/// 活动标签是圆角 pill，非活动只有文字；右侧是侧边栏开关。
/// 系统没有对应控件，这是设计系统里明确允许自绘的地方。
@MainActor
final class TabBarView: NSView {

    struct Tab {
        let title: String
        let active: Bool
    }

    var onSelect: ((Int) -> Void)?
    var onNewTab: (() -> Void)?
    var onToggleSidebar: (() -> Void)?

    private let stack = NSStackView()
    private let toggleButton = NSButton()
    private var toggleLeading: NSLayoutConstraint?

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)

        stack.orientation = .horizontal
        stack.spacing = 4
        stack.alignment = .centerY
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)

        // 开关在最左（macOS 惯例：贴近红绿灯一侧）。
        toggleButton.bezelStyle = .accessoryBarAction
        toggleButton.isBordered = false
        toggleButton.image = NSImage(
            systemSymbolName: "sidebar.left", accessibilityDescription: "切换侧边栏"
        )
        toggleButton.contentTintColor = InkDesignTokens.Color.textSecondary
        toggleButton.target = self
        toggleButton.action = #selector(toggleSidebar)
        toggleButton.translatesAutoresizingMaskIntoConstraints = false
        addSubview(toggleButton)

        let leading = toggleButton.leadingAnchor.constraint(
            equalTo: leadingAnchor, constant: InkDesignTokens.Spacing.sm
        )
        toggleLeading = leading
        NSLayoutConstraint.activate([
            leading,
            toggleButton.centerYAnchor.constraint(equalTo: centerYAnchor),
            stack.leadingAnchor.constraint(equalTo: toggleButton.trailingAnchor, constant: 10),
            stack.centerYAnchor.constraint(equalTo: centerYAnchor),
            stack.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor, constant: -InkDesignTokens.Spacing.sm),
        ])
    }

    /// 侧边栏收起时内容列占满窗口，开关要让开红绿灯。
    func setLeadingInset(_ inset: CGFloat) {
        toggleLeading?.constant = inset
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("代码构建") }

    /// 空白区域拖动窗口——这条带就是事实上的标题栏。
    override var mouseDownCanMoveWindow: Bool { true }

    func reload(tabs: [Tab]) {
        stack.arrangedSubviews.forEach { $0.removeFromSuperview() }
        for (index, tab) in tabs.enumerated() {
            stack.addArrangedSubview(makePill(tab: tab, index: index))
        }
        let plus = NSButton(
            image: NSImage(systemSymbolName: "plus", accessibilityDescription: "新建会话")!,
            target: self, action: #selector(newTab)
        )
        plus.isBordered = false
        plus.contentTintColor = InkDesignTokens.Color.textSecondary
        stack.addArrangedSubview(plus)
    }

    private func makePill(tab: Tab, index: Int) -> NSView {
        let button = NSButton(title: tab.title, target: self, action: #selector(selectTab(_:)))
        button.tag = index
        button.isBordered = false
        button.font = InkDesignTokens.Typography.body
        button.contentTintColor = tab.active
            ? InkDesignTokens.Color.textPrimary
            : InkDesignTokens.Color.textSecondary
        button.wantsLayer = true
        button.layer?.cornerRadius = InkDesignTokens.Radius.control
        button.layer?.cornerCurve = .continuous
        if tab.active {
            button.layer?.backgroundColor = InkDesignTokens.Color.pill.cgColor
        }
        button.setContentHuggingPriority(.defaultHigh, for: .horizontal)
        // pill 内边距：NSButton 无边框时太紧，用固定尺寸补
        button.translatesAutoresizingMaskIntoConstraints = false
        button.heightAnchor.constraint(equalToConstant: 26).isActive = true
        return button
    }

    @objc private func selectTab(_ sender: NSButton) { onSelect?(sender.tag) }
    @objc private func newTab() { onNewTab?() }
    @objc private func toggleSidebar() { onToggleSidebar?() }
}
