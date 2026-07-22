import Foundation
import TerminalCore
@preconcurrency import UserNotifications

struct CommandNotificationRequest: Equatable {
    let tabTitle: String
    let completion: CommandCompletion
}

enum CommandNotificationPolicy {
    static let minimumDuration: Duration = .seconds(10)

    static func shouldNotify(
        isApplicationActive: Bool,
        completion: CommandCompletion
    ) -> Bool {
        !isApplicationActive && completion.duration >= minimumDuration
    }
}

@MainActor
protocol CommandNotificationCoordinating: AnyObject {
    func submit(_ request: CommandNotificationRequest)
}

enum NotificationAuthorizationState {
    case notDetermined
    case authorized
    case denied
}

struct LocalNotificationContent: Equatable {
    let title: String
    let body: String
}

@MainActor
protocol LocalNotificationClient: AnyObject {
    func authorizationState() async -> NotificationAuthorizationState
    func requestAuthorization() async throws -> Bool
    func deliver(_ content: LocalNotificationContent) async throws
}

@MainActor
final class CommandNotificationCoordinator: CommandNotificationCoordinating {
    private var client: LocalNotificationClient?

    init(client: LocalNotificationClient? = nil) {
        self.client = client
    }

    func submit(_ request: CommandNotificationRequest) {
        let client: LocalNotificationClient
        if let existing = self.client {
            client = existing
        } else {
            let created = UserNotificationClient()
            self.client = created
            client = created
        }
        Task { @MainActor [client] in
            let state = await client.authorizationState()
            let allowed: Bool
            switch state {
            case .authorized:
                allowed = true
            case .denied:
                allowed = false
            case .notDetermined:
                allowed = (try? await client.requestAuthorization()) == true
            }
            guard allowed else { return }
            try? await client.deliver(Self.content(for: request))
        }
    }

    private static func content(for request: CommandNotificationRequest) -> LocalNotificationContent {
        let duration = CommandStatusFormatter.duration(request.completion.duration)
        if let exitStatus = request.completion.exitStatus, exitStatus != 0 {
            return LocalNotificationContent(
                title: "命令失败",
                body: "\(request.tabTitle) · 退出状态 \(exitStatus) · \(duration)"
            )
        }
        return LocalNotificationContent(
            title: "命令已完成",
            body: "\(request.tabTitle) · \(duration)"
        )
    }
}

@MainActor
private final class UserNotificationClient: LocalNotificationClient {
    private let center: UNUserNotificationCenter

    init(center: UNUserNotificationCenter = .current()) {
        self.center = center
    }

    func authorizationState() async -> NotificationAuthorizationState {
        let settings = await center.notificationSettings()
        switch settings.authorizationStatus {
        case .notDetermined:
            return .notDetermined
        case .authorized, .provisional:
            return .authorized
        case .denied:
            return .denied
        @unknown default:
            return .denied
        }
    }

    func requestAuthorization() async throws -> Bool {
        try await center.requestAuthorization(options: [.alert])
    }

    func deliver(_ content: LocalNotificationContent) async throws {
        let notification = UNMutableNotificationContent()
        notification.title = content.title
        notification.body = content.body
        let request = UNNotificationRequest(
            identifier: UUID().uuidString,
            content: notification,
            trigger: nil
        )
        try await center.add(request)
    }
}
