import CoincideCore
import CryptoKit
import Foundation
import Observation

/// One window's project commands. A retained row keeps the source it displayed;
/// replacing a registration never transfers that row to another checkout.
@MainActor @Observable
final class ProjectActionCommands {
    struct Source: Codable, Hashable {
        let projectID: UUID
        let projectCreatedAt: Date?
        let projectPath: Data
        let settingsKeys: [Data]
        let threadID: UUID
        let threadCreatedAt: Date
        let workspacePath: Data
        let preparationID: UUID?
        let configuration: Data
        let scriptID: String
        let scriptDigest: Data
        let isProjectAction: Bool

        @MainActor init?(store: WorkspaceStore, thread: CodingThread, entry: ResolvedProjectScript) {
            guard let project = store.snapshot.projects.first(where: { $0.id == thread.projectID }) else { return nil }
            let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
            guard let configuration = try? encoder.encode(ProviderConfiguration(thread: thread)),
                  let script = try? encoder.encode(entry.script) else { return nil }
            projectID = project.id; projectCreatedAt = project.createdAt; projectPath = Data(project.path.utf8)
            settingsKeys = ProjectSettingsKey.candidates(for: project).map { Data($0.utf8) }
            threadID = thread.id; threadCreatedAt = thread.createdAt; workspacePath = Data(thread.workspacePath.utf8)
            preparationID = thread.workspacePreparation?.id; self.configuration = configuration
            scriptID = entry.id; scriptDigest = entry.action?.digest ?? Data(SHA256.hash(data: script))
            isProjectAction = entry.action != nil
        }
        @MainActor func isCurrent(in store: WorkspaceStore) -> Bool {
            guard store.selectedThreadID == threadID, let thread = store.thread(threadID),
                  let project = store.snapshot.projects.first(where: { $0.id == projectID }),
                  thread.projectID == projectID, thread.createdAt == threadCreatedAt,
                  project.createdAt == projectCreatedAt, Data(project.path.utf8) == projectPath,
                  ProjectSettingsKey.candidates(for: project).map({ Data($0.utf8) }) == settingsKeys,
                  Data(thread.workspacePath.utf8) == workspacePath, thread.workspacePreparation?.id == preparationID else { return false }
            let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
            guard (try? encoder.encode(ProviderConfiguration(thread: thread))) == configuration else { return false }
            if isProjectAction {
                return store.projectSettings.document(for: project).actions?.first(where: { $0.id == scriptID })?.digest == scriptDigest
            }
            return true // Checkout scripts still go through the native review/load barrier.
        }
    }
    static func targetIsCurrent(store: WorkspaceStore, thread: CodingThread, project: WorkspaceProject) -> Bool {
        guard store.selectedThreadID == thread.id, let current = store.thread(thread.id),
              let currentProject = store.snapshot.projects.first(where: { $0.id == project.id }),
              current.createdAt == thread.createdAt, current.projectID == project.id,
              currentProject.createdAt == project.createdAt, Data(currentProject.path.utf8) == Data(project.path.utf8),
              ProjectSettingsKey.candidates(for: currentProject).map({ Data($0.utf8) }) == ProjectSettingsKey.candidates(for: project).map({ Data($0.utf8) }),
              Data(current.workspacePath.utf8) == Data(thread.workspacePath.utf8),
              current.workspacePreparation?.id == thread.workspacePreparation?.id else { return false }
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
        return (try? encoder.encode(ProviderConfiguration(thread: current))) == (try? encoder.encode(ProviderConfiguration(thread: thread)))
    }

    struct Binding {
        let source: Source
        let shortcut: ProjectActionShortcut?
        let isAllowed: @MainActor () -> Bool
        let invoke: @MainActor () async throws -> Void
        let report: @MainActor (any Error) -> Void
        var command: KeybindingCommand { .script(source.scriptID) }
    }
    private(set) var bindings: [Binding] = []
    private(set) var isRunning = false
    @ObservationIgnored private var owner: UUID?
    @ObservationIgnored private var jobs: [UUID: Task<Void, Never>] = [:]

    func replace(owner: UUID, bindings: [Binding]) { self.owner = owner; self.bindings = bindings }
    func unregister(owner: UUID) {
        guard self.owner == owner else { return }
        self.owner = nil; bindings = []
    }
    var defaults: [ResolvedKeybinding] {
        bindings.compactMap { binding in
            guard let shortcut = binding.shortcut else { return nil }
            var parts: [String] = []
            if shortcut.command { parts.append("meta") }
            if shortcut.control { parts.append("ctrl") }
            if shortcut.option { parts.append("alt") }
            if shortcut.shift { parts.append("shift") }
            parts.append(shortcut.key)
            return KeybindingRule(key: parts.joined(separator: "+"), command: binding.command).resolved
        }
    }
    func canPerform(_ command: KeybindingCommand) -> Bool {
        !isRunning && bindings.last(where: { $0.command == command })?.isAllowed() == true
    }
    @discardableResult func perform(_ command: KeybindingCommand, expected: Source? = nil) -> Bool {
        guard !isRunning, let binding = bindings.last(where: { $0.command == command }),
              expected.map({ $0 == binding.source }) ?? true, binding.isAllowed() else { return false }
        isRunning = true
        let id = UUID()
        jobs[id] = Task { [self] in
            defer { jobs.removeValue(forKey: id); isRunning = false }
            guard binding.isAllowed() else { return }
            do { try await binding.invoke() }
            catch is CancellationError { }
            catch { binding.report(error) }
        }
        return true
    }
    /// Removing a toolbar never cancels an already accepted launch.
    func drain() async { while !jobs.isEmpty { for task in Array(jobs.values) { await task.value }; await Task.yield() } }
}
