import Darwin
import Foundation

public struct CodexInstallationError: Error, Sendable, Equatable, LocalizedError {
    public enum Kind: String, Sendable {
        case invalidConfiguration, unavailable, invalidRecord, ownershipLost, busy, staleOperation, insufficientDiskSpace
        case downloadFailed, extractFailed, verificationFailed, publicationFailed, cancelled, closed
    }
    public let kind: Kind
    public init(_ kind: Kind) { self.kind = kind }
    public var errorDescription: String? {
        switch kind {
        case .invalidConfiguration: "The Codex runtime selection is invalid."
        case .unavailable: "The selected Codex runtime is unavailable. Check its installation or executable path."
        case .invalidRecord: "The managed Codex package is incomplete or changed. Review its installation before continuing."
        case .ownershipLost: "The managed Codex folder changed. Existing files were preserved."
        case .busy: "Stop Codex sessions and setup flows before removing its managed runtime. Another installation may also be running."
        case .staleOperation: "This Codex installation is no longer current. Refresh its status before cancelling."
        case .insufficientDiskSpace: "There is not enough verified free space to install the complete Codex package."
        case .downloadFailed: "The Codex download could not be verified. The previous runtime remains selected."
        case .extractFailed: "The Codex package could not be safely extracted. The previous runtime remains selected."
        case .verificationFailed: "The Codex executable did not pass its bounded runtime check."
        case .publicationFailed: "The managed Codex package could not be activated. The previous runtime remains selected."
        case .cancelled: "Codex installation cancelled. The previous runtime remains selected."
        case .closed: "The Codex installation service is closed."
        }
    }
}
public enum CodexInstallationPhase: String, Codable, Sendable {
    case idle, downloading, extracting, verifying, succeeded, failed, cancelled
    public var isWorking: Bool { self == .downloading || self == .extracting || self == .verifying }
}
public struct CodexInstallationState: Sendable, Equatable {
    public var operationID: UUID?
    public var phase: CodexInstallationPhase
    public var downloadedBytes: Int64
    public var totalBytes: Int64?
    public var version: String?
    public var installedVersion: String?
    public var canRemove: Bool
    public var message: String?
    public var source: CodexRuntimeSelection?
    public var executablePath: String?
    public init(operationID: UUID? = nil, phase: CodexInstallationPhase = .idle, downloadedBytes: Int64 = 0,
                totalBytes: Int64? = nil, version: String? = nil, installedVersion: String? = nil,
                canRemove: Bool = false, message: String? = nil, source: CodexRuntimeSelection? = nil, executablePath: String? = nil) {
        self.operationID = operationID; self.phase = phase; self.downloadedBytes = downloadedBytes; self.totalBytes = totalBytes
        self.version = version; self.installedVersion = installedVersion; self.canRemove = canRemove; self.message = message
        self.source = source; self.executablePath = executablePath
    }
}
public struct CodexInstallationExecutable: Sendable, Equatable {
    public let executable: URL
    public let source: CodexRuntimeSelection
    public let version: String?
    public let managedDirectory: URL?
    public init(executable: URL, source: CodexRuntimeSelection, version: String? = nil, managedDirectory: URL? = nil) {
        self.executable = executable; self.source = source; self.version = version; self.managedDirectory = managedDirectory
    }
}
public final class CodexInstallationLease: @unchecked Sendable {
    public let resolved: CodexInstallationExecutable
    public let releaseID: String?
    private let lock = NSLock()
    private var cleanup: (@Sendable () -> Void)?
    init(resolved: CodexInstallationExecutable, releaseID: String?, cleanup: @escaping @Sendable () -> Void = {}) {
        self.resolved = resolved; self.releaseID = releaseID; self.cleanup = cleanup
    }
    public func release() { let body = lock.withLock { let old = cleanup; cleanup = nil; return old }; body?() }
    deinit { release() }
}

public final class CodexInstallation: @unchecked Sendable {
    public typealias Downloader = @Sendable (CodexManagedRelease, URL, @escaping @Sendable (Int64) -> Void) async throws -> Void
    public typealias Extractor = @Sendable (CodexManagedRelease, URL, URL) async throws -> Void
    public typealias Verifier = @Sendable (CodexManagedRelease, CodexInstallationExecutable, URL) async throws -> Void
    public typealias Inspector = @Sendable (CodexInstallationExecutable, URL) async throws -> String
    public typealias DiskSpace = @Sendable (URL) throws -> Int64
    public typealias LocalResolver = @Sendable (String) -> URL?
    public static let shared = CodexInstallation()
    public static var defaultRoot: URL { FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support/Coincide/Tools/Codex", isDirectory: true) }
    public let rootURL: URL
    private let release: CodexManagedRelease?
    private let downloader: Downloader, extractor: Extractor, verifier: Verifier, inspector: Inspector, diskSpace: DiskSpace, localResolver: LocalResolver
    private let lock = NSLock()
    private var current: CodexInstallationState
    private var observers: [UUID: AsyncStream<CodexInstallationState>.Continuation] = [:]
    private var running: (id: UUID, task: Task<Void, Never>)?
    private var inspections: [UUID: Task<CodexInstallationExecutable, any Error>] = [:]
    private var leases: [String: Int] = [:]
    private var closed = false
    private static let ownerName = ".coincide-codex-installation.json"
    private struct Owner: Codable { let format: Int; let id: UUID }
    private struct Active: Codable { let releaseID: String }
    private struct Attempt: Codable { let rootID: UUID; let operationID: UUID }
    private struct Complete: Codable { let rootID: UUID; let release: CodexManagedRelease; let inventory: CodexInstalledFile }
    private struct Context: Sendable { let root: CodexInstallDirectory; let versions: CodexInstallDirectory; let ownerID: UUID; let ownerProof: CodexInstalledFile }
    private struct LocalProof: Sendable, Equatable {
        let invoked: String, resolved: String
        let device: UInt64, inode: UInt64, bytes: Int64, modified: Int64, nanoseconds: Int64, changed: Int64, changedNanoseconds: Int64
    }
    public init(rootURL: URL = CodexInstallation.defaultRoot, release: CodexManagedRelease? = .current,
                downloader: Downloader? = nil,
                extractor: Extractor? = nil,
                verifier: Verifier? = nil,
                inspector: Inspector? = nil,
                diskSpace: @escaping DiskSpace = { url in
                    let values = try FileManager.default.attributesOfFileSystem(forPath: url.path)
                    guard let count = values[.systemFreeSize] as? NSNumber else { throw CodexInstallationError(.insufficientDiskSpace) }; return count.int64Value
                }, localResolver: @escaping LocalResolver = ProcessChannel.findExecutable) {
        self.rootURL = rootURL.standardizedFileURL.resolvingSymlinksInPath(); self.release = release
        // Emit async defaults only in this module. Some Swift toolchains emit
        // incompatible async contexts for default-argument closures in clients.
        self.downloader = downloader ?? { try await CodexArchiveDownloader.download(release: $0, to: $1, progress: $2) }
        self.extractor = extractor ?? { try await CodexArchiveExtractor.extract(release: $0, archive: $1, to: $2) }
        self.verifier = verifier ?? { try await CodexInstallationVerifier.verify(release: $0, executable: $1, scratch: $2) }
        self.inspector = inspector ?? { try await CodexInstallationVerifier.inspect(executable: $0, scratch: $1) }
        self.diskSpace = diskSpace; self.localResolver = localResolver
        current = .init(totalBytes: release?.archiveBytes, version: release?.version)
        if FileManager.default.fileExists(atPath: self.rootURL.path) {
            do {
                let context = try self.context(create: false); current.canRemove = true
                if try context.root.exists("active.json") { let selected = try completed(context.root.read(Active.self, "active.json").releaseID, context: context); current.installedVersion = selected.version; current.source = .managed; current.executablePath = selected.executable.path }
            } catch { current.phase = .failed; current.message = CodexInstallationError(.invalidRecord).localizedDescription }
        }
    }
    public func state() -> CodexInstallationState { lock.withLock { current } }
    public func updates() -> AsyncStream<CodexInstallationState> {
        let id = UUID(), pair = AsyncStream<CodexInstallationState>.makeStream(bufferingPolicy: .bufferingNewest(1))
        pair.continuation.onTermination = { [weak self] _ in Task { self?.lock.withLock { _ = self?.observers.removeValue(forKey: id) } } }
        lock.withLock { if closed { pair.continuation.finish() } else { observers[id] = pair.continuation; pair.continuation.yield(current) } }; return pair.stream
    }
    private func publish() { for observer in observers.values { observer.yield(current) } }
    public func resolve(configuration: CodexRuntimeConfiguration) throws -> CodexInstallationExecutable {
        try lock.withLock { try safe { try resolved(configuration).0 } }
    }
    public func acquire(configuration: CodexRuntimeConfiguration) throws -> CodexInstallationLease {
        try lock.withLock {
            try safe { let selected = try resolved(configuration); return try lease(selected.0, context: selected.1, releaseID: selected.2) }
        }
    }
    private func safe<T>(_ body: () throws -> T) throws -> T {
        do { return try body() } catch let error as CodexInstallationError { throw error }
        catch is CancellationError { throw CodexInstallationError(.cancelled) }
        catch { throw CodexInstallationError(.ownershipLost) }
    }
    private func resolved(_ configuration: CodexRuntimeConfiguration) throws -> (CodexInstallationExecutable, Context?, String?) {
        do { try configuration.validate() } catch { throw CodexInstallationError(.invalidConfiguration) }
        guard !closed else { throw CodexInstallationError(.closed) }
        if configuration.selection == .managed {
            guard FileManager.default.fileExists(atPath: rootURL.path) else { throw CodexInstallationError(.unavailable) }
            let context = try context(create: false), active = try context.root.read(Active.self, "active.json")
            return (try completed(active.releaseID, context: context), context, active.releaseID)
        }
        guard let invoked = localResolver(configuration.executable) else { throw CodexInstallationError(.unavailable) }
        _ = try localProof(invoked)
        let physical = invoked.standardizedFileURL.resolvingSymlinksInPath()
        if physical.path.hasPrefix(rootURL.path + "/") {
            let context = try context(create: false), version = physical.deletingLastPathComponent().deletingLastPathComponent()
            guard version.deletingLastPathComponent() == context.versions.url else { throw CodexInstallationError(.invalidRecord) }
            let complete = try completed(version.lastPathComponent, context: context)
            guard complete.executable == physical else { throw CodexInstallationError(.invalidRecord) }
            return (.init(executable: invoked, source: configuration.selection, version: complete.version, managedDirectory: version), context, version.lastPathComponent)
        }
        // Keep launcher spelling: shims may dispatch using their invoked name.
        return (.init(executable: invoked, source: configuration.selection), nil, nil)
    }
    private func lease(_ value: CodexInstallationExecutable, context: Context?, releaseID: String?) throws -> CodexInstallationLease {
        guard let context, let releaseID else { return .init(resolved: value, releaseID: nil) }
        let held = try CodexInstallLock(context.root, name: ".leases.lock", shared: true); leases[releaseID, default: 0] += 1
        return .init(resolved: value, releaseID: releaseID) { [weak self] in
            held.release(); guard let self else { return }; self.lock.withLock {
                if let count = self.leases[releaseID], count > 1 { self.leases[releaseID] = count - 1 } else { self.leases.removeValue(forKey: releaseID) }
            }
        }
    }
    public func inspect(configuration: CodexRuntimeConfiguration) async throws -> CodexInstallationExecutable {
        let id = UUID(), held = try acquire(configuration: configuration), inspector = inspector
        let proof = try localProof(held.resolved.executable)
        let scratch = FileManager.default.temporaryDirectory.appendingPathComponent("coincide-codex-inspect-" + id.uuidString, isDirectory: true)
        let task: Task<CodexInstallationExecutable, any Error> = try lock.withLock {
            guard !closed else { throw CodexInstallationError(.closed) }
            let task = Task<CodexInstallationExecutable, any Error> {
                defer { held.release(); try? FileManager.default.removeItem(at: scratch) }
                try FileManager.default.createDirectory(at: scratch, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
                let version = try await inspector(held.resolved, scratch)
                try Task.checkCancellation()
                guard try self.localProof(held.resolved.executable) == proof else { throw CodexInstallationError(.ownershipLost) }
                let observed = try self.resolve(configuration: configuration)
                guard observed.executable == held.resolved.executable, observed.managedDirectory == held.resolved.managedDirectory,
                      held.resolved.version == nil || held.resolved.version == version else { throw CodexInstallationError(.verificationFailed) }
                return .init(executable: observed.executable, source: observed.source, version: version, managedDirectory: observed.managedDirectory)
            }
            inspections[id] = task; return task
        }
        defer { lock.withLock { _ = inspections.removeValue(forKey: id) } }
        do { return try await withTaskCancellationHandler { try await task.value } onCancel: { task.cancel() } }
        catch is CancellationError { throw CancellationError() }
        catch let error as CodexInstallationError { throw error }
        catch { throw CodexInstallationError(.verificationFailed) }
    }
    private func localProof(_ url: URL) throws -> LocalProof {
        let physical = url.standardizedFileURL.resolvingSymlinksInPath(); var info = stat()
        guard lstat(physical.path, &info) == 0, info.st_mode & S_IFMT == S_IFREG, info.st_mode & 0o111 != 0, access(url.path, X_OK) == 0 else { throw CodexInstallationError(.unavailable) }
        return .init(invoked: url.path, resolved: physical.path, device: UInt64(truncatingIfNeeded: info.st_dev), inode: info.st_ino, bytes: info.st_size,
                     modified: Int64(info.st_mtimespec.tv_sec), nanoseconds: Int64(info.st_mtimespec.tv_nsec), changed: Int64(info.st_ctimespec.tv_sec), changedNanoseconds: Int64(info.st_ctimespec.tv_nsec))
    }
    @discardableResult public func start() throws -> UUID {
        try lock.withLock { try safe {
            guard !closed else { throw CodexInstallationError(.closed) }; if let running { return running.id }
            try Task.checkCancellation(); guard let release else { throw CodexInstallationError(.unavailable) }; try release.validate()
            let context = try context(create: true), held = try CodexInstallLock(context.root, name: ".installation.lock", shared: false), id = UUID()
            current.operationID = id; current.phase = .downloading; current.downloadedBytes = 0; current.totalBytes = release.archiveBytes
            current.version = release.version; current.canRemove = true; current.message = nil
            let task = Task { [weak self] in guard let self else { held.release(); return }; await self.install(id, release: release, context: context); held.release(); self.lock.withLock { if self.running?.id == id { self.running = nil } } }
            running = (id, task); publish(); return id
        } }
    }
    public func cancel(operationID: UUID) async throws {
        let task: Task<Void, Never>? = try lock.withLock {
            guard current.operationID == operationID else { throw CodexInstallationError(.staleOperation) }
            guard let running, running.id == operationID else { return nil }; if current.phase.isWorking { running.task.cancel() }; return running.task
        }; await task?.value
    }
    public func shutdown() async {
        let tasks = lock.withLock { closed = true; running?.task.cancel(); for task in inspections.values { task.cancel() }; return (running?.task, Array(inspections.values)) }
        await tasks.0?.value; for task in tasks.1 { _ = await task.result }
        let streams = lock.withLock { let old = Array(observers.values); observers.removeAll(); return old }; for stream in streams { stream.finish() }
    }
    private func progress(_ id: UUID, _ bytes: Int64, limit: Int64) { lock.withLock { guard current.operationID == id, current.phase == .downloading, bytes >= current.downloadedBytes, bytes <= limit else { return }; current.downloadedBytes = bytes; publish() } }
    private func phase(_ id: UUID, _ value: CodexInstallationPhase) { lock.withLock { guard current.operationID == id else { return }; current.phase = value; publish() } }
    private func install(_ id: UUID, release: CodexManagedRelease, context: Context) async {
        var stage: CodexInstallDirectory?, verificationLease: CodexInstallationLease?
        var failure: CodexInstallationError?
        do {
            try Task.checkCancellation(); try validateOwner(context)
            let staging = try context.versions.create(".install-" + id.uuidString.lowercased()); stage = staging
            try staging.write(Attempt(rootID: context.ownerID, operationID: id), ".attempt.json"); let scratch = try staging.create("verification")
            if try context.versions.exists(release.sha256) {
                let selected = try lock.withLock { try completed(release.sha256, context: context) }
                guard selected.version == release.version else { throw CodexInstallationError(.invalidRecord) }
                verificationLease = try lock.withLock { try lease(selected, context: context, releaseID: release.sha256) }
                phase(id, .verifying)
                do { try await verifier(release, selected, scratch.url) } catch is CancellationError { throw CancellationError() } catch { throw CodexInstallationError(.verificationFailed) }
                try Task.checkCancellation(); try lock.withLock { _ = try completed(release.sha256, context: context); try activate(id, release: release, context: context) }
            } else {
                guard try diskSpace(context.versions.url) >= release.archiveBytes + 8_589_934_592 + 268_435_456 else { throw CodexInstallationError(.insufficientDiskSpace) }
                let archive = staging.url.appendingPathComponent("download.tar.gz")
                do { try await downloader(release, archive) { [weak self] in self?.progress(id, $0, limit: release.archiveBytes) } } catch is CancellationError { throw CancellationError() } catch { throw CodexInstallationError(.downloadFailed) }
                try Task.checkCancellation()
                do { let proof = try staging.file("download.tar.gz", bytes: release.archiveBytes, seal: true); guard proof.digest == release.sha256 else { throw CodexInstallationError(.downloadFailed) } }
                catch is CancellationError { throw CancellationError() } catch { throw CodexInstallationError(.downloadFailed) }
                phase(id, .extracting); let runtime = try staging.create("runtime")
                do { try await extractor(release, archive, runtime.url) } catch is CancellationError { throw CancellationError() } catch { throw CodexInstallationError(.extractFailed) }
                try Task.checkCancellation(); try runtime.validate()
                let inventory = try CodexPackageInventory.seal(runtime, release: release)
                let executable = CodexInstallationExecutable(executable: runtime.url.appendingPathComponent("bin/" + release.executableName), source: .managed, version: release.version, managedDirectory: runtime.url)
                phase(id, .verifying)
                do { try await verifier(release, executable, scratch.url) } catch is CancellationError { throw CancellationError() } catch { throw CodexInstallationError(.verificationFailed) }
                try Task.checkCancellation(); try inventory.validate(runtime, release: release)
                let inventoryProof = try runtime.writeInventory(inventory)
                try runtime.write(Complete(rootID: context.ownerID, release: release, inventory: inventoryProof), CodexPackageInventory.completion)
                try lock.withLock { try Task.checkCancellation(); try validateOwner(context); try context.versions.publish(runtime, from: staging, as: release.sha256); _ = try completed(release.sha256, context: context); try activate(id, release: release, context: context) }
            }
        } catch is CancellationError { failure = .init(.cancelled) }
        catch let error as CodexInstallationError { failure = Task.isCancelled ? .init(.cancelled) : error }
        catch { failure = Task.isCancelled ? .init(.cancelled) : .init(.publicationFailed) }
        verificationLease?.release(); if let stage { try? context.versions.remove(stage) }
        if let failure { lock.withLock { guard current.operationID == id, current.phase != .succeeded else { return }; current.phase = failure.kind == .cancelled ? .cancelled : .failed; current.message = failure.localizedDescription; publish() } }
    }
    private func activate(_ id: UUID, release: CodexManagedRelease, context: Context) throws {
        guard current.operationID == id else { throw CodexInstallationError(.staleOperation) }; try Task.checkCancellation(); try validateOwner(context)
        let value = try completed(release.sha256, context: context)
        try context.root.replace(Active(releaseID: release.sha256), "active.json")
        current.phase = .succeeded; current.installedVersion = release.version; current.source = .managed; current.executablePath = value.executable.path; current.message = nil; publish()
    }
    private func context(create: Bool) throws -> Context {
        guard rootURL.isFileURL, rootURL.path != "/" else { throw CodexInstallationError(.invalidConfiguration) }
        var created = false
        if create { try FileManager.default.createDirectory(at: rootURL.deletingLastPathComponent(), withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700]); if mkdir(rootURL.path, 0o700) == 0 { created = true } else if errno != EEXIST { throw CodexInstallationError(.ownershipLost) } }
        let root = try CodexInstallDirectory(rootURL)
        if created { try root.write(Owner(format: 1, id: UUID()), Self.ownerName) }
        let owner = try root.readSealed(Owner.self, Self.ownerName); guard owner.value.format == 1 else { throw CodexInstallationError(.invalidRecord) }
        let versions: CodexInstallDirectory
        if created { versions = try root.create("versions"); let first = try CodexInstallLock(root, name: ".installation.lock", shared: false, create: true); first.release(); let second = try CodexInstallLock(root, name: ".leases.lock", shared: false, create: true); second.release() }
        else { versions = try .init(child: "versions", parent: root) }
        return .init(root: root, versions: versions, ownerID: owner.value.id, ownerProof: owner.proof)
    }
    private func validateOwner(_ context: Context) throws {
        _ = try context.root.file(Self.ownerName, bytes: context.ownerProof.bytes, seal: false, proof: context.ownerProof)
        let owner = try context.root.read(Owner.self, Self.ownerName)
        guard owner.format == 1, owner.id == context.ownerID else { throw CodexInstallationError(.ownershipLost) }
        _ = try context.root.file(Self.ownerName, bytes: context.ownerProof.bytes, seal: false, proof: context.ownerProof)
    }
    private func completed(_ id: String, context: Context) throws -> CodexInstallationExecutable {
        try validateOwner(context)
        guard id.count == 64, id.utf8.allSatisfy({ (48...57).contains($0) || (97...102).contains($0) }) else { throw CodexInstallationError(.invalidRecord) }
        let directory = try CodexInstallDirectory(child: id, parent: context.versions), record = try directory.read(Complete.self, CodexPackageInventory.completion)
        try record.release.validate(); guard record.rootID == context.ownerID, record.release.sha256 == id else { throw CodexInstallationError(.invalidRecord) }
        let inventory = try directory.readInventory(proof: record.inventory); try inventory.validate(directory, release: record.release)
        return .init(executable: directory.url.appendingPathComponent("bin/" + record.release.executableName), source: .managed, version: record.release.version, managedDirectory: directory.url)
    }
    public func remove(protectedCustomPaths: [String] = []) throws {
        try lock.withLock { try safe {
            guard !closed else { throw CodexInstallationError(.closed) }; guard running == nil, leases.isEmpty, inspections.isEmpty else { throw CodexInstallationError(.busy) }
            if !FileManager.default.fileExists(atPath: rootURL.path) { return }
            let context = try context(create: false), worker = try CodexInstallLock(context.root, name: ".installation.lock", shared: false), binaries = try CodexInstallLock(context.root, name: ".leases.lock", shared: false)
            defer { worker.release(); binaries.release() }
            guard protectedCustomPaths.count <= 4_096 else { throw CodexInstallationError(.invalidConfiguration) }
            for path in protectedCustomPaths where !path.isEmpty { let candidate = (localResolver(path) ?? URL(fileURLWithPath: path)).standardizedFileURL.resolvingSymlinksInPath().path; guard candidate != rootURL.path, !candidate.hasPrefix(rootURL.path + "/") else { throw CodexInstallationError(.busy) } }
            guard Set(try context.root.list()).isSubset(of: [Self.ownerName, "active.json", "versions", ".installation.lock", ".leases.lock"]) else { throw CodexInstallationError(.ownershipLost) }
            var owned: [CodexInstallDirectory] = []
            for name in try context.versions.list() {
                let folder = try CodexInstallDirectory(child: name, parent: context.versions)
                if name.hasPrefix(".install-"), let id = UUID(uuidString: String(name.dropFirst(9))) { let attempt = try folder.read(Attempt.self, ".attempt.json"); guard attempt.rootID == context.ownerID, attempt.operationID == id else { throw CodexInstallationError(.ownershipLost) } }
                else {
                    let complete = try folder.read(Complete.self, CodexPackageInventory.completion); guard complete.rootID == context.ownerID, complete.release.sha256 == name else { throw CodexInstallationError(.ownershipLost) }
                    let inventory = try folder.readInventory(proof: complete.inventory); try inventory.validateForRemoval(folder)
                }; owned.append(folder)
            }
            try validateOwner(context); for folder in owned { try context.versions.remove(folder) }; try context.root.removeEmpty(context.versions)
            for name in ["active.json", Self.ownerName, ".installation.lock", ".leases.lock"] { if unlinkat(context.root.fd, name, 0) != 0 && errno != ENOENT { throw CodexInstallationError(.ownershipLost) } }
            let parent = try CodexInstallDirectory(rootURL.deletingLastPathComponent()); try parent.removeEmpty(context.root)
            current = .init(totalBytes: release?.archiveBytes, version: release?.version); publish()
        } }
    }
}
