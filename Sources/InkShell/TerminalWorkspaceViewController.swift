import AppKit
import InkConfig
import InkDesign
import InkTerminalView
import TerminalCore

@MainActor
final class TerminalPaneContainerView: NSView, WorkspaceSplitMinimumSizing {
    let paneID: PaneID
    let terminalView: TerminalMetalView

    var isActive = false {
        didSet { updateBorder() }
    }

    var minimumSplitSize: NSSize {
        terminalView.minimumViewportSize(columns: 10, rows: 3)
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

/// 当前标签的可见终端工作区。后台标签只保留 TerminalTab，不保留 Metal 视图。
@MainActor
final class TerminalWorkspaceViewController: NSViewController {
    var onActivatePane: ((PaneID) -> Void)?
    var onWeightsChange: ((SplitID, [Double]) -> Void)?

    private weak var currentTab: TerminalTab?
    private var paneContainers: [PaneID: TerminalPaneContainerView] = [:]
    private weak var rootView: NSView?
    private var rootConstraints: [NSLayoutConstraint] = []
    private var searchController: TerminalSearchController?
    private(set) var activeSearchPaneID: PaneID?

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

    private var activeTerminalView: TerminalMetalView? {
        guard let paneID = currentTab?.activePaneID else { return nil }
        return terminalView(for: paneID)
    }

    @discardableResult
    func previousCommandInActivePane() -> Bool {
        activeTerminalView?.navigateToPreviousCommand() ?? false
    }

    @discardableResult
    func nextCommandInActivePane() -> Bool {
        activeTerminalView?.navigateToNextCommand() ?? false
    }

    @discardableResult
    func copyCommandInActivePane() -> Bool {
        activeTerminalView?.copyCurrentCommand() ?? false
    }

    @discardableResult
    func copyCommandOutputInActivePane() -> Bool {
        activeTerminalView?.copyCurrentCommandOutput() ?? false
    }

    var canPerformCommandBlockAction: Bool {
        activeTerminalView?.hasCommandBlocks ?? false
    }

    func refreshSearch(for paneID: PaneID) {
        guard activeSearchPaneID == paneID else { return }
        searchController?.scheduleRefreshForTerminalUpdate()
    }

    @discardableResult
    func openSearchInActivePane() -> Bool {
        guard let tab = currentTab else { return false }
        let paneID = tab.activePaneID
        guard let pane = tab.panes[paneID],
              let container = paneContainers[paneID]
        else { return false }

        if activeSearchPaneID == paneID, let searchController {
            searchController.searchBar.focus()
            return true
        }

        closeSearch(returnFocus: false)
        let controller = TerminalSearchController(
            terminalProvider: { [weak session = pane.session] in
                session?.terminal
                    ?? Terminal(size: TerminalSize(columns: 1, rows: 1), scrollbackCapacity: 1)
            },
            terminalView: container.terminalView
        )
        controller.onClose = { [weak self] in self?.closeSearch(returnFocus: true) }
        searchController = controller
        activeSearchPaneID = paneID

        let searchBar = controller.searchBar
        searchBar.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(searchBar)
        NSLayoutConstraint.activate([
            searchBar.topAnchor.constraint(
                equalTo: container.topAnchor,
                constant: InkDesignTokens.Spacing.xs
            ),
            searchBar.trailingAnchor.constraint(
                equalTo: container.trailingAnchor,
                constant: -InkDesignTokens.Spacing.xs
            ),
        ])
        searchBar.focus()
        return true
    }

    func canOpenSearch(for responder: NSResponder?) -> Bool {
        if let responder = responder as? TerminalMetalView {
            return paneContainers.values.contains { $0.terminalView === responder }
        }
        return searchController?.searchBar.ownsResponder(responder) == true
    }

    @discardableResult
    func openSearch(for responder: NSResponder?) -> Bool {
        if searchController?.searchBar.ownsResponder(responder) == true {
            searchController?.searchBar.focus()
            return true
        }
        guard let terminalView = responder as? TerminalMetalView,
              let paneID = paneContainers.first(where: {
                  $0.value.terminalView === terminalView
              })?.key
        else { return false }
        activate(paneID)
        return openSearchInActivePane()
    }

    func closeSearch(returnFocus: Bool = true) {
        guard let controller = searchController else { return }
        let paneID = activeSearchPaneID
        searchController = nil
        activeSearchPaneID = nil
        controller.onClose = nil
        controller.close()
        controller.searchBar.removeFromSuperview()
        if returnFocus, let paneID, let terminalView = terminalView(for: paneID) {
            view.window?.makeFirstResponder(terminalView)
        }
    }

    func activate(_ paneID: PaneID) {
        guard currentTab?.activePaneID != paneID,
              currentTab?.activate(paneID) == true else { return }
        updateActiveBorders()
        onActivatePane?(paneID)
    }

    func canFocusNeighbor(direction: PaneSplitDirection) -> Bool {
        currentTab?.canFocusNeighbor(direction: direction) ?? false
    }

    @discardableResult
    func focusNeighbor(direction: PaneSplitDirection) -> Bool {
        guard currentTab?.focusNeighbor(direction: direction) == true,
              let paneID = currentTab?.activePaneID else { return false }
        updateActiveBorders()
        onActivatePane?(paneID)
        focusActivePane()
        return true
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
            terminalView.onOpenLink = { url in
                NSWorkspace.shared.open(url)
            }
            let container = TerminalPaneContainerView(paneID: paneID, terminalView: terminalView)
            paneContainers[paneID] = container
            return container

        case let .group(id, axis, weights, children):
            let splitView = WorkspaceSplitContainerView(
                splitID: id, axis: axis, weights: weights
            )
            for child in children {
                splitView.addPaneSubview(makeView(for: child, tab: tab, config: config))
            }
            splitView.onWeightsChange = { [weak self] splitID, weights in
                _ = self?.currentTab?.updateSplitWeights(splitID, weights: weights)
                self?.onWeightsChange?(splitID, weights)
            }
            return splitView
        }
    }

    private func clearViews() {
        closeSearch(returnFocus: false)
        for container in paneContainers.values {
            let terminalView = container.terminalView
            terminalView.onInput = nil
            terminalView.onGridResize = nil
            terminalView.terminalProvider = nil
            terminalView.onFocus = nil
            terminalView.onOpenLink = nil
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
        terminalView.apply(fontConfiguration: TerminalFontConfiguration(
            fontFamily: config.fontFamily,
            fontSize: CGFloat(config.fontSize),
            lineHeightMultiplier: CGFloat(config.lineHeight),
            cellHeightAdjustment: config.fontCellHeightAdjustment,
            fontThicken: config.fontThicken,
            fontThickenStrength: config.fontThickenStrength
        ))
        terminalView.terminalTheme =
            InkTerminalTheme(rawValue: config.terminalTheme.rawValue) ?? .neutral
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
