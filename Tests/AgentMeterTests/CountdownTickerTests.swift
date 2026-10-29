import Foundation
@testable import AgentMeter
import XCTest

@MainActor
final class CountdownTickerTests: XCTestCase {
    private var ticks = 0
    private lazy var ticker = CountdownTicker { [weak self] in self?.ticks += 1 }

    override func tearDown() {
        ticker.stop()
        super.tearDown()
    }

    /// Spins the main run loop for `seconds`, in the given mode. One `run` call
    /// returns after the first event it handles, so it is repeated to the end.
    private func spin(_ seconds: TimeInterval, mode: RunLoop.Mode = .default) {
        let end = Date().addingTimeInterval(seconds)
        while Date() < end {
            RunLoop.main.run(mode: mode, before: min(end, Date().addingTimeInterval(0.01)))
        }
    }

    /// Spins until `condition` holds, for as long as `timeout`: the positive
    /// checks wait for the event instead of betting on how long it takes.
    @discardableResult
    private func spin(until condition: () -> Bool, timeout: TimeInterval = 5, mode: RunLoop.Mode = .default) -> Bool {
        let end = Date().addingTimeInterval(timeout)
        while !condition(), Date() < end {
            RunLoop.main.run(mode: mode, before: min(end, Date().addingTimeInterval(0.01)))
        }
        return condition()
    }

    func testFiresOnceAtTheGivenInstant() async {
        let fired = expectation(description: "tick")
        let ticker = CountdownTicker { fired.fulfill() }

        ticker.arm(at: Date().addingTimeInterval(0.05))
        XCTAssertTrue(ticker.isArmed)

        await fulfillment(of: [fired], timeout: 2)
        XCTAssertFalse(ticker.isArmed, "a one-shot timer is spent after it fires")
    }

    func testAnInstantAlreadyPastFiresPromptly() async {
        let fired = expectation(description: "tick")
        let ticker = CountdownTicker { fired.fulfill() }

        ticker.arm(at: Date().addingTimeInterval(-60))

        await fulfillment(of: [fired], timeout: 2)
    }

    func testArmingAgainReplacesThePendingTick() {
        ticker.arm(at: Date().addingTimeInterval(0.05))
        ticker.arm(at: Date().addingTimeInterval(30))

        spin(0.5)

        XCTAssertEqual(ticks, 0, "the first tick was replaced, the second is 30 s away")
        XCTAssertTrue(ticker.isArmed)
    }

    func testReArmingFromTheTickKeepsItCounting() {
        // What the status item does: every render arms the next change.
        var remaining = 3
        var count = 0
        var chain: CountdownTicker!
        chain = CountdownTicker {
            count += 1
            remaining -= 1
            chain.arm(at: remaining > 0 ? Date().addingTimeInterval(0.02) : nil)
        }

        chain.arm(at: Date().addingTimeInterval(0.02))
        spin(until: { count == 3 })
        spin(0.3)

        XCTAssertEqual(count, 3, "three ticks and no fourth")
        XCTAssertFalse(chain.isArmed, "no next change, so nothing stays scheduled")
    }

    func testNilStopsIt() {
        ticker.arm(at: Date().addingTimeInterval(0.05))
        ticker.arm(at: nil)

        spin(0.4)

        XCTAssertEqual(ticks, 0)
        XCTAssertFalse(ticker.isArmed)
    }

    func testStopCancelsThePendingTick() {
        ticker.arm(at: Date().addingTimeInterval(0.05))
        ticker.stop()

        spin(0.4)

        XCTAssertEqual(ticks, 0)
    }

    func testKeepsTickingWhileAMenuTracksTheMouse() {
        // Menu tracking runs the loop in the event-tracking mode only. AppKit
        // makes that a common mode of the main loop; a test process has no
        // NSApplication to do it, so it is added here.
        CFRunLoopAddCommonMode(CFRunLoopGetMain(), CFRunLoopMode(RunLoop.Mode.eventTracking.rawValue as CFString))

        ticker.arm(at: Date().addingTimeInterval(0.05))
        spin(until: { self.ticks == 1 }, mode: .eventTracking)

        XCTAssertEqual(ticks, 1)
    }

    func testATimerForTheDefaultModeAloneWouldFreezeWhileAMenuTracksTheMouse() {
        // The control for the test above: the same wait, with a timer that
        // is not in the common modes, does not fire.
        CFRunLoopAddCommonMode(CFRunLoopGetMain(), CFRunLoopMode(RunLoop.Mode.eventTracking.rawValue as CFString))
        let fired = FiredFlag()
        let timer = Timer(fire: Date().addingTimeInterval(0.05), interval: 0, repeats: false) { _ in fired.set() }
        RunLoop.main.add(timer, forMode: .default)

        spin(0.6, mode: .eventTracking)

        XCTAssertFalse(fired.value)
        timer.invalidate()
    }
}

private final class FiredFlag: @unchecked Sendable {
    private let lock = NSLock()
    private var flag = false
    var value: Bool { lock.lock(); defer { lock.unlock() }; return flag }
    func set() { lock.lock(); flag = true; lock.unlock() }
}
