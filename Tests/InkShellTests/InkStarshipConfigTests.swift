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
        let indexedColor = try NSRegularExpression(
            pattern: #"(?:fg|bg):(1[6-9]|[2-9][0-9]|1[0-9]{2}|2[0-5][0-9])\b"#
        )
        #expect(indexedColor.firstMatch(in: text, range: range) == nil)
        #expect(text.contains("bg:bright-purple"))
        #expect(text.contains("bg:bright-black"))
    }

    @Test("首次安装原子写入，相同内容不重写")
    func installWritesOnlyWhenContentsChange() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("ink-starship-install-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("starship.toml")

        #expect(try InkStarshipConfig.install(at: url))
        #expect(try String(contentsOf: url, encoding: .utf8) == InkStarshipConfig.managedContents)
        #expect(try InkStarshipConfig.install(at: url) == false)
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
