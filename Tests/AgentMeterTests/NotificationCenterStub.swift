import UserNotifications
@testable import AgentMeter

enum AuthorizationError: Error {
    case denied
}

/// Stands in for `UNUserNotificationCenter`: nothing reaches the real center
/// and no banner ever shows. Models what the tests rely on: the permission
/// prompt (optionally held open), the authorization status it leaves behind,
/// categories, replacement by identifier, and a refused delivery.
@MainActor
final class AuthorizationCenterStub: NotificationAuthorizationCenter {
    var delegate: (any UNUserNotificationCenterDelegate)?
    private(set) var requestCount = 0
    /// Every request handed to `post` (quota) or accepted by `deliver`
    /// (events), in order.
    private(set) var posted: [UNNotificationRequest] = []
    /// What Notification Center would show: one per identifier, the latest.
    private(set) var delivered: [String: UNNotificationRequest] = [:]
    private(set) var deliverAttempts = 0
    private(set) var statusQueries = 0
    private(set) var categories: Set<UNNotificationCategory>?
    /// When set, `requestAuthorization` parks until `releaseRequest()`, like a
    /// permission prompt the user has not answered yet.
    var holdsRequests = false
    /// The status the system reports. A prompt answered with true or false
    /// moves it to authorized or denied.
    var status: UNAuthorizationStatus = .notDetermined
    /// Thrown by `deliver`, like the center refusing a request.
    var deliverError: (any Error)?
    /// Runs while the prompt is open, before it is answered.
    var onPrompt: (() -> Void)?
    private var pendingRequest: CheckedContinuation<Void, Never>?

    private let result: Result<Bool, Error>

    init(result: Result<Bool, Error>, status: UNAuthorizationStatus = .notDetermined) {
        self.result = result
        self.status = status
    }

    func requestAuthorization(options: UNAuthorizationOptions) async throws -> Bool {
        requestCount += 1
        onPrompt?()
        if holdsRequests {
            await withCheckedContinuation { pendingRequest = $0 }
        }
        if case let .success(granted) = result { status = granted ? .authorized : .denied }
        return try result.get()
    }

    func releaseRequest() {
        pendingRequest?.resume()
        pendingRequest = nil
    }

    func post(_ request: UNNotificationRequest) {
        posted.append(request)
        delivered[request.identifier] = request
    }

    func deliver(_ request: UNNotificationRequest) async throws {
        deliverAttempts += 1
        if let deliverError { throw deliverError }
        posted.append(request)
        delivered[request.identifier] = request
    }

    func authorizationStatus() async -> UNAuthorizationStatus {
        statusQueries += 1
        return status
    }

    /// What `currentSettings()` reports beyond the status.
    var settings = AgentMeterNotificationSettings(authorization: .unknown)
    private(set) var settingsQueries = 0

    func currentSettings() async -> AgentMeterNotificationSettings {
        settingsQueries += 1
        var current = settings
        current.authorization = AgentMeterNotificationSettings.authorization(status)
        return current
    }

    func setCategories(_ categories: Set<UNNotificationCategory>) {
        self.categories = categories
    }
}
