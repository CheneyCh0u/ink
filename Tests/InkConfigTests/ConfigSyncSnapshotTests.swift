import Foundation
import Testing
@testable import InkConfig

@Suite("配置同步快照")
struct ConfigSyncSnapshotTests {
    @Test("旧 schema 1 缺少 OSC 52 字段时迁移为开启")
    func oldSchemaDefaultsOSC52ToEnabled() throws {
        let data = try snapshotJSON { root in
            var config = try #require(root["config"] as? [String: Any])
            config.removeValue(forKey: "osc52WriteEnabled")
            root["config"] = config
        }
        #expect(try ConfigSyncSnapshot.decode(data).config.osc52WriteEnabled)
    }

    @Test("schema 1 JSON 完整往返所有已知设置")
    func roundTripsEveryKnownSetting() throws {
        let config = completeConfig()
        let original = ConfigSyncSnapshot(
            config: config,
            modifiedAt: Date(timeIntervalSince1970: 1_785_000_000),
            deviceID: "mac-a"
        )

        let data = try original.encoded()
        let decoded = try ConfigSyncSnapshot.decode(data)
        let object = try #require(
            JSONSerialization.jsonObject(with: data) as? [String: Any]
        )

        #expect(decoded == original)
        #expect(decoded.schemaVersion == 1)
        #expect(decoded.config == config)
        #expect(object["schemaVersion"] != nil)
        #expect(object["modifiedAt"] != nil)
        #expect(object["deviceID"] != nil)
        #expect(object["config"] != nil)
    }

    @Test("schema 1 兼容旧快照并往返快捷键")
    func migratesMissingKeyBindingsAndRoundTripsOverrides() throws {
        let legacy = try snapshotJSON { root in
            var config = try #require(root["config"] as? [String: Any])
            config.removeValue(forKey: "keyBindings")
            root["config"] = config
        }
        #expect(try ConfigSyncSnapshot.decode(legacy).config.keyBindings == .defaults)

        var config = completeConfig()
        _ = config.setKeyBinding(
            .binding(try #require(KeyBinding.parse("ctrl+shift+t"))),
            for: .newTab
        )
        _ = config.setKeyBinding(.disabled, for: .splitRight)
        let snapshot = ConfigSyncSnapshot(
            config: config,
            modifiedAt: Date(timeIntervalSince1970: 1_785_000_000),
            deviceID: "mac-a"
        )
        #expect(try ConfigSyncSnapshot.decode(snapshot.encoded()).config == config)
    }

    @Test("拒绝当前 Ink 不认识的新版 schema")
    func rejectsNewerSchema() throws {
        let data = try snapshotJSON { root in
            root["schemaVersion"] = 2
        }

        #expect(throws: ConfigSyncSnapshotError.unsupportedSchema(2)) {
            try ConfigSyncSnapshot.decode(data)
        }
    }

    @Test("拒绝越界字段而不是部分应用")
    func rejectsInvalidPayload() throws {
        let data = try snapshotJSON { root in
            var config = try #require(root["config"] as? [String: Any])
            config["fontSize"] = 100
            root["config"] = config
        }

        #expect(throws: ConfigSyncSnapshotError.invalidPayload) {
            try ConfigSyncSnapshot.decode(data)
        }
    }

    @Test("损坏 JSON 抛出解码错误")
    func rejectsBrokenJSON() {
        #expect(throws: (any Error).self) {
            try ConfigSyncSnapshot.decode(Data("{broken".utf8))
        }
    }

    private func snapshotJSON(
        mutate: (inout [String: Any]) throws -> Void
    ) throws -> Data {
        let snapshot = ConfigSyncSnapshot(
            config: completeConfig(),
            modifiedAt: Date(timeIntervalSince1970: 1_785_000_000),
            deviceID: "mac-a"
        )
        var root = try #require(
            JSONSerialization.jsonObject(with: snapshot.encoded()) as? [String: Any]
        )
        try mutate(&root)
        return try JSONSerialization.data(withJSONObject: root, options: [.sortedKeys])
    }

    private func completeConfig() -> InkConfig {
        var config = InkConfig()
        config.appearanceMode = .dark
        config.startupSidebarMode = .hidden
        config.rememberWindowFrame = false
        config.windowWidth = 1440
        config.windowHeight = 900
        config.fontFamily = nil
        config.fontSize = 17
        config.lineHeight = 1.25
        config.fontCellHeightAdjustment = -2
        config.fontThicken = false
        config.fontThickenStrength = 64
        config.terminalTheme = .pine
        config.cursorStyle = .underline
        config.cursorBlink = false
        config.optionAsMeta = false
        config.copyOnSelect = true
        config.osc52WriteEnabled = false
        config.scrollbackLines = 250_000
        return config
    }
}
