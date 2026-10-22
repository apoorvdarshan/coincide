import CryptoKit
import Foundation

/// Prospective identities derive only from already-persisted local input owners.
/// They are not delivery receipts; native transcript proof remains mandatory.
public enum ClaudeInputIdentity {
    public static func opening(runID: UUID) -> String { runID.uuidString.lowercased() }
    public static func steering(messageID: String) throws -> String {
        guard !messageID.isEmpty, messageID.utf8.count <= 4_096,
              !messageID.unicodeScalars.contains(where: { $0.value < 32 || $0.value == 127 }) else { throw ClaudeRuntimeConfiguration.invalid() }
        var bytes = Array(SHA256.hash(data: Data(("Coincide.Claude.Steering.v1\0" + messageID).utf8)).prefix(16))
        bytes[6] = (bytes[6] & 15) | 0x80; bytes[8] = (bytes[8] & 63) | 0x80
        let text = bytes.map { String(format: "%02x", $0) }.joined()
        let characters = Array(text)
        return [String(characters[0..<8]), String(characters[8..<12]), String(characters[12..<16]),
                String(characters[16..<20]), String(characters[20..<32])].joined(separator: "-")
    }
}

public struct ClaudeSteeringInputEvidence: Codable, Sendable, Equatable {
    public let messageID: String
    public let nativeInputID: String
    public init(messageID: String) throws {
        self.messageID = messageID; nativeInputID = try ClaudeInputIdentity.steering(messageID: messageID)
    }
    public func validate() throws {
        guard nativeInputID == (try ClaudeInputIdentity.steering(messageID: messageID)) else { throw ClaudeRuntimeConfiguration.invalid() }
    }
}

/// A run's prospective input owners and observed ROOT envelope identities.
/// Root assistant IDs remain separate from weak adapter turnIDs/API message IDs.
public struct ClaudeRunHistoryEvidence: Codable, Sendable, Equatable {
    public static let maximumInputs = 1_024
    public static let maximumAssistants = 4_096
    public let runID: UUID
    public let runtimeIdentity: ClaudeRuntimeIdentity
    public let openingInputID: String
    public private(set) var nativeSessionID: String?
    public private(set) var steeringInputs: [ClaudeSteeringInputEvidence]
    public private(set) var observedInputIDs: [String]
    public private(set) var rootAssistantMessageIDs: [String]
    public private(set) var terminalStatus: ThreadRunStatus?
    public init(runID: UUID, runtimeIdentity: ClaudeRuntimeIdentity, nativeSessionID: String? = nil,
                steeringInputs: [ClaudeSteeringInputEvidence] = [], observedInputIDs: [String] = [],
                rootAssistantMessageIDs: [String] = [], terminalStatus: ThreadRunStatus? = nil) throws {
        self.runID = runID; self.runtimeIdentity = runtimeIdentity; openingInputID = ClaudeInputIdentity.opening(runID: runID)
        self.nativeSessionID = nativeSessionID; self.steeringInputs = steeringInputs; self.observedInputIDs = observedInputIDs
        self.rootAssistantMessageIDs = rootAssistantMessageIDs; self.terminalStatus = terminalStatus
        try validate()
    }
    public var registeredInputIDs: [String] { [openingInputID] + steeringInputs.map(\.nativeInputID) }
    public var finalRootAssistantMessageID: String? { rootAssistantMessageIDs.last }
    public func validate() throws {
        try runtimeIdentity.validate()
        guard openingInputID == ClaudeInputIdentity.opening(runID: runID),
              steeringInputs.count < Self.maximumInputs, observedInputIDs.count <= Self.maximumInputs,
              rootAssistantMessageIDs.count <= Self.maximumAssistants,
              Set(steeringInputs.map(\.messageID)).count == steeringInputs.count,
              Set(registeredInputIDs.map { $0.lowercased() }).count == registeredInputIDs.count,
              Set(observedInputIDs.map { $0.lowercased() }).count == observedInputIDs.count,
              Set(rootAssistantMessageIDs.map { $0.lowercased() }).count == rootAssistantMessageIDs.count,
              observedInputIDs.allSatisfy({ registeredInputIDs.contains($0) }),
              terminalStatus.map({ [.completed, .interrupted, .failed].contains($0) }) ?? true,
              nativeSessionID != nil || (observedInputIDs.isEmpty && rootAssistantMessageIDs.isEmpty && terminalStatus == nil) else { throw ClaudeRuntimeConfiguration.invalid() }
        if let nativeSessionID { try ClaudeRuntimeValidation.uuid(nativeSessionID) }
        for input in steeringInputs { try input.validate() }
        for id in observedInputIDs + rootAssistantMessageIDs { try ClaudeRuntimeValidation.uuid(id) }
    }
    public mutating func registerSteering(messageID: String) throws {
        let input = try ClaudeSteeringInputEvidence(messageID: messageID)
        if steeringInputs.contains(input) { return }
        guard terminalStatus == nil, registeredInputIDs.count < Self.maximumInputs else { throw ClaudeRuntimeConfiguration.invalid() }
        steeringInputs.append(input); try validate()
    }
    public mutating func observe(nativeSessionID: String, inputIDs: [String] = [], rootAssistantMessageID: String? = nil) throws {
        try ClaudeRuntimeValidation.uuid(nativeSessionID)
        guard terminalStatus == nil, self.nativeSessionID == nil || self.nativeSessionID == nativeSessionID,
              inputIDs.allSatisfy({ registeredInputIDs.contains($0) }) else { throw ClaudeRuntimeConfiguration.invalid() }
        self.nativeSessionID = nativeSessionID
        for id in inputIDs where !observedInputIDs.contains(id) { observedInputIDs.append(id) }
        if let rootAssistantMessageID, !rootAssistantMessageIDs.contains(rootAssistantMessageID) { rootAssistantMessageIDs.append(rootAssistantMessageID) }
        try validate()
    }
    public mutating func finish(_ status: ThreadRunStatus) throws {
        guard terminalStatus == nil || terminalStatus == status, nativeSessionID != nil else { throw ClaudeRuntimeConfiguration.invalid() }
        terminalStatus = status; try validate()
    }
    /// The reducer owns prospective steering registration. An adapter snapshot
    /// may observe it, never manufacture extra authored input owners or replace
    /// an earlier observed prefix with another run's identities.
    public func merging(_ observed: Self) throws -> Self {
        try validate(); try observed.validate()
        guard runID == observed.runID, runtimeIdentity == observed.runtimeIdentity, openingInputID == observed.openingInputID,
              nativeSessionID == nil || nativeSessionID == observed.nativeSessionID,
              Array(steeringInputs.prefix(observed.steeringInputs.count)) == observed.steeringInputs,
              observed.observedInputIDs.starts(with: observedInputIDs),
              observed.rootAssistantMessageIDs.starts(with: rootAssistantMessageIDs),
              terminalStatus == nil || terminalStatus == observed.terminalStatus else { throw ClaudeRuntimeConfiguration.invalid() }
        var result = self
        result.nativeSessionID = observed.nativeSessionID
        result.observedInputIDs = observed.observedInputIDs; result.rootAssistantMessageIDs = observed.rootAssistantMessageIDs
        result.terminalStatus = observed.terminalStatus
        try result.validate(); return result
    }
}
