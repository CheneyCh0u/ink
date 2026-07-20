import AppKit
import InkConfig
import InkTerminalView
import TerminalCore

@MainActor
final class TerminalPaneContainerView: NSView {
    let paneID: PaneID
    let terminalView: TerminalMetalView

    var isActive = false {
        didSet { updateBorder() }
    }

    init(paneID: PaneID, terminalView: TerminalMetalView) {
        self.paneID = paneID
        self.terminalView = terminalView
        super.init(frame: .zero)
        wantsLayer = true
        terminalView.translatesAutoresizingMaskIntoConstraints = false
        addSubview(terminalView)
        NSLayoutConstraint.activate([
            terminalView.topAnchor.constraint(equalTo: topAnchor),
            terminalView.leadingAnchor.constraint(equalTo: leadingAnchor),
            terminalView.trailingAnchor.constraint(equalTo: trailingAnchor),
            terminalView.bottomAnchor.constraint(equalTo: bottomAnchor),
        ])
        updateBorder()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("代码构建，不支持 nib")
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        updateBorder()
    }

    private func updateBorder() {
        layer?.borderWidth = isActive ? 1 : 0
        layer?.borderColor = NSColor.controlAccentColor.cgColor
    }
}

/// 保存分组标识和权重，首次拿到有效 frame 后恢复所有 divider 位置。
@MainActor
final class WorkspaceSplitView: NSSplitView {
    let splitID: SplitID
    let modelWeights: [Double]
    var onFinishTracking: (() -> Void)?
    private var appliedInitialWeights = false

    init(splitID: SplitID, weights: [Double]) {
        self.splitID = splitID
        modelWeights = weights
        super.init(frame: .zero)
        dividerStyle = .thin
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("代码构建，不支持 nib")
    }

    override func layout() {
        super.layout()
        guard !appliedInitialWeights,
              subviews.count == modelWeights.count,
              subviews.count > 1 else { return }
        let length = isVertical ? bounds.width : bounds.height
        let available = length - dividerThickness * CGFloat(subviews.count - 1)
        guard available > 1 else { return }
        appliedInitialWeights = true
        var origin: CGFloat = 0
        for index in subviews.indices {
            let childLength = index == subviews.count - 1
                ? length - origin
                : available * CGFloat(modelWeights[index])
            subviews[index].frame = isVertical
                ? NSRect(x: origin, y: 0, width: childLength, height: bounds.height)
                : NSRect(x: 0, y: origin, width: bounds.width, height: childLength)
            origin += childLength + dividerThickness
        }
    }

    override func mouseDown(with event: NSEvent) {
        super.mouseDown(with: event)
        onFinishTracking?()
    }
}

/// 当前标签的可见终端工作区。后台标签只保留 TerminalTab，不保留 Metal 视图。
@MainActor
final class TerminalWorkspaceViewController: NSViewController {
    var onActivatePane: ((PaneID) -> Void)?
    var onWeightsChange: ((SplitID, [Double]) -> Void)?

    private weak var currentTab: TerminalTab?
    private var paneContainers: [PaneID: TerminalPaneContainerView] = [:]
    private weak var rootView: NSView?
    private var rootConstraints: [NSLayoutConstraint] = []

    override func loadView() {
        view = NSView(frame: .zero)
    }

    func show(tab: TerminalTab, config: InkConfig) {
        clearViews()
        currentTab = tab
        let root = makeView(for: tab.layout, tab: tab, config: config)
        rootView = root
        root.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(root)
        rootConstraints = [
            root.topAnchor.constraint(equalTo: view.topAnchor),
            root.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            root.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            root.bottomAnchor.constraint(equalTo: view.bottomAnchor),
        ]
        NSLayoutConstraint.activate(rootConstraints)
        updateActiveBorders()
    }

    func clear() {
        clearViews()
        currentTab = nil
    }

    func paneContainer(for paneID: PaneID) -> TerminalPaneContainerView? {
        paneContainers[paneID]
    }

    func terminalView(for paneID: PaneID) -> TerminalMetalView? {
        paneContainers[paneID]?.terminalView
    }

    func currentGridSize(for paneID: PaneID) -> TerminalSize? {
        terminalView(for: paneID)?.currentGridSize
    }

    func markDirty(_ paneID: PaneID) {
        terminalView(for: paneID)?.markDirty()
    }

    func activate(_ paneID: PaneID) {
        guard currentTab?.activate(paneID) == true else { return }
        updateActiveBorders()
        onActivatePane?(paneID)
    }

    func focusActivePane() {
        guard let paneID = currentTab?.activePaneID,
              let terminalView = terminalView(for: paneID) else { return }
        view.window?.makeFirstResponder(terminalView)
    }

    func apply(config: InkConfig) {
        for container in paneContainers.values {
            apply(config: config, to: container.terminalView)
        }
    }

    private func commitWeights(from splitView: WorkspaceSplitView) {
        guard splitView.subviews.count > 1 else { return }
        let length = splitView.isVertical ? splitView.bounds.width : splitView.bounds.height
        let available = length
            - splitView.dividerThickness * CGFloat(splitView.subviews.count - 1)
        guard available > 1 else { return }
        let weights = splitView.subviews.map { subview in
            Double((splitView.isVertical ? subview.frame.width : subview.frame.height) / available)
        }
        guard weights.allSatisfy({ $0.isFinite && $0 > 0 }) else { return }
        _ = currentTab?.updateSplitWeights(splitView.splitID, weights: weights)
        onWeightsChange?(splitView.splitID, weights)
    }

    private func makeView(
        for layout: PaneLayout,
        tab: TerminalTab,
        config: InkConfig
    ) -> NSView {
        switch layout {
        case let .leaf(paneID):
            guard let pane = tab.panes[paneID] else {
                preconditionFailure("布局引用了不存在的 pane")
            }
            let terminalView = TerminalMetalView(frame: .zero)
            apply(config: config, to: terminalView)
            terminalView.terminalProvider = { [weak session = pane.session] in
                session?.terminal
                    ?? Terminal(size: TerminalSize(columns: 1, rows: 1), scrollbackCapacity: 1)
            }
            terminalView.onInput = { [weak session = pane.session] data in
                session?.write(data)
            }
            terminalView.onGridResize = { [weak session = pane.session] size in
                session?.resize(to: size)
            }
            terminalView.onFocus = { [weak self] in self?.activate(paneID) }
            let container = TerminalPaneContainerView(paneID: paneID, terminalView: terminalView)
            paneContainers[paneID] = container
            return container

        case let .group(id, axis, weights, children):
            let splitView = WorkspaceSplitView(splitID: id, weights: weights)
            splitView.isVertical = axis == .leftRight
            for child in children {
                splitView.addArrangedSubview(makeView(for: child, tab: tab, config: config))
            }
            splitView.onFinishTracking = { [weak self, weak splitView] in
                guard let splitView else { return }
                self?.commitWeights(from: splitView)
            }
            return splitView
        }
    }

    private func clearViews() {
        for container in paneContainers.values {
            let terminalView = container.terminalView
            terminalView.onInput = nil
            terminalView.onGridResize = nil
            terminalView.terminalProvider = nil
            terminalView.onFocus = nil
        }
        paneContainers.removeAll()
        NSLayoutConstraint.deactivate(rootConstraints)
        rootConstraints.removeAll()
        rootView?.removeFromSuperview()
        rootView = nil
    }

    private func updateActiveBorders() {
        let showBorder = paneContainers.count > 1
        let activePaneID = currentTab?.activePaneID
        for (paneID, container) in paneContainers {
            container.isActive = showBorder && paneID == activePaneID
        }
    }

    private func apply(config: InkConfig, to terminalView: TerminalMetalView) {
        terminalView.fontFamily = config.fontFamily
        terminalView.lineHeightMultiplier = CGFloat(config.lineHeight)
        terminalView.fontSize = CGFloat(config.fontSize)
        terminalView.cursorStyle = switch config.cursorStyle {
        case .block: .block
        case .bar: .bar
        case .underline: .underline
        }
        terminalView.cursorBlinkEnabled = config.cursorBlink
        terminalView.optionAsMeta = config.optionAsMeta
        terminalView.copyOnSelect = config.copyOnSelect
    }
}
