import Foundation

/// 在纯快照与 Shell 运行态之间转换；PTY 的实际启动仍由窗口控制器注入。
@MainActor
enum WorkspaceStateMapper {
    static func resolveWorkingDirectory(
        saved: String,
        projectDirectory: URL,
        homeDirectory: URL = FileManager.default.homeDirectoryForCurrentUser,
        fileManager: FileManager = .default
    ) -> String {
        let candidates = [
            URL(fileURLWithPath: (saved as NSString).expandingTildeInPath),
            projectDirectory,
            homeDirectory,
        ]
        for candidate in candidates {
            var isDirectory: ObjCBool = false
            if fileManager.fileExists(atPath: candidate.path, isDirectory: &isDirectory),
               isDirectory.boolValue {
                return candidate.standardizedFileURL.path
            }
        }
        return homeDirectory.standardizedFileURL.path
    }

    static func restoreTab(
        _ state: WorkspaceSnapshot.Tab,
        projectDirectory: URL,
        makePane: (String) -> TerminalPane?,
        discardPane: (TerminalPane) -> Void = { pane in
            pane.session.detach()
            pane.session.terminate()
        }
    ) -> TerminalTab? {
        var panesByStoredID: [String: TerminalPane] = [:]
        for leaf in state.layout.leaves {
            let directory = resolveWorkingDirectory(
                saved: leaf.workingDirectory,
                projectDirectory: projectDirectory
            )
            guard let pane = makePane(directory) else {
                panesByStoredID.values.forEach(discardPane)
                return nil
            }
            panesByStoredID[leaf.paneID] = pane
        }

        guard let layout = state.layout.runtimeLayout(using: panesByStoredID),
              let activePane = panesByStoredID[state.activePaneID] else {
            panesByStoredID.values.forEach(discardPane)
            return nil
        }
        let panes = Dictionary(uniqueKeysWithValues: panesByStoredID.values.map { ($0.id, $0) })
        guard let tab = TerminalTab(
            restoredLayout: layout,
            panes: panes,
            activePaneID: activePane.id,
            customName: state.customName
        ) else {
            panesByStoredID.values.forEach(discardPane)
            return nil
        }
        return tab
    }

    static func capture(
        projects: [Project],
        activeProject: Project?
    ) -> WorkspaceSnapshot {
        WorkspaceSnapshot(
            activeProjectPath: activeProject?.displayName,
            projects: projects.map { project in
                WorkspaceSnapshot.Project(
                    path: project.displayName,
                    activeTabIndex: project.activeTabIndex,
                    tabs: project.tabs.compactMap { tab in
                        guard let layout = snapshotLayout(
                            tab.layout,
                            panes: tab.panes,
                            fallbackDirectory: project.directory.path
                        ) else { return nil }
                        return WorkspaceSnapshot.Tab(
                            customName: tab.customName,
                            activePaneID: tab.activePaneID.rawValue.uuidString,
                            layout: layout
                        )
                    }
                )
            }
        )
    }

    private static func snapshotLayout(
        _ layout: PaneLayout,
        panes: [PaneID: TerminalPane],
        fallbackDirectory: String
    ) -> WorkspaceLayoutNode? {
        switch layout {
        case let .leaf(paneID):
            guard let pane = panes[paneID] else { return nil }
            let directory = pane.session.snapshotWorkingDirectory ?? fallbackDirectory
            return .leaf(
                paneID: paneID.rawValue.uuidString,
                workingDirectory: (directory as NSString).abbreviatingWithTildeInPath
            )

        case let .group(_, axis, weights, children):
            let capturedChildren = children.compactMap {
                snapshotLayout(
                    $0,
                    panes: panes,
                    fallbackDirectory: fallbackDirectory
                )
            }
            guard capturedChildren.count == children.count else { return nil }
            return .group(
                axis: axis == .leftRight ? "leftRight" : "topBottom",
                weights: weights,
                children: capturedChildren
            )
        }
    }
}

private extension WorkspaceLayoutNode {
    struct StoredLeaf {
        let paneID: String
        let workingDirectory: String
    }

    var leaves: [StoredLeaf] {
        switch self {
        case let .leaf(paneID, workingDirectory):
            [StoredLeaf(paneID: paneID, workingDirectory: workingDirectory)]
        case let .group(_, _, children):
            children.flatMap(\.leaves)
        }
    }

    func runtimeLayout(using panes: [String: TerminalPane]) -> PaneLayout? {
        switch self {
        case let .leaf(paneID, _):
            guard let pane = panes[paneID] else { return nil }
            return .leaf(pane.id)

        case let .group(axis, weights, children):
            guard axis == "leftRight" || axis == "topBottom",
                  weights.count == children.count,
                  weights.allSatisfy({ $0.isFinite && $0 > 0 }) else { return nil }
            let runtimeChildren = children.compactMap { $0.runtimeLayout(using: panes) }
            guard runtimeChildren.count == children.count else { return nil }
            let total = weights.reduce(0, +)
            guard total.isFinite, total > 0 else { return nil }
            return .group(
                id: SplitID(),
                axis: axis == "leftRight" ? .leftRight : .topBottom,
                weights: weights.map { $0 / total },
                children: runtimeChildren
            )
        }
    }
}
