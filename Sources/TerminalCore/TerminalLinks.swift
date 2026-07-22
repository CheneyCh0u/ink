import Foundation

public enum TerminalLinkSource: Sendable, Equatable {
    case osc8
    case detectedURL
}

public struct TerminalLink: Sendable, Equatable {
    public let target: String
    public let range: SemanticTextRange
    public let source: TerminalLinkSource

    public init(target: String, range: SemanticTextRange, source: TerminalLinkSource) {
        self.target = target
        self.range = range
        self.source = source
    }
}

struct TerminalLogicalScalar: Sendable {
    let value: UInt32
    let startOffset: Int
    let endOffset: Int
}

struct TerminalLogicalSegment: Sendable {
    let lineID: UInt64
    let absoluteLine: Int
    let startOffset: Int
    let cellCount: Int
}

struct TerminalLogicalLine: Sendable {
    let headLineID: UInt64
    let scalars: ContiguousArray<TerminalLogicalScalar>
    let segments: ContiguousArray<TerminalLogicalSegment>

    func logicalOffset(at position: TextPosition) -> Int? {
        guard let segment = segments.first(where: { $0.absoluteLine == position.line }),
              position.column >= 0,
              position.column < segment.cellCount
        else { return nil }
        return segment.startOffset + position.column
    }

    /// 半开逻辑偏移投影回物理位置；段尾优先归到下一条 wrapped 行的第 0 列。
    func position(at offset: Int) -> TextPosition? {
        guard offset >= 0 else { return nil }
        for index in segments.indices {
            let segment = segments[index]
            let end = segment.startOffset + segment.cellCount
            if offset < end {
                return TextPosition(
                    line: segment.absoluteLine,
                    column: offset - segment.startOffset
                )
            }
            if offset == end, index == segments.index(before: segments.endIndex) {
                return TextPosition(line: segment.absoluteLine, column: segment.cellCount)
            }
        }
        return nil
    }
}

enum TerminalURLDetector {
    struct Match: Sendable, Equatable {
        let target: String
        let offsets: Range<Int>
    }

    static func match(
        in line: TerminalLogicalLine,
        containing logicalOffset: Int
    ) -> Match? {
        let scalars = line.scalars
        guard !scalars.isEmpty else { return nil }

        for index in scalars.indices where isSchemeStart(scalars, at: index) {
            let candidateEnd = endOfCandidate(in: scalars, from: index)
            let end = trimTrailingPunctuation(in: scalars, start: index, end: candidateEnd)
            guard end > index else { continue }

            let offsets = scalars[index].startOffset..<scalars[end - 1].endOffset
            guard offsets.contains(logicalOffset) else { continue }

            var target = ""
            for scalar in scalars[index..<end] {
                guard let unicode = Unicode.Scalar(scalar.value) else {
                    target = ""
                    break
                }
                target.unicodeScalars.append(unicode)
            }
            guard !target.isEmpty,
                  let components = URLComponents(string: target),
                  let scheme = components.scheme?.lowercased(),
                  scheme == "http" || scheme == "https",
                  components.host?.isEmpty == false
            else { continue }

            return Match(target: target, offsets: offsets)
        }
        return nil
    }

    private static func isSchemeStart(
        _ scalars: ContiguousArray<TerminalLogicalScalar>,
        at index: Int
    ) -> Bool {
        matchesASCII("http://", in: scalars, at: index)
            || matchesASCII("https://", in: scalars, at: index)
    }

    private static func matchesASCII(
        _ needle: StaticString,
        in scalars: ContiguousArray<TerminalLogicalScalar>,
        at index: Int
    ) -> Bool {
        let bytes = needle.withUTF8Buffer { Array($0) }
        guard index + bytes.count <= scalars.count else { return false }
        for offset in bytes.indices {
            let actual = scalars[index + offset].value
            let expected = UInt32(bytes[offset])
            guard asciiLower(actual) == asciiLower(expected) else { return false }
        }
        return true
    }

    private static func asciiLower(_ scalar: UInt32) -> UInt32 {
        (0x41...0x5A).contains(scalar) ? scalar + 0x20 : scalar
    }

    private static func endOfCandidate(
        in scalars: ContiguousArray<TerminalLogicalScalar>,
        from start: Int
    ) -> Int {
        var index = start
        while index < scalars.count, !isDelimiter(scalars[index].value) {
            index += 1
        }
        return index
    }

    private static func isDelimiter(_ value: UInt32) -> Bool {
        guard let scalar = Unicode.Scalar(value) else { return true }
        if scalar.properties.isWhitespace { return true }
        if value <= 0x1F || (0x7F...0x9F).contains(value) { return true }
        switch value {
        case 0x22, 0x27, 0x3C, 0x3E, 0x5C, 0x60, // " ' < > \ `
             0x2018, 0x2019, 0x201C, 0x201D,       // 弯引号
             0x3002, 0xFF0C, 0xFF1B, 0xFF1A, 0xFF01, 0xFF1F: // 中文句读
            return true
        default:
            return false
        }
    }

    private static func trimTrailingPunctuation(
        in scalars: ContiguousArray<TerminalLogicalScalar>,
        start: Int,
        end initialEnd: Int
    ) -> Int {
        var end = initialEnd
        while end > start {
            let value = scalars[end - 1].value
            if isSentencePunctuation(value) {
                end -= 1
                continue
            }
            guard let opening = matchingOpening(for: value),
                  count(value, in: scalars, start: start, end: end)
                    > count(opening, in: scalars, start: start, end: end)
            else { break }
            end -= 1
        }
        return end
    }

    private static func isSentencePunctuation(_ value: UInt32) -> Bool {
        switch value {
        case 0x2E, 0x2C, 0x3B, 0x3A, 0x21, 0x3F,
             0x3002, 0xFF0C, 0xFF1B, 0xFF1A, 0xFF01, 0xFF1F:
            return true
        default:
            return false
        }
    }

    private static func matchingOpening(for closing: UInt32) -> UInt32? {
        switch closing {
        case 0x29: 0x28
        case 0x5D: 0x5B
        case 0x7D: 0x7B
        default: nil
        }
    }

    private static func count(
        _ value: UInt32,
        in scalars: ContiguousArray<TerminalLogicalScalar>,
        start: Int,
        end: Int
    ) -> Int {
        scalars[start..<end].reduce(into: 0) { result, scalar in
            if scalar.value == value { result += 1 }
        }
    }
}

extension Terminal {
    public func link(at position: TextPosition) -> TerminalLink? {
        guard let line = logicalLine(containing: position),
              let offset = line.logicalOffset(at: position),
              let match = TerminalURLDetector.match(in: line, containing: offset),
              let start = line.position(at: match.offsets.lowerBound),
              let end = line.position(at: match.offsets.upperBound)
        else { return nil }
        return TerminalLink(
            target: match.target,
            range: SemanticTextRange(start: start, end: end),
            source: .detectedURL
        )
    }

    func logicalLine(containing position: TextPosition) -> TerminalLogicalLine? {
        guard position.line >= 0, position.line < totalLines else { return nil }

        var head = position.line
        while head > 0, absoluteLineInfo(head)?.isWrapped == true {
            head -= 1
        }
        var tail = position.line + 1
        while tail < totalLines, absoluteLineInfo(tail)?.isWrapped == true {
            tail += 1
        }

        let oldestLineID = scrollback.totalAppendedLines - UInt64(scrollback.count)
        var logicalOffset = 0
        var scalars = ContiguousArray<TerminalLogicalScalar>()
        var segments = ContiguousArray<TerminalLogicalSegment>()

        for lineIndex in head..<tail {
            guard var cells = absoluteLine(lineIndex)?.cells else { return nil }
            while let last = cells.last, last.isBlank {
                cells.removeLast()
            }
            segments.append(TerminalLogicalSegment(
                lineID: oldestLineID + UInt64(lineIndex),
                absoluteLine: lineIndex,
                startOffset: logicalOffset,
                cellCount: cells.count
            ))

            for column in cells.indices {
                let cell = cells[column]
                if cell.attr & Cell.Attr.wideTrailing != 0 { continue }
                let startOffset = logicalOffset + column
                let endOffset = startOffset
                    + (cell.attr & Cell.Attr.wideLeading != 0 ? 2 : 1)
                if cell.isCluster {
                    for scalar in clusterTable.scalars(for: cell.scalar) {
                        scalars.append(TerminalLogicalScalar(
                            value: scalar,
                            startOffset: startOffset,
                            endOffset: endOffset
                        ))
                    }
                } else {
                    scalars.append(TerminalLogicalScalar(
                        value: cell.scalar,
                        startOffset: startOffset,
                        endOffset: endOffset
                    ))
                }
            }
            logicalOffset += cells.count
        }

        return TerminalLogicalLine(
            headLineID: oldestLineID + UInt64(head),
            scalars: scalars,
            segments: segments
        )
    }
}
