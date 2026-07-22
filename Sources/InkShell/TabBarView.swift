import AppKit
import InkDesign

/// 顶部标签栏：标签按内容宽度压缩或进入溢出菜单，活动标签显示 pill，
/// 悬停显示关闭按钮，双击改名，右侧保留快捷键提示与新建入口。
/// 系统没有对应控件，这是设计系统里明确允许自绘的地方。
@MainActor
final class TabBarView: NSView {

    struct Tab {
        let title: String
        let shortcut: String
        let active: Bool
    }

    var onSelect: ((Int) -> Void)?
    var onClose: ((Int) -> Void)?
    var onRename: ((Int, String) -> Void)?
    var onNewTab: (() -> Void)?
    var onToggleSidebar: (() -> Void)?
    var onSettings: (() -> Void)?

    private let stack = NSStackView()
    private let toggleButton = NSButton()
    private let plusButton = NSButton()
    private let settingsButton = TabBarSettingsButton()
    private let overflowButton = TabBarOverflowButton()
    private var toggleLeading: NSLayoutConstraint?
    private var tabs: [Tab] = []
    private var tabItems: [TabItemView] = []
    private var widthConstraints: [NSLayoutConstraint] = []
    private var previousVisibleRange: Range<Int>?
    private var appliedLayout: TabBarLayout?
    private(set) var visibleTabIndices: [Int] = []

    var overflowMenu: NSMenu? { overflowButton.menu }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)

        toggleButton.isBordered = false
        toggleButton.image = NSImage(
            systemSymbolName: "sidebar.left", accessibilityDescription: "切换侧边栏"
        )
        toggleButton.contentTintColor = InkDesignTokens.Color.textSecondary
        toggleButton.target = self
        toggleButton.action = #selector(toggleSidebar)
        toggleButton.translatesAutoresizingMaskIntoConstraints = false
        addSubview(toggleButton)

        plusButton.isBordered = false
        plusButton.image = NSImage(systemSymbolName: "plus", accessibilityDescription: "新建标签")
        plusButton.contentTintColor = InkDesignTokens.Color.textSecondary
        plusButton.target = self
        plusButton.action = #selector(newTab)
        plusButton.translatesAutoresizingMaskIntoConstraints = false
        addSubview(plusButton)

        settingsButton.isBordered = false
        settingsButton.image = NSImage(systemSymbolName: "gearshape", accessibilityDescription: nil)
        settingsButton.contentTintColor = InkDesignTokens.Color.textSecondary
        settingsButton.toolTip = "设置（⌘,）"
        settingsButton.setAccessibilityLabel("设置")
        settingsButton.target = self
        settingsButton.action = #selector(openSettings)
        settingsButton.translatesAutoresizingMaskIntoConstraints = false
        addSubview(settingsButton)

        overflowButton.isBordered = false
        overflowButton.image = NSImage(
            systemSymbolName: "chevron.down",
            accessibilityDescription: nil
        )
        overflowButton.contentTintColor = InkDesignTokens.Color.textSecondary
        overflowButton.toolTip = "更多标签"
        overflowButton.setAccessibilityLabel("更多标签")
        overflowButton.target = self
        overflowButton.action = #selector(showOverflowMenu)
        overflowButton.isHidden = true
        addSubview(overflowButton)

        // 标签由连续可见区间控制，宽度及位置在 layout 中统一计算。
        stack.orientation = .horizontal
        stack.distribution = .fill
        stack.spacing = InkDesignTokens.TabBar.itemSpacing
        stack.alignment = .centerY
        addSubview(stack)

        let leading = toggleButton.leadingAnchor.constraint(
            equalTo: leadingAnchor, constant: InkDesignTokens.Spacing.sm
        )
        toggleLeading = leading
        NSLayoutConstraint.activate([
            leading,
            toggleButton.centerYAnchor.constraint(equalTo: centerYAnchor),
            plusButton.centerYAnchor.constraint(equalTo: centerYAnchor),
            settingsButton.leadingAnchor.constraint(equalTo: plusButton.trailingAnchor, constant: 6),
            settingsButton.trailingAnchor.constraint(
                equalTo: trailingAnchor,
                constant: -InkDesignTokens.Spacing.sm
            ),
            settingsButton.centerYAnchor.constraint(equalTo: centerYAnchor),
            settingsButton.widthAnchor.constraint(equalToConstant: 28),
            settingsButton.heightAnchor.constraint(equalToConstant: 28),
        ])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("代码构建") }

    /// 空白区域拖动窗口——这条带就是事实上的标题栏。
    override var mouseDownCanMoveWindow: Bool { true }

    /// 侧边栏收起时内容列占满窗口，开关要让开红绿灯。
    func setLeadingInset(_ inset: CGFloat) {
        toggleLeading?.constant = inset
    }

    func setSidebarMode(_ mode: SidebarDisplayMode) {
        let action: String =
            switch mode {
            case .expanded: "收为项目图标"
            case .compact: "隐藏侧边栏"
            case .hidden: "展开侧边栏"
            }
        toggleButton.toolTip = action
        toggleButton.setAccessibilityLabel(action)
    }

    func setSettingsSelected(_ selected: Bool) {
        settingsButton.setSelected(selected)
    }

    func reload(tabs: [Tab]) {
        overflowButton.menu?.cancelTracking()
        overflowButton.menu = nil
        stack.arrangedSubviews.forEach {
            stack.removeArrangedSubview($0)
            $0.removeFromSuperview()
        }
        tabItems.forEach { $0.removeFromSuperview() }
        widthConstraints.forEach { $0.isActive = false }
        widthConstraints.removeAll(keepingCapacity: true)

        self.tabs = tabs
        tabItems = tabs.enumerated().map { index, tab in
            let item = TabItemView(tab: tab)
            item.translatesAutoresizingMaskIntoConstraints = false
            item.onSelect = { [weak self] in self?.onSelect?(index) }
            item.onClose = { [weak self] in self?.onClose?(index) }
            item.onRename = { [weak self] name in self?.onRename?(index, name) }
            return item
        }
        visibleTabIndices = []
        appliedLayout = nil
        invalidateIntrinsicContentSize()
        needsLayout = true
    }

    override var intrinsicContentSize: NSSize {
        let tabWidth = tabItems.map(\.preferredWidth).max() ?? 0
        let controlWidth = InkDesignTokens.Spacing.sm * 2
            + toggleButton.fittingSize.width
            + 10
            + 8
            + plusButton.fittingSize.width
            + 6
            + settingsButton.fittingSize.width
        return NSSize(width: tabWidth + controlWidth, height: NSView.noIntrinsicMetric)
    }

    override func layout() {
        super.layout()
        let leading = toggleButton.frame.maxX + 10
        let trailing = plusButton.frame.minX - 8
        let availableWidth = max(0, trailing - leading)
        let activeIndex = tabs.firstIndex(where: \.active) ?? 0
        let result = TabBarLayout.resolve(
            preferredWidths: tabItems.map(\.preferredWidth),
            activeIndex: activeIndex,
            availableWidth: availableWidth,
            previousVisibleRange: previousVisibleRange
        )

        let structureUnchanged = appliedLayout?.visibleRange == result.visibleRange
            && appliedLayout?.hiddenIndices == result.hiddenIndices
            && widthConstraints.count == result.widths.count
        if structureUnchanged {
            updateWidths(result.widths)
        } else {
            applyStructure(result)
        }
        appliedLayout = result
        positionTabRegion(result, leading: leading, trailing: trailing)
    }

    private func applyStructure(_ result: TabBarLayout) {
        stack.arrangedSubviews.forEach {
            stack.removeArrangedSubview($0)
            $0.removeFromSuperview()
        }
        widthConstraints.forEach { $0.isActive = false }
        widthConstraints.removeAll(keepingCapacity: true)

        visibleTabIndices = Array(result.visibleRange)
        for (offset, index) in visibleTabIndices.enumerated() {
            let item = tabItems[index]
            stack.addArrangedSubview(item)
            let constraint = item.widthAnchor.constraint(equalToConstant: result.widths[offset])
            constraint.isActive = true
            widthConstraints.append(constraint)
        }
        previousVisibleRange = result.visibleRange
        rebuildOverflowMenu(hiddenIndices: result.hiddenIndices)
    }

    private func updateWidths(_ widths: [CGFloat]) {
        for (constraint, width) in zip(widthConstraints, widths) {
            constraint.constant = width
        }
    }

    private func positionTabRegion(
        _ result: TabBarLayout,
        leading: CGFloat,
        trailing: CGFloat
    ) {
        let token = InkDesignTokens.TabBar.self
        let height: CGFloat = 28
        let y = (bounds.height - height) / 2
        let stackWidth = result.widths.reduce(0, +)
            + CGFloat(max(0, result.widths.count - 1)) * token.itemSpacing
        stack.frame = NSRect(x: leading, y: y, width: stackWidth, height: height)

        overflowButton.isHidden = !result.showsOverflow
        if result.showsOverflow {
            overflowButton.frame = NSRect(
                x: trailing - token.overflowButtonWidth,
                y: y,
                width: token.overflowButtonWidth,
                height: height
            )
        } else {
            overflowButton.frame = .zero
        }
    }

    private func rebuildOverflowMenu(hiddenIndices: [Int]) {
        overflowButton.menu?.cancelTracking()
        guard !hiddenIndices.isEmpty else {
            overflowButton.menu = nil
            return
        }

        let menu = NSMenu(title: "更多标签")
        menu.autoenablesItems = false
        for index in hiddenIndices where tabs.indices.contains(index) {
            let tab = tabs[index]
            let item = NSMenuItem(
                title: tab.title,
                action: #selector(selectOverflowTab(_:)),
                keyEquivalent: ""
            )
            item.target = self
            item.tag = index
            item.isEnabled = true
            if index < 9 {
                item.keyEquivalent = String(index + 1)
                item.keyEquivalentModifierMask = .command
            }
            menu.addItem(item)
        }
        overflowButton.menu = menu
    }

    @objc private func newTab() { onNewTab?() }
    @objc private func toggleSidebar() { onToggleSidebar?() }
    @objc private func openSettings() { onSettings?() }

    @objc private func showOverflowMenu() {
        guard let menu = overflowButton.menu else { return }
        menu.popUp(
            positioning: nil,
            at: NSPoint(x: 0, y: overflowButton.bounds.minY),
            in: overflowButton
        )
    }

    @objc private func selectOverflowTab(_ sender: NSMenuItem) {
        guard let currentMenu = overflowButton.menu,
              sender.menu === currentMenu,
              tabs.indices.contains(sender.tag) else { return }
        onSelect?(sender.tag)
    }
}

/// 顶部栏低频操作：默认安静，悬停或设置页打开时显示 pill 背景。
@MainActor
private final class TabBarSettingsButton: NSButton {
    private var isHovered = false

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layer?.cornerRadius = InkDesignTokens.Radius.item
        layer?.cornerCurve = .continuous
        addTrackingArea(NSTrackingArea(
            rect: .zero,
            options: [.mouseEnteredAndExited, .activeInKeyWindow, .inVisibleRect],
            owner: self
        ))
        updateLayerColors()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("代码构建") }

    func setSelected(_ selected: Bool) {
        state = selected ? .on : .off
        updateLayerColors()
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        updateLayerColors()
    }

    override func mouseEntered(with event: NSEvent) {
        isHovered = true
        updateLayerColors()
    }

    override func mouseExited(with event: NSEvent) {
        isHovered = false
        updateLayerColors()
    }

    private func updateLayerColors() {
        effectiveAppearance.performAsCurrentDrawingAppearance {
            layer?.backgroundColor = state == .on || isHovered
                ? InkDesignTokens.Color.pill.cgColor
                : nil
        }
    }
}

/// 溢出入口沿用设置按钮的悬停视觉，但不保留选中态。
@MainActor
private final class TabBarOverflowButton: NSButton {
    private var isHovered = false

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layer?.cornerRadius = InkDesignTokens.Radius.item
        layer?.cornerCurve = .continuous
        addTrackingArea(NSTrackingArea(
            rect: .zero,
            options: [.mouseEnteredAndExited, .activeInKeyWindow, .inVisibleRect],
            owner: self
        ))
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("代码构建") }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        updateLayerColors()
    }

    override func mouseEntered(with event: NSEvent) {
        isHovered = true
        updateLayerColors()
    }

    override func mouseExited(with event: NSEvent) {
        isHovered = false
        updateLayerColors()
    }

    private func updateLayerColors() {
        effectiveAppearance.performAsCurrentDrawingAppearance {
            layer?.backgroundColor = isHovered
                ? InkDesignTokens.Color.pill.cgColor
                : nil
        }
    }
}

/// 单个标签：标题居中（路径头部截断）、⌘n 靠右、悬停出关闭钮、双击改名。
@MainActor
private final class TabItemView: NSView, NSTextFieldDelegate {

    var onSelect: (() -> Void)?
    var onClose: (() -> Void)?
    var onRename: ((String) -> Void)?

    private let titleLabel = NSTextField(labelWithString: "")
    private let shortcutLabel = NSTextField(labelWithString: "")
    private let closeButton = NSButton()
    private var editor: NSTextField?
    private let active: Bool

    var preferredWidth: CGFloat {
        let token = InkDesignTokens.TabBar.self
        let fixedWidth = InkDesignTokens.Spacing.xs * 2
            + token.closeButtonWidth
            + 8
            + shortcutLabel.intrinsicContentSize.width
        let measured = titleLabel.intrinsicContentSize.width + fixedWidth
        return min(max(measured, token.idealTabWidth), token.maximumTabWidth)
    }

    init(tab: TabBarView.Tab) {
        self.active = tab.active
        super.init(frame: .zero)
        wantsLayer = true
        layer?.cornerRadius = InkDesignTokens.Radius.item
        layer?.cornerCurve = .continuous
        updateLayerColors()

        titleLabel.stringValue = tab.title
        titleLabel.font = InkDesignTokens.Typography.body
        titleLabel.textColor = tab.active
            ? InkDesignTokens.Color.textPrimary
            : InkDesignTokens.Color.textSecondary
        titleLabel.alignment = .center
        titleLabel.lineBreakMode = .byTruncatingHead // 路径保尾部：.../work/code/ink
        titleLabel.translatesAutoresizingMaskIntoConstraints = false
        addSubview(titleLabel)

        shortcutLabel.stringValue = tab.shortcut
        shortcutLabel.font = InkDesignTokens.Typography.label
        shortcutLabel.textColor = InkDesignTokens.Color.textSecondary
        shortcutLabel.translatesAutoresizingMaskIntoConstraints = false
        addSubview(shortcutLabel)

        closeButton.isBordered = false
        closeButton.image = NSImage(systemSymbolName: "xmark", accessibilityDescription: "关闭标签")?
            .withSymbolConfiguration(.init(pointSize: 8, weight: .bold))
        closeButton.contentTintColor = InkDesignTokens.Color.textSecondary
        closeButton.target = self
        closeButton.action = #selector(closeTab)
        closeButton.isHidden = true
        closeButton.translatesAutoresizingMaskIntoConstraints = false
        addSubview(closeButton)

        let sp = InkDesignTokens.Spacing.self
        NSLayoutConstraint.activate([
            closeButton.leadingAnchor.constraint(equalTo: leadingAnchor, constant: sp.xs),
            closeButton.widthAnchor.constraint(equalToConstant: InkDesignTokens.TabBar.closeButtonWidth),
            closeButton.centerYAnchor.constraint(equalTo: centerYAnchor),
            titleLabel.centerXAnchor.constraint(equalTo: centerXAnchor),
            titleLabel.centerYAnchor.constraint(equalTo: centerYAnchor),
            titleLabel.leadingAnchor.constraint(greaterThanOrEqualTo: closeButton.trailingAnchor, constant: 4),
            titleLabel.trailingAnchor.constraint(lessThanOrEqualTo: shortcutLabel.leadingAnchor, constant: -4),
            shortcutLabel.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -sp.xs),
            shortcutLabel.centerYAnchor.constraint(equalTo: centerYAnchor),
        ])

        let tracking = NSTrackingArea(
            rect: .zero,
            options: [.mouseEnteredAndExited, .activeInKeyWindow, .inVisibleRect],
            owner: self
        )
        addTrackingArea(tracking)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("代码构建") }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        updateLayerColors()
    }

    private func updateLayerColors() {
        effectiveAppearance.performAsCurrentDrawingAppearance {
            layer?.backgroundColor = active ? InkDesignTokens.Color.pill.cgColor : nil
        }
    }

    override var mouseDownCanMoveWindow: Bool { false }

    override func mouseEntered(with event: NSEvent) {
        closeButton.isHidden = false
    }

    override func mouseExited(with event: NSEvent) {
        closeButton.isHidden = true
    }

    override func mouseDown(with event: NSEvent) {
        if event.clickCount == 2 {
            beginRename()
        } else {
            onSelect?()
        }
    }

    @objc private func closeTab() { onClose?() }

    // MARK: - 双击改名

    private func beginRename() {
        guard editor == nil else { return }
        let field = NSTextField(string: titleLabel.stringValue)
        field.font = InkDesignTokens.Typography.body
        field.alignment = .center
        field.isBordered = false
        field.backgroundColor = .clear
        field.focusRingType = .none
        field.delegate = self
        field.translatesAutoresizingMaskIntoConstraints = false
        addSubview(field)
        NSLayoutConstraint.activate([
            field.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 20),
            field.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -20),
            field.centerYAnchor.constraint(equalTo: centerYAnchor),
        ])
        titleLabel.isHidden = true
        editor = field
        window?.makeFirstResponder(field)
    }

    func controlTextDidEndEditing(_ notification: Notification) {
        guard let editor else { return }
        let name = editor.stringValue.trimmingCharacters(in: .whitespaces)
        editor.removeFromSuperview()
        self.editor = nil
        titleLabel.isHidden = false
        if !name.isEmpty, name != titleLabel.stringValue {
            onRename?(name)
        }
    }

    func control(_ control: NSControl, textView: NSTextView, doCommandBy selector: Selector) -> Bool {
        if selector == #selector(NSResponder.cancelOperation(_:)) {
            editor?.stringValue = titleLabel.stringValue // Esc 放弃
            window?.makeFirstResponder(nil)
            return true
        }
        if selector == #selector(NSResponder.insertNewline(_:)) {
            window?.makeFirstResponder(nil) // 回车提交（走 didEndEditing）
            return true
        }
        return false
    }
}
