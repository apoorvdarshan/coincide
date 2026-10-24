import AppKit
import CoincideCore
import Foundation
import Observation

enum ProjectIconPresentation: Equatable {
    case image(NSImage)
    case symbol(name: String, color: ProjectIconColor)
    case emoji(String)
    case monogram(text: String, color: ProjectIconColor)
}

/// App-owned project settings: actions, defaults and icon overrides in private per-project files,
/// with small device preferences (last-run action, app-wide defaults) in UserDefaults.
/// Reads and writes run off the main actor; writes are serialized and re-read the latest file first.
@MainActor @Observable
final class ProjectSettingsStore {
    typealias Reader = @Sendable (URL, [String]) throws -> (key: String, document: ProjectSettingsDocument)?
    typealias Writer = @Sendable (ProjectSettingsDocument, URL) throws -> Void
    let root: URL
    private(set) var documents: [String: ProjectSettingsDocument] = [:]
    private(set) var loadErrors: [String: String] = [:]
    private(set) var revision = 0
    /// Exact checkout bytes; `.some(nil)` records that no image was found.
    private(set) var detectedIcons: [Data: NSImage?] = [:]
    private(set) var iconEpoch = 0
    @ObservationIgnored private let defaults: UserDefaults
    @ObservationIgnored private let reader: Reader
    @ObservationIgnored private let writer: Writer
    @ObservationIgnored private let nativeStorage: Bool
    @ObservationIgnored private var captures: [String: ProjectSettingsCapture] = [:]
    @ObservationIgnored private var epochs: [String: UUID] = [:]
    @ObservationIgnored private var closed = false
    private nonisolated static let injectedLock = NSLock()
    @ObservationIgnored private var loads: [String: Task<ProjectSettingsDocument, Never>] = [:]
    @ObservationIgnored private var writeTail: Task<Void, Never>?
    @ObservationIgnored private var iconReads: [Data: Task<Void, Never>] = [:]
    @ObservationIgnored private var iconJobs: [UUID: Task<Void, Never>] = [:]
    @ObservationIgnored private var iconOwners: [Data: UUID] = [:]
    @ObservationIgnored private var iconScopes: [Data: ProjectSettingsPresentationScope] = [:]
    private static let lastInvokedKey = "projectActions.lastInvoked"
    private static let appEnvironmentKey = "projectDefaults.threadEnvironmentMode"
    private static let originKey = "newWorktreesStartFromOrigin"
    private static let appSubmodulesKey = "projectDefaults.worktreeSubmodules"

    init(root: URL, defaults: UserDefaults = .standard,
         reader: Reader? = nil, writer: Writer? = nil) {
        self.root = root; self.defaults = defaults; self.reader = reader ?? Self.readDefault; self.writer = writer ?? Self.writeDefault
        nativeStorage = reader == nil && writer == nil
        newWorktreesStartFromOrigin = defaults.object(forKey: Self.originKey) as? Bool ?? true
        appThreadEnvironmentMode = defaults.string(forKey: Self.appEnvironmentKey).flatMap(ProjectThreadEnvironmentMode.init(rawValue:))
        appWorktreeSubmodules = defaults.string(forKey: Self.appSubmodulesKey).flatMap(ProjectWorktreeSubmoduleMode.init(rawValue:))
    }

    var newWorktreesStartFromOrigin: Bool { didSet { defaults.set(newWorktreesStartFromOrigin, forKey: Self.originKey) } }

    /// App-wide defaults; nil is Inherit (t3.json, then T3's built-in value).
    var appThreadEnvironmentMode: ProjectThreadEnvironmentMode? {
        didSet { defaults.set(appThreadEnvironmentMode?.rawValue, forKey: Self.appEnvironmentKey) }
    }
    var appWorktreeSubmodules: ProjectWorktreeSubmoduleMode? {
        didSet { defaults.set(appWorktreeSubmodules?.rawValue, forKey: Self.appSubmodulesKey) }
    }

    func key(for project: WorkspaceProject) -> String { ProjectSettingsKey.primary(for: project) }
    /// The cached document, or an empty one while the first read is pending.
    func document(for project: WorkspaceProject) -> ProjectSettingsDocument {
        documents[key(for: project)] ?? .init(key: key(for: project))
    }
    func isLoaded(_ project: WorkspaceProject) -> Bool { documents[key(for: project)] != nil }
    private nonisolated static func readDefault(_ root: URL, _ keys: [String]) throws -> (key: String, document: ProjectSettingsDocument)? {
        try ProjectSettingsFiles.load(root: root, keys: keys)
    }
    private nonisolated static func writeDefault(_ value: ProjectSettingsDocument, _ root: URL) throws {
        try ProjectSettingsFiles.save(value, root: root)
    }
    /// Capture this when an editor opens or a reorder row renders. It remains
    /// pinned even if the shared store later refreshes for another window.
    func capture(for project: WorkspaceProject) -> ProjectSettingsCapture? { let _ = revision; return captures[key(for: project)] }

    private struct Loaded: Sendable { let document: ProjectSettingsDocument; let capture: ProjectSettingsCapture? }
    @discardableResult func load(_ project: WorkspaceProject, force: Bool = false) async -> ProjectSettingsDocument {
        let primary = key(for: project), keys = ProjectSettingsKey.candidates(for: project)
        guard !closed else { return document(for: project) }
        if !force, let cached = documents[primary] { return cached }
        if let pending = loads[primary] { return await pending.value }
        let root = root, reader = reader, native = nativeStorage, epoch = UUID(), previous = writeTail
        epochs[primary] = epoch
        let task = Task<ProjectSettingsDocument, Never> { [weak self] in
            await previous?.value
            let worker = Task.detached { () -> Result<Loaded, any Error> in
                Result {
                    if native {
                        let capture = try ProjectSettingsFiles.capture(root: root, keys: keys)
                        var document = capture.document ?? .init(key: primary); document.key = primary
                        return Loaded(document: document, capture: capture)
                    }
                    var document = try reader(root, keys)?.document ?? .init(key: primary); document.key = primary
                    return Loaded(document: document, capture: nil)
                }
            }
            let result = await withTaskCancellationHandler { await worker.value } onCancel: { worker.cancel() }
            guard let self else { return .init(key: primary) }
            self.loads.removeValue(forKey: primary)
            guard !self.closed, !Task.isCancelled, self.epochs[primary] == epoch else { return self.document(for: project) }
            switch result {
            case .success(let loaded):
                self.documents[primary] = loaded.document; self.captures[primary] = loaded.capture
                self.loadErrors.removeValue(forKey: primary); self.revision += 1; return loaded.document
            case .failure(let error):
                self.loadErrors[primary] = error.localizedDescription
                self.captures[primary] = nil; self.documents[primary] = .init(key: primary); self.revision += 1
                return self.documents[primary]!
            }
        }
        loads[primary] = task
        return await task.value
    }
    @discardableResult
    func update(_ project: WorkspaceProject, expectedCapture: ProjectSettingsCapture? = nil,
                sourceIsCurrent: (@MainActor () -> Bool)? = nil,
                _ change: @escaping @Sendable (inout ProjectSettingsDocument) throws -> Void) async throws -> ProjectSettingsDocument {
        guard !closed else { throw CancellationError() }
        let primary = key(for: project), keys = ProjectSettingsKey.candidates(for: project)
        if !isLoaded(project) { await load(project) }
        guard !closed else { throw CancellationError() }
        guard sourceIsCurrent?() != false else { throw ProjectSettingsPresentationScope.changed }
        if let error = loadErrors[primary] { throw CoincideError(error) }
        let expected = expectedCapture ?? captures[primary]
        let root = root, reader = reader, writer = writer, native = nativeStorage, previous = writeTail
        let expectedDocument = documents[primary]
        guard !native || expected != nil else { throw CoincideError("Reload project settings before editing them.") }
        epochs[primary] = UUID()
        let operation = Task<ProjectSettingsDocument, any Error> { [weak self] in
            await previous?.value
            guard sourceIsCurrent?() != false else { throw ProjectSettingsPresentationScope.changed }
            let loaded = try await Task.detached { () -> Loaded in
                if native {
                    let capture = try ProjectSettingsFiles.updateCaptured(root: root, keys: keys, expectedCapture: expected, change: change)
                    var document = capture.document ?? .init(key: primary); document.key = primary
                    return .init(document: document, capture: capture)
                }
                // Explicit reader/writer fixtures keep their injectable backend.
                // They are serialized together and may not silently replace a
                // newer decoded document. Production never takes this path.
                return try Self.injectedLock.withLock {
                    let saved = try reader(root, keys)
                    var document = saved?.document ?? .init(key: primary); document.key = primary
                    if let expectedDocument {
                        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
                        guard try encoder.encode(document) == encoder.encode(expectedDocument) else {
                            throw CoincideError("The project settings changed. Reload before saving.")
                        }
                    }
                    try change(&document); try document.validate(); try writer(document, root)
                    if let saved, !saved.key.utf8.elementsEqual(primary.utf8) { try writer(.init(key: saved.key), root) }
                    return .init(document: document, capture: nil)
                }
            }.value
            guard sourceIsCurrent?() != false else {
                throw ProjectSettingsPresentationScope.changedAfterWrite
            }
            guard let self, !self.closed else { return loaded.document }
            self.documents[primary] = loaded.document; self.captures[primary] = loaded.capture
            self.loadErrors.removeValue(forKey: primary); self.revision += 1; self.invalidateIcons(for: project)
            return loaded.document
        }
        writeTail = Task { _ = await operation.result }
        do {
            let result = try await operation.value
            guard sourceIsCurrent?() != false else { throw ProjectSettingsPresentationScope.changedAfterWrite }
            return result
        }
        catch {
            if !closed { await load(project, force: true) }
            throw error
        }
    }

    // MARK: Last-invoked script

    func lastInvokedScriptID(for project: WorkspaceProject) -> String? {
        (defaults.dictionary(forKey: Self.lastInvokedKey) as? [String: String])?[key(for: project)]
    }
    func rememberInvokedScript(_ id: String, for project: WorkspaceProject) {
        var values = (defaults.dictionary(forKey: Self.lastInvokedKey) as? [String: String]) ?? [:]
        guard values[key(for: project)] != id else { return }
        if values.count >= 256 { values.removeAll() }
        values[key(for: project)] = id; defaults.set(values, forKey: Self.lastInvokedKey); revision += 1
    }

    // MARK: Icons

    /// An explicit or detected icon; nil means the view shows the name's monogram.
    func icon(for project: WorkspaceProject) -> ProjectIconPresentation? {
        switch documents[key(for: project)]?.icon {
        case .symbol(let name, let color): .symbol(name: name, color: color)
        case .emoji(let value): .emoji(value)
        case .monogram(let text, let color): .monogram(text: text, color: color)
        case .image, nil:
            iconScopes[Data(project.path.utf8)] == ProjectSettingsPresentationScope(project: project)
                ? detectedIcons[Data(project.path.utf8)].flatMap { $0.map(ProjectIconPresentation.image) } : nil
        }
    }
    /// Resolves an image once per invalidation: an image override, t3.json `iconPath`, then T3's candidate files.
    func resolveIcon(for project: WorkspaceProject) async {
        guard !closed else { return }
        let path = project.path, pathKey = Data(path.utf8), scope = ProjectSettingsPresentationScope(project: project)
        if iconScopes[pathKey] != scope {
            iconReads.removeValue(forKey: pathKey)?.cancel()
            iconOwners[pathKey] = nil
            detectedIcons[pathKey] = nil
            iconScopes[pathKey] = scope
        }
        let document = await load(project)
        guard !closed, !Task.isCancelled, iconScopes[pathKey] == scope else { return }
        if let pending = iconReads[pathKey] { await pending.value; return }
        guard detectedIcons[pathKey] == nil, project.clone.map({ !$0.isReady }) != true else { return }
        switch document.icon { case .symbol, .emoji, .monogram: return; case .image, nil: break }
        let override: String? = if case .image(let value) = document.icon { value } else { nil }
        let epoch = iconEpoch, owner = UUID()
        let task = Task { [weak self] in
            defer {
                self?.iconJobs[owner] = nil
                if self?.iconOwners[pathKey] == owner { self?.iconReads[pathKey] = nil; self?.iconOwners[pathKey] = nil }
            }
            let worker = Task.detached { () -> Data? in
                let files = WorkspaceFileService(root: URL(fileURLWithPath: path))
                var preferred = override.map { [$0] } ?? []
                if let iconPath = try? await ProjectConfigurationService.load(using: files).configuration?.iconPath { preferred.append(iconPath) }
                let asset = try? await ProjectIconResolver.resolve(using: files, preferred: preferred)
                await files.close()
                return asset?.data
            }
            let data = await withTaskCancellationHandler { await worker.value } onCancel: { worker.cancel() }
            guard let self else { return }
            guard !self.closed, self.iconOwners[pathKey] == owner, self.iconScopes[pathKey] == scope,
                  self.iconEpoch == epoch, !Task.isCancelled else { return }
            let image = data.flatMap(NSImage.init(data:)).flatMap { $0.size.width > 0 && $0.size.height > 0 ? $0 : nil }
            self.detectedIcons[pathKey] = .some(image)
        }
        iconReads[pathKey] = task; iconJobs[owner] = task; iconOwners[pathKey] = owner
        await task.value
    }
    func invalidateIcons(for project: WorkspaceProject) {
        let path = Data(project.path.utf8)
        iconReads.removeValue(forKey: path)?.cancel()
        iconOwners[path] = nil; iconScopes[path] = nil
        detectedIcons.removeValue(forKey: path); iconEpoch += 1
    }
    func shutdown() async {
        closed = true
        let pendingLoads = Array(loads.values)
        for task in pendingLoads { task.cancel() }
        for task in pendingLoads { _ = await task.value }
        for task in iconJobs.values { task.cancel() }
        while !iconJobs.isEmpty { for task in Array(iconJobs.values) { await task.value }; await Task.yield() }
        await writeTail?.value
    }
}
