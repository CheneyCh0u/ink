import Foundation
import TerminalCore

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
    private(set) var attention: TabAttention?

    init(initialPane: TerminalPane) {
        layout = .leaf(initialPane.id)
        panes = [initialPane.id: initialPane]
        activePaneID = initialPane.id
    }

    /// 快照恢复必须一次性提供完整布局，不能把半棵树带进运行态。
    init?(
        restoredLayout: PaneLayout,
        panes: [PaneID: TerminalPane],
        activePaneID: PaneID,
        customName: String?
    ) {
        let paneIDs = restoredLayout.paneIDs
        guard !paneIDs.isEmpty,
              Set(paneIDs).count == paneIDs.count,
              Set(paneIDs) == Set(panes.keys),
              panes[activePaneID] != nil else { return nil }
        layout = restoredLayout
        self.panes = panes
        self.activePaneID = activePaneID
        self.customName = customName
    }

    var paneCount: Int { panes.count }

    var activePane: TerminalPane? { panes[activePaneID] }

    var allPanes: [TerminalPane] { Array(panes.values) }

    func receive(_ event: TerminalEvent, markUnread: Bool) {
        guard markUnread else { return }
        let incoming = TabAttention(event: event)
        attention = attention?.merging(incoming) ?? incoming
    }

    func clearAttention() {
        attention = nil
    }

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
