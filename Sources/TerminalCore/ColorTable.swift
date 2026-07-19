/// 真彩色旁路表：cell 的 11 位颜色字段放不下 24 位 RGB，去重后存这里。
///
/// 编码约定（docs/grid-design.md）：cell 里 `257 + 表内索引`，容量 1791。
/// 打满之后新颜色降级为最近的 xterm 256 色——这是内存优先的明确取舍，
/// 只有 lolcat 式的渐变输出会触碰上限。
public struct ColorTable: Sendable {
    /// 表满时新颜色的降级结果也要可预测，容量写死成编码空间的上限。
    public static let capacity = 2047 - 257 + 1 // 1791

    private var colors: ContiguousArray<UInt32> = []
    private var indexByColor: [UInt32: UInt32] = [:]

    public init() {}

    /// RGB → cell 颜色编码。去重命中直接返回既有索引；表满降级到最近 256 色。
    public mutating func encode(red: UInt8, green: UInt8, blue: UInt8) -> UInt32 {
        let rgb = UInt32(red) << 16 | UInt32(green) << 8 | UInt32(blue)
        if let existing = indexByColor[rgb] {
            return 257 + existing
        }
        if colors.count < Self.capacity {
            let index = UInt32(colors.count)
            colors.append(rgb)
            indexByColor[rgb] = index
            return 257 + index
        }
        return Self.nearestPalette(red: red, green: green, blue: blue)
    }

    /// cell 编码 → RGB。只对 257–2047 段有意义。
    @inline(__always)
    public func rgb(for encoded: UInt32) -> UInt32 {
        colors[Int(encoded - 257)]
    }

    public var count: Int { colors.count }

    // MARK: - 降级

    /// 最近的 xterm 256 色（16–231 色立方 + 232–255 灰阶，标准公式）。
    static func nearestPalette(red: UInt8, green: UInt8, blue: UInt8) -> UInt32 {
        // 色立方分量档位：0, 95, 135, 175, 215, 255。
        @inline(__always)
        func cubeLevel(_ v: UInt8) -> Int {
            v < 48 ? 0 : v < 115 ? 1 : Int((UInt32(v) - 35) / 40)
        }
        @inline(__always)
        func cubeValue(_ level: Int) -> Int {
            level == 0 ? 0 : level * 40 + 55
        }

        let (r, g, b) = (Int(red), Int(green), Int(blue))
        let (lr, lg, lb) = (cubeLevel(red), cubeLevel(green), cubeLevel(blue))
        let (cr, cg, cb) = (cubeValue(lr), cubeValue(lg), cubeValue(lb))

        // 候选一：色立方最近点。
        let cubeIndex = 16 + 36 * lr + 6 * lg + lb
        let cubeDist = (r - cr) * (r - cr) + (g - cg) * (g - cg) + (b - cb) * (b - cb)

        // 候选二：灰阶最近档（8, 18, …, 238）。
        let gray = (r + g + b) / 3
        let grayLevel = min(23, max(0, (gray - 3) / 10))
        let grayValue = grayLevel * 10 + 8
        let grayDist = (r - grayValue) * (r - grayValue)
            + (g - grayValue) * (g - grayValue)
            + (b - grayValue) * (b - grayValue)

        return grayDist < cubeDist ? UInt32(232 + grayLevel) : UInt32(cubeIndex)
    }
}
