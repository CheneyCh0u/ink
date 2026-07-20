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

    var activeTab: TerminalTab? {
        tabs.indices.contains(activeTabIndex) ? tabs[activeTabIndex] : nil
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
    static func load() -> [Project] {
        var stored: [Stored] = []
        if let data = UserDefaults.standard.data(forKey: key),
           let decoded = try? JSONDecoder().decode([Stored].self, from: data) {
            stored = decoded
        } else if let legacy = UserDefaults.standard.stringArray(forKey: legacyKey) {
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
    static func save(_ projects: [Project]) {
        let stored = projects.map {
            Stored(
                path: $0.displayName,
                pinned: $0.pinned,
                note: $0.note,
                label: $0.label == .none ? nil : $0.label.rawValue
            )
        }
        if let data = try? JSONEncoder().encode(stored) {
            UserDefaults.standard.set(data, forKey: key)
        }
    }

    static var activeProjectPath: String? {
        get { UserDefaults.standard.string(forKey: activeKey) }
        set { UserDefaults.standard.set(newValue, forKey: activeKey) }
    }
}
