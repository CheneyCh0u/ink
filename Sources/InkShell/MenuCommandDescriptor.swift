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
