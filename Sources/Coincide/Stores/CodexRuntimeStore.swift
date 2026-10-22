import CoincideCore
import Darwin
import Foundation
import Observation

/// Runtime preferences contain paths only. Binary checks never authenticate an
/// account, and observing the shared installer never starts an installation.
@MainActor @Observable final class CodexRuntimeStore {
    struct Client: Sendable {
        var state: @Sendable () -> CodexInstallationState
        var updates: @Sendable () -> AsyncStream<CodexInstallationState>
        var start: @Sendable () throws -> UUID
        var cancel: @Sendable (UUID) async throws -> Void
        var remove: @Sendable ([String]) throws -> Void
        var inspect: @Sendable (CodexRuntimeConfiguration) async throws -> CodexInstallationExecutable
        init(installation: CodexInstallation) {
            state = { installation.state() }; updates = { installation.updates() }
            start = { try installation.start() }
            cancel = { try await installation.cancel(operationID: $0) }
            remove = { try installation.remove(protectedCustomPaths: $0) }
            inspect = { try await installation.inspect(configuration: $0) }
        }
        init(state: @escaping @Sendable () -> CodexInstallationState,
             updates: @escaping @Sendable () -> AsyncStream<CodexInstallationState>,
             start: @escaping @Sendable () throws -> UUID,
             cancel: @escaping @Sendable (UUID) async throws -> Void,
             remove: @escaping @Sendable ([String]) throws -> Void,
             inspect: @escaping @Sendable (CodexRuntimeConfiguration) async throws -> CodexInstallationExecutable) {
            self.state = state; self.updates = updates; self.start = start
            self.cancel = cancel; self.remove = remove; self.inspect = inspect
        }
    }
    private(set) var configuration: CodexRuntimeConfiguration
    var selection: CodexRuntimeSelection { didSet { invalidateInspection() } }
    var executable: String { didSet { invalidateInspection() } }
    var homeDirectory: String { didSet { invalidateInspection() } }
    var authenticationMode: CodexAuthenticationMode { didSet { invalidateInspection() } }
    private(set) var state: CodexInstallationState
    private(set) var inspected: CodexInstallationExecutable?
    private(set) var inspectedConfiguration: CodexRuntimeConfiguration?
    private(set) var errorMessage: String?
    private(set) var isApplying = false
    private(set) var isChecking = false
    private(set) var isCancelling = false
    @ObservationIgnored private var needsPersistence = false
    @ObservationIgnored private let client: Client
    @ObservationIgnored private let preferencesRoot: URL
    @ObservationIgnored private var observer: Task<Void, Never>?
    @ObservationIgnored private var inspection: Task<CodexInstallationExecutable, any Error>?
    @ObservationIgnored private var inspectionID: UUID?
    @ObservationIgnored private var application: Task<Void, Never>?
    @ObservationIgnored private var accountPublication: Task<Void, any Error>?
    @ObservationIgnored private var apply: (@MainActor (CodexRuntimeConfiguration) async throws -> Void)?
    @ObservationIgnored private var protectedCustomPaths: @MainActor () -> [String] = { [] }
    @ObservationIgnored private var ownedOperations: Set<UUID> = []
    @ObservationIgnored private var cancellations: [UUID: Task<Void, any Error>] = [:]
    @ObservationIgnored private var closed = false
    @ObservationIgnored private var shutdownTask: Task<Void, Never>?

    static var defaultRoot: URL {
        FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support/Coincide", isDirectory: true)
    }
    convenience init(rootURL: URL? = nil, installation: CodexInstallation = .shared) {
        self.init(rootURL: rootURL, client: .init(installation: installation))
    }
    init(rootURL: URL? = nil, client: Client) {
        preferencesRoot = (rootURL ?? Self.defaultRoot).appendingPathComponent("CodexSettings", isDirectory: true)
        var saved = CodexRuntimeConfiguration(), loadError: String?
        do { saved = try CodexRuntimePreferences.load(root: preferencesRoot) ?? saved }
        catch { loadError = String(localized: "The saved Codex runtime could not be read safely. Review the runtime selection before using it.") }
        configuration = saved; selection = saved.selection; executable = saved.executable
        homeDirectory = saved.homeDirectory ?? ""; authenticationMode = saved.authenticationMode
        self.client = client; state = client.state(); errorMessage = loadError
        needsPersistence = loadError != nil
        observer = Task { [weak self] in
            for await value in client.updates() {
                guard !Task.isCancelled, let self else { return }
                self.state = value
            }
        }
    }
    func bind(apply: @escaping @MainActor (CodexRuntimeConfiguration) async throws -> Void,
              protectedCustomPaths: @escaping @MainActor () -> [String] = { [] }) {
        self.apply = apply; self.protectedCustomPaths = protectedCustomPaths
    }
    var draftConfiguration: CodexRuntimeConfiguration? {
        let draft = CodexRuntimeConfiguration(instanceID: configuration.instanceID, selection: selection,
            executable: selection == .custom ? executable : "codex", homeDirectory: homeDirectory.isEmpty ? nil : homeDirectory,
            authenticationMode: authenticationMode, accountBinding: authenticationMode == .ownedChatGPT ? configuration.accountBinding : nil)
        guard (try? draft.validate()) != nil else { return nil }
        return draft
    }
    var hasUnappliedChanges: Bool { draftConfiguration != configuration }
    var canApply: Bool { !closed && !isApplying && apply != nil && draftConfiguration != nil && (hasUnappliedChanges || needsPersistence) }
    var canCheck: Bool { !closed && !isApplying && !isChecking && draftConfiguration != nil }
    var isWorking: Bool { isApplying || isChecking || state.phase.isWorking || isCancelling }
    var canStartInstallation: Bool { !closed && !state.phase.isWorking && !isCancelling }
    var canRemove: Bool { canStartInstallation && state.canRemove }
    var progress: Double? {
        guard state.phase == .downloading, let total = state.totalBytes, total > 0 else { return nil }
        return min(1, max(0, Double(state.downloadedBytes) / Double(total)))
    }
    var progressText: String {
        let downloaded = ByteCountFormatter.string(fromByteCount: max(0, state.downloadedBytes), countStyle: .file)
        guard let total = state.totalBytes, total > 0 else { return downloaded }
        return String(localized: "\(downloaded) of \(ByteCountFormatter.string(fromByteCount: total, countStyle: .file))")
    }
    var installationTitle: String {
        guard let installed = state.installedVersion else { return String(localized: "Install Managed CLI") }
        if let target = state.version, target != installed { return String(localized: "Update Managed CLI") }
        return String(localized: "Verify Managed CLI")
    }
    var installationStatus: String {
        if isCancelling { return String(localized: "Stopping Codex installation…") }
        return switch state.phase {
        case .idle: state.installedVersion == nil ? String(localized: "Managed Codex is not installed") : String(localized: "Managed Codex is installed")
        case .downloading: String(localized: "Downloading Codex…")
        case .extracting: String(localized: "Unpacking Codex…")
        case .verifying: String(localized: "Verifying Codex…")
        case .succeeded: String(localized: "Managed Codex verified")
        case .failed: String(localized: "Codex installation could not finish")
        case .cancelled: String(localized: "Codex installation cancelled")
        }
    }
    func applySelection() async {
        guard canApply, let target = draftConfiguration, let apply else { return }
        isApplying = true; errorMessage = nil
        let task = Task { [self] in
            defer { isApplying = false; application = nil }
            do {
                // Establish a private writable destination before changing the
                // running preference. No account or home data is read here.
                try CodexRuntimePreferences.prepare(root: preferencesRoot)
                try await apply(target)
                configuration = target
                do { try CodexRuntimePreferences.save(target, root: preferencesRoot); needsPersistence = false }
                catch {
                    needsPersistence = true
                    errorMessage = String(localized: "This Codex runtime is selected for this session, but the preference could not be saved. Check the application’s settings folder before restarting.")
                }
            } catch {
                errorMessage = String(localized: "The Codex runtime selection could not be applied. Review the executable and Codex home, then try again.")
            }
        }
        application = task; await task.value
    }
    func checkRuntime() async {
        guard canCheck, let target = draftConfiguration else { return }
        let id = UUID(), client = client
        errorMessage = nil; inspected = nil; inspectedConfiguration = nil; isChecking = true; inspectionID = id
        let task = Task { try await client.inspect(target) }; inspection = task
        defer {
            if inspectionID == id { inspection = nil; inspectionID = nil; isChecking = false }
        }
        do {
            let result = try await task.value
            guard !closed, !task.isCancelled, inspectionID == id, draftConfiguration == target else { return }
            inspected = result; inspectedConfiguration = target
        } catch {
            guard !closed, !task.isCancelled, inspectionID == id, draftConfiguration == target else { return }
            errorMessage = String(localized: "The selected Codex executable could not be checked. Review its path and installation. Account access has not been checked.")
        }
    }

    /// Called only inside the coordinator's Engine admission lease. Publication
    /// retains the exact binary/home and owned mode, including on sign-out.
    /// A persistence failure is thrown so the coordinator reports an observed
    /// account change as unconfirmed rather than claiming a complete save.
    func publishAccountBinding(_ binding: CodexAccountBinding?, expectedInstanceID: UUID) async throws {
        guard !closed, !isApplying, configuration.instanceID == expectedInstanceID,
              configuration.authenticationMode == .ownedChatGPT, let apply else {
            throw CoincideError("Choose the saved Coincide ChatGPT connection before publishing its account.")
        }
        let target = configuration.replacingAccountBinding(binding)
        try target.validate()
        isApplying = true; errorMessage = nil
        let task = Task { [self] in
            defer { isApplying = false; accountPublication = nil }
            try CodexRuntimePreferences.prepare(root: preferencesRoot)
            try await apply(target)
            configuration = target; invalidateInspection()
            do { try CodexRuntimePreferences.save(target, root: preferencesRoot); needsPersistence = false }
            catch {
                needsPersistence = true
                let message = String(localized: "The ChatGPT account changed, but the selected connection could not be saved. Refresh the account before continuing.")
                errorMessage = message
                throw CoincideError(message)
            }
        }
        accountPublication = task
        try await task.value
    }
    func startInstallation() {
        guard canStartInstallation else { return }
        errorMessage = nil
        do { let id = try client.start(); ownedOperations.insert(id); state = client.state() }
        catch { errorMessage = String(localized: "Managed Codex could not be installed or verified. Check available disk space and try again.") }
    }
    func cancelInstallation() async {
        guard !closed, !isCancelling, state.phase.isWorking, let id = state.operationID else { return }
        isCancelling = true; defer { isCancelling = false }
        do { try await cancellation(for: id).value; state = client.state() }
        catch { errorMessage = String(localized: "Codex installation cancellation could not be confirmed. Wait for the operation to stop before trying again.") }
        cancellations.removeValue(forKey: id)
    }
    func removeManagedRuntime() {
        guard canRemove else { return }
        errorMessage = nil
        do { try client.remove(protectedCustomPaths()); state = client.state(); invalidateInspection() }
        catch { errorMessage = String(localized: "Managed Codex could not be removed. Close conversations using it and check custom executable paths before trying again.") }
    }
    func shutdown() async {
        if let shutdownTask { await shutdownTask.value; return }
        closed = true; inspection?.cancel()
        let task = Task { [self] in
            _ = try? await inspection?.value; await application?.value; _ = try? await accountPublication?.value
            for id in ownedOperations { _ = try? await cancellation(for: id).value; cancellations.removeValue(forKey: id) }
            for task in cancellations.values { _ = try? await task.value }
            state = client.state(); observer?.cancel(); await observer?.value; observer = nil
        }
        shutdownTask = task; await task.value
    }
    private func invalidateInspection() {
        inspected = nil; inspectedConfiguration = nil; inspection?.cancel()
    }
    private func cancellation(for id: UUID) -> Task<Void, any Error> {
        if let existing = cancellations[id] { return existing }
        let client = client, task = Task { try await client.cancel(id) }; cancellations[id] = task; return task
    }
}

/// A small bounded, owner-only preferences file. Symlink and nonregular leaf
/// files are rejected; writes are staged in the retained settings directory.
private enum CodexRuntimePreferences {
    static func prepare(root: URL) throws {
        guard root.isFileURL else { throw CodexRuntimeConfiguration.invalid() }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        let fd = try directory(root); defer { Darwin.close(fd) }
        guard fchmod(fd, 0o700) == 0 else { throw CodexRuntimeConfiguration.invalid() }
    }
    static func load(root: URL) throws -> CodexRuntimeConfiguration? {
        guard root.isFileURL else { throw CodexRuntimeConfiguration.invalid() }
        let parent = open(root.path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        if parent < 0 && errno == ENOENT { return nil }
        guard parent >= 0 else { throw CodexRuntimeConfiguration.invalid() }; defer { Darwin.close(parent) }
        try validateDirectory(parent)
        let fd = openat(parent, "runtime.json", O_RDONLY | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC)
        if fd < 0 && errno == ENOENT { return nil }
        guard fd >= 0 else { throw CodexRuntimeConfiguration.invalid() }; defer { Darwin.close(fd) }
        var info = stat()
        guard fstat(fd, &info) == 0, info.st_mode & S_IFMT == S_IFREG, info.st_uid == getuid(),
              info.st_mode & 0o077 == 0, info.st_size > 0, info.st_size <= 65_536 else { throw CodexRuntimeConfiguration.invalid() }
        var bytes = [UInt8](repeating: 0, count: Int(info.st_size)), offset = 0
        while offset < bytes.count {
            let count = bytes.withUnsafeMutableBytes { Darwin.read(fd, $0.baseAddress!.advanced(by: offset), $0.count - offset) }
            if count < 0 && errno == EINTR { continue }
            guard count > 0 else { throw CodexRuntimeConfiguration.invalid() }; offset += count
        }
        return try JSONDecoder().decode(CodexRuntimeConfiguration.self, from: Data(bytes))
    }
    static func save(_ configuration: CodexRuntimeConfiguration, root: URL) throws {
        try configuration.validate()
        let data = try JSONEncoder().encode(configuration)
        guard data.count <= 65_536 else { throw CodexRuntimeConfiguration.invalid() }
        let parent = try directory(root); defer { Darwin.close(parent) }
        let name = ".runtime-" + UUID().uuidString
        let fd = openat(parent, name, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, 0o600)
        guard fd >= 0 else { throw CodexRuntimeConfiguration.invalid() }
        defer { Darwin.close(fd); _ = unlinkat(parent, name, 0) }
        var offset = 0
        while offset < data.count {
            let count = data.withUnsafeBytes { Darwin.write(fd, $0.baseAddress!.advanced(by: offset), $0.count - offset) }
            if count < 0 && errno == EINTR { continue }
            guard count > 0 else { throw CodexRuntimeConfiguration.invalid() }; offset += count
        }
        guard fsync(fd) == 0, renameat(parent, name, parent, "runtime.json") == 0 else { throw CodexRuntimeConfiguration.invalid() }
    }
    private static func directory(_ root: URL) throws -> Int32 {
        let fd = open(root.path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        guard fd >= 0 else { throw CodexRuntimeConfiguration.invalid() }
        do { try validateDirectory(fd); return fd } catch { Darwin.close(fd); throw error }
    }
    private static func validateDirectory(_ fd: Int32) throws {
        var info = stat()
        guard fstat(fd, &info) == 0, info.st_mode & S_IFMT == S_IFDIR, info.st_uid == getuid() else {
            throw CodexRuntimeConfiguration.invalid()
        }
    }
}
