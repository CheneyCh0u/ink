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
    @Test("底部操作按钮与项目卡片横向对齐")
    func footerActionsAlignWithProjectRows() throws {
        let controller = SidebarViewController()
        controller.isSettingsSelected = true
        controller.view.frame = NSRect(x: 0, y: 0, width: InkDesignTokens.Sidebar.width, height: 700)
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

        let rowStack = try #require(
            controller.view.subviews.compactMap { $0 as? NSStackView }.first
        )
        let newButton = try #require(
            controller.view.subviews
                .compactMap { $0 as? NSButton }
                .first { $0.title == "新建项目" }
        )
        let settingsButton = try #require(
            controller.view.subviews
                .compactMap { $0 as? NSButton }
                .first { $0.title == "设置" }
        )

        for button in [newButton, settingsButton] {
            #expect(abs(button.frame.minX - rowStack.frame.minX) < 0.5)
            #expect(abs(button.frame.maxX - rowStack.frame.maxX) < 0.5)
        }
        let contentMinX = try leftmostDarkPixelX(in: settingsButton)
        #expect(
            contentMinX >= InkDesignTokens.Spacing.xs - 0.5,
            "设置按钮内容距背景左缘仅 \(contentMinX)pt"
        )
    }

    private func leftmostDarkPixelX(in view: NSView) throws -> CGFloat {
        let bitmap = try #require(view.bitmapImageRepForCachingDisplay(in: view.bounds))
        view.cacheDisplay(in: view.bounds, to: bitmap)
        let scale = CGFloat(bitmap.pixelsWide) / view.bounds.width

        for x in 0..<bitmap.pixelsWide {
            for y in 0..<bitmap.pixelsHigh {
                guard let color = bitmap.colorAt(x: x, y: y)?
                    .usingColorSpace(.deviceRGB) else { continue }
                let luminance =
                    color.redComponent * 0.2126
                    + color.greenComponent * 0.7152
                    + color.blueComponent * 0.0722
                if color.alphaComponent > 0.5, luminance < 0.65 {
                    return CGFloat(x) / scale
                }
            }
        }
        Issue.record("未在设置按钮快照中找到图标或文字")
        return 0
    }
}
