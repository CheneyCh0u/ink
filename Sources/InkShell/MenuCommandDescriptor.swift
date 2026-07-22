import AppKit
import InkConfig

struct MenuCommandDescriptor {
    let action: KeyBindingAction
    let selector: Selector

    static let all: [MenuCommandDescriptor] = [
        .init(action: .newProject, selector: #selector(MainWindowController.newProject(_:))),
        .init(action: .newTab, selector: #selector(MainWindowController.newSession(_:))),
        .init(action: .closePane, selector: #selector(MainWindowController.closeActivePane(_:))),
        .init(action: .splitLeft, selector: #selector(MainWindowController.splitLeft(_:))),
        .init(action: .splitRight, selector: #selector(MainWindowController.splitRight(_:))),
        .init(action: .splitUp, selector: #selector(MainWindowController.splitUp(_:))),
        .init(action: .splitDown, selector: #selector(MainWindowController.splitDown(_:))),
        .init(action: .focusLeft, selector: #selector(MainWindowController.focusPaneLeft(_:))),
        .init(action: .focusRight, selector: #selector(MainWindowController.focusPaneRight(_:))),
        .init(action: .focusUp, selector: #selector(MainWindowController.focusPaneUp(_:))),
        .init(action: .focusDown, selector: #selector(MainWindowController.focusPaneDown(_:))),
        .init(action: .find, selector: #selector(MainWindowController.findInActivePane(_:))),
        .init(action: .fontIncrease, selector: #selector(MainWindowController.increaseFontSize(_:))),
        .init(action: .fontDecrease, selector: #selector(MainWindowController.decreaseFontSize(_:))),
        .init(action: .fontReset, selector: #selector(MainWindowController.resetFontSize(_:))),
        .init(action: .previousCommand, selector: #selector(MainWindowController.previousCommand(_:))),
        .init(action: .nextCommand, selector: #selector(MainWindowController.nextCommand(_:))),
        .init(action: .copyCommand, selector: #selector(MainWindowController.copyCommand(_:))),
        .init(action: .copyOutput, selector: #selector(MainWindowController.copyCommandOutput(_:))),
        .init(action: .previousTab, selector: #selector(MainWindowController.previousSession(_:))),
        .init(action: .nextTab, selector: #selector(MainWindowController.nextSession(_:))),
        .init(action: .toggleSidebar, selector: #selector(MainWindowController.toggleSidebarMode(_:))),
    ]
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
