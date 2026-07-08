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

    // MARK: - Component-filtered reading

    /// The real payload observed live: a FedRAMP-only incident flips the page
    /// indicator to minor while every Codex component stays operational. The
    /// component reading must stay operational so the banner doesn't show.
    func testIrrelevantIncidentKeepsComponentLevelOperational() throws {
        let result = try XCTUnwrap(ProviderStatusService.parseStatus([
            "status": ["indicator": "minor", "description": "Partial System Degradation"],
            "components": [
                ["id": "fed", "name": "FedRAMP", "status": "degraded_performance"],
                ["id": "cw", "name": "Codex Web", "status": "operational"],
                ["id": "ca", "name": "Codex API", "status": "operational"]
            ],
            "incidents": [["name": "FedRAMP workspaces not working", "components": []]]
        ], relevantComponentKeywords: ["codex"]))

        XCTAssertEqual(result.level, .degraded)
        XCTAssertEqual(result.componentLevel, .operational)
    }

    func testRelevantComponentDegradedSurfacesIncidentName() throws {
        let result = try XCTUnwrap(ProviderStatusService.parseStatus([
            "status": ["indicator": "minor", "description": "Partial System Degradation"],
            "components": [
                ["id": "ca", "name": "Codex API", "status": "degraded_performance"],
                ["id": "sora", "name": "Sora", "status": "operational"]
            ],
            "incidents": [
                ["name": "Sora slow", "components": [["id": "sora", "name": "Sora"]]],
                ["name": "Codex API elevated errors", "components": [["id": "ca", "name": "Codex API"]]]
            ]
        ], relevantComponentKeywords: ["codex"]))

        XCTAssertEqual(result.componentLevel, .degraded)
        XCTAssertEqual(result.componentDescription, "Codex API elevated errors")
    }

    func testRelevantComponentDegradedWithoutTaggedIncidentFallsBackToPageDescription() throws {
        let result = try XCTUnwrap(ProviderStatusService.parseStatus([
            "status": ["indicator": "minor", "description": "Partial System Degradation"],
            "components": [["id": "ca", "name": "Codex API", "status": "degraded_performance"]],
            "incidents": [["name": "Something broke", "components": []]]
        ], relevantComponentKeywords: ["codex"]))

        XCTAssertEqual(result.componentLevel, .degraded)
        XCTAssertEqual(result.componentDescription, "Partial System Degradation")
    }

    func testWorstMatchedComponentWins() throws {
        let result = try XCTUnwrap(ProviderStatusService.parseStatus([
            "status": ["indicator": "major"],
            "components": [
                ["id": "cw", "name": "Codex Web", "status": "operational"],
                ["id": "ca", "name": "Codex API", "status": "major_outage"]
            ]
        ], relevantComponentKeywords: ["codex"]))

        XCTAssertEqual(result.componentLevel, .outage)
    }

    func testMissingComponentDataMirrorsPageLevel() throws {
        let result = try XCTUnwrap(ProviderStatusService.parseStatus([
            "status": ["indicator": "minor", "description": "Partial System Degradation"]
        ], relevantComponentKeywords: ["codex"]))

        XCTAssertEqual(result.componentLevel, .degraded)
        XCTAssertEqual(result.componentDescription, "Partial System Degradation")
    }

    func testNoMatchingComponentsMirrorsPageLevel() throws {
        let result = try XCTUnwrap(ProviderStatusService.parseStatus([
            "status": ["indicator": "minor"],
            "components": [["id": "x", "name": "Renamed Beyond Recognition", "status": "operational"]]
        ], relevantComponentKeywords: ["codex"]))

        XCTAssertEqual(result.componentLevel, .degraded)
    }

    func testComponentKeywordMatchIsCaseInsensitive() throws {
        let result = try XCTUnwrap(ProviderStatusService.parseStatus([
            "status": ["indicator": "minor"],
            "components": [["id": "cc", "name": "CLAUDE CODE", "status": "partial_outage"]]
        ], relevantComponentKeywords: ["claude code"]))

        XCTAssertEqual(result.componentLevel, .outage)
    }

    func testComponentStatusMapping() {
        XCTAssertEqual(ProviderStatusService.level(forComponentStatus: "operational"), .operational)
        XCTAssertEqual(ProviderStatusService.level(forComponentStatus: "degraded_performance"), .degraded)
        XCTAssertEqual(ProviderStatusService.level(forComponentStatus: "under_maintenance"), .degraded)
        XCTAssertEqual(ProviderStatusService.level(forComponentStatus: "partial_outage"), .outage)
        XCTAssertEqual(ProviderStatusService.level(forComponentStatus: "major_outage"), .outage)
        XCTAssertEqual(ProviderStatusService.level(forComponentStatus: "brand_new_status"), .operational)
        XCTAssertEqual(ProviderStatusService.level(forComponentStatus: nil), .operational)
    }
}
