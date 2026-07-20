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

struct PaneRemoval: Equatable, Sendable {
    let layout: PaneLayout?
    let focusPaneID: PaneID?
}

/// 一个标签内的分屏结构。叶节点只保存稳定标识，PTY 与视图由外层管理。
indirect enum PaneLayout: Equatable, Sendable {
    case leaf(PaneID)
    case split(
        id: SplitID,
        axis: PaneSplitAxis,
        ratio: Double,
        first: PaneLayout,
        second: PaneLayout
    )

    var paneCount: Int {
        switch self {
        case .leaf:
            1
        case let .split(_, _, _, first, second):
            first.paneCount + second.paneCount
        }
    }

    func contains(_ paneID: PaneID) -> Bool {
        switch self {
        case let .leaf(candidate):
            candidate == paneID
        case let .split(_, _, _, first, second):
            first.contains(paneID) || second.contains(paneID)
        }
    }

    @discardableResult
    mutating func split(
        target: PaneID,
        newPane: PaneID,
        axis: PaneSplitAxis
    ) -> Bool {
        guard let replacement = replacingLeaf(target, with: newPane, axis: axis) else {
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

        case let .split(id, axis, ratio, first, second):
            if let removal = first.removing(paneID) {
                guard let newFirst = removal.layout else {
                    return PaneRemoval(layout: second, focusPaneID: second.firstPaneID)
                }
                return PaneRemoval(
                    layout: .split(
                        id: id, axis: axis, ratio: ratio,
                        first: newFirst, second: second
                    ),
                    focusPaneID: removal.focusPaneID
                )
            }
            if let removal = second.removing(paneID) {
                guard let newSecond = removal.layout else {
                    return PaneRemoval(layout: first, focusPaneID: first.lastPaneID)
                }
                return PaneRemoval(
                    layout: .split(
                        id: id, axis: axis, ratio: ratio,
                        first: first, second: newSecond
                    ),
                    focusPaneID: removal.focusPaneID
                )
            }
            return nil
        }
    }

    @discardableResult
    mutating func updateRatio(for splitID: SplitID, to ratio: Double) -> Bool {
        guard let updated = replacingRatio(for: splitID, with: min(1, max(0, ratio))) else {
            return false
        }
        self = updated
        return true
    }

    private var firstPaneID: PaneID {
        switch self {
        case let .leaf(paneID): paneID
        case let .split(_, _, _, first, _): first.firstPaneID
        }
    }

    private var lastPaneID: PaneID {
        switch self {
        case let .leaf(paneID): paneID
        case let .split(_, _, _, _, second): second.lastPaneID
        }
    }

    private func replacingLeaf(
        _ target: PaneID,
        with newPane: PaneID,
        axis: PaneSplitAxis
    ) -> PaneLayout? {
        switch self {
        case let .leaf(candidate):
            guard candidate == target else { return nil }
            return .split(
                id: SplitID(), axis: axis, ratio: 0.5,
                first: self, second: .leaf(newPane)
            )

        case let .split(id, existingAxis, ratio, first, second):
            if let replacement = first.replacingLeaf(target, with: newPane, axis: axis) {
                return .split(
                    id: id, axis: existingAxis, ratio: ratio,
                    first: replacement, second: second
                )
            }
            if let replacement = second.replacingLeaf(target, with: newPane, axis: axis) {
                return .split(
                    id: id, axis: existingAxis, ratio: ratio,
                    first: first, second: replacement
                )
            }
            return nil
        }
    }

    private func replacingRatio(for splitID: SplitID, with ratio: Double) -> PaneLayout? {
        switch self {
        case .leaf:
            return nil
        case let .split(id, axis, existingRatio, first, second):
            if id == splitID {
                return .split(id: id, axis: axis, ratio: ratio, first: first, second: second)
            }
            if let replacement = first.replacingRatio(for: splitID, with: ratio) {
                return .split(
                    id: id, axis: axis, ratio: existingRatio,
                    first: replacement, second: second
                )
            }
            if let replacement = second.replacingRatio(for: splitID, with: ratio) {
                return .split(
                    id: id, axis: axis, ratio: existingRatio,
                    first: first, second: replacement
                )
            }
            return nil
        }
    }
}
