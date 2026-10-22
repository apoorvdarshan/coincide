import Foundation

public struct GitCheckpointIndexRevision: Codable, Sendable, Equatable {
    public let identity: GitWorktreeNodeIdentity
    public let byteLength: Int64
    public let modifiedSeconds: Int64
    public let modifiedNanoseconds: Int64
    public let digest: String
    public init(identity: GitWorktreeNodeIdentity, byteLength: Int64, modifiedSeconds: Int64, modifiedNanoseconds: Int64, digest: String) {
        self.identity = identity; self.byteLength = byteLength; self.modifiedSeconds = modifiedSeconds
        self.modifiedNanoseconds = modifiedNanoseconds; self.digest = digest
    }
}

/// A local capture intent. It contains no environment, Git configuration values or commands.
public struct GitCheckpointPlan: Codable, Sendable, Equatable, Identifiable {
    public let id: UUID
    public let workspacePath: String
    public let repositoryPath: String
    public let gitDirectoryPath: String
    public let commonDirectoryPath: String
    public let workspaceIdentity: GitWorktreeNodeIdentity
    public let repositoryIdentity: GitWorktreeNodeIdentity
    public let gitDirectoryIdentity: GitWorktreeNodeIdentity
    public let commonDirectoryIdentity: GitWorktreeNodeIdentity
    public let objectDirectoryIdentity: GitWorktreeNodeIdentity
    public let headCommit: String?
    public let objectFormat: String
    public let configurationDigest: String
    public let indexRevision: GitCheckpointIndexRevision?
    public var reference: String { "refs/coincide/checkpoints/" + id.uuidString.lowercased() }
    public init(id: UUID = UUID(), workspacePath: String, repositoryPath: String, gitDirectoryPath: String, commonDirectoryPath: String,
                workspaceIdentity: GitWorktreeNodeIdentity, repositoryIdentity: GitWorktreeNodeIdentity,
                gitDirectoryIdentity: GitWorktreeNodeIdentity, commonDirectoryIdentity: GitWorktreeNodeIdentity, objectDirectoryIdentity: GitWorktreeNodeIdentity,
                headCommit: String?, objectFormat: String = "sha1", configurationDigest: String, indexRevision: GitCheckpointIndexRevision?) throws {
        self.id = id; self.workspacePath = workspacePath; self.repositoryPath = repositoryPath
        self.gitDirectoryPath = gitDirectoryPath; self.commonDirectoryPath = commonDirectoryPath
        self.workspaceIdentity = workspaceIdentity; self.repositoryIdentity = repositoryIdentity
        self.gitDirectoryIdentity = gitDirectoryIdentity; self.commonDirectoryIdentity = commonDirectoryIdentity
        self.objectDirectoryIdentity = objectDirectoryIdentity
        self.headCommit = headCommit; self.objectFormat = objectFormat; self.configurationDigest = configurationDigest; self.indexRevision = indexRevision
        try validate()
    }
    public func validate() throws {
        for path in [workspacePath, repositoryPath, gitDirectoryPath, commonDirectoryPath] { try CheckpointValidation.path(path) }
        guard workspacePath == repositoryPath || workspacePath.hasPrefix(repositoryPath + "/"),
              gitDirectoryPath == commonDirectoryPath || gitDirectoryPath.hasPrefix(commonDirectoryPath + "/worktrees/"),
              [workspaceIdentity, repositoryIdentity, gitDirectoryIdentity, commonDirectoryIdentity, objectDirectoryIdentity].allSatisfy({ $0.inode != 0 }),
              objectFormat == "sha1" || objectFormat == "sha256", CheckpointValidation.digest(configurationDigest),
              headCommit.map({ CheckpointValidation.object($0, format: objectFormat) }) ?? true else { throw GitCheckpointError(.invalidPlan) }
        if let indexRevision {
            guard indexRevision.identity.inode != 0, (0...67_108_864).contains(indexRevision.byteLength),
                  (0..<1_000_000_000).contains(indexRevision.modifiedNanoseconds), CheckpointValidation.digest(indexRevision.digest) else { throw GitCheckpointError(.invalidPlan) }
        }
    }
    private enum CodingKeys: String, CodingKey { case id, workspacePath, repositoryPath, gitDirectoryPath, commonDirectoryPath, workspaceIdentity, repositoryIdentity, gitDirectoryIdentity, commonDirectoryIdentity, objectDirectoryIdentity, headCommit, objectFormat, configurationDigest, indexRevision }
    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        try self.init(id: c.decode(UUID.self, forKey: .id), workspacePath: c.decode(String.self, forKey: .workspacePath),
            repositoryPath: c.decode(String.self, forKey: .repositoryPath), gitDirectoryPath: c.decode(String.self, forKey: .gitDirectoryPath),
            commonDirectoryPath: c.decode(String.self, forKey: .commonDirectoryPath), workspaceIdentity: c.decode(GitWorktreeNodeIdentity.self, forKey: .workspaceIdentity),
            repositoryIdentity: c.decode(GitWorktreeNodeIdentity.self, forKey: .repositoryIdentity), gitDirectoryIdentity: c.decode(GitWorktreeNodeIdentity.self, forKey: .gitDirectoryIdentity),
            commonDirectoryIdentity: c.decode(GitWorktreeNodeIdentity.self, forKey: .commonDirectoryIdentity), objectDirectoryIdentity: c.decode(GitWorktreeNodeIdentity.self, forKey: .objectDirectoryIdentity), headCommit: c.decodeIfPresent(String.self, forKey: .headCommit),
            objectFormat: c.decode(String.self, forKey: .objectFormat), configurationDigest: c.decode(String.self, forKey: .configurationDigest),
            indexRevision: c.decodeIfPresent(GitCheckpointIndexRevision.self, forKey: .indexRevision))
    }
}

public struct GitCheckpointReceipt: Codable, Sendable, Equatable {
    public let plan: GitCheckpointPlan
    public let commit: String
    public let tree: String
    public let capturedAt: Date
    /// Binds the exact temporary-file ownership proof without making that proof necessary
    /// for reading the saved Git objects. Older receipts deliberately have no cleanup proof.
    public let scratchManifestDigest: String?
    public init(plan: GitCheckpointPlan, commit: String, tree: String, capturedAt: Date = Date(), scratchManifestDigest: String? = nil) throws {
        self.plan = plan; self.commit = commit; self.tree = tree; self.capturedAt = capturedAt
        self.scratchManifestDigest = scratchManifestDigest; try validate()
    }
    public func validate() throws {
        try plan.validate()
        guard CheckpointValidation.object(commit, format: plan.objectFormat), CheckpointValidation.object(tree, format: plan.objectFormat),
              capturedAt.timeIntervalSince1970.isFinite,
              scratchManifestDigest.map(CheckpointValidation.digest) ?? true else { throw GitCheckpointError(.invalidPlan) }
    }
    private enum CodingKeys: String, CodingKey { case plan, commit, tree, capturedAt, scratchManifestDigest }
    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        try self.init(plan: c.decode(GitCheckpointPlan.self, forKey: .plan), commit: c.decode(String.self, forKey: .commit),
                      tree: c.decode(String.self, forKey: .tree), capturedAt: c.decode(Date.self, forKey: .capturedAt),
                      scratchManifestDigest: c.decodeIfPresent(String.self, forKey: .scratchManifestDigest))
    }
}
public enum GitCheckpointInspection: Sendable, Equatable { case missing, incomplete, ready(GitCheckpointReceipt) }
public struct GitCheckpointDiff: Sendable, Equatable {
    public let patch: String
    public let truncated: Bool
    public init(patch: String, truncated: Bool) { self.patch = patch; self.truncated = truncated }
}
public struct GitCheckpointError: Error, LocalizedError, Sendable, Equatable {
    public enum Kind: String, Sendable { case invalidPlan, notRepository, ownershipLost, configurationChanged, unsupportedConfiguration, refCollision, incomplete, metadataInvalid, commandFailed, timedOut, outputLimit }
    public let kind: Kind
    public init(_ kind: Kind) { self.kind = kind }
    public var errorDescription: String? {
        switch kind {
        case .invalidPlan: "The checkpoint plan or filename is invalid."
        case .notRepository: "This folder is not an available local Git workspace."
        case .ownershipLost: "The checkpoint workspace or Git directory changed. Existing files were preserved."
        case .configurationChanged: "Git configuration, HEAD or the real index changed after checkpoint planning. Prepare a new capture."
        case .unsupportedConfiguration: "This Git configuration cannot be checkpointed safely. Executable filters and unsupported sparse layouts are not run or changed."
        case .refCollision: "The checkpoint reference or attempt metadata already exists without matching completion evidence. It was preserved."
        case .incomplete: "This checkpoint attempt was interrupted. Preserve it and prepare a new capture."
        case .metadataInvalid: "The checkpoint completion evidence is invalid or changed. No existing reference was replaced."
        case .commandFailed: "The local Git checkpoint operation failed. Existing files and staging were preserved."
        case .timedOut: "The local Git checkpoint operation timed out. Existing files and staging were preserved."
        case .outputLimit: "Git checkpoint data exceeded its size limit. Existing files and staging were preserved."
        }
    }
}
enum CheckpointValidation {
    static func path(_ value: String) throws {
        guard value.hasPrefix("/"), !value.contains("\0"), !value.split(separator: "/", omittingEmptySubsequences: false).dropFirst().contains(where: { $0.isEmpty || $0 == "." || $0 == ".." }) else { throw GitCheckpointError(.invalidPlan) }
    }
    static func digest(_ value: String) -> Bool { value.utf8.count == 64 && value.utf8.allSatisfy({ (48...57).contains($0) || (97...102).contains($0) }) }
    static func object(_ value: String, format: String) -> Bool { value.utf8.count == (format == "sha256" ? 64 : 40) && value.utf8.allSatisfy({ (48...57).contains($0) || (97...102).contains($0) }) }
}
