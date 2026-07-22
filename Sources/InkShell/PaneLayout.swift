import Foundation

private let paneNavigationEpsilon = 1e-9

struct PaneNavigationGeometry: Equatable, Sendable {
    let width: Double
    let height: Double
    let dividerThickness: Double

    static let normalized = PaneNavigationGeometry(
        width: 1,
        height: 1,
        dividerThickness: 0
    )

    var isValid: Bool {
        width.isFinite && width >= 0
            && height.isFinite && height >= 0
            && dividerThickness.isFinite && dividerThickness >= 0
    }
}

struct PaneID: Hashable, Sendable {
    let rawValue: UUID

    init(rawValue: UUID = UUID()) {
        self.rawValue = rawValue
    }
}

struct SplitID: Hashable, Sendable {
    let rawValue: UUID

    init(rawValue: UUID = UUID()) {
        self.rawValue = rawValue
    }
}

enum PaneSplitAxis: Equatable, Sendable {
    case leftRight
    case topBottom
}

enum PaneSplitDirection: Equatable, Sendable {
    case left
    case right
    case up
    case down

    var axis: PaneSplitAxis {
        switch self {
        case .left, .right: .leftRight
        case .up, .down: .topBottom
        }
    }

    var insertsBefore: Bool {
        switch self {
        case .left, .up: true
        case .right, .down: false
        }
    }
}

private struct PaneNavigationRect: Equatable, Sendable {
    let x: Double
    let y: Double
    let width: Double
    let height: Double

    var minX: Double { x }
    var maxX: Double { x + width }
    var minY: Double { y }
    var maxY: Double { y + height }
    var midX: Double { x + width / 2 }
    var midY: Double { y + height / 2 }
}

private struct PaneNavigationEntry: Sendable {
    let paneID: PaneID
    let rect: PaneNavigationRect
    let ordinal: Int
}

private struct PaneNavigationScore {
    let axialGap: Double
    let perpendicularCenterGap: Double
    let ordinal: Int

    func isBetter(than other: Self) -> Bool {
        if abs(axialGap - other.axialGap) > paneNavigationEpsilon {
            return axialGap < other.axialGap
        }
        if abs(perpendicularCenterGap - other.perpendicularCenterGap)
            > paneNavigationEpsilon {
            return perpendicularCenterGap < other.perpendicularCenterGap
        }
        return ordinal < other.ordinal
    }
}

struct PaneRemoval: Equatable, Sendable {
    let layout: PaneLayout?
    let focusPaneID: PaneID?
}

/// 一个标签内的分屏结构。同方向的相邻窗格合并到同一个多子节点分组。
indirect enum PaneLayout: Equatable, Sendable {
    case leaf(PaneID)
    case group(
        id: SplitID,
        axis: PaneSplitAxis,
        weights: [Double],
        children: [PaneLayout]
    )

    var paneCount: Int {
        switch self {
        case .leaf:
            1
        case let .group(_, _, _, children):
            children.reduce(0) { $0 + $1.paneCount }
        }
    }

    var paneIDs: [PaneID] {
        switch self {
        case let .leaf(paneID):
            [paneID]
        case let .group(_, _, _, children):
            children.flatMap(\.paneIDs)
        }
    }

    func contains(_ paneID: PaneID) -> Bool {
        switch self {
        case let .leaf(candidate):
            candidate == paneID
        case let .group(_, _, _, children):
            children.contains { $0.contains(paneID) }
        }
    }

    func neighbor(
        of paneID: PaneID,
        direction: PaneSplitDirection,
        geometry: PaneNavigationGeometry = .normalized
    ) -> PaneID? {
        guard geometry.isValid else { return nil }
        var entries: [PaneNavigationEntry] = []
        collectNavigationEntries(
            in: PaneNavigationRect(
                x: 0, y: 0,
                width: geometry.width,
                height: geometry.height
            ),
            dividerThickness: geometry.dividerThickness,
            into: &entries
        )
        guard let active = entries.first(where: { $0.paneID == paneID }) else {
            return nil
        }

        var best: (entry: PaneNavigationEntry, score: PaneNavigationScore)?
        for candidate in entries where candidate.paneID != paneID {
            guard let score = Self.navigationScore(
                from: active.rect,
                to: candidate.rect,
                candidateOrdinal: candidate.ordinal,
                direction: direction
            ) else { continue }
            if let currentBest = best {
                if score.isBetter(than: currentBest.score) {
                    best = (candidate, score)
                }
            } else {
                best = (candidate, score)
            }
        }
        return best?.entry.paneID
    }

    @discardableResult
    mutating func split(
        target: PaneID,
        newPane: PaneID,
        direction: PaneSplitDirection
    ) -> Bool {
        guard let replacement = inserting(newPane, beside: target, direction: direction) else {
            return false
        }
        self = replacement
        return true
    }

    func removing(_ paneID: PaneID) -> PaneRemoval? {
        switch self {
        case let .leaf(candidate):
            guard candidate == paneID else { return nil }
            return PaneRemoval(layout: nil, focusPaneID: nil)

        case let .group(id, axis, weights, children):
            guard weights.count == children.count else { return nil }
            for index in children.indices {
                guard let removal = children[index].removing(paneID) else { continue }

                if let replacement = removal.layout {
                    var updatedChildren = children
                    updatedChildren[index] = replacement
                    return PaneRemoval(
                        layout: Self.makeGroup(
                            id: id, axis: axis, weights: weights, children: updatedChildren
                        ),
                        focusPaneID: removal.focusPaneID
                    )
                }

                var updatedChildren = children
                var updatedWeights = weights
                updatedChildren.remove(at: index)
                updatedWeights.remove(at: index)
                guard !updatedChildren.isEmpty else {
                    return PaneRemoval(layout: nil, focusPaneID: nil)
                }
                let focusPaneID = index < updatedChildren.count
                    ? updatedChildren[index].firstPaneID
                    : updatedChildren[updatedChildren.count - 1].lastPaneID
                let layout = updatedChildren.count == 1
                    ? updatedChildren[0]
                    : Self.makeGroup(
                        id: id, axis: axis,
                        weights: updatedWeights, children: updatedChildren
                    )
                return PaneRemoval(layout: layout, focusPaneID: focusPaneID)
            }
            return nil
        }
    }

    @discardableResult
    mutating func updateWeights(for splitID: SplitID, to weights: [Double]) -> Bool {
        guard let replacement = replacingWeights(for: splitID, with: weights) else {
            return false
        }
        self = replacement
        return true
    }

    private var firstPaneID: PaneID {
        switch self {
        case let .leaf(paneID): paneID
        case let .group(_, _, _, children): children[0].firstPaneID
        }
    }

    private var lastPaneID: PaneID {
        switch self {
        case let .leaf(paneID): paneID
        case let .group(_, _, _, children): children[children.count - 1].lastPaneID
        }
    }

    private func collectNavigationEntries(
        in rect: PaneNavigationRect,
        dividerThickness: Double,
        into entries: inout [PaneNavigationEntry]
    ) {
        switch self {
        case let .leaf(paneID):
            entries.append(PaneNavigationEntry(
                paneID: paneID, rect: rect, ordinal: entries.count
            ))

        case let .group(_, axis, weights, children):
            guard !children.isEmpty else { return }
            let resolved = Self.navigationWeights(weights, childCount: children.count)
            let dividerTotal = dividerThickness * Double(max(0, children.count - 1))
            let availableLength = max(
                0,
                (axis == .leftRight ? rect.width : rect.height) - dividerTotal
            )
            var cursor = axis == .leftRight ? rect.minX : rect.minY
            for index in children.indices {
                let isLast = index == children.index(before: children.endIndex)
                let length: Double
                let childRect: PaneNavigationRect
                switch axis {
                case .leftRight:
                    length = isLast
                        ? max(0, rect.maxX - cursor)
                        : availableLength * resolved[index]
                    childRect = PaneNavigationRect(
                        x: cursor, y: rect.y, width: length, height: rect.height
                    )
                case .topBottom:
                    length = isLast
                        ? max(0, rect.maxY - cursor)
                        : availableLength * resolved[index]
                    childRect = PaneNavigationRect(
                        x: rect.x, y: cursor, width: rect.width, height: length
                    )
                }
                children[index].collectNavigationEntries(
                    in: childRect,
                    dividerThickness: dividerThickness,
                    into: &entries
                )
                cursor += length + dividerThickness
            }
        }
    }

    private static func navigationWeights(
        _ weights: [Double],
        childCount: Int
    ) -> [Double] {
        guard weights.count == childCount,
              weights.allSatisfy({ $0.isFinite && $0 > 0 }) else {
            return Array(repeating: 1 / Double(childCount), count: childCount)
        }
        let total = weights.reduce(0, +)
        guard total.isFinite, total > 0 else {
            return Array(repeating: 1 / Double(childCount), count: childCount)
        }
        return weights.map { $0 / total }
    }

    private static func navigationScore(
        from active: PaneNavigationRect,
        to candidate: PaneNavigationRect,
        candidateOrdinal: Int,
        direction: PaneSplitDirection
    ) -> PaneNavigationScore? {
        guard candidate.width > paneNavigationEpsilon,
              candidate.height > paneNavigationEpsilon else { return nil }
        let xOverlap = min(active.maxX, candidate.maxX) - max(active.minX, candidate.minX)
        let yOverlap = min(active.maxY, candidate.maxY) - max(active.minY, candidate.minY)
        let axialGap: Double
        let centerGap: Double

        switch direction {
        case .left:
            guard candidate.maxX <= active.minX + paneNavigationEpsilon,
                  yOverlap > paneNavigationEpsilon else { return nil }
            axialGap = max(0, active.minX - candidate.maxX)
            centerGap = abs(active.midY - candidate.midY)
        case .right:
            guard candidate.minX >= active.maxX - paneNavigationEpsilon,
                  yOverlap > paneNavigationEpsilon else { return nil }
            axialGap = max(0, candidate.minX - active.maxX)
            centerGap = abs(active.midY - candidate.midY)
        case .up:
            guard candidate.maxY <= active.minY + paneNavigationEpsilon,
                  xOverlap > paneNavigationEpsilon else { return nil }
            axialGap = max(0, active.minY - candidate.maxY)
            centerGap = abs(active.midX - candidate.midX)
        case .down:
            guard candidate.minY >= active.maxY - paneNavigationEpsilon,
                  xOverlap > paneNavigationEpsilon else { return nil }
            axialGap = max(0, candidate.minY - active.maxY)
            centerGap = abs(active.midX - candidate.midX)
        }
        return PaneNavigationScore(
            axialGap: axialGap,
            perpendicularCenterGap: centerGap,
            ordinal: candidateOrdinal
        )
    }

    private func inserting(
        _ newPane: PaneID,
        beside target: PaneID,
        direction: PaneSplitDirection
    ) -> PaneLayout? {
        switch self {
        case let .leaf(candidate):
            guard candidate == target else { return nil }
            let newLeaf = PaneLayout.leaf(newPane)
            let children = direction.insertsBefore ? [newLeaf, self] : [self, newLeaf]
            return .group(
                id: SplitID(), axis: direction.axis,
                weights: [0.5, 0.5], children: children
            )

        case let .group(id, axis, weights, children):
            guard weights.count == children.count else { return nil }

            if axis == direction.axis,
               let targetIndex = children.firstIndex(where: {
                   if case let .leaf(candidate) = $0 { return candidate == target }
                   return false
               }) {
                var updatedChildren = children
                var updatedWeights = weights
                let insertionIndex = direction.insertsBefore ? targetIndex : targetIndex + 1
                let sharedWeight = weights[targetIndex] / 2
                updatedWeights[targetIndex] = sharedWeight
                updatedChildren.insert(.leaf(newPane), at: insertionIndex)
                updatedWeights.insert(sharedWeight, at: insertionIndex)
                return Self.makeGroup(
                    id: id, axis: axis,
                    weights: updatedWeights, children: updatedChildren
                )
            }

            for index in children.indices {
                guard let replacement = children[index].inserting(
                    newPane, beside: target, direction: direction
                ) else { continue }
                var updatedChildren = children
                updatedChildren[index] = replacement
                return Self.makeGroup(
                    id: id, axis: axis, weights: weights, children: updatedChildren
                )
            }
            return nil
        }
    }

    private func replacingWeights(
        for splitID: SplitID,
        with weights: [Double]
    ) -> PaneLayout? {
        switch self {
        case .leaf:
            return nil

        case let .group(id, axis, existingWeights, children):
            if id == splitID {
                guard weights.count == children.count,
                      weights.allSatisfy({ $0.isFinite && $0 > 0 }),
                      weights.reduce(0, +).isFinite else { return nil }
                return .group(
                    id: id, axis: axis,
                    weights: Self.normalized(weights), children: children
                )
            }

            for index in children.indices {
                guard let replacement = children[index].replacingWeights(
                    for: splitID, with: weights
                ) else { continue }
                var updatedChildren = children
                updatedChildren[index] = replacement
                return .group(
                    id: id, axis: axis,
                    weights: existingWeights, children: updatedChildren
                )
            }
            return nil
        }
    }

    private static func makeGroup(
        id: SplitID,
        axis: PaneSplitAxis,
        weights: [Double],
        children: [PaneLayout]
    ) -> PaneLayout {
        precondition(weights.count == children.count && !children.isEmpty)
        var flattenedWeights: [Double] = []
        var flattenedChildren: [PaneLayout] = []
        for (weight, child) in zip(weights, children) {
            if case let .group(_, childAxis, childWeights, childChildren) = child,
               childAxis == axis,
               childWeights.count == childChildren.count {
                flattenedWeights.append(contentsOf: childWeights.map { weight * $0 })
                flattenedChildren.append(contentsOf: childChildren)
            } else {
                flattenedWeights.append(weight)
                flattenedChildren.append(child)
            }
        }
        guard flattenedChildren.count > 1 else { return flattenedChildren[0] }
        return .group(
            id: id, axis: axis,
            weights: normalized(flattenedWeights), children: flattenedChildren
        )
    }

    private static func normalized(_ weights: [Double]) -> [Double] {
        let total = weights.reduce(0, +)
        guard total.isFinite, total > 0 else {
            return Array(repeating: 1 / Double(weights.count), count: weights.count)
        }
        return weights.map { $0 / total }
    }
}
