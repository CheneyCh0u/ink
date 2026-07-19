import AppKit
import InkDesign

/// 侧边栏：会话列表 + 底部新建按钮。
///
/// 材质由 NSSplitViewController 的 sidebar item 提供（系统 vibrancy），
/// 这里只放内容。行是自绘的两行式（标题 + 状态 + ⌘n 快捷键提示），
/// 会话数量个位数，直接重建行比 NSTableView 的复用机制更简单。
@MainActor
final class SidebarViewController: NSViewController {

    struct Row {
        let title: String
        let subtitle: String
        let active: Bool
    }

    var onSelect: ((Int) -> Void)?
    var onNewProject: (() -> Void)?
    var onRemove: ((Int) -> Void)?

    private let rowStack = NSStackView()

    override func loadView() {
        let root = NSView()

        rowStack.orientation = .vertical
        rowStack.spacing = 2
        rowStack.alignment = .leading
        rowStack.translatesAutoresizingMaskIntoConstraints = false

        let title = NSTextField(labelWithString: "项目")
        title.font = InkDesignTokens.Typography.label
        title.textColor = InkDesignTokens.Color.textSecondary
        title.translatesAutoresizingMaskIntoConstraints = false

        let newButton = NSButton(title: "新建项目", target: self, action: #selector(newProject))
        newButton.image = NSImage(systemSymbolName: "plus", accessibilityDescription: nil)
        newButton.imagePosition = .imageLeading
        newButton.isBordered = false
        newButton.font = InkDesignTokens.Typography.body
        newButton.contentTintColor = InkDesignTokens.Color.textSecondary
        newButton.translatesAutoresizingMaskIntoConstraints = false

        let shortcutHint = NSTextField(labelWithString: "⌘N")
        shortcutHint.font = InkDesignTokens.Typography.label
        shortcutHint.textColor = InkDesignTokens.Color.textSecondary
        shortcutHint.translatesAutoresizingMaskIntoConstraints = false

        let separator = NSBox()
        separator.boxType = .separator
        separator.translatesAutoresizingMaskIntoConstraints = false

        root.addSubview(title)
        root.addSubview(rowStack)
        root.addSubview(separator)
        root.addSubview(newButton)
        root.addSubview(shortcutHint)

        let sp = InkDesignTokens.Spacing.self
        NSLayoutConstraint.activate([
            // 跟随 safe area：系统已为标题栏/红绿灯留位，再叠固定值就是双重让位。
            title.topAnchor.constraint(equalTo: root.safeAreaLayoutGuide.topAnchor, constant: sp.xs),
            title.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: sp.md),

            rowStack.topAnchor.constraint(equalTo: title.bottomAnchor, constant: sp.xs),
            rowStack.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: sp.xs),
            rowStack.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -sp.xs),

            separator.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            separator.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            separator.bottomAnchor.constraint(equalTo: newButton.topAnchor, constant: -sp.xs),

            newButton.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: sp.md),
            newButton.bottomAnchor.constraint(equalTo: root.bottomAnchor, constant: -sp.sm),
            shortcutHint.centerYAnchor.constraint(equalTo: newButton.centerYAnchor),
            shortcutHint.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -sp.md),
        ])

        view = root
    }

    func reload(rows: [Row]) {
        rowStack.arrangedSubviews.forEach { $0.removeFromSuperview() }
        for (index, row) in rows.enumerated() {
            let rowView = SessionRowView(row: row, shortcut: index < 9 ? "⌘\(index + 1)" : "")
            rowView.onClick = { [weak self] in self?.onSelect?(index) }
            rowView.onRemove = { [weak self] in self?.onRemove?(index) }
            rowStack.addArrangedSubview(rowView)
            rowView.widthAnchor.constraint(equalTo: rowStack.widthAnchor).isActive = true
        }
    }

    @objc private func newProject() { onNewProject?() }
}

/// 两行式会话行：标题 + 状态，右侧 ⌘n。选中态圆角底。
@MainActor
private final class SessionRowView: NSView {

    var onClick: (() -> Void)?
    var onRemove: (() -> Void)?

    init(row: SidebarViewController.Row, shortcut: String) {
        super.init(frame: .zero)
        wantsLayer = true
        layer?.cornerRadius = InkDesignTokens.Radius.item
        layer?.cornerCurve = .continuous
        if row.active {
            layer?.backgroundColor = InkDesignTokens.Color.selected.cgColor
            // 白色高光浮在材质上，需要一道极浅的影子给出边界。
            layer?.masksToBounds = false
            layer?.shadowColor = NSColor.black.cgColor
            layer?.shadowOpacity = 0.10
            layer?.shadowRadius = 2
            layer?.shadowOffset = CGSize(width: 0, height: -1)
        }

        let icon = NSImageView(image: NSImage(
            systemSymbolName: "folder", accessibilityDescription: nil
        )!)
        icon.contentTintColor = row.active
            ? InkDesignTokens.Color.textPrimary
            : InkDesignTokens.Color.textSecondary

        let title = NSTextField(labelWithString: row.title)
        title.font = InkDesignTokens.Typography.bodyEmphasized
        title.textColor = InkDesignTokens.Color.textPrimary
        title.lineBreakMode = .byTruncatingTail

        let subtitle = NSTextField(labelWithString: row.subtitle)
        subtitle.font = InkDesignTokens.Typography.label
        subtitle.textColor = InkDesignTokens.Color.textSecondary

        let keys = NSTextField(labelWithString: shortcut)
        keys.font = InkDesignTokens.Typography.label
        keys.textColor = InkDesignTokens.Color.textSecondary

        let textStack = NSStackView(views: [title, subtitle])
        textStack.orientation = .vertical
        textStack.alignment = .leading
        textStack.spacing = 1

        let hStack = NSStackView(views: [icon, textStack, NSView(), keys])
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
        ])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("代码构建") }

    override func mouseDown(with event: NSEvent) {
        onClick?()
    }

    override func rightMouseDown(with event: NSEvent) {
        let menu = NSMenu()
        let item = NSMenuItem(title: "移除项目", action: #selector(removeAction), keyEquivalent: "")
        item.target = self
        menu.addItem(item)
        NSMenu.popUpContextMenu(menu, with: event, for: self)
    }

    @objc private func removeAction() {
        onRemove?()
    }
}
