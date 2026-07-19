/// 终端网格的最小单元，定死 8 字节。布局见 docs/grid-design.md。
///
/// 热路径纪律：本类型出现在每帧遍历里，只允许位运算，禁止任何会引入
/// 引用计数或装箱的成员。`MemoryLayout<Cell>.stride == 8` 由测试断言。
public struct Cell: Sendable, Equatable {
    /// bit 0–20 Unicode scalar；bit 31 置位时低位是簇表索引（组合字符，M3 实现）。
    public var scalar: UInt32
    /// 颜色与样式的打包位，布局见 `Attr`。
    public var attr: UInt32

    @inline(__always)
    public init(scalar: UInt32 = 0x20, attr: UInt32 = Attr.default) {
        self.scalar = scalar
        self.attr = attr
    }

    /// 空白 cell：空格 + 全默认属性。trim 与清屏都以它为基准。
    public static let blank = Cell()

    @inline(__always)
    public var isBlank: Bool { scalar == 0x20 && attr == Attr.default }

    // MARK: - 簇标记

    /// 置位表示 `scalar` 低位是簇表索引而非码点。
    public static let clusterFlag: UInt32 = 1 << 31

    @inline(__always)
    public var isCluster: Bool { scalar & Cell.clusterFlag != 0 }

    // MARK: - attr 位布局

    public enum Attr {
        // 颜色：11 位。0–255 调色板；256 默认；257–2047 真彩色旁路表（值 - 257）。
        public static let colorDefault: UInt32 = 256
        public static let colorMask: UInt32 = 0x7FF
        public static let bgShift: UInt32 = 11

        // 样式位 22–29。
        public static let bold: UInt32 = 1 << 22
        public static let faint: UInt32 = 1 << 23
        public static let italic: UInt32 = 1 << 24
        public static let underline: UInt32 = 1 << 25
        public static let blink: UInt32 = 1 << 26
        public static let inverse: UInt32 = 1 << 27
        public static let hidden: UInt32 = 1 << 28
        public static let strikethrough: UInt32 = 1 << 29

        // 宽字符：首格占位 + 尾格空穴。
        public static let wideLeading: UInt32 = 1 << 30
        public static let wideTrailing: UInt32 = 1 << 31

        /// 前景默认 + 背景默认 + 无样式。
        public static let `default`: UInt32 = colorDefault | (colorDefault << bgShift)

        @inline(__always)
        public static func pack(fg: UInt32, bg: UInt32, style: UInt32 = 0) -> UInt32 {
            (fg & colorMask) | ((bg & colorMask) << bgShift) | style
        }

        @inline(__always)
        public static func foreground(of attr: UInt32) -> UInt32 { attr & colorMask }

        @inline(__always)
        public static func background(of attr: UInt32) -> UInt32 { (attr >> bgShift) & colorMask }
    }
}

/// 每行 2 字节元数据：reflow 与 OSC 133 的落点，见 docs/grid-design.md。
public struct RowInfo: Sendable, Equatable {
    public var flags: UInt8
    /// OSC 133 语义：`SemanticMark` 的原始值。
    public var semantic: UInt8

    /// 本行是上一行的软折行延续。M6 reflow 靠它把逻辑行拼回去。
    public static let wrapped: UInt8 = 1 << 0

    @inline(__always)
    public init(flags: UInt8 = 0, semantic: UInt8 = 0) {
        self.flags = flags
        self.semantic = semantic
    }

    @inline(__always)
    public var isWrapped: Bool { flags & RowInfo.wrapped != 0 }

    public static let none = RowInfo()
}

/// OSC 133 的行语义标记。
public enum SemanticMark: UInt8, Sendable {
    case none = 0
    case prompt = 1
    case command = 2
    case output = 3
}
