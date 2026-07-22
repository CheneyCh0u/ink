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

    var isEmpty: Bool { lines.isEmpty }

    func anchor(for lineID: UInt64) -> HyperlinkRowAnchor? {
        rowIndex[lineID]
    }

    func record(headLineID: UInt64) -> HyperlinkLineRecord? {
        guard let index = lineIndex(for: headLineID),
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
            } else if rowIndex[segment.lineID]?.headLineID == line.headLineID {
                rowIndex.removeValue(forKey: segment.lineID)
            }
        }
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
