import Foundation

/// A provider-native turn and an adapter-owned run are different evidence.
/// The latter never becomes a native turn or a provider history boundary.
public enum ProviderSteeringTarget: Codable, Sendable, Equatable {
    case nativeTurn(String)
    case adapterRun(UUID)
    public func validate() throws {
        if case .nativeTurn(let id) = self { try ProviderSteeringValidation.id(id) }
    }
    public func matches(run: ActiveRun) -> Bool {
        guard (try? validate()) != nil else { return false }
        switch self {
        case .nativeTurn(let id): return run.nativeTurnID == id
        case .adapterRun(let id): return run.id == id && run.nativeTurnID == nil && run.configuration.provider == .pi
        }
    }
}

public struct ProviderSteeringCapabilities: Codable, Sendable, Equatable {
    public let supportsActiveSteering: Bool
    public let interruptsTools: Bool
    public let unavailableReason: String?
    public let target: ProviderSteeringTarget?
    public init(supportsActiveSteering: Bool = false, interruptsTools: Bool = false, unavailableReason: String? = nil,
                target: ProviderSteeringTarget? = nil) {
        self.supportsActiveSteering = supportsActiveSteering; self.interruptsTools = interruptsTools
        self.unavailableReason = unavailableReason
        self.target = target
    }
}

/// A protocol acknowledgement and a completed transport write are different
/// evidence. Neither proves the model has already consumed the additional input.
public enum ProviderSteeringDelivery: String, Codable, Sendable, Equatable { case acknowledged, submitted }

public struct ProviderSteeringReceipt: Codable, Sendable, Equatable {
    public let turnID: String?
    public let adapterRunID: UUID?
    public let delivery: ProviderSteeringDelivery
    public var target: ProviderSteeringTarget? {
        switch (turnID, adapterRunID) {
        case (.some(let id), .none): .nativeTurn(id)
        case (.none, .some(let id)): .adapterRun(id)
        default: nil
        }
    }
    public init(turnID: String, delivery: ProviderSteeringDelivery = .acknowledged) throws {
        try self.init(target: .nativeTurn(turnID), delivery: delivery)
    }
    public init(target: ProviderSteeringTarget, delivery: ProviderSteeringDelivery = .acknowledged) throws {
        try target.validate()
        switch target {
        case .nativeTurn(let id): turnID = id; adapterRunID = nil
        case .adapterRun(let id): turnID = nil; adapterRunID = id
        }
        self.delivery = delivery
    }
    public func validate() throws {
        guard let target else { throw ProviderSteeringError(.invalidRequest) }
        try target.validate()
    }
    private enum CodingKeys: String, CodingKey { case turnID, adapterRunID, delivery }
    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        turnID = try c.decodeIfPresent(String.self, forKey: .turnID)
        adapterRunID = try c.decodeIfPresent(UUID.self, forKey: .adapterRunID)
        delivery = try c.decodeIfPresent(ProviderSteeringDelivery.self, forKey: .delivery) ?? .acknowledged
        try validate()
    }
}

public struct ProviderSteeringError: LocalizedError, Sendable, Equatable {
    public enum Kind: String, Codable, Sendable { case unsupported, invalidRequest, noActiveTurn, staleTarget, rejected, outcomeUncertain }
    public let kind: Kind
    public init(_ kind: Kind) { self.kind = kind }
    public var mayHaveBeenDelivered: Bool { kind == .outcomeUncertain }
    public var errorDescription: String? {
        switch kind {
        case .unsupported: "This provider connection cannot safely steer the active turn. Queue this message or explicitly restart the turn."
        case .invalidRequest: "The steering message or active turn reference is invalid."
        case .noActiveTurn: "There is no active provider turn to steer."
        case .staleTarget: "The active provider turn changed before the steering message was sent."
        case .rejected: "The provider did not accept the steering message. It was not automatically resent."
        case .outcomeUncertain: "Delivery of the steering message could not be confirmed. It was not automatically resent."
        }
    }
}

enum ProviderSteeringValidation {
    static func id(_ value: String) throws {
        guard !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, value.utf8.count <= 4_096,
              !value.unicodeScalars.contains(where: { $0.value < 32 || $0.value == 127 }) else { throw ProviderSteeringError(.invalidRequest) }
    }
    static func input(_ input: ProviderInput) throws {
        guard !input.text.isEmpty || !input.images.isEmpty, input.text.utf8.count <= 4_194_304,
              input.images.count <= AttachmentLimits.count else { throw ProviderSteeringError(.invalidRequest) }
        var total = 0
        for image in input.images {
            guard ["image/png", "image/jpeg", "image/gif", "image/webp"].contains(image.mimeType),
                  !image.data.isEmpty, image.data.count <= AttachmentLimits.imageBytes else { throw ProviderSteeringError(.invalidRequest) }
            total += image.data.count
        }
        guard total <= AttachmentLimits.totalImageBytes else { throw ProviderSteeringError(.invalidRequest) }
    }
    static func target(_ thread: CodingThread, provider: ProviderKind, configuration: ProviderConfiguration?, runID: UUID?,
                       nativeThreadID: String?, turnID: String?, expectedTurnID: String) throws {
        guard let run = thread.activeRun, let configuration, run.id == runID, !run.stopRequested,
              run.configuration == configuration, run.nativeTurnID == expectedTurnID,
              thread.provider == provider, thread.providerThreadID == nativeThreadID, nativeThreadID != nil,
              turnID == expectedTurnID else { throw ProviderSteeringError(.staleTarget) }
        // The native thread ID can first arrive after the run was captured.
        // Every execution setting must still be the captured active setting.
        var presented = ProviderConfiguration(thread: thread)
        presented.nativeThreadID = configuration.nativeThreadID
        presented.claudeLaunchSelection = configuration.claudeLaunchSelection
        guard presented == configuration else { throw ProviderSteeringError(.staleTarget) }
    }
    static func target(_ thread: CodingThread, provider: ProviderKind, configuration: ProviderConfiguration?, runID: UUID?,
                       nativeThreadID: String?, target: ProviderSteeringTarget) throws {
        try target.validate()
        guard let run = thread.activeRun, let configuration, run.id == runID, !run.stopRequested,
              run.configuration == configuration, target.matches(run: run), thread.provider == provider,
              configuration.provider == provider, thread.providerThreadID == nativeThreadID, nativeThreadID != nil else {
            throw ProviderSteeringError(.staleTarget)
        }
        var presented = ProviderConfiguration(thread: thread); presented.nativeThreadID = configuration.nativeThreadID
        presented.claudeLaunchSelection = configuration.claudeLaunchSelection
        guard presented == configuration else { throw ProviderSteeringError(.staleTarget) }
    }
    static func frame(_ frame: JSONValue) throws {
        // Leave room for the JSON-RPC envelope below the existing 128 MiB
        // provider transport frame limit, including JSON-escaped authored text.
        guard try JSONEncoder().encode(frame).count <= 128 * 1_024 * 1_024 - 16_384 else { throw ProviderSteeringError(.invalidRequest) }
    }
}

struct ProviderSteeringTask: Sendable {
    let id: UUID
    let task: Task<ProviderSteeringReceipt, any Error>
}
