import AppKit
import Foundation
import InkDesign
import Testing
@testable import InkShell

@Suite("项目侧边栏")
struct ProjectSidebarTests {
    @Test("项目侧边栏拆分最终目录名与父路径")
    @MainActor
    func projectSidebarPathComponents() {
        let project = Project(
            directory: URL(fileURLWithPath: "/Users/cheney/work/code/wiselaw/wise-studio")
        )

        #expect(project.sidebarTitle == "wise-studio")
        #expect(project.sidebarParentPath == "~/work/code/wiselaw")
    }

    @Test("用户主目录在侧边栏继续显示波浪号")
    @MainActor
    func homeProjectSidebarPath() {
        let project = Project(directory: FileManager.default.homeDirectoryForCurrentUser)

        #expect(project.sidebarTitle == "~")
        #expect(project.sidebarParentPath.isEmpty)
    }

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

    @Test("项目颜色按侧边栏状态切换形态")
    func projectLabelStyle() {
        #expect(SidebarViewController.DisplayMode.expanded.labelIndicatorStyle == .dot)
        #expect(SidebarViewController.DisplayMode.compact.labelIndicatorStyle == .rail)
        #expect(InkDesignTokens.Sidebar.labelDotDiameter == 8)
    }

    @Test("图标态宽度完整容纳窗口控制按钮")
    func compactSidebarClearsWindowControls() {
        #expect(InkDesignTokens.Sidebar.compactWidth >= 72)
    }
}

@Suite("项目侧边栏布局", .serialized)
@MainActor
struct ProjectSidebarLayoutTests {
    @Test("点击长目录时项目文字区域保持稳定")
    func longPathUsesStableProjectNameLayout() throws {
        let controller = SidebarViewController()
        controller.view.frame = NSRect(
            x: 0,
            y: 0,
            width: InkDesignTokens.Sidebar.width,
            height: 700
        )
        let titleText = "wise-studio"
        let detailText = "~/work/code/very-long-parent-directory/wiselaw"
        let statusText = "1 个标签"
        let fullPath = "\(detailText)/\(titleText)"
        let row = SidebarViewController.Row(
            title: titleText,
            detail: detailText,
            status: statusText,
            fullPath: fullPath,
            active: false,
            pinned: true,
            label: .red
        )
        controller.reload(rows: [row])
        controller.view.layoutSubtreeIfNeeded()

        var rowStack = try #require(
            controller.view.subviews.compactMap { $0 as? NSStackView }.first
        )
        var rowView = try #require(rowStack.arrangedSubviews.first)
        var title = try #require(
            descendants(of: NSTextField.self, in: rowView)
                .first { $0.stringValue == titleText }
        )
        var detail = try #require(
            descendants(of: NSTextField.self, in: rowView)
                .first { $0.stringValue == detailText }
        )
        var status = try #require(
            descendants(of: NSTextField.self, in: rowView)
                .first { $0.stringValue == statusText }
        )
        var closeButton = try #require(descendants(of: NSButton.self, in: rowView).first)
        let initialTitleFrame = title.convert(title.bounds, to: rowView)
        let initialDetailFrame = detail.convert(detail.bounds, to: rowView)
        let initialStatusFrame = status.convert(status.bounds, to: rowView)
        let event = try #require(
            NSEvent.mouseEvent(
                with: .mouseMoved,
                location: .zero,
                modifierFlags: [],
                timestamp: 0,
                windowNumber: 0,
                context: nil,
                eventNumber: 0,
                clickCount: 0,
                pressure: 0
            )
        )

        #expect(detail.lineBreakMode == NSLineBreakMode.byTruncatingHead)
        #expect(detail.frame.width < detail.intrinsicContentSize.width)
        #expect(status.frame.width >= status.intrinsicContentSize.width - 0.5)
        #expect(!closeButton.isHidden)
        #expect(closeButton.alphaValue == 0)

        rowView.mouseEntered(with: event)
        controller.view.layoutSubtreeIfNeeded()
        #expect(title.convert(title.bounds, to: rowView) == initialTitleFrame)
        #expect(detail.convert(detail.bounds, to: rowView) == initialDetailFrame)
        #expect(status.convert(status.bounds, to: rowView) == initialStatusFrame)
        #expect(closeButton.alphaValue == 1)

        controller.reload(rows: [
            .init(
                title: titleText,
                detail: detailText,
                status: statusText,
                fullPath: fullPath,
                active: true,
                pinned: true,
                label: .red
            ),
        ])
        controller.view.layoutSubtreeIfNeeded()
        rowStack = try #require(
            controller.view.subviews.compactMap { $0 as? NSStackView }.first
        )
        rowView = try #require(rowStack.arrangedSubviews.first)
        title = try #require(
            descendants(of: NSTextField.self, in: rowView)
                .first { $0.stringValue == titleText }
        )
        detail = try #require(
            descendants(of: NSTextField.self, in: rowView)
                .first { $0.stringValue == detailText }
        )
        status = try #require(
            descendants(of: NSTextField.self, in: rowView)
                .first { $0.stringValue == statusText }
        )
        closeButton = try #require(descendants(of: NSButton.self, in: rowView).first)

        #expect(title.convert(title.bounds, to: rowView) == initialTitleFrame)
        #expect(detail.convert(detail.bounds, to: rowView) == initialDetailFrame)
        #expect(status.convert(status.bounds, to: rowView) == initialStatusFrame)
        #expect(!closeButton.isHidden)
        #expect(closeButton.alphaValue == 1)

        rowView.mouseExited(with: event)
        controller.view.layoutSubtreeIfNeeded()
        #expect(title.convert(title.bounds, to: rowView) == initialTitleFrame)
        #expect(detail.convert(detail.bounds, to: rowView) == initialDetailFrame)
        #expect(status.convert(status.bounds, to: rowView) == initialStatusFrame)
        #expect(!closeButton.isHidden)
        #expect(closeButton.alphaValue == 0)
    }

    @Test("展开态为所有项目保留圆点列")
    func expandedRowsReserveDotColumn() {
        let controller = makeLabelController(mode: .expanded)
        let indicators = descendants(of: ProjectLabelIndicator.self, in: controller.view)

        #expect(indicators.count == 2)
        #expect(indicators.allSatisfy {
            abs($0.frame.width - InkDesignTokens.Sidebar.labelDotDiameter) < 0.5
                && abs($0.frame.height - InkDesignTokens.Sidebar.labelDotDiameter) < 0.5
        })
        #expect(abs(indicators[0].frame.minX - indicators[1].frame.minX) < 0.5)
        #expect(indicators[0].drawsColor)
        #expect(!indicators[1].drawsColor)
        #expect(!indicators[1].isHidden)
    }

    @Test("图标态继续使用颜色竖条")
    func compactRowsUseLabelRail() {
        let controller = makeLabelController(mode: .compact)
        let indicators = descendants(of: ProjectLabelIndicator.self, in: controller.view)

        #expect(indicators.count == 2)
        #expect(indicators.allSatisfy {
            abs($0.frame.width - InkDesignTokens.Sidebar.labelRailWidth) < 0.5
                && abs($0.frame.height - InkDesignTokens.Sidebar.labelRailHeight) < 0.5
        })
        #expect(descendants(of: NSButton.self, in: controller.view).count == 1)
    }

    @Test("展开态底部只保留全宽新建项目")
    func expandedFooterUsesFullWidthNewProject() throws {
        let (controller, newButton, separator) = try makeController(mode: .expanded)

        #expect(newButton.title == "新建项目")
        #expect(abs(newButton.frame.minX - InkDesignTokens.Spacing.xs) < 0.5)
        #expect(
            abs(controller.view.bounds.maxX - newButton.frame.maxX - InkDesignTokens.Spacing.xs) < 0.5
        )
        #expect(separator.frame.minY > newButton.frame.maxY)
        #expect(newButton.imageHugsTitle)
        #expect(newButton.alignment == .left)
        let imageRect = try #require(newButton.cell?.imageRect(forBounds: newButton.bounds))
        let titleRect = try #require(newButton.cell?.titleRect(forBounds: newButton.bounds))
        #expect(imageRect.minX >= InkDesignTokens.Spacing.xs - 0.5)
        #expect(titleRect.width >= newButton.attributedTitle.size().width)
        #expect(controller.view.subviews.compactMap { $0 as? NSButton }.count == 1)
        #expect(!hasShortcutHints(in: controller.view))
    }

    @Test("图标态底部只保留居中加号")
    func compactFooterUsesCenteredNewProject() throws {
        let (controller, newButton, separator) = try makeController(mode: .compact)

        #expect(abs(newButton.frame.midX - controller.view.bounds.midX) < 0.5)
        #expect(separator.frame.minY > newButton.frame.maxY)
        #expect(newButton.alignment == .center)
        #expect(newButton.title.isEmpty)
        #expect(newButton.toolTip == "新建项目")
        #expect(controller.view.subviews.compactMap { $0 as? NSButton }.count == 1)
        #expect(!hasShortcutHints(in: controller.view))
    }

    private func makeController(
        mode: SidebarViewController.DisplayMode
    ) throws -> (SidebarViewController, NSButton, NSBox) {
        let controller = SidebarViewController()
        controller.displayMode = mode
        let width = mode == .compact
            ? InkDesignTokens.Sidebar.compactWidth
            : InkDesignTokens.Sidebar.width
        controller.view.frame = NSRect(x: 0, y: 0, width: width, height: 700)
        controller.view.appearance = NSAppearance(named: .aqua)
        controller.reload(rows: [
            .init(
                title: "~",
                detail: "",
                status: "1 个标签",
                fullPath: "~",
                active: true,
                pinned: false,
                label: .none
            ),
        ])
        controller.view.layoutSubtreeIfNeeded()

        let buttons = controller.view.subviews.compactMap { $0 as? NSButton }
        let newButton = try #require(buttons.first { button in
            button.title == "新建项目" || button.toolTip == "新建项目"
        })
        let separator = try #require(
            controller.view.subviews.compactMap { $0 as? NSBox }.first
        )
        return (controller, newButton, separator)
    }

    private func makeLabelController(
        mode: SidebarViewController.DisplayMode
    ) -> SidebarViewController {
        let controller = SidebarViewController()
        controller.displayMode = mode
        let width = mode == .compact
            ? InkDesignTokens.Sidebar.compactWidth
            : InkDesignTokens.Sidebar.width
        controller.view.frame = NSRect(x: 0, y: 0, width: width, height: 700)
        controller.reload(rows: [
            .init(
                title: "ink",
                detail: "~/work/code",
                status: "1 个标签",
                fullPath: "~/work/code/ink",
                active: true,
                pinned: false,
                label: .red
            ),
            .init(
                title: "notes",
                detail: "~/work",
                status: "未打开",
                fullPath: "~/work/notes",
                active: false,
                pinned: false,
                label: .none
            ),
        ])
        controller.view.layoutSubtreeIfNeeded()
        return controller
    }

    private func descendants<T: NSView>(of type: T.Type, in view: NSView) -> [T] {
        view.subviews.flatMap { child in
            (child as? T).map { [$0] } ?? descendants(of: type, in: child)
        }
    }

    private func hasShortcutHints(in view: NSView) -> Bool {
        view.subviews
            .compactMap { $0 as? NSTextField }
            .contains { ["⌘N", "⌘,"].contains($0.stringValue) }
    }
}
