import CryptoKit
import Foundation

/// An additive input lane. Existing v1 command payloads keep their exact bytes.
public struct RemoteComposerSubmission: Codable, Sendable, Equatable {
    private struct Payload: Codable, Sendable, Equatable {
        let target: RemoteAttachmentTarget
        let hostID: UUID
        let threadCreatedAt: Date
        let projectCreatedAt: Date?
        let text: String
        let expectedConfiguration: ProviderConfiguration
        let selectionDigest: String
        let expectedHostDraftDigest: String
        let expectedDraftAttachments: [ChatAttachment]
        let selectedDraftAttachmentIDs: [UUID]
        let uploadedAttachmentIDs: [UUID]
        let orderedAttachmentIDs: [UUID]
    }
    private let storage: [Payload]
    public var target: RemoteAttachmentTarget { storage[0].target }
    public var hostID: UUID { storage[0].hostID }
    public var threadCreatedAt: Date { storage[0].threadCreatedAt }
    public var projectCreatedAt: Date? { storage[0].projectCreatedAt }
    public var text: String { storage[0].text }
    public var expectedConfiguration: ProviderConfiguration { storage[0].expectedConfiguration }
    public var selectionDigest: String { storage[0].selectionDigest }
    public var expectedHostDraftDigest: String { storage[0].expectedHostDraftDigest }
    public var expectedDraftAttachments: [ChatAttachment] { storage[0].expectedDraftAttachments }
    public var selectedDraftAttachmentIDs: [UUID] { storage[0].selectedDraftAttachmentIDs }
    public var orderedAttachmentIDs: [UUID] { storage[0].orderedAttachmentIDs }
    public var uploadedAttachmentIDs: [UUID] { storage[0].uploadedAttachmentIDs }
    public init(target: RemoteAttachmentTarget, hostID: UUID, threadCreatedAt: Date, projectCreatedAt: Date?, text: String,
                expectedConfiguration: ProviderConfiguration, expectedHostDraftDigest: String,
                expectedDraftAttachments: [ChatAttachment], selectedDraftAttachmentIDs: [UUID], uploadedAttachmentIDs: [UUID], selectionDigest: String, orderedAttachmentIDs: [UUID]? = nil) {
        storage = [.init(target: target, hostID: hostID, threadCreatedAt: threadCreatedAt, projectCreatedAt: projectCreatedAt,
            text: text, expectedConfiguration: expectedConfiguration, selectionDigest: selectionDigest, expectedHostDraftDigest: expectedHostDraftDigest,
            expectedDraftAttachments: expectedDraftAttachments, selectedDraftAttachmentIDs: selectedDraftAttachmentIDs, uploadedAttachmentIDs: uploadedAttachmentIDs, orderedAttachmentIDs: orderedAttachmentIDs ?? selectedDraftAttachmentIDs + uploadedAttachmentIDs)]
    }
    public init(from decoder: any Decoder) throws { storage = [try Payload(from: decoder)] }
    public func encode(to encoder: any Encoder) throws { try storage[0].encode(to: encoder) }
    public static func textDigest(_ text: String) -> String { SHA256.hash(data: Data(text.utf8)).map { String(format: "%02x", $0) }.joined() }
    public func validate() throws {
        try AttachmentLimits.validate(expectedDraftAttachments)
        guard text.utf16.count <= 120_000, CheckpointValidation.digest(expectedHostDraftDigest), CheckpointValidation.digest(selectionDigest),
              threadCreatedAt.timeIntervalSince1970.isFinite, projectCreatedAt?.timeIntervalSince1970.isFinite != false,
              Set(selectedDraftAttachmentIDs).count == selectedDraftAttachmentIDs.count,
              Set(uploadedAttachmentIDs).count == uploadedAttachmentIDs.count,
              orderedAttachmentIDs.count == selectedDraftAttachmentIDs.count + uploadedAttachmentIDs.count,
              Set(orderedAttachmentIDs) == Set(selectedDraftAttachmentIDs + uploadedAttachmentIDs),
              selectedDraftAttachmentIDs.allSatisfy({ id in expectedDraftAttachments.contains { $0.id == id } }),
              selectedDraftAttachmentIDs.count + uploadedAttachmentIDs.count <= AttachmentLimits.count,
              Set(expectedDraftAttachments.map(\.id)).isDisjoint(with: uploadedAttachmentIDs),
              !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || !selectedDraftAttachmentIDs.isEmpty || !uploadedAttachmentIDs.isEmpty else {
            throw RemoteAttachmentFailure(.invalidRequest)
        }
    }
}
