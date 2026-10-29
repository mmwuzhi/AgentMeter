@testable import AgentMeter
import AppKit
import UserNotifications
import XCTest

/// Settings › Alerts for task notifications, the system settings it reports,
/// and the menu bar's unread count. Nothing here reads or changes the real
/// notification settings or the user's defaults.
@MainActor
final class TaskNotificationSettingsTests: XCTestCase {
    typealias Settings = AgentMeterNotificationSettings

    // MARK: - Preferences

    func testSessionTitlesAreOnByDefaultAndAStoredOffStillWins() {
        // The user's choice, 2026-10-29: banners name the session by default.
        XCTAssertTrue(AgentMeterNotificationPreferences().showsSessionTitle)
        XCTAssertTrue(AgentMeterNotificationPreferences(stored: { _ in nil }).showsSessionTitle)
        XCTAssertTrue(AgentMeterNotificationPreferences(stored: { _ in "no" }).showsSessionTitle, "wrong type keeps the default")
        let off = AgentMeterNotificationPreferences(stored: { $0 == AgentMeterNotificationPreferences.showsSessionTitleKey ? false : nil })
        XCTAssertFalse(off.showsSessionTitle, "someone who turned it off keeps it off")
        XCTAssertTrue(off.taskCompleted && off.taskFailed && off.taskWaiting, "the three kinds keep their defaults")
        XCTAssertEqual(AgentMeterNotificationPreferences.showsSessionTitleKey, "taskNotificationsShowSessionTitle")
    }

    func testTheSwitchesPersistInDefaultsAndApplyToTheNextDelivery() throws {
        let suite = "agentmeter.tests.settings.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        XCTAssertEqual(AgentMeterNotificationPreferences(defaults: defaults), AgentMeterNotificationPreferences())
        defaults.set(false, forKey: AgentMeterNotificationPreferences.taskWaitingKey)
        defaults.set(true, forKey: AgentMeterNotificationPreferences.showsSessionTitleKey)
        let read = AgentMeterNotificationPreferences(defaults: defaults)
        XCTAssertEqual(read, AgentMeterNotificationPreferences(taskWaiting: false, showsSessionTitle: true))
        XCTAssertFalse(read.notifies(.taskWaiting))
        XCTAssertTrue(read.notifies(.taskCompleted))
        XCTAssertFalse(read.notifies(.taskUnknown), "an unconfirmed task is never posted")
    }

    func testTheTaskListIsShownByDefaultAndTheSwitchIsRead() throws {
        let suite = "agentmeter.tests.list.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        XCTAssertEqual(TaskEventListVisibility.key, "taskNotificationsShowListInMenu")
        XCTAssertTrue(TaskEventListVisibility.isShown(in: defaults), "on by default")
        defaults.set("no", forKey: TaskEventListVisibility.key)
        XCTAssertTrue(TaskEventListVisibility.isShown(in: defaults), "wrong type keeps the default")
        defaults.set(false, forKey: TaskEventListVisibility.key)
        XCTAssertFalse(TaskEventListVisibility.isShown(in: defaults))
        XCTAssertEqual(AgentMeterNotificationPreferences(defaults: defaults), AgentMeterNotificationPreferences(),
                       "hiding the list leaves every banner switch as it was")
    }

    // MARK: - System settings, reported never changed

    func testWhatSettingsSaysForEachPermissionAndStyle() {
        let notAsked = Settings(authorization: .notDetermined)
        XCTAssertEqual(notAsked.authorizationText, "Not asked yet")
        XCTAssertEqual(notAsked.guidance, "AgentMeter asks for permission the first time it has something to tell you.")

        let denied = Settings(authorization: .denied)
        XCTAssertTrue(denied.guidance?.contains("System Settings › Notifications › AgentMeter") == true)
        XCTAssertFalse(denied.canPost)

        let banners = Settings(authorization: .authorized, alertStyle: .banner, lockScreen: .enabled, previews: .whenAuthenticated)
        XCTAssertEqual(banners.alertStyleText, "Temporary (banners)")
        XCTAssertNil(banners.guidance, "Temporary is the default and a fine choice: nothing to fix")
        XCTAssertEqual(banners.lockScreenText, "Shown, text hidden until unlocked")
        XCTAssertNil(banners.privacyNote)

        let persistent = Settings(authorization: .authorized, alertStyle: .alert, lockScreen: .enabled, previews: .always)
        XCTAssertEqual(persistent.alertStyleText, "Persistent (alerts)")
        XCTAssertNil(persistent.guidance, "already stays until acted on")
        XCTAssertTrue(persistent.privacyNote?.contains("When unlocked") == true)

        let quiet = Settings(authorization: .authorized, alertStyle: .none)
        XCTAssertTrue(quiet.guidance?.contains("without appearing on screen") == true)
        XCTAssertTrue(quiet.guidance?.contains("Temporary or Persistent") == true)
        XCTAssertEqual(Settings(authorization: .authorized, lockScreen: .disabled).lockScreenText, "Not shown")
    }

    /// Both styles explained, and that only System Settings chooses: no
    /// AgentMeter switch could change it (`alertStyle` is read-only).
    func testTheStyleExplanationNamesBothAndWhereToChoose() {
        let text = Settings.styleExplanation
        for fragment in ["Temporary:", "Persistent:", "until you click it or close it",
                         "System Settings › Notifications › AgentMeter › Alert style", "Temporary is the default",
                         "never changes it"] {
            XCTAssertTrue(text.contains(fragment), fragment)
        }
    }

    func testHeadlessRunsAreOffByDefaultAndTheSwitchIsRead() throws {
        XCTAssertFalse(AgentMeterNotificationPreferences().notifiesHeadlessRuns)
        XCTAssertEqual(AgentMeterNotificationPreferences.notifiesHeadlessRunsKey, "taskNotificationsIncludeHeadlessRuns")
        XCTAssertFalse(AgentMeterNotificationPreferences(stored: { _ in "yes" }).notifiesHeadlessRuns, "wrong type keeps the default")
        let suite = "agentmeter.tests.headless.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        defaults.set(true, forKey: AgentMeterNotificationPreferences.notifiesHeadlessRunsKey)
        let read = AgentMeterNotificationPreferences(defaults: defaults)
        XCTAssertTrue(read.notifiesHeadlessRuns)
        XCTAssertTrue(read.taskCompleted && read.taskFailed && read.taskWaiting && read.showsSessionTitle,
                      "the other switches keep their defaults")
    }

    func testTheSystemValuesMapOneToOne() {
        XCTAssertEqual(Settings.authorization(.authorized), .authorized)
        XCTAssertEqual(Settings.authorization(.provisional), .provisional)
        XCTAssertEqual(Settings.alertStyle(.alert), .alert)
        XCTAssertEqual(Settings.alertStyle(.banner), .banner)
        XCTAssertEqual(Settings.setting(.enabled), .enabled)
        XCTAssertEqual(Settings.previews(.whenAuthenticated), .whenAuthenticated)
        XCTAssertEqual(Settings.previews(.never), .never)
    }

    func testTheManagerReportsSettingsOnlyWithABundleAndNeverAsks() async {
        let center = AuthorizationCenterStub(result: .success(true), status: .denied)
        center.settings = Settings(authorization: .unknown, alertStyle: .banner, lockScreen: .enabled, previews: .always)
        let manager = NotificationManager(authorizationCenter: center, bundleIdentifier: { "com.shu.agentmeter.tests" })
        let settings = await manager.notificationSettings()
        XCTAssertEqual(settings?.authorization, .denied)
        XCTAssertEqual(settings?.alertStyle, .banner)
        XCTAssertEqual(center.requestCount, 0, "reading is not asking")

        let bare = AuthorizationCenterStub(result: .success(true))
        let unbundled = NotificationManager(authorizationCenter: bare, bundleIdentifier: { nil })
        let none = await unbundled.notificationSettings()
        XCTAssertNil(none)
        XCTAssertEqual(bare.settingsQueries, 0, "the real center would trap without a bundle")
    }

    func testTheSettingsLinkOnlyOpensAgentMetersPage() throws {
        let url = try XCTUnwrap(TaskNotificationSettingsSections.systemSettingsURL(bundleID: "com.shu.agentmeter"))
        XCTAssertEqual(url.absoluteString,
                       "x-apple.systempreferences:com.apple.Notifications-Settings.extension?id=com.shu.agentmeter")
    }

    func testTaskNotificationsHidePreviewsBehindAPlaceholder() throws {
        let task = try XCTUnwrap(NotificationManager.eventCategories.first {
            $0.identifier == NotificationManager.taskCategoryIdentifier
        })
        XCTAssertEqual(task.hiddenPreviewsBodyPlaceholder, "Claude Code task update")
        XCTAssertTrue(task.actions.isEmpty)
    }

    // MARK: - Menu bar count

    func testTheCountAddsWidthOnlyWhileThereIsSomethingUnread() {
        let elements: [MenuBarElement] = [.icon(.provider(.claude))]
        let plain = MenuBarContentView.width(elements: elements, showCaptions: true)
        XCTAssertEqual(MenuBarContentView.width(elements: elements, showCaptions: true, unreadBadge: 0), plain,
                       "nothing unread: the item keeps its exact width")
        let one = MenuBarContentView.width(elements: elements, showCaptions: true, unreadBadge: 1)
        XCTAssertEqual(one, plain + MenuBarContentView.badgeGap + MenuBarContentView.badgeHeight, "a one-digit count is round")
        let many = MenuBarContentView.width(elements: elements, showCaptions: true, unreadBadge: 250)
        XCTAssertGreaterThan(many, one)
        XCTAssertEqual(MenuBarContentView.badgeText(9), "9")
        XCTAssertEqual(MenuBarContentView.badgeText(100), "99+")
        XCTAssertEqual(MenuBarContentView.badgeWidth(100), MenuBarContentView.badgeWidth(5_000), "capped, so it never grows")
        XCTAssertEqual(MenuBarContentView.unreadSummary(0), "")
        XCTAssertEqual(MenuBarContentView.unreadSummary(1), ", 1 unread task notification")
        XCTAssertEqual(MenuBarContentView.unreadSummary(3), ", 3 unread task notifications")
    }

    func testTheCountSitsOnClaudesItemOrTheFirstVisibleOne() {
        XCTAssertEqual(StatusItemController.taskEventsSlot(visible: [.codex, .claude]), .claude)
        XCTAssertEqual(StatusItemController.taskEventsSlot(visible: [.codex, .copilot]), .codex,
                       "Claude's item hidden: the count must not vanish with it")
        XCTAssertNil(StatusItemController.taskEventsSlot(visible: []))
    }

    func testTheCountShowsOnlyOnTheListsItemAndOnlyWhileTheListIsShown() {
        let unread = TaskEventsState.loaded(TaskEventsSnapshot.make(
            unreadEvents: [listEvent("a", task: "a"), listEvent("b", task: "b")], recentEvents: [], overflow: nil))
        XCTAssertEqual(StatusItemController.unreadBadge(unread, carriesList: true, listShown: true), 2)
        XCTAssertEqual(StatusItemController.unreadBadge(unread, carriesList: false, listShown: true), 0)
        XCTAssertEqual(StatusItemController.unreadBadge(unread, carriesList: true, listShown: false), 0,
                       "hidden with the list")
        XCTAssertEqual(StatusItemController.unreadBadge(.loading, carriesList: true, listShown: true), 0)
    }

    func testTheCountIsDrawnInsideTheDeclaredWidth() throws {
        let view = MenuBarContentView()
        let elements: [MenuBarElement] = [.icon(.provider(.claude))]
        view.apply(elements: elements, showCaptions: true, fillsByUsed: false)
        view.unreadBadge = 7
        let width = MenuBarContentView.width(elements: elements, showCaptions: true, unreadBadge: 7)
        view.frame = NSRect(x: 0, y: 0, width: width, height: 22)
        let rep = try XCTUnwrap(view.bitmapImageRepForCachingDisplay(in: view.bounds))
        view.cacheDisplay(in: view.bounds, to: rep)
        // The capsule's blue reaches the last column and nothing is cut.
        let edge = try XCTUnwrap(rep.colorAt(x: rep.pixelsWide - 3, y: rep.pixelsHigh / 2)?.usingColorSpace(.sRGB))
        XCTAssertGreaterThan(edge.blueComponent, 0.6)
        XCTAssertLessThan(edge.redComponent, 0.4)
    }
}
