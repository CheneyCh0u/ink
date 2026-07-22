import Foundation
import InkDesign

/// 一个项目 = 一个目录 + 若干会话（标签）+ 置顶/备注元数据。
/// 项目列表持久化；会话是运行态，随进程生灭。
@MainActor
final class Project {
    let directory: URL
    var pinned: Bool
    var note: String?
    var label: InkProjectLabel
    var tabs: [TerminalTab] = []
    var activeTabIndex = 0

    init(
        directory: URL,
        pinned: Bool = false,
        note: String? = nil,
        label: InkProjectLabel = .none
    ) {
        self.directory = directory
        self.pinned = pinned
        self.note = note
        self.label = label
    }

    /// 侧边栏显示名：`~/work/code/ink` 式的缩写路径。
    var displayName: String {
        (directory.path as NSString).abbreviatingWithTildeInPath
    }

    /// 侧边栏主标题只保留最终目录名，用户主目录沿用熟悉的 `~`。
    var sidebarTitle: String {
        if isHomeDirectory {
            return "~"
        }
        return directory.lastPathComponent
    }

    /// 侧边栏副标题使用缩写后的父路径；用户主目录没有父路径提示。
    var sidebarParentPath: String {
        guard !isHomeDirectory else { return "" }
        return (directory.deletingLastPathComponent().path as NSString)
            .abbreviatingWithTildeInPath
    }

    private var isHomeDirectory: Bool {
        directory.standardizedFileURL
            == FileManager.default.homeDirectoryForCurrentUser.standardizedFileURL
    }

    var activeTab: TerminalTab? {
        tabs.indices.contains(activeTabIndex) ? tabs[activeTabIndex] : nil
    }

    var attention: TabAttention? {
        tabs.compactMap(\.attention).reduce(nil) { current, incoming in
            current?.merging(incoming) ?? incoming
        }
    }

    /// 删除标签时保持原活动标签的身份；只有删除活动标签才选择相邻标签。
    @discardableResult
    func removeTab(at index: Int) -> TerminalTab? {
        guard tabs.indices.contains(index) else { return nil }
        let removed = tabs.remove(at: index)
        if tabs.isEmpty {
            activeTabIndex = 0
        } else if index < activeTabIndex {
            activeTabIndex -= 1
        } else if activeTabIndex >= tabs.count {
            activeTabIndex = tabs.count - 1
        }
        return removed
    }
}

/// 项目列表持久化。UserDefaults 存 JSON：这是应用状态不是用户配置，
/// 不进 TOML 配置文件。v1 格式（纯路径数组）自动迁移。
enum ProjectStore {
    private static let key = "ink.projects.v2"
    private static let legacyKey = "ink.projects"
    private static let activeKey = "ink.activeProject"

    struct Stored: Codable {
        var path: String
        var pinned: Bool
        var note: String?
        /// String 保证未来新增颜色时，旧版本遇到未知值也不会让整份项目列表解码失败。
        var label: String?
    }

    @MainActor
    static func load(defaults: UserDefaults = .standard) -> [Project] {
        var stored: [Stored] = []
        if let data = defaults.data(forKey: key),
           let decoded = try? JSONDecoder().decode([Stored].self, from: data) {
            stored = decoded
        } else if let legacy = defaults.stringArray(forKey: legacyKey) {
            stored = legacy.map { Stored(path: $0, pinned: false, note: nil, label: nil) }
        }

        return stored.compactMap { item in
            let url = URL(fileURLWithPath: (item.path as NSString).expandingTildeInPath)
            // 目录没了就静默剔除（外置盘、已删除的项目）。
            var isDir: ObjCBool = false
            let exists = FileManager.default.fileExists(atPath: url.path, isDirectory: &isDir)
            guard exists, isDir.boolValue else { return nil }
            return Project(
                directory: url,
                pinned: item.pinned,
                note: item.note,
                label: item.label.flatMap(InkProjectLabel.init(rawValue:)) ?? .none
            )
        }
    }

    @MainActor
    static func save(_ projects: [Project], defaults: UserDefaults = .standard) {
        let stored = projects.map {
            Stored(
                path: $0.displayName,
                pinned: $0.pinned,
                note: $0.note,
                label: $0.label == .none ? nil : $0.label.rawValue
            )
        }
        if let data = try? JSONEncoder().encode(stored) {
            defaults.set(data, forKey: key)
        }
    }

    static func activeProjectPath(in defaults: UserDefaults = .standard) -> String? {
        defaults.string(forKey: activeKey)
    }

    static func setActiveProjectPath(
        _ path: String?,
        defaults: UserDefaults = .standard
    ) {
        defaults.set(path, forKey: activeKey)
    }

    static var activeProjectPath: String? {
        get { activeProjectPath() }
        set { setActiveProjectPath(newValue) }
    }
}
