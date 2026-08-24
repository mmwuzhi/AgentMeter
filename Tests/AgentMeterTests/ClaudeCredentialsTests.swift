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
