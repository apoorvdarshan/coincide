import CoincideCore
import Foundation
import Observation

/// Automatic fetch and auto-pull preferences: a global default plus per-project overrides kept in
/// user defaults (no workspace journal changes).
struct SourceControlSyncPreferences: @unchecked Sendable {
    let defaults: UserDefaults
    init(defaults: UserDefaults = .standard) { self.defaults = defaults }
    var fetchInterval: GitAutomaticFetchInterval {
        get { defaults.object(forKey: SourceControlPreferenceKeys.fetchInterval) == nil ? .seconds30
              : GitAutomaticFetchInterval(rawValue: defaults.integer(forKey: SourceControlPreferenceKeys.fetchInterval)) ?? .seconds30 }
        nonmutating set { defaults.set(newValue.rawValue, forKey: SourceControlPreferenceKeys.fetchInterval) }
    }
    var autoPullDefault: Bool {
        get { defaults.bool(forKey: SourceControlPreferenceKeys.autoPullDefault) }
        nonmutating set { defaults.set(newValue, forKey: SourceControlPreferenceKeys.autoPullDefault) }
    }
    func override(for projectID: UUID) -> GitAutoPullOverride {
        let values = defaults.dictionary(forKey: SourceControlPreferenceKeys.autoPullOverrides) as? [String: String] ?? [:]
        return values[projectID.uuidString.lowercased()].flatMap(GitAutoPullOverride.init(rawValue:)) ?? .inherit
    }
    func setOverride(_ value: GitAutoPullOverride, for projectID: UUID) {
        var values = defaults.dictionary(forKey: SourceControlPreferenceKeys.autoPullOverrides) as? [String: String] ?? [:]
        if value == .inherit { values.removeValue(forKey: projectID.uuidString.lowercased()) } else { values[projectID.uuidString.lowercased()] = value.rawValue }
        defaults.set(values, forKey: SourceControlPreferenceKeys.autoPullOverrides)
    }
    func autoPullEnabled(projectID: UUID?) -> Bool { projectID.map { override(for: $0).resolve(default: autoPullDefault) } ?? autoPullDefault }
}

/// Keeps ahead/behind current by fetching the checkout someone is looking at, and fast-forwards a
/// clean default branch that is only behind (T3's auto-pull policy). Busy, held or dirty checkouts
/// are skipped; failures back off exponentially. Nothing runs outside the signed app unless started.
@MainActor @Observable
final class GitBackgroundSyncStore {
    struct Target: Hashable, Sendable { let path: String; let projectID: UUID? }
    struct Dependencies {
        var demandTargets: @MainActor () -> [Target]
        var launchTargets: @MainActor () -> [Target]
        var canSync: @MainActor (String) -> Bool
        var didChange: @MainActor (String) async -> Void
    }
    enum Result: Equatable {
        case skipped(String)
        case fetched(pulled: Bool, decision: GitSyncPolicy.PullDecision)
        case failed(String)
    }
    struct PathState: Equatable { var lastFetch: Date?; var lastPull: Date?; var failures = 0; var lastError: String? }

    static var isEnabledInThisProcess: Bool { Bundle.main.bundleIdentifier == "com.apoorvdarshan.coincide" }
    let preferences: SourceControlSyncPreferences
    private(set) var states: [String: PathState] = [:]
    private(set) var isRunning = false
    @ObservationIgnored private let dependencies: Dependencies
    @ObservationIgnored private var loop: Task<Void, Never>?
    @ObservationIgnored private var nextAllowed: [String: ContinuousClock.Instant] = [:]
    @ObservationIgnored private var inFlight: Set<String> = []
    @ObservationIgnored private var closed = false
    @ObservationIgnored private let networkTimeout: Duration

    init(dependencies: Dependencies, preferences: SourceControlSyncPreferences = .init(), networkTimeout: Duration = .seconds(60)) {
        self.dependencies = dependencies; self.preferences = preferences; self.networkTimeout = networkTimeout
    }

    func start() {
        guard loop == nil, !closed else { return }
        isRunning = true
        loop = Task { [weak self] in
            await self?.launchPass()
            while !Task.isCancelled {
                guard let self else { return }
                let interval = self.preferences.fetchInterval.duration ?? .seconds(30)
                try? await Task.sleep(for: interval)
                guard !Task.isCancelled, !self.closed else { return }
                await self.tick()
            }
        }
    }

    func shutdown() async {
        closed = true; isRunning = false
        let task = loop; loop = nil
        task?.cancel(); await task?.value
    }

    /// T3 pulls every auto-pull project once at startup.
    func launchPass() async {
        for target in dependencies.launchTargets() where preferences.autoPullEnabled(projectID: target.projectID) {
            guard !closed, !Task.isCancelled else { return }
            _ = await sync(target, fetch: preferences.fetchInterval != .off)
        }
    }

    func tick() async {
        let now = ContinuousClock.now
        for target in Set(dependencies.demandTargets()) {
            guard !closed, !Task.isCancelled else { return }
            if let allowed = nextAllowed[target.path], allowed > now { continue }
            _ = await sync(target, fetch: preferences.fetchInterval != .off)
        }
    }

    /// One fetch-then-maybe-pull pass for a checkout. Never fetches implicitly beyond the branch's
    /// configured upstream remote, never rebases, merges, stashes or discards.
    @discardableResult
    func sync(_ target: Target, fetch: Bool) async -> Result {
        let path = target.path
        guard !closed, !inFlight.contains(path) else { return .skipped("busy") }
        guard dependencies.canSync(path) else { return .skipped("busy") }
        inFlight.insert(path); defer { inFlight.remove(path) }
        let git = GitService(root: URL(fileURLWithPath: path), networkTimeout: networkTimeout)
        var state = states[path] ?? .init()
        do {
            let before = try await git.status()
            guard !before.isDetached, !before.isUnborn, let upstream = try await git.upstream(for: before.branch) else { return .skipped("no upstream") }
            if fetch, upstream.remote != "." {
                try await git.fetch(remote: upstream.remote)
                state.lastFetch = Date()
            }
            let current = try await git.status()
            let defaultBranch = try await git.defaultBranch(preferredRemote: upstream.remote)?.name
            let decision = GitSyncPolicy.pullDecision(.init(current), defaultBranch: defaultBranch, enabled: preferences.autoPullEnabled(projectID: target.projectID))
            var pulled = false
            // State can change during a network fetch; re-check ownership right before writing.
            if decision == .pull, !closed, dependencies.canSync(path) {
                try await git.pull(branch: current.branch)
                state.lastPull = Date(); pulled = true
            }
            state.failures = 0; state.lastError = nil; states[path] = state
            nextAllowed[path] = ContinuousClock.now + GitSyncPolicy.nextDelay(interval: preferences.fetchInterval.duration ?? .seconds(30), consecutiveFailures: 0) - .seconds(1)
            if fetch || pulled { await dependencies.didChange(path) }
            return .fetched(pulled: pulled, decision: decision)
        } catch is CancellationError {
            return .skipped("cancelled")
        } catch {
            state.failures += 1; state.lastError = error.localizedDescription; states[path] = state
            nextAllowed[path] = ContinuousClock.now + GitSyncPolicy.nextDelay(interval: preferences.fetchInterval.duration ?? .seconds(30), consecutiveFailures: state.failures)
            return .failed(error.localizedDescription)
        }
    }
}

extension GitBackgroundSyncStore {
    /// Demand follows what the person is looking at: the selected conversation's checkout and its project.
    convenience init(workspace: WorkspaceStore, preferences: SourceControlSyncPreferences = .init()) {
        self.init(dependencies: .init(
            demandTargets: { [weak workspace] in
                guard let workspace else { return [] }
                var targets: [Target] = []
                if let thread = workspace.selectedThread, workspace.workspaceReady(for: thread) {
                    targets.append(.init(path: GitBackgroundSyncStore.canonical(thread.workspacePath), projectID: thread.projectID))
                }
                if let project = workspace.selectedProject, project.clone.map({ $0.isReady }) ?? true {
                    targets.append(.init(path: GitBackgroundSyncStore.canonical(project.path), projectID: project.id))
                }
                return targets
            },
            launchTargets: { [weak workspace] in
                workspace?.snapshot.projects.filter { $0.clone.map { $0.isReady } ?? true }.map { .init(path: GitBackgroundSyncStore.canonical($0.path), projectID: $0.id) } ?? []
            },
            canSync: { [weak workspace] path in
                guard let workspace, !workspace.hasUnsavedFileEdits, workspace.canEditWorkspace(path) else { return false }
                return !workspace.snapshot.threads.contains { thread in
                    let other = GitBackgroundSyncStore.canonical(thread.workspacePath)
                    return (other == path || other.hasPrefix(path + "/") || path.hasPrefix(other + "/")) &&
                        (thread.isBusy || !thread.queuedTurns.isEmpty || !thread.runtimeRequests.isEmpty)
                }
            },
            didChange: { [weak workspace] path in await workspace?.gitInspector(path: path).refresh() }), preferences: preferences)
    }
    nonisolated static func canonical(_ path: String) -> String { URL(fileURLWithPath: path).standardizedFileURL.resolvingSymlinksInPath().path }
}

extension WorkspaceStore {
    /// Starts automatic fetch/pull once per store in the signed app; fixtures construct it directly.
    func startGitSyncIfEnabled() {
        guard gitSync == nil, GitBackgroundSyncStore.isEnabledInThisProcess else { return }
        // A token saved in Settings applies to gh children from launch; reading never prompts.
        SourceControlSettingsStore().loadSavedToken()
        let sync = GitBackgroundSyncStore(workspace: self)
        gitSync = sync; sync.start()
    }
}
