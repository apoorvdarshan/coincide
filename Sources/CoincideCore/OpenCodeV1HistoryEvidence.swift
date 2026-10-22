import Foundation

/// Bounded native identities and canonical payload hashes, never transcript text.
public struct OpenCodeV1HistoryMessage: Codable, Sendable, Equatable {
    public let id: String
    public let role: MessageRole
    public let parentID: String?
    public let partIDs: [String]
    public let contentDigest: String
    public let isSettled: Bool
    public let isInternalUserInput: Bool
    public init(id: String, role: MessageRole, parentID: String? = nil, partIDs: [String] = [],
                contentDigest: String, isSettled: Bool = true, isInternalUserInput: Bool = false) throws {
        self.id = id; self.role = role; self.parentID = parentID; self.partIDs = partIDs
        self.contentDigest = contentDigest; self.isSettled = isSettled; self.isInternalUserInput = isInternalUserInput
        try validate()
    }
    public func validate() throws {
        try OpenCodeV1HistoryValidation.nativeID(id, prefix: "msg_")
        try OpenCodeV2HistoryValidation.digest(contentDigest)
        if let parentID { try OpenCodeV1HistoryValidation.nativeID(parentID, prefix: "msg_") }
        guard role == .user || role == .assistant, role != .user || parentID == nil,
              role != .assistant || parentID != nil, !isInternalUserInput || role == .user,
              partIDs.count <= 4_096, Set(partIDs).count == partIDs.count else { throw ProviderHistoryError(.invalidResponse) }
        for id in partIDs { try OpenCodeV1HistoryValidation.nativeID(id, prefix: "prt_") }
    }
}

public struct OpenCodeV1HistorySnapshot: Codable, Sendable, Equatable {
    public let reference: ProviderConversationReference
    public let runtimeIdentity: OpenCodeRuntimeIdentity
    public let workspacePath: String
    public let projectID: String
    public let workspaceID: String?
    public let sessionDigest: String
    public let messages: [OpenCodeV1HistoryMessage]
    public let hasRevert: Bool
    public init(reference: ProviderConversationReference, runtimeIdentity: OpenCodeRuntimeIdentity, workspacePath: String,
                projectID: String, workspaceID: String? = nil, sessionDigest: String,
                messages: [OpenCodeV1HistoryMessage], hasRevert: Bool = false) throws {
        self.reference = reference; self.runtimeIdentity = runtimeIdentity; self.workspacePath = workspacePath
        self.projectID = projectID; self.workspaceID = workspaceID; self.sessionDigest = sessionDigest
        self.messages = messages; self.hasRevert = hasRevert; try validate()
    }
    public func validate() throws {
        try reference.validate(); try OpenCodeV1HistoryValidation.nativeID(reference.nativeThreadID, prefix: "ses_")
        try ProviderHistoryValidation.path(workspacePath); try ProviderHistoryValidation.id(projectID)
        if let workspaceID { try ProviderHistoryValidation.id(workspaceID) }
        try OpenCodeV2HistoryValidation.digest(sessionDigest)
        try OpenCodeConfiguration(instanceID: runtimeIdentity.instanceID, generation: runtimeIdentity.generation,
                                  executable: runtimeIdentity.executable).validate()
        guard reference.provider == .opencode, runtimeIdentity.generation == .v1, messages.count <= 10_000 else {
            throw ProviderHistoryError(.invalidResponse)
        }
        var roles: [String: MessageRole] = [:], parts = Set<String>()
        for message in messages {
            try message.validate()
            guard roles[message.id] == nil else { throw ProviderHistoryError(.invalidResponse) }
            if let parent = message.parentID, roles[parent] != .user { throw ProviderHistoryError(.invalidResponse) }
            for part in message.partIDs {
                guard parts.insert(part).inserted, parts.count <= 40_000 else { throw ProviderHistoryError(.invalidResponse) }
            }
            roles[message.id] = message.role
        }
    }
    public var inventoryDigest: String { OpenCodeV2HistoryValidation.hash(self) }
    public var contentDigest: String { Self.contentDigest(messages) }
    private struct Content: Encodable {
        let role: MessageRole, digest: String
        let parent: Int?
        let parts: Int
        let settled: Bool, internalInput: Bool
    }
    public static func contentDigest(_ messages: some Sequence<OpenCodeV1HistoryMessage>) -> String {
        var positions: [String: Int] = [:], values: [Content] = []
        for message in messages {
            values.append(.init(role: message.role, digest: message.contentDigest,
                parent: message.parentID.flatMap { positions[$0] }, parts: message.partIDs.count,
                settled: message.isSettled, internalInput: message.isInternalUserInput))
            positions[message.id] = values.count - 1
        }
        return OpenCodeV2HistoryValidation.hash(values)
    }
    public func matchesBinding(_ configuration: ProviderConfiguration) -> Bool {
        configuration.provider == .opencode && configuration.openCodeConfiguration?.runtimeIdentity == runtimeIdentity &&
            configuration.openCodeConfiguration?.generation == .v1 && configuration.workspacePath == workspacePath
    }
}

public struct OpenCodeV1HistoryRunInput: Codable, Sendable, Equatable {
    public let runID: UUID
    public let originalReference: ProviderConversationReference
    public let originalMessageID: String
    public let openingMessageID: String
    public init(runID: UUID, originalReference: ProviderConversationReference, originalMessageID: String, openingMessageID: String) {
        self.runID = runID; self.originalReference = originalReference
        self.originalMessageID = originalMessageID; self.openingMessageID = openingMessageID
    }
}

/// A receipt for an acknowledged native fork, committed before any further I/O.
/// OpenCode v1 supplies no fork ancestry; this receipt alone is not copy proof.
public struct OpenCodeV1HistoryCandidate: Codable, Sendable, Equatable {
    public let reference: ProviderConversationReference
    public let sourceInventoryDigest: String
    public let runtimeIdentity: OpenCodeRuntimeIdentity
    public let workspacePath: String
    public let boundary: ProviderHistoryBoundary
    public init(reference: ProviderConversationReference, sourceInventoryDigest: String, runtimeIdentity: OpenCodeRuntimeIdentity,
                workspacePath: String, boundary: ProviderHistoryBoundary) throws {
        self.reference = reference; self.sourceInventoryDigest = sourceInventoryDigest; self.runtimeIdentity = runtimeIdentity
        self.workspacePath = workspacePath; self.boundary = boundary; try validate()
    }
    public func validate() throws {
        try reference.validate(); try OpenCodeV1HistoryValidation.nativeID(reference.nativeThreadID, prefix: "ses_")
        try OpenCodeV2HistoryValidation.digest(sourceInventoryDigest); try ProviderHistoryValidation.path(workspacePath)
        try OpenCodeConfiguration(instanceID: runtimeIdentity.instanceID, generation: runtimeIdentity.generation,
                                  executable: runtimeIdentity.executable).validate()
        try boundary.validate()
        guard reference.provider == .opencode, runtimeIdentity.generation == .v1 else { throw ProviderHistoryError(.invalidResponse) }
        switch boundary { case .head, .beforeMessage: break; default: throw ProviderHistoryError(.invalidResponse) }
    }
}

public struct OpenCodeV1HistoryReviewEvidence: Codable, Sendable, Equatable {
    public let source: OpenCodeV1HistorySnapshot
    public let boundary: ProviderHistoryBoundary
    public let retainedMessageCount: Int
    public let selectedOpeningMessageID: String
    public let inputs: [OpenCodeV1HistoryRunInput]
    public init(source: OpenCodeV1HistorySnapshot, boundary: ProviderHistoryBoundary, retainedMessageCount: Int,
                selectedOpeningMessageID: String, inputs: [OpenCodeV1HistoryRunInput]) throws {
        self.source = source; self.boundary = boundary; self.retainedMessageCount = retainedMessageCount
        self.selectedOpeningMessageID = selectedOpeningMessageID; self.inputs = inputs; try validate()
    }
    public var retainedContentDigest: String { OpenCodeV1HistorySnapshot.contentDigest(source.messages.prefix(retainedMessageCount)) }

    public static func localInputs(in snapshot: WorkspaceSnapshot, thread: CodingThread,
                                   observed: OpenCodeV1HistorySnapshot) throws -> [OpenCodeV1HistoryRunInput] {
        try observed.validate()
        guard observed.reference.nativeThreadID == thread.providerThreadID, observed.matchesBinding(.init(thread: thread)) else {
            throw ProviderHistoryError(.historyChanged)
        }
        let edges = try adoptionEdges(operations: snapshot.conversationHistoryOperations ?? [], threadID: thread.id, runtime: observed.runtimeIdentity, path: observed.workspacePath)
        let target = IndexedSnapshot(observed)
        var resolver = Resolver(edges: edges)
        return try thread.activeHistoryRuns.map { run in
            guard run.status.isTerminal, run.origin == .user, run.messageAttributionVersion == 1,
                  run.configuration.provider == .opencode,
                  run.configuration.openCodeConfiguration?.runtimeIdentity == observed.runtimeIdentity,
                  run.configuration.workspacePath == observed.workspacePath, run.turnIDs.count == 1,
                  let originalID = run.providerThreadID, let inputID = run.turnIDs.first else {
                throw ProviderHistoryError(.boundaryUnavailable)
            }
            let original = try ProviderConversationReference(provider: .opencode, nativeThreadID: originalID)
            let opening = try resolver.resolve(reference: original, messageID: inputID, target: target)
            guard let message = target.message(opening), message.role == .user, !message.isInternalUserInput else {
                throw ProviderHistoryError(.historyChanged)
            }
            return .init(runID: run.id, originalReference: original, originalMessageID: inputID, openingMessageID: opening)
        }
    }
    public static func make(source: OpenCodeV1HistorySnapshot, snapshot: WorkspaceSnapshot, thread: CodingThread,
                            runID: UUID, kind: ConversationHistoryKind) throws -> Self {
        let inputs = try localInputs(in: snapshot, thread: thread, observed: source)
        guard let selected = inputs.firstIndex(where: { $0.runID == runID }) else { throw ProviderHistoryError(.boundaryUnavailable) }
        let cut = kind == .rewindBeforeRun ? inputs[selected].openingMessageID :
            (selected + 1 < inputs.count ? inputs[selected + 1].openingMessageID : nil)
        let count = try cut.map { id in
            guard let position = source.messages.firstIndex(where: { $0.id == id }) else { throw ProviderHistoryError(.historyChanged) }
            return position
        } ?? source.messages.count
        return try .init(source: source, boundary: cut.map(ProviderHistoryBoundary.beforeMessage) ?? .head,
            retainedMessageCount: count, selectedOpeningMessageID: inputs[selected].openingMessageID, inputs: inputs)
    }
    public func validate() throws {
        try source.validate(); try boundary.validate()
        try OpenCodeV1HistoryValidation.nativeID(selectedOpeningMessageID, prefix: "msg_")
        guard !source.hasRevert, source.messages.allSatisfy(\.isSettled), !inputs.isEmpty, inputs.count <= 10_000,
              Set(inputs.map(\.runID)).count == inputs.count, (0...source.messages.count).contains(retainedMessageCount),
              inputs.contains(where: { $0.openingMessageID == selectedOpeningMessageID }) else { throw ProviderHistoryError(.invalidRequest) }
        let positions = Dictionary(uniqueKeysWithValues: source.messages.enumerated().map { ($0.element.id, $0.offset) })
        var claimed = Set<String>(), previous = -1
        for input in inputs {
            try input.originalReference.validate()
            try OpenCodeV1HistoryValidation.nativeID(input.originalReference.nativeThreadID, prefix: "ses_")
            try OpenCodeV1HistoryValidation.nativeID(input.originalMessageID, prefix: "msg_")
            guard input.originalReference.provider == .opencode, claimed.insert(input.openingMessageID).inserted,
                  let position = positions[input.openingMessageID], position > previous,
                  source.messages[position].role == .user, !source.messages[position].isInternalUserInput else {
                throw ProviderHistoryError(.boundaryUnavailable)
            }
            previous = position
        }
        guard let first = inputs.first.flatMap({ positions[$0.openingMessageID] }),
              source.messages[first...].filter({ $0.role == .user && !$0.isInternalUserInput }).allSatisfy({ claimed.contains($0.id) }) else {
            throw ProviderHistoryError(.boundaryUnavailable)
        }
        switch boundary {
        case .head: guard retainedMessageCount == source.messages.count else { throw ProviderHistoryError(.invalidRequest) }
        case .beforeMessage(let id):
            guard positions[id] == retainedMessageCount, claimed.contains(id),
                  source.messages.firstIndex(where: { $0.id >= id }) == retainedMessageCount else { throw ProviderHistoryError(.boundaryUnavailable) }
        default: throw ProviderHistoryError(.invalidRequest)
        }
    }
    public func validateResult(_ result: OpenCodeV1HistorySnapshot, kind: ConversationHistoryKind) throws {
        try validate(); try result.validate()
        guard result.reference != source.reference, result.runtimeIdentity == source.runtimeIdentity,
              result.workspacePath == source.workspacePath, result.projectID == source.projectID, result.workspaceID == source.workspaceID,
              !result.hasRevert, result.messages.allSatisfy(\.isSettled), result.messages.count == retainedMessageCount,
              result.contentDigest == retainedContentDigest,
              Set(result.messages.map(\.id)).isDisjoint(with: Set(source.messages.map(\.id))),
              Set(result.messages.flatMap(\.partIDs)).isDisjoint(with: Set(source.messages.flatMap(\.partIDs))) else {
            throw ProviderHistoryError(.historyChanged)
        }
        if kind == .rewindBeforeRun {
            guard boundary == .beforeMessage(selectedOpeningMessageID) else { throw ProviderHistoryError(.invalidRequest) }
        } else {
            guard let selected = inputs.firstIndex(where: { $0.openingMessageID == selectedOpeningMessageID }),
                  boundary == (selected + 1 < inputs.count ? .beforeMessage(inputs[selected + 1].openingMessageID) : .head) else {
                throw ProviderHistoryError(.invalidRequest)
            }
        }
    }
    public func validateCandidate(_ candidate: OpenCodeV1HistoryCandidate) throws {
        try validate(); try candidate.validate()
        guard candidate.reference != source.reference, candidate.sourceInventoryDigest == source.inventoryDigest,
              candidate.runtimeIdentity == source.runtimeIdentity, candidate.workspacePath == source.workspacePath,
              candidate.boundary == boundary else { throw ProviderHistoryError(.historyChanged) }
    }

    private struct Owner: Equatable {
        let runtime: OpenCodeRuntimeIdentity
        let path: String
        let project: String
        let workspace: String?
    }
    /// Constructed only after snapshot validation has rejected duplicate IDs.
    private struct IndexedSnapshot {
        let snapshot: OpenCodeV1HistorySnapshot
        let positions: [String: Int]
        let owner: Owner
        init(_ snapshot: OpenCodeV1HistorySnapshot) {
            self.snapshot = snapshot
            positions = Dictionary(uniqueKeysWithValues: snapshot.messages.enumerated().map { ($0.element.id, $0.offset) })
            owner = .init(runtime: snapshot.runtimeIdentity, path: snapshot.workspacePath,
                          project: snapshot.projectID, workspace: snapshot.workspaceID)
        }
        func message(_ id: String) -> OpenCodeV1HistoryMessage? {
            positions[id].map { snapshot.messages[$0] }
        }
    }
    private struct Edge {
        let source: IndexedSnapshot
        let result: IndexedSnapshot
    }
    private static func adoptionEdges(operations: [ConversationHistoryOperation], threadID: UUID, runtime: OpenCodeRuntimeIdentity,
                                      path: String) throws -> [String: Edge] {
        var edges: [String: Edge] = [:], targets = Set<String>()
        for operation in operations where operation.phase == .applied &&
            operation.review.sourceThreadID == threadID && operation.review.kind == .rewindBeforeRun {
            guard let proof = operation.review.openCodeV1, proof.source.runtimeIdentity == runtime,
                  proof.source.workspacePath == path else { continue }
            guard let result = operation.result?.openCodeV1, let candidate = operation.openCodeV1Candidate else {
                throw ProviderHistoryError(.invalidResponse)
            }
            try proof.validateCandidate(candidate); try proof.validateResult(result, kind: .rewindBeforeRun)
            let id = proof.source.reference.nativeThreadID
            guard candidate.reference == result.reference, edges[id] == nil,
                  targets.insert(result.reference.nativeThreadID).inserted else { throw ProviderHistoryError(.invalidResponse) }
            edges[id] = .init(source: .init(proof.source), result: .init(result))
        }
        return edges
    }
    /// One immutable validation/read owns this memo. Entries retain checked
    /// endpoint user records, so reusing a path never skips a changed target or
    /// a changed user at a bridge. Assistant/tool pruning remains permitted.
    private struct Resolver {
        struct Key: Hashable { let native: String; let message: String; let target: String }
        struct Resolution {
            let opening: String
            let startOwner: Owner
            let startInput: OpenCodeV1HistoryMessage
            let endOwner: Owner
            let endInput: OpenCodeV1HistoryMessage
        }
        struct Step { let key: Key; let owner: Owner; let input: OpenCodeV1HistoryMessage }
        let edges: [String: Edge]
        private var memo: [Key: Resolution] = [:]
        init(edges: [String: Edge]) { self.edges = edges }

        mutating func resolve(reference: ProviderConversationReference, messageID: String,
                              target: IndexedSnapshot) throws -> String {
            try OpenCodeV1HistoryValidation.nativeID(messageID, prefix: "msg_")
            var native = reference.nativeThreadID, message = messageID, seen = Set<String>()
            var priorOwner: Owner?, expectedInput: OpenCodeV1HistoryMessage?
            var path: [Step] = [], endpoint: (Owner, OpenCodeV1HistoryMessage)?
            while true {
                if native == target.snapshot.reference.nativeThreadID {
                    if let priorOwner, let expectedInput {
                        guard target.owner == priorOwner, target.message(expectedInput.id) == expectedInput else {
                            throw ProviderHistoryError(.historyChanged)
                        }
                        endpoint = (priorOwner, expectedInput)
                    } else { return message }
                    break
                }
                let key = Key(native: native, message: message, target: target.snapshot.reference.nativeThreadID)
                if let cached = memo[key] {
                    if let priorOwner, let expectedInput {
                        guard cached.startOwner == priorOwner, cached.startInput == expectedInput else {
                            throw ProviderHistoryError(.boundaryUnavailable)
                        }
                    }
                    guard target.owner == cached.endOwner, target.message(cached.endInput.id) == cached.endInput else {
                        throw ProviderHistoryError(.historyChanged)
                    }
                    message = cached.opening; endpoint = (cached.endOwner, cached.endInput)
                    break
                }
                guard seen.insert(native).inserted, seen.count <= 10_000, let edge = edges[native] else {
                    throw ProviderHistoryError(.boundaryUnavailable)
                }
                if let priorOwner, let expectedInput {
                    guard edge.source.owner == priorOwner, edge.source.message(expectedInput.id) == expectedInput else {
                        throw ProviderHistoryError(.boundaryUnavailable)
                    }
                }
                guard let position = edge.source.positions[message], position < edge.result.snapshot.messages.count else {
                    throw ProviderHistoryError(.boundaryUnavailable)
                }
                let source = edge.source.snapshot.messages[position], result = edge.result.snapshot.messages[position]
                guard source.role == .user, !source.isInternalUserInput, result.role == .user, !result.isInternalUserInput else {
                    throw ProviderHistoryError(.boundaryUnavailable)
                }
                path.append(.init(key: key, owner: edge.source.owner, input: source))
                priorOwner = edge.result.owner; expectedInput = result
                native = edge.result.snapshot.reference.nativeThreadID; message = result.id
            }
            guard let endpoint else { throw ProviderHistoryError(.boundaryUnavailable) }
            // Memoization is optional and bounded independently of the durable
            // ledger. Hitting this cap changes cost only, never accepted proof.
            for step in path.reversed() where memo.count < 40_000 || memo[step.key] != nil {
                memo[step.key] = .init(opening: message, startOwner: step.owner, startInput: step.input,
                                     endOwner: endpoint.0, endInput: endpoint.1)
            }
            return message
        }
    }
    /// Positional copy proofs preserve immutable run references across repeated
    /// native adoptions. Validate a finite, unbranched graph before using a map.
    public static func validateAdoptionLedger(in snapshot: WorkspaceSnapshot) throws {
        struct Scope: Hashable { let thread: UUID; let runtime: OpenCodeRuntimeIdentity; let path: String }
        let operations = (snapshot.conversationHistoryOperations ?? []).filter { $0.review.openCodeV1 != nil }
        guard operations.count <= 10_000 else { throw ProviderHistoryError(.limitExceeded) }
        let grouped = Dictionary(grouping: operations.filter { $0.phase == .applied }) { operation in
            let source = operation.review.openCodeV1!.source
            return Scope(thread: operation.review.sourceThreadID, runtime: source.runtimeIdentity, path: source.workspacePath)
        }
        for (scope, operations) in grouped {
            let edges = try adoptionEdges(operations: operations, threadID: scope.thread, runtime: scope.runtime, path: scope.path)
            var done = Set<String>()
            for start in edges.keys where !done.contains(start) {
                var current = start, visiting = Set<String>()
                while !done.contains(current), let edge = edges[current] {
                    guard visiting.insert(current).inserted else { throw ProviderHistoryError(.invalidResponse) }
                    current = edge.result.snapshot.reference.nativeThreadID
                }
                done.formUnion(visiting)
            }
            if let thread = snapshot.threads.first(where: { $0.id == scope.thread }) {
                let runs = Dictionary(grouping: thread.runHistory ?? [], by: \.id).mapValues { $0[0] }
                var resolver = Resolver(edges: edges)
                for operation in operations where operation.phase == .applied && operation.review.sourceThreadID == scope.thread {
                    guard let review = operation.review.openCodeV1, review.source.runtimeIdentity == scope.runtime,
                          review.source.workspacePath == scope.path else { continue }
                    let target = IndexedSnapshot(review.source)
                    for input in review.inputs {
                        guard let run = runs[input.runID],
                              run.providerThreadID == input.originalReference.nativeThreadID, run.turnIDs == [input.originalMessageID],
                              run.configuration.openCodeConfiguration?.runtimeIdentity == scope.runtime,
                              run.configuration.workspacePath == scope.path,
                              try resolver.resolve(reference: input.originalReference, messageID: input.originalMessageID,
                                  target: target) == input.openingMessageID else {
                            throw ProviderHistoryError(.invalidResponse)
                        }
                    }
                }
            }
        }
    }
}

enum OpenCodeV1HistoryValidation {
    static func nativeID(_ value: String, prefix: String) throws {
        try ProviderHistoryValidation.id(value)
        guard value.hasPrefix(prefix), value.utf8.count > prefix.utf8.count,
              value.utf8.allSatisfy({ (48...57).contains($0) || (65...90).contains($0) || (97...122).contains($0) || $0 == 95 || $0 == 45 }) else {
            throw ProviderHistoryError(.invalidResponse)
        }
    }
}
