import AppKit
import InkConfig
import InkDesign
import InkTerminalView
import QuartzCore
import TerminalCore

enum SidebarDisplayMode: Equatable {
    case expanded
    case compact
    case hidden

    var next: Self {
        switch self {
        case .expanded: .compact
        case .compact: .hidden
        case .hidden: .expanded
        }
    }
}

/// 主窗口：项目侧边栏 + 标签栏 + 可递归分屏的终端内容区。
///
/// 结构：侧边栏列项目，标签栏列当前项目的标签，每个标签包含一个或多个 pane。
/// 只有当前标签创建 Metal 视图，后台标签只保留 PTY、grid 与 scrollback。
@MainActor
public final class MainWindowController: NSWindowController, NSWindowDelegate, NSMenuItemValidation {

    private let splitVC = ShellSplitViewController()
    private var sidebarItem: NSSplitViewItem?
    private let sidebarVC = SidebarViewController()
    private let tabBar = TabBarView()
    private let workspaceVC = TerminalWorkspaceViewController()
    private let contentRoot = NSView()
    private let terminalWorkspace = NSView()
    private lazy var settingsVC = SettingsViewController(config: config)

    private var projects: [Project] = []
    private var activeProjectIndex = 0
    private var lastChromeSignature = ""
    private var firstSessionScheduled = false
    private var config = InkConfig.load()
    private var configWatcher: ConfigWatcher?
    private var sidebarMode: SidebarDisplayMode = .expanded
    private var isShowingSettings = false
    private var isSettingsViewInstalled = false
    private var splitShortcutState = SplitShortcutState()
    private var splitShortcutMonitor: Any?

    private var activeProject: Project? {
        projects.indices.contains(activeProjectIndex) ? projects[activeProjectIndex] : nil
    }

    public convenience init() {
        let initialConfig = InkConfig.load()
        let window = NSWindow(
            contentRect: NSRect(
                x: 0,
                y: 0,
                width: initialConfig.rememberWindowFrame
                    ? 1280
                    : initialConfig.windowWidth,
                height: initialConfig.rememberWindowFrame
                    ? 800
                    : initialConfig.windowHeight
            ),
            styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        window.titlebarAppearsTransparent = true
        window.titleVisibility = .hidden
        window.titlebarSeparatorStyle = .none
        window.backgroundColor = InkDesignTokens.Color.canvas
        window.minSize = NSSize(width: 520, height: 320)
        self.init(window: window)
        config = initialConfig
        window.delegate = self
        loadProjects()
        buildContent()
        installSplitShortcutMonitor()
        applyConfig(config)
        // 配置热重载：~/.config/ink/config.toml 保存即生效。
        configWatcher = ConfigWatcher { [weak self] fresh in
            self?.config = fresh
            self?.applyConfig(fresh)
            self?.settingsVC.update(config: fresh)
        }
        if initialConfig.rememberWindowFrame {
            window.setFrameAutosaveName("InkMainWindow")
            if !window.setFrameUsingName("InkMainWindow") {
                window.center()
            }
        } else {
            window.center()
        }
    }

    private func applyConfig(_ config: InkConfig) {
        NSApplication.shared.appearance =
            switch config.appearanceMode {
            case .system: nil
            case .light: NSAppearance(named: .aqua)
            case .dark: NSAppearance(named: .darkAqua)
            }
        workspaceVC.apply(config: config)
        if config.rememberWindowFrame {
            window?.setFrameAutosaveName("InkMainWindow")
        } else {
            window?.setFrameAutosaveName("")
        }
        // scrollbackLines 只对新会话生效：改已有 Terminal 的环形容量
        // 需要整体搬迁，不值得为配置热改付这个复杂度。
    }

    // MARK: - 项目持久化

    private func loadProjects() {
        projects = ProjectStore.load()
        if projects.isEmpty {
            projects = [Project(directory: FileManager.default.homeDirectoryForCurrentUser)]
        }
        sortPinnedFirst()
        // 恢复上次的活动项目。
        if let last = ProjectStore.activeProjectPath,
           let index = projects.firstIndex(where: { $0.displayName == last }) {
            activeProjectIndex = index
        }
    }

    private func persistProjects() {
        ProjectStore.save(projects)
        ProjectStore.activeProjectPath = activeProject?.displayName
    }

    /// 不变式：置顶块永远在顶部（组内保持相对顺序）。
    private func sortPinnedFirst() {
        let active = activeProject
        let pinned = projects.filter(\.pinned)
        let rest = projects.filter { !$0.pinned }
        projects = pinned + rest
        if let active, let index = projects.firstIndex(where: { $0 === active }) {
            activeProjectIndex = index
        }
    }

    // MARK: - 组装

    private func buildContent() {
        guard let window else { return }

        let contentVC = NSViewController()
        let hairline = NSBox()
        hairline.boxType = .separator
        terminalWorkspace.translatesAutoresizingMaskIntoConstraints = false
        tabBar.translatesAutoresizingMaskIntoConstraints = false
        let workspaceView = workspaceVC.view
        workspaceView.translatesAutoresizingMaskIntoConstraints = false
        hairline.translatesAutoresizingMaskIntoConstraints = false
        contentRoot.addSubview(tabBar)
        contentRoot.addSubview(hairline)
        contentRoot.addSubview(terminalWorkspace)
        terminalWorkspace.addSubview(workspaceView)
        NSLayoutConstraint.activate([
            tabBar.topAnchor.constraint(equalTo: contentRoot.topAnchor),
            tabBar.leadingAnchor.constraint(equalTo: contentRoot.leadingAnchor),
            tabBar.trailingAnchor.constraint(equalTo: contentRoot.trailingAnchor),
            tabBar.heightAnchor.constraint(equalToConstant: 38),
            hairline.topAnchor.constraint(equalTo: tabBar.bottomAnchor),
            hairline.leadingAnchor.constraint(equalTo: contentRoot.leadingAnchor),
            hairline.trailingAnchor.constraint(equalTo: contentRoot.trailingAnchor),

            terminalWorkspace.topAnchor.constraint(equalTo: hairline.bottomAnchor),
            terminalWorkspace.leadingAnchor.constraint(equalTo: contentRoot.leadingAnchor),
            terminalWorkspace.trailingAnchor.constraint(equalTo: contentRoot.trailingAnchor),
            terminalWorkspace.bottomAnchor.constraint(equalTo: contentRoot.bottomAnchor),

            workspaceView.topAnchor.constraint(equalTo: terminalWorkspace.topAnchor),
            workspaceView.leadingAnchor.constraint(equalTo: terminalWorkspace.leadingAnchor),
            workspaceView.trailingAnchor.constraint(equalTo: terminalWorkspace.trailingAnchor),
            workspaceView.bottomAnchor.constraint(equalTo: terminalWorkspace.bottomAnchor),
        ])
        contentVC.view = contentRoot

        // 不用 sidebarWithViewController：macOS 26 会把它渲染成带圆角的
        // 浮动面板，与窗口脱节。普通 split item 配合侧栏自己的系统材质，
        // 才能让雾面背景从标题栏贯穿到底部。
        let sidebarItem = NSSplitViewItem(viewController: sidebarVC)
        sidebarItem.minimumThickness = InkDesignTokens.Sidebar.minimumExpandedWidth
        sidebarItem.maximumThickness = InkDesignTokens.Sidebar.maximumExpandedWidth
        sidebarItem.canCollapse = true
        sidebarItem.holdingPriority = NSLayoutConstraint.Priority(261)
        self.sidebarItem = sidebarItem
        splitVC.splitView.dividerStyle = .thin
        splitVC.addSplitViewItem(sidebarItem)
        let contentItem = NSSplitViewItem(viewController: contentVC)
        contentItem.holdingPriority = NSLayoutConstraint.Priority(250)
        splitVC.addSplitViewItem(contentItem)
        window.contentViewController = splitVC
        splitVC.onLayoutChange = { [weak self] in
            guard let self else { return }
            self.updateTabBarInset()
        }
        splitVC.onToggleSidebar = { [weak self] in self?.toggleSidebarMode() }
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            let mode: SidebarDisplayMode =
                switch self.config.startupSidebarMode {
                case .expanded: .expanded
                case .compact: .compact
                case .hidden: .hidden
                }
            self.setSidebarMode(mode, animated: false)
        }

        // 事件接线。
        tabBar.onSelect = { [weak self] in self?.selectTab(at: $0) }
        tabBar.onClose = { [weak self] index in
            self?.closeTab(at: index)
        }
        tabBar.onRename = { [weak self] index, name in
            guard let self, let project = self.activeProject,
                  project.tabs.indices.contains(index) else { return }
            project.tabs[index].customName = name
            self.refreshChrome()
        }
        tabBar.onNewTab = { [weak self] in self?.newSession(nil) }
        tabBar.onToggleSidebar = { [weak self] in self?.toggleSidebarMode() }
        tabBar.onSettings = { [weak self] in
            guard let self else { return }
            if self.isShowingSettings {
                self.hideSettings()
            } else {
                self.showSettings(nil)
            }
        }
        sidebarVC.onSelect = { [weak self] in self?.selectProject(at: $0) }
        sidebarVC.onNewProject = { [weak self] in self?.newProject(nil) }
        sidebarVC.onRemove = { [weak self] in self?.removeProject(at: $0) }
        sidebarVC.onTogglePin = { [weak self] in self?.togglePin(at: $0) }
        sidebarVC.onEditNote = { [weak self] in self?.editNote(at: $0) }
        sidebarVC.onSetLabel = { [weak self] index, label in
            self?.setProjectLabel(label, at: index)
        }
        sidebarVC.onReorder = { [weak self] from, to in self?.reorderProject(from: from, to: to) }
        settingsVC.onChange = { [weak self] fresh in self?.saveConfig(fresh) }
        settingsVC.onDone = { [weak self] in self?.hideSettings() }
        settingsVC.onOpenConfig = { [weak self] in self?.openConfigFile() }
        settingsVC.onReset = { [weak self] in self?.saveConfig(InkConfig()) }
        workspaceVC.onActivatePane = { [weak self] _ in self?.refreshChrome() }

        if activeProject?.tabs.isEmpty ?? true, !firstSessionScheduled {
            firstSessionScheduled = true
            DispatchQueue.main.async { [weak self] in self?.newSession(nil) }
        }
    }

    private func saveConfig(_ fresh: InkConfig) {
        do {
            try fresh.save()
            config = fresh
            applyConfig(fresh)
            settingsVC.update(config: fresh)
        } catch {
            guard let window else { return }
            NSAlert(error: error).beginSheetModal(for: window)
        }
    }

    private func openConfigFile() {
        do {
            try config.save()
            NSWorkspace.shared.open(InkConfig.defaultURL)
        } catch {
            guard let window else { return }
            NSAlert(error: error).beginSheetModal(for: window)
        }
    }

    @objc public func showSettings(_ sender: Any?) {
        guard !isShowingSettings else { return }
        cancelSplitShortcut()
        workspaceVC.closeSearch(returnFocus: false)
        installSettingsViewIfNeeded()
        isShowingSettings = true
        tabBar.setSettingsSelected(true)
        settingsVC.update(config: config)
        terminalWorkspace.isHidden = true
        settingsVC.view.isHidden = false
        window?.makeFirstResponder(settingsVC.view)
        refreshChrome()
    }

    private func installSettingsViewIfNeeded() {
        guard !isSettingsViewInstalled else { return }
        let settingsView = settingsVC.view
        settingsView.translatesAutoresizingMaskIntoConstraints = false
        settingsView.isHidden = true
        contentRoot.addSubview(settingsView)
        NSLayoutConstraint.activate([
            settingsView.topAnchor.constraint(equalTo: terminalWorkspace.topAnchor),
            settingsView.leadingAnchor.constraint(equalTo: contentRoot.leadingAnchor),
            settingsView.trailingAnchor.constraint(equalTo: contentRoot.trailingAnchor),
            settingsView.bottomAnchor.constraint(equalTo: contentRoot.bottomAnchor),
        ])
        isSettingsViewInstalled = true
    }

    private func hideSettings() {
        guard isShowingSettings else { return }
        isShowingSettings = false
        tabBar.setSettingsSelected(false)
        settingsVC.view.isHidden = true
        terminalWorkspace.isHidden = false
        workspaceVC.focusActivePane()
        refreshChrome()
    }

    private func toggleSidebarMode() {
        setSidebarMode(sidebarMode.next, animated: true)
    }

    private func setSidebarMode(_ mode: SidebarDisplayMode, animated: Bool) {
        guard let sidebarItem else { return }
        sidebarMode = mode
        sidebarVC.displayMode = mode == .compact ? .compact : .expanded
        tabBar.setSidebarMode(mode)
        updateTabBarInset()

        let reduceMotion = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
        let shouldAnimate = animated && !reduceMotion
        let duration = shouldAnimate ? InkDesignTokens.Motion.stateDuration : 0

        switch mode {
        case .expanded:
            sidebarItem.canCollapse = true
            sidebarItem.minimumThickness = InkDesignTokens.Sidebar.compactWidth
            sidebarItem.maximumThickness = InkDesignTokens.Sidebar.maximumExpandedWidth
            applySidebarGeometry(
                collapsed: false,
                position: InkDesignTokens.Sidebar.width,
                duration: duration
            )
        case .compact:
            // NSSplitView 会把“位置 == 最小宽度”当作折叠阈值。图标态关闭
            // 系统自动折叠，第二次点击再由状态机显式进入 hidden。
            sidebarItem.canCollapse = false
            sidebarItem.minimumThickness = InkDesignTokens.Sidebar.compactWidth
            sidebarItem.maximumThickness = InkDesignTokens.Sidebar.maximumExpandedWidth
            applySidebarGeometry(
                collapsed: false,
                position: InkDesignTokens.Sidebar.compactWidth,
                duration: duration
            )
        case .hidden:
            sidebarItem.canCollapse = true
            applySidebarGeometry(collapsed: true, position: nil, duration: duration)
        }

        guard shouldAnimate else {
            finishSidebarGeometry(for: mode)
            return
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + duration) { [weak self] in
            guard let self, self.sidebarMode == mode else { return }
            self.finishSidebarGeometry(for: mode)
        }
    }

    private func applySidebarGeometry(
        collapsed: Bool,
        position: CGFloat?,
        duration: TimeInterval
    ) {
        guard let sidebarItem else { return }
        if duration > 0 {
            NSAnimationContext.runAnimationGroup { context in
                context.duration = duration
                context.timingFunction = CAMediaTimingFunction(name: .easeOut)
                sidebarItem.animator().isCollapsed = collapsed
                if let position {
                    splitVC.splitView.animator().setPosition(position, ofDividerAt: 0)
                }
            }
        } else {
            sidebarItem.isCollapsed = collapsed
            if let position {
                splitVC.splitView.setPosition(position, ofDividerAt: 0)
            }
        }
    }

    private func finishSidebarGeometry(for mode: SidebarDisplayMode) {
        guard let sidebarItem else { return }
        switch mode {
        case .expanded:
            sidebarItem.minimumThickness = InkDesignTokens.Sidebar.minimumExpandedWidth
            sidebarItem.maximumThickness = InkDesignTokens.Sidebar.maximumExpandedWidth
        case .compact:
            sidebarItem.minimumThickness = InkDesignTokens.Sidebar.compactWidth
            sidebarItem.maximumThickness = InkDesignTokens.Sidebar.compactWidth
        case .hidden:
            break
        }
    }

    private func updateTabBarInset() {
        let inset = sidebarMode == .hidden
            ? InkDesignTokens.Sidebar.collapsedTitlebarInset
            : InkDesignTokens.Spacing.sm
        tabBar.setLeadingInset(inset)
    }

    // MARK: - 项目操作

    @objc public func newProject(_ sender: Any?) {
        guard let window else { return }
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.prompt = "添加项目"
        panel.message = "选择一个目录作为项目，新会话将在该目录打开"
        panel.beginSheetModal(for: window) { [weak self] response in
            guard let self, response == .OK, let url = panel.url else { return }
            MainActor.assumeIsolated {
                // 已存在就直接切过去。
                if let existing = self.projects.firstIndex(where: { $0.directory == url }) {
                    self.selectProject(at: existing)
                    return
                }
                self.projects.append(Project(directory: url))
                self.persistProjects()
                self.selectProject(at: self.projects.count - 1)
            }
        }
    }

    private func selectProject(at index: Int) {
        guard projects.indices.contains(index) else { return }
        hideSettings()
        activeProjectIndex = index
        persistProjects()
        if let project = activeProject, project.tabs.isEmpty {
            newSession(nil) // 空项目：选中即开首个标签
        } else {
            attachActiveTab()
        }
        refreshChrome()
    }

    @objc public func selectSessionMenu(_ sender: NSMenuItem) {
        selectTab(at: sender.tag)
    }

    @objc public func removeCurrentProject(_ sender: Any?) {
        removeProject(at: activeProjectIndex)
    }

    private func togglePin(at index: Int) {
        guard projects.indices.contains(index) else { return }
        projects[index].pinned.toggle()
        sortPinnedFirst()
        persistProjects()
        refreshChrome()
    }

    private func setProjectLabel(_ label: InkProjectLabel, at index: Int) {
        guard projects.indices.contains(index) else { return }
        projects[index].label = label
        persistProjects()
        refreshChrome()
    }

    private func editNote(at index: Int) {
        guard projects.indices.contains(index), let window else { return }
        let project = projects[index]
        let alert = NSAlert()
        alert.messageText = "项目备注"
        alert.informativeText = project.displayName
        alert.addButton(withTitle: "保存")
        alert.addButton(withTitle: "取消")
        let field = NSTextField(string: project.note ?? "")
        field.frame = NSRect(x: 0, y: 0, width: 240, height: 24)
        field.placeholderString = "写点这个项目是干什么的"
        alert.accessoryView = field
        alert.window.initialFirstResponder = field
        alert.beginSheetModal(for: window) { [weak self] response in
            guard let self, response == .alertFirstButtonReturn else { return }
            MainActor.assumeIsolated {
                let text = field.stringValue.trimmingCharacters(in: .whitespaces)
                project.note = text.isEmpty ? nil : text
                self.persistProjects()
                self.refreshChrome()
            }
        }
    }

    /// 拖动排序。目标位置夹回源所在的组（置顶块 / 普通块），拖动不改变置顶状态。
    private func reorderProject(from: Int, to: Int) {
        guard projects.indices.contains(from), projects.indices.contains(to), from != to else { return }
        let active = activeProject
        let moved = projects.remove(at: from)
        var target = to
        let pinnedCount = projects.filter(\.pinned).count
        if moved.pinned {
            target = min(target, pinnedCount)
        } else {
            target = max(target, pinnedCount)
        }
        projects.insert(moved, at: min(target, projects.count))
        if let active, let index = projects.firstIndex(where: { $0 === active }) {
            activeProjectIndex = index
        }
        persistProjects()
        refreshChrome()
    }

    func removeProject(at index: Int) {
        guard projects.indices.contains(index) else { return }
        let project = projects[index]
        // 先解除回调再终止，避免 onExit 重入标签与布局管理。
        for tab in project.tabs {
            terminate(tab: tab)
        }
        project.tabs.removeAll()
        projects.remove(at: index)

        // 项目删光了回到默认 ~，和首启一致，窗口不空转。
        if projects.isEmpty {
            projects = [Project(directory: FileManager.default.homeDirectoryForCurrentUser)]
        }
        if activeProjectIndex >= projects.count {
            activeProjectIndex = projects.count - 1
        }
        persistProjects()
        selectProject(at: activeProjectIndex)
    }

    // MARK: - 标签与 pane 操作

    @objc public func newSession(_ sender: Any?) {
        hideSettings()
        guard let project = activeProject,
              let pane = startPane(
                size: TerminalSize(columns: 80, rows: 24),
                workingDirectory: project.directory.path
              ) else { return }
        project.tabs.append(TerminalTab(initialPane: pane))
        project.activeTabIndex = project.tabs.count - 1
        attachActiveTab()
        refreshChrome()
    }

    /// 兼容旧 selector；关闭语义已改为当前 pane。
    @objc public func closeSession(_ sender: Any?) {
        closeActivePane(sender)
    }

    @objc public func splitLeft(_ sender: Any?) {
        splitActivePane(direction: .left)
    }

    @objc public func splitRight(_ sender: Any?) {
        splitActivePane(direction: .right)
    }

    @objc public func splitUp(_ sender: Any?) {
        splitActivePane(direction: .up)
    }

    @objc public func splitDown(_ sender: Any?) {
        splitActivePane(direction: .down)
    }

    @objc public func closeActivePane(_ sender: Any?) {
        guard !isShowingSettings,
              let project = activeProject,
              let tab = project.activeTab else { return }
        if tab.paneCount == 1 {
            closeTab(at: project.activeTabIndex)
            return
        }
        let paneID = tab.activePaneID
        guard let pane = tab.removePane(paneID) else { return }
        pane.session.detach()
        pane.session.terminate()
        attachActiveTab()
        refreshChrome()
    }

    /// Command-F 只在当前聚焦 pane 打开搜索；已有同 pane 搜索时回到输入框。
    @objc public func findInActivePane(_ sender: Any?) {
        guard !isShowingSettings else { return }
        _ = workspaceVC.openSearch(for: window?.firstResponder)
    }

    private func splitActivePane(direction: PaneSplitDirection) {
        guard !isShowingSettings,
              let project = activeProject,
              let tab = project.activeTab,
              let activePane = tab.activePane else { return }

        let currentSize = workspaceVC.currentGridSize(for: activePane.id)
            ?? activePane.session.terminal.grid.size
        let size: TerminalSize
        switch direction.axis {
        case .leftRight:
            guard currentSize.columns >= 20 else { NSSound.beep(); return }
            size = TerminalSize(columns: currentSize.columns / 2, rows: currentSize.rows)
        case .topBottom:
            guard currentSize.rows >= 6 else { NSSound.beep(); return }
            size = TerminalSize(columns: currentSize.columns, rows: currentSize.rows / 2)
        }
        let workingDirectory = activePane.session.foregroundWorkingDirectory
            ?? project.directory.path
        guard let pane = startPane(size: size, workingDirectory: workingDirectory) else { return }
        guard tab.insertPane(pane, splitting: activePane.id, direction: direction) else {
            pane.session.detach()
            pane.session.terminate()
            return
        }
        attachActiveTab()
        refreshChrome()
    }

    private func installSplitShortcutMonitor() {
        splitShortcutMonitor = NSEvent.addLocalMonitorForEvents(
            matching: [.keyDown, .keyUp, .flagsChanged]
        ) { @MainActor [weak self] event in
            self?.handleSplitShortcut(event) ?? event
        }
    }

    private func handleSplitShortcut(_ event: NSEvent) -> NSEvent? {
        guard event.window === window else {
            _ = splitShortcutState.handleKeyEvent(.contextLost)
            return event
        }

        guard !isShowingSettings,
              window?.firstResponder is TerminalMetalView else {
            _ = splitShortcutState.handleKeyEvent(.contextLost)
            return event
        }

        let keyEvent: SplitShortcutKeyEvent
        switch event.type {
        case .keyDown:
            keyEvent = .keyDown(
                keyCode: event.keyCode,
                isRepeat: event.isARepeat,
                commandDown: event.modifierFlags.contains(.command)
            )
        case .keyUp:
            keyEvent = .keyUp(keyCode: event.keyCode)
        case .flagsChanged:
            keyEvent = .flagsChanged(
                commandDown: event.modifierFlags.contains(.command)
            )
        default:
            return event
        }
        return applySplitShortcutDecision(
            splitShortcutState.handleKeyEvent(keyEvent), event: event
        )
    }

    private func applySplitShortcutDecision(
        _ decision: SplitShortcutDecision,
        event: NSEvent
    ) -> NSEvent? {
        switch decision {
        case .passThrough:
            return event
        case .consume:
            return nil
        case let .split(direction):
            splitActivePane(direction: direction)
            return nil
        }
    }

    private func cancelSplitShortcut() {
        _ = splitShortcutState.handle(.cancel)
    }

    private func startPane(size: TerminalSize, workingDirectory: String) -> TerminalPane? {
        let session = TerminalSession(
            size: size,
            workingDirectory: workingDirectory,
            scrollbackLines: config.scrollbackLines
        )
        let pane = TerminalPane(session: session)
        session.onUpdate = { [weak self, weak pane] in
            guard let self, let pane else { return }
            self.workspaceVC.markDirty(pane.id)
            self.workspaceVC.refreshSearch(for: pane.id)
            self.refreshChromeIfNeeded()
        }
        session.onExit = { [weak self, weak pane] _ in
            guard let self, let pane else { return }
            self.handlePaneExit(pane.id)
        }
        do {
            try session.start()
            return pane
        } catch {
            session.detach()
            NSAlert(error: error).runModal()
            return nil
        }
    }

    private func handlePaneExit(_ paneID: PaneID) {
        for (projectIndex, project) in projects.enumerated() {
            for (tabIndex, tab) in project.tabs.enumerated()
            where tab.panes[paneID] != nil {
                if tab.paneCount > 1, let pane = tab.removePane(paneID) {
                    pane.session.detach()
                    if projectIndex == activeProjectIndex,
                       tabIndex == project.activeTabIndex {
                        attachActiveTab()
                    }
                    refreshChrome()
                } else {
                    tab.activePane?.session.detach()
                    _ = project.removeTab(at: tabIndex)
                    normalizeAfterTabRemoval()
                }
                return
            }
        }
    }

    private func closeTab(at index: Int) {
        guard let project = activeProject,
              let tab = project.removeTab(at: index) else { return }
        terminate(tab: tab)
        normalizeAfterTabRemoval()
    }

    private func terminate(tab: TerminalTab) {
        let panes = tab.allPanes
        for pane in panes { pane.session.detach() }
        for pane in panes { pane.session.terminate() }
    }

    private func normalizeAfterTabRemoval() {
        for project in projects where project.activeTabIndex >= project.tabs.count {
            project.activeTabIndex = max(0, project.tabs.count - 1)
        }
        if projects.allSatisfy(\.tabs.isEmpty) {
            workspaceVC.clear()
            window?.close()
            return
        }
        if activeProject?.tabs.isEmpty ?? true,
           let index = projects.firstIndex(where: { !$0.tabs.isEmpty }) {
            activeProjectIndex = index
        }
        attachActiveTab()
        refreshChrome()
    }

    private func selectTab(at index: Int) {
        guard let project = activeProject, project.tabs.indices.contains(index) else { return }
        hideSettings()
        project.activeTabIndex = index
        attachActiveTab()
        refreshChrome()
    }

    @objc public func nextSession(_ sender: Any?) {
        guard let project = activeProject, project.tabs.count > 1 else { return }
        selectTab(at: (project.activeTabIndex + 1) % project.tabs.count)
    }

    @objc public func previousSession(_ sender: Any?) {
        guard let project = activeProject, project.tabs.count > 1 else { return }
        let count = project.tabs.count
        selectTab(at: (project.activeTabIndex - 1 + count) % count)
    }

    private func attachActiveTab() {
        guard let tab = activeProject?.activeTab else {
            workspaceVC.clear()
            return
        }
        workspaceVC.show(tab: tab, config: config)
        DispatchQueue.main.async { [weak self] in
            self?.workspaceVC.focusActivePane()
        }
    }

    // MARK: - 外壳刷新

    /// 标签标题优先级：用户改的名 > 当前 pane 的 OSC 标题 >
    /// 项目路径缩写。路径在标签里头部截断（保 .../code/ink 尾部）。
    private func tabTitle(_ tab: TerminalTab, project: Project) -> String {
        if let custom = tab.customName { return custom }
        let osc = tab.activePane?.session.terminal.title ?? ""
        if !osc.isEmpty { return osc }
        return project.displayName
    }

    private func chromeSignature() -> String {
        let tabs = activeProject.map { project in
            project.tabs.map { tabTitle($0, project: project) }.joined(separator: "\u{1}")
        } ?? ""
        let sidebar = projects.map {
            "\($0.displayName):\($0.tabs.count):\($0.label.rawValue)"
        }.joined(separator: "\u{1}")
        let pane = activeProject?.activeTab?.activePaneID.rawValue.uuidString ?? ""
        return "\(activeProjectIndex)|\(activeProject?.activeTabIndex ?? -1)|\(pane)|\(tabs)|\(sidebar)"
    }

    /// 标题或结构变了才重建 chrome——每次输出都重建太浪费。
    private func refreshChromeIfNeeded() {
        if chromeSignature() != lastChromeSignature {
            refreshChrome()
        }
    }

    private func refreshChrome() {
        lastChromeSignature = chromeSignature()

        let activeTab = activeProject?.activeTabIndex ?? -1
        let tabs: [TabBarView.Tab] = activeProject.map { project in
            project.tabs.enumerated().map { index, tab in
                TabBarView.Tab(
                    title: tabTitle(tab, project: project),
                    shortcut: index < 9 ? "⌘\(index + 1)" : "",
                    active: index == activeTab
                )
            }
        } ?? []
        tabBar.reload(tabs: tabs)
        sidebarVC.reload(rows: projects.enumerated().map { index, project in
            let status = project.tabs.isEmpty ? "未打开" : "\(project.tabs.count) 个标签"
            return SidebarViewController.Row(
                title: project.sidebarTitle,
                detail: project.note ?? project.sidebarParentPath,
                status: status,
                fullPath: project.displayName,
                active: !isShowingSettings && index == activeProjectIndex,
                pinned: project.pinned,
                label: project.label
            )
        })
    }

    // MARK: - 窗口

    public func windowWillClose(_ notification: Notification) {
        cancelSplitShortcut()
        workspaceVC.closeSearch(returnFocus: false)
        if let splitShortcutMonitor {
            NSEvent.removeMonitor(splitShortcutMonitor)
            self.splitShortcutMonitor = nil
        }
        for project in projects {
            for tab in project.tabs { terminate(tab: tab) }
            project.tabs.removeAll()
        }
    }

    public func windowDidResignKey(_ notification: Notification) {
        cancelSplitShortcut()
    }

    public func validateMenuItem(_ menuItem: NSMenuItem) -> Bool {
        guard let action = menuItem.action else { return true }
        let horizontalActions = [#selector(splitLeft(_:)), #selector(splitRight(_:))]
        let verticalActions = [#selector(splitUp(_:)), #selector(splitDown(_:))]
        if horizontalActions.contains(action) || verticalActions.contains(action) {
            guard !isShowingSettings,
                  let pane = activeProject?.activeTab?.activePane else { return false }
            let size = workspaceVC.currentGridSize(for: pane.id) ?? pane.session.terminal.grid.size
            return horizontalActions.contains(action) ? size.columns >= 20 : size.rows >= 6
        }
        if action == #selector(closeActivePane(_:)) {
            return !isShowingSettings && activeProject?.activeTab != nil
        }
        if action == #selector(findInActivePane(_:)) {
            return !isShowingSettings && workspaceVC.canOpenSearch(for: window?.firstResponder)
        }
        return true
    }
}

/// 只为拿到分栏布局变化（含侧边栏收起/展开）的回调。
@MainActor
final class ShellSplitViewController: NSSplitViewController {
    var onLayoutChange: (() -> Void)?
    var onToggleSidebar: (() -> Void)?

    /// 菜单项仍指向系统 selector，具体三态循环交给窗口控制器。
    override func toggleSidebar(_ sender: Any?) {
        onToggleSidebar?()
    }

    override func splitViewDidResizeSubviews(_ notification: Notification) {
        onLayoutChange?()
    }
}
