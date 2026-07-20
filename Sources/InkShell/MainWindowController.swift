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

/// 主窗口：项目侧边栏 + 会话标签栏 + 终端内容区。
///
/// 结构：侧边栏列**项目**（持久化的目录），标签栏列**当前项目的会话**。
/// 新会话在项目目录里启动。
///
/// 内存纪律的关键选择：**所有会话共享一个 `TerminalMetalView`**。切换只是
/// 换 provider 指针——一块 Metal layer、一份 glyph atlas。会话状态
/// （grid、scrollback）在各自 `TerminalSession` 里，是纯数据。
@MainActor
public final class MainWindowController: NSWindowController, NSWindowDelegate {

    private let splitVC = ShellSplitViewController()
    private var sidebarItem: NSSplitViewItem?
    private let sidebarVC = SidebarViewController()
    private let tabBar = TabBarView()
    private let terminalView = TerminalMetalView(frame: .zero)
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
        terminalView.fontFamily = config.fontFamily
        terminalView.lineHeightMultiplier = CGFloat(config.lineHeight)
        terminalView.fontSize = CGFloat(config.fontSize)
        terminalView.cursorStyle =
            switch config.cursorStyle {
            case .block: .block
            case .bar: .bar
            case .underline: .underline
            }
        terminalView.cursorBlinkEnabled = config.cursorBlink
        terminalView.optionAsMeta = config.optionAsMeta
        terminalView.copyOnSelect = config.copyOnSelect
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
        terminalView.translatesAutoresizingMaskIntoConstraints = false
        hairline.translatesAutoresizingMaskIntoConstraints = false
        contentRoot.addSubview(terminalWorkspace)
        terminalWorkspace.addSubview(tabBar)
        terminalWorkspace.addSubview(hairline)
        terminalWorkspace.addSubview(terminalView)
        NSLayoutConstraint.activate([
            terminalWorkspace.topAnchor.constraint(equalTo: contentRoot.topAnchor),
            terminalWorkspace.leadingAnchor.constraint(equalTo: contentRoot.leadingAnchor),
            terminalWorkspace.trailingAnchor.constraint(equalTo: contentRoot.trailingAnchor),
            terminalWorkspace.bottomAnchor.constraint(equalTo: contentRoot.bottomAnchor),

            tabBar.topAnchor.constraint(equalTo: terminalWorkspace.topAnchor),
            tabBar.leadingAnchor.constraint(equalTo: terminalWorkspace.leadingAnchor),
            tabBar.trailingAnchor.constraint(equalTo: terminalWorkspace.trailingAnchor),
            tabBar.heightAnchor.constraint(equalToConstant: 38),
            hairline.topAnchor.constraint(equalTo: tabBar.bottomAnchor),
            hairline.leadingAnchor.constraint(equalTo: terminalWorkspace.leadingAnchor),
            hairline.trailingAnchor.constraint(equalTo: terminalWorkspace.trailingAnchor),
            terminalView.topAnchor.constraint(equalTo: hairline.bottomAnchor),
            terminalView.leadingAnchor.constraint(equalTo: terminalWorkspace.leadingAnchor),
            terminalView.trailingAnchor.constraint(equalTo: terminalWorkspace.trailingAnchor),
            terminalView.bottomAnchor.constraint(equalTo: terminalWorkspace.bottomAnchor),
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
        tabBar.onSelect = { [weak self] in self?.selectSession(at: $0) }
        tabBar.onClose = { [weak self] index in
            guard let self, let project = self.activeProject,
                  project.sessions.indices.contains(index) else { return }
            project.sessions[index].terminate() // 退出回调里走 removeSession
        }
        tabBar.onRename = { [weak self] index, name in
            guard let self, let project = self.activeProject,
                  project.sessions.indices.contains(index) else { return }
            project.sessions[index].customName = name
            self.refreshChrome()
        }
        tabBar.onNewTab = { [weak self] in self?.newSession(nil) }
        tabBar.onToggleSidebar = { [weak self] in self?.toggleSidebarMode() }
        sidebarVC.onSelect = { [weak self] in self?.selectProject(at: $0) }
        sidebarVC.onNewProject = { [weak self] in self?.newProject(nil) }
        sidebarVC.onSettings = { [weak self] in self?.showSettings(nil) }
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

        terminalView.onGridResize = { [weak self] size in
            guard let self else { return }
            if let session = self.activeProject?.activeSession {
                session.resize(to: size)
            } else if !self.firstSessionScheduled {
                // 首会话推迟到布局稳定（见 M4 的首启修正）。
                self.firstSessionScheduled = true
                DispatchQueue.main.async { [weak self] in
                    self?.newSession(nil)
                }
            }
        }
        window.makeFirstResponder(terminalView)
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
        installSettingsViewIfNeeded()
        isShowingSettings = true
        sidebarVC.isSettingsSelected = true
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
            settingsView.topAnchor.constraint(equalTo: contentRoot.topAnchor),
            settingsView.leadingAnchor.constraint(equalTo: contentRoot.leadingAnchor),
            settingsView.trailingAnchor.constraint(equalTo: contentRoot.trailingAnchor),
            settingsView.bottomAnchor.constraint(equalTo: contentRoot.bottomAnchor),
        ])
        isSettingsViewInstalled = true
    }

    private func hideSettings() {
        guard isShowingSettings else { return }
        isShowingSettings = false
        sidebarVC.isSettingsSelected = false
        settingsVC.view.isHidden = true
        terminalWorkspace.isHidden = false
        window?.makeFirstResponder(terminalView)
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
        if let project = activeProject, project.sessions.isEmpty {
            newSession(nil) // 空项目：选中即开首个会话
        } else {
            attachActiveSession()
        }
        refreshChrome()
    }

    @objc public func selectSessionMenu(_ sender: NSMenuItem) {
        selectSession(at: sender.tag)
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
        // 先解除回调再终止，避免 onExit 重入 removeSession 的列表管理。
        for session in project.sessions {
            session.detach()
            session.terminate()
        }
        project.sessions.removeAll()
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

    // MARK: - 会话操作

    @objc public func newSession(_ sender: Any?) {
        guard let project = activeProject,
              let size = terminalView.currentGridSize else { return }
        let session = TerminalSession(
            size: size,
            workingDirectory: project.directory.path,
            scrollbackLines: config.scrollbackLines
        )
        session.onUpdate = { [weak self] in
            self?.terminalView.markDirty()
            self?.refreshChromeIfNeeded()
        }
        session.onExit = { [weak self, weak session] _ in
            guard let self, let session else { return }
            self.removeSession(session)
        }
        do {
            try session.start()
        } catch {
            NSAlert(error: error).runModal()
            return
        }
        project.sessions.append(session)
        project.activeSessionIndex = project.sessions.count - 1
        attachActiveSession()
        refreshChrome()
    }

    @objc public func closeSession(_ sender: Any?) {
        activeProject?.activeSession?.terminate() // 退出回调里走 removeSession
    }

    private func removeSession(_ session: TerminalSession) {
        for project in projects {
            if let index = project.sessions.firstIndex(where: { $0 === session }) {
                project.sessions.remove(at: index)
                if project.activeSessionIndex >= project.sessions.count {
                    project.activeSessionIndex = max(0, project.sessions.count - 1)
                }
                break
            }
        }
        // 所有项目都没有会话了才关窗口；否则回到当前项目的邻近会话。
        if projects.allSatisfy(\.sessions.isEmpty) {
            window?.close()
            return
        }
        if activeProject?.sessions.isEmpty ?? true {
            // 当前项目空了：切到最近的有会话的项目。
            if let index = projects.firstIndex(where: { !$0.sessions.isEmpty }) {
                activeProjectIndex = index
            }
        }
        attachActiveSession()
        refreshChrome()
    }

    private func selectSession(at index: Int) {
        guard let project = activeProject, project.sessions.indices.contains(index) else { return }
        project.activeSessionIndex = index
        attachActiveSession()
        refreshChrome()
    }

    @objc public func nextSession(_ sender: Any?) {
        guard let project = activeProject, project.sessions.count > 1 else { return }
        selectSession(at: (project.activeSessionIndex + 1) % project.sessions.count)
    }

    @objc public func previousSession(_ sender: Any?) {
        guard let project = activeProject, project.sessions.count > 1 else { return }
        let count = project.sessions.count
        selectSession(at: (project.activeSessionIndex - 1 + count) % count)
    }

    /// 把共享终端视图指到当前会话。
    private func attachActiveSession() {
        guard let session = activeProject?.activeSession else {
            terminalView.terminalProvider = nil
            terminalView.onInput = nil
            terminalView.markDirty()
            return
        }
        terminalView.terminalProvider = { [weak session] in
            session?.terminal ?? Terminal(size: TerminalSize(columns: 80, rows: 24), scrollbackCapacity: 1)
        }
        terminalView.onInput = { [weak session] data in
            session?.write(data)
        }
        if let size = terminalView.currentGridSize {
            session.resize(to: size)
        }
        terminalView.resetTransientState()
    }

    // MARK: - 外壳刷新

    /// 标签标题（Ghostty 式优先级）：用户改的名 > shell 设的 OSC 标题 >
    /// 项目路径缩写。路径在标签里头部截断（保 .../code/ink 尾部）。
    private func sessionTitle(_ session: TerminalSession, project: Project) -> String {
        if let custom = session.customName { return custom }
        let osc = session.terminal.title
        if !osc.isEmpty { return osc }
        return project.displayName
    }

    private func chromeSignature() -> String {
        let tabs = activeProject.map { project in
            project.sessions.map { sessionTitle($0, project: project) }.joined(separator: "\u{1}")
        } ?? ""
        let sidebar = projects.map {
            "\($0.displayName):\($0.sessions.count):\($0.label.rawValue)"
        }.joined(separator: "\u{1}")
        return "\(activeProjectIndex)|\(activeProject?.activeSessionIndex ?? -1)|\(tabs)|\(sidebar)"
    }

    /// 标题或结构变了才重建 chrome——每次输出都重建太浪费。
    private func refreshChromeIfNeeded() {
        if chromeSignature() != lastChromeSignature {
            refreshChrome()
        }
    }

    private func refreshChrome() {
        lastChromeSignature = chromeSignature()

        let activeSession = activeProject?.activeSessionIndex ?? -1
        let tabs: [TabBarView.Tab] = activeProject.map { project in
            project.sessions.enumerated().map { index, session in
                TabBarView.Tab(
                    title: sessionTitle(session, project: project),
                    shortcut: index < 9 ? "⌘\(index + 1)" : "",
                    active: index == activeSession
                )
            }
        } ?? []
        tabBar.reload(tabs: tabs)
        sidebarVC.reload(rows: projects.enumerated().map { index, project in
            let fallback = project.sessions.isEmpty ? "未打开" : "\(project.sessions.count) 个会话"
            return SidebarViewController.Row(
                title: project.displayName,
                subtitle: project.note ?? fallback,
                active: !isShowingSettings && index == activeProjectIndex,
                pinned: project.pinned,
                label: project.label
            )
        })
    }

    // MARK: - 窗口

    public func windowWillClose(_ notification: Notification) {
        for project in projects {
            for session in project.sessions {
                session.terminate()
            }
            project.sessions.removeAll()
        }
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
