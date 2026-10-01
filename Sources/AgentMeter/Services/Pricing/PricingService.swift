import Foundation

/// Normalized price for a model, USD per 1,000,000 tokens.
struct ModelPrice: Codable, Sendable, Equatable {
    var input: Double
    var output: Double
    var cacheWrite5m: Double
    var cacheWrite1h: Double
    var cacheRead: Double
}

/// Token counts for one accounting unit: a message, or one model's share of a
/// day. Codable because the spend ledger stores these, not dollars.
struct TokenCounts: Codable, Sendable, Equatable {
    var input = 0
    var output = 0
    var cacheWrite5m = 0
    var cacheWrite1h = 0
    var cacheRead = 0

    var total: Int { input + output + cacheWrite5m + cacheWrite1h + cacheRead }

    mutating func add(_ other: TokenCounts) {
        input += other.input
        output += other.output
        cacheWrite5m += other.cacheWrite5m
        cacheWrite1h += other.cacheWrite1h
        cacheRead += other.cacheRead
    }
}

extension TokenCounts {
    /// A missing key reads as zero. `LifetimeSpendStore` decodes the ledger as
    /// one array, so a single count written before a field existed, or by a
    /// build that left one out, would otherwise fail every record — and the
    /// first save after launch would overwrite the file with only the days
    /// the scanner can still see. Declared in an extension so the memberwise
    /// initializer stays.
    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        input = try container.decodeIfPresent(Int.self, forKey: .input) ?? 0
        output = try container.decodeIfPresent(Int.self, forKey: .output) ?? 0
        cacheWrite5m = try container.decodeIfPresent(Int.self, forKey: .cacheWrite5m) ?? 0
        cacheWrite1h = try container.decodeIfPresent(Int.self, forKey: .cacheWrite1h) ?? 0
        cacheRead = try container.decodeIfPresent(Int.self, forKey: .cacheRead) ?? 0
    }
}

/// A price table as a value. Every dollar figure the app shows is token counts
/// priced under one of these at the moment of display: the scanners and the
/// spend ledger keep counts, and no persisted dollar amount is read back into
/// the UI. Before that, a complete log scan re-priced the whole ledger under
/// whatever table the process held, and the bundled snapshot lacked the models
/// in use, so a launch whose network table had not arrived yet moved the
/// all-time total by over a thousand dollars with no usage behind it.
struct PriceTable: Sendable, Equatable {
    /// Price for a model nothing in the table matches; also the fallback for a
    /// table without a `default` entry.
    static let unknownModelPrice = ModelPrice(input: 3, output: 15, cacheWrite5m: 3.75, cacheWrite1h: 6, cacheRead: 0.3)

    var models: [String: ModelPrice] = [:]

    /// Best-effort lookup: the exact id, else the longest id that is a prefix
    /// of the model or that the model is a prefix of (a log's dated
    /// `claude-opus-4-8-20260101` finds `claude-opus-4-8`), else `default`.
    func price(for model: String) -> ModelPrice {
        if let exact = models[model] { return exact }
        let candidates = models.keys
            .filter { $0 != "default" && (model.hasPrefix($0) || $0.hasPrefix(model)) }
            .sorted { a, b in a.count != b.count ? a.count > b.count : a < b }
        if let best = candidates.first, let price = models[best] { return price }
        return models["default"] ?? Self.unknownModelPrice
    }

    /// Cost in USD for a set of token counts under a model.
    func cost(model: String, counts: TokenCounts) -> Double {
        let p = price(for: model)
        let m = 1_000_000.0
        return Double(counts.input)       * p.input       / m
             + Double(counts.output)      * p.output      / m
             + Double(counts.cacheWrite5m) * p.cacheWrite5m / m
             + Double(counts.cacheWrite1h) * p.cacheWrite1h / m
             + Double(counts.cacheRead)   * p.cacheRead    / m
    }

    /// Cost of one day's counts split by model.
    func cost(_ usage: [String: TokenCounts]) -> Double {
        usage.reduce(0) { $0 + cost(model: $1.key, counts: $1.value) }
    }
}

/// Owns the live price table: the bundled snapshot, the cached network table
/// over it, then whatever `refresh()` fetches from LiteLLM (fallback
/// models.dev). All sources are normalized to `ModelPrice` (USD per 1M tokens).
actor PricingService {
    static let shared = PricingService()

    private var table = PriceTable()
    private var loaded = false

    private static let liteLLMURL = URL(string: "https://raw.githubusercontent.com/BerriAI/litellm/main/model_prices_and_context_window.json")!
    private static let modelsDevURL = URL(string: "https://models.dev/api.json")!

    nonisolated private static var cacheURL: URL {
        let dir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("AgentMeter", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("pricing.json")
    }

    /// The table a launch starts from: the bundled snapshot with the cached
    /// network table merged over it, however old that cache is. A stale cache
    /// still knows every model the network table did; the snapshot alone may
    /// not, and pricing under it is what made the all-time total jump. Readable
    /// without the actor so `AppViewModel` can price its restored state at init.
    nonisolated static func localTable() -> PriceTable {
        var table = bundledTable()
        table.models.merge(cachedModels()) { $1 }
        return table
    }

    /// The bundled snapshot alone: what a launch with neither a cache nor a
    /// network answer prices under, and what `PriceTableTests` pins to the
    /// official price page.
    nonisolated static func bundledTable() -> PriceTable {
        PriceTable(models: embeddedModels())
    }

    /// Loads the local table once (idempotent).
    func ensureLoaded() {
        guard !loaded else { return }
        loaded = true
        table.models.merge(Self.localTable().models) { $1 }
    }

    /// The table as it stands: the local sources plus whatever `refresh()` has fetched.
    func snapshot() -> PriceTable {
        ensureLoaded()
        return table
    }

    func price(for model: String) -> ModelPrice {
        ensureLoaded()
        return table.price(for: model)
    }

    /// Cost in USD for a set of token counts under a model.
    func cost(model: String, counts: TokenCounts) -> Double {
        ensureLoaded()
        return table.cost(model: model, counts: counts)
    }

    /// Fetches fresh pricing from the network and updates the cache. Safe to call on launch.
    func refresh() async {
        ensureLoaded()
        if let data = try? await fetch(Self.liteLLMURL), let parsed = Self.parseLiteLLM(data), !parsed.isEmpty {
            table.models.merge(parsed) { $1 }
            persist()
            return
        }
        if let data = try? await fetch(Self.modelsDevURL), let parsed = Self.parseModelsDev(data), !parsed.isEmpty {
            table.models.merge(parsed) { $1 }
            persist()
        }
    }

    private func fetch(_ url: URL) async throws -> Data {
        var req = URLRequest(url: url)
        req.timeoutInterval = 15
        let (data, resp) = try await URLSession.shared.data(for: req)
        guard let http = resp as? HTTPURLResponse, http.statusCode == 200 else {
            throw URLError(.badServerResponse)
        }
        return data
    }

    private func persist() {
        // Atomic: `localTable()` loads this file on every launch, and a
        // half-written one would parse as nothing and drop every network price.
        if let data = try? JSONEncoder().encode(NormalizedTable(models: table.models)) {
            try? data.write(to: Self.cacheURL, options: .atomic)
        }
    }

    // MARK: - Local sources

    /// Our normalized format: { "models": { id: ModelPrice } }.
    private struct NormalizedTable: Codable { let models: [String: ModelPrice] }

    nonisolated private static func embeddedModels() -> [String: ModelPrice] {
        // In the packaged .app the JSON sits in Contents/Resources (Bundle.main), the only
        // location codesign accepts. Under `swift run`/debug it lives in the SPM resource
        // bundle next to the binary (Bundle.module). Try both.
        guard let url = Bundle.main.url(forResource: "embedded-pricing", withExtension: "json")
                ?? Bundle.module.url(forResource: "embedded-pricing", withExtension: "json"),
              let data = try? Data(contentsOf: url) else { return [:] }
        return parseNormalized(data)
    }

    nonisolated private static func cachedModels() -> [String: ModelPrice] {
        guard let data = try? Data(contentsOf: cacheURL) else { return [:] }
        return parseNormalized(data)
    }

    nonisolated private static func parseNormalized(_ data: Data) -> [String: ModelPrice] {
        (try? JSONDecoder().decode(NormalizedTable.self, from: data))?.models ?? [:]
    }

    // MARK: - Network parsers

    /// LiteLLM model_prices_and_context_window.json: top-level keys are model ids,
    /// values carry per-token costs. Convert to per-1M.
    nonisolated private static func parseLiteLLM(_ data: Data) -> [String: ModelPrice]? {
        guard let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
        var out: [String: ModelPrice] = [:]
        let m = 1_000_000.0
        for (model, raw) in obj {
            guard let d = raw as? [String: Any] else { continue }
            guard let input = d["input_cost_per_token"] as? Double,
                  let output = d["output_cost_per_token"] as? Double else { continue }
            let cacheRead = (d["cache_read_input_token_cost"] as? Double) ?? input * 0.1
            let cacheWrite5m = (d["cache_creation_input_token_cost"] as? Double) ?? input * 1.25
            let cacheWrite1h = (d["cache_creation_input_token_cost_above_1hr"] as? Double) ?? input * 2.0
            out[model] = ModelPrice(input: input * m, output: output * m,
                                    cacheWrite5m: cacheWrite5m * m, cacheWrite1h: cacheWrite1h * m,
                                    cacheRead: cacheRead * m)
        }
        return out
    }

    /// models.dev api.json: providers -> models with cost block (per 1M tokens).
    nonisolated private static func parseModelsDev(_ data: Data) -> [String: ModelPrice]? {
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
        var out: [String: ModelPrice] = [:]
        for (_, providerRaw) in root {
            guard let provider = providerRaw as? [String: Any],
                  let models = provider["models"] as? [String: Any] else { continue }
            for (id, modelRaw) in models {
                guard let model = modelRaw as? [String: Any],
                      let cost = model["cost"] as? [String: Any],
                      let input = cost["input"] as? Double,
                      let output = cost["output"] as? Double else { continue }
                let cacheRead = (cost["cache_read"] as? Double) ?? input * 0.1
                let cacheWrite = (cost["cache_write"] as? Double) ?? input * 1.25
                out[id] = ModelPrice(input: input, output: output,
                                     cacheWrite5m: cacheWrite, cacheWrite1h: input * 2.0,
                                     cacheRead: cacheRead)
            }
        }
        return out
    }
}
