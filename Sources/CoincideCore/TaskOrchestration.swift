import CryptoKit
import Foundation

/// App-owned delegation is separate from provider-native tools and from ordinary
/// top-level conversation creation. A child receives only its captured brief.
public enum DelegatedTaskRole: String, Codable, Sendable, CaseIterable { case implementation, research, review, design, test, general }
public enum DelegatedTaskIsolation: String, Codable, Sendable { case shared, worktree }
public enum DelegatedTaskMode: String, Codable, Sendable { case `async`, wait }
public enum DelegatedTaskStatus: String, Codable, Sendable {
    case queued, running, waiting, completed, failed, cancelled, interrupted
    public var isTerminal: Bool { [.completed, .failed, .cancelled, .interrupted].contains(self) }
}
public enum DelegatedTaskWorkState: String, Codable, Sendable { case working, waitingForChildren, resultAvailable }
public enum DelegatedTaskWakePolicy: String, Codable, Sendable { case always, settledOnly }
public enum DelegatedTaskDeliveryState: String, Codable, Sendable { case pending, claimed, acknowledged, delivered, disposed, uncertain }
public struct DelegatedTaskLineage: Codable, Sendable, Equatable {
    private struct Payload: Codable, Sendable, Equatable {
        let taskID: UUID
        let parentThreadID: UUID
        let parentRunID: UUID
        let rootThreadID: UUID
    }
    private var storage: [Payload]
    public var taskID: UUID { storage[0].taskID }
    public var parentThreadID: UUID { storage[0].parentThreadID }
    public var parentRunID: UUID { storage[0].parentRunID }
    public var rootThreadID: UUID { storage[0].rootThreadID }
    public init(taskID: UUID, parentThreadID: UUID, parentRunID: UUID, rootThreadID: UUID) {
        storage = [.init(taskID: taskID, parentThreadID: parentThreadID, parentRunID: parentRunID, rootThreadID: rootThreadID)]
    }
    public init(from decoder: any Decoder) throws { storage = [try Payload(from: decoder)] }
    public func encode(to encoder: any Encoder) throws { try storage[0].encode(to: encoder) }
}
public struct DelegatedTaskRequest: Codable, Sendable, Equatable {
    // Several captured provider configurations must not inflate every task,
    // command switch and nested native reducer frame. Array storage keeps flat
    // Codable and immutable value equality without shared mutable proof.
    private struct Payload: Codable, Sendable, Equatable {
        let parentThreadID: UUID
        let parentRunID: UUID
        let expectedConfiguration: ProviderConfiguration
        let configuration: ProviderConfiguration
        let configurationSourceThreadID: UUID?
        let expectedConfigurationSource: ProviderConfiguration?
        let task: String
        let title: String?
        let role: DelegatedTaskRole
        let isolation: DelegatedTaskIsolation
        let mode: DelegatedTaskMode
        let clientRequestID: String?
        let appMCPRequestDigest: String?
    }
    private var storage: [Payload]
    public var parentThreadID: UUID { storage[0].parentThreadID }
    public var parentRunID: UUID { storage[0].parentRunID }
    public var expectedConfiguration: ProviderConfiguration { storage[0].expectedConfiguration }
    public var configuration: ProviderConfiguration { storage[0].configuration }
    public var configurationSourceThreadID: UUID? { storage[0].configurationSourceThreadID }
    public var expectedConfigurationSource: ProviderConfiguration? { storage[0].expectedConfigurationSource }
    public var task: String { storage[0].task }
    public var title: String? { storage[0].title }
    public var role: DelegatedTaskRole { storage[0].role }
    public var isolation: DelegatedTaskIsolation { storage[0].isolation }
    public var mode: DelegatedTaskMode { storage[0].mode }
    public var clientRequestID: String? { storage[0].clientRequestID }
    public var appMCPRequestDigest: String? { storage[0].appMCPRequestDigest }
    public init(parentThreadID: UUID, parentRunID: UUID, expectedConfiguration: ProviderConfiguration,
                configuration: ProviderConfiguration, task: String, title: String? = nil,
                role: DelegatedTaskRole = .general, isolation: DelegatedTaskIsolation = .shared,
                mode: DelegatedTaskMode = .async, clientRequestID: String? = nil,
                configurationSourceThreadID: UUID? = nil, expectedConfigurationSource: ProviderConfiguration? = nil, appMCPRequestDigest: String? = nil) {
        storage = [.init(parentThreadID: parentThreadID, parentRunID: parentRunID, expectedConfiguration: expectedConfiguration,
            configuration: configuration, configurationSourceThreadID: configurationSourceThreadID, expectedConfigurationSource: expectedConfigurationSource,
            task: task, title: title, role: role, isolation: isolation, mode: mode, clientRequestID: clientRequestID, appMCPRequestDigest: appMCPRequestDigest)]
    }
    public init(from decoder: any Decoder) throws { storage = [try Payload(from: decoder)] }
    public func encode(to encoder: any Encoder) throws { try storage[0].encode(to: encoder) }
    public var prompt: String { role == .general ? task : "Act as the \(role.rawValue) sub-agent for this task.\n\n\(task)" }
}
public struct DelegatedTaskResult: Codable, Sendable, Equatable {
    public let runID: UUID
    public let status: DelegatedTaskStatus
    public let summary: String
    public let digest: String
    public let contextTransferID: UUID
    public let createdAt: Date
    public var truncated: Bool? = nil
}
public struct DelegatedTaskCompletion: Codable, Sendable, Equatable {
    public var state: DelegatedTaskDeliveryState
    public var observedByRunID: UUID?
    public var cohortID: UUID?
    public init(state: DelegatedTaskDeliveryState = .pending, observedByRunID: UUID? = nil, cohortID: UUID? = nil) {
        self.state = state; self.observedByRunID = observedByRunID; self.cohortID = cohortID
    }
}
public struct DelegatedTask: Codable, Sendable, Equatable, Identifiable {
    public let id: UUID
    public let commandID: UUID
    public let parentThreadID: UUID
    public let parentRunID: UUID
    public let childThreadID: UUID
    public let childRunID: UUID
    public let parentTaskID: UUID?
    public let request: DelegatedTaskRequest
    public let createdAt: Date
    public var updatedAt: Date
    public var status: DelegatedTaskStatus
    public var workState: DelegatedTaskWorkState
    public var result: DelegatedTaskResult?
    public var latestTerminalResult: DelegatedTaskResult?
    public var wakePolicy: DelegatedTaskWakePolicy
    public var completion: DelegatedTaskCompletion
    public var cancelRequestedAt: Date?
    public var completedAt: Date?
    public var isolationProof: TaskIsolationProof? = nil
    public var isFollowup: Bool?
}
public struct DelegatedTaskCompletionReference: Codable, Sendable, Equatable {
    private struct Payload: Codable, Sendable, Equatable {
        let cohortID: UUID
        let parentRunID: UUID
        let generation: Int
        let taskIDs: [UUID]
    }
    private var storage: [Payload]
    public var cohortID: UUID { storage[0].cohortID }
    public var parentRunID: UUID { storage[0].parentRunID }
    public var generation: Int { storage[0].generation }
    public var taskIDs: [UUID] { storage[0].taskIDs }
    public init(cohortID: UUID, parentRunID: UUID, generation: Int, taskIDs: [UUID]) {
        storage = [.init(cohortID: cohortID, parentRunID: parentRunID, generation: generation, taskIDs: taskIDs)]
    }
    public init(from decoder: any Decoder) throws { storage = [try Payload(from: decoder)] }
    public func encode(to encoder: any Encoder) throws { try storage[0].encode(to: encoder) }
}
public enum DelegatedTaskCohortDisposition: String, Codable, Sendable { case open, stopped, disposed }
public struct DelegatedTaskCohort: Codable, Sendable, Equatable, Identifiable {
    public let id: UUID
    public let threadID: UUID
    public let parentRunID: UUID
    public let generation: Int
    public var disposition: DelegatedTaskCohortDisposition
    public var taskIDs: [UUID]
    public var state: DelegatedTaskDeliveryState
    public let inputID: UUID
    public let createdAt: Date
    public var steeringOperationID: UUID?
    public var observedByRunID: UUID?
    public var updatedAt: Date
}
public struct DelegatedTaskStatusSnapshot: Sendable, Equatable {
    public let task: DelegatedTask
    public let hasPendingChildRuns: Bool
    public let pendingQuestions: [RuntimeRequest]
    public let pendingApproval: RuntimeRequest?
    public let pendingApprovalRunID: UUID?
    public let waitTimedOut: Bool
    public init(task: DelegatedTask, hasPendingChildRuns: Bool, pendingQuestions: [RuntimeRequest], pendingApproval: RuntimeRequest?, waitTimedOut: Bool = false, pendingApprovalRunID: UUID? = nil) {
        self.task = task; self.hasPendingChildRuns = hasPendingChildRuns; self.pendingQuestions = pendingQuestions
        self.pendingApproval = pendingApproval; self.waitTimedOut = waitTimedOut; self.pendingApprovalRunID = pendingApprovalRunID
    }
}
public enum DelegatedTaskError: Error, LocalizedError, Sendable, Equatable {
    case invalidRequest, staleParent, permissionDenied, notFound, limit, unavailable
    public var errorDescription: String? {
        switch self {
        case .invalidRequest: "The delegated task request is invalid."
        case .staleParent: "The parent no longer owns this exact active run."
        case .permissionDenied: "The delegated work requires broader permissions than its parent."
        case .notFound: "This delegated task does not belong to the selected parent."
        case .limit: "The delegated task or task tree exceeds its bounded capacity."
        case .unavailable: "This delegated task cannot run while its workspace or provider is held."
        }
    }
}
public enum TaskOrchestration {
    public static let maximumTasks = 4_096
    public static let maximumActiveTasks = 64
    public static let maximumDepth = 8
    public static let maximumCohortTasks = 64
    public static let maximumResultBytes = 4 * 1_024 * 1_024
    public static let maximumLedgerBytes = 128 * 1_024 * 1_024
    public static let defaultWaitMilliseconds = 600_000
    public static let maximumWaitMilliseconds = 3_600_000
    public static func derivedID(_ commandID: UUID, _ label: String) -> UUID {
        let digest = Array(SHA256.hash(data: Data((commandID.uuidString + ":" + label).utf8)))
        var bytes = Array(digest.prefix(16)); bytes[6] = (bytes[6] & 0x0f) | 0x50; bytes[8] = (bytes[8] & 0x3f) | 0x80
        return UUID(uuid: (bytes[0],bytes[1],bytes[2],bytes[3],bytes[4],bytes[5],bytes[6],bytes[7],bytes[8],bytes[9],bytes[10],bytes[11],bytes[12],bytes[13],bytes[14],bytes[15]))
    }
}

public struct DelegatedTaskAcceptance: Sendable, Equatable {
    public let taskID: UUID
    public let childThreadID: UUID
    public let childRunID: UUID
    public let receipt: WorkspaceCommandReceipt
}

/// Captured native-only preparation. Clients never supply a child, worktree
/// request, ownership identity or provider executable through an MCP argument.
struct DelegatedTaskPreparation: Codable, Sendable {
    private struct Payload: Codable, Sendable {
        let request: DelegatedTaskRequest
        let child: CodingThread
        let parentIncarnation: UUID
        let parentRuntimeID: UUID
        let isolation: TaskIsolationProof?
        let worktree: GitWorktreeRequest?
    }
    private var storage: [Payload]
    var request: DelegatedTaskRequest { storage[0].request }
    var child: CodingThread { storage[0].child }
    var parentIncarnation: UUID { storage[0].parentIncarnation }
    var parentRuntimeID: UUID { storage[0].parentRuntimeID }
    var isolation: TaskIsolationProof? { storage[0].isolation }
    var worktree: GitWorktreeRequest? { storage[0].worktree }
    init(request: DelegatedTaskRequest, child: CodingThread, parentIncarnation: UUID, parentRuntimeID: UUID,
         isolation: TaskIsolationProof?, worktree: GitWorktreeRequest?) {
        storage = [.init(request: request, child: child, parentIncarnation: parentIncarnation, parentRuntimeID: parentRuntimeID, isolation: isolation, worktree: worktree)]
    }
    init(from decoder: any Decoder) throws { storage = [try Payload(from: decoder)] }
    func encode(to encoder: any Encoder) throws { try storage[0].encode(to: encoder) }
}

struct DelegatedTaskDrainOwner: Codable, Sendable { let threadID: UUID; let runID: UUID; let runtimeID: UUID? }

public enum DelegatedTaskTransferKind: String, Codable, Sendable { case subagentSpawn, subagentResult }
/// Consumed provenance, not copied provider input or a native history proof.
/// Results are retrieved through their owning task, never an arbitrary thread.
public struct DelegatedTaskResultTransfer: Codable, Sendable, Equatable, Identifiable {
    public let id: UUID
    public let taskID: UUID
    public let kind: DelegatedTaskTransferKind
    public let sourceThreadID: UUID
    public let sourceRunID: UUID
    public let sourceMessageID: String?
    public let targetThreadID: UUID
    public let targetRunID: UUID
    public let sourceProviderInstanceID: UUID
    public let targetProviderInstanceID: UUID
    public let createdAt: Date
    public let consumedAt: Date
    /// An oversized source identity is represented by its exact digest.
    public var sourceMessageIDDigest: String? = nil
}
