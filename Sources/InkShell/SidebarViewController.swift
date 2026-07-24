import AppKit
import InkDesign

enum SidebarProjectDropIntent: Equatable {
    case reorder(Int)
    case importDirectories([URL])
    case reject
}

@MainActor
enum SidebarProjectDropDecoder {
    static func intent(from pasteboard: NSPasteboard) -> SidebarProjectDropIntent {
        if let raw = pasteboard.string(forType: SidebarViewController.dragType),
           let index = Int(raw) {
            return .reorder(index)
        }
        let urls = (pasteboard.readObjects(
            forClasses: [NSURL.self],
            options: [.urlReadingFileURLsOnly: true]
        ) as? [NSURL] ?? []).map { $0 as URL }
        let directories = ProjectDirectoryImportPlanner.validDirectories(from: urls)
        return directories.isEmpty ? .reject : .importDirectories(directories)
    }
}

enum ProjectLabelIndicatorStyle: Equatable {
    case dot
    case rail
}

/// 侧边栏：项目列表 + 底部操作行（新建项目、设置）。
///
/// 根视图直接承载系统 sidebar 材质，让背景从标题栏贯穿到底部。
/// 不使用系统 sidebar split item，避免新系统把侧栏变成浮动圆角面板。
/// 行是自绘的两行式，项目数量个位数，直接重建行比
/// NSTableView 的复用机制更简单。支持拖动排序（本地拖拽）、悬停关闭、
/// 右键置顶/备注。
@MainActor
final class SidebarViewController: NSViewController {

    enum DisplayMode {
        case expanded
        case compact

        var labelIndicatorStyle: ProjectLabelIndicatorStyle {
            switch self {
            case .expanded: .dot
            case .compact: .rail
            }
        }
    }

    struct Row {
        let title: String
        let detail: String
        let status: String
        let fullPath: String
        let active: Bool
        let pinned: Bool
        let label: InkProjectLabel
        let attention: TabAttention?

        init(
            title: String,
            detail: String,
            status: String,
            fullPath: String,
            active: Bool,
            pinned: Bool,
            label: InkProjectLabel,
            attention: TabAttention? = nil
        ) {
            self.title = title
            self.detail = detail
            self.status = status
            self.fullPath = fullPath
            self.active = active
            self.pinned = pinned
            self.label = label
            self.attention = attention
        }
    }

    var displayMode: DisplayMode = .expanded {
        didSet {
            guard displayMode != oldValue else { return }
            updateDisplayMode()
            rebuildRows()
        }
    }

    var onSelect: ((Int) -> Void)?
    var onNewProject: (() -> Void)?
    var onSettings: (() -> Void)?
    var onRemove: ((Int) -> Void)?
    var onTogglePin: ((Int) -> Void)?
    var onEditNote: ((Int) -> Void)?
    var onSetLabel: ((Int, InkProjectLabel) -> Void)?
    /// 拖动排序：把第 from 行移动到第 to 位。
    var onReorder: ((Int, Int) -> Void)?
    var onImportDirectories: (([URL]) -> Void)?

    static let dragType = NSPasteboard.PasteboardType("com.ink.project-row")

    private let rowStack = NSStackView()
    private let newButton = SidebarActionButton()
    private let settingsButton = SidebarActionButton()
    private let footerSeparator = NSBox()
    private let sectionTitle = NSTextField(labelWithString: "项目")
    private var rows: [Row] = []
    private var hoveredRowPath: String?
    private var expandedRowsTop: NSLayoutConstraint?
    private var compactRowsTop: NSLayoutConstraint?
    private var newButtonLeading: NSLayoutConstraint?
    private var settingsButtonTrailing: NSLayoutConstraint?

    override func loadView() {
        let root = ProjectDropView()
        root.material = InkDesignTokens.Sidebar.material
        root.blendingMode = InkDesignTokens.Sidebar.blendingMode
        root.state = .active
        root.isEmphasized = true
        root.rowStack = rowStack
        root.onDrop = { [weak self] from, to in self?.onReorder?(from, to) }
        root.onImportDirectories = { [weak self] in self?.onImportDirectories?($0) }

        rowStack.orientation = .vertical
        rowStack.spacing = 2
        rowStack.alignment = .leading
        rowStack.translatesAutoresizingMaskIntoConstraints = false

        sectionTitle.font = InkDesignTokens.Typography.label
        sectionTitle.textColor = InkDesignTokens.Color.textSecondary
        sectionTitle.translatesAutoresizingMaskIntoConstraints = false

        configureFooterButton(
            newButton,
            symbolName: "plus",
            toolTip: "新建项目",
            accessibilityLabel: "新建项目",
            action: #selector(newProject)
        )
        configureFooterButton(
            settingsButton,
            symbolName: "gearshape",
            toolTip: "设置（⌘,）",
            accessibilityLabel: "设置",
            action: #selector(openSettings)
        )

        footerSeparator.boxType = .separator
        footerSeparator.translatesAutoresizingMaskIntoConstraints = false

        root.addSubview(sectionTitle)
        root.addSubview(rowStack)
        root.addSubview(newButton)
        root.addSubview(settingsButton)
        root.addSubview(footerSeparator)

        let sp = InkDesignTokens.Spacing.self
        let expandedRowsTop = rowStack.topAnchor.constraint(
            equalTo: sectionTitle.bottomAnchor,
            constant: sp.xs
        )
        let compactRowsTop = rowStack.topAnchor.constraint(
            equalTo: root.safeAreaLayoutGuide.topAnchor,
            constant: sp.xs
        )
        self.expandedRowsTop = expandedRowsTop
        self.compactRowsTop = compactRowsTop
        let newButtonLeading = newButton.leadingAnchor.constraint(
            equalTo: root.leadingAnchor,
            constant: sp.xs
        )
        let settingsButtonTrailing = settingsButton.trailingAnchor.constraint(
            equalTo: root.trailingAnchor,
            constant: -sp.xs
        )
        self.newButtonLeading = newButtonLeading
        self.settingsButtonTrailing = settingsButtonTrailing
        NSLayoutConstraint.activate([
            // 跟随 safe area：系统已为标题栏/红绿灯留位，再叠固定值就是双重让位。
            sectionTitle.topAnchor.constraint(
                equalTo: root.safeAreaLayoutGuide.topAnchor,
                constant: sp.xs
            ),
            sectionTitle.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: sp.md),

            expandedRowsTop,
            rowStack.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: sp.xs),
            rowStack.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -sp.xs),

            footerSeparator.bottomAnchor.constraint(equalTo: newButton.topAnchor, constant: -sp.xs),
            newButtonLeading,
            newButton.bottomAnchor.constraint(equalTo: root.bottomAnchor, constant: -sp.sm),
            newButton.widthAnchor.constraint(
                equalToConstant: InkDesignTokens.Sidebar.footerButtonSize
            ),
            newButton.heightAnchor.constraint(
                equalToConstant: InkDesignTokens.Sidebar.footerButtonSize
            ),
            settingsButtonTrailing,
            settingsButton.centerYAnchor.constraint(equalTo: newButton.centerYAnchor),
            settingsButton.widthAnchor.constraint(
                equalToConstant: InkDesignTokens.Sidebar.footerButtonSize
            ),
            settingsButton.heightAnchor.constraint(
                equalToConstant: InkDesignTokens.Sidebar.footerButtonSize
            ),
            footerSeparator.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: sp.sm),
            footerSeparator.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -sp.sm),
        ])

        view = root
        updateDisplayMode()
    }

    /// 底部操作按钮统一为纯图标：文字进 tooltip，展开/图标态共用一套布局。
    private func configureFooterButton(
        _ button: SidebarActionButton,
        symbolName: String,
        toolTip: String,
        accessibilityLabel: String,
        action: Selector
    ) {
        button.title = ""
        button.image = NSImage(systemSymbolName: symbolName, accessibilityDescription: nil)?
            .withSymbolConfiguration(.init(pointSize: 13, weight: .medium))
        button.imagePosition = .imageOnly
        button.isBordered = false
        button.contentTintColor = InkDesignTokens.Color.textSecondary
        button.toolTip = toolTip
        button.setAccessibilityLabel(accessibilityLabel)
        button.target = self
        button.action = action
        button.layer?.cornerRadius = InkDesignTokens.Radius.item
        button.layer?.cornerCurve = .continuous
        button.translatesAutoresizingMaskIntoConstraints = false
    }

    func setSettingsSelected(_ selected: Bool) {
        settingsButton.isSelectedState = selected
    }

    func reload(rows: [Row]) {
        self.rows = rows
        if let hoveredRowPath,
           !rows.contains(where: { $0.fullPath == hoveredRowPath }) {
            self.hoveredRowPath = nil
        }
        rebuildRows()
    }

    private func rebuildRows() {
        guard isViewLoaded else { return }
        rowStack.arrangedSubviews.forEach { $0.removeFromSuperview() }
        for (index, row) in rows.enumerated() {
            let rowView = ProjectRowView(
                row: row,
                index: index,
                compact: displayMode == .compact,
                indicatorStyle: displayMode.labelIndicatorStyle,
                revealsCloseButton: row.fullPath == hoveredRowPath
            )
            rowView.onClick = { [weak self] in self?.onSelect?(index) }
            rowView.onRemove = { [weak self] in self?.onRemove?(index) }
            rowView.onTogglePin = { [weak self] in self?.onTogglePin?(index) }
            rowView.onEditNote = { [weak self] in self?.onEditNote?(index) }
            rowView.onSetLabel = { [weak self] label in self?.onSetLabel?(index, label) }
            rowView.onHoverChanged = { [weak self] hovered in
                guard let self else { return }
                if hovered {
                    self.hoveredRowPath = row.fullPath
                } else if self.hoveredRowPath == row.fullPath {
                    self.hoveredRowPath = nil
                }
            }
            rowStack.addArrangedSubview(rowView)
            rowView.widthAnchor.constraint(equalTo: rowStack.widthAnchor).isActive = true
        }
    }

    private func updateDisplayMode() {
        guard isViewLoaded else { return }
        let compact = displayMode == .compact
        sectionTitle.isHidden = compact
        expandedRowsTop?.isActive = !compact
        compactRowsTop?.isActive = compact
        // 图标态宽度只有 72pt，两枚 28pt 按钮按 xs 边距会贴死，收紧到 xxs 留出间隙。
        let footerInset = compact ? InkDesignTokens.Spacing.xxs : InkDesignTokens.Spacing.xs
        newButtonLeading?.constant = footerInset
        settingsButtonTrailing?.constant = -footerInset
    }

    @objc private func newProject() { onNewProject?() }
    @objc private func openSettings() { onSettings?() }
}

/// 承接项目行拖拽的容器：按落点 y 算插入位置。
@MainActor
final class ProjectDropView: NSVisualEffectView {
    weak var rowStack: NSStackView?
    var onDrop: ((Int, Int) -> Void)?
    var onImportDirectories: (([URL]) -> Void)?

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        registerForDraggedTypes([SidebarViewController.dragType, .fileURL])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("代码构建") }

    /// 侧栏空白区域与标题栏一样可以拖动窗口。
    override var mouseDownCanMoveWindow: Bool { true }

    override func draggingEntered(_ sender: any NSDraggingInfo) -> NSDragOperation {
        operation(for: SidebarProjectDropDecoder.intent(from: sender.draggingPasteboard))
    }

    override func draggingUpdated(_ sender: any NSDraggingInfo) -> NSDragOperation {
        operation(for: SidebarProjectDropDecoder.intent(from: sender.draggingPasteboard))
    }

    private func operation(for intent: SidebarProjectDropIntent) -> NSDragOperation {
        switch intent {
        case .reorder: .move
        case .importDirectories: .copy
        case .reject: []
        }
    }

    override func performDragOperation(_ sender: any NSDraggingInfo) -> Bool {
        switch SidebarProjectDropDecoder.intent(from: sender.draggingPasteboard) {
        case let .importDirectories(directories):
            onImportDirectories?(directories)
            return true
        case let .reorder(from):
            return performReorder(from: from, sender: sender)
        case .reject:
            return false
        }
    }

    private func performReorder(from: Int, sender: any NSDraggingInfo) -> Bool {
        guard let rows = rowStack?.arrangedSubviews, !rows.isEmpty else { return false }
        let point = convert(sender.draggingLocation, from: nil)
        var target = rows.count - 1
        for (index, row) in rows.enumerated() {
            let frame = row.convert(row.bounds, to: self)
            if point.y < frame.midY { // isFlipped == false：y 向上
                continue
            }
            target = index
            break
        }
        if target != from {
            onDrop?(from, target)
        }
        return true
    }
}

/// 展开态是两行项目卡片；图标态复用同一交互，只保留图标与颜色轨道。
@MainActor
private final class ProjectRowView: NSView, NSDraggingSource {

    var onClick: (() -> Void)?
    var onRemove: (() -> Void)?
    var onTogglePin: (() -> Void)?
    var onEditNote: (() -> Void)?
    var onSetLabel: ((InkProjectLabel) -> Void)?
    var onHoverChanged: ((Bool) -> Void)?

    private let index: Int
    private let pinned: Bool
    private let active: Bool
    private let label: InkProjectLabel
    private let compact: Bool
    private let closeButton = NSButton()
    private var mouseDownPoint: NSPoint?
    private var didDrag = false

    init(
        row: SidebarViewController.Row,
        index: Int,
        compact: Bool,
        indicatorStyle: ProjectLabelIndicatorStyle,
        revealsCloseButton: Bool
    ) {
        self.index = index
        self.pinned = row.pinned
        self.active = row.active
        self.label = row.label
        self.compact = compact
        super.init(frame: .zero)
        wantsLayer = true
        layer?.cornerRadius = InkDesignTokens.Radius.item
        layer?.cornerCurve = .continuous
        updateLayerColors()
        let attentionToolTip = row.attention.map { "\n\($0.presentation.toolTip)" } ?? ""
        toolTip = compact
            ? "\(row.fullPath)\n\(row.status)\(attentionToolTip)"
            : "\(row.fullPath)\(attentionToolTip)"
        setAccessibilityElement(true)
        setAccessibilityRole(.button)
        setAccessibilityLabel(row.fullPath)

        let icon = NSImageView(image: NSImage(
            systemSymbolName: row.pinned ? "pin.fill" : "folder",
            accessibilityDescription: nil
        )!)
        icon.contentTintColor = row.active
            ? InkDesignTokens.Color.textPrimary
            : InkDesignTokens.Color.textSecondary

        let indicator = ProjectLabelIndicator(label: row.label, style: indicatorStyle)
        indicator.translatesAutoresizingMaskIntoConstraints = false
        let attentionImage = Self.attentionImage(for: row.attention)

        if compact {
            icon.translatesAutoresizingMaskIntoConstraints = false
            addSubview(icon)
            addSubview(indicator)
            if let attentionImage { addSubview(attentionImage) }
            NSLayoutConstraint.activate([
                heightAnchor.constraint(equalToConstant: InkDesignTokens.Sidebar.projectRowHeight),
                icon.centerXAnchor.constraint(equalTo: centerXAnchor),
                icon.centerYAnchor.constraint(equalTo: centerYAnchor),
                indicator.leadingAnchor.constraint(
                    equalTo: leadingAnchor,
                    constant: InkDesignTokens.Sidebar.labelRailInset
                ),
                indicator.centerYAnchor.constraint(equalTo: centerYAnchor),
                indicator.widthAnchor.constraint(
                    equalToConstant: InkDesignTokens.Sidebar.labelRailWidth
                ),
                indicator.heightAnchor.constraint(
                    equalToConstant: InkDesignTokens.Sidebar.labelRailHeight
                ),
            ])
            if let attentionImage {
                NSLayoutConstraint.activate([
                    attentionImage.centerXAnchor.constraint(equalTo: icon.trailingAnchor),
                    attentionImage.centerYAnchor.constraint(equalTo: icon.bottomAnchor),
                    attentionImage.widthAnchor.constraint(equalToConstant: 12),
                    attentionImage.heightAnchor.constraint(equalToConstant: 12),
                ])
            }
            installTrackingArea()
            return
        }

        let title = NSTextField(labelWithString: row.title)
        title.font = InkDesignTokens.Typography.bodyEmphasized
        title.textColor = InkDesignTokens.Color.textPrimary
        title.lineBreakMode = .byTruncatingTail
        title.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)

        let detail = NSTextField(labelWithString: row.detail)
        detail.font = InkDesignTokens.Typography.label
        detail.textColor = InkDesignTokens.Color.textSecondary
        detail.lineBreakMode = .byTruncatingHead
        detail.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)

        let status = NSTextField(labelWithString: row.status)
        status.font = InkDesignTokens.Typography.label
        status.textColor = InkDesignTokens.Color.textSecondary
        status.alignment = .right
        status.setContentHuggingPriority(.required, for: .horizontal)
        status.setContentCompressionResistancePriority(.required, for: .horizontal)

        closeButton.isBordered = false
        closeButton.image = NSImage(systemSymbolName: "xmark", accessibilityDescription: "移除项目")?
            .withSymbolConfiguration(.init(pointSize: 8, weight: .bold))
        closeButton.contentTintColor = InkDesignTokens.Color.textSecondary
        closeButton.target = self
        closeButton.action = #selector(removeAction)
        closeButton.isHidden = false
        closeButton.translatesAutoresizingMaskIntoConstraints = false
        setCloseButtonRevealed(revealsCloseButton)

        var metadataViews: [NSView] = [detail]
        if let attentionImage {
            metadataViews.append(attentionImage)
            attentionImage.widthAnchor.constraint(equalToConstant: 12).isActive = true
            attentionImage.heightAnchor.constraint(equalToConstant: 12).isActive = true
        }
        metadataViews.append(status)
        let metadataStack = NSStackView(views: metadataViews)
        metadataStack.orientation = .horizontal
        metadataStack.alignment = .centerY
        metadataStack.spacing = InkDesignTokens.Spacing.xs
        metadataStack.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)

        let textStack = NSStackView(views: [title, metadataStack])
        textStack.orientation = .vertical
        textStack.alignment = .leading
        textStack.spacing = 1
        textStack.setContentHuggingPriority(.defaultLow, for: .horizontal)
        textStack.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)

        for subview in [indicator, icon, textStack, closeButton] {
            subview.translatesAutoresizingMaskIntoConstraints = false
            addSubview(subview)
        }

        let sp = InkDesignTokens.Spacing.self
        NSLayoutConstraint.activate([
            indicator.leadingAnchor.constraint(equalTo: leadingAnchor, constant: sp.xs),
            indicator.centerYAnchor.constraint(equalTo: centerYAnchor),
            indicator.widthAnchor.constraint(equalToConstant: InkDesignTokens.Sidebar.labelDotDiameter),
            indicator.heightAnchor.constraint(equalToConstant: InkDesignTokens.Sidebar.labelDotDiameter),

            icon.leadingAnchor.constraint(equalTo: indicator.trailingAnchor, constant: sp.xs),
            icon.centerYAnchor.constraint(equalTo: centerYAnchor),
            icon.widthAnchor.constraint(equalToConstant: 16),
            icon.heightAnchor.constraint(equalToConstant: 16),

            closeButton.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -sp.xs),
            closeButton.centerYAnchor.constraint(equalTo: centerYAnchor),
            closeButton.widthAnchor.constraint(
                equalToConstant: InkDesignTokens.Sidebar.projectCloseButtonWidth
            ),

            textStack.leadingAnchor.constraint(equalTo: icon.trailingAnchor, constant: sp.xs),
            textStack.trailingAnchor.constraint(equalTo: closeButton.leadingAnchor, constant: -sp.xs),
            textStack.topAnchor.constraint(equalTo: topAnchor, constant: 6),
            textStack.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -6),
            title.widthAnchor.constraint(equalTo: textStack.widthAnchor),
            metadataStack.widthAnchor.constraint(equalTo: textStack.widthAnchor),
        ])

        installTrackingArea()
    }

    private static func attentionImage(for attention: TabAttention?) -> NSImageView? {
        guard let presentation = attention?.presentation else { return nil }
        let view = NSImageView(image: NSImage(
            systemSymbolName: presentation.symbolName,
            accessibilityDescription: presentation.accessibilityLabel
        )!)
        view.contentTintColor = presentation.tintColor
        view.toolTip = presentation.toolTip
        view.setAccessibilityLabel(presentation.accessibilityLabel)
        view.translatesAutoresizingMaskIntoConstraints = false
        return view
    }

    private func installTrackingArea() {
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

    private func updateLayerColors() {
        effectiveAppearance.performAsCurrentDrawingAppearance {
            layer?.backgroundColor = active ? InkDesignTokens.Color.selected.cgColor : nil
        }
    }

    private func setCloseButtonRevealed(_ revealed: Bool) {
        closeButton.alphaValue = revealed ? 1 : 0
        closeButton.isEnabled = revealed
        closeButton.setAccessibilityHidden(!revealed)
    }

    override func mouseEntered(with event: NSEvent) {
        if !compact {
            setCloseButtonRevealed(true)
            onHoverChanged?(true)
        }
    }

    override func mouseExited(with event: NSEvent) {
        if !compact { setCloseButtonRevealed(false) }
        onHoverChanged?(false)
    }

    // 点击选中放到 mouseUp，给拖拽让路。
    override func mouseDown(with event: NSEvent) {
        mouseDownPoint = event.locationInWindow
        didDrag = false
    }

    override func mouseUp(with event: NSEvent) {
        if !didDrag { onClick?() }
        mouseDownPoint = nil
    }

    override func mouseDragged(with event: NSEvent) {
        guard let start = mouseDownPoint, !didDrag,
              abs(event.locationInWindow.y - start.y) > 4 else { return }
        didDrag = true

        let item = NSPasteboardItem()
        item.setString("\(index)", forType: SidebarViewController.dragType)
        let dragItem = NSDraggingItem(pasteboardWriter: item)
        let snapshot = snapshotImage()
        dragItem.setDraggingFrame(bounds, contents: snapshot)
        beginDraggingSession(with: [dragItem], event: event, source: self)
    }

    private func snapshotImage() -> NSImage {
        guard let rep = bitmapImageRepForCachingDisplay(in: bounds) else {
            return NSImage(size: bounds.size)
        }
        cacheDisplay(in: bounds, to: rep)
        let image = NSImage(size: bounds.size)
        image.addRepresentation(rep)
        return image
    }

    nonisolated func draggingSession(
        _ session: NSDraggingSession, sourceOperationMaskFor context: NSDraggingContext
    ) -> NSDragOperation {
        context == .withinApplication ? .move : []
    }

    override func rightMouseDown(with event: NSEvent) {
        let menu = NSMenu()
        let pin = NSMenuItem(
            title: pinned ? "取消置顶" : "置顶",
            action: #selector(pinAction), keyEquivalent: ""
        )
        pin.target = self
        menu.addItem(pin)
        let note = NSMenuItem(title: "编辑备注…", action: #selector(noteAction), keyEquivalent: "")
        note.target = self
        menu.addItem(note)

        let labelItem = NSMenuItem(title: "颜色标记", action: nil, keyEquivalent: "")
        let labelMenu = NSMenu(title: "颜色标记")
        for (tag, option) in InkProjectLabel.allCases.enumerated() {
            let item = NSMenuItem(
                title: option.title,
                action: #selector(labelAction(_:)),
                keyEquivalent: ""
            )
            item.target = self
            item.tag = tag
            item.state = option == label ? .on : .off
            item.image = Self.labelMenuImage(for: option)
            labelMenu.addItem(item)
        }
        labelItem.submenu = labelMenu
        menu.addItem(labelItem)

        menu.addItem(.separator())
        let remove = NSMenuItem(title: "移除项目", action: #selector(removeAction), keyEquivalent: "")
        remove.target = self
        menu.addItem(remove)
        NSMenu.popUpContextMenu(menu, with: event, for: self)
    }

    @objc private func removeAction() { onRemove?() }
    @objc private func pinAction() { onTogglePin?() }
    @objc private func noteAction() { onEditNote?() }

    @objc private func labelAction(_ sender: NSMenuItem) {
        guard InkProjectLabel.allCases.indices.contains(sender.tag) else { return }
        onSetLabel?(InkProjectLabel.allCases[sender.tag])
    }

    private static func labelMenuImage(for label: InkProjectLabel) -> NSImage? {
        guard let color = InkDesignTokens.ProjectLabel.color(for: label) else { return nil }
        return NSImage(size: NSSize(width: 12, height: 12), flipped: false) { rect in
            color.setFill()
            NSBezierPath(ovalIn: rect.insetBy(dx: 2, dy: 2)).fill()
            return true
        }
    }
}

@MainActor
final class ProjectLabelIndicator: NSView {
    private let label: InkProjectLabel
    private let style: ProjectLabelIndicatorStyle

    var drawsColor: Bool { label != .none }

    init(label: InkProjectLabel, style: ProjectLabelIndicatorStyle) {
        self.label = label
        self.style = style
        super.init(frame: .zero)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("代码构建") }

    override func draw(_ dirtyRect: NSRect) {
        guard let color = InkDesignTokens.ProjectLabel.color(for: label) else { return }
        color.setFill()
        switch style {
        case .dot:
            NSBezierPath(ovalIn: bounds).fill()
        case .rail:
            NSBezierPath(
                roundedRect: bounds,
                xRadius: bounds.width / 2,
                yRadius: bounds.width / 2
            ).fill()
        }
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        needsDisplay = true
    }
}

/// 底部操作按钮的背景是 layer 色，外观变化时需要重新解析动态 NSColor。
@MainActor
private final class SidebarActionButton: NSButton {

    private var hovered = false
    var isSelectedState = false {
        didSet { updateLayerColor() }
    }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        updateLayerColor()
        addTrackingArea(NSTrackingArea(
            rect: .zero,
            options: [.mouseEnteredAndExited, .activeInKeyWindow, .inVisibleRect],
            owner: self
        ))
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("代码构建") }

    /// SF Symbol 会给按钮带上不对称的 alignment insets，导致约束约出的
    /// frame 比 28×28 高且不居中；归零后 hover pill 才是正方形。
    override var alignmentRectInsets: NSEdgeInsets {
        NSEdgeInsets(top: 0, left: 0, bottom: 0, right: 0)
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        updateLayerColor()
    }

    override func mouseEntered(with event: NSEvent) {
        hovered = true
        updateLayerColor()
    }

    override func mouseExited(with event: NSEvent) {
        hovered = false
        updateLayerColor()
    }

    private func updateLayerColor() {
        effectiveAppearance.performAsCurrentDrawingAppearance {
            layer?.backgroundColor =
                if isSelectedState {
                    InkDesignTokens.Color.selected.cgColor
                } else if hovered {
                    InkDesignTokens.Color.pill.cgColor
                } else {
                    nil
                }
        }
    }
}
