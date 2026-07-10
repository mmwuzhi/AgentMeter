import Foundation
@testable import AgentMeter
import XCTest

final class AgentAppActivatorTests: XCTestCase {
    func testParentPIDResolvesForCurrentProcess() {
        let parent = AgentAppActivator.parentPID(of: getpid())
        XCTAssertNotNil(parent)
        XCTAssertGreaterThan(parent ?? -1, 0)
    }

    func testParentPIDReturnsNilForBogusPID() {
        XCTAssertNil(AgentAppActivator.parentPID(of: -2))
    }
}
