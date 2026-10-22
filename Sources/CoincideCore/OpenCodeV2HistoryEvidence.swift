import CryptoKit
import Foundation

/// OpenCode exposes ordered messages, not Codex native turns. Evidence retains
/// bounded identities and canonical content hashes, never provider payloads.
public enum OpenCodeV2HistoryMessageKind: String, Codable, Sendable {
    case agentSwitched = "agent-switched", modelSwitched = "model-switched", locationSwitched = "location-switched"
    case user, synthetic, system, skill, shell, assistant, compaction, idle
}

public struct OpenCodeV2HistoryMessage: Codable, Sendable, Equatable {
    public let id: String
    public let kind: OpenCodeV2HistoryMessageKind
    public let contentDigest: String
    public let isSettled: Bool
    public let idleOutcome: String?
    public init(id: String, kind: OpenCodeV2HistoryMessageKind, contentDigest: String,
                isSettled: Bool = true, idleOutcome: String? = nil) throws {
        self.id = id; self.kind = kind; self.contentDigest = contentDigest
        self.isSettled = isSettled; self.idleOutcome = idleOutcome
        try validate()
    }
    public func validate() throws {
        try OpenCodeV2HistoryValidation.messageID(id); try OpenCodeV2HistoryValidation.digest(contentDigest)
        guard kind == .idle ? ["succeeded", "failed", "interrupted"].contains(idleOutcome ?? "") : idleOutcome == nil else {
            throw ProviderHistoryError(.invalidResponse)
        }
    }
}

public struct OpenCodeV2HistoryStage: Codable, Sendable, Equatable {
    public enum FilesState: String, Codable, Sendable { case absent, empty, nonempty }
    public let messageID: String
    public let snapshot: String?
    public let partID: String?
    public let files: FilesState
    public init(messageID: String, snapshot: String? = nil, partID: String? = nil, files: FilesState) throws {
        self.messageID = messageID; self.snapshot = snapshot; self.partID = partID; self.files = files
        try validate()
    }
    public func validate() throws {
        try OpenCodeV2HistoryValidation.messageID(messageID)
        if let snapshot { try ProviderHistoryValidation.id(snapshot) }
        if let partID { try ProviderHistoryValidation.id(partID) }
    }
    public var isHistoryOnly: Bool { files == .empty && partID == nil }
}

public struct OpenCodeV2HistoryFork: Codable, Sendable, Equatable {
    public let sourceSessionID: String
    public let boundary: ProviderHistoryBoundary
    public init(sourceSessionID: String, boundary: ProviderHistoryBoundary) throws {
        self.sourceSessionID = sourceSessionID; self.boundary = boundary; try validate()
    }
    public func validate() throws {
        try OpenCodeV2HistoryValidation.sessionID(sourceSessionID); try boundary.validate()
        switch boundary {
        case .beforeMessage, .throughMessage: break
        default: throw ProviderHistoryError(.invalidResponse)
        }
    }
}

public struct OpenCodeV2HistorySnapshot: Codable, Sendable, Equatable {
    public let reference: ProviderConversationReference
    public let runtimeIdentity: OpenCodeRuntimeIdentity
    public let workspacePath: String
    public let messages: [OpenCodeV2HistoryMessage]
    public let stage: OpenCodeV2HistoryStage?
    public let fork: OpenCodeV2HistoryFork?
    public let maintenance: OpenCodeV2HistoryMaintenanceReceipt?
    public init(reference: ProviderConversationReference, runtimeIdentity: OpenCodeRuntimeIdentity, workspacePath: String,
                messages: [OpenCodeV2HistoryMessage], stage: OpenCodeV2HistoryStage? = nil, fork: OpenCodeV2HistoryFork? = nil,
                maintenance: OpenCodeV2HistoryMaintenanceReceipt? = nil) throws {
        self.reference = reference; self.runtimeIdentity = runtimeIdentity; self.workspacePath = workspacePath
        self.messages = messages; self.stage = stage; self.fork = fork; self.maintenance = maintenance; try validate()
    }
    public func validate() throws {
        try reference.validate(); try OpenCodeV2HistoryValidation.sessionID(reference.nativeThreadID)
        try ProviderHistoryValidation.path(workspacePath)
        try OpenCodeConfiguration(instanceID: runtimeIdentity.instanceID, generation: runtimeIdentity.generation,
                                  executable: runtimeIdentity.executable).validate()
        guard reference.provider == .opencode, runtimeIdentity.generation == .v2, messages.count <= 10_000,
              Set(messages.map(\.id)).count == messages.count else { throw ProviderHistoryError(.invalidResponse) }
        for message in messages { try message.validate() }
        try stage?.validate(); try fork?.validate()
        if let stage, !messages.contains(where: { $0.id == stage.messageID }) { throw ProviderHistoryError(.invalidResponse) }
        if let maintenance {
            try maintenance.validate()
            guard stage == nil, let last = messages.last, last.kind == .idle, last.isSettled,
                  last.id == maintenance.idleMessageID,
                  OpenCodeV2HistoryValidation.hash(Array(messages.dropLast())) == maintenance.priorInventoryDigest else {
                throw ProviderHistoryError(.invalidResponse)
            }
        }
    }
    /// Includes native IDs: changing a native suffix with the same user head is
    /// observable. Fork matching instead uses the canonical semantic digest.
    public var inventoryDigest: String { OpenCodeV2HistoryValidation.hash(messages) }
    public var contentDigest: String { Self.contentDigest(messages) }
    private struct Content: Encodable { let kind: OpenCodeV2HistoryMessageKind; let digest: String; let settled: Bool; let idle: String? }
    public static func contentDigest(_ messages: some Sequence<OpenCodeV2HistoryMessage>) -> String {
        return OpenCodeV2HistoryValidation.hash(messages.map { Content(kind: $0.kind, digest: $0.contentDigest, settled: $0.isSettled, idle: $0.idleOutcome) })
    }
    public var headMessageID: String? { messages.last(where: { $0.kind == .user })?.id }
    public func matchesBinding(_ configuration: ProviderConfiguration) -> Bool {
        configuration.provider == .opencode && configuration.openCodeConfiguration?.runtimeIdentity == runtimeIdentity &&
            configuration.workspacePath == workspacePath
    }
}

public struct OpenCodeV2HistoryRunInput: Codable, Sendable, Equatable {
    public let runID: UUID
    public let openingMessageID: String
    public let steeringMessageIDs: [String]
    public init(runID: UUID, openingMessageID: String, steeringMessageIDs: [String] = []) {
        self.runID = runID; self.openingMessageID = openingMessageID; self.steeringMessageIDs = steeringMessageIDs
    }
    public static func steeringMessageID(instanceID: UUID, sessionID: String, runID: UUID, clientMessageID: String) throws -> String {
        try OpenCodeV2HistoryValidation.sessionID(sessionID); try ProviderSteeringValidation.id(clientMessageID)
        let bytes = try JSONEncoder().encode([instanceID.uuidString, sessionID, runID.uuidString, clientMessageID])
        return "msg_coincide_steer_" + SHA256.hash(data: bytes).map { String(format: "%02x", $0) }.joined()
    }
    public static func openingMessageID(instanceID: UUID, runID: UUID) -> String {
        "msg_coincide_" + SHA256.hash(data: Data((instanceID.uuidString + ":" + runID.uuidString).utf8)).map { String(format: "%02x", $0) }.joined()
    }
}

/// The wire has no independent execution identifier. These are the exact
/// observed start/terminal event IDs of one owned empty maintenance cycle.
public struct OpenCodeV2HistoryMaintenanceReceipt: Codable, Sendable, Equatable {
    public let priorInventoryDigest: String
    public let startEventID: String
    public let terminalEventID: String
    public let idleMessageID: String
    public init(priorInventoryDigest: String, startEventID: String, terminalEventID: String, idleMessageID: String) throws {
        self.priorInventoryDigest = priorInventoryDigest; self.startEventID = startEventID
        self.terminalEventID = terminalEventID; self.idleMessageID = idleMessageID; try validate()
    }
    public func validate() throws {
        try OpenCodeV2HistoryValidation.digest(priorInventoryDigest)
        try ProviderHistoryValidation.id(startEventID); try ProviderHistoryValidation.id(terminalEventID)
        try OpenCodeV2HistoryValidation.messageID(idleMessageID)
        guard startEventID.hasPrefix("evt_"), terminalEventID.hasPrefix("evt_"), startEventID != terminalEventID,
              idleMessageID == "msg_" + terminalEventID.dropFirst(4) else { throw ProviderHistoryError(.invalidResponse) }
    }
}

public struct OpenCodeV2HistoryReviewEvidence: Codable, Sendable, Equatable {
    public let source: OpenCodeV2HistorySnapshot
    public let boundary: ProviderHistoryBoundary
    public let retainedMessageCount: Int
    public let selectedOpeningMessageID: String
    public let inputs: [OpenCodeV2HistoryRunInput]
    public init(source: OpenCodeV2HistorySnapshot, boundary: ProviderHistoryBoundary, retainedMessageCount: Int,
                selectedOpeningMessageID: String, inputs: [OpenCodeV2HistoryRunInput]) throws {
        self.source = source; self.boundary = boundary; self.retainedMessageCount = retainedMessageCount
        self.selectedOpeningMessageID = selectedOpeningMessageID; self.inputs = inputs; try validate()
    }
    public var retainedContentDigest: String { OpenCodeV2HistorySnapshot.contentDigest(source.messages.prefix(retainedMessageCount)) }
    /// Existing OpenCode run refs are weak observed input IDs. They become
    /// usable message boundaries only after native inventory and durable local
    /// ownership agree; no message text or timestamp is used for attribution.
    public static func localInputs(in snapshot: WorkspaceSnapshot, thread: CodingThread,
                                   observed: OpenCodeV2HistorySnapshot) throws -> [OpenCodeV2HistoryRunInput] {
        try observed.validate()
        guard let nativeID = thread.providerThreadID, observed.reference.nativeThreadID == nativeID,
              observed.matchesBinding(.init(thread: thread)) else { throw ProviderHistoryError(.historyChanged) }
        let records = thread.activeHistoryRuns
        let positions = Dictionary(uniqueKeysWithValues: observed.messages.enumerated().map { ($0.element.id, $0.offset) })
        return try records.map { run in
            guard run.status.isTerminal, run.origin == .user, run.messageAttributionVersion == 1,
                  run.configuration.provider == .opencode, run.configuration.openCodeConfiguration?.runtimeIdentity == observed.runtimeIdentity,
                  run.configuration.workspacePath == observed.workspacePath, run.providerThreadID == nativeID,
                  run.turnIDs.count == 1, let opening = run.turnIDs.first,
                  opening == OpenCodeV2HistoryRunInput.openingMessageID(instanceID: observed.runtimeIdentity.instanceID, runID: run.id),
                  let position = positions[opening], observed.messages[position].kind == .user else { throw ProviderHistoryError(.boundaryUnavailable) }
            var steering: [String] = []
            for operation in snapshot.promptSteerings ?? [] where operation.threadID == thread.id && operation.runID == run.id {
                guard operation.nativeThreadID == nativeID, operation.configuration.openCodeConfiguration?.runtimeIdentity == observed.runtimeIdentity else {
                    throw ProviderHistoryError(.boundaryUnavailable)
                }
                let id = try OpenCodeV2HistoryRunInput.steeringMessageID(instanceID: observed.runtimeIdentity.instanceID,
                    sessionID: nativeID, runID: run.id, clientMessageID: operation.messageID)
                let present = positions[id].map { observed.messages[$0].kind == .user } == true
                if operation.phase == .delivered && operation.receipt?.delivery == .acknowledged {
                    guard present, operation.receipt?.target == .nativeTurn(opening) else { throw ProviderHistoryError(.historyChanged) }
                    steering.append(id)
                } else if operation.phase == .unconfirmed || (operation.phase == .delivered && operation.receipt?.delivery == .submitted) {
                    // Native existence proves only this history input reference;
                    // it does not rewrite the retained delivery audit. Retained
                    // unconfirmed inputs still fail the separate prefix gate.
                    if present { steering.append(id) }
                } else if present { throw ProviderHistoryError(.historyChanged) }
            }
            steering.sort { positions[$0]! < positions[$1]! }
            return .init(runID: run.id, openingMessageID: opening, steeringMessageIDs: steering)
        }
    }
    public static func make(source: OpenCodeV2HistorySnapshot, snapshot: WorkspaceSnapshot, thread: CodingThread,
                            runID: UUID, kind: ConversationHistoryKind) throws -> Self {
        let inputs = try localInputs(in: snapshot, thread: thread, observed: source)
        guard let selected = inputs.firstIndex(where: { $0.runID == runID }) else { throw ProviderHistoryError(.boundaryUnavailable) }
        let cut = kind == .rewindBeforeRun ? inputs[selected].openingMessageID :
            (selected + 1 < inputs.count ? inputs[selected + 1].openingMessageID : nil)
        let count = try cut.map { id in
            guard let index = source.messages.firstIndex(where: { $0.id == id }) else { throw ProviderHistoryError(.historyChanged) }
            return index
        } ?? source.messages.count
        return try .init(source: source, boundary: cut.map(ProviderHistoryBoundary.beforeMessage) ?? .head,
            retainedMessageCount: count, selectedOpeningMessageID: inputs[selected].openingMessageID, inputs: inputs)
    }
    public func validate() throws {
        try source.validate(); try boundary.validate(); try OpenCodeV2HistoryValidation.messageID(selectedOpeningMessageID)
        guard source.stage == nil, source.messages.allSatisfy(\.isSettled), !inputs.isEmpty, inputs.count <= 10_000,
              Set(inputs.map(\.runID)).count == inputs.count, (0...source.messages.count).contains(retainedMessageCount),
              inputs.contains(where: { $0.openingMessageID == selectedOpeningMessageID }) else { throw ProviderHistoryError(.invalidRequest) }
        let positions = Dictionary(uniqueKeysWithValues: source.messages.enumerated().map { ($0.element.id, $0.offset) })
        var claimed = Set<String>(), previous = -1
        for (index, input) in inputs.enumerated() {
            guard let start = positions[input.openingMessageID], start > previous,
                  source.messages[start].kind == .user, input.steeringMessageIDs.count <= 128 else { throw ProviderHistoryError(.boundaryUnavailable) }
            let end = index + 1 < inputs.count ? positions[inputs[index + 1].openingMessageID] ?? -1 : source.messages.count
            guard end > start else { throw ProviderHistoryError(.boundaryUnavailable) }
            for id in [input.openingMessageID] + input.steeringMessageIDs {
                try OpenCodeV2HistoryValidation.messageID(id)
                guard claimed.insert(id).inserted, let position = positions[id], position >= start, position < end,
                      source.messages[position].kind == .user else { throw ProviderHistoryError(.boundaryUnavailable) }
            }
            previous = start
        }
        guard let first = inputs.first.flatMap({ positions[$0.openingMessageID] }),
              source.messages[first...].filter({ $0.kind == .user }).allSatisfy({ claimed.contains($0.id) }) else {
            throw ProviderHistoryError(.boundaryUnavailable)
        }
        switch boundary {
        case .head: guard retainedMessageCount == source.messages.count else { throw ProviderHistoryError(.invalidRequest) }
        case .beforeMessage(let id):
            guard positions[id] == retainedMessageCount, source.messages[retainedMessageCount].kind == .user else { throw ProviderHistoryError(.invalidRequest) }
        default: throw ProviderHistoryError(.invalidRequest)
        }
    }
    public func validateResult(_ result: OpenCodeV2HistorySnapshot, kind: ConversationHistoryKind) throws {
        try validate(); try result.validate()
        let retained = Array(source.messages.prefix(retainedMessageCount))
        let actual: [OpenCodeV2HistoryMessage]
        if let maintenance = result.maintenance {
            guard kind == .rewindBeforeRun, maintenance.priorInventoryDigest == OpenCodeV2HistoryValidation.hash(retained) else {
                throw ProviderHistoryError(.historyChanged)
            }
            actual = Array(result.messages.dropLast())
        } else { actual = result.messages }
        guard result.runtimeIdentity == source.runtimeIdentity, result.workspacePath == source.workspacePath,
              result.stage == nil, actual.count == retainedMessageCount,
              OpenCodeV2HistorySnapshot.contentDigest(actual) == retainedContentDigest, result.messages.allSatisfy(\.isSettled) else {
            throw ProviderHistoryError(.historyChanged)
        }
        if kind == .rewindBeforeRun {
            guard result.reference == source.reference, actual == retained else { throw ProviderHistoryError(.historyChanged) }
        } else {
            guard result.reference != source.reference, let fork = result.fork,
                  fork.sourceSessionID == source.reference.nativeThreadID,
                  Set(actual.map(\.id)).isDisjoint(with: Set(source.messages.map(\.id))) else {
                throw ProviderHistoryError(.historyChanged)
            }
            if case .head = boundary {
                guard let last = source.messages.last, fork.boundary == .throughMessage(last.id) else { throw ProviderHistoryError(.historyChanged) }
            } else { guard fork.boundary == boundary else { throw ProviderHistoryError(.historyChanged) } }
        }
    }
    public func validatesClear(_ observed: OpenCodeV2HistorySnapshot) throws {
        try validate(); try observed.validate()
        guard observed.reference == source.reference, observed.runtimeIdentity == source.runtimeIdentity,
              observed.workspacePath == source.workspacePath, observed.messages == source.messages,
              let stage = observed.stage, stage.isHistoryOnly,
              case .beforeMessage(let cut) = boundary, stage.messageID == cut else { throw ProviderHistoryError(.historyChanged) }
    }
}

enum OpenCodeV2HistoryValidation {
    static func messageID(_ value: String) throws { try ProviderHistoryValidation.id(value); guard value.hasPrefix("msg_") else { throw ProviderHistoryError(.invalidResponse) } }
    static func sessionID(_ value: String) throws { try ProviderHistoryValidation.id(value); guard value.hasPrefix("ses_") else { throw ProviderHistoryError(.invalidResponse) } }
    static func digest(_ value: String) throws {
        guard value.utf8.count == 64, value.utf8.allSatisfy({ (48...57).contains($0) || (97...102).contains($0) }) else { throw ProviderHistoryError(.invalidResponse) }
    }
    static func hash(_ value: some Encodable) -> String {
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        // These callers contain validated bounded scalar records only.
        return SHA256.hash(data: (try? encoder.encode(value)) ?? Data()).map { String(format: "%02x", $0) }.joined()
    }
}
