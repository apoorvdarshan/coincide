import Foundation

public enum ProviderContextInputDisposition: Sendable, Equatable { case ordinary, nativeCommand }

/// This payload is reserved durably for one explicit run before provider I/O.
/// The literal authored text and its image/attachment proofs stay separate.
public struct ProviderHistoricalContext: Codable, Sendable, Equatable {
    public let deliveryID: UUID
    public let transferIDs: [UUID]
    public let selection: ContextHandoffSelection
    public init(deliveryID: UUID, transferIDs: [UUID], selection: ContextHandoffSelection) {
        self.deliveryID = deliveryID; self.transferIDs = transferIDs; self.selection = selection
    }
    public func validate() throws {
        guard !transferIDs.isEmpty, transferIDs.count <= 32, Set(transferIDs).count == transferIDs.count,
              Set([selection.source.transferID] + selection.source.additionalTransferIDs) == Set(transferIDs) else {
            throw ContextHandoffError(.invalidSource)
        }
        try ContextHandoffService.validate(selection)
    }
}

extension ProviderInput {
    func requireNoHistoricalContextForSteering() throws {
        guard historicalContext == nil else { throw ProviderSteeringError(.unsupported) }
    }
    /// Each returned element becomes its own text block when the protocol
    /// supports blocks. Flat-text transports use the explicit inline wrapper.
    public func providerTextBlocks() throws -> [String] {
        guard let historicalContext else { return text.isEmpty ? [] : [text] }
        try historicalContext.validate()
        return [historicalContext.selection.renderedText] + (text.isEmpty ? [] : [text])
    }
    public func providerText() throws -> String {
        guard let historicalContext else { return text }
        try historicalContext.validate()
        return historicalContext.selection.renderedText + "\n\nUser message:\n" + text
    }
}
