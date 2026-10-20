import Foundation
@testable import AgentMeter
import XCTest

final class ClaudeCLIScraperTests: XCTestCase {
    private let windows = [QuotaWindow(id: "five_hour", label: "5-hour", usedPercent: 40, resetsAt: nil)]
    private let fetchedAt = Date(timeIntervalSince1970: 1_782_000_000)

    /// The scraped panel names no plan, so the snapshot carries what the
    /// login credential said; before, every scrape tick dropped the badge.
    func testSnapshotCarriesTheCredentialPlanAndTier() {
        let snapshot = ClaudeCLIScraper.snapshot(
            windows: windows, planType: "team", rateLimitTier: "default_claude_max_5x", fetchedAt: fetchedAt
        )

        XCTAssertEqual(snapshot.source, .cli)
        XCTAssertEqual(snapshot.planType, "team")
        XCTAssertEqual(snapshot.rateLimitTier, "default_claude_max_5x")
        XCTAssertEqual(snapshot.planBadge?.text, "TEAM PREMIUM")
    }

    func testSnapshotWithoutACredentialCarriesNoPlan() {
        let snapshot = ClaudeCLIScraper.snapshot(
            windows: windows, planType: nil, rateLimitTier: nil, fetchedAt: fetchedAt
        )

        XCTAssertEqual(snapshot.source, .cli)
        XCTAssertNil(snapshot.planType)
        XCTAssertNil(snapshot.planBadge)
    }

    // MARK: - A panel that only repeats Claude Code's cache

    /// `~/.claude.json` as Claude Code writes it: the last `/api/oauth/usage`
    /// body it fetched, under the time it fetched it.
    private func config(fetchedAt: Date?, fiveHour: Double? = 0, sevenDay: Double? = 57) -> [String: Any] {
        var utilization: [String: Any] = ["seven_day_opus": NSNull()]
        if let fiveHour { utilization["five_hour"] = ["utilization": fiveHour, "resets_at": NSNull()] }
        if let sevenDay { utilization["seven_day"] = ["utilization": sevenDay, "resets_at": "2025-01-24T12:00:00.123456+00:00"] }
        var cache: [String: Any] = ["accountUuid": "uuid", "utilization": utilization]
        if let fetchedAt { cache["fetchedAtMs"] = fetchedAt.timeIntervalSince1970 * 1000 }
        return ["numStartups": 3, "cachedUsageUtilization": cache]
    }

    /// What `claude /usage` prints on a pipe (print mode, 2.1.301): no
    /// panel, and nothing that says whether the numbers were read now or
    /// come from its cache. A model-scoped weekly the plan allows (Fable here)
    /// prints as a row of its own.
    private func printed(fiveHour: Double = 0, sevenDay: Double = 57, scoped: [(String, Double)] = [("Fable", 91)]) -> String {
        var lines = [
            "You are currently using your subscription to power your Claude Code usage",
            "",
            "Current session: \(Int(fiveHour))% used · resets Jan 20, 10am (Asia/Tokyo)",
            "Current week (all models): \(Int(sevenDay))% used · resets Jan 24, 9pm (Asia/Tokyo)",
        ]
        lines += scoped.map { "Current week (\($0.0)): \(Int($0.1))% used · resets Jan 24, 9pm (Asia/Tokyo)" }
        return lines.joined(separator: "\n")
    }

    private func scraped(fiveHour: Double = 0, sevenDay: Double = 57) -> [QuotaWindow] {
        ClaudeCLIScraper.parse(printed(fiveHour: fiveHour, sevenDay: sevenDay))
    }

    /// A CLI scrape that repeats the cache keeps the cache’s reading time.
    func testPanelRepeatingTheCacheIsDatedByTheCache() {
        let cachedOn = Date(timeIntervalSince1970: 1_737_302_400)
        let scrapedAt = cachedOn.addingTimeInterval(2 * 86_400 + 6 * 3_600)
        let windows = scraped()
        XCTAssertEqual(windows.map(\.id), ["five_hour", "seven_day"])

        let cachedAt = ClaudeCLIScraper.cachedReadingTime(matching: windows, config: config(fetchedAt: cachedOn))
        XCTAssertEqual(cachedAt, cachedOn)

        let snapshot = ClaudeCLIScraper.snapshot(windows: windows, planType: "max", rateLimitTier: nil,
                                                 fetchedAt: scrapedAt, cachedAt: cachedAt)
        XCTAssertEqual(snapshot.fetchedAt, scrapedAt, "the fetch time stays the fetch time")
        XCTAssertEqual(snapshot.readingTime, cachedOn)
        XCTAssertTrue(snapshot.echoesStaleCache)
    }

    /// The CLI's own read succeeded and rewrote the cache just before the
    /// panel printed: a current reading.
    func testPanelMatchingAFreshCacheIsCurrent() {
        let scrapedAt = Date(timeIntervalSince1970: 1_792_400_000)
        let windows = scraped()
        let cachedAt = ClaudeCLIScraper.cachedReadingTime(
            matching: windows, config: config(fetchedAt: scrapedAt.addingTimeInterval(-4)))
        let snapshot = ClaudeCLIScraper.snapshot(windows: windows, planType: nil, rateLimitTier: nil,
                                                 fetchedAt: scrapedAt, cachedAt: cachedAt)

        XCTAssertEqual(snapshot.readingTime, scrapedAt.addingTimeInterval(-4))
        XCTAssertFalse(snapshot.echoesStaleCache)
    }

    func testPanelThatDiffersFromTheCacheWasReadLive() {
        let cachedOn = Date(timeIntervalSince1970: 1_737_302_400)
        XCTAssertNil(ClaudeCLIScraper.cachedReadingTime(
            matching: scraped(fiveHour: 2, sevenDay: 58), config: config(fetchedAt: cachedOn)))
        XCTAssertNil(ClaudeCLIScraper.cachedReadingTime(
            matching: scraped(fiveHour: 0, sevenDay: 58), config: config(fetchedAt: cachedOn)),
            "one window off is enough")
    }

    /// The panel prints whole percents; the cache may hold a fraction.
    func testPanelRoundingOfACachedFractionStillMatches() {
        let cachedOn = Date(timeIntervalSince1970: 1_737_302_400)
        XCTAssertEqual(ClaudeCLIScraper.cachedReadingTime(
            matching: scraped(fiveHour: 0, sevenDay: 57), config: config(fetchedAt: cachedOn, sevenDay: 56.6)), cachedOn)
    }

    func testNoUsableCacheMeansNoCacheTime() {
        let cachedOn = Date(timeIntervalSince1970: 1_737_302_400)
        let windows = scraped()
        XCTAssertNil(ClaudeCLIScraper.cachedReadingTime(matching: windows, config: nil))
        XCTAssertNil(ClaudeCLIScraper.cachedReadingTime(matching: windows, config: ["numStartups": 3]))
        XCTAssertNil(ClaudeCLIScraper.cachedReadingTime(matching: windows, config: config(fetchedAt: nil)),
                     "no fetch time")
        XCTAssertNil(ClaudeCLIScraper.cachedReadingTime(matching: windows, config: config(fetchedAt: Date(timeIntervalSince1970: 0))),
                     "a zero fetch time")
        XCTAssertEqual(ClaudeCLIScraper.cachedReadingTime(matching: windows, config: config(fetchedAt: cachedOn, sevenDay: nil)),
                       cachedOn, "a row the cache has no figure for does not decide; the rest still match")
        XCTAssertNil(ClaudeCLIScraper.cachedReadingTime(matching: [], config: config(fetchedAt: cachedOn)))
    }

    // MARK: - Print-mode rows the named keys do not hold

    /// A model-scoped weekly prints as `Current week (Opus …)`, which `parse`
    /// files under `seven_day_opus` — a key the cache leaves null, its figure
    /// sitting in `limits[]`. It is compared there, so the echo is still dated.
    func testScopedWeeklyRowIsComparedWithItsLimit() {
        let cachedOn = Date(timeIntervalSince1970: 1_737_390_000)
        let windows = ClaudeCLIScraper.parse(printed(fiveHour: 92, sevenDay: 83, scoped: [("Opus 5.5", 40)]))
        XCTAssertEqual(windows.map(\.id), ["five_hour", "seven_day", "seven_day_opus"])
        var cache = config(fetchedAt: cachedOn, fiveHour: 92, sevenDay: 83)
        var usage = (cache["cachedUsageUtilization"] as! [String: Any])
        var utilization = usage["utilization"] as! [String: Any]
        utilization["limits"] = [
            ["kind": "session", "percent": 92, "scope": NSNull()],
            ["kind": "weekly_scoped", "percent": 40, "scope": ["model": ["id": NSNull(), "display_name": "Opus 5.5"]]],
        ]
        usage["utilization"] = utilization
        cache["cachedUsageUtilization"] = usage

        XCTAssertEqual(ClaudeCLIScraper.cachedReadingTime(matching: windows, config: cache), cachedOn)

        var moved = utilization
        moved["limits"] = [["kind": "weekly_scoped", "percent": 47, "scope": ["model": ["display_name": "Opus 5.5"]]]]
        usage["utilization"] = moved
        cache["cachedUsageUtilization"] = usage
        XCTAssertNil(ClaudeCLIScraper.cachedReadingTime(matching: windows, config: cache), "the scoped row differs: live")
    }

    /// A row the cache holds no figure for at all neither dates nor clears
    /// the reading; the rows it does hold decide.
    func testRowWithoutACachedFigureDoesNotDecide() {
        let cachedOn = Date(timeIntervalSince1970: 1_737_390_000)
        let windows = ClaudeCLIScraper.parse(printed(fiveHour: 92, sevenDay: 83, scoped: [("Sonnet only", 12)]))
        XCTAssertEqual(windows.map(\.id), ["five_hour", "seven_day", "seven_day_sonnet"])

        XCTAssertEqual(ClaudeCLIScraper.cachedReadingTime(
            matching: windows, config: config(fetchedAt: cachedOn, fiveHour: 92, sevenDay: 83)), cachedOn)
        XCTAssertNil(ClaudeCLIScraper.cachedReadingTime(
            matching: Array(windows.suffix(1)), config: config(fetchedAt: cachedOn, fiveHour: 92, sevenDay: 83)),
            "nothing left to compare")
    }

    /// Claude Code reads a non-empty legacy `.config.json` in its config
    /// home before `.claude.json`; the cache has to be read where it wrote it.
    func testConfigIsFoundWhereClaudeCodeKeepsIt() throws {
        let home = FileManager.default.temporaryDirectory.resolvingSymlinksInPath()
            .appendingPathComponent("claude-config-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: home) }
        let configHome = home.appendingPathComponent(".claude", isDirectory: true)
        try FileManager.default.createDirectory(at: configHome, withIntermediateDirectories: true)

        XCTAssertEqual(ClaudeCLIScraper.claudeConfigURL(environment: [:], home: home).path,
                       home.appendingPathComponent(".claude.json").path)
        try Data().write(to: configHome.appendingPathComponent(".config.json"))
        XCTAssertEqual(ClaudeCLIScraper.claudeConfigURL(environment: [:], home: home).path,
                       home.appendingPathComponent(".claude.json").path, "an empty legacy file is not used")
        try Data("{}".utf8).write(to: configHome.appendingPathComponent(".config.json"))
        XCTAssertEqual(ClaudeCLIScraper.claudeConfigURL(environment: [:], home: home).path,
                       configHome.appendingPathComponent(".config.json").path)

        let custom = home.appendingPathComponent("custom", isDirectory: true)
        XCTAssertEqual(ClaudeCLIScraper.claudeConfigURL(environment: ["CLAUDE_CONFIG_DIR": custom.path], home: home).path,
                       custom.appendingPathComponent(".claude.json").path)
        XCTAssertEqual(ClaudeCLIScraper.claudeConfigURL(
            environment: ["CLAUDE_CONFIG_DIR": custom.path, "CLAUDE_CODE_CUSTOM_OAUTH_URL": "https://example.invalid"],
            home: home).path,
            custom.appendingPathComponent(".claude-custom-oauth.json").path)
    }

    /// Claude Code stats the legacy file through a symlink, and only a
    /// non-empty regular file counts.
    func testLegacyConfigIsJudgedThroughItsSymlink() throws {
        let fm = FileManager.default
        let home = fm.temporaryDirectory.resolvingSymlinksInPath()
            .appendingPathComponent("claude-config-\(UUID().uuidString)", isDirectory: true)
        defer { try? fm.removeItem(at: home) }
        let configHome = home.appendingPathComponent(".claude", isDirectory: true)
        try fm.createDirectory(at: configHome, withIntermediateDirectories: true)
        let target = home.appendingPathComponent("empty.json")
        try Data().write(to: target)
        try fm.createSymbolicLink(at: configHome.appendingPathComponent(".config.json"), withDestinationURL: target)

        XCTAssertEqual(ClaudeCLIScraper.claudeConfigURL(environment: [:], home: home).path,
                       home.appendingPathComponent(".claude.json").path, "a link to an empty file is an empty file")
        try Data("{}".utf8).write(to: target)
        XCTAssertEqual(ClaudeCLIScraper.claudeConfigURL(environment: [:], home: home).path,
                       configHome.appendingPathComponent(".config.json").path)
    }

    /// Every other reading carries no cache time and is dated by its fetch.
    func testReadingWithoutACacheTimeIsDatedByItsFetch() {
        let snapshot = ClaudeCLIScraper.snapshot(windows: windows, planType: nil, rateLimitTier: nil, fetchedAt: fetchedAt)
        XCTAssertNil(snapshot.cachedAt)
        XCTAssertEqual(snapshot.readingTime, fetchedAt)
        XCTAssertFalse(snapshot.echoesStaleCache)
    }
}
