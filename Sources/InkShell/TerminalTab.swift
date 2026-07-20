import Foundation

@MainActor
final class TerminalPane {
    let id: PaneID
    let session: TerminalSession

    init(id: PaneID = PaneID(), session: TerminalSession) {
        self.id = id
        self.session = session
    }
}

/// 一个标签的运行态：递归布局、PTY pane 集合和当前焦点。
@MainActor
final class TerminalTab {
    private(set) var layout: PaneLayout
    private(set) var panes: [PaneID: TerminalPane]
    private(set) var activePaneID: PaneID
    var customName: String?

    init(initialPane: TerminalPane) {
        layout = .leaf(initialPane.id)
        panes = [initialPane.id: initialPane]
        activePaneID = initialPane.id
    }

    var paneCount: Int { panes.count }

    var activePane: TerminalPane? { panes[activePaneID] }

    var allPanes: [TerminalPane] { Array(panes.values) }

    @discardableResult
    func activate(_ paneID: PaneID) -> Bool {
        guard panes[paneID] != nil else { return false }
        activePaneID = paneID
        return true
    }

    @discardableResult
    func insertPane(
        _ pane: TerminalPane,
        splitting target: PaneID,
        direction: PaneSplitDirection
    ) -> Bool {
        guard panes[pane.id] == nil,
              layout.split(target: target, newPane: pane.id, direction: direction) else {
            return false
        }
        panes[pane.id] = pane
        activePaneID = pane.id
        return true
    }

    /// 最后一个 pane 由标签级关闭处理，这里不制造空标签。
    @discardableResult
    func removePane(_ paneID: PaneID) -> TerminalPane? {
        guard panes.count > 1,
              let pane = panes[paneID],
              let removal = layout.removing(paneID),
              let remainingLayout = removal.layout else { return nil }

        layout = remainingLayout
        panes.removeValue(forKey: paneID)
        if activePaneID == paneID,
           let focusPaneID = removal.focusPaneID,
           panes[focusPaneID] != nil {
            activePaneID = focusPaneID
        }
        return pane
    }

    @discardableResult
    func updateSplitWeights(_ splitID: SplitID, weights: [Double]) -> Bool {
        layout.updateWeights(for: splitID, to: weights)
    }
}
