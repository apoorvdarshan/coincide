import CoincideCore
import Foundation
import Observation

/// An inventory belongs to one captured conversation/runtime, never the global
/// provider picker. Its metadata actor is independent of the running turn.
@MainActor @Observable
final class ProviderSkillsStore {
    struct Scope: Hashable {
        let threadID: UUID
        let projectID: UUID
        let workspacePath: String
        let configuration: CodexRuntimeConfiguration
        init(_ thread: CodingThread) {
            threadID = thread.id; projectID = thread.projectID; workspacePath = thread.workspacePath
            configuration = thread.codexRuntimeConfiguration ?? .init()
        }
        func matches(_ thread: CodingThread) -> Bool { thread.provider == .codex && self == Scope(thread) }
    }
    let id: UUID
    let scope: Scope
    private(set) var inventory: ProviderSkillInventory?
    private(set) var isLoading = false
    private(set) var errorMessage: String?
    private(set) var isClosed = false
    @ObservationIgnored private let read: @Sendable (Bool) async throws -> ProviderSkillInventory
    @ObservationIgnored private let isCurrent: @MainActor () -> Bool
    @ObservationIgnored private var reads: [UUID: Task<ProviderSkillInventory, any Error>] = [:]
    @ObservationIgnored private var currentRead: UUID?
    init(id: UUID = UUID(), scope: Scope,
         read: @escaping @Sendable (Bool) async throws -> ProviderSkillInventory,
         isCurrent: @escaping @MainActor () -> Bool = { true }) {
        self.id = id; self.scope = scope; self.read = read; self.isCurrent = isCurrent
    }
    var skills: [ProviderSkill] {
        var names = Set<String>()
        return (inventory?.skills ?? []).filter {
            $0.canInvokeFromComposer && names.insert($0.name.lowercased()).inserted
        }
    }
    func refresh(forceReload: Bool = false) async {
        guard !isClosed, isCurrent() else { return }
        if let currentRead, let existing = reads[currentRead], !forceReload { _ = await existing.result; return }
        if inventory != nil && !forceReload { return }
        // A forced refresh supersedes publication immediately, while every old
        // cancellation-resistant read stays owned until shutdown joins it.
        for task in reads.values { task.cancel() }
        if forceReload { inventory = nil }
        let id = UUID(), read = read
        let task = Task { try await read(forceReload) }
        reads[id] = task; currentRead = id; isLoading = true; errorMessage = nil
        defer {
            reads.removeValue(forKey: id)
            if currentRead == id { currentRead = nil; isLoading = false }
        }
        do {
            let value = try await task.value
            guard !task.isCancelled, !isClosed, currentRead == id, isCurrent(), value.cwd == scope.workspacePath else { return }
            try value.validate()
            inventory = value
        } catch is CancellationError { }
        catch {
            guard !isClosed, currentRead == id, isCurrent() else { return }
            // Provider payloads and filesystem errors may contain private data.
            errorMessage = (error as? ProviderSkillError)?.localizedDescription ?? String(localized: "Skills could not be loaded. Try refreshing this workspace.")
        }
    }
    func cancel() {
        isClosed = true; inventory = nil; errorMessage = nil; isLoading = false; currentRead = nil
        for task in reads.values { task.cancel() }
    }
    func shutdown() async {
        cancel()
        let owned = Array(reads.values)
        for task in owned { _ = await task.result }
        reads.removeAll()
    }
}
