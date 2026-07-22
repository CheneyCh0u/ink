import AppKit

@MainActor
protocol OSC52PasteboardWriting: AnyObject {
    @discardableResult func write(_ text: String) -> Bool
}

@MainActor
final class OSC52PasteboardWriter: OSC52PasteboardWriting {
    private let pasteboard: NSPasteboard

    init(pasteboard: NSPasteboard = .general) {
        self.pasteboard = pasteboard
    }

    @discardableResult
    func write(_ text: String) -> Bool {
        pasteboard.clearContents()
        return pasteboard.setString(text, forType: .string)
    }
}
