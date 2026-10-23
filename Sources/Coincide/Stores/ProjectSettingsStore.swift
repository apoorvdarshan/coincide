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
    /// Detected images by checkout path; `.some(nil)` records that no image was found.
    private(set) var detectedIcons: [String: NSImage?] = [:]
    private(set) var iconEpoch = 0
    @ObservationIgnored private let defaults: UserDefaults
    @ObservationIgnored private let reader: Reader
    @ObservationIgnored private let writer: Writer
    @ObservationIgnored private var loads: [String: Task<ProjectSettingsDocument, Never>] = [:]
    @ObservationIgnored private var writeTail: Task<Void, Never>?
    @ObservationIgnored private var iconReads: [String: Task<Void, Never>] = [:]
    private static let lastInvokedKey = "projectActions.lastInvoked"
    private static let appEnvironmentKey = "projectDefaults.threadEnvironmentMode"
    private static let appSubmodulesKey = "projectDefaults.worktreeSubmodules"

    init(root: URL, defaults: UserDefaults = .standard,
         reader: @escaping Reader = { try ProjectSettingsFiles.load(root: $0, keys: $1) },
         writer: @escaping Writer = { try ProjectSettingsFiles.save($0, root: $1) }) {
        self.root = root; self.defaults = defaults; self.reader = reader; self.writer = writer
        appThreadEnvironmentMode = defaults.string(forKey: Self.appEnvironmentKey).flatMap(ProjectThreadEnvironmentMode.init(rawValue:))
        appWorktreeSubmodules = defaults.string(forKey: Self.appSubmodulesKey).flatMap(ProjectWorktreeSubmoduleMode.init(rawValue:))
    }

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
    @discardableResult func load(_ project: WorkspaceProject, force: Bool = false) async -> ProjectSettingsDocument {
        let primary = key(for: project), keys = ProjectSettingsKey.candidates(for: project)
        if !force, let cached = documents[primary] { return cached }
        if let pending = loads[primary] { return await pending.value }
        let root = root, reader = reader
        let task = Task<ProjectSettingsDocument, Never> { [weak self] in
            let result = await Task.detached { Result { try reader(root, keys) } }.value
            guard let self else { return .init(key: primary) }
            self.loads.removeValue(forKey: primary)
            switch result {
            case .success(let saved):
                var document = saved?.document ?? .init(key: primary); document.key = primary
                self.documents[primary] = document; self.loadErrors.removeValue(forKey: primary)
                self.revision += 1; return document
            case .failure(let error):
                // A corrupt or newer file is left untouched; editing stays disabled until it is resolved.
                self.loadErrors[primary] = error.localizedDescription
                self.documents[primary] = .init(key: primary); self.revision += 1
                return self.documents[primary]!
            }
        }
        loads[primary] = task
        return await task.value
    }
    /// Applies one change to the latest saved document. A file saved under the checkout fallback key
    /// moves to the shared repository key with this write.
    @discardableResult
    func update(_ project: WorkspaceProject, _ change: @escaping @Sendable (inout ProjectSettingsDocument) throws -> Void) async throws -> ProjectSettingsDocument {
        let primary = key(for: project), keys = ProjectSettingsKey.candidates(for: project)
        if let error = loadErrors[primary] { throw CoincideError(error) }
        let root = root, reader = reader, writer = writer, previous = writeTail
        let operation = Task<ProjectSettingsDocument, any Error> {
            await previous?.value
            return try await Task.detached {
                let saved = try reader(root, keys)
                var document = saved?.document ?? .init(key: primary)
                document.key = primary
                try change(&document)
                try document.validate()
                try writer(document, root)
                if let saved, saved.key != primary { try writer(.init(key: saved.key), root) }
                return document
            }.value
        }
        writeTail = Task { _ = await operation.result }
        let document = try await operation.value
        documents[primary] = document; loadErrors.removeValue(forKey: primary); revision += 1
        invalidateIcons(for: project)
        return document
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
        case .image, nil: detectedIcons[project.path].flatMap { $0.map(ProjectIconPresentation.image) }
        }
    }
    /// Resolves an image once per invalidation: an image override, t3.json `iconPath`, then T3's candidate files.
    func resolveIcon(for project: WorkspaceProject) async {
        let document = await load(project)
        let path = project.path
        if let pending = iconReads[path] { await pending.value; return }
        guard detectedIcons[path] == nil, project.clone.map({ !$0.isReady }) != true else { return }
        switch document.icon { case .symbol, .emoji, .monogram: return; case .image, nil: break }
        let override: String? = if case .image(let value) = document.icon { value } else { nil }
        let epoch = iconEpoch
        let task = Task { [weak self] in
            let data = await Task.detached { () -> Data? in
                let files = WorkspaceFileService(root: URL(fileURLWithPath: path))
                var preferred = override.map { [$0] } ?? []
                if let iconPath = try? await ProjectConfigurationService.load(using: files).configuration?.iconPath { preferred.append(iconPath) }
                let asset = try? await ProjectIconResolver.resolve(using: files, preferred: preferred)
                await files.close()
                return asset?.data
            }.value
            guard let self else { return }
            self.iconReads.removeValue(forKey: path)
            guard self.iconEpoch == epoch, !Task.isCancelled else { return }
            let image = data.flatMap(NSImage.init(data:)).flatMap { $0.size.width > 0 && $0.size.height > 0 ? $0 : nil }
            self.detectedIcons[path] = .some(image)
        }
        iconReads[path] = task
        await task.value
    }
    func invalidateIcons(for project: WorkspaceProject) {
        iconReads.removeValue(forKey: project.path)?.cancel()
        detectedIcons.removeValue(forKey: project.path); iconEpoch += 1
    }
    func shutdown() async {
        for task in iconReads.values { task.cancel() }
        for task in iconReads.values { await task.value }
        await writeTail?.value
    }
}
