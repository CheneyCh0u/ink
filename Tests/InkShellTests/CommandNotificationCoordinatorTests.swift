import TerminalCore
import Testing
@testable import InkShell

@Suite("命令系统通知")
@MainActor
struct CommandNotificationCoordinatorTests {
    @Test("只允许失焦后的十秒完整命令")
    func policyThreshold() {
        let short = CommandCompletion(exitStatus: 1, duration: .milliseconds(9_999))
        let long = CommandCompletion(exitStatus: 0, duration: .seconds(10))

        #expect(!CommandNotificationPolicy.shouldNotify(
            isApplicationActive: false,
            completion: short
        ))
        #expect(!CommandNotificationPolicy.shouldNotify(
            isApplicationActive: true,
            completion: long
        ))
        #expect(CommandNotificationPolicy.shouldNotify(
            isApplicationActive: false,
            completion: long
        ))
    }

    @Test("首次授权后投递同一条脱敏通知")
    func requestsThenDelivers() async throws {
        let client = NotificationClientFake(
            authorization: .notDetermined,
            requestResult: true
        )
        let coordinator = CommandNotificationCoordinator(client: client)
        coordinator.submit(.init(
            tabTitle: "构建",
            completion: .init(exitStatus: 2, duration: .seconds(12))
        ))

        #expect(try await waitUntil { client.delivered.count == 1 })
        let content = try #require(client.delivered.first)
        #expect(content.title == "命令失败")
        #expect(content.body.contains("构建"))
        #expect(content.body.contains("退出状态 2"))
        #expect(!content.body.contains("rm "))
        #expect(client.requestCount == 1)
    }

    @Test("拒绝与投递错误静默跳过")
    func deniedAndDeliveryFailure() async throws {
        let denied = NotificationClientFake(authorization: .denied)
        CommandNotificationCoordinator(client: denied).submit(sampleRequest)
        #expect(try await waitUntil { denied.authorizationChecks == 1 })
        #expect(denied.delivered.isEmpty)

        let failing = NotificationClientFake(
            authorization: .authorized,
            deliveryFails: true
        )
        CommandNotificationCoordinator(client: failing).submit(sampleRequest)
        #expect(try await waitUntil { failing.deliveryAttempts == 1 })
        #expect(failing.delivered.isEmpty)
    }

    private var sampleRequest: CommandNotificationRequest {
        .init(
            tabTitle: "任务",
            completion: .init(exitStatus: 0, duration: .seconds(12))
        )
    }

    private func waitUntil(
        timeout: Duration = .seconds(1),
        condition: @escaping @MainActor () -> Bool
    ) async throws -> Bool {
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: timeout)
        while clock.now < deadline {
            if condition() { return true }
            try await Task.sleep(for: .milliseconds(10))
        }
        return condition()
    }
}

@MainActor
private final class NotificationClientFake: LocalNotificationClient {
    var authorization: NotificationAuthorizationState
    let requestResult: Bool
    let deliveryFails: Bool
    private(set) var authorizationChecks = 0
    private(set) var requestCount = 0
    private(set) var deliveryAttempts = 0
    private(set) var delivered: [LocalNotificationContent] = []

    init(
        authorization: NotificationAuthorizationState,
        requestResult: Bool = false,
        deliveryFails: Bool = false
    ) {
        self.authorization = authorization
        self.requestResult = requestResult
        self.deliveryFails = deliveryFails
    }

    func authorizationState() async -> NotificationAuthorizationState {
        authorizationChecks += 1
        return authorization
    }

    func requestAuthorization() async throws -> Bool {
        requestCount += 1
        if requestResult { authorization = .authorized }
        return requestResult
    }

    func deliver(_ content: LocalNotificationContent) async throws {
        deliveryAttempts += 1
        if deliveryFails { throw DeliveryError.failed }
        delivered.append(content)
    }

    private enum DeliveryError: Error {
        case failed
    }
}
