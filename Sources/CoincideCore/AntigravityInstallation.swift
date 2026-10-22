import Darwin
import Foundation

public struct AntigravityInstallationError: Error, Sendable, Equatable, LocalizedError {
    public enum Kind: String, Sendable {
        case invalidConfiguration, unavailable, invalidRecord, ownershipLost, busy, staleOperation, insufficientDiskSpace
        case downloadFailed, extractFailed, verificationFailed, publicationFailed, cancelled, closed
    }
    public let kind: Kind
    public init(_ kind: Kind) { self.kind = kind }
    public var errorDescription: String? {
        switch kind {
        case .invalidConfiguration: "The Antigravity runtime selection is invalid."
        case .unavailable: "The selected Antigravity server and harness are unavailable for this platform."
        case .invalidRecord: "The managed Antigravity runtime is incomplete or changed. Review its installation before continuing."
        case .ownershipLost: "The managed runtime folder changed. Existing files were preserved."
        case .busy: "Stop Antigravity sessions and sign-in flows before removing its managed runtime. Another installation may also be running."
        case .staleOperation: "This installation is no longer current. Refresh its status before cancelling."
        case .insufficientDiskSpace: "There is not enough verified free space to install Antigravity."
        case .downloadFailed: "The Antigravity download could not be verified. The previous runtime remains selected."
        case .extractFailed: "The Antigravity archive could not be safely extracted. The previous runtime remains selected."
        case .verificationFailed: "The downloaded runtime did not verify as the expected Antigravity release."
        case .publicationFailed: "The Antigravity runtime could not be activated. The previous runtime remains selected."
        case .cancelled: "Installation cancelled. The previous runtime remains selected."
        case .closed: "The Antigravity installation service is closed."
        }
    }
}

public enum AntigravityInstallationPhase: String, Codable, Sendable {
    case idle, downloading, extracting, verifying, succeeded, failed, cancelled
    public var isWorking: Bool { self == .downloading || self == .extracting || self == .verifying }
}
public struct AntigravityInstallationState: Sendable, Equatable {
    public var operationID: UUID?
    public var phase: AntigravityInstallationPhase
    public var downloadedBytes: Int64
    public var totalBytes: Int64?
    public var version: String?
    public var installedVersion: String?
    public var canRemove: Bool
    public var message: String?
    public init(operationID: UUID? = nil, phase: AntigravityInstallationPhase = .idle, downloadedBytes: Int64 = 0,
                totalBytes: Int64? = nil, version: String? = nil, installedVersion: String? = nil,
                canRemove: Bool = false, message: String? = nil) {
        self.operationID = operationID; self.phase = phase; self.downloadedBytes = downloadedBytes
        self.totalBytes = totalBytes; self.version = version; self.installedVersion = installedVersion
        self.canRemove = canRemove; self.message = message
    }
}

/// A binary lease lasts through native process and pipe drain, not the first RPC.
public final class AntigravityInstallationLease: @unchecked Sendable {
    public let pair: AntigravityExecutablePair
    public let releaseID: String?
    private let lock = NSLock()
    private var cleanup: (@Sendable () -> Void)?
    init(pair: AntigravityExecutablePair, releaseID: String?, cleanup: @escaping @Sendable () -> Void = {}) {
        self.pair = pair; self.releaseID = releaseID; self.cleanup = cleanup
    }
    public func release() { let action = lock.withLock { let value = cleanup; cleanup = nil; return value }; action?() }
    deinit { release() }
}

/// Synchronous resolution fits the provider factory. Background installation
/// owns immutable staging; only activation/removal/acquisition share the lock.
public final class AntigravityInstallation: @unchecked Sendable {
    public typealias Downloader = @Sendable (AntigravityManagedRelease, URL, @escaping @Sendable (Int64) -> Void) async throws -> Void
    public typealias Extractor = @Sendable (AntigravityManagedRelease, URL, URL) async throws -> Void
    public typealias Verifier = @Sendable (AntigravityManagedRelease, AntigravityExecutablePair, URL) async throws -> Void
    public typealias DiskSpace = @Sendable (URL) throws -> Int64
    public static let shared = AntigravityInstallation()
    public static var defaultRoot: URL {
        FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support/Coincide/Tools/Antigravity", isDirectory: true)
    }
    public let rootURL: URL
    private let release: AntigravityManagedRelease?
    private let downloader: Downloader, extractor: Extractor, verifier: Verifier, diskSpace: DiskSpace
    private let lock = NSLock()
    private var current: AntigravityInstallationState
    private var observers: [UUID: AsyncStream<AntigravityInstallationState>.Continuation] = [:]
    private var running: (id: UUID, task: Task<Void, Never>)?
    private var leases: [String: Int] = [:]
    private var closed = false
    private static let ownerName = ".coincide-antigravity-installation.json"
    private static let completeName = ".install-complete.json"
    private struct Owner: Codable { let format: Int; let id: UUID }
    private struct Active: Codable { let releaseID: String }
    private struct Attempt: Codable { let rootID: UUID; let operationID: UUID }
    private struct Complete: Codable {
        let rootID: UUID
        let release: AntigravityManagedRelease
        let server: AntigravityInstalledFile
        let harness: AntigravityInstalledFile
    }
    private struct Context: Sendable {
        let root: AntigravityInstallDirectory
        let versions: AntigravityInstallDirectory
        let ownerID: UUID
        let ownerProof: AntigravityInstalledFile
    }

    public init(rootURL: URL = AntigravityInstallation.defaultRoot, release: AntigravityManagedRelease? = .current,
                downloader: @escaping Downloader = { try await AntigravityArchiveDownloader.download(release: $0, to: $1, progress: $2) },
                extractor: @escaping Extractor = { try await AntigravityArchiveExtractor.extract(release: $0, archive: $1, to: $2) },
                verifier: @escaping Verifier = { try await AntigravityInstallationVerifier.verify(release: $0, pair: $1, scratch: $2) },
                diskSpace: @escaping DiskSpace = { url in
                    let attributes = try FileManager.default.attributesOfFileSystem(forPath: url.path)
                    guard let bytes = attributes[.systemFreeSize] as? NSNumber else { throw AntigravityInstallationError(.insufficientDiskSpace) }
                    return bytes.int64Value
                }) {
        self.rootURL = rootURL.standardizedFileURL.resolvingSymlinksInPath(); self.release = release
        self.downloader = downloader; self.extractor = extractor; self.verifier = verifier; self.diskSpace = diskSpace
        current = .init(totalBytes: release?.archiveBytes, version: release?.version)
        if FileManager.default.fileExists(atPath: self.rootURL.path) {
            do {
                let context = try self.context(create: false); current.canRemove = true
                if try context.root.exists("active.json") {
                    let active = try context.root.read(Active.self, "active.json")
                    let completed = try completed(active.releaseID, context: context)
                    current.installedVersion = completed.0.release.version
                }
            } catch { current.phase = .failed; current.message = AntigravityInstallationError(.invalidRecord).localizedDescription }
        }
    }
    public func state() -> AntigravityInstallationState { lock.withLock { current } }
    public func updates() -> AsyncStream<AntigravityInstallationState> {
        let id = UUID(), pair = AsyncStream<AntigravityInstallationState>.makeStream(bufferingPolicy: .bufferingNewest(1))
        pair.continuation.onTermination = { [weak self] _ in Task { self?.removeObserver(id) } }
        lock.withLock { if closed { pair.continuation.finish() } else { observers[id] = pair.continuation; pair.continuation.yield(current) } }
        return pair.stream
    }
    private func removeObserver(_ id: UUID) { lock.withLock { _ = observers.removeValue(forKey: id) } }
    private func publish() { for observer in observers.values { observer.yield(current) } }

    public func resolve(configuration: AntigravityConfiguration) throws -> AntigravityExecutablePair {
        do { return try lock.withLock { try resolved(configuration).pair } }
        catch let error as AntigravityInstallationError { throw error }
        catch { throw AntigravityInstallationError(.invalidRecord) }
    }
    public func acquire(configuration: AntigravityConfiguration) throws -> AntigravityInstallationLease {
        do {
            return try lock.withLock {
                let value = try resolved(configuration)
                return try makeLease(pair: value.pair, releaseID: value.releaseID, context: value.context)
            }
        } catch let error as AntigravityInstallationError { throw error }
        catch { throw AntigravityInstallationError(.invalidRecord) }
    }
    private func makeLease(pair: AntigravityExecutablePair, releaseID: String?, context: Context?) throws -> AntigravityInstallationLease {
        guard let releaseID, let context else { return .init(pair: pair, releaseID: nil) }
        let fileLock = try AntigravityInstallationLock(context.root, name: ".leases.lock", shared: true)
        leases[releaseID, default: 0] += 1
        return .init(pair: pair, releaseID: releaseID) { [weak self] in
            fileLock.release()
            self?.lock.withLock {
                guard let self else { return }
                if let count = self.leases[releaseID], count > 1 { self.leases[releaseID] = count - 1 }
                else { self.leases.removeValue(forKey: releaseID) }
            }
        }
    }
    private func resolved(_ configuration: AntigravityConfiguration) throws -> (pair: AntigravityExecutablePair, releaseID: String?, context: Context?) {
        do { try configuration.validate() } catch { throw AntigravityInstallationError(.invalidConfiguration) }
        guard !closed else { throw AntigravityInstallationError(.closed) }
        if configuration.runtimeSelection == .managed {
            guard FileManager.default.fileExists(atPath: rootURL.path) else { throw AntigravityInstallationError(.unavailable) }
            let context = try context(create: false), active = try context.root.read(Active.self, "active.json")
            return (try completed(active.releaseID, context: context).1, active.releaseID, context)
        }
        guard let selected = ProcessChannel.findExecutable(configuration.executable) else { throw AntigravityInstallationError(.unavailable) }
        let server = selected.standardizedFileURL.resolvingSymlinksInPath()
        let harnessSelection = configuration.harnessPath.map { $0.hasPrefix("/") ? URL(fileURLWithPath: $0) : selected.deletingLastPathComponent().appendingPathComponent($0) }
            ?? selected.deletingLastPathComponent().appendingPathComponent("localharness_external")
        let harness = harnessSelection.standardizedFileURL.resolvingSymlinksInPath()
        for file in [server, harness] {
            var info = stat()
            guard lstat(file.path, &info) == 0, info.st_mode & S_IFMT == S_IFREG, info.st_mode & 0o111 != 0,
                  access(file.path, X_OK) == 0 else { throw AntigravityInstallationError(.unavailable) }
        }
        guard server != harness else { throw AntigravityInstallationError(.invalidConfiguration) }
        let pair = AntigravityExecutablePair(executable: server, harness: harness)
        if [server, harness].contains(where: { $0.path.hasPrefix(rootURL.path + "/") }) {
            let context = try context(create: false), directory = server.deletingLastPathComponent()
            guard directory.deletingLastPathComponent() == context.versions.url else { throw AntigravityInstallationError(.invalidRecord) }
            let id = directory.lastPathComponent, ready = try completed(id, context: context)
            guard ready.1.executable == server, ready.1.harness == harness else { throw AntigravityInstallationError(.invalidRecord) }
            return (pair, id, context)
        }
        return (pair, nil, nil)
    }

    @discardableResult public func start() throws -> UUID {
        do { return try lock.withLock {
            guard !closed else { throw AntigravityInstallationError(.closed) }
            if let running { return running.id }
            try Task.checkCancellation()
            guard let release else { throw AntigravityInstallationError(.unavailable) }; try release.validate()
            let context = try context(create: true)
            let operationLock = try AntigravityInstallationLock(context.root, name: ".installation.lock", shared: false)
            let id = UUID()
            current.operationID = id; current.phase = .downloading; current.downloadedBytes = 0
            current.totalBytes = release.archiveBytes; current.version = release.version; current.canRemove = true; current.message = nil
            let task = Task { [weak self] in
                guard let self else { operationLock.release(); return }
                await self.install(id, release: release, context: context)
                operationLock.release()
                self.finished(id)
            }
            running = (id, task); publish(); return id
        } } catch let error as AntigravityInstallationError { throw error }
        catch is CancellationError { throw AntigravityInstallationError(.cancelled) }
        catch { throw AntigravityInstallationError(.ownershipLost) }
    }
    public func cancel(operationID: UUID) async throws {
        let task: Task<Void, Never>? = try lock.withLock {
            guard current.operationID == operationID else { throw AntigravityInstallationError(.staleOperation) }
            guard let running, running.id == operationID else { return nil }
            if current.phase.isWorking { running.task.cancel() }; return running.task
        }
        await task?.value
    }
    public func shutdown() async {
        let task = lock.withLock { closed = true; running?.task.cancel(); return running?.task }
        await task?.value
        let streams = lock.withLock { let value = Array(observers.values); observers.removeAll(); return value }
        for stream in streams { stream.finish() }
    }
    private func finished(_ id: UUID) { lock.withLock { if running?.id == id { running = nil } } }
    private func progress(_ id: UUID, bytes: Int64, limit: Int64) {
        lock.withLock {
            guard current.operationID == id, current.phase == .downloading, bytes >= current.downloadedBytes, bytes <= limit else { return }
            current.downloadedBytes = bytes; publish()
        }
    }
    private func phase(_ id: UUID, _ phase: AntigravityInstallationPhase) {
        lock.withLock { guard current.operationID == id else { return }; current.phase = phase; publish() }
    }

    private func install(_ id: UUID, release: AntigravityManagedRelease, context: Context) async {
        var stage: AntigravityInstallDirectory?, installedLease: AntigravityInstallationLease?
        var failure: AntigravityInstallationError?
        do {
            try Task.checkCancellation(); try validateOwner(context); try context.versions.validate()
            let staging = try context.versions.create(".install-" + id.uuidString.lowercased()); stage = staging
            try staging.write(Attempt(rootID: context.ownerID, operationID: id), ".attempt.json")
            let scratch = try staging.create("verification")
            if try context.versions.exists(release.sha256) {
                let ready = try lock.withLock { try completed(release.sha256, context: context) }
                guard ready.0.release == release else { throw AntigravityInstallationError(.invalidRecord) }
                installedLease = try lock.withLock { try makeLease(pair: ready.1, releaseID: release.sha256, context: context) }
                phase(id, .verifying)
                do { try await verifier(release, ready.1, scratch.url) } catch is CancellationError { throw CancellationError() }
                catch { throw AntigravityInstallationError(.verificationFailed) }
                try Task.checkCancellation()
                try lock.withLock { _ = try completed(release.sha256, context: context); try activate(id, release: release, context: context) }
            } else {
                guard try diskSpace(context.versions.url) >= release.requiredFreeBytes else { throw AntigravityInstallationError(.insufficientDiskSpace) }
                let archive = staging.url.appendingPathComponent("download.zip")
                do { try await downloader(release, archive) { [weak self] in self?.progress(id, bytes: $0, limit: release.archiveBytes) } }
                catch is CancellationError { throw CancellationError() }
                catch { throw AntigravityInstallationError(.downloadFailed) }
                try Task.checkCancellation()
                let archiveProof: AntigravityInstalledFile
                do { archiveProof = try staging.installedFile("download.zip", bytes: release.archiveBytes, seal: true, executable: false) }
                catch is CancellationError { throw CancellationError() }
                catch { throw AntigravityInstallationError(.downloadFailed) }
                guard archiveProof.digest == release.sha256 else { throw AntigravityInstallationError(.downloadFailed) }
                phase(id, .extracting); let pairDirectory = try staging.create("runtime")
                do { try await extractor(release, archive, pairDirectory.url) } catch is CancellationError { throw CancellationError() }
                catch { throw AntigravityInstallationError(.extractFailed) }
                try Task.checkCancellation(); try staging.validate(); try pairDirectory.validate()
                guard Set(try pairDirectory.list()) == [release.serverName, release.harnessName] else { throw AntigravityInstallationError(.extractFailed) }
                let pair = AntigravityExecutablePair(executable: pairDirectory.url.appendingPathComponent(release.serverName), harness: pairDirectory.url.appendingPathComponent(release.harnessName))
                phase(id, .verifying)
                do { try await verifier(release, pair, scratch.url) } catch is CancellationError { throw CancellationError() }
                catch { throw AntigravityInstallationError(.verificationFailed) }
                try Task.checkCancellation()
                let server = try pairDirectory.installedFile(release.serverName, bytes: release.serverBytes, seal: true)
                let harness = try pairDirectory.installedFile(release.harnessName, bytes: release.harnessBytes, seal: true)
                try pairDirectory.write(Complete(rootID: context.ownerID, release: release, server: server, harness: harness), Self.completeName)
                try lock.withLock {
                    try Task.checkCancellation(); try validateOwner(context)
                    try context.versions.publish(pairDirectory, from: staging, as: release.sha256)
                    _ = try completed(release.sha256, context: context)
                    try activate(id, release: release, context: context)
                }
            }
        } catch is CancellationError { failure = .init(.cancelled) }
        catch let error as AntigravityInstallationError { failure = Task.isCancelled ? .init(.cancelled) : error }
        catch { failure = Task.isCancelled ? .init(.cancelled) : .init(.publicationFailed) }
        installedLease?.release()
        if let stage { try? context.versions.remove(stage) }
        if let failure {
            lock.withLock {
                // A committed pointer is never rolled back by cancellation or
                // later cleanup; previous/successor operation state is untouched.
                guard current.operationID == id, current.phase != .succeeded else { return }
                current.phase = failure.kind == .cancelled ? .cancelled : .failed
                current.message = failure.localizedDescription; publish()
            }
        }
    }
    private func activate(_ id: UUID, release: AntigravityManagedRelease, context: Context) throws {
        guard current.operationID == id else { throw AntigravityInstallationError(.staleOperation) }
        try Task.checkCancellation(); try validateOwner(context)
        try context.root.replace(Active(releaseID: release.sha256), "active.json")
        current.phase = .succeeded; current.installedVersion = release.version; current.message = nil; publish()
    }

    private func context(create: Bool) throws -> Context {
        guard rootURL.isFileURL, rootURL.path != "/", rootURL.path.utf8.count <= 16_384 else { throw AntigravityInstallationError(.invalidConfiguration) }
        var created = false
        if create {
            try FileManager.default.createDirectory(at: rootURL.deletingLastPathComponent(), withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
            if mkdir(rootURL.path, 0o700) == 0 { created = true }
            else if errno != EEXIST { throw AntigravityInstallationError(.ownershipLost) }
        }
        let root = try AntigravityInstallDirectory(rootURL)
        if created { try root.write(Owner(format: 1, id: UUID()), Self.ownerName) }
        let owner = try root.readSealed(Owner.self, Self.ownerName)
        guard owner.value.format == 1 else { throw AntigravityInstallationError(.invalidRecord) }
        let versions: AntigravityInstallDirectory
        if created {
            versions = try root.create("versions")
            let installLock = try AntigravityInstallationLock(root, name: ".installation.lock", shared: false, create: true); installLock.release()
            let leaseLock = try AntigravityInstallationLock(root, name: ".leases.lock", shared: false, create: true); leaseLock.release()
        } else { versions = try .init(child: "versions", parent: root) }
        return .init(root: root, versions: versions, ownerID: owner.value.id, ownerProof: owner.proof)
    }
    private func validateOwner(_ context: Context) throws {
        do {
            _ = try context.root.installedFile(Self.ownerName, bytes: context.ownerProof.bytes, seal: false, proof: context.ownerProof, executable: false)
            let owner = try context.root.read(Owner.self, Self.ownerName)
            guard owner.format == 1, owner.id == context.ownerID else { throw AntigravityInstallationError(.ownershipLost) }
            _ = try context.root.installedFile(Self.ownerName, bytes: context.ownerProof.bytes, seal: false, proof: context.ownerProof, executable: false)
        } catch { throw AntigravityInstallationError(.ownershipLost) }
    }
    private func completed(_ id: String, context: Context) throws -> (Complete, AntigravityExecutablePair) {
        try validateOwner(context)
        guard id.count == 64, id.utf8.allSatisfy({ (48...57).contains($0) || (97...102).contains($0) }) else { throw AntigravityInstallationError(.invalidRecord) }
        let directory = try AntigravityInstallDirectory(child: id, parent: context.versions)
        let record = try directory.read(Complete.self, Self.completeName); try record.release.validate()
        guard record.rootID == context.ownerID, record.release.sha256 == id,
              Set(try directory.list()) == [record.release.serverName, record.release.harnessName, Self.completeName] else { throw AntigravityInstallationError(.invalidRecord) }
        _ = try directory.installedFile(record.release.serverName, bytes: record.release.serverBytes, seal: false, proof: record.server)
        _ = try directory.installedFile(record.release.harnessName, bytes: record.release.harnessBytes, seal: false, proof: record.harness)
        return (record, .init(executable: directory.url.appendingPathComponent(record.release.serverName), harness: directory.url.appendingPathComponent(record.release.harnessName)))
    }
    public func remove(protectedCustomPaths: [String] = []) throws {
        do { try lock.withLock {
            guard !closed else { throw AntigravityInstallationError(.closed) }
            guard running == nil, leases.isEmpty else { throw AntigravityInstallationError(.busy) }
            if !FileManager.default.fileExists(atPath: rootURL.path) { return }
            let context = try context(create: false)
            let operationLock = try AntigravityInstallationLock(context.root, name: ".installation.lock", shared: false)
            defer { operationLock.release() }
            let leaseLock = try AntigravityInstallationLock(context.root, name: ".leases.lock", shared: false)
            defer { leaseLock.release() }
            guard protectedCustomPaths.count <= 4_096 else { throw AntigravityInstallationError(.invalidConfiguration) }
            for path in protectedCustomPaths where !path.isEmpty {
                let selected = ProcessChannel.findExecutable(path) ?? URL(fileURLWithPath: path)
                let resolved = selected.standardizedFileURL.resolvingSymlinksInPath().path
                guard resolved != rootURL.path, !resolved.hasPrefix(rootURL.path + "/") else { throw AntigravityInstallationError(.busy) }
            }
            guard Set(try context.root.list()).isSubset(of: [Self.ownerName, "active.json", "versions", ".installation.lock", ".leases.lock"]) else { throw AntigravityInstallationError(.ownershipLost) }
            var owned: [AntigravityInstallDirectory] = []
            // Validate all ownership before deleting any release. Missing binary
            // members of an otherwise owned completion can be removed explicitly.
            for name in try context.versions.list() {
                let directory = try AntigravityInstallDirectory(child: name, parent: context.versions)
                if name.hasPrefix(".install-"), let id = UUID(uuidString: String(name.dropFirst(9))) {
                    let record = try directory.read(Attempt.self, ".attempt.json")
                    guard record.rootID == context.ownerID, record.operationID == id else { throw AntigravityInstallationError(.ownershipLost) }
                } else {
                    let record = try directory.read(Complete.self, Self.completeName); try record.release.validate()
                    guard record.rootID == context.ownerID, record.release.sha256 == name,
                          Set(try directory.list()).isSubset(of: [record.release.serverName, record.release.harnessName, Self.completeName]) else { throw AntigravityInstallationError(.ownershipLost) }
                }
                owned.append(directory)
            }
            try validateOwner(context)
            for directory in owned { try context.versions.remove(directory) }
            try context.root.removeEmpty(context.versions)
            for name in ["active.json", Self.ownerName, ".installation.lock", ".leases.lock"] { if unlinkat(context.root.fd, name, 0) != 0 && errno != ENOENT { throw AntigravityInstallationError(.ownershipLost) } }
            let parent = try AntigravityInstallDirectory(rootURL.deletingLastPathComponent())
            try parent.removeEmpty(context.root)
            current = .init(totalBytes: release?.archiveBytes, version: release?.version); publish()
        } } catch let error as AntigravityInstallationError { throw error }
        catch { throw AntigravityInstallationError(.ownershipLost) }
    }
}
