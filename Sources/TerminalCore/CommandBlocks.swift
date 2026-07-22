/// OSC 133 标记定义的半开文本范围。`start` 包含，`end` 不包含，因而可以
/// 精确表达“命令结束于下一物理行第 0 列”而不把回车复制进去。
public struct SemanticTextRange: Sendable, Equatable {
    public let start: TextPosition
    public let end: TextPosition

    public init(start: TextPosition, end: TextPosition) {
        self.start = start
        self.end = end
    }
}

public struct CommandBlock: Sendable, Equatable {
    public let commandRange: SemanticTextRange
    public let outputRange: SemanticTextRange?
    public let completion: CommandCompletion?

    public init(
        commandRange: SemanticTextRange,
        outputRange: SemanticTextRange?,
        completion: CommandCompletion? = nil
    ) {
        self.commandRange = commandRange
        self.outputRange = outputRange
        self.completion = completion
    }
}

extension Terminal {
    /// 按需扫描 OSC 133 转换点。命令数量通常远少于物理行数，不为此维护
    /// 第二份历史文本或每格索引；只有用户触发跳转/复制时才走这条冷路径。
    public func commandBlocks() -> [CommandBlock] {
        guard !modes.alternateScreen else { return [] }
        var blocks: [CommandBlock] = []
        var commandStart: TextPosition?
        var completedCommand: SemanticTextRange?
        var outputStart: TextPosition?

        let oldestLineID = scrollback.totalAppendedLines - UInt64(scrollback.count)
        var overflowByLine: [Int: [SemanticOverflowTransition]] = [:]
        for transition in semanticOverflowTransitions[semanticOverflowStart...]
        where transition.lineID >= oldestLineID {
            let line = Int(transition.lineID - oldestLineID)
            guard line < totalLines else { continue }
            overflowByLine[line, default: []].append(transition)
        }
        var completionsByLine: [Int: [CommandCompletionRecord]] = [:]
        for record in liveCommandCompletionRecords where record.lineID >= oldestLineID {
            let line = Int(record.lineID - oldestLineID)
            guard line < totalLines else { continue }
            completionsByLine[line, default: []].append(record)
        }

        func completion(at position: TextPosition) -> CommandCompletion? {
            completionsByLine[position.line]?
                .last(where: { Int($0.column) == position.column })?
                .completion
        }

        func consume(_ mark: SemanticMark, at position: TextPosition) {
            switch mark {
            case .command:
                if let command = completedCommand, let outputStart {
                    blocks.append(CommandBlock(
                        commandRange: command,
                        outputRange: SemanticTextRange(start: outputStart, end: position),
                        completion: nil
                    ))
                }
                commandStart = position
                completedCommand = nil
                outputStart = nil

            case .output:
                guard let start = commandStart, start <= position else { return }
                completedCommand = SemanticTextRange(start: start, end: position)
                commandStart = nil
                outputStart = position

            case .prompt:
                if let command = completedCommand, let outputStart, outputStart <= position {
                    blocks.append(CommandBlock(
                        commandRange: command,
                        outputRange: SemanticTextRange(start: outputStart, end: position),
                        completion: nil
                    ))
                }
                commandStart = nil
                completedCommand = nil
                outputStart = nil

            case .none:
                if let command = completedCommand, let outputStart, outputStart <= position {
                    blocks.append(CommandBlock(
                        commandRange: command,
                        outputRange: SemanticTextRange(start: outputStart, end: position),
                        completion: completion(at: position)
                    ))
                }
                commandStart = nil
                completedCommand = nil
                outputStart = nil
            }
        }

        for line in 0..<totalLines {
            for transition in overflowByLine[line] ?? [] {
                consume(
                    transition.mark,
                    at: TextPosition(line: line, column: Int(transition.column))
                )
            }
            guard let info = absoluteLineInfo(line),
                  let column = info.semanticTransitionColumn else { continue }
            consume(info.semanticMark, at: TextPosition(line: line, column: column))
        }

        return blocks
    }

    /// 提取半开语义范围。软折行拼接、硬换行保留，行为与普通选区复制一致。
    public func extractText(in range: SemanticTextRange) -> String {
        guard range.start < range.end else { return "" }
        let lastLine = range.end.column == 0 ? range.end.line - 1 : range.end.line
        guard range.start.line >= 0,
              range.start.line < totalLines,
              lastLine >= range.start.line else { return "" }

        var out = ""
        let boundedLastLine = min(lastLine, totalLines - 1)
        for lineIndex in range.start.line...boundedLastLine {
            guard let (cells, _) = absoluteLine(lineIndex) else { continue }
            let from = lineIndex == range.start.line ? max(0, range.start.column) : 0
            let to = lineIndex == range.end.line
                ? min(max(range.end.column, 0), cells.count)
                : cells.count

            if from < to {
                var lineText = ""
                var trailingBlanks = 0
                for col in from..<to {
                    let cell = cells[col]
                    if cell.attr & Cell.Attr.wideTrailing != 0 { continue }
                    if cell.isBlank {
                        trailingBlanks += 1
                        lineText.unicodeScalars.append(" ")
                        continue
                    }
                    trailingBlanks = 0
                    if cell.isCluster {
                        for scalar in clusterTable.scalars(for: cell.scalar) {
                            lineText.unicodeScalars.append(Unicode.Scalar(scalar) ?? "\u{FFFD}")
                        }
                    } else {
                        lineText.unicodeScalars.append(Unicode.Scalar(cell.scalar) ?? "\u{FFFD}")
                    }
                }
                if trailingBlanks > 0 { lineText.removeLast(trailingBlanks) }
                out += lineText
            }

            if lineIndex < boundedLastLine {
                let nextWrapped = absoluteLineInfo(lineIndex + 1)?.isWrapped ?? false
                if !nextWrapped { out += "\n" }
            }
        }
        return out
    }
}
