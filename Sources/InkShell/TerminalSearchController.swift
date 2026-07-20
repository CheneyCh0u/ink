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
    private var refreshRequestedWhileSearching = false
    private var updateGeneration: UInt64 = 0
    private var updateTask: Task<Void, Never>?
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
        terminalView.searchResultsProvider = { [weak self] in
            guard let self else { return ([], nil) }
            return (self.matches, self.currentIndex)
        }
        searchBar.onQueryChange = { [weak self] in self?.updateQuery($0) }
        searchBar.onNext = { [weak self] in self?.selectNext() }
        searchBar.onPrevious = { [weak self] in self?.selectPrevious() }
        searchBar.onClose = { [weak self] in self?.onClose?() }
    }

    func updateQuery(_ newQuery: String) {
        query = newQuery
        updateGeneration &+= 1
        updateTask?.cancel()
        updateTask = nil
        refreshRequestedWhileSearching = false

        guard !newQuery.isEmpty else {
            index.clear()
            currentIndex = nil
            publish(reveal: false)
            return
        }

        let terminal = terminalProvider()
        index.clear()
        currentIndex = nil
        publish(reveal: false)
        startBackgroundUpdate(
            terminal: terminal,
            startingIndex: TerminalSearchIndex(),
            query: newQuery,
            chooseNearest: true,
            reveal: true,
            debounce: true
        )
    }

    func refreshForTerminalUpdate() {
        guard !query.isEmpty else { return }
        guard updateTask == nil else {
            refreshRequestedWhileSearching = true
            return
        }
        let terminal = terminalProvider()
        if !index.requiresBackgroundUpdate(in: terminal, query: query) {
            let previousMatch = currentMatch
            let previousIndex = currentIndex
            _ = index.update(in: terminal, query: query)
            preserveCurrentSelection(
                previousMatch: previousMatch,
                previousIndex: previousIndex,
                terminal: terminal
            )
            publish(reveal: false)
            return
        }
        startBackgroundUpdate(
            terminal: terminal,
            startingIndex: index,
            query: query,
            chooseNearest: false,
            reveal: false,
            debounce: false
        )
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
        updateGeneration &+= 1
        updateTask?.cancel()
        updateTask = nil
        refreshScheduled = false
        refreshRequestedWhileSearching = false
        index.clear()
        currentIndex = nil
        terminalView?.searchResultsProvider = nil
        terminalView?.clearSearchResults()
        searchBar.onQueryChange = nil
        searchBar.onNext = nil
        searchBar.onPrevious = nil
        searchBar.onClose = nil
    }

    func waitForPendingUpdate() async {
        while updateTask != nil {
            try? await Task.sleep(for: .milliseconds(1))
        }
    }

    private func startBackgroundUpdate(
        terminal: Terminal,
        startingIndex: TerminalSearchIndex,
        query: String,
        chooseNearest: Bool,
        reveal: Bool,
        debounce: Bool
    ) {
        updateGeneration &+= 1
        let generation = updateGeneration
        updateTask = Task { [weak self] in
            if debounce {
                try? await Task.sleep(for: .milliseconds(30))
                guard !Task.isCancelled else { return }
            }
            let scanTask = Task.detached(priority: .userInitiated) {
                var nextIndex = startingIndex
                nextIndex.update(in: terminal, query: query)
                return nextIndex
            }
            let updated = await withTaskCancellationHandler {
                await scanTask.value
            } onCancel: {
                scanTask.cancel()
            }
            guard !Task.isCancelled, let self, self.updateGeneration == generation else { return }
            self.updateTask = nil
            self.apply(
                updatedIndex: updated,
                terminal: terminal,
                chooseNearest: chooseNearest,
                reveal: reveal
            )
            if self.refreshRequestedWhileSearching {
                self.refreshRequestedWhileSearching = false
                self.scheduleRefreshForTerminalUpdate()
            }
        }
    }

    private func apply(
        updatedIndex: TerminalSearchIndex,
        terminal: Terminal,
        chooseNearest: Bool,
        reveal: Bool
    ) {
        let previousMatch = currentMatch
        let previousIndex = currentIndex
        index = updatedIndex

        if chooseNearest {
            currentIndex = nearestMatchIndex(
                to: terminalView?.searchViewportLineRange(in: terminal)
            )
        } else {
            preserveCurrentSelection(
                previousMatch: previousMatch,
                previousIndex: previousIndex,
                terminal: terminal
            )
        }
        publish(reveal: reveal)
    }

    private func preserveCurrentSelection(
        previousMatch: TerminalSearchMatch?,
        previousIndex: Int?,
        terminal: Terminal
    ) {
        if matches.isEmpty {
            currentIndex = nil
        } else if let previousMatch, index.lastEvictedLineCount > 0 {
            var shifted = previousMatch.range
            shifted.start.line -= index.lastEvictedLineCount
            shifted.end.line -= index.lastEvictedLineCount
            currentIndex = matches.firstIndex(of: TerminalSearchMatch(range: shifted))
                ?? previousIndex.map { max(0, min($0, matches.count - 1)) }
        } else if let previousMatch, let preserved = matches.firstIndex(of: previousMatch) {
            currentIndex = preserved
        } else if let previousIndex {
            currentIndex = max(0, min(previousIndex, matches.count - 1))
        } else {
            currentIndex = nearestMatchIndex(
                to: terminalView?.searchViewportLineRange(in: terminal)
            )
        }
    }

    private func publish(reveal: Bool) {
        searchBar.updateResultPosition(currentIndex: currentIndex, total: matches.count)
        terminalView?.markDirty()
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
