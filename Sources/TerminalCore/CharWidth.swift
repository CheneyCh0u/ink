/// 码点显示宽度：0（组合进前格）/ 1 / 2（东亚全角，占两格）。
///
/// wcwidth 语义。宽表按 UAX #11 的 W/F 段 + emoji 表示段整理，组合类
/// 直接用 stdlib 的 Unicode 属性（免维护整张 Mn/Me 表）。
/// 这里错一个区间，表现就是中文对不齐、光标漂移——中文用户第一眼就能看到。
public enum CharWidth {

    @inline(__always)
    public static func width(of scalar: UInt32) -> Int {
        // ASCII 快速通道：终端流量的绝对大头。
        if scalar < 0x0300 { return 1 }

        // 零宽：ZWJ、变体选择符、韩文中/终声、组合标记。
        if scalar == 0x200D { return 0 }
        if (0xFE00...0xFE0F).contains(scalar) || (0xE0100...0xE01EF).contains(scalar) { return 0 }
        if (0x1160...0x11FF).contains(scalar) { return 0 }
        if let s = Unicode.Scalar(scalar) {
            switch s.properties.generalCategory {
            case .nonspacingMark, .enclosingMark, .format:
                return 0
            default:
                break
            }
        }

        return isWide(scalar) ? 2 : 1
    }

    /// 东亚宽 / 全角 / emoji 表示。区间已排序，二分查找。
    @inline(__always)
    static func isWide(_ scalar: UInt32) -> Bool {
        var lo = 0
        var hi = wideRanges.count - 1
        while lo <= hi {
            let mid = (lo + hi) / 2
            let range = wideRanges[mid]
            if scalar < range.lowerBound {
                hi = mid - 1
            } else if scalar > range.upperBound {
                lo = mid + 1
            } else {
                return true
            }
        }
        return false
    }

    /// UAX #11 W/F 段 + 常用 emoji 表示段。VS16 把窄字符转宽的语义暂不处理
    /// （与 wcwidth 保持一致，应用侧也是按 wcwidth 排版的，宽度不一致才会漂移）。
    static let wideRanges: [ClosedRange<UInt32>] = [
        0x1100...0x115F,   // 韩文初声
        0x231A...0x231B,   // ⌚⌛
        0x2329...0x232A,   // 尖角括号
        0x23E9...0x23EC,   // 播放控制 emoji
        0x23F0...0x23F0,
        0x23F3...0x23F3,
        0x25FD...0x25FE,
        0x2614...0x2615,   // ☔☕
        0x2648...0x2653,   // 星座
        0x267F...0x267F,
        0x2693...0x2693,
        0x26A1...0x26A1,
        0x26AA...0x26AB,
        0x26BD...0x26BE,
        0x26C4...0x26C5,
        0x26CE...0x26CE,
        0x26D4...0x26D4,
        0x26EA...0x26EA,
        0x26F2...0x26F3,
        0x26F5...0x26F5,
        0x26FA...0x26FA,
        0x26FD...0x26FD,
        0x2705...0x2705,
        0x270A...0x270B,
        0x2728...0x2728,
        0x274C...0x274C,
        0x274E...0x274E,
        0x2753...0x2755,
        0x2757...0x2757,
        0x2795...0x2797,
        0x27B0...0x27B0,
        0x27BF...0x27BF,
        0x2B1B...0x2B1C,
        0x2B50...0x2B50,
        0x2B55...0x2B55,
        0x2E80...0x303E,   // CJK 部首、注音、CJK 符号（不含 0x303F）
        0x3041...0x33FF,   // 平假名…CJK 兼容
        0x3400...0x4DBF,   // CJK 扩展 A
        0x4E00...0x9FFF,   // CJK 统一表意
        0xA000...0xA4CF,   // 彝文
        0xA960...0xA97F,   // 韩文初声扩展 A
        0xAC00...0xD7A3,   // 韩文音节
        0xF900...0xFAFF,   // CJK 兼容表意
        0xFE10...0xFE19,   // 竖排形式
        0xFE30...0xFE52,   // CJK 兼容形式
        0xFE54...0xFE66,
        0xFE68...0xFE6B,
        0xFF00...0xFF60,   // 全角形式
        0xFFE0...0xFFE6,
        0x16FE0...0x16FE4, // 西夏文等标点
        0x17000...0x187F7, // 西夏文
        0x18800...0x18CD5,
        0x1B000...0x1B2FB, // 假名补充
        0x1F004...0x1F004, // 🀄
        0x1F0CF...0x1F0CF,
        0x1F18E...0x1F18E,
        0x1F191...0x1F19A,
        0x1F200...0x1F320, // 方块表意与常用 emoji 起点
        0x1F32D...0x1F335,
        0x1F337...0x1F37C,
        0x1F37E...0x1F393,
        0x1F3A0...0x1F3CA,
        0x1F3CF...0x1F3D3,
        0x1F3E0...0x1F3F0,
        0x1F3F4...0x1F3F4,
        0x1F3F8...0x1F43E,
        0x1F440...0x1F440,
        0x1F442...0x1F4FC,
        0x1F4FF...0x1F53D,
        0x1F54B...0x1F54E,
        0x1F550...0x1F567,
        0x1F57A...0x1F57A,
        0x1F595...0x1F596,
        0x1F5A4...0x1F5A4,
        0x1F5FB...0x1F64F,
        0x1F680...0x1F6C5,
        0x1F6CC...0x1F6CC,
        0x1F6D0...0x1F6D2,
        0x1F6D5...0x1F6D7,
        0x1F6DC...0x1F6DF,
        0x1F6EB...0x1F6EC,
        0x1F6F4...0x1F6FC,
        0x1F7E0...0x1F7EB,
        0x1F7F0...0x1F7F0,
        0x1F90C...0x1F93A,
        0x1F93C...0x1F945,
        0x1F947...0x1F9FF,
        0x1FA70...0x1FAFF,
        0x20000...0x2FFFD, // CJK 扩展 B–F
        0x30000...0x3FFFD,
    ]
}
