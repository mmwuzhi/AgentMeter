import Foundation
@testable import AgentMeter
import XCTest

final class ClaudeCredentialsTests: XCTestCase {
    func testConcurrentCacheMissesShareOneCredentialLoad() async throws {
        await ClaudeCredentials.invalidate()
        let probe = BlockingCredentialLoader()

        let first = Task {
            await ClaudeCredentials.load(using: { probe.load() })
        }
        await fulfillment(of: [probe.firstStarted], timeout: 1)

        let second = Task {
            await ClaudeCredentials.load(using: { probe.load() })
        }
        await fulfillment(of: [probe.duplicateStarted], timeout: 0.25)

        probe.releaseLoads(2)
        let firstToken = await first.value
        let secondToken = await second.value
        await ClaudeCredentials.invalidate()

        XCTAssertEqual(probe.invocationCount, 1)
        XCTAssertEqual(firstToken?.accessToken, "token")
        XCTAssertEqual(secondToken?.accessToken, "token")
    }

    func testZeroExpiryIsTreatedAsUnknown() throws {
        let data = Data(#"{"claudeAiOauth":{"accessToken":"token","refreshToken":"refresh","expiresAt":0}}"#.utf8)

        let token = try XCTUnwrap(ClaudeCredentials.parse(data))

        XCTAssertNil(token.expiresAt)
        XCTAssertFalse(token.isExpired)
    }

    func testPositiveMillisecondExpiryIsParsed() throws {
        let milliseconds = 2_000_000_000_000.0
        let data = Data(#"{"claudeAiOauth":{"accessToken":"token","expiresAt":2000000000000}}"#.utf8)

        let token = try XCTUnwrap(ClaudeCredentials.parse(data))

        XCTAssertEqual(
            try XCTUnwrap(token.expiresAt).timeIntervalSince1970,
            milliseconds / 1_000,
            accuracy: 0.001
        )
    }

    func testParseReadsSubscriptionType() throws {
        let data = Data(#"{"claudeAiOauth":{"accessToken":"token","refreshToken":"refresh","expiresAt":2000000000000,"subscriptionType":"team"}}"#.utf8)

        let token = try XCTUnwrap(ClaudeCredentials.parse(data))

        XCTAssertEqual(token.accessToken, "token")
        XCTAssertEqual(token.subscriptionType, "team")
    }

    func testParseWithoutSubscriptionTypeLeavesItNil() throws {
        let data = Data(#"{"claudeAiOauth":{"accessToken":"token","expiresAt":0}}"#.utf8)

        let token = try XCTUnwrap(ClaudeCredentials.parse(data))

        XCTAssertNil(token.subscriptionType)
    }

    func testParseDropsBlankSubscriptionType() throws {
        let data = Data(#"{"claudeAiOauth":{"accessToken":"token","subscriptionType":"   "}}"#.utf8)

        let token = try XCTUnwrap(ClaudeCredentials.parse(data))

        XCTAssertNil(token.subscriptionType)
    }

    func testParseLowercasesSubscriptionType() throws {
        let data = Data(#"{"claudeAiOauth":{"accessToken":"token","subscriptionType":"Team"}}"#.utf8)

        let token = try XCTUnwrap(ClaudeCredentials.parse(data))

        XCTAssertEqual(token.subscriptionType, "team")
    }

    /// One grapheme cluster can stack thousands of combining marks: a
    /// cluster count let 100 KB through as "four characters".
    func testParseBoundsSubscriptionTypeInBytesNotGraphemes() throws {
        let bomb = "t" + String(repeating: "\u{0301}", count: 5_000) + "eam"
        let data = Data(#"{"claudeAiOauth":{"accessToken":"token","subscriptionType":"\#(bomb)"}}"#.utf8)

        let token = try XCTUnwrap(ClaudeCredentials.parse(data))

        XCTAssertEqual(token.accessToken, "token", "a bad plan never costs the token")
        XCTAssertNil(token.subscriptionType)
    }

    /// An embedded newline, a NUL and a bidi override each survived
    /// end-trimming and would have reached the badge and the cache.
    func testParseDropsSubscriptionTypeWithControlOrFormatCharacters() throws {
        for hostile in ["pro\\nmax", "te\\u0000am", "\\u202Exam"] {
            let json = "{\"claudeAiOauth\":{\"accessToken\":\"token\",\"subscriptionType\":\"\(hostile)\"}}"

            let token = try XCTUnwrap(ClaudeCredentials.parse(Data(json.utf8)), hostile)

            XCTAssertNil(token.subscriptionType, hostile)
        }
    }

    /// The badge shows an ASCII name or nothing: a plan outside
    /// `PlanLabel.pattern` is treated as unstated.
    func testParseDropsSubscriptionTypeOutsideTheAllowList() throws {
        let cases: [(String, String?)] = [
            ("prö", nil), ("pro!", nil), ("team-premium", "team-premium"), ("max 20x", "max 20x")
        ]
        for (raw, expected) in cases {
            let json = "{\"claudeAiOauth\":{\"accessToken\":\"token\",\"subscriptionType\":\"\(raw)\"}}"

            let token = try XCTUnwrap(ClaudeCredentials.parse(Data(json.utf8)), raw)

            XCTAssertEqual(token.subscriptionType, expected, raw)
        }
    }

    func testParseReadsRateLimitTier() throws {
        let data = Data(#"{"claudeAiOauth":{"accessToken":"token","subscriptionType":"team","rateLimitTier":"default_claude_max_5x"}}"#.utf8)

        let token = try XCTUnwrap(ClaudeCredentials.parse(data))

        XCTAssertEqual(token.rateLimitTier, "default_claude_max_5x")
    }

    /// The tier is checked against Claude Code's own `^[a-z][a-z0-9_]{0,63}$`
    /// before it can reach a tooltip: spaces, punctuation or an oversized value
    /// leave it nil, and never reject the token itself.
    func testParseRejectsMalformedRateLimitTier() throws {
        let punctuated = Data(#"{"claudeAiOauth":{"accessToken":"token","rateLimitTier":"Default Tier!"}}"#.utf8)
        let seventyChars = String(repeating: "a", count: 70)
        let oversized = Data(#"{"claudeAiOauth":{"accessToken":"token","rateLimitTier":"\#(seventyChars)"}}"#.utf8)

        XCTAssertNil(try XCTUnwrap(ClaudeCredentials.parse(punctuated)).rateLimitTier)
        XCTAssertNil(try XCTUnwrap(ClaudeCredentials.parse(oversized)).rateLimitTier)
    }

    func testParseLowercasesRateLimitTier() throws {
        let data = Data(#"{"claudeAiOauth":{"accessToken":"token","rateLimitTier":" Default_Claude_Max_5x\n"}}"#.utf8)

        let token = try XCTUnwrap(ClaudeCredentials.parse(data))

        XCTAssertEqual(token.rateLimitTier, "default_claude_max_5x")
    }

    func testParseWithoutRateLimitTierLeavesItNil() throws {
        let data = Data(#"{"claudeAiOauth":{"accessToken":"token","subscriptionType":"team"}}"#.utf8)

        let token = try XCTUnwrap(ClaudeCredentials.parse(data))

        XCTAssertNil(token.rateLimitTier)
    }
}

private final class BlockingCredentialLoader: @unchecked Sendable {
    let firstStarted = XCTestExpectation(description: "first credential load started")
    let duplicateStarted: XCTestExpectation = {
        let expectation = XCTestExpectation(description: "duplicate credential load did not start")
        expectation.isInverted = true
        return expectation
    }()

    private let lock = NSLock()
    private let gate = DispatchSemaphore(value: 0)
    private var count = 0

    var invocationCount: Int {
        lock.withLock { count }
    }

    func load() -> ClaudeCredentials.Token? {
        let invocation = lock.withLock {
            count += 1
            return count
        }
        if invocation == 1 {
            firstStarted.fulfill()
        } else {
            duplicateStarted.fulfill()
        }
        gate.wait()
        return ClaudeCredentials.Token(accessToken: "token", refreshToken: nil, expiresAt: nil)
    }

    func releaseLoads(_ count: Int) {
        for _ in 0..<count {
            gate.signal()
        }
    }
}
