import Darwin
import Foundation

public struct ScratchWorkspaceError: Error, LocalizedError, Sendable {
    public let message: String
    public init(_ message: String = "The private scratch workspace could not be verified. Existing folders and files were preserved.") { self.message = message }
    public var errorDescription: String? { message }
}

/// Physical directory incarnation; unlike a path or inode alone, a deleted
/// folder recreated at the same path cannot silently inherit the old grant.
public struct ScratchDirectoryIdentity: Codable, Sendable, Equatable {
    public let device: UInt64
    public let inode: UInt64
    public let birthSeconds: Int64
    public let birthNanoseconds: Int64
    public let owner: UInt32
    init(_ directory: GitWorktreeDirectory) throws {
        try directory.validate(); var value = stat()
        guard fstat(directory.fd, &value) == 0, value.st_birthtimespec.tv_sec > 0 else { throw ScratchWorkspaceError() }
        device = UInt64(truncatingIfNeeded: value.st_dev); inode = value.st_ino
        birthSeconds = Int64(value.st_birthtimespec.tv_sec); birthNanoseconds = Int64(value.st_birthtimespec.tv_nsec)
        owner = value.st_uid
    }
    var node: GitWorktreeNodeIdentity { .init(device: device, inode: inode) }
    func matches(_ directory: GitWorktreeDirectory) -> Bool { (try? ScratchDirectoryIdentity(directory)) == self }
}

/// App-owned filesystem identity, separate from Git/worktree/history proof.
/// Only the owned allocator and its internal registration decision grant this
/// authority; ordinary project/thread commands cannot supply it.
public struct ScratchProjectReceipt: Codable, Sendable, Equatable {
    private final class Storage: Codable, Sendable {
        let id: UUID
        let projectID: UUID
        let rootPath: String
        let identity: ScratchDirectoryIdentity
        let createdAt: Date
        init(id: UUID, projectID: UUID, rootPath: String, identity: ScratchDirectoryIdentity, createdAt: Date) {
            self.id = id; self.projectID = projectID; self.rootPath = rootPath; self.identity = identity; self.createdAt = createdAt
        }
    }
    private let storage: Storage
    public var id: UUID { storage.id }
    public var projectID: UUID { storage.projectID }
    public var rootPath: String { storage.rootPath }
    public var identity: ScratchDirectoryIdentity { storage.identity }
    public var createdAt: Date { storage.createdAt }
    init(id: UUID, projectID: UUID, rootPath: String, identity: ScratchDirectoryIdentity, createdAt: Date) {
        storage = .init(id: id, projectID: projectID, rootPath: rootPath, identity: identity, createdAt: createdAt)
    }
    public init(from decoder: any Decoder) throws { storage = try Storage(from: decoder) }
    public func encode(to encoder: any Encoder) throws { try storage.encode(to: encoder) }
    public static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.id == rhs.id && lhs.projectID == rhs.projectID && lhs.identity == rhs.identity && lhs.createdAt == rhs.createdAt &&
        lhs.rootPath.utf8.elementsEqual(rhs.rootPath.utf8)
    }
    func validates(_ project: WorkspaceProject) -> Bool {
        project.id == projectID && project.path.utf8.elementsEqual(rootPath.utf8) && project.clone == nil &&
        identity.inode != 0 && createdAt.timeIntervalSince1970.isFinite && rootPath.hasPrefix("/") && !rootPath.contains("\0")
    }
}

public struct ScratchWorkspaceReceipt: Codable, Sendable, Equatable {
    private final class Storage: Codable, Sendable {
        let commandID: UUID
        let threadID: UUID
        let project: ScratchProjectReceipt
        let folderName: String
        let identity: ScratchDirectoryIdentity
        let namingDigest: String
        let createdAt: Date
        let sharedFrom: UUID?
        init(commandID: UUID, threadID: UUID, project: ScratchProjectReceipt, folderName: String,
             identity: ScratchDirectoryIdentity, namingDigest: String, createdAt: Date, sharedFrom: UUID?) {
            self.sharedFrom = sharedFrom
            self.commandID = commandID; self.threadID = threadID; self.project = project; self.folderName = folderName
            self.identity = identity; self.namingDigest = namingDigest; self.createdAt = createdAt
        }
    }
    private let storage: Storage
    public var commandID: UUID { storage.commandID }
    public var threadID: UUID { storage.threadID }
    public var project: ScratchProjectReceipt { storage.project }
    public var folderName: String { storage.folderName }
    public var identity: ScratchDirectoryIdentity { storage.identity }
    public var namingDigest: String { storage.namingDigest }
    public var createdAt: Date { storage.createdAt }
    public var sharedFrom: UUID? { storage.sharedFrom }
    public var workspacePath: String { project.rootPath + "/" + folderName }
    init(commandID: UUID, threadID: UUID, project: ScratchProjectReceipt, folderName: String,
         identity: ScratchDirectoryIdentity, namingDigest: String, createdAt: Date, sharedFrom: UUID? = nil) {
        storage = .init(commandID: commandID, threadID: threadID, project: project, folderName: folderName,
                        identity: identity, namingDigest: namingDigest, createdAt: createdAt, sharedFrom: sharedFrom)
    }
    public init(from decoder: any Decoder) throws { storage = try Storage(from: decoder) }
    public func encode(to encoder: any Encoder) throws { try storage.encode(to: encoder) }
    public static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.commandID == rhs.commandID && lhs.threadID == rhs.threadID && lhs.project == rhs.project &&
        lhs.folderName.utf8.elementsEqual(rhs.folderName.utf8) && lhs.identity == rhs.identity &&
        lhs.namingDigest == rhs.namingDigest && lhs.createdAt == rhs.createdAt && lhs.sharedFrom == rhs.sharedFrom
    }
    func validates(thread: CodingThread, project owner: WorkspaceProject) -> Bool {
        guard let root = owner.scratch, root == project, root.validates(owner), thread.id == threadID,
              thread.projectID == owner.id, thread.createdAt == createdAt, thread.workspacePath.utf8.elementsEqual(workspacePath.utf8),
              thread.workspacePreparation == nil, identity.inode != 0, createdAt.timeIntervalSince1970.isFinite,
              (1...160).contains(folderName.utf8.count), !folderName.hasPrefix("."),
              folderName.utf8.allSatisfy({ (48...57).contains($0) || (97...122).contains($0) || $0 == 45 }),
              namingDigest.count == 64 else { return false }
        return namingDigest.utf8.allSatisfy { (48...57).contains($0) || (97...102).contains($0) }
    }
}

/// The original allocation is kept outside the conversation's user files.
public struct ScratchWorkspaceAllocation: Codable, Sendable, Equatable {
    private final class Storage: Codable, Sendable {
        let receipt: ScratchWorkspaceReceipt
        let project: WorkspaceProject
        init(receipt: ScratchWorkspaceReceipt, project: WorkspaceProject) { self.receipt = receipt; self.project = project }
    }
    private let storage: Storage
    public var receipt: ScratchWorkspaceReceipt { storage.receipt }
    public var project: WorkspaceProject { storage.project }
    public var threadID: UUID { receipt.threadID }
    public var workspacePath: String { receipt.workspacePath }
    init(receipt: ScratchWorkspaceReceipt, project: WorkspaceProject) { storage = .init(receipt: receipt, project: project) }
    public init(from decoder: any Decoder) throws { storage = try Storage(from: decoder) }
    public func encode(to encoder: any Encoder) throws { try storage.encode(to: encoder) }
    public static func == (lhs: Self, rhs: Self) -> Bool {
        guard lhs.receipt == rhs.receipt, let a = try? ScratchWorkspaceService.bytes(lhs.project),
              let b = try? ScratchWorkspaceService.bytes(rhs.project) else { return false }
        return a == b
    }
}

/// A first input is optional; opening an ordinary scratch conversation never
/// starts a provider. The complete request is saved before its original UUID is
/// enqueued, so recovery can inspect that exact payload without resending it.
public struct ScratchThreadCreation: Codable, Sendable, Equatable {
    private final class Storage: Codable, Sendable {
        let allocation: ScratchWorkspaceAllocation
        let thread: CodingThread
        let prompt: String?
        let selectsConversation: Bool
        let modelEdits: [ThreadEdit]
        init(allocation: ScratchWorkspaceAllocation, thread: CodingThread, prompt: String?, selectsConversation: Bool, modelEdits: [ThreadEdit]) {
            self.allocation = allocation; self.thread = thread; self.prompt = prompt; self.selectsConversation = selectsConversation; self.modelEdits = modelEdits
        }
    }
    private let storage: Storage
    public var allocation: ScratchWorkspaceAllocation { storage.allocation }
    public var thread: CodingThread { storage.thread }
    public var prompt: String? { storage.prompt }
    public var selectsConversation: Bool { storage.selectsConversation }
    public var modelEdits: [ThreadEdit] { storage.modelEdits }
    public init(allocation: ScratchWorkspaceAllocation, thread: CodingThread, prompt: String? = nil, selectsConversation: Bool = true, modelEdits: [ThreadEdit] = []) {
        storage = .init(allocation: allocation, thread: thread, prompt: prompt, selectsConversation: selectsConversation, modelEdits: modelEdits)
    }
    public init(from decoder: any Decoder) throws { storage = try Storage(from: decoder) }
    public func encode(to encoder: any Encoder) throws { try storage.encode(to: encoder) }
    public static func == (lhs: Self, rhs: Self) -> Bool {
        (try? ScratchWorkspaceService.bytes(lhs)) == (try? ScratchWorkspaceService.bytes(rhs))
    }
    func validate() throws {
        let thread = storage.thread, allocation = storage.allocation
        guard thread.scratchWorkspace == allocation.receipt,
              allocation.receipt.validates(thread: thread, project: allocation.project),
              thread.createdAt == allocation.receipt.createdAt, thread.providerThreadID == nil,
              thread.messages.isEmpty, thread.runHistory?.isEmpty ?? true, thread.queuedTurns.isEmpty,
              !thread.isBusy, !thread.isArchived, thread.runtimeID == nil, thread.runtimeRequests.isEmpty,
              thread.contextTransferLineage == nil, thread.contextProviderBindings == nil,
              thread.claudeResumeSelection == nil, thread.claudeResumeConsumerRunID == nil, thread.claudeInheritedHead == nil,
              thread.forkedFromHistoryOperationID == nil, thread.pullRequestCheckoutOperationID == nil,
              thread.providerMetadata == nil, thread.providerActivity == nil,
              thread.delegatedTaskLineage == nil, thread.settlement == nil, thread.draftWorkspaceIntent == nil,
              thread.draft.utf16.count <= 120_000, thread.draftAttachments.isEmpty,
              thread.effectiveCheckpointPolicy == .disabled else { throw ScratchWorkspaceError() }
        guard modelEdits.count <= 16 else { throw ScratchWorkspaceError() }
        for edit in modelEdits {
            switch edit {
            case .codexModel, .codexReasoning, .codexDefaultModel, .codexServiceTier,
                 .claudeModel, .claudeModelOptions: break
            default: throw ScratchWorkspaceError("A scratch launch can capture model choices, not arbitrary workspace or runtime edits.")
            }
        }
        if let prompt {
            guard !prompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, prompt.utf16.count <= 120_000,
                  thread.draft.isEmpty else { throw ScratchWorkspaceError("A scratch first input must be bounded and independent of an unsent draft.") }
        }
    }
}

public enum ScratchWorkspaceRecoveryPhase: String, Sendable { case prepared, uncertain, accepted, acceptedHistoryPending, rejected, cancelled, incomplete }
public struct ScratchWorkspaceRecovery: Sendable, Identifiable {
    public let id: UUID
    public let allocation: ScratchWorkspaceAllocation?
    public let phase: ScratchWorkspaceRecoveryPhase
    public let receipt: WorkspaceCommandReceipt?
    init(id: UUID, allocation: ScratchWorkspaceAllocation?, phase: ScratchWorkspaceRecoveryPhase, receipt: WorkspaceCommandReceipt? = nil) {
        self.id = id; self.allocation = allocation; self.phase = phase; self.receipt = receipt
    }
}
