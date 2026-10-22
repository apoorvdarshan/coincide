import Foundation

/// An explicit review of the complete checkpoint scope. The preview is display
/// data; only the sealed full manifest identified by manifestDigest authorizes
/// filesystem mutations. The target never falls back to HEAD.
public struct GitCheckpointRestoreReview: Codable, Sendable, Equatable, Identifiable {
    public let id: UUID
    public let targetReceipt: GitCheckpointReceipt
    public let currentPlan: GitCheckpointPlan
    public let reviewedAt: Date
    public let manifestDigest: String
    public let affectedPaths: [String]
    public let previewPatch: String
    public let previewTruncated: Bool
    public init(id: UUID = UUID(), targetReceipt: GitCheckpointReceipt, currentPlan: GitCheckpointPlan,
                reviewedAt: Date = Date(), manifestDigest: String, affectedPaths: [String] = [],
                previewPatch: String = "", previewTruncated: Bool = false) throws {
        self.id = id; self.targetReceipt = targetReceipt; self.currentPlan = currentPlan
        self.reviewedAt = reviewedAt; self.manifestDigest = manifestDigest; self.affectedPaths = affectedPaths
        self.previewPatch = previewPatch; self.previewTruncated = previewTruncated
        try validate()
    }
    public func validate() throws {
        try targetReceipt.validate(); try currentPlan.validate()
        let target = targetReceipt.plan
        guard reviewedAt.timeIntervalSince1970.isFinite, CheckpointValidation.digest(manifestDigest),
              currentPlan.workspacePath == target.workspacePath, currentPlan.repositoryPath == target.repositoryPath,
              currentPlan.gitDirectoryPath == target.gitDirectoryPath, currentPlan.commonDirectoryPath == target.commonDirectoryPath,
              currentPlan.workspaceIdentity == target.workspaceIdentity, currentPlan.repositoryIdentity == target.repositoryIdentity,
              currentPlan.gitDirectoryIdentity == target.gitDirectoryIdentity, currentPlan.commonDirectoryIdentity == target.commonDirectoryIdentity,
              currentPlan.objectDirectoryIdentity == target.objectDirectoryIdentity, currentPlan.objectFormat == target.objectFormat,
              Set(affectedPaths).count == affectedPaths.count, affectedPaths.count <= 100_000,
              affectedPaths.reduce(0, { $0 + $1.utf8.count + 1 }) <= 4_194_304,
              previewPatch.utf8.count <= 1_048_576 else { throw GitCheckpointRestoreError(.invalidReview) }
        for path in affectedPaths { do { try CheckpointFiles.relative(path) } catch { throw GitCheckpointRestoreError(.invalidReview) } }
    }
    private enum CodingKeys: String, CodingKey { case id, targetReceipt, currentPlan, reviewedAt, manifestDigest, affectedPaths, previewPatch, previewTruncated }
    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        try self.init(id: c.decode(UUID.self, forKey: .id), targetReceipt: c.decode(GitCheckpointReceipt.self, forKey: .targetReceipt),
            currentPlan: c.decode(GitCheckpointPlan.self, forKey: .currentPlan), reviewedAt: c.decode(Date.self, forKey: .reviewedAt),
            manifestDigest: c.decode(String.self, forKey: .manifestDigest), affectedPaths: c.decode([String].self, forKey: .affectedPaths),
            previewPatch: c.decode(String.self, forKey: .previewPatch), previewTruncated: c.decode(Bool.self, forKey: .previewTruncated))
    }
}

/// Written only after the entire owned restore and final verification complete.
public struct GitCheckpointRestoreReceipt: Codable, Sendable, Equatable {
    public let review: GitCheckpointRestoreReview
    public let completedAt: Date
    public let finalIndexRevision: GitCheckpointIndexRevision?
    public let stateDigest: String
    public init(review: GitCheckpointRestoreReview, completedAt: Date = Date(),
                finalIndexRevision: GitCheckpointIndexRevision? = nil, stateDigest: String) throws {
        self.review = review; self.completedAt = completedAt; self.finalIndexRevision = finalIndexRevision
        self.stateDigest = stateDigest; try validate()
    }
    public func validate() throws {
        try review.validate()
        guard completedAt.timeIntervalSince1970.isFinite, CheckpointValidation.digest(stateDigest) else { throw GitCheckpointRestoreError(.metadataInvalid) }
        if let index = finalIndexRevision {
            guard index.identity.inode != 0, (index.byteLength >= 0 && index.byteLength <= Int64(CheckpointFiles.maximumIndexBytes)),
                  (0..<1_000_000_000).contains(index.modifiedNanoseconds), CheckpointValidation.digest(index.digest) else { throw GitCheckpointRestoreError(.metadataInvalid) }
        }
    }
    private enum CodingKeys: String, CodingKey { case review, completedAt, finalIndexRevision, stateDigest }
    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        try self.init(review: c.decode(GitCheckpointRestoreReview.self, forKey: .review), completedAt: c.decode(Date.self, forKey: .completedAt),
            finalIndexRevision: c.decodeIfPresent(GitCheckpointIndexRevision.self, forKey: .finalIndexRevision), stateDigest: c.decode(String.self, forKey: .stateDigest))
    }
}
public enum GitCheckpointRestoreInspection: Codable, Sendable, Equatable {
    case notStarted
    case interrupted
    case ready(GitCheckpointRestoreReceipt)
}

/// After a restore starts, failure/cancellation may leave a partially changed
/// checkout. Callers must inspect recorded evidence; never replay blindly.
public struct GitCheckpointRestoreError: Error, LocalizedError, Sendable, Equatable {
    public enum Kind: String, Codable, Sendable {
        case invalidReview, staleReview, ownershipLost, unsupportedConfiguration, metadataInvalid
        case incomplete, commandFailed, timedOut, outputLimit, interrupted
    }
    public let kind: Kind
    public let mayHaveMutated: Bool
    public init(_ kind: Kind, mayHaveMutated: Bool = false) { self.kind = kind; self.mayHaveMutated = mayHaveMutated }
    public var errorDescription: String? {
        if mayHaveMutated { return "Checkpoint restore did not finish with confirmed evidence. Some files or staging may have changed. Preserved recovery data must be inspected before continuing." }
        switch kind {
        case .invalidReview: return "The checkpoint restore review is invalid. Review the current workspace again."
        case .staleReview: return "The checkout, staging or checkpoint changed after review. No restore was started."
        case .ownershipLost: return "The workspace or Git ownership changed. No restore was started."
        case .unsupportedConfiguration: return "This workspace cannot be restored safely with its current Git configuration or file layout."
        case .metadataInvalid: return "Checkpoint restore ownership evidence is missing or changed. Existing recovery data was preserved."
        case .incomplete, .interrupted: return "A checkpoint restore attempt was interrupted. Inspect its recorded state instead of repeating it."
        case .commandFailed: return "The local checkpoint restore could not be prepared. No restore was started."
        case .timedOut: return "Checkpoint restore preparation timed out. No restore was started."
        case .outputLimit: return "The checkpoint restore exceeds its bounded review or staging limits. No restore was started."
        }
    }
}
