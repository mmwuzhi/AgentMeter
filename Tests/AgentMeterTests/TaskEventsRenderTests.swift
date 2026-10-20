@testable import AgentMeter
import AppKit
import SwiftUI
import UserNotifications
import XCTest

/// Renders the task list, its Settings sections and the menu bar count to PNG
/// files for a visual check, since this environment cannot capture the menu
/// bar. Skipped unless `AGENTMETER_RENDER_DIR` names an output directory:
///
///     AGENTMETER_RENDER_DIR=/path/to/dir swift test --filter TaskEventsRenderTests
///
/// Off-screen windows only; nothing is shown and nothing is posted.
@MainActor
final class TaskEventsRenderTests: XCTestCase {
    private var outputDirectory: URL!

    override func setUpWithError() throws {
        guard let path = ProcessInfo.processInfo.environment["AGENTMETER_RENDER_DIR"], !path.isEmpty else {
            throw XCTSkip("set AGENTMETER_RENDER_DIR to render")
        }
        outputDirectory = URL(fileURLWithPath: path, isDirectory: true)
        try FileManager.default.createDirectory(at: outputDirectory, withIntermediateDirectories: true)
    }

    private let now = Date(timeIntervalSince1970: 1_792_480_000 + 3_600)
    private let decided = Date(timeIntervalSince1970: 1_792_480_000)

    private func items() -> [AgentMeterEvent] {
        [
            listEvent("c", .taskCompleted, session: "ffafe0d9-1", task: "p1", at: 3_400, body: "Session ffafe0d9\n12m run"),
            listEvent("f", .taskFailed, session: "0a1b2c3d-2", task: "p2", at: 2_900,
                      body: "Session 0a1b2c3d\nRate limit · after 2m"),
            listEvent("w", .taskWaiting, session: "77aa88bb-3", task: "p3", at: 2_000,
                      body: "Session 77aa88bb\nWaiting for permission · 1m"),
            listEvent("u", .taskUnknown, session: "c0ffee00-4", task: "p4", at: 600,
                      delivery: .suppressed(TaskOutcomeAnnouncement.Reason.backgroundShellRunning, at: decided),
                      title: "agentmeter stopped, background work running",
                      body: "Session c0ffee00\n2 background shells still running · after 14m"),
        ]
    }

    func testRenderTheTaskListStates() throws {
        let unread = TaskEventsSnapshot.make(unreadEvents: items(), recentEvents: [], overflow: nil)
        let overflow = TaskEventOverflowNotice(dropped: 12, throughDiscoveredAt: decided, total: 12, lastDroppedAt: now)
        var withOverflow = unread
        withOverflow.overflow = overflow
        let notice = TaskEventNotice(itemID: "77aa88bb-3|p3", projectName: "agentmeter", sessionLabel: "Session 77aa88bb",
                                     reason: .appOnly,
                                     host: TaskSessionHost(pid: 1, bundleID: "com.microsoft.VSCode", name: "Visual Studio Code"),
                                     eventIDs: ["w"])
        let handledEvents = items().map { event -> AgentMeterEvent in
            var read = event
            read.readAt = decided
            return read
        }
        let handled = TaskEventsSnapshot.make(unreadEvents: [], recentEvents: handledEvents, overflow: nil)
        var many: [AgentMeterEvent] = []
        for index in 0..<7 { many.append(listEvent("m\(index)", task: "m\(index)", at: Double(index * 60))) }
        let titles = ["ffafe0d9-1": "Fix the quota pacing tooltip", "77aa88bb-3": "Phase 1c notification list"]

        let cases: [(String, TaskEventsState, TaskEventNotice?, Bool)] = [
            ("1-loading", .loading, nil, true),
            ("2-none-yet", .loaded(.empty), nil, true),
            ("3-hooks-off", .loaded(.empty), nil, false),
            ("4-unread", .loaded(unread), nil, true),
            ("5-unread-notice-overflow", .loaded(withOverflow), notice, true),
            ("6-all-handled", .loaded(handled), nil, true),
            ("7-more-unread", .loaded(TaskEventsSnapshot.make(unreadEvents: many, recentEvents: [], overflow: nil)), nil, true),
        ]
        for (name, state, notice, hooks) in cases {
            for dark in [false, true] {
                try render(TaskEventsSection(state: state, notice: notice, hooksEnabled: hooks, sessionTitles: titles, now: now)
                            .padding(12)
                            .frame(width: 340),
                           name: "list-\(name)", dark: dark)
            }
        }
    }

    func testRenderTheSettingsSections() throws {
        let cases: [(String, AgentMeterNotificationSettings, UNAuthorizationStatus)] = [
            ("banners", .init(authorization: .authorized, alertStyle: .banner, lockScreen: .enabled, previews: .always), .authorized),
            ("persistent", .init(authorization: .authorized, alertStyle: .alert, lockScreen: .enabled,
                                 previews: .whenAuthenticated), .authorized),
            ("denied", .init(authorization: .denied), .denied),
            ("not-asked", .init(authorization: .notDetermined), .notDetermined),
        ]
        for (name, settings, status) in cases {
            let center = AuthorizationCenterStub(result: .success(true), status: status)
            center.settings = settings
            let manager = NotificationManager(authorizationCenter: center, bundleIdentifier: { "com.shu.agentmeter.tests" })
            try render(Form { TaskNotificationSettingsSections(manager: manager) }.formStyle(.grouped).frame(width: 460),
                       name: "settings-\(name)", dark: false, settle: 0.5)
        }
    }

    func testRenderTheMenuBarCount() throws {
        let segments: [MenuBarElement] = [
            .icon(.provider(.claude)),
            .segment(MenuBarSegment(label: "5h", value: "62%", remaining: 62, alertLevel: .none)),
            .segment(MenuBarSegment(label: "7d", value: "18%", remaining: 18, alertLevel: .warn)),
        ]
        for count in [0, 1, 7, 23, 120] {
            for dark in [false, true] {
                for captions in [true, false] {
                    let view = MenuBarContentView()
                    view.apply(elements: segments, showCaptions: captions, fillsByUsed: false)
                    view.unreadBadge = count
                    let width = MenuBarContentView.width(elements: segments, showCaptions: captions, unreadBadge: count)
                    view.frame = NSRect(x: 0, y: 0, width: width, height: 24)
                    view.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
                    let backdrop = NSView(frame: NSRect(x: 0, y: 0, width: width + 16, height: 24))
                    backdrop.wantsLayer = true
                    backdrop.layer?.backgroundColor = (dark ? NSColor(white: 0.15, alpha: 1) : NSColor(white: 0.93, alpha: 1)).cgColor
                    backdrop.appearance = view.appearance
                    view.setFrameOrigin(NSPoint(x: 8, y: 0))
                    backdrop.addSubview(view)
                    try write(backdrop, name: "menubar-\(count)-\(captions ? "captions" : "plain")-\(dark ? "dark" : "light")")
                }
            }
        }
    }

    // MARK: - Rendering

    private func render<V: View>(_ view: V, name: String, dark: Bool, settle: TimeInterval = 0.1) throws {
        let backdrop = dark ? Color(white: 0.16) : Color(white: 0.97)
        let host = NSHostingView(rootView: view.background(backdrop).environment(\.colorScheme, dark ? .dark : .light))
        host.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
        let window = NSWindow(contentRect: NSRect(x: -10_000, y: -10_000, width: 460, height: 400),
                              styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.appearance = host.appearance
        window.backgroundColor = dark ? NSColor(white: 0.16, alpha: 1) : NSColor(white: 0.97, alpha: 1)
        window.contentView = host
        RunLoop.main.run(until: Date().addingTimeInterval(settle))
        let size = host.fittingSize
        window.setContentSize(size)
        host.frame = NSRect(origin: .zero, size: size)
        host.layoutSubtreeIfNeeded()
        RunLoop.main.run(until: Date().addingTimeInterval(0.05))
        try write(host, name: "\(name)-\(dark ? "dark" : "light")")
        window.close()
    }

    private func write(_ view: NSView, name: String) throws {
        let rep = try XCTUnwrap(view.bitmapImageRepForCachingDisplay(in: view.bounds))
        view.cacheDisplay(in: view.bounds, to: rep)
        let data = try XCTUnwrap(rep.representation(using: .png, properties: [:]))
        try data.write(to: outputDirectory.appendingPathComponent("\(name).png"))
    }
}
