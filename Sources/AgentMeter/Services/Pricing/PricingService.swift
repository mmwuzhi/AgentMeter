import Foundation

/// Normalized price for a model, USD per 1,000,000 tokens.
struct ModelPrice: Codable, Sendable {
    var input: Double
    var output: Double
    var cacheWrite5m: Double
    var cacheWrite1h: Double
    var cacheRead: Double
}

/// Token counts for one accounting unit (a message or a day).
struct TokenCounts: Sendable {
    var input = 0
    var output = 0
    var cacheWrite5m = 0
    var cacheWrite1h = 0
    var cacheRead = 0
}

/// Resolves model pricing and computes spend.
///
/// Order of truth: cached file (fresh) → embedded snapshot, refreshed in the
/// background from LiteLLM (fallback models.dev). All sources normalized to
/// `ModelPrice` (USD per 1M tokens).
actor PricingService {
    static let shared = PricingService()

    private var table: [String: ModelPrice] = [:]
    private var loaded = false

    private let liteLLMURL = URL(string: "https://raw.githubusercontent.com/BerriAI/litellm/main/model_prices_and_context_window.json")!
    private let modelsDevURL = URL(string: "https://models.dev/api.json")!

    private var cacheURL: URL {
        let dir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("AgentMeter", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("pricing.json")
    }

    /// Loads embedded + cached pricing synchronously-ish (idempotent).
    func ensureLoaded() {
        guard !loaded else { return }
        loaded = true
        loadEmbedded()
        loadCache()
    }

    /// Best-effort price lookup: exact id, then longest matching prefix, then default.
    func price(for model: String) -> ModelPrice {
        if let exact = table[model] { return exact }
        // Prefix match: e.g. log "claude-opus-4-8-20260101" -> "claude-opus-4-8"
        let candidates = table.keys
            .filter { $0 != "default" && (model.hasPrefix($0) || $0.hasPrefix(model)) }
            .sorted { $0.count > $1.count }
        if let best = candidates.first { return table[best]! }
        return table["default"] ?? ModelPrice(input: 3, output: 15, cacheWrite5m: 3.75, cacheWrite1h: 6, cacheRead: 0.3)
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

    // MARK: - Loading

    private func loadEmbedded() {
        guard let url = Bundle.module.url(forResource: "embedded-pricing", withExtension: "json"),
              let data = try? Data(contentsOf: url) else { return }
        merge(parseNormalized(data))
    }

    private func loadCache() {
        // Use cache only if newer than 24h; otherwise it'll be refreshed by refresh().
        guard let attrs = try? FileManager.default.attributesOfItem(atPath: cacheURL.path),
              let mtime = attrs[.modificationDate] as? Date,
              Date().timeIntervalSince(mtime) < 60 * 60 * 24,
              let data = try? Data(contentsOf: cacheURL) else { return }
        merge(parseNormalized(data))
    }

    /// Fetches fresh pricing from the network and updates the cache. Safe to call on launch.
    func refresh() async {
        ensureLoaded()
        if let data = try? await fetch(liteLLMURL), let parsed = parseLiteLLM(data), !parsed.isEmpty {
            merge(parsed)
            persist()
            return
        }
        if let data = try? await fetch(modelsDevURL), let parsed = parseModelsDev(data), !parsed.isEmpty {
            merge(parsed)
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

    private func merge(_ newer: [String: ModelPrice]) {
        for (k, v) in newer { table[k] = v }
    }

    private func persist() {
        struct Wrapper: Codable { let models: [String: ModelPrice] }
        if let data = try? JSONEncoder().encode(Wrapper(models: table)) {
            try? data.write(to: cacheURL)
        }
    }

    // MARK: - Parsers

    /// Our normalized format: { "models": { id: ModelPrice } }.
    private func parseNormalized(_ data: Data) -> [String: ModelPrice] {
        struct Wrapper: Codable { let models: [String: ModelPrice] }
        return (try? JSONDecoder().decode(Wrapper.self, from: data))?.models ?? [:]
    }

    /// LiteLLM model_prices_and_context_window.json: top-level keys are model ids,
    /// values carry per-token costs. Convert to per-1M.
    private func parseLiteLLM(_ data: Data) -> [String: ModelPrice]? {
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
    private func parseModelsDev(_ data: Data) -> [String: ModelPrice]? {
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
