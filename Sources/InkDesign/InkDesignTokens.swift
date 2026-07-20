import AppKit

/// Finder 式项目颜色标记。`.none` 也参与持久化和菜单选择。
public enum InkProjectLabel: String, CaseIterable, Codable, Sendable {
    case none
    case red
    case orange
    case yellow
    case green
    case blue
    case purple
    case gray

    public var title: String {
        switch self {
        case .none: "无颜色"
        case .red: "红色"
        case .orange: "橙色"
        case .yellow: "黄色"
        case .green: "绿色"
        case .blue: "蓝色"
        case .purple: "紫色"
        case .gray: "灰色"
        }
    }
}

/// ink 全局视觉 token。
///
/// 颜色使用语义名称，不允许业务组件直接写 RGB 值。动态颜色会随 macOS
/// 外观实时解析；侧边栏材质由 `NSVisualEffectView` 承担，不在组件中模拟透明。
///
/// 终端内容区的 ANSI 调色板见 `InkTerminalPalette`——渲染热路径不用本文件的
/// `NSColor`，而是用解析后的快照，避免每帧动态解色。
public enum InkDesignTokens {
    public enum Color {
        // MARK: - Surface

        public static let canvas = dynamic(
            light: rgb(0xF9F9F7),
            dark: rgb(0x171819)
        )

        public static let terminal = dynamic(
            light: rgb(0xFDFDFD),
            dark: rgb(0x111314)
        )

        public static let sidebarFallback = dynamic(
            light: rgb(0xEFEAE2, alpha: 0.78),
            dark: rgb(0x262421, alpha: 0.86)
        )

        public static let elevated = dynamic(
            light: rgb(0xFFFFFF, alpha: 0.88),
            dark: rgb(0xFFFFFF, alpha: 0.05)
        )

        /// 侧边栏选中行：白色高光浮在 vibrancy 材质上（chatwise 式的透亮）。
        /// 曾用暖褐 #D9D2C8——HTML mock 里好看，真机叠上壁纸透光就发闷。
        public static let selected = dynamic(
            light: rgb(0xFFFFFF, alpha: 0.72),
            dark: rgb(0xFFFFFF, alpha: 0.085)
        )

        /// 标签 pill 活动态：中性灰压在 canvas 上，不带色相。
        public static let pill = dynamic(
            light: rgb(0x000000, alpha: 0.055),
            dark: rgb(0xFFFFFF, alpha: 0.075)
        )

        // MARK: - Content

        public static let textPrimary = dynamic(
            light: rgb(0x303238),
            dark: rgb(0xE2E3DF)
        )

        public static let textSecondary = dynamic(
            light: rgb(0x777A80),
            dark: rgb(0x92969C)
        )

        public static let separator = dynamic(
            light: rgb(0x70737A, alpha: 0.22),
            dark: rgb(0xFFFFFF, alpha: 0.08)
        )

        // MARK: - Semantic

        public static let accent = dynamic(
            light: rgb(0x168FAF),
            dark: rgb(0x58B6C9)
        )

        public static let success = dynamic(
            light: rgb(0x228F5B),
            dark: rgb(0x67C88D)
        )

        public static let warning = dynamic(
            light: rgb(0xB67F2B),
            dark: rgb(0xD9B25E)
        )

        public static let branch = dynamic(
            light: rgb(0x9B67C8),
            dark: rgb(0xC29ADA)
        )

        public static let danger = dynamic(
            light: rgb(0xD84A4A),
            dark: rgb(0xF06B68)
        )

        static func dynamic(light: NSColor, dark: NSColor) -> NSColor {
            NSColor(name: nil) { appearance in
                appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
                    ? dark
                    : light
            }
        }

        static func rgb(_ value: UInt32, alpha: CGFloat = 1) -> NSColor {
            NSColor(
                srgbRed: CGFloat((value >> 16) & 0xFF) / 255,
                green: CGFloat((value >> 8) & 0xFF) / 255,
                blue: CGFloat(value & 0xFF) / 255,
                alpha: alpha
            )
        }
    }

    public enum Spacing {
        public static let xxs: CGFloat = 4
        public static let xs: CGFloat = 8
        public static let sm: CGFloat = 12
        public static let md: CGFloat = 16
        public static let lg: CGFloat = 24
        public static let xl: CGFloat = 32
    }

    public enum Radius {
        public static let control: CGFloat = 6
        public static let item: CGFloat = 10
        public static let panel: CGFloat = 14
        public static let window: CGFloat = 22
        public static let pill: CGFloat = 999
    }

    // NSFont 非 Sendable，字体 token 只在主线程使用（渲染器走 CoreText，不经这里）。
    @MainActor
    public enum Typography {
        public static let label = NSFont.systemFont(ofSize: 11, weight: .medium)
        public static let body = NSFont.systemFont(ofSize: 13, weight: .regular)
        public static let bodyEmphasized = NSFont.systemFont(ofSize: 13, weight: .semibold)
        public static let title = NSFont.systemFont(ofSize: 15, weight: .semibold)
        public static let pageTitle = NSFont.systemFont(ofSize: 22, weight: .semibold)
        public static let sectionTitle = NSFont.systemFont(ofSize: 12, weight: .semibold)

        public static func terminal(size: CGFloat = 14) -> NSFont {
            NSFont.monospacedSystemFont(ofSize: size, weight: .regular)
        }

        public static func terminalEmphasized(size: CGFloat = 14) -> NSFont {
            NSFont.monospacedSystemFont(ofSize: size, weight: .semibold)
        }
    }

    public enum Motion {
        public static let pressDuration: TimeInterval = 0.14
        public static let stateDuration: TimeInterval = 0.18
    }

    public enum Sidebar {
        public static let width: CGFloat = 258
        /// 必须覆盖 macOS 红绿灯的完整横向占位，避免绿灯跨过分隔线。
        public static let compactWidth: CGFloat = 72
        public static let minimumExpandedWidth: CGFloat = 200
        public static let maximumExpandedWidth: CGFloat = 320
        public static let collapsedTitlebarInset: CGFloat = 84
        public static let projectRowHeight: CGFloat = 40
        public static let actionHeight: CGFloat = 36
        public static let labelDotDiameter: CGFloat = 8
        public static let labelRailWidth: CGFloat = 4
        public static let labelRailHeight: CGFloat = 26
        public static let labelRailInset: CGFloat = 4
        public static let material: NSVisualEffectView.Material = .sidebar
        public static let blendingMode: NSVisualEffectView.BlendingMode = .behindWindow
    }

    public enum Settings {
        public static let contentWidth: CGFloat = 720
        public static let headerHeight: CGFloat = 44
        public static let rowMinimumHeight: CGFloat = 52
        public static let previewHeight: CGFloat = 112
        public static let controlWidth: CGFloat = 260
    }

    public enum ProjectLabel {
        public static func color(for label: InkProjectLabel) -> NSColor? {
            switch label {
            case .none:
                nil
            case .red:
                Color.dynamic(light: Color.rgb(0xD95F59), dark: Color.rgb(0xEF7771))
            case .orange:
                Color.dynamic(light: Color.rgb(0xD1843E), dark: Color.rgb(0xE4A05C))
            case .yellow:
                Color.dynamic(light: Color.rgb(0xB99532), dark: Color.rgb(0xD7B85B))
            case .green:
                Color.dynamic(light: Color.rgb(0x4C9965), dark: Color.rgb(0x69BD82))
            case .blue:
                Color.dynamic(light: Color.rgb(0x4789BC), dark: Color.rgb(0x68A9DA))
            case .purple:
                Color.dynamic(light: Color.rgb(0x916DB9), dark: Color.rgb(0xB08CD5))
            case .gray:
                Color.dynamic(light: Color.rgb(0x85898F), dark: Color.rgb(0xA3A6AA))
            }
        }
    }
}
