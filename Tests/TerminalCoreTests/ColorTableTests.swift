import Testing
@testable import TerminalCore

@Suite("ColorTable")
struct ColorTableTests {
    @Test("编码从 257 起，同色去重")
    func encodesAndDedupes() {
        var table = ColorTable()
        let a = table.encode(red: 0x16, green: 0x8F, blue: 0xAF)
        let b = table.encode(red: 0x16, green: 0x8F, blue: 0xAF)
        #expect(a == 257)
        #expect(b == a)
        #expect(table.count == 1)
        #expect(table.rgb(for: a) == 0x168FAF)
    }

    @Test("表满降级为最近 256 色，不再入表")
    func degradesWhenFull() {
        var table = ColorTable()
        // 用互不相同的颜色打满 1791 个槽位。
        var filled = 0
        outer: for r in 0..<256 {
            for g in 0..<256 {
                if filled == ColorTable.capacity { break outer }
                _ = table.encode(red: UInt8(r), green: UInt8(g), blue: 1)
                filled += 1
            }
        }
        #expect(table.count == ColorTable.capacity)

        let degraded = table.encode(red: 255, green: 0, blue: 255)
        #expect(degraded <= 255) // 落回调色板段
        #expect(table.count == ColorTable.capacity)
    }

    @Test("降级公式：纯色到色立方角点，灰色到灰阶")
    func nearestPalette() {
        // 纯红最近 (5,0,0) = 16 + 180 = 196。
        #expect(ColorTable.nearestPalette(red: 255, green: 0, blue: 0) == 196)
        // 纯白是立方角点 231。
        #expect(ColorTable.nearestPalette(red: 255, green: 255, blue: 255) == 231)
        // 中灰 0x80 → 灰阶段（232–255）。
        let gray = ColorTable.nearestPalette(red: 128, green: 128, blue: 128)
        #expect((232...255).contains(gray))
    }
}
