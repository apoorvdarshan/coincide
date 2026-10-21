import AppKit
import CoincideCore
import Foundation

/// Explicit local editor actions. Discovery and validation are cancelled and drained on close;
/// a successfully handed-off application is independent of Coincide's runtime lifecycle.
@MainActor
final class NativeExternalEditorService {
    typealias ResolveWorkspace = @MainActor (URL) throws -> WorkspaceFileService
    typealias Authorize = @MainActor (URL, WorkspaceFileService) -> Bool
    typealias Discovery = @MainActor () async throws -> [ExternalEditorInstallation]
    typealias Handoff = @MainActor (ExternalEditorLaunchPlan) throws -> Task<Void, any Error>
    static let preferredEditorDefaultsKey = "preferredExternalEditorID"

    private let defaults: UserDefaults
    private let resolveWorkspace: ResolveWorkspace
    private let authorize: Authorize
    private let discovery: Discovery
    private let handoff: Handoff
    private var cachedInstallations: [ExternalEditorInstallation] = []
    private var cacheExpiry: ContinuousClock.Instant?
    private var latestScanID: UUID?
    private var currentScan: SharedExternalEditorScan?
    private var scans: [UUID: SharedExternalEditorScan] = [:]
    private var scanObservers: [UUID: Task<Void, Never>] = [:]
    private var operations: [UUID: Task<Void, any Error>] = [:]
    private var closed = false
    private var shutdownTask: Task<Void, Never>?

    init(defaults: UserDefaults = .standard, resolveWorkspace: @escaping ResolveWorkspace,
         authorize: @escaping Authorize, discovery: Discovery? = nil, handoff: Handoff? = nil) {
        self.defaults = defaults; self.resolveWorkspace = resolveWorkspace; self.authorize = authorize
        self.discovery = discovery ?? Self.discoverApplications
        self.handoff = handoff ?? Self.handoffToSystem
    }
    var preferredEditorID: ExternalEditorID? {
        get { defaults.string(forKey: Self.preferredEditorDefaultsKey).flatMap(ExternalEditorID.init(rawValue:)) }
        set {
            if let newValue { defaults.set(newValue.rawValue, forKey: Self.preferredEditorDefaultsKey) }
            else { defaults.removeObject(forKey: Self.preferredEditorDefaultsKey) }
        }
    }
    func availableEditors(forceRefresh: Bool = false) async -> [ExternalEditorDescriptor] {
        guard !closed else { return [] }
        do { return descriptors(try await installations(forceRefresh: forceRefresh)) }
        catch { return closed ? [] : descriptors(cachedInstallations) }
    }
    func open(_ target: ExternalEditorTarget, editor: ExternalEditorID? = nil) async throws {
        try await perform(target, editor: editor, reveal: false)
    }
    func reveal(_ target: ExternalEditorTarget) async throws {
        try await perform(target, editor: nil, reveal: true)
    }
    private func perform(_ target: ExternalEditorTarget, editor: ExternalEditorID?, reveal: Bool) async throws {
        guard !closed else { throw ExternalEditorError(.closed, "External editor actions are unavailable while Coincide is closing.") }
        try Task.checkCancellation()
        let id = UUID(), task = Task { try await self.prepareAndHandoff(target, requestedEditor: editor, reveal: reveal, operationID: id) }
        operations[id] = task
        defer { operations.removeValue(forKey: id) }
        try await withTaskCancellationHandler { try await task.value } onCancel: { task.cancel() }
    }
    private func prepareAndHandoff(_ target: ExternalEditorTarget, requestedEditor: ExternalEditorID?, reveal: Bool, operationID: UUID) async throws {
        guard target.workspaceRoot.isFileURL,
              target.workspaceRoot.host == nil || target.workspaceRoot.host == "" || target.workspaceRoot.host == "localhost",
              target.workspaceRoot.query == nil, target.workspaceRoot.fragment == nil else {
            throw ExternalEditorError(.invalidTarget, "Choose a local registered workspace.")
        }
        let root = target.workspaceRoot.standardizedFileURL.resolvingSymlinksInPath()
        let service = try resolveWorkspace(root)
        guard service.root.path == root.path else { throw CancellationError() }
        try ensureOwner(root, service)
        // Capture the root anchor before any slow editor discovery. Replacing the named root
        // while the picker is discovering editors must not silently authorize its replacement.
        _ = try await ownedMetadata(service, root: root, relativePath: "")
        let installed: [ExternalEditorInstallation]
        if reveal { installed = [] }
        else {
            do { installed = try await installations(forceRefresh: false) }
            catch { try ensureOwner(root, service); throw error }
        }
        try Task.checkCancellation()
        try ensureOwner(root, service)
        let selected: ExternalEditorID
        if reveal { selected = .fileManager }
        else if let requestedEditor { selected = requestedEditor }
        else {
            let ids = Set(installed.map(\.id))
            if let preferredEditorID, preferredEditorID == .fileManager || ids.contains(preferredEditorID) { selected = preferredEditorID }
            else { selected = ExternalEditorID.allCases.first(where: { ids.contains($0) }) ?? .fileManager }
        }
        let installation = installed.first { $0.id == selected }
        if selected != .fileManager {
            guard let installation else { throw ExternalEditorError(.unavailable, "This editor is not installed or its launcher is unavailable. Refresh the installed editors and choose another.") }
            try installation.validate()
        }
        // Metadata is checked after discovery and installation validation, so a target changed
        // during either await cannot escape the captured workspace or redirect to a special file.
        let metadata = try await ownedMetadata(service, root: root, relativePath: target.relativePath ?? "")
        let plan: ExternalEditorLaunchPlan
        if reveal { plan = .reveal(metadata.resolvedURL) }
        else { plan = try ExternalEditorCatalog.plan(editor: selected, installation: installation, metadata: metadata, location: target.location) }
        try Task.checkCancellation()
        try installation?.validate()
        try ensureOwner(root, service)
        // No await occurs between the final owner/cache check and the synchronous handoff.
        // Cancellation after this point never signals or terminates the external application.
        let completion = try handoff(plan)
        operations.removeValue(forKey: operationID)
        try await completion.value
    }
    private func ensureOwner(_ root: URL, _ service: WorkspaceFileService) throws {
        guard !closed, authorize(root, service), let current = try? resolveWorkspace(root), current === service else { throw CancellationError() }
    }
    private func ownedMetadata(_ service: WorkspaceFileService, root: URL, relativePath: String) async throws -> WorkspaceFileMetadata {
        do {
            let metadata = try await service.metadata(relativePath: relativePath)
            try Task.checkCancellation(); try ensureOwner(root, service); return metadata
        } catch {
            try Task.checkCancellation(); try ensureOwner(root, service); throw error
        }
    }
    private func descriptors(_ installations: [ExternalEditorInstallation]) -> [ExternalEditorDescriptor] {
        let ids = Set(installations.map(\.id))
        return ExternalEditorCatalog.editors.filter { $0.id == .fileManager || ids.contains($0.id) }
    }
    private func installations(forceRefresh: Bool) async throws -> [ExternalEditorInstallation] {
        guard !closed else { throw CancellationError() }
        try Task.checkCancellation()
        if !forceRefresh, let cacheExpiry, ContinuousClock.now < cacheExpiry { return cachedInstallations }
        let waiter = UUID(), scan: SharedExternalEditorScan
        if let currentScan, currentScan.add(waiter) { scan = currentScan }
        else {
            let discovery = discovery
            scan = SharedExternalEditorScan(task: Task { try Task.checkCancellation(); return try await discovery() })
            _ = scan.add(waiter)
            currentScan = scan; latestScanID = scan.id; scans[scan.id] = scan
            scanObservers[scan.id] = Task { [weak self] in
                let result = await scan.task.result
                scan.complete(result)
                self?.scanFinished(scan, result: result)
            }
        }
        defer { scan.finish(waiter) }
        let values = try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in scan.suspend(waiter, continuation: continuation) }
        } onCancel: { scan.cancel(waiter) }
        try Task.checkCancellation()
        guard !closed else { throw CancellationError() }
        var seen = Set<ExternalEditorID>()
        return values.filter { seen.insert($0.id).inserted }
    }
    private func scanFinished(_ scan: SharedExternalEditorScan, result: Result<[ExternalEditorInstallation], any Error>) {
        scans.removeValue(forKey: scan.id); scanObservers.removeValue(forKey: scan.id)
        if currentScan === scan { currentScan = nil }
        if !closed, latestScanID == scan.id, case .success(let values) = result {
            var seen = Set<ExternalEditorID>()
            cachedInstallations = values.filter { seen.insert($0.id).inserted }
            cacheExpiry = ContinuousClock.now + .seconds(60)
        }
    }
    func shutdown() async {
        if let shutdownTask { await shutdownTask.value; return }
        closed = true; latestScanID = nil
        let operations = Array(operations.values), scans = Array(scans.values)
        let observers = Array(scanObservers.values)
        for task in operations { task.cancel() }
        for scan in scans { scan.cancelAll() }
        let task = Task {
            for operation in operations { _ = await operation.result }
            for observer in observers { await observer.value }
        }
        shutdownTask = task; await task.value
    }
    private static func discoverApplications() async throws -> [ExternalEditorInstallation] {
        var registered: [URL] = []
        for id in ExternalEditorID.allCases {
            try Task.checkCancellation()
            for bundleID in ExternalEditorCatalog.bundleIdentifiers(for: id) {
                registered.append(contentsOf: NSWorkspace.shared.urlsForApplications(withBundleIdentifier: bundleID).prefix(4))
            }
        }
        let directories = [FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Applications", isDirectory: true),
                           URL(fileURLWithPath: "/Applications", isDirectory: true)]
        let worker = Task.detached(priority: .utility) { try ExternalEditorCatalog.discover(applicationDirectories: directories, registeredApplications: registered) }
        return try await withTaskCancellationHandler { try await worker.value } onCancel: { worker.cancel() }
    }
    private static func handoffToSystem(_ plan: ExternalEditorLaunchPlan) throws -> Task<Void, any Error> {
        let workspace = NSWorkspace.shared
        switch plan {
        case .defaultApplication(let url):
            let configuration = NSWorkspace.OpenConfiguration(); configuration.promptsUserIfNeeded = false
            let pair = AsyncThrowingStream<Void, any Error>.makeStream()
            let completion = Task<Void, any Error> { for try await _ in pair.stream { } }
            workspace.open(url, configuration: configuration) { _, error in
                pair.continuation.finish(throwing: error == nil ? nil : ExternalEditorError(.launchFailed, "No application could open this workspace item."))
            }
            return completion
        case .reveal(let url): workspace.activateFileViewerSelecting([url]); return Task { }
        case .application(let applicationURL, let targetURL):
            let configuration = NSWorkspace.OpenConfiguration()
            configuration.promptsUserIfNeeded = false
            configuration.allowsRunningApplicationSubstitution = false
            let pair = AsyncThrowingStream<Void, any Error>.makeStream()
            let completion = Task<Void, any Error> { for try await _ in pair.stream { } }
            workspace.open([targetURL], withApplicationAt: applicationURL, configuration: configuration) { _, error in
                pair.continuation.finish(throwing: error == nil ? nil : ExternalEditorError(.launchFailed, "The selected editor could not open this workspace item. Refresh the installed editors and try again."))
            }
            return completion
        case .command(let executableURL, let arguments):
            try DetachedExternalEditorLauncher.launch(executableURL: executableURL, arguments: arguments)
            return Task { }
        }
    }
}

/// One interrupted menu/action cannot cancel a discovery another action is awaiting.
private final class SharedExternalEditorScan: @unchecked Sendable {
    let id = UUID()
    let task: Task<[ExternalEditorInstallation], any Error>
    private let lock = NSLock()
    private struct Waiter { var continuation: CheckedContinuation<[ExternalEditorInstallation], any Error>? }
    private var waiters: [UUID: Waiter] = [:]
    private var result: Result<[ExternalEditorInstallation], any Error>?
    private var accepting = true
    init(task: Task<[ExternalEditorInstallation], any Error>) { self.task = task }
    func add(_ waiter: UUID) -> Bool {
        lock.lock(); defer { lock.unlock() }
        guard accepting else { return false }; waiters[waiter] = .init(); return true
    }
    func suspend(_ waiter: UUID, continuation: CheckedContinuation<[ExternalEditorInstallation], any Error>) {
        lock.lock()
        guard waiters[waiter] != nil else { lock.unlock(); continuation.resume(throwing: CancellationError()); return }
        if let result { lock.unlock(); continuation.resume(with: result); return }
        waiters[waiter]?.continuation = continuation; lock.unlock()
    }
    func complete(_ result: Result<[ExternalEditorInstallation], any Error>) {
        lock.lock(); self.result = result; accepting = false
        let continuations = waiters.values.compactMap(\.continuation)
        for id in Array(waiters.keys) { waiters[id]?.continuation = nil }
        lock.unlock()
        for continuation in continuations { continuation.resume(with: result) }
    }
    func finish(_ waiter: UUID) { lock.lock(); waiters.removeValue(forKey: waiter); lock.unlock() }
    func cancel(_ waiter: UUID) {
        lock.lock(); let continuation = waiters.removeValue(forKey: waiter)?.continuation
        let stop = waiters.isEmpty
        if stop { accepting = false }
        lock.unlock()
        continuation?.resume(throwing: CancellationError())
        if stop { task.cancel() }
    }
    func cancelAll() {
        lock.lock(); accepting = false
        let continuations = waiters.values.compactMap(\.continuation); waiters = [:]
        lock.unlock()
        for continuation in continuations { continuation.resume(throwing: CancellationError()) }
        task.cancel()
    }
}
