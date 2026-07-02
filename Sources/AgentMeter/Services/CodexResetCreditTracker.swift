import Foundation

struct CodexResetCreditState: Codable, Sendable, Equatable {
    var lastObservedCount: Int?
    var credits: [CodexResetCreditExpiry]

    init(lastObservedCount: Int? = nil, credits: [CodexResetCreditExpiry] = []) {
        self.lastObservedCount = lastObservedCount
        self.credits = credits
    }

    var nearestExpiry: Date? {
        credits.map(\.expiresAt).min()
    }
}

struct CodexResetCreditExpiry: Codable, Sendable, Equatable, Identifiable {
    let id: String
    let grantedAt: Date
    let expiresAt: Date
}

enum CodexResetCreditTracker {
    static let inferredLifetime: TimeInterval = 30 * 24 * 60 * 60
    private static let maxStoredCredits = 20

    static func reconcile(
        existing: CodexResetCreditState,
        quota: QuotaSnapshot,
        at now: Date = Date()
    ) -> CodexResetCreditState {
        var credits = existing.credits
            .filter { $0.expiresAt > now }
            .sorted { $0.expiresAt < $1.expiresAt }
        let expiredKnownCount = existing.credits.count - credits.count

        guard quota.provider == .codex, let available = quota.resetCreditsAvailable else {
            return CodexResetCreditState(lastObservedCount: existing.lastObservedCount, credits: credits)
        }

        if available == 0 {
            return CodexResetCreditState(lastObservedCount: 0, credits: [])
        }

        if let previous = existing.lastObservedCount {
            let adjustedPrevious = max(previous - expiredKnownCount, 0)
            let delta = available - adjustedPrevious
            if delta > 0 {
                let expiresAt = now.addingTimeInterval(inferredLifetime)
                for index in 0..<delta {
                    credits.append(CodexResetCreditExpiry(
                        id: "\(Int(now.timeIntervalSince1970))-\(index)",
                        grantedAt: now,
                        expiresAt: expiresAt
                    ))
                }
            } else if delta < 0 {
                credits.removeFirst(min(-delta, credits.count))
            }
        }

        if credits.count > available {
            credits = Array(credits.prefix(available))
        }
        if credits.count > maxStoredCredits {
            credits = Array(credits.prefix(maxStoredCredits))
        }

        return CodexResetCreditState(lastObservedCount: available, credits: credits)
    }
}
