import AppKit
import CoincideKit
import Observation

/// Keeps every master's iCloud Drive and Git copies in step with it: at launch, when Coincide comes forward, every
/// minute, and right after the master is saved in Coincide. Repositories are pulled at most every five minutes unless
/// something changed here. Settings from an older Coincide, which moved the master to sync it, are brought forward
/// first (`InstructionCopyMigration`).
@MainActor
@Observable
final class InstructionCopySyncer {
    static let shared = InstructionCopySyncer()

    /// How a copy stood after its last sync.
    enum Status: Equatable {
        case inStep
        /// The master and the copy both changed; the user picks one in Sync.
        case conflict
        case downloading
        case failed(String)

        var needsAttention: Bool { self != .inStep }
    }

    struct Key: Hashable {
        enum Copy: Hashable { case iCloud, git }
        var scope: InstructionScope
        var copy: Copy
    }

    /// Set by each sync; tests set it to show a state.
    var statuses: [Key: Status] = [:]
    private(set) var isRunning = false
    /// Goes up whenever a sync changed a master or its settings, so open Instructions views reload.
    private(set) var revision = 0

    @ObservationIgnored private let store: InstructionSettingsStore
    @ObservationIgnored private var timer: Timer?
    @ObservationIgnored private var activationObserver: NSObjectProtocol?
    @ObservationIgnored private var lastPull: [InstructionScope: Date] = [:]
    @ObservationIgnored private var queued: (pull: Bool, push: Bool)?

    init(store: InstructionSettingsStore = .shared) {
        self.store = store
    }

    func start() {
        guard timer == nil else { return }
        timer = Timer.scheduledTimer(withTimeInterval: 60, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.sync() }
        }
        activationObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.didBecomeActiveNotification, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.sync(pull: true) }
        }
        sync(pull: true)
    }

    func status(_ scope: InstructionScope, _ copy: Key.Copy) -> Status? { statuses[Key(scope: scope, copy: copy)] }

    /// Syncs every master that has copies. `pull` pulls repositories even when nothing changed here; `push` pushes
    /// even copies that only push on Sync Now. A request made while a sync runs waits for it.
    func sync(pull: Bool = false, push: Bool = false) {
        guard !isRunning else {
            queued = (pull || queued?.pull == true, push || queued?.push == true)
            return
        }
        isRunning = true
        Task {
            await run(pull: pull, push: push)
            isRunning = false
            if let next = queued {
                queued = nil
                sync(pull: next.pull, push: next.push)
            }
        }
    }

    /// Forgets a copy's status after its sync was turned off.
    func clear(_ scope: InstructionScope, _ copy: Key.Copy) {
        statuses[Key(scope: scope, copy: copy)] = nil
    }

    private func run(pull: Bool, push: Bool) async {
        var scopes: [InstructionScope] = []
        if store.settings.global != nil { scopes.append(.global) }
        scopes += store.settings.projects.keys.sorted().map { .project(URL(fileURLWithPath: $0)) }
        guard scopes.contains(where: { hasCopies(store.settings.config(for: $0)) }) else { return }
        let locations = await InstructionsModel.currentLocations()
        for scope in scopes {
            guard var config = store.settings.config(for: scope), config.isEnabled, hasCopies(config) else { continue }
            if InstructionCopyMigration.needsMigration(config) {
                guard let migrated = await migrate(config, scope: scope, locations: locations) else { continue }
                config = migrated
            }
            if let copy = config.iCloud { await syncICloud(copy, master: config.masterURL, scope: scope) }
            if let copy = config.git { await syncGit(copy, master: config.masterURL, scope: scope, pull: pull, push: push) }
        }
    }

    private func hasCopies(_ config: InstructionMasterConfig?) -> Bool {
        guard let config else { return false }
        return config.iCloud != nil || config.git != nil || InstructionCopyMigration.needsMigration(config)
    }

    private func migrate(_ config: InstructionMasterConfig, scope: InstructionScope, locations: InstructionLocations) async -> InstructionMasterConfig? {
        let targets = InstructionMaster.targets(for: scope, master: config.masterURL, locations: locations)
        let local = switch scope {
        case .global: locations.defaultGlobalMaster
        case .project(let root): root.appendingPathComponent("AGENTS.md")
        }
        let copy: Key.Copy = if case .git = config.sync { .git } else { .iCloud }
        do {
            var migrated = try await Task.detached { try InstructionCopyMigration.migrate(config, local: local, targets: targets) }.value
            if var git = migrated.git, git.gitHubName == nil {
                git.gitHubName = await InstructionGitRepository(url: git.repositoryURL).gitHubName()
                migrated.git = git
            }
            try store.update(migrated, for: scope)
            revision += 1
            return migrated
        } catch {
            statuses[Key(scope: scope, copy: copy)] = .failed(error.localizedDescription)
            return nil
        }
    }

    private func syncICloud(_ copy: InstructionICloudCopy, master: URL, scope: InstructionScope) async {
        let key = Key(scope: scope, copy: .iCloud)
        do {
            let result = try await Task.detached { try InstructionCopySync.sync(master: master, iCloudCopy: copy.url, agreed: copy.agreed) }.value
            record(result, key: key) { config in
                guard config.iCloud?.path == copy.path else { return false }
                config.iCloud?.agreed = result.agreed
                return true
            }
        } catch {
            statuses[key] = .failed(error.localizedDescription)
        }
    }

    private func syncGit(_ copy: InstructionGitCopy, master: URL, scope: InstructionScope, pull: Bool, push: Bool) async {
        let key = Key(scope: scope, copy: .git)
        let due = pull || push || statuses[key] != .inStep || lastPull[scope].map { Date().timeIntervalSince($0) > 300 } ?? true
        if !due {
            // Nothing to pull yet; only a change here needs the repository.
            let unchanged = await Task.detached {
                let master = try? InstructionCopySync.text(of: master)
                let copy = try? InstructionCopySync.text(of: copy.url)
                return master != nil && master == copy
            }.value
            if unchanged { return }
        }
        let allowed = allowedFiles(in: copy.repositoryURL)
        do {
            let result = try await InstructionCopySync.sync(master: master, gitCopy: copy, allowedFiles: allowed, push: push || copy.pushesAutomatically)
            lastPull[scope] = Date()
            // A remote added after linking still gets its GitHub name shown.
            let gitHubName = copy.gitHubName == nil ? await InstructionGitRepository(url: copy.repositoryURL).gitHubName() : copy.gitHubName
            record(result, key: key) { config in
                guard config.git?.repository == copy.repository, config.git?.path == copy.path else { return false }
                config.git?.agreed = result.agreed
                config.git?.gitHubName = gitHubName
                return true
            }
        } catch {
            statuses[key] = .failed(error.localizedDescription)
        }
    }

    /// Saves what the copy and the master agree on now, unless the user changed that copy's sync meanwhile.
    private func record(_ result: InstructionCopyResult, key: Key, update: (inout InstructionMasterConfig) -> Bool) {
        statuses[key] = switch result.outcome {
        case .inStep, .updatedCopy, .updatedMaster: .inStep
        case .conflict: .conflict
        case .downloading: .downloading
        }
        if let saved = store.settings.config(for: key.scope) {
            var config = saved
            if update(&config), config != saved { try? store.update(config, for: key.scope) }
        }
        if result.outcome == .updatedMaster { revision += 1 }
    }

    /// The copies in the repository at `url`, as paths in it: the only files Coincide may push there.
    private func allowedFiles(in url: URL) -> [String] {
        let root = InstructionPaths.canonical(url)
        let configs = [store.settings.global].compactMap(\.self) + Array(store.settings.projects.values)
        return configs.compactMap { config in
            guard let git = config.git, InstructionPaths.canonical(git.repositoryURL) == root else { return nil }
            return InstructionDiscovery.relative(InstructionPaths.canonical(git.url), to: root)
        }
    }
}

extension InstructionSettings {
    func config(for scope: InstructionScope) -> InstructionMasterConfig? {
        switch scope {
        case .global: global
        case .project(let root): projects[root.path]
        }
    }
}
