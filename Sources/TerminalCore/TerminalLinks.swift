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
        guard let hitIndex = scalars.firstIndex(where: {
            $0.startOffset <= logicalOffset && logicalOffset < $0.endOffset
        }) else { return nil }

        var tokenStart = hitIndex
        while tokenStart > scalars.startIndex,
              !isDelimiter(scalars[tokenStart - 1].value) {
            tokenStart -= 1
        }
        var tokenEnd = hitIndex + 1
        while tokenEnd < scalars.endIndex,
              !isDelimiter(scalars[tokenEnd].value) {
            tokenEnd += 1
        }

        // 同一无分隔 token 只验证一个候选，避免重复 `http:///` 触发二次扫描。
        var schemeStart: Int?
        for index in tokenStart...hitIndex where isSchemeStart(scalars, at: index) {
            schemeStart = index
        }
        guard let start = schemeStart else { return nil }
        let end = trimTrailingPunctuation(in: scalars, start: start, end: tokenEnd)
        guard end > start else { return nil }

        let offsets = scalars[start].startOffset..<scalars[end - 1].endOffset
        guard offsets.contains(logicalOffset) else { return nil }

        var target = ""
        for scalar in scalars[start..<end] {
            guard let unicode = Unicode.Scalar(scalar.value) else { return nil }
            target.unicodeScalars.append(unicode)
        }
        guard let components = URLComponents(string: target),
              let scheme = components.scheme?.lowercased(),
              scheme == "http" || scheme == "https",
              components.host?.isEmpty == false
        else { return nil }

        return Match(target: target, offsets: offsets)
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
        needle.withUTF8Buffer { bytes in
            guard index + bytes.count <= scalars.count else { return false }
            for offset in bytes.indices {
                let actual = scalars[index + offset].value
                let expected = UInt32(bytes[offset])
                guard asciiLower(actual) == asciiLower(expected) else { return false }
            }
            return true
        }
    }

    private static func asciiLower(_ scalar: UInt32) -> UInt32 {
        (0x41...0x5A).contains(scalar) ? scalar + 0x20 : scalar
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
        var openingCounts: [UInt32: Int] = [:]
        var closingCounts: [UInt32: Int] = [:]
        for scalar in scalars[start..<end] {
            if matchingClosing(for: scalar.value) != nil {
                openingCounts[scalar.value, default: 0] += 1
            } else if matchingOpening(for: scalar.value) != nil {
                closingCounts[scalar.value, default: 0] += 1
            }
        }
        while end > start {
            let value = scalars[end - 1].value
            if isSentencePunctuation(value) {
                end -= 1
                continue
            }
            guard let opening = matchingOpening(for: value),
                  closingCounts[value, default: 0] > openingCounts[opening, default: 0]
            else { break }
            closingCounts[value, default: 0] -= 1
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

    private static func matchingClosing(for opening: UInt32) -> UInt32? {
        switch opening {
        case 0x28: 0x29
        case 0x5B: 0x5D
        case 0x7B: 0x7D
        default: nil
        }
    }
}

extension Terminal {
    /// 鼠标命中必须同步返回；限制单次冷路径物化，避免恶意超长软折行阻塞主线程。
    private static let maxLinkSnapshotCells = 65_536
    private static let maxLinkSnapshotRows = 2_048
    private static let maxExplicitProjectionRows = 2_048

    public func link(at position: TextPosition) -> TerminalLink? {
        if let explicit = explicitLink(at: position) { return explicit }
        guard let line = logicalLine(
            containing: position,
            preserveGridTrailingBlanks: true,
            cellLimit: Self.maxLinkSnapshotCells,
            rowLimit: Self.maxLinkSnapshotRows
        ), let offset = line.logicalOffset(at: position)
        else { return nil }
        guard
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

    var hyperlinkMetadataAllocated: Bool { hyperlinks != nil }

    var explicitHyperlinkRecordCount: Int { hyperlinks?.lineCount ?? 0 }
    var explicitHyperlinkStorageCount: Int { hyperlinks?.lineStorageCount ?? 0 }
    var explicitHyperlinkRowAnchorCount: Int { hyperlinks?.rowIndex.count ?? 0 }

    private func explicitLink(at position: TextPosition) -> TerminalLink? {
        guard position.line >= 0, position.line < totalLines, position.column >= 0 else { return nil }
        let physicalCellCount = position.line < scrollback.count
            ? scrollback[position.line].count
            : grid.size.columns
        guard position.column < physicalCellCount else { return nil }
        let oldestLineID = scrollback.totalAppendedLines - UInt64(scrollback.count)
        let stableLineID = oldestLineID + UInt64(position.line)
        guard let hyperlinks,
              let targets = hyperlinkTargets,
              let anchor = hyperlinks.anchor(for: stableLineID),
              let record = hyperlinks.record(headLineID: anchor.headLineID),
              let span = record.span(
                  containing: anchor.startOffset + UInt32(clamping: position.column)
              ),
              let target = targets.uri(for: span.targetID)
        else { return nil }
        let fallbackEnd = TextPosition(
            line: position.line,
            column: min(physicalCellCount, position.column + 1)
        )
        let start = projectExplicitOffset(
            span.offsets.lowerBound,
            from: stableLineID,
            headLineID: anchor.headLineID
        ) ?? position
        let end = projectExplicitOffset(
            span.offsets.upperBound,
            from: stableLineID,
            headLineID: anchor.headLineID
        ) ?? fallbackEnd
        return TerminalLink(
            target: target,
            range: SemanticTextRange(start: start, end: end),
            source: .osc8
        )
    }

    /// 通过稀疏 row anchor 从命中行向端点走，普通短链接是常数工作；极端跨越超过
    /// 2,048 行时只降级悬停高亮范围，目标仍可打开，不在主线程构造整条逻辑行。
    private func projectExplicitOffset(
        _ offset: UInt32,
        from hitLineID: UInt64,
        headLineID: UInt64
    ) -> TextPosition? {
        guard let hyperlinks else { return nil }
        let oldestLineID = scrollback.totalAppendedLines - UInt64(scrollback.count)
        var lineID = hitLineID
        var visited = 0
        while visited < Self.maxExplicitProjectionRows,
              lineID >= oldestLineID {
            guard let anchor = hyperlinks.anchor(for: lineID),
                  anchor.headLineID == headLineID
            else { return nil }
            let absoluteLine = Int(lineID - oldestLineID)
            guard absoluteLine >= 0, absoluteLine < totalLines else { return nil }
            guard let cellCount = logicalSegmentCellCount(
                at: absoluteLine,
                preserveGridTrailingBlanks: true
            ) else { return nil }
            let segmentEnd = anchor.startOffset + UInt32(clamping: cellCount)
            if offset < anchor.startOffset {
                guard lineID > oldestLineID else { return nil }
                lineID -= 1
            } else if offset < segmentEnd {
                return TextPosition(
                    line: absoluteLine,
                    column: Int(offset - anchor.startOffset)
                )
            } else if offset == segmentEnd {
                let nextLine = absoluteLine + 1
                if nextLine < totalLines, absoluteLineInfo(nextLine)?.isWrapped == true {
                    return TextPosition(line: nextLine, column: 0)
                }
                return TextPosition(line: absoluteLine, column: cellCount)
            } else {
                lineID += 1
            }
            visited += 1
        }
        return nil
    }

    /// wrapped 后继意味着该历史段来自当时的满宽 grid；即使入库裁掉了行尾补白，
    /// 逻辑偏移仍保留这一概念宽度，避免后续 continuation 整体左移。
    func logicalSegmentCellCount(
        at lineIndex: Int,
        preserveGridTrailingBlanks: Bool
    ) -> Int? {
        guard lineIndex >= 0, lineIndex < totalLines else { return nil }
        if lineIndex < scrollback.count {
            let nextIsWrapped = lineIndex + 1 < totalLines
                && absoluteLineInfo(lineIndex + 1)?.isWrapped == true
            return nextIsWrapped ? grid.size.columns : scrollback[lineIndex].count
        }
        let row = grid.row(lineIndex - scrollback.count)
        guard !preserveGridTrailingBlanks else { return row.count }
        var trimmedCount = row.count
        while trimmedCount > 0, row[row.startIndex + trimmedCount - 1].isBlank {
            trimmedCount -= 1
        }
        return trimmedCount
    }

    func logicalLine(
        containing position: TextPosition,
        preserveGridTrailingBlanks: Bool = false,
        cellLimit: Int? = nil,
        rowLimit: Int? = nil,
        includeScalars: Bool = true
    ) -> TerminalLogicalLine? {
        guard position.line >= 0, position.line < totalLines else { return nil }

        var head = position.line
        while head > 0, absoluteLineInfo(head)?.isWrapped == true {
            head -= 1
            if let rowLimit, position.line - head + 1 > rowLimit { return nil }
        }
        var tail = position.line + 1
        while tail < totalLines, absoluteLineInfo(tail)?.isWrapped == true {
            tail += 1
            if let rowLimit, tail - head > rowLimit { return nil }
        }

        let oldestLineID = scrollback.totalAppendedLines - UInt64(scrollback.count)
        var logicalOffset = 0
        var scalars = ContiguousArray<TerminalLogicalScalar>()
        var segments = ContiguousArray<TerminalLogicalSegment>()

        for lineIndex in head..<tail {
            guard let cellCount = logicalSegmentCellCount(
                at: lineIndex,
                preserveGridTrailingBlanks: preserveGridTrailingBlanks
            ) else { return nil }
            if let cellLimit, logicalOffset > cellLimit - cellCount { return nil }
            segments.append(TerminalLogicalSegment(
                lineID: oldestLineID + UInt64(lineIndex),
                absoluteLine: lineIndex,
                startOffset: logicalOffset,
                cellCount: cellCount
            ))

            guard includeScalars else {
                logicalOffset += cellCount
                continue
            }
            let storedCellCount = lineIndex < scrollback.count
                ? scrollback[lineIndex].count
                : cellCount
            for column in 0..<storedCellCount {
                let cell = lineIndex < scrollback.count
                    ? scrollback[lineIndex].cell(at: column)
                    : grid[lineIndex - scrollback.count, column]
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
            logicalOffset += cellCount
        }

        return TerminalLogicalLine(
            headLineID: oldestLineID + UInt64(head),
            scalars: scalars,
            segments: segments
        )
    }
}
