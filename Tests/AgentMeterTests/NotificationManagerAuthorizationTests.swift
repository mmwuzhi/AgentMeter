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
}

private enum AuthorizationError: Error {
    case denied
}

private final class AuthorizationCenterStub: NotificationAuthorizationCenter {
    var delegate: (any UNUserNotificationCenterDelegate)?
    private(set) var requestCount = 0

    private let result: Result<Bool, Error>

    init(result: Result<Bool, Error>) {
        self.result = result
    }

    func requestAuthorization(options: UNAuthorizationOptions) async throws -> Bool {
        requestCount += 1
        return try result.get()
    }
}
