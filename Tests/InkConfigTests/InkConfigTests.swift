import Foundation
import Testing
@testable import InkConfig

@Suite("MiniTOML")
struct MiniTOMLTests {
    @Test("分节、类型、注释、下划线数字")
    func basicParsing() {
        let values = MiniTOML.parse("""
        # 顶部注释
        top = "level"

        [font]
        size = 14.5   # 行尾注释

        [cursor]
        style = "bar"
        blink = false

        [scrollback]
        lines = 100_000
        """)
        #expect(values.string("top") == "level")
        #expect(values.double("font.size") == 14.5)
        #expect(values.string("cursor.style") == "bar")
        #expect(values.bool("cursor.blink") == false)
        #expect(values.int("scrollback.lines") == 100_000)
    }

    @Test("字符串里的 # 与转义不受注释剥离影响")
    func hashInsideString() {
        let values = MiniTOML.parse(#"title = "a # b \"c\"""#)
        #expect(values.string("title") == "a # b \"c\"")
    }

    @Test("坏行跳过不炸，整数当浮点取也行")
    func toleratesGarbage() {
        let values = MiniTOML.parse("""
        ???
        [ok]
        good = 1
        broken =
        = broken
        """)
        #expect(values.int("ok.good") == 1)
        #expect(values.double("ok.good") == 1)
        #expect(values.count == 1)
    }

    @Test("更新已知键时保留注释与未知内容")
    func updatingPreservesHandwrittenContent() {
        let updated = MiniTOML.updating(
            """
            # 用户写的说明
            custom = "keep"

            [font]
            size = 13   # 行尾注释
            experimental = true
            """,
            values: [
                ("font.size", "16"),
                ("cursor.style", #""bar""#),
            ]
        )

        #expect(updated.contains("# 用户写的说明"))
        #expect(updated.contains(#"custom = "keep""#))
        #expect(updated.contains("size = 16   # 行尾注释"))
        #expect(updated.contains("experimental = true"))
        #expect(updated.contains("[cursor]"))
        #expect(updated.contains(#"style = "bar""#))
    }
}

@Suite("InkConfig")
struct InkConfigTests {
    @Test("文件缺失回默认值")
    func missingFileGivesDefaults() {
        let config = InkConfig.load(from: URL(fileURLWithPath: "/nonexistent/ink.toml"))
        #expect(config == InkConfig())
    }

    @Test("合法配置逐项覆盖，非法值回默认")
    func loadAndClamp() throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("ink-test-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let file = dir.appendingPathComponent("config.toml")
        try """
        [font]
        size = 16

        [cursor]
        style = "underline"
        blink = false

        [input]
        option_as_meta = false

        [scrollback]
        lines = 5   # 低于下限，应被拒
        """.write(to: file, atomically: true, encoding: .utf8)

        let config = InkConfig.load(from: file)
        #expect(config.fontSize == 16)
        #expect(config.cursorStyle == .underline)
        #expect(config.cursorBlink == false)
        #expect(config.optionAsMeta == false)
        #expect(config.scrollbackLines == InkConfig().scrollbackLines) // 非法回默认
        #expect(config.copyOnSelect == false) // 未配置保持默认
    }

    @Test("设置写回后完整往返并保留未知字段")
    func saveRoundtripPreservesUnknownFields() throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("ink-save-test-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let file = dir.appendingPathComponent("config.toml")
        try """
        # 这行必须保留
        [custom]
        future_option = "keep"

        [font]
        size = 12 # 保留行尾注释
        """.write(to: file, atomically: true, encoding: .utf8)

        var config = InkConfig()
        config.appearanceMode = .dark
        config.startupSidebarMode = .compact
        config.rememberWindowFrame = false
        config.windowWidth = 1440
        config.windowHeight = 900
        config.fontFamily = "Menlo"
        config.fontSize = 16
        config.lineHeight = 1.35
        config.cursorStyle = .bar
        config.cursorBlink = false
        config.optionAsMeta = false
        config.copyOnSelect = true
        config.scrollbackLines = 250_000
        try config.save(to: file)

        let text = try String(contentsOf: file, encoding: .utf8)
        #expect(text.contains("# 这行必须保留"))
        #expect(text.contains(#"future_option = "keep""#))
        #expect(text.contains("size = 16 # 保留行尾注释"))
        #expect(InkConfig.load(from: file) == config)
    }
}
