import Foundation
@testable import AgentMeter
import XCTest

final class ClaudeCredentialsTests: XCTestCase {
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
