import Dispatch
import InkTerminalView
import TerminalCore

private struct FrozenSearchSelection {
    let range: SelectionRange
    let coordinateSpace: TerminalSearchCoordinateSpace
}

/// 一个 pane 搜索浮层的瞬态状态；关闭后立即释放索引和匹配数组。
@MainActor
final class TerminalSearchController {
    let searchBar = TerminalSearchBarView()
    var onClose: (() -> Void)?

    private let terminalProvider: () -> Terminal
    private let selectionProvider: (Terminal) -> SelectionRange?
    private weak var terminalView: TerminalMetalView?
    private var index = TerminalSearchIndex()
    private var query = ""
    private var refreshScheduled = false
    private var refreshRequestedWhileSearching = false
    private var updateGeneration: UInt64 = 0
    private var updateTask: Task<Void, Never>?
    private(set) var currentIndex: Int?
    private(set) var caseSensitive = false
    private(set) var selectionOnly = false
    private var frozenSelection: FrozenSearchSelection?
    private var resultCoordinateSpace: TerminalSearchCoordinateSpace?

    var matches: [TerminalSearchMatch] { index.matches }
    var currentMatch: TerminalSearchMatch? {
        guard let currentIndex, matches.indices.contains(currentIndex) else { return nil }
        return matches[currentIndex]
    }

    init(
        terminalProvider: @escaping () -> Terminal,
        terminalView: TerminalMetalView,
        selectionProvider: ((Terminal) -> SelectionRange?)? = nil
    ) {
        self.terminalProvider = terminalProvider
        self.terminalView = terminalView
        self.selectionProvider = selectionProvider ?? { [weak terminalView] terminal in
            terminalView?.searchSelection(in: terminal)
        }
        terminalView.searchResultsProvider = { [weak self] in
            guard let self else { return ([], nil) }
            return (self.matches, self.currentIndex)
        }
        searchBar.onQueryChange = { [weak self] in self?.updateQuery($0) }
        searchBar.onCaseSensitivityChange = { [weak self] in self?.setCaseSensitive($0) }
        searchBar.onSelectionScopeChange = { [weak self] in self?.setSelectionOnly($0) }
        searchBar.onCopyMatchCommandOutput = { [weak self] in
            _ = self?.copyCurrentMatchCommandOutput()
        }
        searchBar.onNext = { [weak self] in self?.selectNext() }
        searchBar.onPrevious = { [weak self] in self?.selectPrevious() }
        searchBar.onClose = { [weak self] in self?.onClose?() }
        publish(reveal: false, terminal: terminalProvider())
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

    func setSelectionOnly(_ enabled: Bool) {
        guard selectionOnly != enabled else { return }
        let terminal = terminalProvider()
        if enabled {
            guard let selection = availableSelection(in: terminal) else {
                publish(reveal: false, terminal: terminal)
                return
            }
            frozenSelection = FrozenSearchSelection(
                range: selection,
                coordinateSpace: TerminalSearchCoordinateSpace(in: terminal)
            )
            selectionOnly = true
        } else {
            invalidateSelectionScope()
        }
        restartSearch(chooseNearest: true, terminal: terminal)
    }

    @discardableResult
    func copyCurrentMatchCommandOutput() -> Bool {
        let terminal = terminalProvider()
        guard let range = currentMatchRange(in: terminal) else { return false }
        return terminalView?.copyCommandOutput(containing: range, in: terminal) ?? false
    }

    private func restartSearch(chooseNearest: Bool, terminal providedTerminal: Terminal? = nil) {
        updateGeneration &+= 1
        updateTask?.cancel()
        updateTask = nil
        refreshRequestedWhileSearching = false

        let liveTerminal = providedTerminal ?? terminalProvider()
        guard !query.isEmpty else {
            index.clear()
            currentIndex = nil
            resultCoordinateSpace = nil
            publish(reveal: false, terminal: liveTerminal)
            return
        }

        var options = resolvedOptions(in: liveTerminal)
        if options == nil {
            invalidateSelectionScope()
            options = resolvedOptions(in: liveTerminal)
        }
        guard let options else { return }
        let terminal = liveTerminal.snapshotForSearch()
        index.clear()
        currentIndex = nil
        resultCoordinateSpace = nil
        publish(reveal: false, terminal: liveTerminal)
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
        let liveTerminal = terminalProvider()
        if selectionOnly, resolvedOptions(in: liveTerminal) == nil {
            invalidateSelectionScope()
            restartSearch(chooseNearest: true, terminal: liveTerminal)
            return
        }
        guard !query.isEmpty else {
            publish(reveal: false, terminal: liveTerminal)
            return
        }
        guard updateTask == nil else {
            refreshRequestedWhileSearching = true
            return
        }
        guard let options = resolvedOptions(in: liveTerminal) else { return }
        let terminal = liveTerminal.snapshotForSearch()
        if !index.requiresBackgroundUpdate(in: terminal, query: query, options: options) {
            let previousMatch = currentMatch
            let previousIndex = currentIndex
            _ = index.update(in: terminal, query: query, options: options)
            resultCoordinateSpace = TerminalSearchCoordinateSpace(in: terminal)
            preserveCurrentSelection(
                previousMatch: previousMatch,
                previousIndex: previousIndex,
                terminal: terminal
            )
            publish(reveal: false, terminal: liveTerminal)
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
        guard (!query.isEmpty || selectionOnly), !refreshScheduled else { return }
        refreshScheduled = true
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.refreshScheduled = false
            self.refreshForTerminalUpdate()
        }
    }

    /// scrollback 基址整体归零后，旧 snapshot 的坐标不再可增量复用。
    /// 保留查询与搜索栏，但推进代次、取消旧扫描并从清理后的快照重建索引。
    func terminalHistoryDidClear() {
        let terminal = terminalProvider()
        updateGeneration &+= 1
        updateTask?.cancel()
        updateTask = nil
        refreshScheduled = false
        refreshRequestedWhileSearching = false
        index.clear()
        currentIndex = nil
        resultCoordinateSpace = nil
        if selectionOnly { invalidateSelectionScope() }
        publish(reveal: false, terminal: terminal)
        guard !query.isEmpty,
              let options = resolvedOptions(in: terminal) else { return }
        startBackgroundUpdate(
            terminal: terminal.snapshotForSearch(),
            startingIndex: TerminalSearchIndex(),
            query: query,
            options: options,
            chooseNearest: true,
            reveal: true,
            debounce: false
        )
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
        resultCoordinateSpace = nil
        terminalView?.searchResultsProvider = nil
        terminalView?.clearSearchResults()
        searchBar.onQueryChange = nil
        searchBar.onCaseSensitivityChange = nil
        searchBar.onSelectionScopeChange = nil
        searchBar.onCopyMatchCommandOutput = nil
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
        resultCoordinateSpace = TerminalSearchCoordinateSpace(in: terminal)

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

    private func publish(reveal: Bool, terminal providedTerminal: Terminal? = nil) {
        let terminal = providedTerminal ?? terminalProvider()
        searchBar.updateResultPosition(currentIndex: currentIndex, total: matches.count)
        searchBar.updateSearchModes(
            caseSensitive: caseSensitive,
            selectionOnly: selectionOnly,
            selectionAvailable: availableSelection(in: terminal) != nil,
            copyOutputAvailable: currentMatchRange(in: terminal).map {
                terminalView?.canCopyCommandOutput(containing: $0, in: terminal) == true
            } ?? false
        )
        terminalView?.markDirty()
        if reveal, let currentMatch {
            terminalView?.revealSearchResult(currentMatch)
        }
    }

    private func resolvedOptions(in terminal: Terminal) -> TerminalSearchOptions? {
        var selection: SelectionRange?
        if selectionOnly {
            guard let frozenSelection,
                  let resolved = frozenSelection.coordinateSpace.resolve(
                      frozenSelection.range,
                      in: terminal
                  ) else { return nil }
            selection = resolved
        }
        return TerminalSearchOptions(
            caseSensitive: caseSensitive,
            selection: selection
        )
    }

    private func currentMatchRange(in terminal: Terminal) -> SelectionRange? {
        guard let currentMatch, let resultCoordinateSpace else { return nil }
        return resultCoordinateSpace.resolve(currentMatch.range, in: terminal)
    }

    private func availableSelection(in terminal: Terminal) -> SelectionRange? {
        guard let selection = selectionProvider(terminal),
              !terminal.extractText(in: selection).isEmpty else { return nil }
        return selection
    }

    private func invalidateSelectionScope() {
        selectionOnly = false
        frozenSelection = nil
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
