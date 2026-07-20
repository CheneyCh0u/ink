import AppKit
import InkConfig
import InkDesign
import Testing
@testable import InkShell

@Suite("终端配色设置", .serialized)
@MainActor
struct TerminalThemeSettingsTests {

    @Test("五个主题都提供完整且不同的浅色与深色调色板")
    func themesProvideLightAndDarkPalettes() {
        #expect(InkTerminalTheme.allCases.count == 5)

        var signatures = Set<[UInt32]>()
        for theme in InkTerminalTheme.allCases {
            let light = theme.palette(for: .light)
            let dark = theme.palette(for: .dark)
            #expect(light.ansi.count == 16)
            #expect(dark.ansi.count == 16)
            #expect(light.defaultForeground != dark.defaultForeground)
            #expect(light.defaultBackground != dark.defaultBackground)
            signatures.insert(paletteSignature(light))
            signatures.insert(paletteSignature(dark))
        }
        #expect(signatures.count == 10)
    }

    @Test("正文与语义色在对应背景上保持可读对比")
    func palettesKeepReadableContrast() {
        for theme in InkTerminalTheme.allCases {
            for variant in [InkTerminalPalette.Variant.light, .dark] {
                let palette = theme.palette(for: variant)
                #expect(
                    contrast(palette.defaultForeground, palette.defaultBackground) >= 7,
                    "\(theme.displayName)正文对比不足"
                )
                for index in 1...6 {
                    #expect(
                        contrast(palette.ansi[index], palette.defaultBackground) >= 3,
                        "\(theme.displayName) ANSI \(index) 对比不足"
                    )
                }
                #expect(
                    contrast(palette.ansi[8], palette.defaultBackground) >= 3,
                    "\(theme.displayName)次要文字对比不足"
                )
            }
        }
    }

    @Test("设置页列出五个主题并把选择即时写回配置")
    func settingsSelectsTerminalTheme() throws {
        let controller = SettingsViewController(config: InkConfig())
        var changed: InkConfig?
        controller.onChange = { changed = $0 }
        controller.loadView()

        let popUp = try #require(
            allSubviews(in: controller.view)
                .compactMap { $0 as? NSPopUpButton }
                .first { $0.accessibilityLabel() == "终端配色" }
        )
        #expect(popUp.itemTitles == ["暖墨", "石墨蓝", "松针", "紫墨", "中性炭"])
        #expect(popUp.titleOfSelectedItem == "中性炭")

        popUp.selectItem(withTitle: "松针")
        let action = try #require(popUp.action)
        #expect(NSApp.sendAction(action, to: popUp.target, from: popUp))
        #expect(changed?.terminalTheme == .pine)
    }

    @Test("预览同时使用默认字色与 ANSI 语义色")
    func previewUsesThemePaletteColors() throws {
        var config = InkConfig()
        config.terminalTheme = .plum
        let controller = SettingsViewController(config: config)
        controller.loadView()

        let preview = try #require(
            allSubviews(in: controller.view)
                .first { $0.accessibilityLabel() == "终端配色预览" }
        )
        let label = try #require(
            allSubviews(in: preview)
                .compactMap { $0 as? NSTextField }
                .first
        )
        let colors = attributedColors(in: label.attributedStringValue)
        #expect(colors.count >= 7)

        let background = try #require(preview.layer?.backgroundColor)
        let expected = InkTerminalTheme.plum
            .palette(for: preview.effectiveAppearance)
            .defaultBackground.nsColor.cgColor
        #expect(background == expected)
    }

    private func paletteSignature(_ palette: InkTerminalPalette) -> [UInt32] {
        [
            palette.defaultForeground.rgb,
            palette.defaultBackground.rgb,
            palette.cursor.rgb,
            palette.selection.rgb,
            palette.searchHighlight.rgb,
        ] + palette.ansi.map(\.rgb)
    }

    private func contrast(
        _ foreground: InkTerminalPalette.TerminalColor,
        _ background: InkTerminalPalette.TerminalColor
    ) -> Double {
        let lighter = max(luminance(foreground), luminance(background))
        let darker = min(luminance(foreground), luminance(background))
        return (lighter + 0.05) / (darker + 0.05)
    }

    private func luminance(_ color: InkTerminalPalette.TerminalColor) -> Double {
        func linear(_ byte: UInt8) -> Double {
            let component = Double(byte) / 255
            return component <= 0.04045
                ? component / 12.92
                : pow((component + 0.055) / 1.055, 2.4)
        }
        return 0.2126 * linear(color.red)
            + 0.7152 * linear(color.green)
            + 0.0722 * linear(color.blue)
    }

    private func attributedColors(in value: NSAttributedString) -> Set<UInt32> {
        var colors = Set<UInt32>()
        value.enumerateAttribute(
            .foregroundColor,
            in: NSRange(location: 0, length: value.length)
        ) { color, _, _ in
            guard let color = color as? NSColor,
                  let converted = color.usingColorSpace(.sRGB) else { return }
            let red = UInt32((converted.redComponent * 255).rounded())
            let green = UInt32((converted.greenComponent * 255).rounded())
            let blue = UInt32((converted.blueComponent * 255).rounded())
            colors.insert((red << 16) | (green << 8) | blue)
        }
        return colors
    }

    private func allSubviews(in view: NSView) -> [NSView] {
        view.subviews.flatMap { [$0] + allSubviews(in: $0) }
    }
}
