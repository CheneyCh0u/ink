import TerminalCore
import Testing
@testable import InkShell

@Suite("命令系统通知")
@MainActor
struct CommandNotificationCoordinatorTests {
    @Test("默认协调器初始化不访问系统通知中心")
    func defaultInitializationIsLazy() {
        let coordinator = CommandNotificationCoordinator()
        withExtendedLifetime(coordinator) {}
    }

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

    @Test("命令与 OSC 映射为同一内容请求")
    func requestContent() {
        let command = CommandNotificationRequest.command(
            tabTitle: "构建",
            completion: .init(exitStatus: 2, duration: .seconds(12))
        )
        #expect(command.title == "命令失败")
        #expect(command.body == "构建 · 退出状态 2 · 12 秒")

        let fallback = CommandNotificationRequest.terminal(
            .init(title: nil, body: "完成"),
            fallbackTitle: "后台"
        )
        #expect(fallback.title == "后台")
        #expect(fallback.body == "完成")

        let explicit = CommandNotificationRequest.terminal(
            .init(title: "部署", body: "节点完成"),
            fallbackTitle: "后台"
        )
        #expect(explicit.title == "部署")
        #expect(explicit.body == "节点完成")
    }

    @Test("OSC 只在当前前台 pane 抑制")
    func explicitPolicy() {
        #expect(!ExplicitNotificationPolicy.shouldNotify(
            isApplicationActive: true,
            isPaneActive: true
        ))
        #expect(ExplicitNotificationPolicy.shouldNotify(
            isApplicationActive: true,
            isPaneActive: false
        ))
        #expect(ExplicitNotificationPolicy.shouldNotify(
            isApplicationActive: false,
            isPaneActive: true
        ))
        #expect(ExplicitNotificationPolicy.shouldNotify(
            isApplicationActive: false,
            isPaneActive: false
        ))
    }

    @Test("首次授权后投递同一条脱敏通知")
    func requestsThenDelivers() async throws {
        let client = NotificationClientFake(
            authorization: .notDetermined,
            requestResult: true
        )
        let coordinator = CommandNotificationCoordinator(client: client)
        coordinator.submit(.command(
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

    @Test("命令与 OSC 共享一秒节流窗口")
    func sharedThrottle() async throws {
        let clock = ContinuousClock()
        let start = clock.now
        var now = start
        let client = NotificationClientFake(authorization: .authorized)
        let coordinator = CommandNotificationCoordinator(
            client: client,
            now: { now }
        )

        coordinator.submit(sampleRequest)
        coordinator.submit(.terminal(
            .init(title: "部署", body: "第一批"),
            fallbackTitle: "任务"
        ))
        #expect(try await waitUntil { client.delivered.count == 1 })
        #expect(client.authorizationChecks == 1)

        now = start.advanced(by: .milliseconds(999))
        coordinator.submit(.terminal(
            .init(title: nil, body: "仍然过快"),
            fallbackTitle: "任务"
        ))
        await Task.yield()
        #expect(client.delivered.count == 1)

        now = start.advanced(by: .seconds(1))
        coordinator.submit(.terminal(
            .init(title: nil, body: "可以投递"),
            fallbackTitle: "任务"
        ))
        #expect(try await waitUntil { client.delivered.count == 2 })
        #expect(client.delivered.last?.body == "可以投递")
    }

    @Test("节流在授权查询任务之前执行")
    func throttlePrecedesAuthorization() async throws {
        let clock = ContinuousClock()
        let now = clock.now
        let denied = NotificationClientFake(authorization: .denied)
        let coordinator = CommandNotificationCoordinator(
            client: denied,
            now: { now }
        )

        coordinator.submit(sampleRequest)
        coordinator.submit(sampleRequest)
        #expect(try await waitUntil { denied.authorizationChecks == 1 })
        await Task.yield()
        #expect(denied.authorizationChecks == 1)
    }

    private var sampleRequest: CommandNotificationRequest {
        .command(
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
