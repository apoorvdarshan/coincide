import CryptoKit
import Foundation

/// Hashes native payloads without persisting another copy of private prompts.
/// Native envelope UUIDs remain distinct from API message IDs and local turns.
public struct ClaudeHistoryRecord: Codable, Sendable, Equatable {
    public let id: String?
    public let kind: String
    public let parentID: String?
    public let digest: String
    public let contentDigest: String
    public let isRoot: Bool
    public let isUserInput: Bool

    init(_ value: JSONValue, projected: Bool = false) throws {
        id = value["uuid"].string; kind = value["type"].string ?? ""
        parentID = projected ? nil : value["parentUuid"].string
        digest = try ClaudeHistoryValidation.hash(value)
        contentDigest = try ClaudeHistoryValidation.hash(value["message"])
        isRoot = value["isSidechain"] != .bool(true) && value["isMeta"] != .bool(true) &&
            (value["teamName"] == .null || value["teamName"].string == "") &&
            value["parent_tool_use_id"] == .null && value["parent_agent_id"] == .null
        let toolResult = value["message"]["content"].array?.contains { $0["type"].string == "tool_result" } == true
        isUserInput = kind == "user" && isRoot && !toolResult && value["is_meta"] != .bool(true) &&
            value["isCompactSummary"] != .bool(true) && value["isCompletedLocalCommand"] != .bool(true)
        try validate()
    }
    public func validate() throws {
        if let id { try ClaudeRuntimeValidation.uuid(id) }
        if let parentID { try ClaudeRuntimeValidation.uuid(parentID) }
        guard !kind.isEmpty, kind.utf8.count <= 256, !kind.contains("\0"),
              ClaudeHistoryValidation.isDigest(digest), ClaudeHistoryValidation.isDigest(contentDigest),
              !isUserInput || (kind == "user" && isRoot && id != nil) else { throw ClaudeHistoryValidation.invalid() }
    }
}

/// A physical native source revision plus its effective selected context. A
/// pending rewind changes only selection, never the raw revision/graph proof.
public struct ClaudeHistorySnapshot: Codable, Sendable, Equatable {
    public let reference: ProviderConversationReference
    public let runtimeIdentity: ClaudeRuntimeIdentity
    public let sourceLocation: ClaudeTranscriptLocation?
    public let sourceRevision: ClaudeTranscriptRevision?
    public let records: [ClaudeHistoryRecord]
    public let selectedMessages: [ClaudeHistoryRecord]
    public let selectedChainIDs: [String]
    public let selection: ClaudeResumeSelection?
    public var workspacePath: String { runtimeIdentity.registeredWorkspacePath }
    public var selectedMessageIDs: [String] { selectedMessages.compactMap(\.id) }
    public var graphDigest: String { (try? ClaudeHistoryValidation.hash(records)) ?? "" }
    public var headMessageID: String? { selectedMessages.last?.id }
    public var location: ClaudeTranscriptLocation? { sourceLocation }
    public var revision: ClaudeTranscriptRevision? { sourceRevision }

    public init(reference: ProviderConversationReference, runtimeIdentity: ClaudeRuntimeIdentity,
                sourceLocation: ClaudeTranscriptLocation?, sourceRevision: ClaudeTranscriptRevision?,
                records: [ClaudeHistoryRecord], selectedMessages: [ClaudeHistoryRecord], selectedChainIDs: [String],
                selection: ClaudeResumeSelection? = nil) throws {
        self.reference = reference; self.runtimeIdentity = runtimeIdentity
        self.sourceLocation = sourceLocation; self.sourceRevision = sourceRevision
        self.records = records; self.selectedMessages = selectedMessages; self.selectedChainIDs = selectedChainIDs
        self.selection = selection; try validate()
    }

    public func validate() throws {
        try reference.validate(); try ClaudeRuntimeValidation.uuid(reference.nativeThreadID); try runtimeIdentity.validate()
        try selection?.validate()
        guard reference.provider == .claude, records.count <= ClaudeTranscript.maximumRecords,
              selectedMessages.count <= ClaudeTranscript.maximumRecords, selectedChainIDs.count <= ClaudeTranscript.maximumRecords,
              Set(records.compactMap(\.id).map { $0.lowercased() }).count == records.compactMap(\.id).count,
              Set(selectedMessageIDs.map { $0.lowercased() }).count == selectedMessages.count,
              Set(selectedChainIDs.map { $0.lowercased() }).count == selectedChainIDs.count,
              selection == nil || selection?.nativeSessionID == reference.nativeThreadID else { throw ClaudeHistoryValidation.invalid() }
        for record in records + selectedMessages { try record.validate() }
        for id in selectedChainIDs { try ClaudeRuntimeValidation.uuid(id) }
        guard selectedMessages.allSatisfy({ $0.id != nil && $0.isRoot && ($0.kind == "user" || $0.kind == "assistant") }) else {
            throw ClaudeHistoryValidation.invalid()
        }
        switch (sourceLocation, sourceRevision) {
        case (.some(let location), .some(let revision)):
            try location.validate(); try revision.validate()
            let legacyProject = try ClaudeTranscriptStore.projectDirectoryName(forPhysicalWorkspacePath: runtimeIdentity.workspacePath)
            guard location.sessionID == reference.nativeThreadID, location.configurationDirectory == runtimeIdentity.configurationDirectory,
                  location.workspacePath == runtimeIdentity.workspacePath,
                  location.projectDirectoryName == runtimeIdentity.projectKey || location.projectDirectoryName == legacyProject,
                  selection?.kind != .freshSession,
                  selection?.reviewedLocation == nil || selection?.reviewedLocation == location,
                  selection?.reviewedRevision == nil || selection?.reviewedRevision == revision else { throw ClaudeHistoryValidation.invalid() }
            if let selection { guard selection.cursor == headMessageID else { throw ClaudeHistoryValidation.invalid() } }
            let rawIDs = Set(records.compactMap(\.id))
            guard selectedChainIDs.allSatisfy(rawIDs.contains) else { throw ClaudeHistoryValidation.invalid() }
        case (.none, .none):
            guard let selection, selection.kind == .freshSession, records.isEmpty, selectedMessages.isEmpty, selectedChainIDs.isEmpty else {
                throw ClaudeHistoryValidation.invalid()
            }
        default: throw ClaudeHistoryValidation.invalid()
        }
    }

    public func matchesBinding(_ configuration: ProviderConfiguration) -> Bool {
        configuration.provider == .claude && configuration.claudeRuntimeConfiguration?.runtimeIdentity == runtimeIdentity &&
            configuration.workspacePath == workspacePath
    }
}

public enum ClaudeHistoryBoundary: Codable, Sendable, Equatable {
    case throughMessage(String)
    /// A reserved new native session. No transcript exists until explicit send.
    case freshSession(String)
    public var providerBoundary: ProviderHistoryBoundary {
        switch self { case .throughMessage(let id): .throughClaudeMessage(id); case .freshSession(let id): .freshClaudeSession(id) }
    }
    public func validate() throws {
        switch self { case .throughMessage(let id), .freshSession(let id): try ClaudeRuntimeValidation.uuid(id) }
    }
}

public struct ClaudeHistoryRunInput: Codable, Sendable, Equatable {
    public let runID: UUID
    public let openingInputID: String
    public let steeringInputs: [ClaudeSteeringInputEvidence]
    public let rootAssistantMessageIDs: [String]
    public var inputIDs: [String] { [openingInputID] + steeringInputs.map(\.nativeInputID) }
    public init(runID: UUID, openingInputID: String, steeringInputs: [ClaudeSteeringInputEvidence], rootAssistantMessageIDs: [String]) throws {
        self.runID = runID; self.openingInputID = openingInputID; self.steeringInputs = steeringInputs
        self.rootAssistantMessageIDs = rootAssistantMessageIDs; try validate()
    }
    public func validate() throws {
        guard openingInputID == ClaudeInputIdentity.opening(runID: runID), steeringInputs.count < ClaudeRunHistoryEvidence.maximumInputs,
              rootAssistantMessageIDs.count <= ClaudeRunHistoryEvidence.maximumAssistants,
              Set(inputIDs).count == inputIDs.count, Set(rootAssistantMessageIDs).count == rootAssistantMessageIDs.count else {
            throw ClaudeHistoryValidation.invalid()
        }
        for value in steeringInputs { try value.validate() }
        for id in rootAssistantMessageIDs { try ClaudeRuntimeValidation.uuid(id) }
    }
}

public struct ClaudeHistoryReviewEvidence: Codable, Sendable, Equatable {
    public let source: ClaudeHistorySnapshot
    public let kind: ConversationHistoryKind
    public let runID: UUID
    public let inputs: [ClaudeHistoryRunInput]
    public let boundary: ClaudeHistoryBoundary
    public let retainedMessageIDs: [String]
    public let inheritedHead: ClaudeInheritedHead?
    public init(source: ClaudeHistorySnapshot, kind: ConversationHistoryKind, runID: UUID, inputs: [ClaudeHistoryRunInput],
                boundary: ClaudeHistoryBoundary, retainedMessageIDs: [String], inheritedHead: ClaudeInheritedHead? = nil) throws {
        self.source = source; self.kind = kind; self.runID = runID; self.inputs = inputs; self.boundary = boundary
        self.retainedMessageIDs = retainedMessageIDs; self.inheritedHead = inheritedHead; try validate()
    }

    public func validate() throws {
        try source.validate(); try boundary.validate(); try inheritedHead?.validate()
        guard !inputs.isEmpty, inputs.count <= 10_000, Set(inputs.map(\.runID)).count == inputs.count,
              let selected = inputs.firstIndex(where: { $0.runID == runID }),
              retainedMessageIDs.count <= source.selectedMessages.count,
              Array(source.selectedMessageIDs.prefix(retainedMessageIDs.count)) == retainedMessageIDs else { throw ClaudeHistoryValidation.invalid() }
        let positions = Dictionary(uniqueKeysWithValues: source.selectedMessageIDs.enumerated().map { ($0.element, $0.offset) })
        var previous = -1, allInputs = Set<String>()
        for (runIndex, input) in inputs.enumerated() {
            try input.validate()
            for id in input.inputIDs {
                guard let index = positions[id], index > previous, source.selectedMessages[index].isUserInput,
                      allInputs.insert(id).inserted else { throw ClaudeHistoryValidation.invalid() }
                previous = index
            }
            var previousAssistant = positions[input.openingInputID] ?? -1
            let nextOpening = runIndex + 1 < inputs.count ? positions[inputs[runIndex + 1].openingInputID] : nil
            for id in input.rootAssistantMessageIDs {
                guard let index = positions[id], index > previousAssistant,
                      nextOpening == nil || index < nextOpening!,
                      source.selectedMessages[index].kind == "assistant" else { throw ClaudeHistoryValidation.invalid() }
                previousAssistant = index
            }
            if let final = input.rootAssistantMessageIDs.last {
                guard positions[final]! > positions[input.inputIDs.last!]! else { throw ClaudeHistoryValidation.invalid() }
            }
        }
        if let first = inputs.first.flatMap({ positions[$0.openingInputID] }) {
            guard source.selectedMessages.dropFirst(first).filter(\.isUserInput).allSatisfy({ allInputs.contains($0.id!) }) else {
                throw ClaudeHistoryValidation.invalid()
            }
        }
        if let inheritedHead {
            guard inheritedHead.runtimeIdentity == source.runtimeIdentity, inheritedHead.nativeSessionID == source.reference.nativeThreadID,
                  let index = positions[inheritedHead.cursor], index < (positions[inputs[0].openingInputID] ?? -1),
                  source.selectedMessages[index].kind == "assistant" else { throw ClaudeHistoryValidation.invalid() }
        }
        switch boundary {
        case .throughMessage(let cursor):
            guard let end = positions[cursor], source.selectedMessages[end].kind == "assistant",
                  retainedMessageIDs == Array(source.selectedMessageIDs.prefix(end + 1)) else { throw ClaudeHistoryValidation.invalid() }
            switch kind {
            case .forkAfterRun:
                guard inputs[selected].rootAssistantMessageIDs.last == cursor,
                      selected + 1 == inputs.count || end < positions[inputs[selected + 1].openingInputID]! else { throw ClaudeHistoryValidation.invalid() }
            case .rewindBeforeRun:
                guard end < positions[inputs[selected].openingInputID]!,
                      (selected > 0 && inputs[selected - 1].rootAssistantMessageIDs.last == cursor) || (selected == 0 && inheritedHead?.cursor == cursor) else {
                    throw ClaudeHistoryValidation.invalid()
                }
            }
        case .freshSession(let nativeID):
            guard kind == .rewindBeforeRun, selected == 0, inheritedHead == nil, retainedMessageIDs.isEmpty,
                  nativeID != source.reference.nativeThreadID else { throw ClaudeHistoryValidation.invalid() }
        }
    }

    /// Both three-choice dialog alternatives independently revalidate source.
    /// Only the unused fresh-session reservation may differ between them.
    public func sameLogicalBoundary(as other: Self) -> Bool {
        guard source == other.source, kind == other.kind, runID == other.runID, inputs == other.inputs,
              retainedMessageIDs == other.retainedMessageIDs, inheritedHead == other.inheritedHead else { return false }
        switch (boundary, other.boundary) {
        case (.freshSession, .freshSession): return true
        default: return boundary == other.boundary
        }
    }

    public static func make(source: ClaudeHistorySnapshot, snapshot: WorkspaceSnapshot, thread: CodingThread,
                            runID: UUID, kind: ConversationHistoryKind) throws -> Self {
        try source.validate()
        guard source.matchesBinding(.init(thread: thread)), thread.providerThreadID == source.reference.nativeThreadID,
              thread.claudeResumeSelection == source.selection else { throw ClaudeHistoryValidation.invalid() }
        let runs = (thread.runHistory ?? []).filter { $0.removedByHistoryOperationID == nil }
        guard let selected = runs.firstIndex(where: { $0.id == runID }), runs.count <= 10_000 else { throw ClaudeHistoryValidation.invalid() }
        let native = Dictionary(uniqueKeysWithValues: source.selectedMessages.map { ($0.id!, $0) })
        var inputs: [ClaudeHistoryRunInput] = []
        for run in runs {
            guard run.origin == .user, run.status.isTerminal, run.messageAttributionVersion == 1,
                  source.matchesBinding(run.configuration), let evidence = run.claude,
                  evidence.runID == run.id, evidence.runtimeIdentity == source.runtimeIdentity,
                  evidence.nativeSessionID == source.reference.nativeThreadID, evidence.terminalStatus == run.status,
                  let row = thread.messages.first(where: { $0.id == run.userMessageID }), row.role == .user,
                  row.runReference == .init(threadID: thread.id, runID: run.id), row.removedByHistoryOperationID == nil,
                  native[evidence.openingInputID]?.isUserInput == true else { throw ClaudeHistoryValidation.invalid() }
            try evidence.validate()
            guard evidence.observedInputIDs.allSatisfy({ native[$0]?.isUserInput == true }) else { throw ClaudeHistoryValidation.invalid() }
            var steers: [ClaudeSteeringInputEvidence] = []
            for steer in evidence.steeringInputs {
                guard let operation = snapshot.promptSteerings?.first(where: { $0.threadID == thread.id && $0.runID == run.id && $0.messageID == steer.messageID }),
                      operation.configuration.claudeRuntimeConfiguration?.runtimeIdentity == source.runtimeIdentity,
                      operation.nativeThreadID == source.reference.nativeThreadID else { throw ClaudeHistoryValidation.invalid() }
                if native[steer.nativeInputID] != nil {
                    guard operation.phase == .delivered || operation.phase == .unconfirmed,
                          native[steer.nativeInputID]?.isUserInput == true,
                          thread.messages.contains(where: { $0.id == steer.messageID && $0.promptSteeringID == operation.id && $0.runReference == .init(threadID: thread.id, runID: run.id) }) else {
                        throw ClaudeHistoryValidation.invalid()
                    }
                    steers.append(steer)
                } else if operation.phase == .delivered { throw ClaudeHistoryValidation.invalid() }
            }
            let assistants = evidence.rootAssistantMessageIDs.filter { native[$0] != nil }
            guard assistants.count == evidence.rootAssistantMessageIDs.count else { throw ClaudeHistoryValidation.invalid() }
            inputs.append(try .init(runID: run.id, openingInputID: evidence.openingInputID, steeringInputs: steers, rootAssistantMessageIDs: assistants))
        }
        let boundary: ClaudeHistoryBoundary
        if kind == .forkAfterRun {
            guard runs[selected].status == .completed, let end = inputs[selected].rootAssistantMessageIDs.last else { throw ClaudeHistoryValidation.invalid() }
            boundary = .throughMessage(end)
        } else if selected > 0 {
            guard let end = inputs[selected - 1].rootAssistantMessageIDs.last else { throw ClaudeHistoryValidation.invalid() }
            boundary = .throughMessage(end)
        } else if let inherited = thread.claudeInheritedHead {
            boundary = .throughMessage(inherited.cursor)
        } else { boundary = .freshSession(UUID().uuidString.lowercased()) }
        let retained: [String]
        switch boundary {
        case .throughMessage(let id):
            guard let index = source.selectedMessageIDs.firstIndex(of: id) else { throw ClaudeHistoryValidation.invalid() }
            retained = Array(source.selectedMessageIDs.prefix(index + 1))
        case .freshSession: retained = []
        }
        return try .init(source: source, kind: kind, runID: runID, inputs: inputs, boundary: boundary,
                         retainedMessageIDs: retained, inheritedHead: thread.claudeInheritedHead)
    }

    public func validatePublication(_ publication: ClaudeTranscriptPublication) throws {
        try validate(); try publication.validate()
        guard kind == .forkAfterRun, let location = source.sourceLocation, let revision = source.sourceRevision,
              publication.source == location, publication.sourceRevision == revision,
              case .throughMessage(let cursor) = boundary, publication.upToMessageID == cursor,
              publication.target.sessionID != source.reference.nativeThreadID,
              publication.headMessageID == publication.sourceToForkMessageIDs[cursor] else { throw ClaudeHistoryValidation.invalid() }
    }

    public func validateResult(_ result: ClaudeHistoryResult) throws {
        try validate(); try result.validate()
        switch result {
        case .fork(let target, let publication, let inherited):
            try validatePublication(publication)
            guard kind == .forkAfterRun, target.sourceLocation == publication.target,
                  target.sourceRevision?.digest == publication.targetDigest, target.sourceRevision?.byteCount == publication.targetByteCount,
                  target.runtimeIdentity == source.runtimeIdentity, target.reference.nativeThreadID == publication.target.sessionID,
                  inherited.cursor == publication.headMessageID else { throw ClaudeHistoryValidation.invalid() }
            let retained = Array(source.selectedMessages.prefix(retainedMessageIDs.count))
            guard target.selectedMessages.count == retained.count else { throw ClaudeHistoryValidation.invalid() }
            for (original, copy) in zip(retained, target.selectedMessages) {
                let expectedID = original.id.flatMap { publication.sourceToForkMessageIDs[$0] ?? $0 }
                guard copy.id == expectedID, copy.kind == original.kind, copy.contentDigest == original.contentDigest,
                      copy.isUserInput == original.isUserInput else { throw ClaudeHistoryValidation.invalid() }
            }
        case .contextSelected(let observed, let selection):
            guard kind == .rewindBeforeRun, observed == source else { throw ClaudeHistoryValidation.invalid() }
            switch boundary {
            case .throughMessage(let cursor):
                guard selection.kind == .resumeAt, selection.nativeSessionID == source.reference.nativeThreadID,
                      selection.cursor == cursor, selection.reviewedLocation == source.sourceLocation,
                      selection.reviewedRevision == source.sourceRevision,
                      selection.discardedInputID == inputs.first(where: { $0.runID == runID })?.openingInputID else { throw ClaudeHistoryValidation.invalid() }
            case .freshSession(let id):
                guard selection.kind == .freshSession, selection.nativeSessionID == id else { throw ClaudeHistoryValidation.invalid() }
            }
        }
    }
}

public enum ClaudeHistoryResult: Codable, Sendable, Equatable {
    case fork(snapshot: ClaudeHistorySnapshot, publication: ClaudeTranscriptPublication, inheritedHead: ClaudeInheritedHead)
    case contextSelected(source: ClaudeHistorySnapshot, selection: ClaudeResumeSelection)
    public var reference: ProviderConversationReference {
        switch self {
        case .fork(let snapshot, _, _): snapshot.reference
        case .contextSelected(let source, let selection):
            // Invalid decoded selections still fail validate(); property access
            // must never turn untrusted journal bytes into a forced unwrap.
            (try? .init(provider: .claude, nativeThreadID: selection.nativeSessionID)) ?? source.reference
        }
    }
    public var workspacePath: String {
        switch self { case .fork(let snapshot, _, _), .contextSelected(let snapshot, _): snapshot.workspacePath }
    }
    public var selection: ClaudeResumeSelection? { if case .contextSelected(_, let value) = self { value } else { nil } }
    public var publication: ClaudeTranscriptPublication? { if case .fork(_, let value, _) = self { value } else { nil } }
    public var inheritedHead: ClaudeInheritedHead? { if case .fork(_, _, let value) = self { value } else { nil } }
    public func validate() throws {
        switch self {
        case .fork(let snapshot, let publication, let inherited):
            try snapshot.validate(); try publication.validate(); try inherited.validate()
            guard snapshot.selection == nil, snapshot.sourceLocation == publication.target,
                  snapshot.sourceRevision?.digest == publication.targetDigest,
                  snapshot.sourceRevision?.byteCount == publication.targetByteCount,
                  inherited.runtimeIdentity == snapshot.runtimeIdentity, inherited.nativeSessionID == snapshot.reference.nativeThreadID,
                  inherited.cursor == publication.headMessageID, inherited.cursor == snapshot.headMessageID else { throw ClaudeHistoryValidation.invalid() }
        case .contextSelected(let source, let selection):
            try source.validate(); try selection.validate()
            switch selection.kind {
            case .resumeAt:
                guard selection.nativeSessionID == source.reference.nativeThreadID,
                      selection.reviewedLocation == source.sourceLocation, selection.reviewedRevision == source.sourceRevision,
                      source.selectedMessages.contains(where: { $0.id == selection.cursor && $0.kind == "assistant" }) else { throw ClaudeHistoryValidation.invalid() }
            case .freshSession:
                guard selection.nativeSessionID != source.reference.nativeThreadID else { throw ClaudeHistoryValidation.invalid() }
            }
        }
    }
}

enum ClaudeHistoryValidation {
    static func invalid() -> CoincideError { .init("The Claude history boundary is unavailable or does not prove exact native input ownership. Nothing was replayed.") }
    static func isDigest(_ value: String) -> Bool { value.utf8.count == 64 && value.utf8.allSatisfy { (48...57).contains($0) || (97...102).contains($0) } }
    static func hash<T: Encodable>(_ value: T) throws -> String {
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        return SHA256.hash(data: try encoder.encode(value)).map { String(format: "%02x", $0) }.joined()
    }
}
