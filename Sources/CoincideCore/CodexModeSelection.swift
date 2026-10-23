import Foundation

/// A menu action owns the original conversation and full captured settings.
/// Flat Codable heap storage keeps runtime configurations off reducer stacks.
public struct CodexModeSelection: Codable, Sendable, Equatable {
    private final class Storage: Codable, Sendable {
        let threadID: UUID
        let birth: Date
        let projectID: UUID
        let workspacePath: String
        let configuration: ProviderConfiguration
        let mode: CodexInteractionMode
        let model: ProviderModel?
        init(thread: CodingThread, mode: CodexInteractionMode, model: ProviderModel?) {
            threadID = thread.id; birth = thread.createdAt; projectID = thread.projectID
            workspacePath = thread.workspacePath; configuration = .init(thread: thread); self.mode = mode; self.model = model
        }
    }
    private let storage: Storage
    public var threadID: UUID { storage.threadID }
    public var mode: CodexInteractionMode { storage.mode }
    public var model: ProviderModel? { storage.model }
    public init(thread: CodingThread, mode: CodexInteractionMode, model: ProviderModel? = nil) { storage = .init(thread: thread, mode: mode, model: model) }
    public init(from decoder: any Decoder) throws { storage = try Storage(from: decoder) }
    public func encode(to encoder: any Encoder) throws { try storage.encode(to: encoder) }
    public static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.storage.threadID == rhs.storage.threadID && lhs.storage.birth == rhs.storage.birth &&
        lhs.storage.projectID == rhs.storage.projectID && lhs.storage.workspacePath.utf8.elementsEqual(rhs.storage.workspacePath.utf8) &&
        lhs.storage.configuration.matchesModelControlCapture(rhs.storage.configuration) && lhs.mode == rhs.mode && lhs.model == rhs.model
    }
    public func matches(_ thread: CodingThread) -> Bool {
        thread.id == storage.threadID && thread.createdAt == storage.birth && thread.projectID == storage.projectID &&
        thread.workspacePath.utf8.elementsEqual(storage.workspacePath.utf8) && thread.provider == .codex &&
        ProviderConfiguration(thread: thread).matchesModelControlCapture(storage.configuration)
    }
    public static func isAvailable(for thread: CodingThread, model: ProviderModel? = nil) -> Bool {
        guard thread.provider == .codex, !thread.model.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return false }
        if let model { return model.id.utf8.elementsEqual(thread.model.utf8) && model.codexInteractionModes == [.default, .plan] }
        let metadata = thread.providerMetadata?["codexInteractionModes"] ?? .null
        return metadata["supported"] == .bool(true) && metadata["profile"] == .string("codex-0.163") &&
            metadata["modes"].array == [.string("default"), .string("plan")]
    }
    func apply(to thread: inout CodingThread) throws {
        guard matches(thread), Self.isAvailable(for: thread, model: storage.model), !thread.isArchived else {
            throw WorkspaceCommandError("This Codex conversation or its supported modes changed. Open the current mode menu again.")
        }
        // Permission/sandbox and the active run capture remain unchanged.
        thread.agentModeID = mode.rawValue
    }
}
