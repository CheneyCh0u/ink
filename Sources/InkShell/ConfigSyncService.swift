import Foundation
import InkConfig

@MainActor
protocol ConfigCloudStore: AnyObject {
    var isAvailable: Bool { get }
    func data(forKey key: String) -> Data?
    func set(_ data: Data, forKey key: String)
    @discardableResult func synchronize() -> Bool
}

@MainActor
final class UbiquitousConfigCloudStore: ConfigCloudStore {
    private let store: NSUbiquitousKeyValueStore

    init(store: NSUbiquitousKeyValueStore = .default) {
        self.store = store
    }

    var isAvailable: Bool {
        FileManager.default.ubiquityIdentityToken != nil
    }

    func data(forKey key: String) -> Data? {
        store.data(forKey: key)
    }

    func set(_ data: Data, forKey key: String) {
        store.set(data, forKey: key)
    }

    func synchronize() -> Bool {
        store.synchronize()
    }
}

enum ConfigSyncStatus: Equatable {
    case idle
    case uploading
    case reading
    case uploaded(Date)
    case cloudSnapshot(Date, isCurrentDevice: Bool)
    case cloudEmpty
    case unavailable
    case failed(String)
}

enum ConfigSyncServiceError: LocalizedError, Equatable {
    case iCloudUnavailable
    case synchronizeFailed
    case invalidSnapshot

    var errorDescription: String? {
        switch self {
        case .iCloudUnavailable:
            "iCloud 不可用"
        case .synchronizeFailed:
            "无法连接 iCloud"
        case .invalidSnapshot:
            "云端配置无法读取"
        }
    }
}

/// 配置同步的事件驱动边界。不监听远端变化，也不创建周期任务。
@MainActor
final class ConfigSyncService {
    static let snapshotKey = "ink.config.snapshot.v1"
    private static let automaticUploadKey = "ink.sync.automaticUpload"
    private static let deviceIDKey = "ink.sync.deviceID"

    private let store: ConfigCloudStore
    private let defaults: UserDefaults
    private let now: () -> Date

    private(set) var status: ConfigSyncStatus = .idle
    var onStatusChange: ((ConfigSyncStatus) -> Void)?

    var automaticUploadEnabled: Bool {
        defaults.bool(forKey: Self.automaticUploadKey)
    }

    let deviceID: String

    init(
        store: ConfigCloudStore = UbiquitousConfigCloudStore(),
        defaults: UserDefaults = .standard,
        now: @escaping () -> Date = Date.init
    ) {
        self.store = store
        self.defaults = defaults
        self.now = now
        if let saved = defaults.string(forKey: Self.deviceIDKey), !saved.isEmpty {
            deviceID = saved
        } else {
            let generated = UUID().uuidString
            defaults.set(generated, forKey: Self.deviceIDKey)
            deviceID = generated
        }
    }

    func setAutomaticUploadEnabled(_ enabled: Bool, currentConfig: InkConfig) {
        defaults.set(enabled, forKey: Self.automaticUploadKey)
        guard enabled else {
            setStatus(.idle)
            return
        }
        do {
            try upload(currentConfig)
        } catch {
            // 开关保持开启；下一次配置变化或手动操作会重试。
        }
    }

    func configDidChange(_ config: InkConfig) {
        guard automaticUploadEnabled else { return }
        do {
            try upload(config)
        } catch {
            // 状态已经由 upload 更新，本地配置不回滚。
        }
    }

    func upload(_ config: InkConfig) throws {
        setStatus(.uploading)
        do {
            try requireAvailableCloud()
            let modifiedAt = now()
            let data = try ConfigSyncSnapshot(
                config: config,
                modifiedAt: modifiedAt,
                deviceID: deviceID
            ).encoded()
            store.set(data, forKey: Self.snapshotKey)
            guard store.synchronize() else {
                throw ConfigSyncServiceError.synchronizeFailed
            }
            setStatus(.uploaded(modifiedAt))
        } catch {
            setFailureStatus(for: error)
            throw error
        }
    }

    func readCloudSnapshot() throws -> ConfigSyncSnapshot? {
        setStatus(.reading)
        do {
            try requireAvailableCloud()
            guard store.synchronize() else {
                throw ConfigSyncServiceError.synchronizeFailed
            }
            guard let data = store.data(forKey: Self.snapshotKey) else {
                setStatus(.cloudEmpty)
                return nil
            }
            let snapshot: ConfigSyncSnapshot
            do {
                snapshot = try ConfigSyncSnapshot.decode(data)
            } catch {
                throw ConfigSyncServiceError.invalidSnapshot
            }
            setStatus(.cloudSnapshot(
                snapshot.modifiedAt,
                isCurrentDevice: snapshot.deviceID == deviceID
            ))
            return snapshot
        } catch {
            setFailureStatus(for: error)
            throw error
        }
    }

    private func requireAvailableCloud() throws {
        guard store.isAvailable else {
            throw ConfigSyncServiceError.iCloudUnavailable
        }
    }

    private func setFailureStatus(for error: Error) {
        if error as? ConfigSyncServiceError == .iCloudUnavailable {
            setStatus(.unavailable)
        } else {
            setStatus(.failed(error.localizedDescription))
        }
    }

    private func setStatus(_ fresh: ConfigSyncStatus) {
        status = fresh
        onStatusChange?(fresh)
    }
}
