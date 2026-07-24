import Foundation
import InkConfig
import Testing
@testable import InkShell

@Suite("Ink Starship 配置")
struct InkStarshipConfigTests {
    @Test("模板保留约定分段且只使用 ANSI 命名色")
    func templateUsesSemanticANSIColors() throws {
        let text = InkStarshipConfig.managedContents
        for segment in [
            "$os", "$directory", "$git_branch", "$git_status",
            "$nodejs", "$python", "$rust", "$golang", "$java",
            "$conda", "$docker_context", "$time", "$cmd_duration", "$character",
        ] {
            #expect(text.contains(segment), "缺少 \(segment)")
        }
        let hex = try NSRegularExpression(pattern: #"#[0-9A-Fa-f]{6}"#)
        let range = NSRange(text.startIndex..<text.endIndex, in: text)
        #expect(hex.firstMatch(in: text, range: range) == nil)
        #expect(!text.contains("rgb("))
        #expect(try !containsIndexedColor(text))
        #expect(text.contains("bg:bright-purple"))
        #expect(text.contains("bg:bright-black"))
    }

    @Test("数字颜色检测覆盖独立样式且不误伤普通数字")
    func indexedColorDetectionUnderstandsStarshipStyles() throws {
        #expect(try containsIndexedColor("format = '[x](16)'"))
        #expect(try containsIndexedColor("format = '[x](17)'"))
        #expect(try containsIndexedColor("format = '[x](255)'"))
        #expect(try !containsIndexedColor("truncation_length = 255"))
    }

    @Test("首次安装原子写入，相同内容不重写")
    func installWritesOnlyWhenContentsChange() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("ink-starship-install-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("starship.toml")

        #expect(try InkStarshipConfig.install(at: url))
        #expect(try String(contentsOf: url, encoding: .utf8) == InkStarshipConfig.managedContents)
        #expect(try posixPermissions(at: directory) == 0o700)
        #expect(try posixPermissions(at: url) == 0o600)
        let identity = try fileIdentity(at: url)
        #expect(try InkStarshipConfig.install(at: url) == false)
        #expect(try fileIdentity(at: url) == identity)
    }

    @Test("拒绝符号链接父目录且不触碰链接目标")
    func installRejectsSymlinkedParentDirectory() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("ink-starship-symlink-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let emptyTarget = root.appendingPathComponent("empty-target")
        let userTarget = root.appendingPathComponent("user-target")
        try FileManager.default.createDirectory(at: emptyTarget, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: userTarget, withIntermediateDirectories: true)

        let emptyLink = root.appendingPathComponent("empty-link")
        try FileManager.default.createSymbolicLink(at: emptyLink, withDestinationURL: emptyTarget)
        let emptyConfig = emptyLink.appendingPathComponent("starship.toml")
        #expect(throws: (any Error).self) {
            try InkStarshipConfig.install(at: emptyConfig)
        }
        #expect(!FileManager.default.fileExists(
            atPath: emptyTarget.appendingPathComponent("starship.toml").path
        ))

        let userConfig = userTarget.appendingPathComponent("starship.toml")
        try "user configuration".write(to: userConfig, atomically: true, encoding: .utf8)
        let userLink = root.appendingPathComponent("user-link")
        try FileManager.default.createSymbolicLink(at: userLink, withDestinationURL: userTarget)
        #expect(throws: (any Error).self) {
            try InkStarshipConfig.install(at: userLink.appendingPathComponent("starship.toml"))
        }
        #expect(try String(contentsOf: userConfig, encoding: .utf8) == "user configuration")
    }

    @Test("拒绝非目录父路径且不修改原文件")
    func installRejectsNonDirectoryParent() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("ink-starship-nondirectory-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let parent = root.appendingPathComponent("not-a-directory")
        try "parent contents".write(to: parent, atomically: true, encoding: .utf8)

        #expect(throws: (any Error).self) {
            try InkStarshipConfig.install(
                at: parent.appendingPathComponent("starship.toml")
            )
        }
        #expect(try String(contentsOf: parent, encoding: .utf8) == "parent contents")
    }

    @Test("拒绝硬链接托管文件且不修改链接目标")
    func installRejectsHardLinkedManagedFile() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("ink-starship-hardlink-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let directory = root.appendingPathComponent("managed")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let userConfig = root.appendingPathComponent("user-starship.toml")
        try InkStarshipConfig.managedContents.write(
            to: userConfig,
            atomically: true,
            encoding: .utf8
        )
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o666],
            ofItemAtPath: userConfig.path
        )
        let managedConfig = directory.appendingPathComponent("starship.toml")
        try FileManager.default.linkItem(at: userConfig, to: managedConfig)

        #expect(throws: (any Error).self) {
            try InkStarshipConfig.install(at: managedConfig)
        }
        #expect(try String(contentsOf: userConfig, encoding: .utf8) == InkStarshipConfig.managedContents)
        #expect(try posixPermissions(at: userConfig) == 0o666)
    }

    @Test("相同内容仍收紧托管目录与文件权限")
    func installRepairsPermissionsWithoutRewritingContents() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("ink-starship-permissions-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: directory) }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let url = directory.appendingPathComponent("starship.toml")
        try InkStarshipConfig.managedContents.write(to: url, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o777],
            ofItemAtPath: directory.path
        )
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o666],
            ofItemAtPath: url.path
        )
        let identity = try fileIdentity(at: url)

        #expect(try InkStarshipConfig.install(at: url) == false)
        #expect(try String(contentsOf: url, encoding: .utf8) == InkStarshipConfig.managedContents)
        #expect(try fileIdentity(at: url) == identity)
        #expect(try posixPermissions(at: directory) == 0o700)
        #expect(try posixPermissions(at: url) == 0o600)
    }

    @Test("只有 Ink 来源写入文件并覆盖 STARSHIP_CONFIG")
    func sourceControlsEnvironmentOverride() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("ink-starship-source-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("starship.toml")

        #expect(try InkStarshipConfig.environmentOverrides(for: .user, configURL: url).isEmpty)
        #expect(!FileManager.default.fileExists(atPath: url.path))
        try FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: true
        )
        try "user configuration".write(to: url, atomically: true, encoding: .utf8)
        #expect(try InkStarshipConfig.environmentOverrides(for: .user, configURL: url).isEmpty)
        #expect(try String(contentsOf: url, encoding: .utf8) == "user configuration")
        #expect(try InkStarshipConfig.environmentOverrides(for: .ink, configURL: url) == [
            "STARSHIP_CONFIG": url.path,
        ])
        #expect(FileManager.default.fileExists(atPath: url.path))
    }

    @Test("本机 Starship 可解析 Ink 模板")
    func installedStarshipParsesTemplate() throws {
        let executable = ["/opt/homebrew/bin/starship", "/usr/local/bin/starship"]
            .first { FileManager.default.isExecutableFile(atPath: $0) }
        guard let executable else { return }
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("ink-starship-parse-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("starship.toml")
        try InkStarshipConfig.install(at: url)

        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = ["prompt"]
        process.environment = ProcessInfo.processInfo.environment.merging([
            "TERM": "xterm-256color",
            "COLORTERM": "truecolor",
            "STARSHIP_CONFIG": url.path,
        ]) { _, override in override }
        process.standardOutput = Pipe()
        let errors = Pipe()
        process.standardError = errors
        try process.run()
        process.waitUntilExit()
        let diagnostic = String(
            data: errors.fileHandleForReading.readDataToEndOfFile(),
            encoding: .utf8
        ) ?? ""
        #expect(process.terminationStatus == 0)
        #expect(diagnostic.isEmpty)
    }
}

private func containsIndexedColor(_ text: String) throws -> Bool {
    let stylePrefix = #"(?:\b(?:fg|bg):|\]\([^)]*|(?:^|\n)\s*style\s*=\s*["'][^"']*)"#
    let colorIndex = #"(?<![0-9])(?:1[6-9]|[2-9][0-9]|1[0-9]{2}|2[0-5][0-9])(?![0-9])"#
    let expression = try NSRegularExpression(pattern: stylePrefix + colorIndex)
    let range = NSRange(text.startIndex..<text.endIndex, in: text)
    return expression.firstMatch(in: text, range: range) != nil
}

private func posixPermissions(at url: URL) throws -> Int {
    let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
    let permissions = try #require(attributes[.posixPermissions] as? NSNumber)
    return permissions.intValue & 0o777
}

private struct FileIdentity: Equatable {
    let inode: UInt64
    let modificationDate: Date
}

private func fileIdentity(at url: URL) throws -> FileIdentity {
    let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
    let inode = try #require(attributes[.systemFileNumber] as? NSNumber)
    let modificationDate = try #require(attributes[.modificationDate] as? Date)
    return FileIdentity(
        inode: inode.uint64Value,
        modificationDate: modificationDate
    )
}
