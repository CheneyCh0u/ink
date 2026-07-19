/// 块元素（U+2580–U+259F）程序化栅格：半格 / 八分格 / 四象限 / 阴影。
///
/// 这段码位不能交给字体：字形按字体 em box 设计，与终端 cell（含行距）
/// 不重合，上下左右拼接的像素画（Claude Code 的 logo、htop 的条形图）
/// 会错位漏缝。按 cell 精确像素直接填充 coverage，接缝为零。
enum BlockElements {

    static func contains(_ scalar: UInt32) -> Bool {
        (0x2580...0x259F).contains(scalar)
    }

    /// 画进 A8 coverage 缓冲。坐标系：row 0 是 cell 顶部（与纹理内存一致）。
    /// `width`/`height` 是 cell 的像素尺寸，`bytesPerRow` 是缓冲行距。
    static func render(
        _ scalar: UInt32,
        width: Int, height: Int,
        into buffer: inout [UInt8], bytesPerRow: Int
    ) {
        func fill(x0: Int, y0: Int, x1: Int, y1: Int, alpha: UInt8 = 255) {
            let xa = max(0, x0), xb = min(width, x1)
            let ya = max(0, y0), yb = min(height, y1)
            guard xa < xb, ya < yb else { return }
            for y in ya..<yb {
                let base = y * bytesPerRow
                for x in xa..<xb {
                    buffer[base + x] = alpha
                }
            }
        }
        // 八分格坐标：向上取整保证 1/8 在小字号下至少 1px。
        func eighthH(_ n: Int) -> Int { (height * n + 7) / 8 }
        func eighthW(_ n: Int) -> Int { (width * n + 7) / 8 }
        let halfW = width / 2
        let halfH = height / 2

        switch scalar {
        case 0x2580: // ▀ 上半
            fill(x0: 0, y0: 0, x1: width, y1: halfH)
        case 0x2581...0x2588: // ▁…█ 下 1/8…8/8
            let n = Int(scalar - 0x2580)
            fill(x0: 0, y0: height - eighthH(n), x1: width, y1: height)
        case 0x2589...0x258F: // ▉…▏ 左 7/8…1/8
            let n = 8 - Int(scalar - 0x2588)
            fill(x0: 0, y0: 0, x1: eighthW(n), y1: height)
        case 0x2590: // ▐ 右半
            fill(x0: halfW, y0: 0, x1: width, y1: height)
        case 0x2591: // ░
            fill(x0: 0, y0: 0, x1: width, y1: height, alpha: 64)
        case 0x2592: // ▒
            fill(x0: 0, y0: 0, x1: width, y1: height, alpha: 128)
        case 0x2593: // ▓
            fill(x0: 0, y0: 0, x1: width, y1: height, alpha: 192)
        case 0x2594: // ▔ 上 1/8
            fill(x0: 0, y0: 0, x1: width, y1: eighthH(1))
        case 0x2595: // ▕ 右 1/8
            fill(x0: width - eighthW(1), y0: 0, x1: width, y1: height)
        case 0x2596...0x259F: // 四象限组合
            // 位序：1=左上 2=右上 4=左下 8=右下
            let masks: [UInt32: Int] = [
                0x2596: 4, 0x2597: 8, 0x2598: 1, 0x2599: 1 | 4 | 8,
                0x259A: 1 | 8, 0x259B: 1 | 2 | 4, 0x259C: 1 | 2 | 8,
                0x259D: 2, 0x259E: 2 | 4, 0x259F: 2 | 4 | 8,
            ]
            let mask = masks[scalar] ?? 0
            if mask & 1 != 0 { fill(x0: 0, y0: 0, x1: halfW, y1: halfH) }
            if mask & 2 != 0 { fill(x0: halfW, y0: 0, x1: width, y1: halfH) }
            if mask & 4 != 0 { fill(x0: 0, y0: halfH, x1: halfW, y1: height) }
            if mask & 8 != 0 { fill(x0: halfW, y0: halfH, x1: width, y1: height) }
        default:
            break
        }
    }
}
