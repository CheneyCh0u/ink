import Testing
@testable import TerminalCore

@Suite("CharWidth 宽度表")
struct CharWidthTableTests {
    @Test("基本分类")
    func basicWidths() {
        #expect(CharWidth.width(of: UnicodeScalar("A").value) == 1)
        #expect(CharWidth.width(of: UnicodeScalar("终").value) == 2)
        #expect(CharWidth.width(of: UnicodeScalar("ｱ").value) == 1)  // 半角片假名
        #expect(CharWidth.width(of: UnicodeScalar("Ａ").value) == 2) // 全角拉丁
        #expect(CharWidth.width(of: 0xAC00) == 2)  // 韩文音节
        #expect(CharWidth.width(of: 0x1F600) == 2) // 😀
        #expect(CharWidth.width(of: 0x231A) == 2)  // ⌚
        #expect(CharWidth.width(of: 0x0301) == 0)  // 组合尖音符
        #expect(CharWidth.width(of: 0x200D) == 0)  // ZWJ
        #expect(CharWidth.width(of: 0xFE0F) == 0)  // VS16
        #expect(CharWidth.width(of: 0x20BB7) == 2) // CJK 扩展 B
    }

    @Test("字符簇宽度识别 emoji 与文本变体选择符")
    func variationSequenceWidths() {
        #expect(CharWidth.width(of: Character("⏱\u{FE0F}")) == 2)
        #expect(CharWidth.width(of: Character("☁\u{FE0E}")) == 1)
        #expect(CharWidth.width(of: Character("A\u{FE0F}")) == 1)
        #expect(CharWidth.width(of: Character("⏱\u{0301}\u{FE0F}")) == 1)
        #expect(CharWidth.width(of: Character("\u{1F1E6}\u{FE0F}")) == 1)
    }
}

@Suite("宽字符与组合入格")
struct WideAndClusterTests {
    @Test("中文占两格：首格标 leading，尾格标 trailing，光标进 2")
    func wideCharOccupiesTwoCells() {
        var (parser, term) = makeTerminal(columns: 10, rows: 2)
        feed("终A", &parser, &term)
        #expect(term.grid[0, 0].scalar == UnicodeScalar("终").value)
        #expect(term.grid[0, 0].attr & Cell.Attr.wideLeading != 0)
        #expect(term.grid[0, 1].attr & Cell.Attr.wideTrailing != 0)
        #expect(term.grid[0, 2].scalar == UnicodeScalar("A").value)
        #expect(term.grid.cursorCol == 3)
    }

    @Test("行尾剩一格：宽字符整字折到下一行并标 wrapped")
    func wideCharWrapsWhole() {
        var (parser, term) = makeTerminal(columns: 5, rows: 2)
        feed("abcd终", &parser, &term)
        #expect(term.grid[0, 4].isBlank) // 行尾补的空白
        #expect(term.grid[1, 0].scalar == UnicodeScalar("终").value)
        #expect(term.grid.info(ofRow: 1).isWrapped)
    }

    @Test("组合尖音符并入前格成簇，光标不动")
    func combiningMarkJoins() {
        var (parser, term) = makeTerminal()
        feed("e\u{0301}x", &parser, &term) // é 分解形式
        let cell = term.grid[0, 0]
        #expect(cell.isCluster)
        let scalars = term.clusterTable.scalars(for: cell.scalar)
        #expect(scalars == [UnicodeScalar("e").value, 0x0301])
        #expect(term.grid[0, 1].scalar == UnicodeScalar("x").value)
    }

    @Test("ZWJ 家庭 emoji 合成单簇，只占一个宽格")
    func zwjFamilyIsOneCluster() {
        var (parser, term) = makeTerminal()
        feed("👨\u{200D}👩\u{200D}👧x", &parser, &term)
        let cell = term.grid[0, 0]
        #expect(cell.isCluster)
        #expect(cell.attr & Cell.Attr.wideLeading != 0)
        let scalars = term.clusterTable.scalars(for: cell.scalar)
        #expect(scalars.count == 5) // 3 emoji + 2 ZWJ
        #expect(term.grid[0, 2].scalar == UnicodeScalar("x").value) // 后续字符紧跟宽格之后
    }

    @Test("VS15 并入簇并保留文本表现的一列宽度")
    func textVariationSelectorJoins() {
        var (parser, term) = makeTerminal()
        feed("☁\u{FE0E}x", &parser, &term)
        #expect(term.grid[0, 0].isCluster)
        #expect(term.grid[0, 1].scalar == UnicodeScalar("x").value)
    }

    @Test("VS16 把窄 emoji 基字符升级为两列")
    func emojiPresentationSequenceOccupiesTwoCells() {
        var (parser, term) = makeTerminal()
        feed("⏱\u{FE0F}x", &parser, &term)

        #expect(term.grid[0, 0].isCluster)
        #expect(term.grid[0, 0].attr & Cell.Attr.wideLeading != 0)
        #expect(term.grid[0, 1].attr & Cell.Attr.wideTrailing != 0)
        #expect(term.grid[0, 2].scalar == UnicodeScalar("x").value)
        #expect(term.grid.cursorCol == 3)
    }

    @Test("VS16 在行末把完整 emoji 序列折到下一行")
    func emojiPresentationSequenceWrapsFromLastColumn() {
        var (parser, term) = makeTerminal(columns: 4, rows: 2)
        feed("abc⏱\u{FE0F}x", &parser, &term)

        #expect(term.grid[0, 3].isBlank)
        #expect(term.grid.info(ofRow: 1).isWrapped)
        #expect(term.grid[1, 0].isCluster)
        #expect(term.grid[1, 0].attr & Cell.Attr.wideLeading != 0)
        #expect(term.grid[1, 1].attr & Cell.Attr.wideTrailing != 0)
        #expect(term.grid[1, 2].scalar == UnicodeScalar("x").value)
    }

    @Test("ZWJ 后续宽 emoji 把原本的窄基字符簇升级为两列")
    func zwjSequencePromotesNarrowBaseToTwoCells() {
        var (parser, term) = makeTerminal()
        feed("❤\u{200D}🔥x", &parser, &term)

        #expect(term.grid[0, 0].isCluster)
        #expect(term.grid[0, 0].attr & Cell.Attr.wideLeading != 0)
        #expect(term.grid[0, 1].attr & Cell.Attr.wideTrailing != 0)
        #expect(term.grid[0, 2].scalar == UnicodeScalar("x").value)
    }

    @Test("关闭自动折行时行末 emoji 序列与普通宽字符一样左移")
    func emojiPresentationAtLastColumnWithoutAutowrapMovesLeft() {
        var (parser, term) = makeTerminal(columns: 4, rows: 1)
        feed("\u{1B}[?7labc⏱\u{FE0F}", &parser, &term)

        #expect(term.grid[0, 2].isCluster)
        #expect(term.grid[0, 2].attr & Cell.Attr.wideLeading != 0)
        #expect(term.grid[0, 3].attr & Cell.Attr.wideTrailing != 0)
        #expect(term.grid.cursorCol == 3)
    }

    @Test("关闭自动折行时行末 ZWJ 序列续写同一个基字符")
    func zwjSequenceAtLastColumnWithoutAutowrapStaysIntact() {
        var (parser, term) = makeTerminal(columns: 4, rows: 1)
        feed("\u{1B}[?7labc❤\u{200D}🔥", &parser, &term)

        let cell = term.grid[0, 2]
        #expect(cell.isCluster)
        #expect(cell.attr & Cell.Attr.wideLeading != 0)
        #expect(term.grid[0, 3].attr & Cell.Attr.wideTrailing != 0)
        #expect(term.clusterTable.scalars(for: cell.scalar) == [
            UnicodeScalar("❤").value,
            0x200D,
            UnicodeScalar("🔥").value,
        ])
    }

    @Test("非相邻 VS16 不把文本簇误升级为两列")
    func nonAdjacentVariationSelectorStaysNarrow() {
        var (parser, term) = makeTerminal()
        feed("⏱\u{0301}\u{FE0F}x", &parser, &term)

        #expect(term.grid[0, 0].isCluster)
        #expect(term.grid[0, 0].attr & Cell.Attr.wideLeading == 0)
        #expect(term.grid[0, 1].scalar == UnicodeScalar("x").value)
    }

    @Test("覆写宽字符半格时清掉孤儿")
    func overwriteClearsOrphan() {
        var (parser, term) = makeTerminal(columns: 10, rows: 1)
        feed("终\u{1B}[1;2HX", &parser, &term) // 覆写尾格
        #expect(term.grid[0, 0].isBlank) // 首格孤儿被清
        #expect(term.grid[0, 1].scalar == UnicodeScalar("X").value)
    }

    @Test("同一 emoji 簇去重，表只存一份")
    func clusterDedupes() {
        var (parser, term) = makeTerminal(columns: 40, rows: 4)
        feed("👍\u{FE0F}👍\u{FE0F}👍\u{FE0F}", &parser, &term)
        #expect(term.clusterTable.count == 1)
    }

    @Test("行首孤立组合符丢弃不崩")
    func orphanCombiningAtRowStart() {
        var (parser, term) = makeTerminal()
        feed("\u{0301}A", &parser, &term)
        #expect(term.grid[0, 0].scalar == UnicodeScalar("A").value)
    }

    @Test("切换备用屏后不沿用主屏的字符簇续写位置")
    func alternateScreenClearsClusterContinuation() {
        var (parser, term) = makeTerminal()
        feed("A\u{1B}[?1049h\u{0301}", &parser, &term)

        #expect(term.grid[0, 0].isBlank)
        #expect(!term.grid[0, 0].isCluster)
    }
}
