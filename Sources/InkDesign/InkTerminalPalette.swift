import AppKit

/// 用户可选的终端配色家族。每个家族同时提供浅色与深色快照。
public enum InkTerminalTheme: String, CaseIterable, Sendable {
    case warm
    case graphite
    case pine
    case plum
    case neutral

    public var displayName: String {
        switch self {
        case .warm: "暖墨"
        case .graphite: "石墨蓝"
        case .pine: "松针"
        case .plum: "紫墨"
        case .neutral: "中性炭"
        }
    }

    public func palette(for appearance: NSAppearance) -> InkTerminalPalette {
        palette(
            for: appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
                ? .dark
                : .light
        )
    }

    public func palette(for variant: InkTerminalPalette.Variant) -> InkTerminalPalette {
        switch (self, variant) {
        case (.warm, .light): .warmLight
        case (.warm, .dark): .warmDark
        case (.graphite, .light): .graphiteLight
        case (.graphite, .dark): .graphiteDark
        case (.pine, .light): .pineLight
        case (.pine, .dark): .pineDark
        case (.plum, .light): .plumLight
        case (.plum, .dark): .plumDark
        case (.neutral, .light): .neutralLight
        case (.neutral, .dark): .neutralDark
        }
    }
}

/// 终端内容区调色板：ANSI 16 色 + 前景 / 背景 / 光标 / 选区。
///
/// 与 `InkDesignTokens.Color` 的分工：外壳用动态 `NSColor`，渲染热路径用本文件的
/// 值快照。主题或系统外观变化时只替换一次 renderer uniform，帧循环内没有动态
/// 解色、字符串查找或 ARC 流量。
public struct InkTerminalPalette: Sendable, Equatable {
    public enum Variant: Sendable {
        case light
        case dark
    }

    /// 打包 sRGB 颜色值（0xRRGGBB）。渲染器负责转成顶点 / uniform 格式。
    public struct TerminalColor: Sendable, Equatable {
        public let rgb: UInt32

        public init(_ rgb: UInt32) { self.rgb = rgb }

        public var red: UInt8 { UInt8((rgb >> 16) & 0xFF) }
        public var green: UInt8 { UInt8((rgb >> 8) & 0xFF) }
        public var blue: UInt8 { UInt8(rgb & 0xFF) }
    }

    /// ANSI 0–15。0–7 标准色，8–15 高亮色。
    public let ansi: [TerminalColor]
    public let defaultForeground: TerminalColor
    public let defaultBackground: TerminalColor
    public let cursor: TerminalColor
    /// 选区底色。渲染时按固定不透明度与背景混合，值本身不带 alpha。
    public let selection: TerminalColor
    /// 搜索结果强调色；普通与当前结果由渲染器采用不同混合强度。
    public let searchHighlight: TerminalColor

    // MARK: - 暖墨

    static let warmLight = InkTerminalPalette(
        ansi: [
            0x3D3929, 0xB3423A, 0x4E7A44, 0x9A6D24,
            0x2E5F8F, 0x8B3F7A, 0x2E6E6B, 0xA8A089,
            0x6B6659, 0xCC5A4F, 0x6A9462, 0xB88732,
            0x4A7FB0, 0xA65895, 0x4A8F8C, 0x3D3929,
        ],
        defaultForeground: 0x3D3929,
        defaultBackground: 0xF5EEDC,
        cursor: 0xCC785C,
        selection: 0xE6DCC0,
        searchHighlight: 0xCC785C
    )

    static let warmDark = InkTerminalPalette(
        ansi: [
            0x3B352B, 0xE07A6A, 0x87B97B, 0xD8AD65,
            0x78A7D1, 0xC58CB6, 0x72AAA5, 0xD8CFBC,
            0x6C6457, 0xF08B7A, 0xA1CC96, 0xEBC27A,
            0x96BDE0, 0xD8A6C9, 0x91C2BD, 0xF2EBDD,
        ],
        defaultForeground: 0xE8DFCC,
        defaultBackground: 0x17140F,
        cursor: 0xCC785C,
        selection: 0x493A31,
        searchHighlight: 0xCC785C
    )

    // MARK: - 石墨蓝

    static let graphiteLight = InkTerminalPalette(
        ansi: [
            0x303844, 0xB5484D, 0x3F7B5A, 0x9B742D,
            0x386FA4, 0x805D9E, 0x317B82, 0xBFC5CC,
            0x667080, 0xCC5D62, 0x55946F, 0xB68C43,
            0x4F88BD, 0x9875B5, 0x48939A, 0xE7EAF0,
        ],
        defaultForeground: 0x303844,
        defaultBackground: 0xF7F9FC,
        cursor: 0x386FA4,
        selection: 0xD6E3F1,
        searchHighlight: 0x386FA4
    )

    static let graphiteDark = InkTerminalPalette(
        ansi: [
            0x46515E, 0xED7A7F, 0x73B68C, 0xD7B46A,
            0x77AEE0, 0xB097D2, 0x67B1BA, 0xC9D1DA,
            0x697685, 0xFF9397, 0x91CBA4, 0xE9C981,
            0x96C3EE, 0xC8AFE2, 0x87C9D0, 0xEEF3F8,
        ],
        defaultForeground: 0xDCE3EC,
        defaultBackground: 0x101419,
        cursor: 0x77AEE0,
        selection: 0x293D50,
        searchHighlight: 0x77AEE0
    )

    // MARK: - 松针

    static let pineLight = InkTerminalPalette(
        ansi: [
            0x263A34, 0xB74A46, 0x397258, 0x8D762D,
            0x386D88, 0x775A84, 0x287879, 0xBBC5BF,
            0x64736E, 0xCD605B, 0x4E8C6C, 0xA58D43,
            0x50869F, 0x906FA0, 0x3D9292, 0xE7ECE9,
        ],
        defaultForeground: 0x263A34,
        defaultBackground: 0xF5F8F6,
        cursor: 0x287879,
        selection: 0xD3E7DE,
        searchHighlight: 0x287879
    )

    static let pineDark = InkTerminalPalette(
        ansi: [
            0x3B4C44, 0xE47D75, 0x71B68D, 0xD1B66D,
            0x74A9C0, 0xAE91B8, 0x68B8B2, 0xC5D4CB,
            0x60736A, 0xF2948C, 0x8FCBA4, 0xE2C984,
            0x91C0D3, 0xC5A9CE, 0x86CEC7, 0xEAF2ED,
        ],
        defaultForeground: 0xD9E8DF,
        defaultBackground: 0x101713,
        cursor: 0x68B8B2,
        selection: 0x29483C,
        searchHighlight: 0x68B8B2
    )

    // MARK: - 紫墨

    static let plumLight = InkTerminalPalette(
        ansi: [
            0x3C3443, 0xB6475B, 0x4D795F, 0x96702D,
            0x4E6599, 0x86588C, 0x34777A, 0xC2BBC5,
            0x746B79, 0xCD5E70, 0x638F75, 0xAE8743,
            0x687DB0, 0x9F70A5, 0x4D9193, 0xECE8ED,
        ],
        defaultForeground: 0x3C3443,
        defaultBackground: 0xFAF7FA,
        cursor: 0x86588C,
        selection: 0xE8D9E9,
        searchHighlight: 0x86588C
    )

    static let plumDark = InkTerminalPalette(
        ansi: [
            0x4C414F, 0xEA788D, 0x83B392, 0xD3AF66,
            0x879FD3, 0xC28FC7, 0x70B2B2, 0xD2C8D3,
            0x756A78, 0xFA90A2, 0x9CC8A8, 0xE5C27D,
            0xA2B6E3, 0xD5A8D9, 0x8BC9C8, 0xF2EAF3,
        ],
        defaultForeground: 0xE8DDE9,
        defaultBackground: 0x171218,
        cursor: 0xC28FC7,
        selection: 0x4A304B,
        searchHighlight: 0xC28FC7
    )

    // MARK: - 中性炭

    static let neutralLight = InkTerminalPalette(
        ansi: [
            0x34363A, 0xB54C48, 0x467657, 0x8C702E,
            0x456E9A, 0x795D8F, 0x3A777C, 0xC6C7CB,
            0x74777D, 0xCC625D, 0x5C8E6B, 0xA78945,
            0x5D87B2, 0x9275A7, 0x529095, 0xECEDEF,
        ],
        defaultForeground: 0x34363A,
        defaultBackground: 0xFDFDFD,
        cursor: 0x456E9A,
        selection: 0xD9E1EA,
        searchHighlight: 0x456E9A
    )

    static let neutralDark = InkTerminalPalette(
        ansi: [
            0x4A4D55, 0xEF7A6D, 0x67C88D, 0xD9B25E,
            0x79A9E8, 0xC29ADA, 0x58B6C9, 0xC8CACF,
            0x6C6F78, 0xFF958A, 0x8ADBA8, 0xEBC97E,
            0x99C0F5, 0xD7B4EE, 0x7BD2E2, 0xF0F2F5,
        ],
        defaultForeground: 0xE2E3DF,
        defaultBackground: 0x111314,
        cursor: 0x58B6C9,
        selection: 0x2A4A54,
        searchHighlight: 0x58B6C9
    )

    /// 兼容原有调用和默认视觉名称。
    public static let mistLight = neutralLight
    public static let mistDark = neutralDark

    /// 默认中性主题，旧调用保持原有按外观切换的语义。
    public static func current(for appearance: NSAppearance) -> InkTerminalPalette {
        InkTerminalTheme.neutral.palette(for: appearance)
    }

    init(
        ansi: [UInt32],
        defaultForeground: UInt32,
        defaultBackground: UInt32,
        cursor: UInt32,
        selection: UInt32,
        searchHighlight: UInt32
    ) {
        precondition(ansi.count == 16, "ANSI 调色板必须是 16 色")
        self.ansi = ansi.map(TerminalColor.init)
        self.defaultForeground = TerminalColor(defaultForeground)
        self.defaultBackground = TerminalColor(defaultBackground)
        self.cursor = TerminalColor(cursor)
        self.selection = TerminalColor(selection)
        self.searchHighlight = TerminalColor(searchHighlight)
    }
}

extension InkTerminalPalette.TerminalColor {
    /// 桥接给外壳 UI（预览、设置界面）。渲染热路径不得调用。
    public var nsColor: NSColor {
        NSColor(
            srgbRed: CGFloat(red) / 255,
            green: CGFloat(green) / 255,
            blue: CGFloat(blue) / 255,
            alpha: 1
        )
    }
}
