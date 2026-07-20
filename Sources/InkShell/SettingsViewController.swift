import AppKit
import InkConfig
import InkDesign

/// 主窗口内嵌设置页。它只负责编辑 `InkConfig`，持久化与应用由窗口控制器统一处理。
@MainActor
final class SettingsViewController: NSViewController {

    var onChange: ((InkConfig) -> Void)?
    var onDone: (() -> Void)?
    var onOpenConfig: (() -> Void)?
    var onReset: (() -> Void)?

    private var config: InkConfig
    private var suppressChanges = false

    private let appearanceControl = NSSegmentedControl()
    private let sidebarControl = NSSegmentedControl()
    private let rememberFrameSwitch = NSSwitch()
    private let windowWidthControl = NumericSettingControl(
        value: 1280, range: 640...4096, increment: 20, decimals: 0, suffix: "pt"
    )
    private let windowHeightControl = NumericSettingControl(
        value: 800, range: 400...2160, increment: 20, decimals: 0, suffix: "pt"
    )
    private let fontCombo = NSComboBox()
    private let fontSizeControl = NumericSettingControl(
        value: 14, range: 6...72, increment: 1, decimals: 0, suffix: "pt"
    )
    private let lineHeightControl = NumericSettingControl(
        value: 1.2, range: 0.8...2, increment: 0.05, decimals: 2, suffix: "×"
    )
    private let cursorControl = NSSegmentedControl()
    private let cursorBlinkSwitch = NSSwitch()
    private let optionMetaSwitch = NSSwitch()
    private let copyOnSelectSwitch = NSSwitch()
    private let scrollbackControl = NumericSettingControl(
        value: 100_000, range: 100...2_000_000, increment: 1_000, decimals: 0, suffix: "行"
    )
    private let preview = TerminalSettingsPreview()

    init(config: InkConfig) {
        self.config = config
        super.init(nibName: nil, bundle: nil)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("代码构建") }

    override func loadView() {
        let root = SettingsRootView()
        root.wantsLayer = true
        root.onCancel = { [weak self] in self?.onDone?() }

        let header = makeHeader()
        let separator = NSBox()
        separator.boxType = .separator
        let scrollView = makeScrollView()

        for item in [header, separator, scrollView] {
            item.translatesAutoresizingMaskIntoConstraints = false
            root.addSubview(item)
        }
        NSLayoutConstraint.activate([
            header.topAnchor.constraint(equalTo: root.topAnchor),
            header.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            header.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            header.heightAnchor.constraint(equalToConstant: InkDesignTokens.Settings.headerHeight),
            separator.topAnchor.constraint(equalTo: header.bottomAnchor),
            separator.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            separator.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            scrollView.topAnchor.constraint(equalTo: separator.bottomAnchor),
            scrollView.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            scrollView.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            scrollView.bottomAnchor.constraint(equalTo: root.bottomAnchor),
        ])

        view = root
        configureControls()
        updateControls()
    }

    func update(config: InkConfig) {
        self.config = config
        guard isViewLoaded else { return }
        updateControls()
    }

    private func makeHeader() -> NSView {
        let header = NSView()
        let title = NSTextField(labelWithString: "设置")
        title.font = InkDesignTokens.Typography.title
        title.textColor = InkDesignTokens.Color.textPrimary

        let done = NSButton(title: "完成", target: self, action: #selector(doneAction))
        done.bezelStyle = .rounded
        done.keyEquivalent = "\r"

        title.translatesAutoresizingMaskIntoConstraints = false
        done.translatesAutoresizingMaskIntoConstraints = false
        header.addSubview(title)
        header.addSubview(done)

        NSLayoutConstraint.activate([
            title.leadingAnchor.constraint(equalTo: header.leadingAnchor, constant: InkDesignTokens.Spacing.md),
            title.centerYAnchor.constraint(equalTo: header.centerYAnchor),
            done.trailingAnchor.constraint(equalTo: header.trailingAnchor, constant: -InkDesignTokens.Spacing.md),
            done.centerYAnchor.constraint(equalTo: header.centerYAnchor),
        ])
        return header
    }

    private func makeScrollView() -> NSScrollView {
        let scroll = NSScrollView()
        scroll.drawsBackground = false
        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true

        let document = FlippedView()
        // 文档视图参与约束布局。漏掉这行时，零 frame 的文档会携带一条
        // required 的 width == 0 autoresizing 约束，经下方 width 等式传导到
        // 分栏内容列，AppKit 的窗口适配布局会把整个主窗口压到最小宽度。
        document.translatesAutoresizingMaskIntoConstraints = false
        let content = NSStackView()
        content.orientation = .vertical
        content.alignment = .leading
        content.spacing = InkDesignTokens.Spacing.lg
        content.translatesAutoresizingMaskIntoConstraints = false
        document.addSubview(content)

        let heading = NSTextField(labelWithString: "让 Ink 按你的工作方式运行")
        heading.font = InkDesignTokens.Typography.pageTitle
        heading.textColor = InkDesignTokens.Color.textPrimary
        content.addArrangedSubview(heading)

        let subtitle = NSTextField(wrappingLabelWithString: "更改会立即应用。配置仍保存在 ~/.config/ink/config.toml，手写注释和未知字段会被保留。")
        subtitle.font = InkDesignTokens.Typography.body
        subtitle.textColor = InkDesignTokens.Color.textSecondary
        content.addArrangedSubview(subtitle)

        content.addArrangedSubview(makeSection(
            title: "外观",
            rows: [
                makeRow(title: "界面模式", detail: "跟随系统会在 macOS 切换外观时实时更新。", control: appearanceControl),
                makeRow(title: "启动时侧边栏", detail: "选择下次打开 Ink 时的初始状态。", control: sidebarControl),
            ]
        ))
        content.addArrangedSubview(makeSection(
            title: "窗口",
            rows: [
                makeRow(title: "记住上次位置与大小", detail: "关闭后恢复当前窗口的 frame。", control: rememberFrameSwitch),
                makeRow(title: "默认宽度", detail: "关闭记忆窗口后，在下次启动时使用。", control: windowWidthControl),
                makeRow(title: "默认高度", detail: "关闭记忆窗口后，在下次启动时使用。", control: windowHeightControl),
            ]
        ))
        content.addArrangedSubview(makeSection(
            title: "终端",
            rows: [
                makeRow(title: "字体", detail: "只列出系统中可用的等宽字体。", control: fontCombo),
                makeRow(title: "字号", detail: nil, control: fontSizeControl),
                makeRow(title: "行高", detail: "调整字符行之间的呼吸感。", control: lineHeightControl),
                preview,
            ]
        ))
        content.addArrangedSubview(makeSection(
            title: "光标",
            rows: [
                makeRow(title: "形状", detail: nil, control: cursorControl),
                makeRow(title: "闪烁", detail: nil, control: cursorBlinkSwitch),
            ]
        ))
        content.addArrangedSubview(makeSection(
            title: "交互",
            rows: [
                makeRow(title: "Option 作为 Meta", detail: "关闭后保留 macOS 的重音字符输入。", control: optionMetaSwitch),
                makeRow(title: "选中即复制", detail: "鼠标选中文本后立即写入剪贴板。", control: copyOnSelectSwitch),
            ]
        ))
        content.addArrangedSubview(makeSection(
            title: "高级",
            rows: [
                makeRow(title: "回滚缓冲区", detail: "仅对新建会话生效。", control: scrollbackControl),
                makeActionsRow(),
            ]
        ))
        for item in content.arrangedSubviews {
            item.widthAnchor.constraint(equalTo: content.widthAnchor).isActive = true
        }

        scroll.documentView = document
        let preferredContentWidth = content.widthAnchor.constraint(
            equalToConstant: InkDesignTokens.Settings.contentWidth
        )
        preferredContentWidth.priority = .defaultHigh
        NSLayoutConstraint.activate([
            content.topAnchor.constraint(equalTo: document.topAnchor, constant: InkDesignTokens.Spacing.xl),
            content.bottomAnchor.constraint(equalTo: document.bottomAnchor, constant: -InkDesignTokens.Spacing.xl),
            content.centerXAnchor.constraint(equalTo: document.centerXAnchor),
            preferredContentWidth,
            content.widthAnchor.constraint(
                lessThanOrEqualToConstant: InkDesignTokens.Settings.contentWidth
            ),
            content.leadingAnchor.constraint(
                greaterThanOrEqualTo: document.leadingAnchor,
                constant: InkDesignTokens.Spacing.xl
            ),
            document.widthAnchor.constraint(equalTo: scroll.contentView.widthAnchor),
        ])

        return scroll
    }

    private func makeSection(title: String, rows: [NSView]) -> NSView {
        let container = NSStackView()
        container.orientation = .vertical
        container.alignment = .leading
        container.spacing = InkDesignTokens.Spacing.xs

        let label = NSTextField(labelWithString: title)
        label.font = InkDesignTokens.Typography.sectionTitle
        label.textColor = InkDesignTokens.Color.textSecondary
        container.addArrangedSubview(label)

        let panel = SettingsPanelView()
        let stack = NSStackView()
        stack.orientation = .vertical
        stack.spacing = 0
        stack.translatesAutoresizingMaskIntoConstraints = false
        panel.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.topAnchor.constraint(equalTo: panel.topAnchor),
            stack.leadingAnchor.constraint(equalTo: panel.leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: panel.trailingAnchor),
            stack.bottomAnchor.constraint(equalTo: panel.bottomAnchor),
        ])

        for (index, row) in rows.enumerated() {
            stack.addArrangedSubview(row)
            row.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true
            if index < rows.count - 1 {
                let divider = NSBox()
                divider.boxType = .separator
                stack.addArrangedSubview(divider)
                divider.leadingAnchor.constraint(
                    equalTo: stack.leadingAnchor,
                    constant: InkDesignTokens.Spacing.md
                ).isActive = true
            }
        }
        container.addArrangedSubview(panel)
        panel.widthAnchor.constraint(equalTo: container.widthAnchor).isActive = true
        return container
    }

    private func makeRow(title: String, detail: String?, control: NSView) -> NSView {
        let row = NSView()
        let labels = NSStackView()
        labels.orientation = .vertical
        labels.alignment = .leading
        labels.spacing = 2

        let titleLabel = NSTextField(labelWithString: title)
        titleLabel.font = InkDesignTokens.Typography.body
        titleLabel.textColor = InkDesignTokens.Color.textPrimary
        labels.addArrangedSubview(titleLabel)
        if let detail {
            let detailLabel = NSTextField(wrappingLabelWithString: detail)
            detailLabel.font = InkDesignTokens.Typography.label
            detailLabel.textColor = InkDesignTokens.Color.textSecondary
            labels.addArrangedSubview(detailLabel)
        }

        labels.translatesAutoresizingMaskIntoConstraints = false
        control.translatesAutoresizingMaskIntoConstraints = false
        row.addSubview(labels)
        row.addSubview(control)
        NSLayoutConstraint.activate([
            row.heightAnchor.constraint(greaterThanOrEqualToConstant: InkDesignTokens.Settings.rowMinimumHeight),
            labels.leadingAnchor.constraint(equalTo: row.leadingAnchor, constant: InkDesignTokens.Spacing.md),
            labels.centerYAnchor.constraint(equalTo: row.centerYAnchor),
            labels.trailingAnchor.constraint(lessThanOrEqualTo: control.leadingAnchor, constant: -InkDesignTokens.Spacing.md),
            control.trailingAnchor.constraint(equalTo: row.trailingAnchor, constant: -InkDesignTokens.Spacing.md),
            control.centerYAnchor.constraint(equalTo: row.centerYAnchor),
            control.widthAnchor.constraint(lessThanOrEqualToConstant: InkDesignTokens.Settings.controlWidth),
        ])
        return row
    }

    private func makeActionsRow() -> NSView {
        let row = NSView()
        let reset = NSButton(title: "恢复默认值…", target: self, action: #selector(resetAction))
        reset.bezelStyle = .rounded
        let open = NSButton(title: "打开 config.toml", target: self, action: #selector(openConfigAction))
        open.bezelStyle = .rounded

        let stack = NSStackView(views: [reset, NSView(), open])
        stack.orientation = .horizontal
        stack.alignment = .centerY
        stack.translatesAutoresizingMaskIntoConstraints = false
        row.addSubview(stack)
        NSLayoutConstraint.activate([
            row.heightAnchor.constraint(greaterThanOrEqualToConstant: InkDesignTokens.Settings.rowMinimumHeight),
            stack.leadingAnchor.constraint(equalTo: row.leadingAnchor, constant: InkDesignTokens.Spacing.md),
            stack.trailingAnchor.constraint(equalTo: row.trailingAnchor, constant: -InkDesignTokens.Spacing.md),
            stack.centerYAnchor.constraint(equalTo: row.centerYAnchor),
        ])
        return row
    }

    private func configureControls() {
        configureSegmented(appearanceControl, labels: ["跟随系统", "浅色", "深色"], action: #selector(controlChanged))
        configureSegmented(sidebarControl, labels: ["展开", "图标", "隐藏"], action: #selector(controlChanged))
        configureSegmented(cursorControl, labels: ["方块", "竖线", "下划线"], action: #selector(controlChanged))

        for toggle in [rememberFrameSwitch, cursorBlinkSwitch, optionMetaSwitch, copyOnSelectSwitch] {
            toggle.target = self
            toggle.action = #selector(controlChanged)
        }

        fontCombo.removeAllItems()
        fontCombo.addItem(withObjectValue: "系统等宽")
        let manager = NSFontManager.shared
        let families = manager.availableFontFamilies.filter { family in
            manager.font(
                withFamily: family,
                traits: [.fixedPitchFontMask],
                weight: 5,
                size: 14
            )?.isFixedPitch == true
        }
        fontCombo.addItems(withObjectValues: families.sorted())
        fontCombo.isEditable = false
        fontCombo.numberOfVisibleItems = 12
        fontCombo.target = self
        fontCombo.action = #selector(controlChanged)

        for number in [windowWidthControl, windowHeightControl, fontSizeControl, lineHeightControl, scrollbackControl] {
            number.onChange = { [weak self] in self?.controlChanged() }
        }
    }

    private func configureSegmented(
        _ control: NSSegmentedControl,
        labels: [String],
        action: Selector
    ) {
        control.segmentCount = labels.count
        control.segmentStyle = .rounded
        control.trackingMode = .selectOne
        for (index, label) in labels.enumerated() {
            control.setLabel(label, forSegment: index)
        }
        control.target = self
        control.action = action
    }

    private func updateControls() {
        suppressChanges = true
        appearanceControl.selectedSegment = switch config.appearanceMode {
        case .system: 0
        case .light: 1
        case .dark: 2
        }
        sidebarControl.selectedSegment = switch config.startupSidebarMode {
        case .expanded: 0
        case .compact: 1
        case .hidden: 2
        }
        rememberFrameSwitch.state = config.rememberWindowFrame ? .on : .off
        windowWidthControl.value = Double(config.windowWidth)
        windowHeightControl.value = Double(config.windowHeight)
        windowWidthControl.isEnabled = !config.rememberWindowFrame
        windowHeightControl.isEnabled = !config.rememberWindowFrame

        let family = config.fontFamily ?? ""
        if family.isEmpty {
            fontCombo.selectItem(at: 0)
        } else if let index = fontCombo.objectValues.firstIndex(where: { ($0 as? String) == family }) {
            fontCombo.selectItem(at: index)
        } else {
            fontCombo.stringValue = family
        }
        fontSizeControl.value = config.fontSize
        lineHeightControl.value = config.lineHeight
        cursorControl.selectedSegment = switch config.cursorStyle {
        case .block: 0
        case .bar: 1
        case .underline: 2
        }
        cursorBlinkSwitch.state = config.cursorBlink ? .on : .off
        optionMetaSwitch.state = config.optionAsMeta ? .on : .off
        copyOnSelectSwitch.state = config.copyOnSelect ? .on : .off
        scrollbackControl.value = Double(config.scrollbackLines)
        updatePreview()
        suppressChanges = false
    }

    @objc private func controlChanged() {
        guard !suppressChanges else { return }
        config.appearanceMode = [.system, .light, .dark][max(0, appearanceControl.selectedSegment)]
        config.startupSidebarMode = [.expanded, .compact, .hidden][max(0, sidebarControl.selectedSegment)]
        config.rememberWindowFrame = rememberFrameSwitch.state == .on
        config.windowWidth = Int(windowWidthControl.value.rounded())
        config.windowHeight = Int(windowHeightControl.value.rounded())
        let selectedFamily = fontCombo.stringValue
        config.fontFamily = selectedFamily == "系统等宽" || selectedFamily.isEmpty
            ? nil
            : selectedFamily
        config.fontSize = fontSizeControl.value
        config.lineHeight = lineHeightControl.value
        config.cursorStyle = [.block, .bar, .underline][max(0, cursorControl.selectedSegment)]
        config.cursorBlink = cursorBlinkSwitch.state == .on
        config.optionAsMeta = optionMetaSwitch.state == .on
        config.copyOnSelect = copyOnSelectSwitch.state == .on
        config.scrollbackLines = Int(scrollbackControl.value.rounded())
        windowWidthControl.isEnabled = !config.rememberWindowFrame
        windowHeightControl.isEnabled = !config.rememberWindowFrame
        updatePreview()
        onChange?(config)
    }

    private func updatePreview() {
        preview.update(
            family: config.fontFamily,
            size: CGFloat(config.fontSize),
            lineHeight: CGFloat(config.lineHeight)
        )
    }

    @objc private func doneAction() { onDone?() }
    @objc private func openConfigAction() { onOpenConfig?() }

    @objc private func resetAction() {
        guard let window = view.window else {
            onReset?()
            return
        }
        let alert = NSAlert()
        alert.messageText = "恢复默认设置？"
        alert.informativeText = "已知设置会恢复默认值，config.toml 中的注释和未知字段仍会保留。"
        alert.addButton(withTitle: "恢复默认值")
        alert.addButton(withTitle: "取消")
        alert.beginSheetModal(for: window) { [weak self] response in
            guard response == .alertFirstButtonReturn else { return }
            self?.onReset?()
        }
    }
}

@MainActor
private final class SettingsRootView: NSView {
    var onCancel: (() -> Void)?

    override var acceptsFirstResponder: Bool { true }

    override func cancelOperation(_ sender: Any?) {
        onCancel?()
    }
}

@MainActor
private final class FlippedView: NSView {
    override var isFlipped: Bool { true }
}

@MainActor
private final class SettingsPanelView: NSView {
    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layer?.cornerRadius = InkDesignTokens.Radius.panel
        layer?.cornerCurve = .continuous
        updateColor()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("代码构建") }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        updateColor()
    }

    private func updateColor() {
        effectiveAppearance.performAsCurrentDrawingAppearance {
            layer?.backgroundColor = InkDesignTokens.Color.elevated.cgColor
        }
    }
}

@MainActor
private final class NumericSettingControl: NSView, NSTextFieldDelegate {
    var onChange: (() -> Void)?

    var value: Double {
        get { field.doubleValue }
        set {
            field.doubleValue = min(max(newValue, range.lowerBound), range.upperBound)
            updateText()
        }
    }

    var isEnabled = true {
        didSet {
            field.isEnabled = isEnabled
            stepper.isEnabled = isEnabled
            suffixLabel.textColor = isEnabled
                ? InkDesignTokens.Color.textSecondary
                : InkDesignTokens.Color.textSecondary.withAlphaComponent(0.5)
        }
    }

    private let range: ClosedRange<Double>
    private let decimals: Int
    private let suffix: String
    private let field = NSTextField()
    private let stepper = NSStepper()
    private let suffixLabel = NSTextField(labelWithString: "")

    init(
        value: Double,
        range: ClosedRange<Double>,
        increment: Double,
        decimals: Int,
        suffix: String
    ) {
        self.range = range
        self.decimals = decimals
        self.suffix = suffix
        super.init(frame: .zero)

        field.alignment = .right
        field.delegate = self
        field.target = self
        field.action = #selector(commitValue)
        stepper.minValue = range.lowerBound
        stepper.maxValue = range.upperBound
        stepper.increment = increment
        stepper.target = self
        stepper.action = #selector(stepperChanged)
        suffixLabel.stringValue = suffix
        suffixLabel.font = InkDesignTokens.Typography.label
        suffixLabel.textColor = InkDesignTokens.Color.textSecondary

        let stack = NSStackView(views: [field, suffixLabel, stepper])
        stack.orientation = .horizontal
        stack.alignment = .centerY
        stack.spacing = InkDesignTokens.Spacing.xxs
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)
        NSLayoutConstraint.activate([
            stack.topAnchor.constraint(equalTo: topAnchor),
            stack.leadingAnchor.constraint(equalTo: leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: trailingAnchor),
            stack.bottomAnchor.constraint(equalTo: bottomAnchor),
            field.widthAnchor.constraint(equalToConstant: 76),
        ])
        self.value = value
        stepper.doubleValue = self.value
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("代码构建") }

    func controlTextDidEndEditing(_ obj: Notification) {
        commitValue()
    }

    @objc private func stepperChanged() {
        value = stepper.doubleValue
        onChange?()
    }

    @objc private func commitValue() {
        value = field.doubleValue
        stepper.doubleValue = value
        onChange?()
    }

    private func updateText() {
        field.stringValue = decimals == 0
            ? "\(Int(value.rounded()))"
            : String(format: "%.\(decimals)f", value)
        stepper.doubleValue = value
        setAccessibilityValue("\(field.stringValue) \(suffix)")
    }
}

@MainActor
private final class TerminalSettingsPreview: NSView {
    private let text = NSTextField(wrappingLabelWithString: "")

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layer?.cornerRadius = InkDesignTokens.Radius.control
        layer?.cornerCurve = .continuous
        text.translatesAutoresizingMaskIntoConstraints = false
        addSubview(text)
        NSLayoutConstraint.activate([
            heightAnchor.constraint(equalToConstant: InkDesignTokens.Settings.previewHeight),
            text.leadingAnchor.constraint(equalTo: leadingAnchor, constant: InkDesignTokens.Spacing.md),
            text.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -InkDesignTokens.Spacing.md),
            text.centerYAnchor.constraint(equalTo: centerYAnchor),
        ])
        updateBackground()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("代码构建") }

    func update(family: String?, size: CGFloat, lineHeight: CGFloat) {
        let manager = NSFontManager.shared
        let font = family.flatMap {
            manager.font(withFamily: $0, traits: [.fixedPitchFontMask], weight: 5, size: size)
        } ?? InkDesignTokens.Typography.terminal(size: size)
        let paragraph = NSMutableParagraphStyle()
        paragraph.lineHeightMultiple = lineHeight
        let sample = NSMutableAttributedString(
            string: "~/work/ink  main\n❯ echo \"你好，ink\"\n你好，ink",
            attributes: [
                .font: font,
                .foregroundColor: InkDesignTokens.Color.textPrimary,
                .paragraphStyle: paragraph,
            ]
        )
        sample.addAttribute(
            .foregroundColor,
            value: InkDesignTokens.Color.accent,
            range: NSRange(location: 17, length: 1)
        )
        text.attributedStringValue = sample
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        updateBackground()
    }

    private func updateBackground() {
        effectiveAppearance.performAsCurrentDrawingAppearance {
            layer?.backgroundColor = InkDesignTokens.Color.terminal.cgColor
        }
    }
}
