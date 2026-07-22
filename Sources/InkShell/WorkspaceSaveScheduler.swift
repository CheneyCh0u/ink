import Foundation

/// 合并短时间内连续的工作区变化；没有周期任务，也不接触终端输出路径。
@MainActor
final class WorkspaceSaveScheduler {
    private let store: WorkspaceStore
    private let delay: TimeInterval
    private var pending: DispatchWorkItem?
    private var generation: UInt = 0

    init(store: WorkspaceStore, delay: TimeInterval = 0.25) {
        self.store = store
        self.delay = delay
    }

    func schedule(_ snapshot: WorkspaceSnapshot) {
        pending?.cancel()
        generation &+= 1
        let scheduledGeneration = generation
        let work = DispatchWorkItem { [weak self] in
            MainActor.assumeIsolated {
                guard let self,
                      self.generation == scheduledGeneration else { return }
                self.pending = nil
                _ = self.store.save(snapshot)
            }
        }
        pending = work
        DispatchQueue.main.asyncAfter(
            deadline: .now() + max(0, delay),
            execute: work
        )
    }

    func flush(_ snapshot: WorkspaceSnapshot) {
        pending?.cancel()
        pending = nil
        generation &+= 1
        _ = store.save(snapshot)
    }

    func cancel() {
        pending?.cancel()
        pending = nil
        generation &+= 1
    }

}
