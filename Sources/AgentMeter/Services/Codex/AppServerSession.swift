import Foundation

/// Spawns `codex app-server --listen stdio://` and speaks newline-delimited JSON-RPC 2.0
/// over the child's stdin/stdout. Used for *live* Codex quota (fresh even with no session).
/// Falls back to CodexRolloutReader when the binary or method is unavailable.
final class AppServerSession {
    enum SessionError: Error { case binaryNotFound, timeout, badResponse, rpc(String) }

    private let process = Process()
    private let inPipe = Pipe()
    private let outPipe = Pipe()
    private var buffer = Data()
    private var nextID = 0
    private let lock = NSLock()

    /// Candidate locations for the codex binary.
    static func resolveBinary() -> URL? {
        // 1. PATH lookup via /usr/bin/env
        if let path = which("codex") { return URL(fileURLWithPath: path) }
        // 2. Codex.app bundle
        let app = URL(fileURLWithPath: "/Applications/Codex.app/Contents/Resources/codex")
        if FileManager.default.isExecutableFile(atPath: app.path) { return app }
        // 3. Common install dirs
        for p in ["/opt/homebrew/bin/codex", "/usr/local/bin/codex",
                  NSHomeDirectory() + "/.local/bin/codex"] where FileManager.default.isExecutableFile(atPath: p) {
            return URL(fileURLWithPath: p)
        }
        return nil
    }

    private static func which(_ name: String) -> String? {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        p.arguments = ["which", name]
        p.currentDirectoryURL = SubprocessWorkingDirectory.url
        let out = Pipe()
        p.standardOutput = out
        p.standardError = Pipe()
        do {
            try p.run()
            p.waitUntilExit()
            guard p.terminationStatus == 0 else { return nil }
            let data = out.fileHandleForReading.readDataToEndOfFile()
            let s = String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines)
            return (s?.isEmpty == false) ? s : nil
        } catch { return nil }
    }

    func start() throws {
        guard let bin = Self.resolveBinary() else { throw SessionError.binaryNotFound }
        process.executableURL = bin
        process.arguments = ["app-server", "--listen", "stdio://"]
        process.currentDirectoryURL = SubprocessWorkingDirectory.url
        process.standardInput = inPipe
        process.standardOutput = outPipe
        process.standardError = Pipe()
        try process.run()
    }

    func stop() {
        if process.isRunning { process.terminate() }
    }

    /// Fetches a live quota snapshot. Throws if the app-server path is unusable.
    func fetchQuota() async throws -> QuotaSnapshot {
        try start()
        defer { stop() }

        _ = try await request(method: "initialize",
            params: ["clientInfo": ["name": "agent_meter", "title": "AgentMeter", "version": "1.0"]])
        notify(method: "initialized", params: [:])
        _ = try? await request(method: "account/read", params: ["refreshToken": false])
        let rl = try await request(method: "account/rateLimits/read", params: [:])
        return try Self.parseQuota(rl)
    }

    static func parseQuota(_ result: [String: Any]) throws -> QuotaSnapshot {
        let rl = (result["rateLimits"] as? [String: Any]) ?? result
        let resetCredits = (result["rateLimitResetCredits"] as? [String: Any])
            ?? (result["rate_limit_reset_credits"] as? [String: Any])
        var windows: [QuotaWindow] = []
        func add(_ id: String, _ d: [String: Any]?) {
            guard let d else { return }
            let used = (d["usedPercent"] as? Double) ?? (d["used_percent"] as? Double) ?? 0
            let mins = (d["windowDurationMins"] as? Double) ?? (d["window_minutes"] as? Double) ?? 0
            let resets = ((d["resetsAt"] as? Double) ?? (d["resets_at"] as? Double))
                .map { Date(timeIntervalSince1970: $0) }
            windows.append(QuotaWindow(id: id, label: CodexRolloutReader.label(forMinutes: mins),
                                       usedPercent: used, resetsAt: resets))
        }
        add("primary", rl["primary"] as? [String: Any])
        add("secondary", rl["secondary"] as? [String: Any])
        guard !windows.isEmpty else { throw SessionError.badResponse }
        return QuotaSnapshot(provider: .codex, windows: windows, source: .appServer,
                             planType: rl["planType"] as? String,
                             resetCreditsAvailable: Self.resetCreditsAvailable(in: resetCredits),
                             resetCreditsExpiresAt: Self.resetCreditsExpiresAt(in: resetCredits),
                             fetchedAt: Date(), note: nil)
    }

    private static func resetCreditsAvailable(in obj: [String: Any]?) -> Int? {
        guard let obj else { return nil }
        if let count = obj["availableCount"] as? Int { return count }
        if let count = obj["available_count"] as? Int { return count }
        if let count = obj["availableCount"] as? Double { return Int(count) }
        if let count = obj["available_count"] as? Double { return Int(count) }
        return nil
    }

    private static func resetCreditsExpiresAt(in obj: [String: Any]?) -> Date? {
        guard let obj else { return nil }
        let keys = ["expiresAt", "expires_at", "expirationDate", "expiration_date", "expires"]
        for key in keys {
            if let seconds = obj[key] as? Double {
                return Date(timeIntervalSince1970: seconds)
            }
            if let seconds = obj[key] as? Int {
                return Date(timeIntervalSince1970: Double(seconds))
            }
            if let string = obj[key] as? String,
               let date = CodexRolloutReader.parseISO(string) {
                return date
            }
        }
        return nil
    }

    // MARK: - JSON-RPC plumbing

    private func nextRequestID() -> Int {
        lock.lock(); defer { lock.unlock() }
        nextID += 1
        return nextID
    }

    private func notify(method: String, params: [String: Any]) {
        let msg: [String: Any] = ["jsonrpc": "2.0", "method": method, "params": params]
        writeMessage(msg)
    }

    private func request(method: String, params: [String: Any], timeout: TimeInterval = 10) async throws -> [String: Any] {
        let id = nextRequestID()
        let msg: [String: Any] = ["jsonrpc": "2.0", "id": id, "method": method, "params": params]
        writeMessage(msg)
        return try await readResponse(matching: id, timeout: timeout)
    }

    private func writeMessage(_ msg: [String: Any]) {
        guard var data = try? JSONSerialization.data(withJSONObject: msg) else { return }
        data.append(0x0A) // newline
        inPipe.fileHandleForWriting.write(data)
    }

    private func readResponse(matching id: Int, timeout: TimeInterval) async throws -> [String: Any] {
        let deadline = Date().addingTimeInterval(timeout)
        let handle = outPipe.fileHandleForReading
        while Date() < deadline {
            // Drain any buffered complete lines first.
            if let obj = try takeMatchingLine(id: id) { return obj }
            let chunk = handle.availableData
            if chunk.isEmpty {
                try await Task.sleep(nanoseconds: 50_000_000)
                continue
            }
            buffer.append(chunk)
            if let obj = try takeMatchingLine(id: id) { return obj }
        }
        throw SessionError.timeout
    }

    private func takeMatchingLine(id: Int) throws -> [String: Any]? {
        while let nl = buffer.firstIndex(of: 0x0A) {
            let lineData = buffer.subdata(in: buffer.startIndex..<nl)
            buffer.removeSubrange(buffer.startIndex...nl)
            guard let obj = try? JSONSerialization.jsonObject(with: lineData) as? [String: Any] else { continue }
            guard (obj["id"] as? Int) == id else { continue } // skip notifications / other ids
            if let err = obj["error"] as? [String: Any] {
                throw SessionError.rpc((err["message"] as? String) ?? "rpc error")
            }
            return (obj["result"] as? [String: Any]) ?? [:]
        }
        return nil
    }
}
