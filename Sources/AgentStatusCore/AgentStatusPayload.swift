import Foundation

public enum AgentStatusState: String, Codable, Sendable, CaseIterable {
    case working
    case waiting
    case idle
    case error

    public var priority: Int {
        switch self {
        case .error: return 3
        case .waiting: return 2
        case .working: return 1
        case .idle: return 0
        }
    }
}

/// One live Claude Code session status written by the hook helper and read by
/// AgentMeter. The process ancestry lets the app disambiguate two sessions
/// running from the same working directory even before their transcripts can
/// be mapped to processes.
public struct AgentStatusPayload: Codable, Sendable, Equatable {
    public var state: AgentStatusState
    public var sessionID: String
    public var message: String?
    public var cwd: String?
    public var processAncestry: [Int]?
    public var updatedAt: Date

    public init(
        state: AgentStatusState,
        sessionID: String,
        message: String? = nil,
        cwd: String? = nil,
        processAncestry: [Int]? = nil,
        updatedAt: Date = Date()
    ) {
        self.state = state
        self.sessionID = sessionID
        self.message = message
        self.cwd = cwd
        self.processAncestry = processAncestry
        self.updatedAt = updatedAt
    }
}
