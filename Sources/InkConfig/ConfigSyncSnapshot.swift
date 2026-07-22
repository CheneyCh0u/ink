import Foundation

public enum ConfigSyncSnapshotError: Error, Equatable, Sendable {
    case unsupportedSchema(Int)
    case invalidPayload
}

/// iCloud 中的版本化配置快照。Wire 格式与本地 TOML 解耦，变更必须显式迁移。
public struct ConfigSyncSnapshot: Equatable, Sendable {
    public static let currentSchemaVersion = 1

    public let schemaVersion: Int
    public let modifiedAt: Date
    public let deviceID: String
    public let config: InkConfig

    public init(config: InkConfig, modifiedAt: Date, deviceID: String) {
        self.schemaVersion = Self.currentSchemaVersion
        self.modifiedAt = modifiedAt
        self.deviceID = deviceID
        self.config = config
    }

    public func encoded() throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        return try encoder.encode(WireSnapshot(snapshot: self))
    }

    public static func decode(_ data: Data) throws -> ConfigSyncSnapshot {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let wire = try decoder.decode(WireSnapshot.self, from: data)
        guard wire.schemaVersion == currentSchemaVersion else {
            throw ConfigSyncSnapshotError.unsupportedSchema(wire.schemaVersion)
        }
        return try wire.validatedSnapshot()
    }
}

private struct WireSnapshot: Codable {
    let schemaVersion: Int
    let modifiedAt: Date
    let deviceID: String
    let config: WireConfig

    init(snapshot: ConfigSyncSnapshot) {
        schemaVersion = snapshot.schemaVersion
        modifiedAt = snapshot.modifiedAt
        deviceID = snapshot.deviceID
        config = WireConfig(config: snapshot.config)
    }

    func validatedSnapshot() throws -> ConfigSyncSnapshot {
        guard !deviceID.isEmpty else { throw ConfigSyncSnapshotError.invalidPayload }
        return ConfigSyncSnapshot(
            config: try config.validatedConfig(),
            modifiedAt: modifiedAt,
            deviceID: deviceID
        )
    }
}

private struct WireConfig: Codable {
    let appearanceMode: String
    let startupSidebarMode: String
    let rememberWindowFrame: Bool
    let windowWidth: Int
    let windowHeight: Int
    let fontFamily: String?
    let fontSize: Double
    let lineHeight: Double
    let fontCellHeightAdjustment: Int
    let fontThicken: Bool
    let fontThickenStrength: Int
    let terminalTheme: String
    let cursorStyle: String
    let cursorBlink: Bool
    let optionAsMeta: Bool
    let copyOnSelect: Bool
    let osc52WriteEnabled: Bool?
    let scrollbackLines: Int

    init(config: InkConfig) {
        appearanceMode = config.appearanceMode.rawValue
        startupSidebarMode = config.startupSidebarMode.rawValue
        rememberWindowFrame = config.rememberWindowFrame
        windowWidth = config.windowWidth
        windowHeight = config.windowHeight
        fontFamily = config.fontFamily
        fontSize = config.fontSize
        lineHeight = config.lineHeight
        fontCellHeightAdjustment = config.fontCellHeightAdjustment
        fontThicken = config.fontThicken
        fontThickenStrength = config.fontThickenStrength
        terminalTheme = config.terminalTheme.rawValue
        cursorStyle = config.cursorStyle.rawValue
        cursorBlink = config.cursorBlink
        optionAsMeta = config.optionAsMeta
        copyOnSelect = config.copyOnSelect
        osc52WriteEnabled = config.osc52WriteEnabled
        scrollbackLines = config.scrollbackLines
    }

    func validatedConfig() throws -> InkConfig {
        guard let appearanceMode = InkConfig.AppearanceMode(rawValue: appearanceMode),
              let startupSidebarMode = InkConfig.SidebarMode(rawValue: startupSidebarMode),
              let terminalTheme = InkConfig.TerminalTheme(rawValue: terminalTheme),
              let cursorStyle = InkConfig.CursorStyle(rawValue: cursorStyle),
              (640...4096).contains(windowWidth),
              (400...2160).contains(windowHeight),
              fontSize.isFinite, (6...72).contains(fontSize),
              lineHeight.isFinite, (0.8...2.0).contains(lineHeight),
              (-10...20).contains(fontCellHeightAdjustment),
              (0...255).contains(fontThickenStrength),
              (100...2_000_000).contains(scrollbackLines) else {
            throw ConfigSyncSnapshotError.invalidPayload
        }

        var result = InkConfig()
        result.appearanceMode = appearanceMode
        result.startupSidebarMode = startupSidebarMode
        result.rememberWindowFrame = rememberWindowFrame
        result.windowWidth = windowWidth
        result.windowHeight = windowHeight
        result.fontFamily = fontFamily
        result.fontSize = fontSize
        result.lineHeight = lineHeight
        result.fontCellHeightAdjustment = fontCellHeightAdjustment
        result.fontThicken = fontThicken
        result.fontThickenStrength = fontThickenStrength
        result.terminalTheme = terminalTheme
        result.cursorStyle = cursorStyle
        result.cursorBlink = cursorBlink
        result.optionAsMeta = optionAsMeta
        result.copyOnSelect = copyOnSelect
        result.osc52WriteEnabled = osc52WriteEnabled ?? true
        result.scrollbackLines = scrollbackLines
        return result
    }
}
