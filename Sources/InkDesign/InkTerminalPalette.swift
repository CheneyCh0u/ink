import AppKit

/// 终端内容区调色板：ANSI 16 色 + 前景 / 背景 / 光标 / 选区。
///
/// 与 `InkDesignTokens.Color` 的分工：外壳用动态 `NSColor`，渲染热路径用本文件的
/// **值快照**——`TerminalColor` 是打包的 sRGB 值，外观切换时渲染器整体换一份快照
/// 并重传 uniform，帧循环内没有任何动态解色和 ARC 流量。
///
/// 两套配色不是互为反相：浅色套在 `#FDFDFD` 上压暗保对比，深色套在 `#111314`
/// 上提亮防发虚。语义上与外壳 token 对齐——ANSI green/cyan/magenta 分别落在
/// success / accent / branch 同一色相族上，终端输出和外壳 UI 不会各说各话。
public struct InkTerminalPalette: Sendable, Equatable {
    /// 打包 sRGB 颜色值（0xRRGGBB）。渲染器负责转成自己的顶点 / uniform 格式。
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
    /// 选区底色。渲染时按固定不透明度与背景混合，值本身是不带 alpha 的纯色。
    public let selection: TerminalColor
    /// 搜索结果使用的强调色；普通与当前结果由渲染器采用不同混合强度。
    public let searchHighlight: TerminalColor

    // MARK: - 内置两套

    /// 浅色：终端底 `#FDFDFD`。整体压暗、降饱和，黄色最容易在白底上发虚，压得最狠。
    public static let mistLight = InkTerminalPalette(
        ansi: [
            // 0-7: black red green yellow blue magenta cyan white
            0x3A3C42, 0xC13B30, 0x2E8548, 0x9C7211,
            0x3465A8, 0x8A4BB4, 0x0E7F96, 0xC6C7CB,
            // 8-15
            0x6E7076, 0xD85145, 0x3B9A5C, 0xB8891F,
            0x4A7FC9, 0xA468D0, 0x1FA3BE, 0xECEDEF,
        ],
        defaultForeground: 0x303238,
        defaultBackground: 0xFDFDFD,
        cursor: 0x168FAF,
        selection: 0xC3E0E8,
        searchHighlight: 0x168FAF
    )

    /// 深色：终端底 `#111314`。green / yellow / magenta / cyan 直接复用外壳深色
    /// 语义色，红蓝按同明度配平。正文不用纯白，与外壳纪律一致。
    public static let mistDark = InkTerminalPalette(
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

    /// 按外观取对应快照。只在外观切换时调用，不进帧循环。
    public static func current(for appearance: NSAppearance) -> InkTerminalPalette {
        appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua ? .mistDark : .mistLight
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
