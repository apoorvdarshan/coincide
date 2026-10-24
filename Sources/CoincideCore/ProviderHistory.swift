import Foundation

public enum ProviderHistoryMode: String, Codable, Sendable, Equatable { case legacy, paginated, nativeTranscript, unknown }
public enum ProviderHistoryTurnStatus: String, Codable, Sendable, Equatable {
    case running, completed, interrupted, failed, unknown
    public var isTerminal: Bool { self == .completed || self == .interrupted || self == .failed }
}

/// Native provider IDs are opaque. App conversation IDs and checkpoint object IDs
/// are never interchangeable with these references.
public struct ProviderConversationReference: Codable, Sendable, Equatable {
    public let provider: ProviderKind
    public let nativeThreadID: String
    public init(provider: ProviderKind, nativeThreadID: String) throws {
        try ProviderHistoryValidation.id(nativeThreadID)
        self.provider = provider; self.nativeThreadID = nativeThreadID
    }
    public func validate() throws { try ProviderHistoryValidation.id(nativeThreadID) }
    private enum CodingKeys: String, CodingKey { case provider, nativeThreadID }
    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        try self.init(provider: c.decode(ProviderKind.self, forKey: .provider), nativeThreadID: c.decode(String.self, forKey: .nativeThreadID))
    }
}

public enum ProviderHistoryBoundary: Codable, Sendable, Equatable {
    case head
    case throughTurn(String)
    case beforeTurn(String)
    case throughClaudeMessage(String)
    case freshClaudeSession(String)
    public func validate() throws {
        switch self { case .head: break; case .throughTurn(let id), .beforeTurn(let id): try ProviderHistoryValidation.id(id)
        case .throughClaudeMessage(let id), .freshClaudeSession(let id):
            guard id.utf8.count == 36, UUID(uuidString: id) != nil else { throw ProviderHistoryError(.invalidRequest) }
        }
    }
    private enum CodingKeys: String, CodingKey { case kind, turnID, messageID }
    private enum Kind: String, Codable { case head, throughTurn, beforeTurn, throughClaudeMessage, freshClaudeSession }
    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        switch try c.decode(Kind.self, forKey: .kind) {
        case .head: self = .head
        case .throughTurn: self = .throughTurn(try c.decode(String.self, forKey: .turnID))
        case .beforeTurn: self = .beforeTurn(try c.decode(String.self, forKey: .turnID))
        case .throughClaudeMessage: self = .throughClaudeMessage(try c.decode(String.self, forKey: .messageID))
        case .freshClaudeSession: self = .freshClaudeSession(try c.decode(String.self, forKey: .messageID))
        }
        try validate()
    }
    public func encode(to encoder: any Encoder) throws {
        try validate(); var c = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .head: try c.encode(Kind.head, forKey: .kind)
        case .throughTurn(let id): try c.encode(Kind.throughTurn, forKey: .kind); try c.encode(id, forKey: .turnID)
        case .beforeTurn(let id): try c.encode(Kind.beforeTurn, forKey: .kind); try c.encode(id, forKey: .turnID)
        case .throughClaudeMessage(let id): try c.encode(Kind.throughClaudeMessage, forKey: .kind); try c.encode(id, forKey: .messageID)
        case .freshClaudeSession(let id): try c.encode(Kind.freshClaudeSession, forKey: .kind); try c.encode(id, forKey: .messageID)
        }
    }
}

public struct ProviderHistoryCapabilities: Sendable, Equatable {
    public let reference: ProviderConversationReference
    public let historyMode: ProviderHistoryMode
    public let canRead: Bool
    public let canForkHead: Bool
    public let canForkFromTurn: Bool
    public let canRevertBeforeTurn: Bool
    public let unavailableReason: String?
    public init(reference: ProviderConversationReference, historyMode: ProviderHistoryMode = .unknown,
                canRead: Bool = false, canForkHead: Bool = false, canForkFromTurn: Bool = false,
                canRevertBeforeTurn: Bool = false, unavailableReason: String? = nil) {
        self.reference = reference; self.historyMode = historyMode; self.canRead = canRead
        self.canForkHead = canForkHead; self.canForkFromTurn = canForkFromTurn
        self.canRevertBeforeTurn = canRevertBeforeTurn; self.unavailableReason = unavailableReason
    }
}

public struct ProviderHistoryTurn: Codable, Sendable, Equatable, Identifiable {
    public let id: String
    public let status: ProviderHistoryTurnStatus
    public init(id: String, status: ProviderHistoryTurnStatus) throws {
        try ProviderHistoryValidation.id(id); self.id = id; self.status = status
    }
    private enum CodingKeys: String, CodingKey { case id, status }
    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        try self.init(id: c.decode(String.self, forKey: .id), status: c.decode(ProviderHistoryTurnStatus.self, forKey: .status))
    }
}

public struct ProviderHistoryPage: Sendable, Equatable {
    public let reference: ProviderConversationReference
    public let turns: [ProviderHistoryTurn]
    public let nextCursor: String?
    public init(reference: ProviderConversationReference, turns: [ProviderHistoryTurn], nextCursor: String? = nil) throws {
        try reference.validate()
        guard turns.count <= 100, Set(turns.map(\.id)).count == turns.count else { throw ProviderHistoryError(.invalidResponse) }
        if let nextCursor { try ProviderHistoryValidation.cursor(nextCursor) }
        self.reference = reference; self.turns = turns; self.nextCursor = nextCursor
    }
}

/// A verified provider history head. This is conversation evidence only; no file
/// restoration or Git operation is implied by creating one.
public struct ProviderConversationSnapshot: Codable, Sendable, Equatable {
    public let reference: ProviderConversationReference
    public let workspacePath: String
    public let historyMode: ProviderHistoryMode
    public let headTurnID: String?
    public let claude: ClaudeHistoryResult?
    public init(reference: ProviderConversationReference, workspacePath: String,
                historyMode: ProviderHistoryMode, headTurnID: String? = nil, claude: ClaudeHistoryResult? = nil) throws {
        try reference.validate(); try ProviderHistoryValidation.path(workspacePath)
        if let headTurnID { try ProviderHistoryValidation.id(headTurnID) }
        self.reference = reference; self.workspacePath = workspacePath
        self.historyMode = historyMode; self.headTurnID = headTurnID
        self.claude = claude
        try validate()
    }
    public func validate() throws {
        try reference.validate(); try ProviderHistoryValidation.path(workspacePath)
        if let headTurnID { try ProviderHistoryValidation.id(headTurnID) }
        if let claude {
            try claude.validate()
            guard reference == claude.reference, workspacePath == claude.workspacePath,
                  historyMode == .nativeTranscript, headTurnID == nil else { throw ProviderHistoryError(.invalidResponse) }
        } else if historyMode == .nativeTranscript { throw ProviderHistoryError(.invalidResponse) }
    }
    private enum CodingKeys: String, CodingKey { case reference, workspacePath, historyMode, headTurnID, claude }
    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        try self.init(reference: c.decode(ProviderConversationReference.self, forKey: .reference),
            workspacePath: c.decode(String.self, forKey: .workspacePath), historyMode: c.decode(ProviderHistoryMode.self, forKey: .historyMode),
            headTurnID: c.decodeIfPresent(String.self, forKey: .headTurnID),
            claude: c.decodeIfPresent(ClaudeHistoryResult.self, forKey: .claude))
    }
}

public struct ProviderHistoryError: LocalizedError, Sendable, Equatable {
    public enum Kind: String, Codable, Sendable { case unsupported, invalidRequest, invalidResponse, notIdle, unsafeGoal, boundaryUnavailable, historyChanged, limitExceeded, outcomeUncertain }
    public let kind: Kind
    public init(_ kind: Kind) { self.kind = kind }
    public var errorDescription: String? {
        switch kind {
        case .unsupported: "This provider connection does not support this conversation history operation."
        case .invalidRequest: "The conversation history reference or boundary is invalid."
        case .invalidResponse: "The provider returned invalid conversation history evidence."
        case .notIdle: "The provider conversation must be loaded and idle before it can be rewound."
        case .unsafeGoal: "Pause or finish the provider goal before rewinding this conversation."
        case .boundaryUnavailable: "The selected provider turn is not an available completed history boundary."
        case .historyChanged: "The provider conversation changed. Review its current history before continuing."
        case .limitExceeded: "The provider history exceeds the bounded operation limit."
        case .outcomeUncertain: "The provider operation could not be confirmed. It was not automatically repeated."
        }
    }
}

enum ProviderHistoryValidation {
    static func id(_ value: String) throws {
        guard !value.isEmpty, value.utf8.count <= 4_096, !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              !value.unicodeScalars.contains(where: { $0.value < 32 || $0.value == 127 }) else { throw ProviderHistoryError(.invalidRequest) }
    }
    static func cursor(_ value: String) throws {
        guard !value.isEmpty, value.utf8.count <= 8_192,
              !value.unicodeScalars.contains(where: { $0.value < 32 || $0.value == 127 }) else { throw ProviderHistoryError(.invalidResponse) }
    }
    static func path(_ value: String) throws {
        guard value.hasPrefix("/"), value.utf8.count <= 16_384, !value.contains("\0"),
              !value.split(separator: "/", omittingEmptySubsequences: false).contains(where: { $0 == "." || $0 == ".." }) else { throw ProviderHistoryError(.invalidRequest) }
    }
}
