import Foundation

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
