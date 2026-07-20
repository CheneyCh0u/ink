import Dispatch
import InkTerminalView
import TerminalCore

/// 一个 pane 搜索浮层的瞬态状态；关闭后立即释放索引和匹配数组。
@MainActor
final class TerminalSearchController {
    let searchBar = TerminalSearchBarView()
    var onClose: (() -> Void)?

    private let terminalProvider: () -> Terminal
    private weak var terminalView: TerminalMetalView?
    private var index = TerminalSearchIndex()
    private var query = ""
    private var refreshScheduled = false
    private(set) var currentIndex: Int?

    var matches: [TerminalSearchMatch] { index.matches }
    var currentMatch: TerminalSearchMatch? {
        guard let currentIndex, matches.indices.contains(currentIndex) else { return nil }
        return matches[currentIndex]
    }

    init(
        terminalProvider: @escaping () -> Terminal,
        terminalView: TerminalMetalView
    ) {
        self.terminalProvider = terminalProvider
        self.terminalView = terminalView
        searchBar.onQueryChange = { [weak self] in self?.updateQuery($0) }
        searchBar.onNext = { [weak self] in self?.selectNext() }
        searchBar.onPrevious = { [weak self] in self?.selectPrevious() }
        searchBar.onClose = { [weak self] in self?.onClose?() }
    }

    func updateQuery(_ newQuery: String) {
        query = newQuery
        let terminal = terminalProvider()
        _ = index.update(in: terminal, query: newQuery)
        currentIndex = nearestMatchIndex(to: terminalView?.searchViewportLineRange(in: terminal))
        publish(reveal: true)
    }

    func refreshForTerminalUpdate() {
        guard !query.isEmpty else { return }
        let previousMatch = currentMatch
        let previousIndex = currentIndex
        let terminal = terminalProvider()
        _ = index.update(in: terminal, query: query)

        if let previousMatch, let preserved = matches.firstIndex(of: previousMatch) {
            currentIndex = preserved
        } else if let previousIndex, !matches.isEmpty {
            currentIndex = min(previousIndex, matches.count - 1)
        } else {
            currentIndex = nearestMatchIndex(to: terminalView?.searchViewportLineRange(in: terminal))
        }
        publish(reveal: false)
    }

    /// PTY 可能在一轮主循环内连续送来多个 chunk，只安排一次索引更新。
    func scheduleRefreshForTerminalUpdate() {
        guard !query.isEmpty, !refreshScheduled else { return }
        refreshScheduled = true
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.refreshScheduled = false
            self.refreshForTerminalUpdate()
        }
    }

    func selectNext() {
        guard !matches.isEmpty else { return }
        currentIndex = ((currentIndex ?? -1) + 1) % matches.count
        publish(reveal: true)
    }

    func selectPrevious() {
        guard !matches.isEmpty else { return }
        currentIndex = ((currentIndex ?? 0) - 1 + matches.count) % matches.count
        publish(reveal: true)
    }

    func close() {
        query = ""
        refreshScheduled = false
        index.clear()
        currentIndex = nil
        terminalView?.clearSearchResults()
        searchBar.onQueryChange = nil
        searchBar.onNext = nil
        searchBar.onPrevious = nil
        searchBar.onClose = nil
    }

    private func publish(reveal: Bool) {
        searchBar.updateResultPosition(currentIndex: currentIndex, total: matches.count)
        terminalView?.setSearchResults(matches, currentIndex: currentIndex)
        if reveal, let currentMatch {
            terminalView?.revealSearchResult(currentMatch)
        }
    }

    private func nearestMatchIndex(to viewport: ClosedRange<Int>?) -> Int? {
        guard !matches.isEmpty else { return nil }
        guard let viewport else { return matches.indices.last }
        return matches.indices.min { lhs, rhs in
            score(matches[lhs], viewport: viewport) < score(matches[rhs], viewport: viewport)
        }
    }

    private func score(_ match: TerminalSearchMatch, viewport: ClosedRange<Int>) -> (Int, Int) {
        let range = match.range.normalized
        let distance: Int
        if range.end.line < viewport.lowerBound {
            distance = viewport.lowerBound - range.end.line
        } else if range.start.line > viewport.upperBound {
            distance = range.start.line - viewport.upperBound
        } else {
            distance = 0
        }
        // 距离相同取更新的结果。
        return (distance, -range.start.line)
    }
}
