import Foundation
import Testing
@testable import InkShell

@Suite("工作区保存调度", .serialized)
@MainActor
struct WorkspaceSaveSchedulerTests {
    @Test("连续变化只保存最后快照")
    func coalescesChanges() async throws {
        let fixture = try Fixture()
        defer { fixture.cleanUp() }
        let scheduler = WorkspaceSaveScheduler(store: fixture.store, delay: 0.01)

        scheduler.schedule(snapshot(path: "~/first"))
        scheduler.schedule(snapshot(path: "~/last"))
        try await Task.sleep(for: .milliseconds(50))

        #expect(fixture.store.load()?.activeProjectPath == "~/last")
    }

    @Test("flush 立即保存且旧任务不会覆盖")
    func flushesImmediately() async throws {
        let fixture = try Fixture()
        defer { fixture.cleanUp() }
        let scheduler = WorkspaceSaveScheduler(store: fixture.store, delay: 0.04)

        scheduler.schedule(snapshot(path: "~/stale"))
        scheduler.flush(snapshot(path: "~/final"))
        #expect(fixture.store.load()?.activeProjectPath == "~/final")
        try await Task.sleep(for: .milliseconds(80))

        #expect(fixture.store.load()?.activeProjectPath == "~/final")
    }

    @Test("已执行任务之后可以再次调度")
    func schedulesAgainAfterExecution() async throws {
        let fixture = try Fixture()
        defer { fixture.cleanUp() }
        let scheduler = WorkspaceSaveScheduler(store: fixture.store, delay: 0.01)

        scheduler.schedule(snapshot(path: "~/first"))
        try await Task.sleep(for: .milliseconds(40))
        #expect(fixture.store.load()?.activeProjectPath == "~/first")

        scheduler.schedule(snapshot(path: "~/second"))
        try await Task.sleep(for: .milliseconds(40))
        #expect(fixture.store.load()?.activeProjectPath == "~/second")
    }

    private func snapshot(path: String) -> WorkspaceSnapshot {
        WorkspaceSnapshot(activeProjectPath: path, projects: [])
    }

    private final class Fixture {
        let suiteName: String
        let defaults: UserDefaults
        let store: WorkspaceStore

        init() throws {
            suiteName = "ink.workspace-scheduler-tests.\(UUID().uuidString)"
            defaults = try #require(UserDefaults(suiteName: suiteName))
            store = WorkspaceStore(defaults: defaults)
        }

        func cleanUp() {
            defaults.removePersistentDomain(forName: suiteName)
        }
    }
}
