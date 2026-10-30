import AppKit
import CoincideKit
import Observation

/// The master settings in `instructions.json`, shared by every Instructions view.
final class InstructionSettingsStore {
    static let shared = InstructionSettingsStore(directory: AppStore.shared.directory)

    private let url: URL
    private(set) var settings: InstructionSettings

    init(directory: URL) {
        url = InstructionSettings.file(in: directory)
        settings = InstructionSettings.load(from: url)
    }

    func config(for scope: InstructionScope, locations: InstructionLocations) -> InstructionMasterConfig {
        switch scope {
        case .global: settings.global ?? .globalDefault(locations)
        case .project(let root): settings.projects[root.path] ?? .projectDefault(root)
        }
    }

    func update(_ config: InstructionMasterConfig, for scope: InstructionScope) throws {
        switch scope {
        case .global: settings.global = config
        case .project(let root): settings.projects[root.path] = config
        }
        try settings.save(to: url)
    }
}

/// A notice above the editor.
struct InstructionsNotice: Equatable {
    enum Kind { case info, warning, error }
    var kind: Kind
    var text: String
}

/// One project's or the global instruction files, the file open in the editor, and master mode.
@Observable
final class InstructionsModel {
    let scope: InstructionScope
    /// The project's name, or nil for the global files.
    let projectName: String?

    private(set) var files: [InstructionFile] = []
    private(set) var isLoading = false
    private(set) var selectedID: String?
    /// The editor's text.
    var text = ""
    private(set) var snapshot: InstructionSnapshot?
    /// The open file changed on disk since it was loaded.
    private(set) var changedOnDisk = false
    var notice: InstructionsNotice?
    private(set) var divergences: [InstructionDivergence] = []

    private(set) var locations = InstructionLocations(home: FileManager.default.homeDirectoryForCurrentUser)
    private(set) var config: InstructionMasterConfig
    private(set) var health: [MasterTargetStatus] = []
    /// Linking waiting for the user to review it.
    var plan: MasterPlan?
    var choices: [String: MasterChoice] = [:]
    /// A pair of drifted files to compare.
    var comparison: InstructionDivergence?
    var showingSync = false
    private(set) var isSyncing = false

    @ObservationIgnored private let store: InstructionSettingsStore
    @ObservationIgnored let syncer: InstructionCopySyncer
    @ObservationIgnored private var activationObserver: NSObjectProtocol?

    init(scope: InstructionScope, projectName: String? = nil, store: InstructionSettingsStore = .shared, syncer: InstructionCopySyncer = .shared) {
        self.scope = scope
        self.projectName = projectName
        self.store = store
        self.syncer = syncer
        config = store.config(for: scope, locations: InstructionLocations(home: FileManager.default.homeDirectoryForCurrentUser))
        activationObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.didBecomeActiveNotification, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.checkDisk()
                Task { await self?.reload() }
            }
        }
    }

    isolated deinit {
        if let activationObserver { NotificationCenter.default.removeObserver(activationObserver) }
    }

    var selected: InstructionFile? { files.first { $0.id == selectedID } }
    var isDirty: Bool { snapshot.map { $0.text != text } ?? false }
    var masterURL: URL { config.masterURL }
    var isMasterMode: Bool { config.isEnabled }
    var projectRoot: URL? { if case .project(let root) = scope { root } else { nil } }

    /// What the master is read by: every agent whose file links to it, plus its own readers.
    var masterReaders: [ProviderKind] {
        let readers = Set(health.filter { $0.state == .linked }.flatMap(\.target.readers))
            .union(files.filter { $0.resolvedURL == InstructionPaths.resolve(masterURL).url }.flatMap(\.readers))
        return ProviderKind.allCases.filter(readers.contains)
    }

    /// The files listed on their own: in master mode, the ones not linked to the master.
    var listedFiles: [InstructionFile] {
        guard isMasterMode else { return files }
        let master = InstructionPaths.resolve(masterURL).url
        return files.filter { $0.resolvedURL != master }
    }

    var linkedTargets: [MasterTargetStatus] { health.filter { $0.state == .linked } }
    var unhealthyTargets: [MasterTargetStatus] { health.filter(\.state.needsAttention) }

    func usedBy(_ file: InstructionFile) -> [ProviderKind] { InstructionDiscovery.usedBy(file, among: files) }

    // MARK: Loading

    /// Finds the files again, keeping the open one.
    func reload() async {
        isLoading = true
        defer { isLoading = false }
        let settings = AppStore.shared.settings
        let enabled = Set(ProviderKind.allCases.filter { settings.settings(for: $0).isEnabled })
        let locations = await Self.currentLocations()
        self.locations = locations
        config = store.config(for: scope, locations: locations)
        let scope = self.scope
        let config = self.config
        let found = await Task.detached {
            var files: [InstructionFile]
            switch scope {
            case .project(let root): files = InstructionDiscovery.projectFiles(in: root, enabled: enabled)
            case .global: files = InstructionDiscovery.globalFiles(locations, enabled: enabled)
            }
            if config.isEnabled, !files.contains(where: { $0.url.standardizedFileURL == config.masterURL.standardizedFileURL }) {
                let name = InstructionPaths.abbreviated(config.masterURL, home: locations.home)
                let display = switch scope {
                case .project(let root): InstructionDiscovery.relative(config.masterURL, to: root)
                case .global: name
                }
                files.insert(InstructionFile(url: config.masterURL, displayName: display, readers: []), at: 0)
            }
            let divergences: [InstructionDivergence] = if case .project(let root) = scope { InstructionDivergence.find(in: root) } else { [] }
            let health = config.isEnabled
                ? InstructionMaster.health(master: config.masterURL, targets: InstructionMaster.targets(for: scope, master: config.masterURL, locations: locations))
                : []
            return (files, divergences, health)
        }.value
        files = found.0
        divergences = found.1
        health = found.2
        if isMasterMode, selectedID == nil || !files.contains(where: { $0.id == selectedID }) {
            select(masterURL.path)
        } else if selectedID == nil || !files.contains(where: { $0.id == selectedID }) {
            if let first = files.first(where: \.exists) ?? files.first { select(first.id) }
        } else if let selected, snapshot == nil {
            load(selected)
        }
    }

    /// Where the agents keep their files on this Mac, with the user's shell and provider settings.
    static func currentLocations() async -> InstructionLocations {
        let settings = AppStore.shared.settings
        let environments = Dictionary(uniqueKeysWithValues: ProviderKind.allCases.map { ($0, settings.settings(for: $0).environment) })
        let accounts = ProviderKind.allCases.flatMap { settings.settings(for: $0).allAccounts(of: $0) }
        let environment = await ShellEnvironment.shared.environment()
        return InstructionLocations.standard(
            environment: environment, providerEnvironments: environments, accounts: accounts, dataDirectory: AppStore.shared.directory)
    }

    /// Opens a file in the editor. Unsaved edits to the open one are kept only if the user saves first; the view asks.
    func select(_ id: String) {
        guard let file = files.first(where: { $0.id == id }) else { return }
        selectedID = id
        load(file)
    }

    private func load(_ file: InstructionFile) {
        do {
            let snapshot = try InstructionFileStore.read(file.url)
            self.snapshot = snapshot
            text = snapshot.text
            changedOnDisk = false
            notice = nil
        } catch {
            snapshot = nil
            text = ""
            notice = InstructionsNotice(kind: .error, text: error.localizedDescription)
        }
    }

    /// Looks for a change made outside Coincide to the open file.
    func checkDisk() {
        guard let selected, let snapshot, !changedOnDisk else { return }
        if InstructionFileStore.hasChanged(selected.url, since: snapshot) { changedOnDisk = true }
    }

    // MARK: Editing

    func save() {
        guard let selected else { return }
        write(expecting: snapshot, file: selected)
    }

    /// Saves over a file that changed on disk, after the user chose their version.
    func saveOverExternalChanges() {
        guard let selected else { return }
        write(expecting: nil, file: selected)
    }

    private func write(expecting: InstructionSnapshot?, file: InstructionFile) {
        do {
            snapshot = try InstructionFileStore.write(text, to: file.url, expecting: expecting)
            changedOnDisk = false
            notice = nil
            afterSave(file)
            if !file.exists { Task { await reload() } }
        } catch InstructionFileError.changedOnDisk {
            changedOnDisk = true
        } catch {
            notice = InstructionsNotice(kind: .error, text: error.localizedDescription)
        }
    }

    /// Sends a saved master to its copies right away.
    private func afterSave(_ file: InstructionFile) {
        guard isMasterMode, config.iCloud != nil || config.git != nil,
            file.resolvedURL == InstructionPaths.resolve(masterURL).url
        else { return }
        syncer.sync()
    }

    func revert() {
        guard let selected else { return }
        load(selected)
    }

    // MARK: Helpers

    func createAgentsFile() {
        guard let root = projectRoot else { return }
        perform { try InstructionHelpers.createAgentsFile(in: root) }
        Task {
            await reload()
            select(root.appendingPathComponent("AGENTS.md").path)
        }
    }

    func link(_ name: String) {
        guard let root = projectRoot else { return }
        perform { try InstructionHelpers.link(name, in: root) }
        Task { await reload() }
    }

    /// Whether `name` can be linked to the project's `AGENTS.md`: that exists and nothing is at `name`.
    func canLink(_ name: String) -> Bool {
        guard let root = projectRoot, !isMasterMode else { return false }
        return InstructionPaths.isRegularFile(root.appendingPathComponent("AGENTS.md"))
            && !InstructionPaths.itemExists(root.appendingPathComponent(name))
    }

    var canCreateAgentsFile: Bool {
        guard let root = projectRoot else { return false }
        return !InstructionPaths.itemExists(root.appendingPathComponent("AGENTS.md"))
    }

    func reveal(_ file: InstructionFile) {
        if FileManager.default.fileExists(atPath: file.url.path) {
            NSWorkspace.shared.activateFileViewerSelecting([file.url])
        } else {
            NSWorkspace.shared.selectFile(nil, inFileViewerRootedAtPath: file.url.deletingLastPathComponent().path)
        }
    }

    /// Opens the file the path stands for in the preferred editor (`OpenTargets`), or the default app.
    func openInEditor(_ file: InstructionFile) {
        let url = file.resolvedURL
        let configuration = NSWorkspace.OpenConfiguration()
        configuration.activates = true
        Task {
            do {
                if let editor = OpenTargets.preferred, editor.kind == .editor {
                    _ = try await NSWorkspace.shared.open([url], withApplicationAt: editor.appURL, configuration: configuration)
                } else {
                    NSWorkspace.shared.open(url)
                }
            } catch {
                ThemedAlert(error: error).runModal()
            }
        }
    }

    private func perform(_ work: () throws -> Void) {
        do {
            try work()
        } catch {
            notice = InstructionsNotice(kind: .error, text: error.localizedDescription)
        }
    }

    // MARK: Master mode

    private var targets: [MasterTarget] { InstructionMaster.targets(for: scope, master: masterURL, locations: locations) }

    /// Checks the files and asks the user to review linking them.
    func reviewLinks() {
        let plan = InstructionMaster.plan(master: masterURL, targets: targets)
        choices = Dictionary(uniqueKeysWithValues: plan.statuses.map { ($0.id, plan.defaultChoice(for: $0)) })
        self.plan = plan
    }

    func setMasterPath(_ url: URL) {
        var updated = store.config(for: scope, locations: locations)
        updated.masterPath = url.path
        save(updated)
        Task { await reload() }
    }

    /// Links the files as reviewed and turns master mode on.
    func applyPlan() {
        guard let plan else { return }
        self.plan = nil
        do {
            let results = try InstructionMaster.apply(plan, choices: choices)
            var updated = store.config(for: scope, locations: locations)
            updated.isEnabled = true
            save(updated)
            notice = summary(of: results)
        } catch {
            notice = InstructionsNotice(kind: .error, text: error.localizedDescription)
        }
        snapshot = nil
        selectedID = nil
        Task { await reload() }
    }

    private func summary(of results: [MasterLinkResult]) -> InstructionsNotice {
        var lines: [String] = []
        for result in results {
            if let backup = result.backup {
                lines.append(String(localized: "\(result.target.displayName) was backed up to \(InstructionPaths.abbreviated(backup))."))
            }
            if let replaced = result.replacedLink {
                lines.append(String(localized: "\(result.target.displayName) linked to \(replaced) before."))
            }
            if case .failed(let reason) = result.outcome {
                lines.append(String(localized: "Couldn't link \(result.target.displayName): \(reason)"))
            }
        }
        let linked = results.filter { $0.outcome == .linked || $0.outcome == .alreadyLinked }.count
        lines.insert(String(localized: "Files linked to the master: \(linked)"), at: 0)
        let failed = results.contains { if case .failed = $0.outcome { true } else { false } }
        return InstructionsNotice(kind: failed ? .warning : .info, text: lines.joined(separator: "\n"))
    }

    /// Turns master mode off; with `replaceWithCopies` each link becomes a real copy of the master.
    func disableMasterMode(replaceWithCopies: Bool) {
        do {
            let replaced = try InstructionMaster.disable(master: masterURL, targets: targets, replaceWithCopies: replaceWithCopies)
            var updated = store.config(for: scope, locations: locations)
            updated.isEnabled = false
            // Sync belongs to master mode; the synced file stays where it is.
            if !updated.sync.isOff {
                updated.sync = .off
                if let local = updated.localMasterPath { updated.masterPath = local }
                updated.localMasterPath = nil
            }
            save(updated)
            notice = replaced.isEmpty
                ? nil
                : InstructionsNotice(kind: .info, text: String(localized: "Links replaced with copies of the master: \(replaced.count)"))
        } catch {
            notice = InstructionsNotice(kind: .error, text: error.localizedDescription)
        }
        Task { await reload() }
    }

    private func save(_ updated: InstructionMasterConfig) {
        do {
            try store.update(updated, for: scope)
            config = updated
        } catch {
            notice = InstructionsNotice(kind: .error, text: error.localizedDescription)
        }
    }

    // MARK: Sync

    /// The name of this master's copies in iCloud Drive and in a repository.
    var syncName: String { projectName ?? "Global" }

    var iCloudStatus: InstructionCopySyncer.Status? { syncer.status(scope, .iCloud) }
    var gitStatus: InstructionCopySyncer.Status? { syncer.status(scope, .git) }

    /// Changes this master's settings as they are saved now, so a sync that finished meanwhile isn't undone.
    private func modify(_ change: (inout InstructionMasterConfig) -> Void) {
        var updated = store.config(for: scope, locations: locations)
        change(&updated)
        save(updated)
    }

    /// Keeps a copy of the master in iCloud Drive › Coincide › Instructions. A copy already there from another Mac
    /// that differs is left for the user to choose between.
    func turnOnICloud(cloud: InstructionCloud = .standard) {
        guard cloud.isAvailable else {
            notice = InstructionsNotice(kind: .error, text: InstructionSyncError.iCloudUnavailable.localizedDescription)
            return
        }
        let copy = cloud.file(named: syncName)
        modify { $0.iCloud = InstructionICloudCopy(path: copy.path) }
        syncer.sync()
    }

    /// Stops updating the iCloud Drive copy. The copy stays there.
    func turnOffICloud() {
        modify { $0.iCloud = nil }
        syncer.clear(scope, .iCloud)
    }

    /// Keeps a copy of the master in the repository at `folder`, committed when it changes and pushed right away.
    func linkRepository(_ folder: URL) {
        isSyncing = true
        let name = syncName
        Task {
            defer { isSyncing = false }
            do {
                let repository = try await InstructionGitRepository.open(folder)
                let gitHubName = await repository.gitHubName()
                modify { $0.git = InstructionGitCopy(repository: folder.path, path: repository.file(named: name).path, gitHubName: gitHubName) }
                syncer.sync(pull: true)
            } catch {
                notice = InstructionsNotice(kind: .error, text: error.localizedDescription)
            }
        }
    }

    /// Creates a private GitHub repository holding a copy of the master, then keeps it in step. Only runs when the
    /// user clicks it.
    func createGitHubRepository(named name: String) {
        isSyncing = true
        let folder = AppStore.shared.directory.appendingPathComponent("instructions", isDirectory: true)
            .appendingPathComponent(InstructionCloud.safeName(name), isDirectory: true)
        let fileName = InstructionCloud.safeName(syncName) + ".md"
        let text = (try? InstructionFileStore.read(masterURL).text) ?? ""
        Task {
            defer { isSyncing = false }
            do {
                let repository = try await InstructionGitRepository.createOnGitHub(name: name, folder: folder, fileName: fileName, text: text)
                let gitHubName = await repository.gitHubName()
                modify {
                    $0.git = InstructionGitCopy(
                        repository: folder.path, path: repository.file(named: syncName).path, gitHubName: gitHubName,
                        agreed: InstructionCopySync.digest(text))
                }
                syncer.sync(pull: true)
            } catch {
                notice = InstructionsNotice(kind: .error, text: error.localizedDescription)
            }
        }
    }

    /// Stops updating the repository's copy. The repository stays as it is.
    func unlinkRepository() {
        modify { $0.git = nil }
        syncer.clear(scope, .git)
    }

    func setPushesAutomatically(_ on: Bool) {
        modify { $0.git?.pushesAutomatically = on }
        if on { syncer.sync(pull: true) }
    }

    /// Pulls and pushes every copy now.
    func syncNow() {
        syncer.sync(pull: true, push: true)
    }

    /// Ends a conflict between the master and a copy by giving both one side's text. The losing text is backed up.
    func resolve(_ copy: InstructionCopySyncer.Key.Copy, keeping side: InstructionCopySide) {
        let current = store.config(for: scope, locations: locations)
        let master = current.masterURL
        let copyURL: URL? = switch copy {
        case .iCloud: current.iCloud?.url
        case .git: current.git?.url
        }
        guard let copyURL else { return }
        do {
            let agreed = try InstructionCopySync.resolve(master: master, copy: copyURL, keeping: side, backUpCopy: copy == .iCloud)
            modify {
                switch copy {
                case .iCloud: $0.iCloud?.agreed = agreed
                case .git: $0.git?.agreed = agreed
                }
            }
            snapshot = nil
            Task { await reload() }
            syncer.sync(pull: true)
        } catch {
            notice = InstructionsNotice(kind: .error, text: error.localizedDescription)
        }
    }

    /// The text of the master and of a copy, for comparing them in a conflict.
    func conflictTexts(_ copy: InstructionCopySyncer.Key.Copy) -> (master: String, copy: String) {
        let url = switch copy {
        case .iCloud: config.iCloud?.url
        case .git: config.git?.url
        }
        let master = (try? InstructionFileStore.read(masterURL).text) ?? ""
        return (master, url.flatMap { try? InstructionFileStore.read($0).text } ?? "")
    }

    /// The repository's name: "owner/name" on GitHub, otherwise its folder.
    var repositoryDescription: String? {
        guard let git = config.git else { return nil }
        return git.gitHubName ?? InstructionPaths.abbreviated(git.repositoryURL)
    }

    /// The repository as a sync place: "GitHub owner/name", or "Git" and its folder.
    var repositoryTitle: String? {
        guard let git = config.git, let name = repositoryDescription else { return nil }
        return git.gitHubName == nil ? String(localized: "Git \(name)") : String(localized: "GitHub \(name)")
    }
}
