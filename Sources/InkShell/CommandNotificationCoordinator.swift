import Foundation
import TerminalCore
@preconcurrency import UserNotifications

struct CommandNotificationRequest: Equatable {
    let title: String
    let body: String

    static func command(
        tabTitle: String,
        completion: CommandCompletion
    ) -> CommandNotificationRequest {
        let duration = CommandStatusFormatter.duration(completion.duration)
        if let exitStatus = completion.exitStatus, exitStatus != 0 {
            return CommandNotificationRequest(
                title: "命令失败",
                body: "\(tabTitle) · 退出状态 \(exitStatus) · \(duration)"
            )
        }
        return CommandNotificationRequest(
            title: "命令已完成",
            body: "\(tabTitle) · \(duration)"
        )
    }

    static func terminal(
        _ notification: TerminalNotification,
        fallbackTitle: String
    ) -> CommandNotificationRequest {
        CommandNotificationRequest(
            title: notification.title ?? fallbackTitle,
            body: notification.body
        )
    }
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

enum ExplicitNotificationPolicy {
    static func shouldNotify(
        isApplicationActive: Bool,
        isPaneActive: Bool
    ) -> Bool {
        !isApplicationActive || !isPaneActive
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
    private let now: () -> ContinuousClock.Instant
    private let minimumInterval: Duration
    private var lastAcceptedAt: ContinuousClock.Instant?

    init(
        client: LocalNotificationClient? = nil,
        now: @escaping () -> ContinuousClock.Instant = { ContinuousClock().now },
        minimumInterval: Duration = .seconds(1)
    ) {
        self.client = client
        self.now = now
        self.minimumInterval = minimumInterval
    }

    func submit(_ request: CommandNotificationRequest) {
        let submittedAt = now()
        if let lastAcceptedAt,
           lastAcceptedAt.duration(to: submittedAt) < minimumInterval {
            return
        }
        lastAcceptedAt = submittedAt

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
        return LocalNotificationContent(
            title: request.title,
            body: request.body
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
