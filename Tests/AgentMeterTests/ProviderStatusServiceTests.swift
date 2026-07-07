import Foundation
@testable import AgentMeter
import XCTest

final class ProviderStatusServiceTests: XCTestCase {
    func testParsesOperationalStatus() throws {
        let result = try XCTUnwrap(ProviderStatusService.parseStatus([
            "status": ["indicator": "none", "description": "All Systems Operational"]
        ]))

        XCTAssertEqual(result.level, .operational)
        XCTAssertEqual(result.description, "All Systems Operational")
    }

    func testParsesMinorAsDegraded() throws {
        let result = try XCTUnwrap(ProviderStatusService.parseStatus([
            "status": ["indicator": "minor", "description": "Partial System Degradation"]
        ]))

        XCTAssertEqual(result.level, .degraded)
    }

    func testParsesMajorAndCriticalAsOutage() throws {
        for indicator in ["major", "critical"] {
            let result = try XCTUnwrap(ProviderStatusService.parseStatus(["status": ["indicator": indicator]]))
            XCTAssertEqual(result.level, .outage, "indicator \(indicator) should map to outage")
        }
    }

    func testUnknownIndicatorDefaultsToOperationalRatherThanFailing() throws {
        let result = try XCTUnwrap(ProviderStatusService.parseStatus(["status": ["indicator": "something_new"]]))
        XCTAssertEqual(result.level, .operational)
    }

    func testMissingStatusKeyReturnsNil() {
        XCTAssertNil(ProviderStatusService.parseStatus(["components": []]))
    }

    func testMissingIndicatorReturnsNil() {
        XCTAssertNil(ProviderStatusService.parseStatus(["status": ["description": "no indicator here"]]))
    }

    func testDescriptionStripsNewlinesAndControlCharacters() {
        let sanitized = ProviderStatusService.sanitizedDescription("Line one\nLine two\r\ntab\there")
        XCTAssertEqual(sanitized, "Line one Line two tab here")
    }

    func testDescriptionIsCappedAtMaxLength() {
        let raw = String(repeating: "x", count: 500)
        let sanitized = ProviderStatusService.sanitizedDescription(raw)
        XCTAssertEqual(sanitized?.count, 200)
    }

    func testNilDescriptionStaysNil() {
        XCTAssertNil(ProviderStatusService.sanitizedDescription(nil))
    }

    func testWhitespaceOnlyDescriptionBecomesNil() {
        XCTAssertNil(ProviderStatusService.sanitizedDescription("   \n\t  "))
    }

    func testParseStatusAppliesSanitizationToDescription() throws {
        let result = try XCTUnwrap(ProviderStatusService.parseStatus([
            "status": ["indicator": "minor", "description": "Degraded\nperformance\ndetected"]
        ]))

        XCTAssertEqual(result.description, "Degraded performance detected")
    }
}
