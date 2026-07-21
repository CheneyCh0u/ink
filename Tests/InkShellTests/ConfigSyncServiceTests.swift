import Foundation
import InkConfig
import Testing
@testable import InkShell

@Suite("iCloud 配置同步服务", .serialized)
@MainActor
struct ConfigSyncServiceTests {
    @Test("开启时立即上传，之后只响应本机配置变化")
    func automaticUploadFollowsLocalChanges() throws {
        let fixture = makeFixture()
        defer { fixture.cleanUp() }
        var config = InkConfig()

        #expect(!fixture.service.automaticUploadEnabled)
        fixture.service.setAutomaticUploadEnabled(true, currentConfig: config)
        #expect(fixture.service.automaticUploadEnabled)
        #expect(fixture.store.setCallCount == 1)

        config.fontSize = 18
        fixture.service.configDidChange(config)
        #expect(fixture.store.setCallCount == 2)
        #expect(try cloudConfig(in: fixture.store) == config)

        fixture.service.setAutomaticUploadEnabled(false, currentConfig: config)
        config.fontSize = 19
        fixture.service.configDidChange(config)
        #expect(fixture.store.setCallCount == 2)
    }

    @Test("关闭自动上传后仍可手动上传和读取")
    func manualOperationsWorkWhileDisabled() throws {
        let fixture = makeFixture()
        defer { fixture.cleanUp() }
        var local = InkConfig()
        local.terminalTheme = .plum

        try fixture.service.upload(local)
        #expect(fixture.store.setCallCount == 1)
        #expect(try cloudConfig(in: fixture.store) == local)

        var remote = InkConfig()
        remote.cursorStyle = .bar
        fixture.store.values[ConfigSyncService.snapshotKey] = try ConfigSyncSnapshot(
            config: remote,
            modifiedAt: fixture.now,
            deviceID: "remote-mac"
        ).encoded()
        let result = try fixture.service.readCloudSnapshot()
        let snapshot = try #require(result)

        #expect(snapshot.config == remote)
        #expect(fixture.service.status == .cloudSnapshot(fixture.now, isCurrentDevice: false))
    }

    @Test("设备标识在同一台 Mac 上保持稳定")
    func deviceIDPersists() {
        let fixture = makeFixture()
        defer { fixture.cleanUp() }
        let first = fixture.service.deviceID
        let second = ConfigSyncService(
            store: fixture.store,
            defaults: fixture.defaults,
            now: { fixture.now }
        )

        #expect(!first.isEmpty)
        #expect(second.deviceID == first)
    }

    @Test("操作状态按上传和读取顺序变化")
    func reportsOperationStates() throws {
        let fixture = makeFixture()
        defer { fixture.cleanUp() }
        var states: [ConfigSyncStatus] = []
        fixture.service.onStatusChange = { states.append($0) }

        try fixture.service.upload(InkConfig())
        #expect(states == [.uploading, .uploaded(fixture.now)])

        states.removeAll()
        _ = try fixture.service.readCloudSnapshot()
        #expect(states == [
            .reading,
            .cloudSnapshot(fixture.now, isCurrentDevice: true),
        ])
    }

    @Test("未登录 iCloud 时保留本机并报告不可用")
    func unavailableCloudDoesNotWrite() {
        let fixture = makeFixture()
        defer { fixture.cleanUp() }
        fixture.store.isAvailable = false

        #expect(throws: ConfigSyncServiceError.iCloudUnavailable) {
            try fixture.service.upload(InkConfig())
        }
        #expect(fixture.store.setCallCount == 0)
        #expect(fixture.service.status == .unavailable)
    }

    @Test("同步请求失败时报告错误")
    func synchronizeFailureIsVisible() {
        let fixture = makeFixture()
        defer { fixture.cleanUp() }
        fixture.store.synchronizeResult = false

        #expect(throws: ConfigSyncServiceError.synchronizeFailed) {
            try fixture.service.upload(InkConfig())
        }
        guard case .failed = fixture.service.status else {
            Issue.record("同步失败后应进入 failed 状态")
            return
        }
    }

    @Test("云端为空和损坏 JSON 都不产生配置")
    func emptyAndBrokenCloudAreSafe() throws {
        let fixture = makeFixture()
        defer { fixture.cleanUp() }

        #expect(try fixture.service.readCloudSnapshot() == nil)
        #expect(fixture.service.status == .cloudEmpty)

        fixture.store.values[ConfigSyncService.snapshotKey] = Data("{broken".utf8)
        #expect(throws: ConfigSyncServiceError.invalidSnapshot) {
            try fixture.service.readCloudSnapshot()
        }
        guard case .failed = fixture.service.status else {
            Issue.record("损坏 JSON 后应进入 failed 状态")
            return
        }
    }

    private func cloudConfig(in store: MemoryConfigCloudStore) throws -> InkConfig {
        let data = try #require(store.values[ConfigSyncService.snapshotKey])
        return try ConfigSyncSnapshot.decode(data).config
    }

    private func makeFixture() -> Fixture {
        let suite = "ink-config-sync-tests-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defaults.removePersistentDomain(forName: suite)
        let store = MemoryConfigCloudStore()
        let now = Date(timeIntervalSince1970: 1_785_000_000)
        let service = ConfigSyncService(
            store: store,
            defaults: defaults,
            now: { now }
        )
        return Fixture(
            service: service,
            store: store,
            defaults: defaults,
            suite: suite,
            now: now
        )
    }
}

@MainActor
private struct Fixture {
    let service: ConfigSyncService
    let store: MemoryConfigCloudStore
    let defaults: UserDefaults
    let suite: String
    let now: Date

    func cleanUp() {
        defaults.removePersistentDomain(forName: suite)
    }
}

@MainActor
private final class MemoryConfigCloudStore: ConfigCloudStore {
    var isAvailable = true
    var synchronizeResult = true
    var values: [String: Data] = [:]
    var synchronizeCallCount = 0
    var setCallCount = 0

    func data(forKey key: String) -> Data? { values[key] }

    func set(_ data: Data, forKey key: String) {
        setCallCount += 1
        values[key] = data
    }

    func synchronize() -> Bool {
        synchronizeCallCount += 1
        return synchronizeResult
    }
}
