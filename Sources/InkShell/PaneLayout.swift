import Foundation

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
