import Foundation

/// 一个项目 = 一个目录 + 若干会话（标签）。
/// 项目列表持久化；会话是运行态，随进程生灭。
@MainActor
final class Project {
    let directory: URL
    var sessions: [TerminalSession] = []
    var activeSessionIndex = 0

    init(directory: URL) {
        self.directory = directory
    }

    /// 侧边栏显示名：`~/work/code/ink` 式的缩写路径。
    var displayName: String {
        (directory.path as NSString).abbreviatingWithTildeInPath
    }

    var activeSession: TerminalSession? {
        sessions.indices.contains(activeSessionIndex) ? sessions[activeSessionIndex] : nil
    }
}

/// 项目列表持久化。UserDefaults 足够：这是应用状态不是用户配置，
/// 不进将来的 TOML 配置文件（任务 #13）。
enum ProjectStore {
    private static let key = "ink.projects"
    private static let activeKey = "ink.activeProject"

    static func load() -> [URL] {
        let paths = UserDefaults.standard.stringArray(forKey: key) ?? []
        return paths.compactMap { path in
            let url = URL(fileURLWithPath: (path as NSString).expandingTildeInPath)
            // 目录没了就静默剔除（外置盘、已删除的项目）。
            var isDir: ObjCBool = false
            let exists = FileManager.default.fileExists(atPath: url.path, isDirectory: &isDir)
            return exists && isDir.boolValue ? url : nil
        }
    }

    static func save(_ directories: [URL]) {
        let paths = directories.map { ($0.path as NSString).abbreviatingWithTildeInPath }
        UserDefaults.standard.set(paths, forKey: key)
    }

    static var activeProjectPath: String? {
        get { UserDefaults.standard.string(forKey: activeKey) }
        set { UserDefaults.standard.set(newValue, forKey: activeKey) }
    }
}
