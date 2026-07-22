import Foundation

public enum TerminalContextSplitDirection: String, Sendable, Equatable {
    case left
    case right
    case up
    case down
}

enum LinkContextAction: Sendable, Equatable {
    case reportToTUI
    case showNativeMenu
}

enum LinkMouseRouter {
    static func contextAction(
        mouseReporting: Bool,
        optionHeld: Bool
    ) -> LinkContextAction {
        mouseReporting && !optionHeld ? .reportToTUI : .showNativeMenu
    }
}

struct TerminalLinkMenuPayload: Sendable, Equatable {
    let target: String

    var url: URL? {
        guard let url = URL(string: target), url.scheme?.isEmpty == false else { return nil }
        return url
    }
}
