struct HyperlinkSpan: Sendable, Equatable {
    var offsets: Range<UInt32>
    var targetID: UInt32
}

struct HyperlinkLineRecord: Sendable, Equatable {
    var headLineID: UInt64
    var spans: ContiguousArray<HyperlinkSpan>
    /// 当前物理布局中最后一条实际与 span 相交的稳定行号；0 表示索引待重建。
    var lastAnchoredLineID: UInt64 = 0

    func span(containing offset: UInt32) -> HyperlinkSpan? {
        var lower = 0
        var upper = spans.count
        while lower < upper {
            let middle = lower + (upper - lower) / 2
            if spans[middle].offsets.upperBound <= offset {
                lower = middle + 1
            } else {
                upper = middle
            }
        }
        guard lower < spans.count, spans[lower].offsets.contains(offset) else { return nil }
        return spans[lower]
    }

    func overlaps(_ offsets: Range<UInt32>) -> Bool {
        guard !offsets.isEmpty else { return false }
        var lower = 0
        var upper = spans.count
        while lower < upper {
            let middle = lower + (upper - lower) / 2
            if spans[middle].offsets.upperBound <= offsets.lowerBound {
                lower = middle + 1
            } else {
                upper = middle
            }
        }
        return lower < spans.count && spans[lower].offsets.lowerBound < offsets.upperBound
    }
}

struct HyperlinkRowAnchor: Sendable, Equatable {
    var headLineID: UInt64
    var startOffset: UInt32
}

struct HyperlinkRemovedGap: Sendable {
    var offsets: Range<UInt32>
    var removedBefore: UInt32
}

struct HyperlinkReferenceDelta: Sendable {
    var counts: [UInt32: Int] = [:]

    mutating func remove(_ id: UInt32) {
        counts[id, default: 0] -= 1
    }

    mutating func add(_ id: UInt32) {
        counts[id, default: 0] += 1
    }
}

struct HyperlinkRangeStore: Sendable {
    static let defaultMaxLineRecords = 131_072
    static let defaultMaxSpans = 262_144

    private(set) var lines: ContiguousArray<HyperlinkLineRecord> = []
    private var lineStart = 0
    private(set) var rowIndex: [UInt64: HyperlinkRowAnchor] = [:]
    private var newestAnchoredLineID: UInt64?
    private var rowIndexCleanupFloor: UInt64 = 0
    private let maxLineRecords: Int
    private let maxSpans: Int
    private(set) var spanCount = 0

    init(
        maxLineRecords: Int = Self.defaultMaxLineRecords,
        maxSpans: Int = Self.defaultMaxSpans
    ) {
        precondition(maxLineRecords > 0 && maxSpans > 0, "超链接元数据预算必须为正")
        self.maxLineRecords = maxLineRecords
        self.maxSpans = maxSpans
    }

    var isEmpty: Bool { lineStart == lines.count }
    var lineCount: Int { lines.count - lineStart }
    var lineStorageCount: Int { lines.count }
    var isSpanBudgetExhausted: Bool { spanCount >= maxSpans }

    @inline(__always)
    func mayContainRow(lineID: UInt64) -> Bool {
        guard let newestAnchoredLineID else { return false }
        return lineID <= newestAnchoredLineID
    }

    func containsRow(lineID: UInt64) -> Bool {
        guard mayContainRow(lineID: lineID) else { return false }
        return rowIndex[lineID] != nil
    }

    func removingAllReferenceDelta() -> HyperlinkReferenceDelta {
        var delta = HyperlinkReferenceDelta()
        for line in lines[lineStart...] {
            for span in line.spans { delta.remove(span.targetID) }
        }
        return delta
    }

    @inline(__always)
    func needsPrune(before oldestLineID: UInt64) -> Bool {
        lineStart < lines.count && lines[lineStart].headLineID < oldestLineID
    }

    func anchor(for lineID: UInt64) -> HyperlinkRowAnchor? {
        guard let newestAnchoredLineID, lineID <= newestAnchoredLineID else { return nil }
        return rowIndex[lineID]
    }

    func record(headLineID: UInt64) -> HyperlinkLineRecord? {
        guard let index = lineIndex(for: headLineID),
              index < lines.endIndex,
              lines[index].headLineID == headLineID else { return nil }
        return lines[index]
    }

    mutating func replace(
        headLineID: UInt64,
        offsets: Range<UInt32>,
        with targetID: UInt32?
    ) -> HyperlinkReferenceDelta {
        guard !offsets.isEmpty else { return HyperlinkReferenceDelta() }
        let insertionIndex = lineIndex(for: headLineID) ?? lines.endIndex
        let hasRecord = insertionIndex < lines.endIndex
            && lines[insertionIndex].headLineID == headLineID
        guard hasRecord || targetID != nil else { return HyperlinkReferenceDelta() }

        if let targetID,
           hasRecord,
           let last = lines[insertionIndex].spans.last,
           last.offsets.upperBound == offsets.lowerBound {
            if last.targetID == targetID {
                lines[insertionIndex].spans[lines[insertionIndex].spans.count - 1].offsets =
                    last.offsets.lowerBound..<offsets.upperBound
                return HyperlinkReferenceDelta()
            }
            guard spanCount < maxSpans else { return HyperlinkReferenceDelta() }
            lines[insertionIndex].spans.append(HyperlinkSpan(
                offsets: offsets,
                targetID: targetID
            ))
            spanCount += 1
            var delta = HyperlinkReferenceDelta()
            delta.add(targetID)
            return delta
        }
        let oldSpans = hasRecord
            ? lines[insertionIndex].spans
            : ContiguousArray<HyperlinkSpan>()
        var next = ContiguousArray<HyperlinkSpan>()
        next.reserveCapacity(oldSpans.count + (targetID == nil ? 0 : 1))

        for span in oldSpans {
            guard span.offsets.overlaps(offsets) else {
                next.append(span)
                continue
            }
            if span.offsets.lowerBound < offsets.lowerBound {
                next.append(HyperlinkSpan(
                    offsets: span.offsets.lowerBound..<offsets.lowerBound,
                    targetID: span.targetID
                ))
            }
            if span.offsets.upperBound > offsets.upperBound {
                next.append(HyperlinkSpan(
                    offsets: offsets.upperBound..<span.offsets.upperBound,
                    targetID: span.targetID
                ))
            }
        }
        if let targetID {
            next.append(HyperlinkSpan(offsets: offsets, targetID: targetID))
        }
        next.sort {
            if $0.offsets.lowerBound == $1.offsets.lowerBound {
                return $0.offsets.upperBound < $1.offsets.upperBound
            }
            return $0.offsets.lowerBound < $1.offsets.lowerBound
        }
        next = Self.coalesced(next)

        let nextLineCount = lineCount + (hasRecord ? 0 : 1) - (next.isEmpty ? 1 : 0)
        let nextSpanCount = spanCount - oldSpans.count + next.count
        guard nextLineCount <= maxLineRecords, nextSpanCount <= maxSpans else {
            let mustApplyExistingMutation = hasRecord && (
                targetID == nil || oldSpans.contains(where: { $0.offsets.overlaps(offsets) })
            )
            if mustApplyExistingMutation {
                var delta = HyperlinkReferenceDelta()
                for span in oldSpans { delta.remove(span.targetID) }
                removeRowAnchors(headLineID: headLineID)
                removeLine(at: insertionIndex)
                spanCount -= oldSpans.count
                return delta
            }
            return HyperlinkReferenceDelta()
        }

        var delta = HyperlinkReferenceDelta()
        for span in oldSpans { delta.remove(span.targetID) }
        for span in next { delta.add(span.targetID) }

        if next.isEmpty {
            if hasRecord { removeLine(at: insertionIndex) }
        } else if hasRecord {
            lines[insertionIndex].spans = next
        } else {
            lines.insert(
                HyperlinkLineRecord(headLineID: headLineID, spans: next),
                at: insertionIndex
            )
        }
        spanCount = nextSpanCount
        return delta
    }

    mutating func clear(
        headLineID: UInt64,
        offsets: Range<UInt32>
    ) -> HyperlinkReferenceDelta {
        replace(headLineID: headLineID, offsets: offsets, with: nil)
    }

    mutating func insert(
        headLineID: UInt64,
        at offset: UInt32,
        count: UInt32,
        segmentEnd: UInt32
    ) -> HyperlinkReferenceDelta {
        guard count > 0, offset < segmentEnd else { return HyperlinkReferenceDelta() }
        let shiftedEnd = segmentEnd > count ? max(offset, segmentEnd - count) : offset
        return transform(headLineID: headLineID) { span in
            var pieces = ContiguousArray<HyperlinkSpan>()
            Self.appendIntersection(
                of: span,
                with: 0..<offset,
                shiftedBy: 0,
                to: &pieces
            )
            Self.appendIntersection(
                of: span,
                with: offset..<shiftedEnd,
                shiftedBy: Int64(count),
                to: &pieces
            )
            Self.appendIntersection(
                of: span,
                with: segmentEnd..<UInt32.max,
                shiftedBy: 0,
                to: &pieces
            )
            return pieces
        }
    }

    mutating func delete(
        headLineID: UInt64,
        at offset: UInt32,
        count: UInt32,
        segmentEnd: UInt32
    ) -> HyperlinkReferenceDelta {
        guard count > 0, offset < segmentEnd else { return HyperlinkReferenceDelta() }
        let removedEnd = offset + min(count, segmentEnd - offset)
        return transform(headLineID: headLineID) { span in
            var pieces = ContiguousArray<HyperlinkSpan>()
            Self.appendIntersection(
                of: span,
                with: 0..<offset,
                shiftedBy: 0,
                to: &pieces
            )
            Self.appendIntersection(
                of: span,
                with: removedEnd..<segmentEnd,
                shiftedBy: -Int64(removedEnd - offset),
                to: &pieces
            )
            Self.appendIntersection(
                of: span,
                with: segmentEnd..<UInt32.max,
                shiftedBy: 0,
                to: &pieces
            )
            return pieces
        }
    }

    mutating func rebuildRowIndex(for line: TerminalLogicalLine) {
        for segment in line.segments {
            rebuildRowAnchor(
                lineID: segment.lineID,
                headLineID: line.headLineID,
                startOffset: UInt32(clamping: segment.startOffset),
                cellCount: UInt32(clamping: segment.cellCount)
            )
        }
    }

    mutating func rebuildRowAnchor(
        lineID: UInt64,
        headLineID: UInt64,
        startOffset: UInt32,
        cellCount: UInt32
    ) {
        guard let recordIndex = lineIndex(for: headLineID),
              recordIndex < lines.endIndex,
              lines[recordIndex].headLineID == headLineID
        else {
            rowIndex.removeValue(forKey: lineID)
            return
        }
        let upper = startOffset &+ cellCount
        let intersects = lines[recordIndex].overlaps(startOffset..<upper)
        if intersects {
            let wasEmpty = rowIndex.isEmpty
            rowIndex[lineID] = HyperlinkRowAnchor(
                headLineID: headLineID,
                startOffset: startOffset
            )
            lines[recordIndex].lastAnchoredLineID = max(
                lines[recordIndex].lastAnchoredLineID,
                lineID
            )
            rowIndexCleanupFloor = wasEmpty ? lineID : min(rowIndexCleanupFloor, lineID)
            newestAnchoredLineID = max(newestAnchoredLineID ?? 0, lineID)
        } else if rowIndex[lineID]?.headLineID == headLineID {
            rowIndex.removeValue(forKey: lineID)
            if lines[recordIndex].lastAnchoredLineID == lineID {
                var candidate = lineID
                var previous: UInt64 = 0
                while candidate > headLineID {
                    candidate -= 1
                    if rowIndex[candidate]?.headLineID == headLineID {
                        previous = candidate
                        break
                    }
                }
                lines[recordIndex].lastAnchoredLineID = previous
            }
            if newestAnchoredLineID == lineID { newestAnchoredLineID = rowIndex.keys.max() }
        }
    }

    mutating func removeAllRowAnchors() {
        rowIndex.removeAll(keepingCapacity: true)
        newestAnchoredLineID = nil
        rowIndexCleanupFloor = 0
    }

    mutating func remapHeads(
        _ mapping: [UInt64: (
            headLineID: UInt64,
            cellCount: UInt32,
            removedGaps: ContiguousArray<HyperlinkRemovedGap>
        )]
    ) -> HyperlinkReferenceDelta {
        var delta = HyperlinkReferenceDelta()
        var remapped = ContiguousArray<HyperlinkLineRecord>()
        remapped.reserveCapacity(lines.count)
        for var line in lines[lineStart...] {
            for span in line.spans { delta.remove(span.targetID) }
            guard let destination = mapping[line.headLineID] else { continue }
            var spans = ContiguousArray<HyperlinkSpan>()
            for span in line.spans {
                let lower = min(
                    Self.compactedOffset(span.offsets.lowerBound, removing: destination.removedGaps),
                    destination.cellCount
                )
                let upper = min(
                    Self.compactedOffset(span.offsets.upperBound, removing: destination.removedGaps),
                    destination.cellCount
                )
                guard lower < upper else { continue }
                spans.append(HyperlinkSpan(
                    offsets: lower..<upper,
                    targetID: span.targetID
                ))
            }
            spans = Self.coalesced(spans)
            guard !spans.isEmpty else { continue }
            for span in spans { delta.add(span.targetID) }
            line.headLineID = destination.headLineID
            line.spans = spans
            line.lastAnchoredLineID = 0
            remapped.append(line)
        }
        lines = ContiguousArray(remapped.sorted { $0.headLineID < $1.headLineID })
        lineStart = 0
        spanCount = lines.reduce(into: 0) { $0 += $1.spans.count }
        rowIndex.removeAll(keepingCapacity: true)
        newestAnchoredLineID = nil
        rowIndexCleanupFloor = 0
        return delta
    }

    mutating func prune(
        before oldestLineID: UInt64,
        rebase: (UInt64) -> (headLineID: UInt64, removedPrefix: UInt32)?
    ) -> HyperlinkReferenceDelta {
        var delta = HyperlinkReferenceDelta()
        var nextLines = ContiguousArray<HyperlinkLineRecord>()
        var rebased: [UInt64: (headLineID: UInt64, removedPrefix: UInt32)] = [:]

        for record in lines[lineStart...] {
            guard record.headLineID < oldestLineID else {
                nextLines.append(record)
                continue
            }
            for span in record.spans { delta.remove(span.targetID) }
            guard let destination = rebase(record.headLineID) else { continue }
            var spans = ContiguousArray<HyperlinkSpan>()
            for span in record.spans where span.offsets.upperBound > destination.removedPrefix {
                let lower = max(span.offsets.lowerBound, destination.removedPrefix)
                spans.append(HyperlinkSpan(
                    offsets: (lower - destination.removedPrefix)..<(span.offsets.upperBound - destination.removedPrefix),
                    targetID: span.targetID
                ))
            }
            spans = Self.coalesced(spans)
            guard !spans.isEmpty else { continue }
            for span in spans { delta.add(span.targetID) }
            nextLines.append(HyperlinkLineRecord(
                headLineID: destination.headLineID,
                spans: spans
            ))
            rebased[record.headLineID] = destination
        }

        var nextRowIndex: [UInt64: HyperlinkRowAnchor] = [:]
        nextRowIndex.reserveCapacity(rowIndex.count)
        for (lineID, anchor) in rowIndex where lineID >= oldestLineID {
            if let destination = rebased[anchor.headLineID],
               anchor.startOffset >= destination.removedPrefix {
                nextRowIndex[lineID] = HyperlinkRowAnchor(
                    headLineID: destination.headLineID,
                    startOffset: anchor.startOffset - destination.removedPrefix
                )
            } else if anchor.headLineID >= oldestLineID {
                nextRowIndex[lineID] = anchor
            }
        }
        lines = ContiguousArray(nextLines.sorted { $0.headLineID < $1.headLineID })
        lineStart = 0
        spanCount = lines.reduce(into: 0) { $0 += $1.spans.count }
        rowIndex = nextRowIndex
        var lastAnchoredByHead: [UInt64: UInt64] = [:]
        lastAnchoredByHead.reserveCapacity(nextRowIndex.count)
        for (lineID, anchor) in nextRowIndex {
            lastAnchoredByHead[anchor.headLineID] = max(
                lastAnchoredByHead[anchor.headLineID] ?? 0,
                lineID
            )
        }
        for index in lines.indices {
            lines[index].lastAnchoredLineID = lastAnchoredByHead[lines[index].headLineID] ?? 0
        }
        newestAnchoredLineID = rowIndex.keys.max()
        rowIndexCleanupFloor = oldestLineID
        return delta
    }

    private func lineIndex(for headLineID: UInt64) -> Int? {
        var lower = lineStart
        var upper = lines.endIndex
        while lower < upper {
            let middle = lower + (upper - lower) / 2
            if lines[middle].headLineID < headLineID {
                lower = middle + 1
            } else {
                upper = middle
            }
        }
        return lower
    }

    private mutating func transform(
        headLineID: UInt64,
        _ body: (HyperlinkSpan) -> ContiguousArray<HyperlinkSpan>
    ) -> HyperlinkReferenceDelta {
        guard let index = lineIndex(for: headLineID),
              index < lines.endIndex,
              lines[index].headLineID == headLineID
        else { return HyperlinkReferenceDelta() }

        let oldSpans = lines[index].spans
        var next = ContiguousArray<HyperlinkSpan>()
        for span in oldSpans { next.append(contentsOf: body(span)) }
        next.sort { $0.offsets.lowerBound < $1.offsets.lowerBound }
        next = Self.coalesced(next)

        let nextSpanCount = spanCount - oldSpans.count + next.count

        var delta = HyperlinkReferenceDelta()
        for span in oldSpans { delta.remove(span.targetID) }
        guard nextSpanCount <= maxSpans else {
            removeRowAnchors(headLineID: headLineID)
            removeLine(at: index)
            spanCount -= oldSpans.count
            return delta
        }
        for span in next { delta.add(span.targetID) }
        if next.isEmpty {
            removeLine(at: index)
        } else {
            lines[index].spans = next
        }
        spanCount = nextSpanCount
        return delta
    }

    /// 每条记录的最后 anchor 可直接判断它是否仍跨越淘汰边界。物理索引按稳定
    /// 行号单调删除，每个历史行只做一次字典移除，密集与稀疏输出都是摊销 O(1)。
    mutating func discardUncontinuedPrefix(
        before oldestLineID: UInt64
    ) -> HyperlinkReferenceDelta {
        var delta = HyperlinkReferenceDelta()
        while lineStart < lines.count {
            let record = lines[lineStart]
            guard record.headLineID < oldestLineID,
                  record.lastAnchoredLineID < oldestLineID
            else { break }
            for span in record.spans { delta.remove(span.targetID) }
            spanCount -= record.spans.count
            lineStart += 1
        }

        if oldestLineID >= rowIndexCleanupFloor {
            while rowIndexCleanupFloor < oldestLineID {
                rowIndex.removeValue(forKey: rowIndexCleanupFloor)
                rowIndexCleanupFloor += 1
            }
        }

        if isEmpty {
            rowIndex.removeAll(keepingCapacity: true)
            newestAnchoredLineID = nil
            rowIndexCleanupFloor = oldestLineID
        }
        compactLinesIfNeeded()
        return delta
    }

    func continuationRebaseDistance(before oldestLineID: UInt64) -> UInt64? {
        guard lineStart < lines.count else { return nil }
        let record = lines[lineStart]
        guard record.headLineID < oldestLineID,
              record.lastAnchoredLineID >= oldestLineID
        else { return nil }
        return oldestLineID - record.headLineID
    }

    private mutating func removeLine(at index: Int) {
        if index == lineStart {
            lineStart += 1
            compactLinesIfNeeded()
        } else {
            lines.remove(at: index)
        }
    }

    private mutating func removeRowAnchors(headLineID: UInt64) {
        rowIndex = rowIndex.filter { $0.value.headLineID != headLineID }
        newestAnchoredLineID = rowIndex.keys.max()
    }

    private mutating func compactLinesIfNeeded() {
        guard lineStart > 0 else { return }
        if lineStart == lines.count {
            lines.removeAll(keepingCapacity: true)
            lineStart = 0
        } else if lineStart >= 256, lineStart * 2 >= lines.count {
            lines.removeFirst(lineStart)
            lineStart = 0
        }
    }

    private static func appendIntersection(
        of span: HyperlinkSpan,
        with range: Range<UInt32>,
        shiftedBy shift: Int64,
        to pieces: inout ContiguousArray<HyperlinkSpan>
    ) {
        let lower = max(span.offsets.lowerBound, range.lowerBound)
        let upper = min(span.offsets.upperBound, range.upperBound)
        guard lower < upper else { return }
        pieces.append(HyperlinkSpan(
            offsets: UInt32(Int64(lower) + shift)..<UInt32(Int64(upper) + shift),
            targetID: span.targetID
        ))
    }

    private static func compactedOffset(
        _ offset: UInt32,
        removing gaps: ContiguousArray<HyperlinkRemovedGap>
    ) -> UInt32 {
        var lower = 0
        var upper = gaps.count
        while lower < upper {
            let middle = lower + (upper - lower) / 2
            if gaps[middle].offsets.lowerBound < offset {
                lower = middle + 1
            } else {
                upper = middle
            }
        }
        guard lower > 0 else { return offset }
        let gap = gaps[lower - 1]
        if offset < gap.offsets.upperBound {
            return gap.offsets.lowerBound - gap.removedBefore
        }
        return offset - gap.removedBefore - UInt32(clamping: gap.offsets.count)
    }

    private static func coalesced(
        _ spans: ContiguousArray<HyperlinkSpan>
    ) -> ContiguousArray<HyperlinkSpan> {
        var result = ContiguousArray<HyperlinkSpan>()
        result.reserveCapacity(spans.count)
        for span in spans {
            if let last = result.last,
               last.targetID == span.targetID,
               last.offsets.upperBound >= span.offsets.lowerBound {
                result[result.count - 1].offsets = last.offsets.lowerBound..<max(
                    last.offsets.upperBound, span.offsets.upperBound
                )
            } else {
                result.append(span)
            }
        }
        return result
    }
}

struct HyperlinkTargetTable: Sendable {
    /// URI 本体的总预算；范围仍受 scrollback 容量约束，防止大量唯一长 URI 放大内存。
    static let maxStoredURIBytes = 8 * 1_024 * 1_024
    static let maxTargetCount = 65_536

    struct Entry: Sendable {
        var uri: String
        var references: Int
    }

    private var entries: ContiguousArray<Entry?> = []
    private var freeIDs: ContiguousArray<UInt32> = []
    private var idsByURI: [String: UInt32] = [:]
    private(set) var storedURIBytes = 0
    private let storedURIByteLimit: Int
    private let targetCountLimit: Int

    init(
        maxStoredURIBytes: Int = Self.maxStoredURIBytes,
        maxTargetCount: Int = Self.maxTargetCount
    ) {
        precondition(maxStoredURIBytes > 0 && maxTargetCount > 0, "超链接目标预算必须为正")
        storedURIByteLimit = maxStoredURIBytes
        targetCountLimit = maxTargetCount
    }

    var isEmpty: Bool { idsByURI.isEmpty }

    mutating func retain(uri: String) -> UInt32? {
        if let id = idsByURI[uri] {
            retain(id: id, count: 1)
            return id
        }
        let byteCount = uri.utf8.count
        guard idsByURI.count < targetCountLimit,
              byteCount <= storedURIByteLimit,
              storedURIBytes <= storedURIByteLimit - byteCount
        else { return nil }
        let id: UInt32
        if let recycled = freeIDs.popLast() {
            id = recycled
            entries[Int(id)] = Entry(uri: uri, references: 1)
        } else {
            id = UInt32(entries.count)
            entries.append(Entry(uri: uri, references: 1))
        }
        idsByURI[uri] = id
        storedURIBytes += byteCount
        return id
    }

    mutating func retain(id: UInt32, count: Int) {
        guard count > 0, entries.indices.contains(Int(id)), entries[Int(id)] != nil else { return }
        entries[Int(id)]!.references += count
    }

    mutating func release(id: UInt32, count: Int) {
        guard count > 0, entries.indices.contains(Int(id)), var entry = entries[Int(id)] else { return }
        entry.references -= count
        precondition(entry.references >= 0, "超链接目标引用计数不能为负")
        if entry.references == 0 {
            idsByURI.removeValue(forKey: entry.uri)
            storedURIBytes -= entry.uri.utf8.count
            entries[Int(id)] = nil
            freeIDs.append(id)
        } else {
            entries[Int(id)] = entry
        }
    }

    func uri(for id: UInt32) -> String? {
        guard entries.indices.contains(Int(id)) else { return nil }
        return entries[Int(id)]?.uri
    }
}
