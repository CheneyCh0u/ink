import AppKit
import Foundation
import InkDesign
import Testing
@testable import InkShell

@Suite("项目侧边栏")
struct ProjectSidebarTests {
    @Test("旧版项目元数据缺少颜色时仍可解码")
    func legacyProjectMetadataDecodes() throws {
        let data = Data(#"{"path":"~/work/ink","pinned":false,"note":null}"#.utf8)
        let stored = try JSONDecoder().decode(ProjectStore.Stored.self, from: data)

        #expect(stored.path == "~/work/ink")
        #expect(stored.label == nil)
    }

    @Test("项目颜色可以持久化往返")
    func projectLabelRoundtrip() throws {
        let stored = ProjectStore.Stored(
            path: "~/work/ink",
            pinned: true,
            note: "终端",
            label: InkProjectLabel.blue.rawValue
        )
        let data = try JSONEncoder().encode(stored)
        let decoded = try JSONDecoder().decode(ProjectStore.Stored.self, from: data)

        #expect(decoded.label.flatMap(InkProjectLabel.init(rawValue:)) == .blue)
    }

    @Test("侧边栏按展开、图标、隐藏循环")
    func sidebarModeCycle() {
        #expect(SidebarDisplayMode.expanded.next == .compact)
        #expect(SidebarDisplayMode.compact.next == .hidden)
        #expect(SidebarDisplayMode.hidden.next == .expanded)
    }

    @Test("项目颜色只在图标态展示")
    func projectLabelVisibility() {
        #expect(!SidebarViewController.DisplayMode.expanded.showsProjectLabels)
        #expect(SidebarViewController.DisplayMode.compact.showsProjectLabels)
    }

    @Test("图标态宽度完整容纳窗口控制按钮")
    func compactSidebarClearsWindowControls() {
        #expect(InkDesignTokens.Sidebar.compactWidth >= 72)
    }
}

@Suite("项目侧边栏布局", .serialized)
@MainActor
struct ProjectSidebarLayoutTests {
    @Test("展开态底部入口横向等宽排列")
    func expandedFooterUsesOneRow() throws {
        let (controller, newButton, settingsButton, separator) = try makeController(mode: .expanded)

        #expect(abs(newButton.frame.midY - settingsButton.frame.midY) < 0.5)
        #expect(abs(newButton.frame.width - settingsButton.frame.width) < 0.5)
        #expect(newButton.frame.maxX < settingsButton.frame.minX)
        #expect(separator.frame.minY > max(newButton.frame.maxY, settingsButton.frame.maxY))
        #expect(newButton.imageHugsTitle)
        #expect(settingsButton.imageHugsTitle)
        #expect(!hasShortcutHints(in: controller.view))
    }

    @Test("图标态底部入口上下排列")
    func compactFooterUsesTwoRows() throws {
        let (controller, newButton, settingsButton, separator) = try makeController(mode: .compact)

        #expect(abs(newButton.frame.midX - settingsButton.frame.midX) < 0.5)
        #expect(newButton.frame.minY > settingsButton.frame.maxY)
        #expect(separator.frame.minY > newButton.frame.maxY)
        #expect(newButton.title.isEmpty)
        #expect(settingsButton.title.isEmpty)
        #expect(!hasShortcutHints(in: controller.view))
    }

    private func makeController(
        mode: SidebarViewController.DisplayMode
    ) throws -> (SidebarViewController, NSButton, NSButton, NSBox) {
        let controller = SidebarViewController()
        controller.displayMode = mode
        controller.isSettingsSelected = true
        let width = mode == .compact
            ? InkDesignTokens.Sidebar.compactWidth
            : InkDesignTokens.Sidebar.width
        controller.view.frame = NSRect(x: 0, y: 0, width: width, height: 700)
        controller.view.appearance = NSAppearance(named: .aqua)
        controller.reload(rows: [
            .init(
                title: "~",
                subtitle: "1 个会话",
                active: true,
                pinned: false,
                label: .none
            ),
        ])
        controller.view.layoutSubtreeIfNeeded()

        let buttons = controller.view.subviews.compactMap { $0 as? NSButton }
        #expect(buttons.count == 2)
        let separator = try #require(
            controller.view.subviews.compactMap { $0 as? NSBox }.first
        )
        return (controller, try #require(buttons.first), try #require(buttons.last), separator)
    }

    private func hasShortcutHints(in view: NSView) -> Bool {
        view.subviews
            .compactMap { $0 as? NSTextField }
            .contains { ["⌘N", "⌘,"].contains($0.stringValue) }
    }
}
