import UserNotifications
import XCTest
@testable import AgentMeter

@MainActor
final class NotificationManagerAuthorizationTests: XCTestCase {
    func testAuthorizationUsesAsyncCenterAndStoresGrant() async {
        let center = AuthorizationCenterStub(result: .success(true))
        let manager = NotificationManager(
            authorizationCenter: center,
            bundleIdentifier: { "com.shu.agentmeter.tests" }
        )

        await manager.requestAuthorizationIfNeeded()

        XCTAssertTrue(manager.requested)
        XCTAssertTrue(manager.authorized)
        XCTAssertEqual(center.requestCount, 1)
        XCTAssertTrue(center.delegate === manager)
    }

    func testAuthorizationFailureStaysUnauthorizedAndDoesNotRetry() async {
        let center = AuthorizationCenterStub(result: .failure(AuthorizationError.denied))
        let manager = NotificationManager(
            authorizationCenter: center,
            bundleIdentifier: { "com.shu.agentmeter.tests" }
        )

        await manager.requestAuthorizationIfNeeded()
        await manager.requestAuthorizationIfNeeded()

        XCTAssertTrue(manager.requested)
        XCTAssertFalse(manager.authorized)
        XCTAssertEqual(center.requestCount, 1)
    }

    func testAuthorizationSkipsUnbundledExecutables() async {
        let center = AuthorizationCenterStub(result: .success(true))
        let manager = NotificationManager(
            authorizationCenter: center,
            bundleIdentifier: { nil }
        )

        await manager.requestAuthorizationIfNeeded()

        XCTAssertFalse(manager.requested)
        XCTAssertFalse(manager.authorized)
        XCTAssertEqual(center.requestCount, 0)
        XCTAssertNil(center.delegate)
    }

    func testDeferredEvaluationAfterThePromptUsesTheLatestWindows() async {
        let defaults = UserDefaults.standard
        let savedEnabled = defaults.object(forKey: "alertsEnabled")
        let savedThreshold = defaults.object(forKey: "alertThresholdPercent")
        defaults.set(true, forKey: "alertsEnabled")
        defaults.set(10.0, forKey: "alertThresholdPercent")
        defer {
            restore(defaults, key: "alertsEnabled", to: savedEnabled)
            restore(defaults, key: "alertThresholdPercent", to: savedThreshold)
        }

        let center = AuthorizationCenterStub(result: .success(true))
        center.holdsRequests = true
        let manager = NotificationManager(
            authorizationCenter: center,
            bundleIdentifier: { "com.shu.agentmeter.tests" }
        )
        let reset = Date().addingTimeInterval(3600)
        let low = [QuotaWindow(id: "five_hour", label: "5-hour", usedPercent: 95, resetsAt: reset)]
        let recovered = [QuotaWindow(id: "five_hour", label: "5-hour", usedPercent: 10,
                                     resetsAt: reset.addingTimeInterval(5 * 3600))]

        // The first low reading asks for permission and parks its evaluation
        // behind the prompt.
        manager.evaluate(provider: .claude, windows: low)
        await settle(until: { center.requestCount == 1 })
        XCTAssertTrue(manager.requested)
        XCTAssertFalse(manager.authorized)

        // The window recovers while the prompt is still open.
        manager.evaluate(provider: .claude, windows: recovered)
        XCTAssertTrue(center.posted.isEmpty, "nothing can be delivered before the grant")

        center.releaseRequest()
        await settle(until: { manager.authorized })
        XCTAssertTrue(
            center.posted.isEmpty,
            "allowing the prompt must evaluate the recovered reading, not the one captured "
                + "before it; posted: \(center.posted.map(\.content.title))"
        )

        // The manager is armed: the next genuine drop still notifies, once.
        manager.evaluate(provider: .claude, windows: low)
        manager.evaluate(provider: .claude, windows: low)
        XCTAssertEqual(center.posted.count, 1)
        XCTAssertTrue(center.posted.first?.content.title.hasSuffix("quota low") == true)
    }

    /// Yields the main actor until `condition` holds, so a parked `Task` on it
    /// can run; fails instead of hanging when it never does.
    private func settle(until condition: () -> Bool) async {
        for _ in 0..<1_000 where !condition() {
            await Task.yield()
        }
        XCTAssertTrue(condition(), "the deferred work never ran")
    }
}

private func restore(_ defaults: UserDefaults, key: String, to value: Any?) {
    if let value {
        defaults.set(value, forKey: key)
    } else {
        defaults.removeObject(forKey: key)
    }
}

private enum AuthorizationError: Error {
    case denied
}

private final class AuthorizationCenterStub: NotificationAuthorizationCenter {
    var delegate: (any UNUserNotificationCenterDelegate)?
    private(set) var requestCount = 0
    private(set) var posted: [UNNotificationRequest] = []
    /// When set, `requestAuthorization` parks until `releaseRequest()`, like a
    /// permission prompt the user has not answered yet.
    var holdsRequests = false
    private var pendingRequest: CheckedContinuation<Void, Never>?

    private let result: Result<Bool, Error>

    init(result: Result<Bool, Error>) {
        self.result = result
    }

    func requestAuthorization(options: UNAuthorizationOptions) async throws -> Bool {
        requestCount += 1
        if holdsRequests {
            await withCheckedContinuation { pendingRequest = $0 }
        }
        return try result.get()
    }

    func releaseRequest() {
        pendingRequest?.resume()
        pendingRequest = nil
    }

    func post(_ request: UNNotificationRequest) {
        posted.append(request)
    }
}
