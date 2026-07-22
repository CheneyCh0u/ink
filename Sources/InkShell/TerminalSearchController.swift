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
    private(set) var caseSensitive = false

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
        searchBar.onCaseSensitivityChange = { [weak self] in self?.setCaseSensitive($0) }
        searchBar.onNext = { [weak self] in self?.selectNext() }
        searchBar.onPrevious = { [weak self] in self?.selectPrevious() }
        searchBar.onClose = { [weak self] in self?.onClose?() }
    }

    func updateQuery(_ newQuery: String) {
        query = newQuery
        restartSearch(chooseNearest: true)
    }

    func setCaseSensitive(_ enabled: Bool) {
        guard caseSensitive != enabled else { return }
        caseSensitive = enabled
        restartSearch(chooseNearest: true)
    }

    private func restartSearch(chooseNearest: Bool) {
        updateGeneration &+= 1
        updateTask?.cancel()
        updateTask = nil
        refreshRequestedWhileSearching = false

        guard !query.isEmpty else {
            index.clear()
            currentIndex = nil
            publish(reveal: false)
            return
        }

        let terminal = terminalProvider().snapshotForSearch()
        let options = TerminalSearchOptions(caseSensitive: caseSensitive)
        index.clear()
        currentIndex = nil
        publish(reveal: false)
        startBackgroundUpdate(
            terminal: terminal,
            startingIndex: TerminalSearchIndex(),
            query: query,
            options: options,
            chooseNearest: chooseNearest,
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
        let terminal = terminalProvider().snapshotForSearch()
        let options = TerminalSearchOptions(caseSensitive: caseSensitive)
        if !index.requiresBackgroundUpdate(in: terminal, query: query, options: options) {
            let previousMatch = currentMatch
            let previousIndex = currentIndex
            _ = index.update(in: terminal, query: query, options: options)
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
            options: options,
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
        searchBar.onCaseSensitivityChange = nil
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
        options: TerminalSearchOptions,
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
                nextIndex.update(in: terminal, query: query, options: options)
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
        searchBar.updateSearchModes(
            caseSensitive: caseSensitive,
            selectionOnly: false,
            selectionAvailable: false,
            copyOutputAvailable: false
        )
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
