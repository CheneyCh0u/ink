import AppKit
import InkDesign

/// 侧边栏：项目列表 + 底部新建按钮。
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
    }

    struct Row {
        let title: String
        let subtitle: String
        let active: Bool
        let pinned: Bool
        let label: InkProjectLabel
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
    var onRemove: ((Int) -> Void)?
    var onTogglePin: ((Int) -> Void)?
    var onEditNote: ((Int) -> Void)?
    var onSetLabel: ((Int, InkProjectLabel) -> Void)?
    /// 拖动排序：把第 from 行移动到第 to 位。
    var onReorder: ((Int, Int) -> Void)?

    static let dragType = NSPasteboard.PasteboardType("com.ink.project-row")

    private let rowStack = NSStackView()
    private let newButton = SidebarActionButton()
    private let sectionTitle = NSTextField(labelWithString: "项目")
    private let shortcutHint = NSTextField(labelWithString: "⌘N")
    private var rows: [Row] = []
    private var expandedRowsTop: NSLayoutConstraint?
    private var compactRowsTop: NSLayoutConstraint?

    override func loadView() {
        let root = ProjectDropView()
        root.material = InkDesignTokens.Sidebar.material
        root.blendingMode = InkDesignTokens.Sidebar.blendingMode
        root.state = .active
        root.isEmphasized = true
        root.rowStack = rowStack
        root.onDrop = { [weak self] from, to in self?.onReorder?(from, to) }

        rowStack.orientation = .vertical
        rowStack.spacing = 2
        rowStack.alignment = .leading
        rowStack.translatesAutoresizingMaskIntoConstraints = false

        sectionTitle.font = InkDesignTokens.Typography.label
        sectionTitle.textColor = InkDesignTokens.Color.textSecondary
        sectionTitle.translatesAutoresizingMaskIntoConstraints = false

        newButton.title = "新建项目"
        newButton.target = self
        newButton.action = #selector(newProject)
        newButton.image = NSImage(systemSymbolName: "plus", accessibilityDescription: nil)
        newButton.imagePosition = .imageLeading
        newButton.isBordered = false
        newButton.font = InkDesignTokens.Typography.body
        newButton.contentTintColor = InkDesignTokens.Color.textSecondary
        newButton.alignment = .left
        newButton.layer?.cornerRadius = InkDesignTokens.Radius.item
        newButton.layer?.cornerCurve = .continuous
        newButton.translatesAutoresizingMaskIntoConstraints = false

        shortcutHint.font = InkDesignTokens.Typography.label
        shortcutHint.textColor = InkDesignTokens.Color.textSecondary
        shortcutHint.translatesAutoresizingMaskIntoConstraints = false

        root.addSubview(sectionTitle)
        root.addSubview(rowStack)
        root.addSubview(newButton)
        root.addSubview(shortcutHint)

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

            newButton.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: sp.sm),
            newButton.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -sp.sm),
            newButton.bottomAnchor.constraint(equalTo: root.bottomAnchor, constant: -sp.sm),
            newButton.heightAnchor.constraint(equalToConstant: InkDesignTokens.Sidebar.actionHeight),
            shortcutHint.centerYAnchor.constraint(equalTo: newButton.centerYAnchor),
            shortcutHint.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -sp.md),
        ])

        view = root
        updateDisplayMode()
    }

    func reload(rows: [Row]) {
        self.rows = rows
        rebuildRows()
    }

    private func rebuildRows() {
        guard isViewLoaded else { return }
        rowStack.arrangedSubviews.forEach { $0.removeFromSuperview() }
        for (index, row) in rows.enumerated() {
            let rowView = ProjectRowView(
                row: row,
                index: index,
                compact: displayMode == .compact
            )
            rowView.onClick = { [weak self] in self?.onSelect?(index) }
            rowView.onRemove = { [weak self] in self?.onRemove?(index) }
            rowView.onTogglePin = { [weak self] in self?.onTogglePin?(index) }
            rowView.onEditNote = { [weak self] in self?.onEditNote?(index) }
            rowView.onSetLabel = { [weak self] label in self?.onSetLabel?(index, label) }
            rowStack.addArrangedSubview(rowView)
            rowView.widthAnchor.constraint(equalTo: rowStack.widthAnchor).isActive = true
        }
    }

    private func updateDisplayMode() {
        guard isViewLoaded else { return }
        let compact = displayMode == .compact
        sectionTitle.isHidden = compact
        shortcutHint.isHidden = compact
        expandedRowsTop?.isActive = !compact
        compactRowsTop?.isActive = compact
        newButton.title = compact ? "" : "新建项目"
        newButton.imagePosition = compact ? .imageOnly : .imageLeading
        newButton.alignment = compact ? .center : .left
        newButton.toolTip = compact ? "新建项目" : nil
        newButton.setAccessibilityLabel("新建项目")
    }

    @objc private func newProject() { onNewProject?() }
}

/// 承接项目行拖拽的容器：按落点 y 算插入位置。
@MainActor
private final class ProjectDropView: NSVisualEffectView {
    weak var rowStack: NSStackView?
    var onDrop: ((Int, Int) -> Void)?

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        registerForDraggedTypes([SidebarViewController.dragType])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("代码构建") }

    /// 侧栏空白区域与标题栏一样可以拖动窗口。
    override var mouseDownCanMoveWindow: Bool { true }

    override func draggingEntered(_ sender: any NSDraggingInfo) -> NSDragOperation { .move }
    override func draggingUpdated(_ sender: any NSDraggingInfo) -> NSDragOperation { .move }

    override func performDragOperation(_ sender: any NSDraggingInfo) -> Bool {
        guard
            let raw = sender.draggingPasteboard.string(forType: SidebarViewController.dragType),
            let from = Int(raw),
            let rows = rowStack?.arrangedSubviews, !rows.isEmpty
        else { return false }

        let point = convert(sender.draggingLocation, from: nil)
        var target = rows.count - 1
        for (i, row) in rows.enumerated() {
            let frame = row.convert(row.bounds, to: self)
            if point.y < frame.midY { // isFlipped == false：y 向上
                continue
            }
            target = i
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

    private let index: Int
    private let pinned: Bool
    private let active: Bool
    private let label: InkProjectLabel
    private let compact: Bool
    private let closeButton = NSButton()
    private var mouseDownPoint: NSPoint?
    private var didDrag = false

    init(row: SidebarViewController.Row, index: Int, compact: Bool) {
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
        toolTip = compact ? "\(row.title)\n\(row.subtitle)" : nil
        setAccessibilityElement(true)
        setAccessibilityRole(.button)
        setAccessibilityLabel(row.title)

        let icon = NSImageView(image: NSImage(
            systemSymbolName: row.pinned ? "pin.fill" : "folder",
            accessibilityDescription: nil
        )!)
        icon.contentTintColor = row.active
            ? InkDesignTokens.Color.textPrimary
            : InkDesignTokens.Color.textSecondary

        let indicator = ProjectLabelIndicator(
            label: row.label,
            style: compact ? .rail : .dot
        )

        if compact {
            icon.translatesAutoresizingMaskIntoConstraints = false
            indicator.translatesAutoresizingMaskIntoConstraints = false
            addSubview(icon)
            addSubview(indicator)
            NSLayoutConstraint.activate([
                heightAnchor.constraint(equalToConstant: InkDesignTokens.Sidebar.projectRowHeight),
                icon.centerXAnchor.constraint(equalTo: centerXAnchor),
                icon.centerYAnchor.constraint(equalTo: centerYAnchor),
                indicator.leadingAnchor.constraint(equalTo: leadingAnchor),
                indicator.centerYAnchor.constraint(equalTo: centerYAnchor),
                indicator.widthAnchor.constraint(
                    equalToConstant: InkDesignTokens.Sidebar.labelRailWidth
                ),
                indicator.heightAnchor.constraint(
                    equalToConstant: InkDesignTokens.Sidebar.labelRailHeight
                ),
            ])
            installTrackingArea()
            return
        }

        let title = NSTextField(labelWithString: row.title)
        title.font = InkDesignTokens.Typography.bodyEmphasized
        title.textColor = InkDesignTokens.Color.textPrimary
        title.lineBreakMode = .byTruncatingHead

        let subtitle = NSTextField(labelWithString: row.subtitle)
        subtitle.font = InkDesignTokens.Typography.label
        subtitle.textColor = InkDesignTokens.Color.textSecondary
        subtitle.lineBreakMode = .byTruncatingTail

        closeButton.isBordered = false
        closeButton.image = NSImage(systemSymbolName: "xmark", accessibilityDescription: "移除项目")?
            .withSymbolConfiguration(.init(pointSize: 8, weight: .bold))
        closeButton.contentTintColor = InkDesignTokens.Color.textSecondary
        closeButton.target = self
        closeButton.action = #selector(removeAction)
        closeButton.isHidden = true

        let textStack = NSStackView(views: [title, subtitle])
        textStack.orientation = .vertical
        textStack.alignment = .leading
        textStack.spacing = 1

        let hStack = NSStackView(views: [indicator, icon, textStack, NSView(), closeButton])
        hStack.orientation = .horizontal
        hStack.alignment = .centerY
        hStack.spacing = InkDesignTokens.Spacing.xs
        hStack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(hStack)

        let sp = InkDesignTokens.Spacing.self
        NSLayoutConstraint.activate([
            hStack.topAnchor.constraint(equalTo: topAnchor, constant: 6),
            hStack.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -6),
            hStack.leadingAnchor.constraint(equalTo: leadingAnchor, constant: sp.xs),
            hStack.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -sp.xs),
            indicator.widthAnchor.constraint(
                equalToConstant: InkDesignTokens.Sidebar.labelDotSize
            ),
            indicator.heightAnchor.constraint(
                equalToConstant: InkDesignTokens.Sidebar.labelDotSize
            ),
        ])

        installTrackingArea()
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

    override func mouseEntered(with event: NSEvent) {
        if !compact { closeButton.isHidden = false }
    }

    override func mouseExited(with event: NSEvent) {
        closeButton.isHidden = true
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
private final class ProjectLabelIndicator: NSView {
    enum Style {
        case dot
        case rail
    }

    private let label: InkProjectLabel
    private let style: Style

    init(label: InkProjectLabel, style: Style) {
        self.label = label
        self.style = style
        super.init(frame: .zero)
        wantsLayer = true
        isHidden = label == .none
        updateColor()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("代码构建") }

    override func layout() {
        super.layout()
        layer?.cornerRadius = style == .dot
            ? bounds.width / 2
            : InkDesignTokens.Radius.pill
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        updateColor()
    }

    private func updateColor() {
        effectiveAppearance.performAsCurrentDrawingAppearance {
            layer?.backgroundColor = InkDesignTokens.ProjectLabel.color(for: label)?.cgColor
        }
    }
}

/// 底部操作按钮的背景是 layer 色，外观变化时需要重新解析动态 NSColor。
@MainActor
private final class SidebarActionButton: NSButton {

    private var hovered = false

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
            layer?.backgroundColor = hovered ? InkDesignTokens.Color.pill.cgColor : nil
        }
    }
}
