import Foundation

/// New Pi history values use immutable indirection because they are nested in
/// durable reviews, operations and reducer commands. The JSON remains flat.
private final class PiHistoryStorage<Value: Sendable>: Sendable {
    let value: Value
    init(_ value: Value) { self.value = value }
}

public struct PiHistoryFileRevision: Codable, Sendable, Equatable {
    private struct Payload: Codable, Sendable, Equatable {
        let filePath: String
        let byteDigest: String
        let byteCount: Int
        let device: UInt64
        let inode: UInt64
        let headerDigest: String
        let sessionID: String
        let parentSessionPath: String?
    }
    private let storage: PiHistoryStorage<Payload>
    public var filePath: String { storage.value.filePath }
    public var byteDigest: String { storage.value.byteDigest }
    public var byteCount: Int { storage.value.byteCount }
    public var device: UInt64 { storage.value.device }
    public var inode: UInt64 { storage.value.inode }
    public var headerDigest: String { storage.value.headerDigest }
    public var sessionID: String { storage.value.sessionID }
    public var parentSessionPath: String? { storage.value.parentSessionPath }
    init(_ file: PiHistoryFileSnapshot) throws {
        storage = .init(.init(filePath: file.filePath, byteDigest: file.byteDigest, byteCount: file.byteCount,
            device: file.device, inode: file.inode, headerDigest: try PiHistoryValidation.digest(file.graph.header.raw),
            sessionID: file.graph.header.sessionID, parentSessionPath: file.graph.header.parentSessionPath))
        try validate()
    }
    public init(from decoder: any Decoder) throws { storage = .init(try Payload(from: decoder)); try validate() }
    public func encode(to encoder: any Encoder) throws { try storage.value.encode(to: encoder) }
    public static func == (lhs: Self, rhs: Self) -> Bool { lhs.storage.value == rhs.storage.value }
    public func validate() throws {
        try PiHistoryValidation.absolutePath(filePath)
        if let parentSessionPath { try PiHistoryValidation.absolutePath(parentSessionPath) }
        _ = try PiHistoryValidation.identifier(.string(sessionID))
        try PiHistoryProofValidation.digest(byteDigest); try PiHistoryProofValidation.digest(headerDigest)
        guard byteCount > 0, byteCount <= PiHistoryGraph.maximumBytes else { throw PiHistoryGraphError(.invalidWindow) }
    }
}

/// Explicit permission to materialize this exact, absent native path as empty
/// context. The native UUID/parent header need not survive a missing-file open.
/// It is never authority to treat an arbitrary missing resume path as empty.
public struct PiFreshSessionIntent: Codable, Sendable, Equatable {
    private struct Payload: Codable, Sendable, Equatable {
        let id: UUID
        let operationID: UUID
        let runtimeIdentity: PiRuntimeIdentity
        let nativeSessionFile: String
        let sourceNativeSessionFile: String
        let originalNativeSessionID: String
        let sourceInventoryDigest: String
        let semanticDigest: String
    }
    private let storage: PiHistoryStorage<Payload>
    public var id: UUID { storage.value.id }
    public var operationID: UUID { storage.value.operationID }
    public var runtimeIdentity: PiRuntimeIdentity { storage.value.runtimeIdentity }
    public var nativeSessionFile: String { storage.value.nativeSessionFile }
    public var sourceNativeSessionFile: String { storage.value.sourceNativeSessionFile }
    public var originalNativeSessionID: String { storage.value.originalNativeSessionID }
    public var sourceInventoryDigest: String { storage.value.sourceInventoryDigest }
    public var semanticDigest: String { storage.value.semanticDigest }
    public init(id: UUID, operationID: UUID, runtimeIdentity: PiRuntimeIdentity, nativeSessionFile: String,
                sourceNativeSessionFile: String, originalNativeSessionID: String, sourceInventoryDigest: String, semanticDigest: String) throws {
        storage = .init(.init(id: id, operationID: operationID, runtimeIdentity: runtimeIdentity, nativeSessionFile: nativeSessionFile,
            sourceNativeSessionFile: sourceNativeSessionFile, originalNativeSessionID: originalNativeSessionID,
            sourceInventoryDigest: sourceInventoryDigest, semanticDigest: semanticDigest))
        try validate()
    }
    public func validate() throws {
        try PiHistoryProofValidation.runtime(runtimeIdentity)
        try PiHistoryValidation.absolutePath(nativeSessionFile); try PiHistoryValidation.absolutePath(sourceNativeSessionFile)
        _ = try PiHistoryValidation.identifier(.string(originalNativeSessionID))
        try PiHistoryProofValidation.digest(sourceInventoryDigest); try PiHistoryProofValidation.digest(semanticDigest)
        guard nativeSessionFile != sourceNativeSessionFile else { throw PiHistoryGraphError(.invalidWindow) }
    }
    public init(from decoder: any Decoder) throws { storage = .init(try Payload(from: decoder)); try validate() }
    public func encode(to encoder: any Encoder) throws { try storage.value.encode(to: encoder) }
    public static func == (lhs: Self, rhs: Self) -> Bool { lhs.storage.value == rhs.storage.value }
}

public struct PiHistorySnapshot: Codable, Sendable, Equatable {
    private struct Payload: Codable, Sendable, Equatable {
        let reference: ProviderConversationReference
        let runtimeIdentity: PiRuntimeIdentity
        let observedVersion: String
        let fileRevision: PiHistoryFileRevision?
        let observation: PiRuntimeEntryObservation
        let freshIntent: PiFreshSessionIntent?
    }
    private let storage: PiHistoryStorage<Payload>
    public var reference: ProviderConversationReference { storage.value.reference }
    public var runtimeIdentity: PiRuntimeIdentity { storage.value.runtimeIdentity }
    public var observedVersion: String { storage.value.observedVersion }
    public var fileRevision: PiHistoryFileRevision? { storage.value.fileRevision }
    public var observation: PiRuntimeEntryObservation { storage.value.observation }
    public var freshIntent: PiFreshSessionIntent? { storage.value.freshIntent }
    public var workspacePath: String { runtimeIdentity.runtime?.registeredWorkspacePath ?? "" }
    public var leafID: String? { observation.leafID }
    public var entries: [PiHistoryEntryDescriptor] { observation.entries }
    public var inventoryDigest: String { observation.inventoryDigest }
    public init(reference: ProviderConversationReference, runtimeIdentity: PiRuntimeIdentity, observedVersion: String,
                fileRevision: PiHistoryFileRevision?, observation: PiRuntimeEntryObservation, freshIntent: PiFreshSessionIntent? = nil) throws {
        storage = .init(.init(reference: reference, runtimeIdentity: runtimeIdentity, observedVersion: observedVersion,
            fileRevision: fileRevision, observation: observation, freshIntent: freshIntent)); try validate()
    }
    public func validate() throws {
        try reference.validate(); try PiHistoryProofValidation.runtime(runtimeIdentity); try observation.validate()
        guard reference.provider == .pi, reference.nativeThreadID == observation.nativeSessionFile,
              PiRuntimeConfiguration.supportsObservedVersion(observedVersion) else { throw PiHistoryGraphError(.invalidWindow) }
        if let revision = fileRevision {
            try revision.validate()
            guard revision.filePath == reference.nativeThreadID, revision.sessionID == observation.nativeSessionID else { throw PiHistoryGraphError(.invalidWindow) }
        } else {
            guard let freshIntent, freshIntent.nativeSessionFile == reference.nativeThreadID,
                  freshIntent.runtimeIdentity == runtimeIdentity, entries.isEmpty, leafID == nil else { throw PiHistoryGraphError(.invalidWindow) }
        }
        try freshIntent?.validate()
        if let freshIntent { guard freshIntent.nativeSessionFile == reference.nativeThreadID, freshIntent.runtimeIdentity == runtimeIdentity else { throw PiHistoryGraphError(.invalidWindow) } }
    }
    public func matchesBinding(_ configuration: ProviderConfiguration) -> Bool {
        configuration.provider == .pi && configuration.piConfiguration?.runtimeIdentity == runtimeIdentity && configuration.workspacePath == workspacePath
    }
    public init(from decoder: any Decoder) throws { storage = .init(try Payload(from: decoder)); try validate() }
    public func encode(to encoder: any Encoder) throws { try storage.value.encode(to: encoder) }
    public static func == (lhs: Self, rhs: Self) -> Bool { lhs.storage.value == rhs.storage.value }
}

public struct PiHistoryRunInput: Codable, Sendable, Equatable {
    public let runID: UUID
    public let nativeSessionFile: String
    public let inputs: [PiHistoryInputEvidence]
    public let captureStatus: PiRunHistoryCaptureStatus
    public let baselineLeafID: String?
    public let finalLeafID: String?
    public var nativeUserEntryIDs: [String] { inputs.compactMap(\.nativeUserEntryID) }
    public init(runID: UUID, nativeSessionFile: String, inputs: [PiHistoryInputEvidence], captureStatus: PiRunHistoryCaptureStatus,
                baselineLeafID: String?, finalLeafID: String?) throws {
        self.runID = runID; self.nativeSessionFile = nativeSessionFile; self.inputs = inputs; self.captureStatus = captureStatus
        self.baselineLeafID = baselineLeafID; self.finalLeafID = finalLeafID; try validate()
    }
    public func validate() throws {
        try PiHistoryValidation.absolutePath(nativeSessionFile)
        guard !inputs.isEmpty, inputs.count <= 65, inputs.first?.kind == .opening,
              inputs.dropFirst().allSatisfy({ $0.kind != .opening }), Set(inputs.map(\.clientMessageID)).count == inputs.count,
              captureStatus == .proven || captureStatus == .noNativeChange else { throw PiHistoryGraphError(.invalidWindow) }
        for input in inputs { try input.validate() }
        for id in [baselineLeafID, finalLeafID].compactMap({ $0 }) { _ = try PiHistoryValidation.identifier(.string(id)) }
        if captureStatus == .proven {
            guard inputs.first?.nativeUserEntryID != nil, inputs.filter({ $0.kind != .compact }).allSatisfy({ $0.nativeUserEntryID != nil }),
                  Set(nativeUserEntryIDs).count == nativeUserEntryIDs.count else { throw PiHistoryGraphError(.invalidWindow) }
        } else { guard nativeUserEntryIDs.isEmpty, baselineLeafID == finalLeafID else { throw PiHistoryGraphError(.invalidWindow) } }
    }
}

public enum PiHistoryBoundary: Codable, Sendable, Equatable {
    case head
    case beforeUserEntry(String)
    case freshSession(UUID)
    public var providerBoundary: ProviderHistoryBoundary {
        switch self {
        case .head: .head
        case .beforeUserEntry(let id): .beforePiUserEntry(id)
        case .freshSession(let id): .freshPiSession(id)
        }
    }
    public func validate() throws {
        if case .beforeUserEntry(let id) = self { _ = try PiHistoryValidation.identifier(.string(id)) }
    }
}

public struct PiHistoryReviewEvidence: Codable, Sendable, Equatable {
    private struct Payload: Codable, Sendable, Equatable {
        let operationID: UUID
        let source: PiHistorySnapshot
        let kind: ConversationHistoryKind
        let runID: UUID
        let inputs: [PiHistoryRunInput]
        let boundary: PiHistoryBoundary
        let cutUserEntryID: String?
        let retainedLeafID: String?
        let retainedEntries: [PiHistoryEntryDescriptor]
        let semanticDigest: String
    }
    private let storage: PiHistoryStorage<Payload>
    public var operationID: UUID { storage.value.operationID }
    public var source: PiHistorySnapshot { storage.value.source }
    public var kind: ConversationHistoryKind { storage.value.kind }
    public var runID: UUID { storage.value.runID }
    public var inputs: [PiHistoryRunInput] { storage.value.inputs }
    public var boundary: PiHistoryBoundary { storage.value.boundary }
    public var cutUserEntryID: String? { storage.value.cutUserEntryID }
    public var retainedLeafID: String? { storage.value.retainedLeafID }
    public var retainedEntries: [PiHistoryEntryDescriptor] { storage.value.retainedEntries }
    public var semanticDigest: String { storage.value.semanticDigest }
    public init(operationID: UUID, source: PiHistorySnapshot, kind: ConversationHistoryKind, runID: UUID,
                inputs: [PiHistoryRunInput], boundary: PiHistoryBoundary, cutUserEntryID: String?, retainedLeafID: String?,
                retainedEntries: [PiHistoryEntryDescriptor], semanticDigest: String) throws {
        storage = .init(.init(operationID: operationID, source: source, kind: kind, runID: runID, inputs: inputs, boundary: boundary,
            cutUserEntryID: cutUserEntryID, retainedLeafID: retainedLeafID, retainedEntries: retainedEntries, semanticDigest: semanticDigest)); try validate()
    }
    public func validate() throws {
        try source.validate(); try boundary.validate(); try PiHistoryProofValidation.digest(semanticDigest)
        guard !inputs.isEmpty, inputs.count <= 10_000, Set(inputs.map(\.runID)).count == inputs.count,
              inputs.contains(where: { $0.runID == runID }), retainedEntries.count <= PiHistoryGraph.maximumEntries,
              Set(retainedEntries.map(\.id)).count == retainedEntries.count else { throw PiHistoryGraphError(.invalidWindow) }
        for input in inputs { try input.validate() }
        for entry in retainedEntries { try entry.validate() }
        let index = Dictionary(uniqueKeysWithValues: source.entries.map { ($0.id, $0) })
        var reverse: [PiHistoryEntryDescriptor] = [], cursor = source.leafID
        while let id = cursor {
            guard let entry = index[id], reverse.count <= source.entries.count else { throw PiHistoryGraphError(.invalidWindow) }
            reverse.append(entry); cursor = entry.parentID
        }
        let branch = Array(reverse.reversed())
        let positions = Dictionary(uniqueKeysWithValues: branch.enumerated().map { ($0.element.id, $0.offset) })
        var last = -1, owned = Set<String>()
        for input in inputs {
            for id in input.nativeUserEntryIDs {
                guard let position = positions[id], position > last, branch[position].isUser, owned.insert(id).inserted else { throw PiHistoryGraphError(.invalidWindow) }
                last = position
            }
        }
        if let firstID = inputs.flatMap(\.nativeUserEntryIDs).first, let first = positions[firstID] {
            guard branch.dropFirst(first).filter(\.isUser).allSatisfy({ owned.contains($0.id) }) else { throw PiHistoryGraphError(.invalidWindow) }
        }
        guard let selected = inputs.firstIndex(where: { $0.runID == runID }) else { throw PiHistoryGraphError(.invalidWindow) }
        let firstDiscarded = kind == .forkAfterRun ? selected + 1 : selected
        let expectedCut = inputs.dropFirst(firstDiscarded).compactMap { $0.nativeUserEntryIDs.first }.first
        guard cutUserEntryID == expectedCut else { throw PiHistoryGraphError(.invalidWindow) }
        let expectedLeaf = expectedCut.flatMap { index[$0]?.parentID } ?? (expectedCut == nil ? source.leafID : nil)
        guard retainedLeafID == expectedLeaf else { throw PiHistoryGraphError(.invalidWindow) }
        if let expectedCut, let cut = positions[expectedCut] {
            let expected = branch[..<cut].filter { $0.kind != PiHistoryEntry.Kind.label.rawValue }
            guard retainedEntries.map(\.id) == expected.map(\.id),
                  zip(retainedEntries, expected).allSatisfy({ pair in pair.0.kind == pair.1.kind && pair.0.isUser == pair.1.isUser }) else { throw PiHistoryGraphError(.invalidWindow) }
            var parent: String?
            for entry in retainedEntries { guard entry.parentID == parent else { throw PiHistoryGraphError(.invalidWindow) }; parent = entry.id }
        } else { guard retainedEntries == source.entries else { throw PiHistoryGraphError(.invalidWindow) } }
        if let cutUserEntryID { guard source.entries.contains(where: { $0.id == cutUserEntryID && $0.isUser }) else { throw PiHistoryGraphError(.invalidWindow) } }
        if let retainedLeafID { guard source.entries.contains(where: { $0.id == retainedLeafID }) else { throw PiHistoryGraphError(.invalidWindow) } }
        switch boundary {
        case .head: guard cutUserEntryID == nil, retainedLeafID == source.leafID else { throw PiHistoryGraphError(.invalidWindow) }
        case .beforeUserEntry(let id): guard id == cutUserEntryID, retainedLeafID != nil else { throw PiHistoryGraphError(.invalidWindow) }
        case .freshSession: guard cutUserEntryID != nil, retainedLeafID == nil, retainedEntries.isEmpty else { throw PiHistoryGraphError(.invalidWindow) }
        }
    }
    public func sameLogicalBoundary(as other: Self) -> Bool {
        source == other.source && kind == other.kind && runID == other.runID && inputs == other.inputs &&
        cutUserEntryID == other.cutUserEntryID && retainedLeafID == other.retainedLeafID && retainedEntries == other.retainedEntries && semanticDigest == other.semanticDigest
    }

    /// Durable admission validates only retained ledger facts. Native bytes and
    /// label payloads are checked by make/apply, never by journal reduction.
    public func validateLedger(snapshot: WorkspaceSnapshot, thread: CodingThread) throws {
        try validate()
        guard source.matchesBinding(.init(thread: thread)), source.reference.nativeThreadID == thread.providerThreadID,
              source.observedVersion == "0.80.5" else { throw PiHistoryGraphError(.invalidWindow) }
        let visible = (thread.runHistory ?? []).filter { $0.removedByHistoryOperationID == nil }
        guard visible.count <= 10_000, Set(visible.map(\.id)).count == visible.count,
              Set(thread.messages.map(\.id)).count == thread.messages.count else { throw PiHistoryGraphError(.invalidWindow) }
        let rows = Dictionary(uniqueKeysWithValues: thread.messages.map { ($0.id, $0) })
        let steerings = snapshot.promptSteerings ?? []
        var expected: [PiHistoryRunInput] = [], coveredEntries = 0
        for run in visible {
            guard let proof = run.pi else {
                if run.id == runID { throw PiHistoryGraphError(.invalidWindow) }
                continue
            }
            try proof.validate()
            guard run.origin == .user, run.status.isTerminal, run.status != .unknown,
                  proof.terminalStatus == run.status, proof.runID == run.id,
                  proof.captureStatus == .proven || proof.captureStatus == .noNativeChange,
                  run.configuration.provider == .pi,
                  run.configuration.piConfiguration?.runtimeIdentity == proof.runtimeIdentity,
                  run.providerThreadID == proof.nativeSessionFile,
                  proof.inputs.first?.clientMessageID == run.userMessageID else { throw PiHistoryGraphError(.invalidWindow) }
            let owner = try PiHistoryRunInput(runID: run.id, nativeSessionFile: proof.nativeSessionFile, inputs: proof.inputs,
                captureStatus: proof.captureStatus, baselineLeafID: proof.preparation.baseline.leafID, finalLeafID: proof.finalObservation?.leafID)
            coveredEntries = max(coveredEntries, try PiHistoryProofValidation.lineage(owner: owner, proof: proof,
                current: source, snapshot: snapshot, threadID: thread.id))
            for input in proof.inputs {
                guard let row = rows[input.clientMessageID], row.role == .user,
                      row.removedByHistoryOperationID == nil,
                      row.runReference == .init(threadID: thread.id, runID: run.id) else { throw PiHistoryGraphError(.invalidWindow) }
                if input.kind == .opening {
                    guard row.id == run.userMessageID, row.promptSteeringID == nil else { throw PiHistoryGraphError(.invalidWindow) }
                } else {
                    guard let operationID = row.promptSteeringID,
                          let operation = steerings.first(where: { $0.id == operationID }),
                          operation.threadID == thread.id, operation.runID == run.id, operation.messageID == row.id,
                          operation.input.text == row.text, operation.input.attachments == row.attachments,
                          operation.configuration.piConfiguration?.runtimeIdentity == proof.runtimeIdentity,
                          operation.nativeThreadID == proof.nativeSessionFile else { throw PiHistoryGraphError(.invalidWindow) }
                    let text = row.text.trimmingCharacters(in: .whitespacesAndNewlines)
                    let suffix = text.hasPrefix("/compact") ? String(text.dropFirst(8)) : nil
                    let compact = suffix.map { $0.isEmpty || $0.first?.isWhitespace == true } ?? false
                    guard (input.kind == .compact) == compact else { throw PiHistoryGraphError(.invalidWindow) }
                }
                // Attachment bytes are deliberately not reread in reduction.
                // Their admitted digest is bound by the immutable run proof.
                if row.attachments?.isEmpty != false {
                    guard try PiHistoryInputEvidence.digest(.init(text: row.text)) == input.inputDigest else { throw PiHistoryGraphError(.invalidWindow) }
                }
            }
            expected.append(owner)
        }
        guard expected == inputs,
              source.entries.dropFirst(coveredEntries).allSatisfy({
                  [PiHistoryEntry.Kind.modelChange.rawValue, PiHistoryEntry.Kind.thinkingLevelChange.rawValue,
                   PiHistoryEntry.Kind.label.rawValue, PiHistoryEntry.Kind.sessionInfo.rawValue].contains($0.kind)
              }) else { throw PiHistoryGraphError(.invalidWindow) }
    }
    public func validateCandidate(_ candidate: PiHistoryCandidate, previous: [PiHistoryCandidate]) throws {
        try validate(); try candidate.validate()
        guard candidate.operationID == operationID, candidate.sourceInventoryDigest == source.inventoryDigest,
              candidate.semanticDigest == semanticDigest,
              try PiHistoryProofValidation.sameNamespace(source.runtimeIdentity, candidate.runtimeIdentity),
              previous.count < 3, !previous.contains(candidate) else { throw PiHistoryGraphError(.invalidWindow) }
        for (index, prior) in previous.enumerated() { try validateCandidate(prior, previous: Array(previous.prefix(index))) }
        switch candidate.stage {
        case .reserved:
            guard kind == .forkAfterRun, previous.isEmpty, candidate.expectedParentSessionPath == source.reference.nativeThreadID else { throw PiHistoryGraphError(.invalidWindow) }
        case .initialClone:
            guard kind == .forkAfterRun, previous.count == 1, previous[0].stage == .reserved,
                  candidate.runtimeIdentity == previous[0].runtimeIdentity, candidate.operationDirectory == previous[0].operationDirectory,
                  candidate.expectedParentSessionPath == source.reference.nativeThreadID else { throw PiHistoryGraphError(.invalidWindow) }
        case .finalBranch:
            if kind == .forkAfterRun {
                guard previous.count == 2, previous[0].stage == .reserved, previous[1].stage == .initialClone,
                      candidate.runtimeIdentity == previous[1].runtimeIdentity, candidate.operationDirectory == previous[1].operationDirectory,
                      candidate.expectedParentSessionPath == previous[1].nativeSessionFile else { throw PiHistoryGraphError(.invalidWindow) }
            } else {
                guard previous.isEmpty, candidate.runtimeIdentity == source.runtimeIdentity,
                      candidate.expectedParentSessionPath == source.reference.nativeThreadID, candidate.operationDirectory == nil else { throw PiHistoryGraphError(.invalidWindow) }
            }
            guard cutUserEntryID != nil else { throw PiHistoryGraphError(.invalidWindow) }
        }
        if let path = candidate.nativeSessionFile {
            guard path != source.reference.nativeThreadID, !previous.contains(where: { $0.nativeSessionFile == path }) else { throw PiHistoryGraphError(.invalidWindow) }
        }
        if let id = candidate.nativeSessionID {
            guard id != source.observation.nativeSessionID,
                  !previous.contains(where: { $0.nativeSessionID == id }) else { throw PiHistoryGraphError(.invalidWindow) }
        }
    }
    public func validateResult(_ result: PiHistoryResult) throws {
        try validate(); try result.validate()
        guard result.operationID == operationID, result.source == source, result.semanticDigest == semanticDigest,
              let selected = inputs.firstIndex(where: { $0.runID == runID }) else { throw PiHistoryGraphError(.invalidWindow) }
        let count = kind == .forkAfterRun ? selected + 1 : selected
        guard result.inputs == Array(inputs.prefix(count)) else { throw PiHistoryGraphError(.invalidWindow) }
        if result.snapshot == source {
            guard kind == .rewindBeforeRun, boundary == .head, result.candidates.isEmpty,
                  inputs.dropFirst(selected).allSatisfy({ $0.captureStatus == .noNativeChange }) else { throw PiHistoryGraphError(.invalidWindow) }
            return
        }
        for (index, candidate) in result.candidates.enumerated() { try validateCandidate(candidate, previous: Array(result.candidates.prefix(index))) }
        guard let final = result.candidates.last,
              final.stage == (cutUserEntryID == nil ? .initialClone : .finalBranch),
              result.snapshot.runtimeIdentity == final.runtimeIdentity,
              (kind == .forkAfterRun || result.snapshot.runtimeIdentity == source.runtimeIdentity),
              result.snapshot.observation.nativeSessionID == final.nativeSessionID else { throw PiHistoryGraphError(.invalidWindow) }
        if boundary == .head {
            guard result.snapshot.entries == retainedEntries else { throw PiHistoryGraphError(.invalidWindow) }
        } else {
            guard Array(result.snapshot.entries.prefix(retainedEntries.count)) == retainedEntries,
                  result.snapshot.entries.dropFirst(retainedEntries.count).allSatisfy({ $0.kind == PiHistoryEntry.Kind.label.rawValue }) else { throw PiHistoryGraphError(.invalidWindow) }
        }
        if case .freshSession(let id) = boundary {
            guard result.freshIntent?.id == id, result.freshIntent?.operationID == operationID,
                  result.freshIntent?.sourceNativeSessionFile == source.reference.nativeThreadID,
                  result.freshIntent?.sourceInventoryDigest == source.inventoryDigest,
                  result.freshIntent?.semanticDigest == semanticDigest else { throw PiHistoryGraphError(.invalidWindow) }
        } else { guard result.freshIntent == nil else { throw PiHistoryGraphError(.invalidWindow) } }
    }

    /// Called during explicit review, outside journal reduction. The anchored
    /// native bytes are needed for the exact label transform, never archived.
    public static func make(source: PiHistorySnapshot, snapshot: WorkspaceSnapshot, thread: CodingThread,
                            runID: UUID, kind: ConversationHistoryKind, operationID: UUID) throws -> Self {
        try source.validate()
        guard source.matchesBinding(.init(thread: thread)), source.reference.nativeThreadID == thread.providerThreadID,
              source.observedVersion == "0.80.5" else { throw PiHistoryGraphError(.unavailable) }
        let graph = try PiHistoryService.sourceGraph(expected: source)
        let visible = (thread.runHistory ?? []).filter { $0.removedByHistoryOperationID == nil }
        guard visible.contains(where: { $0.id == runID }), visible.count <= 10_000 else { throw PiHistoryGraphError(.invalidWindow) }
        var inputs: [PiHistoryRunInput] = [], mapped = Set<String>(), previousPosition = -1, coveredEntries = 0
        let branch = graph.activeBranch
        let positions = Dictionary(uniqueKeysWithValues: branch.enumerated().map { ($0.element.id, $0.offset) })
        for run in visible {
            guard let proof = run.pi else {
                if run.id == runID { throw PiHistoryGraphError(.unavailable) }
                continue
            }
            try proof.validate()
            guard run.origin == .user, run.status.isTerminal, run.status != .unknown,
                  proof.captureStatus == .proven || proof.captureStatus == .noNativeChange,
                  run.configuration.piConfiguration?.runtimeIdentity == proof.runtimeIdentity,
                  run.providerThreadID == proof.nativeSessionFile else { throw PiHistoryGraphError(.invalidWindow) }
            let owner = try PiHistoryRunInput(runID: run.id, nativeSessionFile: proof.nativeSessionFile, inputs: proof.inputs,
                captureStatus: proof.captureStatus, baselineLeafID: proof.preparation.baseline.leafID, finalLeafID: proof.finalObservation?.leafID)
            coveredEntries = max(coveredEntries, try PiHistoryProofValidation.lineage(owner: owner, proof: proof, current: source, snapshot: snapshot, threadID: thread.id))
            for input in owner.inputs {
                guard let id = input.nativeUserEntryID else { continue }
                guard let position = positions[id], position > previousPosition, mapped.insert(id).inserted,
                      branch[position].isUserMessage, try PiProtocol.inputDigest(branch[position]) == input.inputDigest else { throw PiHistoryGraphError(.invalidWindow) }
                previousPosition = position
            }
            inputs.append(owner)
        }
        guard let selected = inputs.firstIndex(where: { $0.runID == runID }) else { throw PiHistoryGraphError(.unavailable) }
        guard graph.entries.dropFirst(coveredEntries).allSatisfy({ [.modelChange, .thinkingLevelChange, .label, .sessionInfo].contains($0.kind) }) else {
            throw PiHistoryGraphError(.invalidWindow)
        }
        if let opening = inputs.flatMap(\.nativeUserEntryIDs).first, let first = positions[opening] {
            guard branch.dropFirst(first).filter(\.isUserMessage).allSatisfy({ mapped.contains($0.id) }) else { throw PiHistoryGraphError(.invalidWindow) }
        }
        let nextIndex = kind == .forkAfterRun ? selected + 1 : selected
        let cut = inputs.dropFirst(nextIndex).compactMap { $0.nativeUserEntryIDs.first }.first
        let retainedLeaf = cut.flatMap { graph.entry(id: $0)?.parentID } ?? (cut == nil ? graph.leafID : nil)
        let boundary: PiHistoryBoundary = cut.map { retainedLeaf == nil ? .freshSession(UUID()) : .beforeUserEntry($0) } ?? .head
        let mode: PiHistoryForkTransform.Mode = cut == nil ? .cliFork : (retainedLeaf == nil ? .fresh : .branched)
        if kind == .rewindBeforeRun, cut == nil {
            return try .init(operationID: operationID, source: source, kind: kind, runID: runID, inputs: inputs, boundary: .head,
                cutUserEntryID: nil, retainedLeafID: source.leafID, retainedEntries: source.entries,
                semanticDigest: PiHistoryValidation.digest(.object(["mode": .string("unchanged"), "inventory": .string(source.inventoryDigest), "leaf": source.leafID.map(JSONValue.string) ?? .null])))
        }
        let transform = try PiHistoryForkTransform(source: graph, mode: mode, retainedLeafID: retainedLeaf)
        return try .init(operationID: operationID, source: source, kind: kind, runID: runID, inputs: inputs, boundary: boundary,
            cutUserEntryID: cut, retainedLeafID: retainedLeaf, retainedEntries: transform.retainedEntries, semanticDigest: transform.semanticDigest)
    }
    public init(from decoder: any Decoder) throws { storage = .init(try Payload(from: decoder)); try validate() }
    public func encode(to encoder: any Encoder) throws { try storage.value.encode(to: encoder) }
    public static func == (lhs: Self, rhs: Self) -> Bool { lhs.storage.value == rhs.storage.value }
}

public struct PiHistoryCandidate: Codable, Sendable, Equatable {
    public enum Stage: String, Codable, Sendable { case reserved, initialClone, finalBranch }
    private struct Payload: Codable, Sendable, Equatable {
        let operationID: UUID
        let stage: Stage
        let runtimeIdentity: PiRuntimeIdentity
        let operationDirectory: String?
        let nativeSessionFile: String?
        let nativeSessionID: String?
        let expectedParentSessionPath: String
        let sourceInventoryDigest: String
        let semanticDigest: String
    }
    private let storage: PiHistoryStorage<Payload>
    public var operationID: UUID { storage.value.operationID }
    public var stage: Stage { storage.value.stage }
    public var runtimeIdentity: PiRuntimeIdentity { storage.value.runtimeIdentity }
    public var workspacePath: String { runtimeIdentity.runtime?.registeredWorkspacePath ?? "" }
    public var operationDirectory: String? { storage.value.operationDirectory }
    public var nativeSessionFile: String? { storage.value.nativeSessionFile }
    public var nativeSessionID: String? { storage.value.nativeSessionID }
    public var expectedParentSessionPath: String { storage.value.expectedParentSessionPath }
    public var sourceInventoryDigest: String { storage.value.sourceInventoryDigest }
    public var semanticDigest: String { storage.value.semanticDigest }
    public init(operationID: UUID, stage: Stage, runtimeIdentity: PiRuntimeIdentity, operationDirectory: String? = nil,
                nativeSessionFile: String? = nil, nativeSessionID: String? = nil, expectedParentSessionPath: String,
                sourceInventoryDigest: String, semanticDigest: String) throws {
        storage = .init(.init(operationID: operationID, stage: stage, runtimeIdentity: runtimeIdentity, operationDirectory: operationDirectory,
            nativeSessionFile: nativeSessionFile, nativeSessionID: nativeSessionID, expectedParentSessionPath: expectedParentSessionPath,
            sourceInventoryDigest: sourceInventoryDigest, semanticDigest: semanticDigest)); try validate()
    }
    public func validate() throws {
        try PiHistoryProofValidation.runtime(runtimeIdentity); try PiHistoryValidation.absolutePath(expectedParentSessionPath)
        try PiHistoryProofValidation.digest(sourceInventoryDigest); try PiHistoryProofValidation.digest(semanticDigest)
        if let operationDirectory { try PiHistoryValidation.absolutePath(operationDirectory) }
        if stage == .reserved {
            guard operationDirectory != nil, nativeSessionFile == nil, nativeSessionID == nil else { throw PiHistoryGraphError(.invalidWindow) }
        } else {
            guard let nativeSessionFile, let nativeSessionID, nativeSessionFile != expectedParentSessionPath else { throw PiHistoryGraphError(.invalidWindow) }
            try PiHistoryValidation.absolutePath(nativeSessionFile); _ = try PiHistoryValidation.identifier(.string(nativeSessionID))
            if let operationDirectory { guard (nativeSessionFile as NSString).deletingLastPathComponent == operationDirectory else { throw PiHistoryGraphError(.invalidWindow) } }
        }
    }
    public init(from decoder: any Decoder) throws { storage = .init(try Payload(from: decoder)); try validate() }
    public func encode(to encoder: any Encoder) throws { try storage.value.encode(to: encoder) }
    public static func == (lhs: Self, rhs: Self) -> Bool { lhs.storage.value == rhs.storage.value }
}

public struct PiHistoryResult: Codable, Sendable, Equatable {
    private struct Payload: Codable, Sendable, Equatable {
        let operationID: UUID
        let source: PiHistorySnapshot
        let snapshot: PiHistorySnapshot
        let inputs: [PiHistoryRunInput]
        let candidates: [PiHistoryCandidate]
        let semanticDigest: String
    }
    private let storage: PiHistoryStorage<Payload>
    public var operationID: UUID { storage.value.operationID }
    public var source: PiHistorySnapshot { storage.value.source }
    public var snapshot: PiHistorySnapshot { storage.value.snapshot }
    public var inputs: [PiHistoryRunInput] { storage.value.inputs }
    public var candidates: [PiHistoryCandidate] { storage.value.candidates }
    public var semanticDigest: String { storage.value.semanticDigest }
    public var freshIntent: PiFreshSessionIntent? { snapshot.freshIntent }
    public var reference: ProviderConversationReference { snapshot.reference }
    public var workspacePath: String { snapshot.workspacePath }
    public init(operationID: UUID, source: PiHistorySnapshot, snapshot: PiHistorySnapshot, inputs: [PiHistoryRunInput],
                candidates: [PiHistoryCandidate], semanticDigest: String) throws {
        storage = .init(.init(operationID: operationID, source: source, snapshot: snapshot, inputs: inputs, candidates: candidates, semanticDigest: semanticDigest)); try validate()
    }
    public func validate() throws {
        try source.validate(); try snapshot.validate(); try PiHistoryProofValidation.digest(semanticDigest)
        guard candidates.count <= 3,
              inputs.count <= 10_000, Set(inputs.map(\.runID)).count == inputs.count else { throw PiHistoryGraphError(.invalidWindow) }
        if source == snapshot {
            guard candidates.isEmpty else { throw PiHistoryGraphError(.invalidWindow) }
            for input in inputs { try input.validate() }
            return
        }
        guard source.reference.nativeThreadID != snapshot.reference.nativeThreadID,
              let final = candidates.last, final.stage != .reserved, final.operationID == operationID,
              final.nativeSessionFile == snapshot.reference.nativeThreadID, final.runtimeIdentity == snapshot.runtimeIdentity,
              final.sourceInventoryDigest == source.inventoryDigest, final.semanticDigest == semanticDigest else { throw PiHistoryGraphError(.invalidWindow) }
        for candidate in candidates { try candidate.validate(); guard candidate.operationID == operationID else { throw PiHistoryGraphError(.invalidWindow) } }
        for input in inputs { try input.validate() }
    }
    public init(from decoder: any Decoder) throws { storage = .init(try Payload(from: decoder)); try validate() }
    public func encode(to encoder: any Encoder) throws { try storage.value.encode(to: encoder) }
    public static func == (lhs: Self, rhs: Self) -> Bool { lhs.storage.value == rhs.storage.value }
}

/// sessionID is the Engine-owned history worker identity, never Pi's native ID.
public struct PiHistoryControlState: Codable, Sendable, Equatable {
    public let sessionID: UUID
    public var requests: [RuntimeRequest]
    public init(sessionID: UUID, requests: [RuntimeRequest] = []) { self.sessionID = sessionID; self.requests = requests }
    public func validate() throws {
        guard requests.count <= 256, Set(requests.map(\.id)).count == requests.count,
              requests.allSatisfy({ $0.sessionScoped == true && $0.request.method == "pi/extension" }) else { throw PiHistoryGraphError(.invalidWindow) }
        for request in requests { _ = try PiExtensionRequest.presentation(request.request) }
    }
}

enum PiHistoryProofValidation {
    static func digest(_ value: String) throws {
        guard value.utf8.count == 64, value.utf8.allSatisfy({ (48...57).contains($0) || (97...102).contains($0) }) else { throw PiHistoryGraphError(.invalidWindow) }
    }
    static func runtime(_ value: PiRuntimeIdentity) throws {
        guard let runtime = value.runtime, runtime.instanceID == value.instanceID, runtime.requestedExecutable == value.executable else { throw PiHistoryGraphError(.invalidWindow) }
        try runtime.validate()
    }
    static func sameNamespace(_ lhs: PiRuntimeIdentity, _ rhs: PiRuntimeIdentity) throws -> Bool {
        try runtime(lhs); try runtime(rhs)
        guard lhs.instanceID == rhs.instanceID, lhs.executable == rhs.executable, let a = lhs.runtime, let b = rhs.runtime else { return false }
        return try a.replacingWorkspace(b.registeredWorkspacePath, physicalPath: b.workspacePath) == b
    }
    static func lineage(owner: PiHistoryRunInput, proof: PiRunHistoryEvidence, current: PiHistorySnapshot,
                        snapshot: WorkspaceSnapshot, threadID: UUID) throws -> Int {
        var cursor = current, visited = Set<String>(), covered: Int?
        while cursor.reference.nativeThreadID != proof.nativeSessionFile {
            guard visited.insert(cursor.reference.nativeThreadID).inserted, visited.count <= 256 else { throw PiHistoryGraphError(.invalidWindow) }
            let edges = (snapshot.conversationHistoryOperations ?? []).filter { operation in
                guard operation.phase == .applied, operation.review.sourceThreadID == threadID || operation.review.targetThreadID == threadID,
                      let review = operation.review.pi, let result = operation.result?.pi,
                      result.snapshot.reference == cursor.reference, result.snapshot.runtimeIdentity == cursor.runtimeIdentity,
                      result.inputs.contains(owner), cursor.entries.count >= result.snapshot.entries.count,
                      Array(cursor.entries.prefix(result.snapshot.entries.count)) == result.snapshot.entries else { return false }
                return (try? review.validateResult(result)) != nil
            }
            guard edges.count == 1, let previous = edges[0].review.pi?.source else { throw PiHistoryGraphError(.invalidWindow) }
            if covered == nil { covered = edges[0].result?.pi?.snapshot.entries.count }
            cursor = previous
        }
        guard cursor.runtimeIdentity == proof.runtimeIdentity, let observed = proof.finalObservation,
              cursor.entries.count >= observed.entries.count,
              Array(cursor.entries.prefix(observed.entries.count)) == observed.entries else { throw PiHistoryGraphError(.invalidWindow) }
        return covered ?? observed.entries.count
    }
}
