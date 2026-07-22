struct HyperlinkSpan: Sendable, Equatable {
    var offsets: Range<UInt32>
    var targetID: UInt32
}

struct HyperlinkLineRecord: Sendable, Equatable {
    var headLineID: UInt64
    var spans: ContiguousArray<HyperlinkSpan>
}

struct HyperlinkRowAnchor: Sendable, Equatable {
    var headLineID: UInt64
    var startOffset: UInt32
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
    private(set) var lines: ContiguousArray<HyperlinkLineRecord> = []
    private(set) var rowIndex: [UInt64: HyperlinkRowAnchor] = [:]
    private var newestAnchoredLineID: UInt64?

    var isEmpty: Bool { lines.isEmpty }

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
        for line in lines {
            for span in line.spans { delta.remove(span.targetID) }
        }
        return delta
    }

    @inline(__always)
    func needsPrune(before oldestLineID: UInt64) -> Bool {
        guard let first = lines.first else { return false }
        return first.headLineID < oldestLineID
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

        let oldSpans = hasRecord
            ? lines[insertionIndex].spans
            : ContiguousArray<HyperlinkSpan>()
        if let targetID,
           hasRecord,
           let last = oldSpans.last,
           last.targetID == targetID,
           last.offsets.upperBound == offsets.lowerBound {
            lines[insertionIndex].spans[oldSpans.count - 1].offsets =
                last.offsets.lowerBound..<offsets.upperBound
            return HyperlinkReferenceDelta()
        }
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

        var delta = HyperlinkReferenceDelta()
        for span in oldSpans { delta.remove(span.targetID) }
        for span in next { delta.add(span.targetID) }

        if next.isEmpty {
            if hasRecord { lines.remove(at: insertionIndex) }
        } else if hasRecord {
            lines[insertionIndex].spans = next
        } else {
            lines.insert(
                HyperlinkLineRecord(headLineID: headLineID, spans: next),
                at: insertionIndex
            )
        }
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
        let record = record(headLineID: line.headLineID)
        for segment in line.segments {
            let lower = UInt32(clamping: segment.startOffset)
            let upper = UInt32(clamping: segment.startOffset + segment.cellCount)
            let intersects = record?.spans.contains(where: {
                $0.offsets.overlaps(lower..<upper)
            }) ?? false
            if intersects {
                rowIndex[segment.lineID] = HyperlinkRowAnchor(
                    headLineID: line.headLineID,
                    startOffset: lower
                )
                newestAnchoredLineID = max(newestAnchoredLineID ?? 0, segment.lineID)
            } else if rowIndex[segment.lineID]?.headLineID == line.headLineID {
                rowIndex.removeValue(forKey: segment.lineID)
                if newestAnchoredLineID == segment.lineID {
                    newestAnchoredLineID = rowIndex.keys.max()
                }
            }
        }
    }

    mutating func removeAllRowAnchors() {
        rowIndex.removeAll(keepingCapacity: true)
        newestAnchoredLineID = nil
    }

    mutating func remapHeads(_ mapping: [UInt64: UInt64]) {
        guard !mapping.isEmpty else { return }
        for index in lines.indices {
            if let head = mapping[lines[index].headLineID] {
                lines[index].headLineID = head
            }
        }
        lines.sort { $0.headLineID < $1.headLineID }
        rowIndex.removeAll(keepingCapacity: true)
        newestAnchoredLineID = nil
    }

    mutating func prune(
        before oldestLineID: UInt64,
        rebase: (UInt64) -> (headLineID: UInt64, removedPrefix: UInt32)?
    ) -> HyperlinkReferenceDelta {
        var delta = HyperlinkReferenceDelta()
        var nextLines = ContiguousArray<HyperlinkLineRecord>()
        var rebased: [UInt64: (headLineID: UInt64, removedPrefix: UInt32)] = [:]

        for record in lines {
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
        rowIndex = nextRowIndex
        newestAnchoredLineID = rowIndex.keys.max()
        return delta
    }

    private func lineIndex(for headLineID: UInt64) -> Int? {
        var lower = lines.startIndex
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

        var delta = HyperlinkReferenceDelta()
        for span in oldSpans { delta.remove(span.targetID) }
        for span in next { delta.add(span.targetID) }
        if next.isEmpty {
            lines.remove(at: index)
        } else {
            lines[index].spans = next
        }
        return delta
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
    struct Entry: Sendable {
        var uri: String
        var references: Int
    }

    private var entries: ContiguousArray<Entry?> = []
    private var freeIDs: ContiguousArray<UInt32> = []
    private var idsByURI: [String: UInt32] = [:]

    var isEmpty: Bool { idsByURI.isEmpty }

    mutating func retain(uri: String) -> UInt32 {
        if let id = idsByURI[uri] {
            retain(id: id, count: 1)
            return id
        }
        let id: UInt32
        if let recycled = freeIDs.popLast() {
            id = recycled
            entries[Int(id)] = Entry(uri: uri, references: 1)
        } else {
            id = UInt32(entries.count)
            entries.append(Entry(uri: uri, references: 1))
        }
        idsByURI[uri] = id
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
