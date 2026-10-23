import CryptoKit
import Foundation

public struct PiHistoryInputEvidence: Codable, Sendable, Equatable {
    public enum Kind: String, Codable, Sendable { case opening, steering, compact }
    public let clientMessageID: String
    public let inputDigest: String
    public let kind: Kind
    public var nativeUserEntryID: String?
    public let bridgeReservation: PiInputBridgeReservation?
    public var bridgeEvidence: PiInputBridgeEvidence?
    public var nativeInputDigest: String { bridgeEvidence?.expandedDigest ?? inputDigest }
    public init(clientMessageID: String, inputDigest: String, kind: Kind, nativeUserEntryID: String? = nil,
                bridgeReservation: PiInputBridgeReservation? = nil, bridgeEvidence: PiInputBridgeEvidence? = nil) throws {
        self.clientMessageID = clientMessageID; self.inputDigest = inputDigest; self.kind = kind; self.nativeUserEntryID = nativeUserEntryID
        self.bridgeReservation = bridgeReservation; self.bridgeEvidence = bridgeEvidence
        try validate()
    }
    public func validate() throws {
        try ProviderSteeringValidation.id(clientMessageID); try PiRunHistoryValidation.digest(inputDigest)
        if let nativeUserEntryID { _ = try PiHistoryValidation.identifier(.string(nativeUserEntryID)) }
        guard kind != .compact || nativeUserEntryID == nil else { throw PiHistoryGraphError(.invalidWindow) }
        if let reservation = bridgeReservation {
            try reservation.validate()
            guard kind != .compact, reservation.clientMessageID == clientMessageID, reservation.originalDigest == inputDigest else {
                throw PiHistoryGraphError(.invalidWindow)
            }
            if let proof = bridgeEvidence {
                try proof.validate()
                guard proof.marker.reservation == reservation, nativeUserEntryID == proof.nativeUserEntryID else {
                    throw PiHistoryGraphError(.invalidWindow)
                }
            } else { guard nativeUserEntryID == nil else { throw PiHistoryGraphError(.invalidWindow) } }
        } else { guard bridgeEvidence == nil else { throw PiHistoryGraphError(.invalidWindow) } }
    }
    public func matchesAuthored(_ expected: Self) -> Bool {
        clientMessageID == expected.clientMessageID && inputDigest == expected.inputDigest && kind == expected.kind
    }
    public static func digest(_ input: ProviderInput) throws -> String {
        try ProviderSteeringValidation.input(input)
        return try PiHistoryValidation.digest(.object(["text": .string(input.text), "images": .array(input.images.map {
            .object(["mimeType": .string($0.mimeType), "byteCount": .number(Double($0.data.count)), "digest": .string(PiHistoryValidation.sha($0.data))])
        })]))
    }
    public static func steering(clientMessageID: String, input: ProviderInput) throws -> Self {
        let text = input.text.trimmingCharacters(in: .whitespacesAndNewlines)
        let suffix = text.hasPrefix("/compact") ? String(text.dropFirst(8)) : nil
        let compact = suffix.map { $0.isEmpty || $0.first?.isWhitespace == true } ?? false
        return try .init(clientMessageID: clientMessageID, inputDigest: digest(input), kind: compact ? .compact : .steering)
    }
}

public struct PiHistoryEntryDescriptor: Codable, Sendable, Equatable {
    public let id: String
    public let parentID: String?
    public let kind: String
    public let contentDigest: String
    public let isUser: Bool
    init(_ entry: PiHistoryEntry) {
        id = entry.id; parentID = entry.parentID; kind = entry.kind.rawValue; contentDigest = entry.digest; isUser = entry.isUserMessage
    }
    func validate() throws {
        _ = try PiHistoryValidation.identifier(.string(id))
        if let parentID { _ = try PiHistoryValidation.identifier(.string(parentID)) }
        guard let parsed = PiHistoryEntry.Kind(rawValue: kind), !isUser || parsed == .message else { throw PiHistoryGraphError(.invalidEntry) }
        try PiRunHistoryValidation.digest(contentDigest)
    }
}

/// Live RPC descriptors, not a fabricated file header or a prompt archive.
public struct PiRuntimeEntryObservation: Codable, Sendable, Equatable {
    public let nativeSessionFile: String
    public let nativeSessionID: String
    public let leafID: String?
    public let entries: [PiHistoryEntryDescriptor]
    public let inventoryDigest: String
    public init(nativeSessionFile: String, nativeSessionID: String, leafID: String?, entries: [PiHistoryEntryDescriptor]) throws {
        self.nativeSessionFile = nativeSessionFile; self.nativeSessionID = nativeSessionID; self.leafID = leafID; self.entries = entries
        inventoryDigest = try PiRunHistoryValidation.inventoryDigest(entries)
        try validate()
    }
    public func validate() throws {
        try PiRuntimeConfiguration.path(nativeSessionFile)
        _ = try PiHistoryValidation.identifier(.string(nativeSessionID))
        guard entries.count <= PiHistoryGraph.maximumEntries else { throw PiHistoryGraphError(.oversized) }
        var index: [String: Int] = [:]
        for (position, entry) in entries.enumerated() {
            try entry.validate()
            guard index[entry.id] == nil else { throw PiHistoryGraphError(.invalidGraph) }
            if let parent = entry.parentID { guard index[parent] != nil else { throw PiHistoryGraphError(.invalidGraph) } }
            index[entry.id] = position
        }
        if let leafID { guard index[leafID] != nil else { throw PiHistoryGraphError(.invalidGraph) } }
        guard try PiRunHistoryValidation.inventoryDigest(entries) == inventoryDigest else { throw PiHistoryGraphError(.invalidGraph) }
    }
    func appendedWindow(since before: Self) throws -> [PiHistoryEntryDescriptor] {
        try validate(); try before.validate()
        guard nativeSessionFile == before.nativeSessionFile, nativeSessionID == before.nativeSessionID,
              entries.count >= before.entries.count, Array(entries.prefix(before.entries.count)) == before.entries else { throw PiHistoryGraphError(.invalidWindow) }
        let index = Dictionary(uniqueKeysWithValues: entries.enumerated().map { ($0.element.id, $0.offset) })
        var cursor = leafID, reverse: [PiHistoryEntryDescriptor] = []
        while cursor != before.leafID {
            guard let id = cursor, let position = index[id], position >= before.entries.count else { throw PiHistoryGraphError(.invalidWindow) }
            let entry = entries[position]; reverse.append(entry); cursor = entry.parentID
        }
        return Array(reverse.reversed())
    }
}

/// Raw payloads live only in the actor while it validates an exact native read.
struct PiRuntimeEntries: Sendable {
    let observation: PiRuntimeEntryObservation
    let entries: [PiHistoryEntry]
    init(_ value: JSONValue, state: PiState) throws {
        guard let raw = value["entries"].array, raw.count <= PiHistoryGraph.maximumEntries,
              value.object?["leafId"] != nil else { throw PiHistoryGraphError(.invalidGraph) }
        let leaf = value["leafId"] == .null ? nil : try PiHistoryValidation.identifier(value["leafId"])
        var parsed: [PiHistoryEntry] = [], bytes = 0
        for item in raw {
            bytes += try PiHistoryValidation.bytes(item).count
            guard bytes <= PiHistoryGraph.maximumBytes else { throw PiHistoryGraphError(.oversized) }
            parsed.append(try PiHistoryEntry(raw: item))
        }
        entries = parsed
        observation = try .init(nativeSessionFile: state.sessionFile, nativeSessionID: state.sessionID, leafID: leaf, entries: parsed.map(PiHistoryEntryDescriptor.init))
    }
}

public struct PiRunHistoryPreparation: Codable, Sendable, Equatable {
    public let id: UUID
    public let runID: UUID
    public let runtimeIdentity: PiRuntimeIdentity
    public let observedVersion: String
    public let inputDigest: String
    public let openingInput: PiHistoryInputEvidence
    public let nativeSessionFile: String
    public let nativeSessionID: String
    public let baseline: PiRuntimeEntryObservation
    public let freshIntentID: UUID?
    public let freshEmptyObservation: PiRuntimeEntryObservation?
    public init(id: UUID = UUID(), runID: UUID, runtimeIdentity: PiRuntimeIdentity, observedVersion: String,
                openingInput: PiHistoryInputEvidence, baseline: PiRuntimeEntryObservation, freshIntentID: UUID? = nil,
                freshEmptyObservation: PiRuntimeEntryObservation? = nil) throws {
        self.id = id; self.runID = runID; self.runtimeIdentity = runtimeIdentity; self.observedVersion = observedVersion
        self.openingInput = openingInput; inputDigest = openingInput.inputDigest; self.baseline = baseline
        nativeSessionFile = baseline.nativeSessionFile; nativeSessionID = baseline.nativeSessionID
        self.freshIntentID = freshIntentID
        self.freshEmptyObservation = freshEmptyObservation
        try validate()
    }
    public func validate() throws {
        guard let runtime = runtimeIdentity.runtime, runtime.instanceID == runtimeIdentity.instanceID,
              runtime.requestedExecutable == runtimeIdentity.executable,
              PiRuntimeConfiguration.supportsObservedVersion(observedVersion),
              openingInput.kind == .opening, openingInput.nativeUserEntryID == nil,
              openingInput.inputDigest == inputDigest,
              baseline.nativeSessionFile == nativeSessionFile, baseline.nativeSessionID == nativeSessionID else { throw PiHistoryGraphError(.invalidWindow) }
        try runtime.validate(); try openingInput.validate(); try baseline.validate()
        if let reservation = openingInput.bridgeReservation {
            guard reservation.runPreparationID == id, reservation.nativeSessionID == nativeSessionID,
                  reservation.nativeSessionFile == nativeSessionFile else { throw PiHistoryGraphError(.invalidWindow) }
        }
        if let freshIntentID {
            _ = freshIntentID
            guard let empty = freshEmptyObservation, empty.nativeSessionFile == nativeSessionFile,
                  empty.nativeSessionID == nativeSessionID, empty.entries.isEmpty, empty.leafID == nil,
                  baseline.entries.allSatisfy({ $0.kind == PiHistoryEntry.Kind.modelChange.rawValue || $0.kind == PiHistoryEntry.Kind.thinkingLevelChange.rawValue }) else {
                throw PiHistoryGraphError(.invalidWindow)
            }
            try empty.validate()
        } else { guard freshEmptyObservation == nil else { throw PiHistoryGraphError(.invalidWindow) } }
    }
}

public enum PiRunHistoryCaptureStatus: String, Codable, Sendable { case prepared, proven, noNativeChange, unavailable }

public struct PiSteeringHistoryPreparation: Codable, Sendable, Equatable {
    public let id: UUID
    public let runID: UUID
    public let runPreparationID: UUID
    public let runtimeIdentity: PiRuntimeIdentity
    public let input: PiHistoryInputEvidence
    public init(id: UUID = UUID(), runID: UUID, runPreparationID: UUID, runtimeIdentity: PiRuntimeIdentity,
                input: PiHistoryInputEvidence) throws {
        self.id = id; self.runID = runID; self.runPreparationID = runPreparationID; self.runtimeIdentity = runtimeIdentity; self.input = input
        try validate()
    }
    public func validate() throws {
        guard let runtime = runtimeIdentity.runtime, runtime.instanceID == runtimeIdentity.instanceID,
              runtime.requestedExecutable == runtimeIdentity.executable, input.kind != .opening, input.nativeUserEntryID == nil else { throw PiHistoryGraphError(.invalidWindow) }
        try runtime.validate(); try input.validate()
        if let reservation = input.bridgeReservation {
            guard reservation.runPreparationID == runPreparationID else { throw PiHistoryGraphError(.invalidWindow) }
        }
    }
}

public struct PiRunHistoryEvidence: Codable, Sendable, Equatable {
    public let preparation: PiRunHistoryPreparation
    public var inputs: [PiHistoryInputEvidence]
    public let finalObservation: PiRuntimeEntryObservation?
    public let openingUserEntryID: String?
    public let nativeUserEntryIDs: [String]
    public let captureStatus: PiRunHistoryCaptureStatus
    public let terminalStatus: ThreadRunStatus?
    /// Only a fresh consumer needs this anchored, actually persisted native
    /// artifact before its deferred empty-context intent may be cleared.
    public let persistedFileRevision: PiHistoryFileRevision?
    public var runID: UUID { preparation.runID }
    public var runtimeIdentity: PiRuntimeIdentity { preparation.runtimeIdentity }
    public var nativeSessionFile: String { preparation.nativeSessionFile }
    public var nativeSessionID: String { preparation.nativeSessionID }
    public init(preparation: PiRunHistoryPreparation) throws {
        try self.init(preparation: preparation, inputs: [preparation.openingInput], finalObservation: nil,
            openingUserEntryID: nil, nativeUserEntryIDs: [], captureStatus: .prepared, terminalStatus: nil)
    }
    public init(preparation: PiRunHistoryPreparation, inputs: [PiHistoryInputEvidence], finalObservation: PiRuntimeEntryObservation?,
                openingUserEntryID: String?, nativeUserEntryIDs: [String], captureStatus: PiRunHistoryCaptureStatus, terminalStatus: ThreadRunStatus?,
                persistedFileRevision: PiHistoryFileRevision? = nil) throws {
        self.preparation = preparation; self.inputs = inputs; self.finalObservation = finalObservation
        self.openingUserEntryID = openingUserEntryID; self.nativeUserEntryIDs = nativeUserEntryIDs
        self.captureStatus = captureStatus; self.terminalStatus = terminalStatus
        self.persistedFileRevision = persistedFileRevision
        try validate()
    }
    public mutating func registerSteering(_ input: PiHistoryInputEvidence) throws {
        try validate(); try input.validate()
        guard captureStatus == .prepared, input.kind != .opening, input.nativeUserEntryID == nil,
              inputs.count < 65, !inputs.contains(where: { $0.clientMessageID == input.clientMessageID }) else { throw PiHistoryGraphError(.invalidWindow) }
        inputs.append(input)
    }
    public func validate() throws {
        try preparation.validate()
        guard !inputs.isEmpty, inputs.count <= 65, inputs.first?.clientMessageID == preparation.openingInput.clientMessageID,
              inputs.first?.inputDigest == preparation.inputDigest, inputs.first?.kind == .opening,
              inputs.dropFirst().allSatisfy({ $0.kind != .opening }), Set(inputs.map(\.clientMessageID)).count == inputs.count else { throw PiHistoryGraphError(.invalidWindow) }
        for input in inputs { try input.validate() }
        guard inputs.first?.bridgeReservation == preparation.openingInput.bridgeReservation else { throw PiHistoryGraphError(.invalidWindow) }
        let userInputs = inputs.filter { $0.kind != .compact }
        if preparation.openingInput.bridgeReservation != nil {
            guard userInputs.allSatisfy({ input in
                input.bridgeReservation?.runPreparationID == preparation.id &&
                input.bridgeReservation?.nativeSessionID == nativeSessionID &&
                input.bridgeReservation?.nativeSessionFile == nativeSessionFile &&
                input.bridgeReservation?.processEpoch == preparation.openingInput.bridgeReservation?.processEpoch
            }) else { throw PiHistoryGraphError(.invalidWindow) }
        } else { guard userInputs.allSatisfy({ $0.bridgeReservation == nil }) else { throw PiHistoryGraphError(.invalidWindow) } }
        let mapped = inputs.compactMap(\.nativeUserEntryID)
        guard Set(mapped).count == mapped.count, Set(nativeUserEntryIDs).count == nativeUserEntryIDs.count else { throw PiHistoryGraphError(.invalidWindow) }
        if captureStatus == .prepared {
            guard terminalStatus == nil, finalObservation == nil, openingUserEntryID == nil, nativeUserEntryIDs.isEmpty, mapped.isEmpty, persistedFileRevision == nil else { throw PiHistoryGraphError(.invalidWindow) }
            return
        }
        guard terminalStatus == .completed || terminalStatus == .interrupted || terminalStatus == .failed else { throw PiHistoryGraphError(.invalidWindow) }
        if let finalObservation {
            try finalObservation.validate()
            guard finalObservation.nativeSessionFile == nativeSessionFile, finalObservation.nativeSessionID == nativeSessionID else { throw PiHistoryGraphError(.invalidWindow) }
        }
        if let persistedFileRevision {
            try persistedFileRevision.validate()
            guard preparation.freshIntentID != nil, finalObservation != nil,
                  persistedFileRevision.filePath == nativeSessionFile, persistedFileRevision.sessionID == nativeSessionID else { throw PiHistoryGraphError(.invalidWindow) }
        }
        if captureStatus == .unavailable {
            guard openingUserEntryID == nil, nativeUserEntryIDs.isEmpty, mapped.isEmpty else { throw PiHistoryGraphError(.invalidWindow) }; return
        }
        guard let finalObservation else { throw PiHistoryGraphError(.invalidWindow) }
        let window = try finalObservation.appendedWindow(since: preparation.baseline)
        if captureStatus == .noNativeChange {
            guard window.isEmpty, finalObservation == preparation.baseline, nativeUserEntryIDs.isEmpty, mapped.isEmpty, openingUserEntryID == nil else { throw PiHistoryGraphError(.invalidWindow) }
        } else {
            let users = window.filter(\.isUser).map(\.id)
            guard !users.isEmpty, users == nativeUserEntryIDs, openingUserEntryID == users.first,
                  inputs.first?.nativeUserEntryID == users.first, mapped == users,
                  inputs.filter({ $0.kind != .compact }).allSatisfy({ $0.nativeUserEntryID != nil }) else { throw PiHistoryGraphError(.invalidWindow) }
            if preparation.openingInput.bridgeReservation != nil {
                try PiInputBridge.validate(reservations: userInputs.compactMap(\.bridgeReservation),
                    evidence: userInputs.compactMap(\.bridgeEvidence), baseline: preparation.baseline, finalObservation: finalObservation)
            }
        }
    }
    public func merging(_ observed: Self) throws -> Self {
        try validate(); try observed.validate()
        guard preparation == observed.preparation else { throw PiHistoryGraphError(.invalidWindow) }
        func sameOwner(_ old: PiHistoryInputEvidence, _ new: PiHistoryInputEvidence) -> Bool {
            old.clientMessageID == new.clientMessageID && old.inputDigest == new.inputDigest && old.kind == new.kind &&
                old.bridgeReservation == new.bridgeReservation && (old.bridgeEvidence == nil || old.bridgeEvidence == new.bridgeEvidence) &&
                (old.nativeUserEntryID == nil || old.nativeUserEntryID == new.nativeUserEntryID)
        }
        if captureStatus == .prepared, observed.captureStatus != .prepared, inputs.count > observed.inputs.count,
           zip(inputs, observed.inputs).allSatisfy({ sameOwner($0.0, $0.1) }) {
            // A marker can commit just before cancellation releases an actor
            // reservation. Preserve that owner without inventing consumption or
            // rejecting the real terminal. This run's history remains gated.
            let retained = try inputs.map { try PiHistoryInputEvidence(clientMessageID: $0.clientMessageID,
                inputDigest: $0.inputDigest, kind: $0.kind, bridgeReservation: $0.bridgeReservation) }
            return try .init(preparation: preparation, inputs: retained, finalObservation: observed.finalObservation,
                openingUserEntryID: nil, nativeUserEntryIDs: [], captureStatus: .unavailable, terminalStatus: observed.terminalStatus)
        }
        guard inputs.count == observed.inputs.count,
              zip(inputs, observed.inputs).allSatisfy({ sameOwner($0.0, $0.1) }),
              captureStatus == .prepared || self == observed else { throw PiHistoryGraphError(.invalidWindow) }
        return observed
    }
}

enum PiRunHistoryValidation {
    static func digest(_ value: String) throws {
        guard value.utf8.count == 64, value.utf8.allSatisfy({ (48...57).contains($0) || (97...102).contains($0) }) else { throw PiHistoryGraphError(.invalidWindow) }
    }
    static func inventoryDigest(_ values: [PiHistoryEntryDescriptor]) throws -> String {
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        let bytes = try encoder.encode(values)
        guard bytes.count <= PiHistoryGraph.maximumBytes else { throw PiHistoryGraphError(.oversized) }
        return PiHistoryValidation.sha(bytes)
    }
}
