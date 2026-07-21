import AppKit
import InkPTY

enum SessionCloseTarget: Equatable {
    case pane
    case tab
    case project
    case window
    case application

    var destructiveButtonTitle: String {
        switch self {
        case .pane: "关闭分屏"
        case .tab: "关闭标签"
        case .project: "移除项目"
        case .window: "关闭窗口"
        case .application: "退出 Ink"
        }
    }
}

struct SessionCloseAlertContent: Equatable {
    let messageText: String
    let informativeText: String
    let destructiveButtonTitle: String
}

enum SessionCloseConfirmation {
    static func content(
        target: SessionCloseTarget,
        processes: [PTYSession.ForegroundProcess]
    ) -> SessionCloseAlertContent? {
        let programs = processes.reduce(into: [String?]()) { result, process in
            if case let .program(name) = process {
                result.append(name)
            }
        }
        guard !programs.isEmpty else { return nil }

        let count = programs.count
        let messageText: String = switch target {
        case .window:
            "关闭窗口并结束 \(count) 个活跃会话？"
        case .application:
            "退出 Ink 并结束 \(count) 个活跃会话？"
        case .pane, .tab, .project:
            count == 1 ? "关闭正在运行的会话？" : "关闭 \(count) 个正在运行的会话？"
        }

        var knownNames: [String] = []
        for name in programs.compactMap({ $0 }) where !knownNames.contains(name) {
            knownNames.append(name)
        }

        let informativeText: String
        if count == 1, let name = knownNames.first {
            informativeText = "\(name) 仍在运行。关闭后，该进程会被终止。"
        } else if knownNames.isEmpty {
            informativeText = "有会话仍在运行。关闭后，前台进程会被终止。"
        } else {
            let names = knownNames.prefix(3).joined(separator: "、")
            let needsTotal = count > 3 || knownNames.count < count
            let summary = needsTotal ? "\(names) 等 \(count) 个会话" : names
            informativeText = "\(summary)仍在运行。未保存的工作可能丢失。"
        }

        return SessionCloseAlertContent(
            messageText: messageText,
            informativeText: informativeText,
            destructiveButtonTitle: target.destructiveButtonTitle
        )
    }
}

@MainActor
protocol SessionClosePresenting: AnyObject {
    func confirm(_ content: SessionCloseAlertContent) -> Bool
}

@MainActor
final class NSAlertSessionClosePresenter: SessionClosePresenting {
    func confirm(_ content: SessionCloseAlertContent) -> Bool {
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = content.messageText
        alert.informativeText = content.informativeText
        let destructive = alert.addButton(withTitle: content.destructiveButtonTitle)
        destructive.hasDestructiveAction = true
        let cancel = alert.addButton(withTitle: "取消")
        cancel.keyEquivalent = "\u{1b}"
        return alert.runModal() == .alertFirstButtonReturn
    }
}

@MainActor
final class SessionCloseCoordinator {
    private let presenter: any SessionClosePresenting
    private var applicationTerminationApproved = false
    private var isPresentingConfirmation = false

    init(presenter: any SessionClosePresenting = NSAlertSessionClosePresenter()) {
        self.presenter = presenter
    }

    @discardableResult
    func perform(
        target: SessionCloseTarget,
        processes: [PTYSession.ForegroundProcess],
        action: () -> Void
    ) -> Bool {
        if let content = SessionCloseConfirmation.content(
            target: target,
            processes: processes
        ), !confirm(content) {
            return false
        }
        action()
        return true
    }

    func requestApplicationTermination(
        processes: [PTYSession.ForegroundProcess]
    ) -> Bool {
        let approved: Bool
        if let content = SessionCloseConfirmation.content(
            target: .application,
            processes: processes
        ) {
            approved = confirm(content)
        } else {
            approved = true
        }
        applicationTerminationApproved = approved
        return approved
    }

    func allowWindowClose(processes: [PTYSession.ForegroundProcess]) -> Bool {
        if applicationTerminationApproved {
            applicationTerminationApproved = false
            return true
        }
        guard let content = SessionCloseConfirmation.content(
            target: .window,
            processes: processes
        ) else { return true }
        return confirm(content)
    }

    private func confirm(_ content: SessionCloseAlertContent) -> Bool {
        guard !isPresentingConfirmation else { return false }
        isPresentingConfirmation = true
        defer { isPresentingConfirmation = false }
        return presenter.confirm(content)
    }
}
