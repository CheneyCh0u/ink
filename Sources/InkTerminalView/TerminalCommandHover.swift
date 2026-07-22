import Foundation
import TerminalCore

struct CommandHoverTarget: Sendable, Equatable {
    let commandStartLineID: UInt64
    let layoutRevision: UInt64
}

struct CommandHoverResolution: Sendable, Equatable {
    let block: CommandBlock
    let previous: CommandBlock?
    let next: CommandBlock?
}

final class CommandHoverMenuPayload: NSObject {
    let target: CommandHoverTarget

    init(target: CommandHoverTarget) {
        self.target = target
    }
}

enum CommandHoverResolver {
    static func target(startingAt line: Int, in terminal: Terminal) -> CommandHoverTarget? {
        guard line >= 0,
              terminal.commandBlocks().contains(where: {
                  $0.commandRange.start.line == line
              }) else { return nil }
        let oldestLineID = terminal.scrollback.totalAppendedLines
            - UInt64(terminal.scrollback.count)
        return CommandHoverTarget(
            commandStartLineID: oldestLineID + UInt64(line),
            layoutRevision: terminal.searchLayoutRevision
        )
    }

    static func resolve(
        _ target: CommandHoverTarget,
        in terminal: Terminal
    ) -> CommandHoverResolution? {
        guard target.layoutRevision == terminal.searchLayoutRevision else { return nil }
        let oldestLineID = terminal.scrollback.totalAppendedLines
            - UInt64(terminal.scrollback.count)
        guard target.commandStartLineID >= oldestLineID else { return nil }
        let line = Int(target.commandStartLineID - oldestLineID)
        guard line < terminal.totalLines else { return nil }

        let blocks = terminal.commandBlocks()
        guard let index = blocks.firstIndex(where: {
            $0.commandRange.start.line == line
        }) else { return nil }
        return CommandHoverResolution(
            block: blocks[index],
            previous: index > blocks.startIndex ? blocks[index - 1] : nil,
            next: index + 1 < blocks.endIndex ? blocks[index + 1] : nil
        )
    }

}
