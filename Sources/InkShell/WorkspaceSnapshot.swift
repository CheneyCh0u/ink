import Foundation

/// 从本机快照恢复工作区时的防御性资源预算。
struct WorkspaceLimits: Sendable {
    var maxProjects: Int
    var maxTabsPerProject: Int
    var maxPanesPerTab: Int
    var maxLayoutDepth: Int
    var maxTotalPanes: Int

    init(
        maxProjects: Int = 64,
        maxTabsPerProject: Int = 32,
        maxPanesPerTab: Int = 16,
        maxLayoutDepth: Int = 16,
        maxTotalPanes: Int = 128
    ) {
        self.maxProjects = maxProjects
        self.maxTabsPerProject = maxTabsPerProject
        self.maxPanesPerTab = maxPanesPerTab
        self.maxLayoutDepth = maxLayoutDepth
        self.maxTotalPanes = maxTotalPanes
    }
}

/// 只描述 pane 的结构与启动目录，不包含任何 PTY 或终端内容。
indirect enum WorkspaceLayoutNode: Codable, Equatable, Sendable {
    case leaf(paneID: String, workingDirectory: String)
    case group(axis: String, weights: [Double], children: [WorkspaceLayoutNode])

    var weights: [Double] {
        if case let .group(_, weights, _) = self { return weights }
        return []
    }

    var paneCount: Int {
        switch self {
        case .leaf:
            1
        case let .group(_, _, children):
            children.reduce(0) { $0 + $1.paneCount }
        }
    }

    fileprivate var firstPaneID: String? {
        switch self {
        case let .leaf(paneID, _):
            paneID
        case let .group(_, _, children):
            children.first?.firstPaneID
        }
    }

    private enum CodingKeys: String, CodingKey {
        case kind
        case paneID
        case workingDirectory
        case axis
        case weights
        case children
    }

    private enum Kind: String, Codable {
        case leaf
        case group
    }

    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        switch try values.decode(Kind.self, forKey: .kind) {
        case .leaf:
            self = .leaf(
                paneID: try values.decode(String.self, forKey: .paneID),
                workingDirectory: try values.decode(String.self, forKey: .workingDirectory)
            )
        case .group:
            self = .group(
                axis: try values.decode(String.self, forKey: .axis),
                weights: try values.decode([Double].self, forKey: .weights),
                children: try values.decode([WorkspaceLayoutNode].self, forKey: .children)
            )
        }
    }

    func encode(to encoder: Encoder) throws {
        var values = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case let .leaf(paneID, workingDirectory):
            try values.encode(Kind.leaf, forKey: .kind)
            try values.encode(paneID, forKey: .paneID)
            try values.encode(workingDirectory, forKey: .workingDirectory)
        case let .group(axis, weights, children):
            try values.encode(Kind.group, forKey: .kind)
            try values.encode(axis, forKey: .axis)
            try values.encode(weights, forKey: .weights)
            try values.encode(children, forKey: .children)
        }
    }
}

struct WorkspaceSnapshot: Codable, Equatable, Sendable {
    var schemaVersion = 1
    var activeProjectPath: String?
    var projects: [Project]

    struct Project: Codable, Equatable, Sendable {
        var path: String
        var activeTabIndex: Int
        var tabs: [Tab]
    }

    struct Tab: Codable, Equatable, Sendable {
        var customName: String?
        var activePaneID: String
        var layout: WorkspaceLayoutNode
    }

    /// 语法损坏由 JSONDecoder 整份拒绝；这里把语义损坏限制在单个项目或标签。
    func validated(limits: WorkspaceLimits = WorkspaceLimits()) -> WorkspaceSnapshot? {
        guard schemaVersion == 1 else { return nil }

        var remainingPanes = max(0, limits.maxTotalPanes)
        var validatedProjects: [Project] = []
        validatedProjects.reserveCapacity(min(projects.count, max(0, limits.maxProjects)))

        for project in projects.prefix(max(0, limits.maxProjects)) {
            guard Self.isAbsolutePath(project.path) else { continue }

            var validatedTabs: [Tab] = []
            var mappedActiveTabIndex: Int?
            for (originalIndex, tab) in project.tabs
                .prefix(max(0, limits.maxTabsPerProject)).enumerated() {
                guard remainingPanes > 0,
                      let validated = tab.validated(limits: limits),
                      validated.layout.paneCount <= remainingPanes else { continue }
                if originalIndex == project.activeTabIndex {
                    mappedActiveTabIndex = validatedTabs.count
                }
                validatedTabs.append(validated)
                remainingPanes -= validated.layout.paneCount
            }

            let activeTabIndex: Int
            if let mappedActiveTabIndex {
                activeTabIndex = mappedActiveTabIndex
            } else if validatedTabs.isEmpty {
                activeTabIndex = 0
            } else {
                activeTabIndex = min(
                    max(0, project.activeTabIndex),
                    validatedTabs.count - 1
                )
            }
            validatedProjects.append(Project(
                path: project.path,
                activeTabIndex: activeTabIndex,
                tabs: validatedTabs
            ))
        }

        let activeProjectPath = activeProjectPath.flatMap {
            Self.isAbsolutePath($0) ? $0 : nil
        }
        return WorkspaceSnapshot(
            activeProjectPath: activeProjectPath,
            projects: validatedProjects
        )
    }

    fileprivate static func isAbsolutePath(_ path: String) -> Bool {
        guard !path.isEmpty else { return false }
        let expanded = (path as NSString).expandingTildeInPath
        return (expanded as NSString).isAbsolutePath
    }
}

private extension WorkspaceSnapshot.Tab {
    func validated(limits: WorkspaceLimits) -> WorkspaceSnapshot.Tab? {
        var paneIDs: Set<String> = []
        var paneCount = 0
        guard let layout = layout.validated(
            depth: 1,
            limits: limits,
            paneIDs: &paneIDs,
            paneCount: &paneCount
        ),
        let firstPaneID = layout.firstPaneID else { return nil }

        return WorkspaceSnapshot.Tab(
            customName: customName,
            activePaneID: paneIDs.contains(activePaneID) ? activePaneID : firstPaneID,
            layout: layout
        )
    }
}

private extension WorkspaceLayoutNode {
    func validated(
        depth: Int,
        limits: WorkspaceLimits,
        paneIDs: inout Set<String>,
        paneCount: inout Int
    ) -> WorkspaceLayoutNode? {
        guard depth <= max(0, limits.maxLayoutDepth) else { return nil }

        switch self {
        case let .leaf(paneID, workingDirectory):
            guard !paneID.isEmpty,
                  WorkspaceSnapshot.isAbsolutePath(workingDirectory),
                  paneIDs.insert(paneID).inserted,
                  paneCount < max(0, limits.maxPanesPerTab) else { return nil }
            paneCount += 1
            return .leaf(paneID: paneID, workingDirectory: workingDirectory)

        case let .group(axis, weights, children):
            guard axis == "leftRight" || axis == "topBottom",
                  children.count >= 2,
                  weights.count == children.count,
                  weights.allSatisfy({ $0.isFinite && $0 > 0 }) else { return nil }

            var validatedChildren: [WorkspaceLayoutNode] = []
            validatedChildren.reserveCapacity(children.count)
            for child in children {
                guard let validated = child.validated(
                    depth: depth + 1,
                    limits: limits,
                    paneIDs: &paneIDs,
                    paneCount: &paneCount
                ) else { return nil }
                validatedChildren.append(validated)
            }
            let total = weights.reduce(0, +)
            guard total.isFinite, total > 0 else { return nil }
            return .group(
                axis: axis,
                weights: weights.map { $0 / total },
                children: validatedChildren
            )
        }
    }
}

/// 工作区是本机应用状态；用独立 JSON Data 避免与配置 TOML 混在一起。
struct WorkspaceStore {
    static let key = "ink.workspace.v1"

    private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    func load(limits: WorkspaceLimits = WorkspaceLimits()) -> WorkspaceSnapshot? {
        guard let data = defaults.data(forKey: Self.key),
              let decoded = try? JSONDecoder().decode(WorkspaceSnapshot.self, from: data) else {
            return nil
        }
        return decoded.validated(limits: limits)
    }

    @discardableResult
    func save(_ snapshot: WorkspaceSnapshot) -> Bool {
        guard let data = try? JSONEncoder().encode(snapshot) else { return false }
        defaults.set(data, forKey: Self.key)
        return true
    }
}
