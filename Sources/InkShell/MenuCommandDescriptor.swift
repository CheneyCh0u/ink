import AppKit
import InkConfig

enum MenuCommandGroup: String {
    case file = "文件"
    case edit = "编辑"
    case view = "显示"
    case window = "窗口"

    var title: String { rawValue }
}

struct MenuCommandDescriptor {
    let action: KeyBindingAction
    let title: String
    let selector: Selector
    let group: MenuCommandGroup
    let tag: Int

    init(
        action: KeyBindingAction,
        title: String,
        selector: Selector,
        group: MenuCommandGroup,
        tag: Int = 0
    ) {
        self.action = action
        self.title = title
        self.selector = selector
        self.group = group
        self.tag = tag
    }

    static let all: [MenuCommandDescriptor] = [
        .init(
            action: .newProject,
            title: "新建项目…",
            selector: #selector(MainWindowController.newProject(_:)),
            group: .file
        ),
        .init(
            action: .newTab,
            title: "新建标签",
            selector: #selector(MainWindowController.newSession(_:)),
            group: .file
        ),
        .init(
            action: .splitLeft,
            title: "向左分屏",
            selector: #selector(MainWindowController.splitLeft(_:)),
            group: .file
        ),
        .init(
            action: .splitRight,
            title: "向右分屏",
            selector: #selector(MainWindowController.splitRight(_:)),
            group: .file
        ),
        .init(
            action: .splitUp,
            title: "向上分屏",
            selector: #selector(MainWindowController.splitUp(_:)),
            group: .file
        ),
        .init(
            action: .splitDown,
            title: "向下分屏",
            selector: #selector(MainWindowController.splitDown(_:)),
            group: .file
        ),
        .init(
            action: .closePane,
            title: "关闭当前分屏",
            selector: #selector(MainWindowController.closeActivePane(_:)),
            group: .file
        ),
        .init(
            action: .find,
            title: "查找…",
            selector: #selector(MainWindowController.findInActivePane(_:)),
            group: .edit
        ),
        .init(
            action: .previousCommand,
            title: "上一条命令",
            selector: #selector(MainWindowController.previousCommand(_:)),
            group: .edit
        ),
        .init(
            action: .nextCommand,
            title: "下一条命令",
            selector: #selector(MainWindowController.nextCommand(_:)),
            group: .edit
        ),
        .init(
            action: .copyCommand,
            title: "拷贝命令",
            selector: #selector(MainWindowController.copyCommand(_:)),
            group: .edit
        ),
        .init(
            action: .copyOutput,
            title: "拷贝命令输出",
            selector: #selector(MainWindowController.copyCommandOutput(_:)),
            group: .edit
        ),
        .init(
            action: .fontIncrease,
            title: "放大字号",
            selector: #selector(MainWindowController.increaseFontSize(_:)),
            group: .view
        ),
        .init(
            action: .fontDecrease,
            title: "缩小字号",
            selector: #selector(MainWindowController.decreaseFontSize(_:)),
            group: .view
        ),
        .init(
            action: .fontReset,
            title: "恢复默认字号",
            selector: #selector(MainWindowController.resetFontSize(_:)),
            group: .view
        ),
        .init(
            action: .toggleSidebar,
            title: "切换侧边栏",
            selector: #selector(MainWindowController.toggleSidebarMode(_:)),
            group: .view
        ),
        .init(
            action: .focusLeft,
            title: "聚焦左侧 pane",
            selector: #selector(MainWindowController.focusPaneLeft(_:)),
            group: .window
        ),
        .init(
            action: .focusRight,
            title: "聚焦右侧 pane",
            selector: #selector(MainWindowController.focusPaneRight(_:)),
            group: .window
        ),
        .init(
            action: .focusUp,
            title: "聚焦上方 pane",
            selector: #selector(MainWindowController.focusPaneUp(_:)),
            group: .window
        ),
        .init(
            action: .focusDown,
            title: "聚焦下方 pane",
            selector: #selector(MainWindowController.focusPaneDown(_:)),
            group: .window
        ),
        .init(
            action: .nextTab,
            title: "下一个会话",
            selector: #selector(MainWindowController.nextSession(_:)),
            group: .window
        ),
        .init(
            action: .previousTab,
            title: "上一个会话",
            selector: #selector(MainWindowController.previousSession(_:)),
            group: .window
        ),
    ]

    static func descriptors(in group: MenuCommandGroup) -> [MenuCommandDescriptor] {
        all.filter { $0.group == group }
    }
}

extension KeyBindingAction {
    var displayTitle: String {
        switch self {
        case .newProject: "新建项目"
        case .newTab: "新建标签"
        case .closePane: "关闭当前分屏"
        case .splitPrefix: "分屏前缀"
        case .splitLeft: "向左分屏"
        case .splitRight: "向右分屏"
        case .splitUp: "向上分屏"
        case .splitDown: "向下分屏"
        case .focusLeft: "聚焦左侧分屏"
        case .focusRight: "聚焦右侧分屏"
        case .focusUp: "聚焦上方分屏"
        case .focusDown: "聚焦下方分屏"
        case .find: "查找"
        case .fontIncrease: "放大字号"
        case .fontDecrease: "缩小字号"
        case .fontReset: "恢复默认字号"
        case .previousCommand: "上一条命令"
        case .nextCommand: "下一条命令"
        case .copyCommand: "拷贝命令"
        case .copyOutput: "拷贝命令输出"
        case .previousTab: "上一个会话"
        case .nextTab: "下一个会话"
        case .toggleSidebar: "切换侧边栏"
        }
    }
}
