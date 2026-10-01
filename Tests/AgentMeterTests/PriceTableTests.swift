import Foundation
@testable import AgentMeter
import XCTest

final class PriceTableTests: XCTestCase {
    private func price(_ input: Double, output: Double = 0) -> ModelPrice {
        ModelPrice(input: input, output: output, cacheWrite5m: 0, cacheWrite1h: 0, cacheRead: 0)
    }

    func testExactIDWinsOverAPrefix() {
        let table = PriceTable(models: [
            "claude-opus-4": price(1),
            "claude-opus-4-8": price(2),
            "claude-opus-4-8-20260101": price(3),
        ])

        XCTAssertEqual(table.price(for: "claude-opus-4-8-20260101").input, 3)
    }

    /// A dated id out of a transcript must land on its own model, not on the
    /// shorter family key that is a prefix of it too.
    func testLongestMatchingPrefixWins() {
        let table = PriceTable(models: [
            "claude-opus-4": price(1),
            "claude-opus-4-8": price(2),
        ])

        XCTAssertEqual(table.price(for: "claude-opus-4-8-20260101").input, 2)
    }

    /// The match runs the other way as well — a bare family id finds a key it
    /// is a prefix of — but only once nothing matches it exactly.
    func testRequestThatPrefixesAKeyFindsItOnlyWithoutAnExactKey() {
        let without = PriceTable(models: ["claude-opus-5-5": price(4)])
        XCTAssertEqual(without.price(for: "claude-opus-5").input, 4)

        let with = PriceTable(models: [
            "claude-opus-5-5": price(4),
            "claude-opus-5": price(5),
        ])
        XCTAssertEqual(with.price(for: "claude-opus-5").input, 5)
    }

    /// Two keys of one length can only tie when the id is a prefix of both.
    /// The pick is then alphabetical, so a lookup never depends on the order a
    /// dictionary happens to iterate in.
    func testEqualLengthCandidatesResolveAlphabetically() {
        let table = PriceTable(models: [
            "claude-opus-5-9": price(9),
            "claude-opus-5-5": price(5),
        ])

        XCTAssertEqual(table.price(for: "claude-opus-5").input, 5)
    }

    func testUnknownModelFallsBackToDefaultThenToUnknownModelPrice() {
        let withDefault = PriceTable(models: ["gpt-5": price(1), "default": price(7)])
        XCTAssertEqual(withDefault.price(for: "o3-mini").input, 7)

        let withoutDefault = PriceTable(models: ["gpt-5": price(1)])
        XCTAssertEqual(withoutDefault.price(for: "o3-mini"), PriceTable.unknownModelPrice)
    }

    func testCostPricesEveryCounterPerMillionTokens() {
        let table = PriceTable(models: [
            "m": ModelPrice(input: 10, output: 50, cacheWrite5m: 12.5, cacheWrite1h: 20, cacheRead: 0.25),
        ])
        let counts = TokenCounts(input: 1_000_000, output: 100_000, cacheWrite5m: 200_000,
                                 cacheWrite1h: 50_000, cacheRead: 4_000_000)

        // 10 + 5 + 2.5 + 1 + 1
        XCTAssertEqual(table.cost(model: "m", counts: counts), 19.5, accuracy: 1e-9)
    }

    func testCostOfADaySumsEveryModelUnderItsOwnPrice() {
        let table = PriceTable(models: [
            "m": ModelPrice(input: 10, output: 50, cacheWrite5m: 12.5, cacheWrite1h: 20, cacheRead: 0.25),
            "n": ModelPrice(input: 1, output: 1, cacheWrite5m: 1, cacheWrite1h: 1, cacheRead: 1),
        ])

        let cost = table.cost([
            "m": TokenCounts(input: 1_000_000),
            "n": TokenCounts(output: 500_000),
        ])

        XCTAssertEqual(cost, 10.5, accuracy: 1e-9)
    }

    /// The bundled snapshot must know every model in current use with its own
    /// cache-read price: one missing from it prices at the `default` 3/15
    /// entry, and a launch whose network table had not arrived priced a whole
    /// ledger under that — the all-time total moved by $1,400 with no usage
    /// behind it. Pinned on the bundle alone, so the machine's cached network
    /// table cannot mask a wrong snapshot; the values are the official page's.
    func testBundledTableCarriesTheModelsInUse() throws {
        let models = PricingService.bundledTable().models

        let fable = try XCTUnwrap(models["claude-fable-5-1"])
        XCTAssertEqual(fable.input, 10, accuracy: 1e-9)
        XCTAssertEqual(fable.cacheRead, 0.25, accuracy: 1e-9)

        let opus5 = try XCTUnwrap(models["claude-opus-5"])
        XCTAssertEqual(opus5.input, 5, accuracy: 1e-9)
        XCTAssertEqual(opus5.output, 25, accuracy: 1e-9)

        let sonnet5 = try XCTUnwrap(models["claude-sonnet-5"])
        XCTAssertEqual(sonnet5.input, 2, accuracy: 1e-9)
        XCTAssertEqual(sonnet5.output, 10, accuracy: 1e-9)

        let opus55 = try XCTUnwrap(models["claude-opus-5-5"])
        XCTAssertEqual(opus55.cacheRead, 0.2, accuracy: 1e-9)
    }
}
