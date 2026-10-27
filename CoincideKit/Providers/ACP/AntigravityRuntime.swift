import CryptoKit
import Foundation
import Observation
import Security

/// An Antigravity executable and the harness it needs, ready to launch.
public struct AntigravityExecutable: Sendable, Hashable {
    public var executable: URL
    public var harness: URL
    /// The release version, for a runtime Coincide installed.
    public var version: String?
    /// The release folder, for a runtime Coincide installed.
    public var releaseDirectory: URL?

    public nonisolated init(executable: URL, harness: URL, version: String?, releaseDirectory: URL?) {
        self.executable = executable
        self.harness = harness
        self.version = version
        self.releaseDirectory = releaseDirectory
    }
}

/// Why an installation step failed. `message` is safe to show as it is.
public struct AntigravityInstallError: LocalizedError, Equatable {
    public var operation: String
    public var message: String

    public nonisolated init(_ operation: String, _ message: String) {
        self.operation = operation
        self.message = message
    }

    public nonisolated var errorDescription: String? { message }

    nonisolated static var incomplete: AntigravityInstallError {
        AntigravityInstallError(
            "resolve", String(localized: "The downloaded Antigravity runtime is incomplete. Remove it and install it again."))
    }
}

/// Where an installation stands, as T3 Code reports `ProviderInstallState`.
public struct AntigravityInstallState: Sendable, Hashable {
    public enum Phase: String, Sendable {
        case idle, downloading, extracting, verifying, succeeded, failed, cancelled
    }

    public var phase: Phase = .idle
    public var operationID: UUID?
    public var downloadedBytes: Int64 = 0
    public var totalBytes: Int64?
    /// The release Coincide installs.
    public var version: String?
    /// The release that is installed and active, if any.
    public var installedVersion: String?
    /// Whether there is a downloaded runtime (complete or not) to remove.
    public var canRemove = false
    public var message: String?

    public nonisolated init(
        phase: Phase = .idle, operationID: UUID? = nil, downloadedBytes: Int64 = 0, totalBytes: Int64? = nil,
        version: String? = nil, installedVersion: String? = nil, canRemove: Bool = false, message: String? = nil
    ) {
        self.phase = phase
        self.operationID = operationID
        self.downloadedBytes = downloadedBytes
        self.totalBytes = totalBytes
        self.version = version
        self.installedVersion = installedVersion
        self.canRemove = canRemove
        self.message = message
    }

    public nonisolated var isRunning: Bool { phase == .downloading || phase == .extracting || phase == .verifying }
    /// An older release is installed than the one this Coincide pins.
    public nonisolated var isUpdateAvailable: Bool {
        guard let installedVersion, let version else { return false }
        return installedVersion != version
    }
}

/// Receives a download as it streams. Calls arrive one at a time and in order.
public protocol AntigravityDownloadSink: AnyObject, Sendable {
    func receive(response: HTTPURLResponse) throws
    func receive(_ data: Data) throws
}

/// Fetches `url` into a sink; throwing from the sink stops the download.
public typealias AntigravityDownloader = @Sendable (_ url: URL, _ sink: AntigravityDownloadSink) async throws -> Void

/// What an installation reports while it runs.
enum AntigravityInstallProgress: Sendable, Hashable {
    case downloaded(Int64)
    case extracting
    case verifying
}

// MARK: - Runtime manager

/// Installs, checks and removes the Antigravity runtime Coincide downloads from Google, as T3 Code's
/// `AntigravityInstallation` does: one pinned release, downloaded straight from Google, checked
/// against its pinned size and SHA-256 before anything is unpacked, unpacked under Coincide's data
/// folder, started once to check it is the expected release, and only then made active. Each file is
/// also checked against its pinned SHA-256 and Google's Developer ID signature before it first runs.
/// Anything that fails leaves the previous runtime as it was.
///
/// Sessions and sign-in hold a lease on the release they run from, so it is never removed under them.
@MainActor
@Observable
public final class AntigravityRuntime {
    public static let shared = AntigravityRuntime()

    public let paths: AntigravityPaths
    /// The release this Mac gets, or nil when Google publishes none for its architecture.
    public let asset: AntigravityReleaseAsset?
    public private(set) var state: AntigravityInstallState
    /// Launches that run from a downloaded release right now.
    public private(set) var leaseCount = 0

    @ObservationIgnored private let installer: AntigravityInstaller
    @ObservationIgnored private var task: Task<Void, Never>?
    @ObservationIgnored private var cancelledOperation: UUID?
    @ObservationIgnored private var leases: [String: Int] = [:]

    public convenience init(paths: AntigravityPaths = .standard) {
        self.init(paths: paths, asset: AntigravityRelease.asset(architecture: paths.architecture))
    }

    public init(
        paths: AntigravityPaths, asset: AntigravityReleaseAsset?,
        download: @escaping AntigravityDownloader = AntigravityDownload.urlSession,
        verifySignature: @escaping @Sendable (URL, String) throws -> Void = AntigravityInstaller.verifyCodeSignature,
        validate: (@Sendable (AntigravityExecutable, String) async throws -> Void)? = nil,
        freeSpace: @escaping @Sendable (URL) -> Int64? = AntigravityInstaller.availableSpace
    ) {
        self.paths = paths
        self.asset = asset
        installer = AntigravityInstaller(
            paths: paths, download: download, verifySignature: verifySignature,
            validate: validate ?? { try await AntigravityValidation.check($0, version: $1) }, freeSpace: freeSpace)
        state = AntigravityInstallState(totalBytes: asset?.archiveBytes, version: asset?.version)
        refresh()
        let installer = installer
        DispatchQueue.global(qos: .utility).async { installer.removeLeftovers(olderThan: 6 * 60 * 60) }
    }

    /// The active downloaded release, after checking its record and files; nil when none is installed.
    public func activeRelease() throws -> AntigravityExecutable? {
        try installer.activeRelease()
    }

    /// Reads the installed release again (after something outside changed it).
    public func refresh() {
        guard !state.isRunning else { return }
        state.canRemove = FileManager.default.fileExists(atPath: paths.managedDirectory.path)
        do {
            state.installedVersion = try installer.activeRelease()?.version
            if state.phase == .failed, state.message == AntigravityInstallError.incomplete.message {
                state.phase = .idle
                state.message = nil
            }
        } catch {
            state.installedVersion = nil
            state.phase = .failed
            state.message = AntigravityInstallError.incomplete.message
        }
    }

    /// Starts installing (or updating to) the pinned release. Progress shows in `state`.
    public func install() {
        guard !state.isRunning else { return }
        guard let asset else {
            state.phase = .failed
            state.message = String(
                localized:
                    "Google doesn’t publish an Antigravity runtime for this Mac (\(AntigravityRelease.platformKey(architecture: paths.architecture))). Choose your own executable instead."
            )
            return
        }
        let operation = UUID()
        cancelledOperation = nil
        state = AntigravityInstallState(
            phase: .downloading, operationID: operation, totalBytes: asset.archiveBytes, version: asset.version,
            installedVersion: state.installedVersion, canRemove: true,
            message: String(localized: "Downloading Google’s official Antigravity runtime."))
        let installer = installer
        task = Task {
            let report: @Sendable (AntigravityInstallProgress) -> Void = { progress in
                DispatchQueue.main.async { MainActor.assumeIsolated { self.apply(progress, operation: operation) } }
            }
            let outcome: InstallOutcome
            do {
                outcome = .installed(try await installer.install(asset, progress: report))
            } catch is CancellationError {
                outcome = .cancelled
            } catch let error as AntigravityInstallError {
                outcome = .failed(error.message)
            } catch {
                outcome = .failed(String(localized: "Couldn’t install Antigravity. Check free disk space and folder access, then try again."))
            }
            // Queued behind the progress already reported, so no progress can follow the outcome.
            DispatchQueue.main.async { MainActor.assumeIsolated { self.finish(operation, asset: asset, outcome: outcome) } }
        }
    }

    /// Stops a running installation. The previous runtime stays as it was.
    public func cancel() {
        guard state.isRunning, let operation = state.operationID else { return }
        cancelledOperation = operation
        task?.cancel()
    }

    /// Deletes the downloaded runtime. The private Google profile (sign-in and history) is kept.
    /// Refused while it runs or installs, or while a custom path in `protectedPaths` points into it.
    public func remove(protecting protectedPaths: [String] = []) throws {
        guard !state.isRunning, leases.isEmpty else {
            throw AntigravityInstallError(
                "remove", String(localized: "Stop Antigravity sessions and sign-in before removing the downloaded runtime."))
        }
        for path in protectedPaths.map({ $0.trimmingCharacters(in: .whitespacesAndNewlines) }) where !path.isEmpty {
            if paths.isManaged(URL(fileURLWithPath: (path as NSString).expandingTildeInPath)) {
                throw AntigravityInstallError(
                    "remove",
                    String(localized: "Your custom Antigravity path points into the downloaded runtime. Clear it before removing the runtime."))
            }
        }
        do {
            if FileManager.default.fileExists(atPath: paths.managedDirectory.path) {
                try FileManager.default.removeItem(at: paths.managedDirectory)
            }
        } catch {
            refresh()
            throw AntigravityInstallError(
                "remove", String(localized: "Couldn’t remove the downloaded Antigravity runtime. Check for open processes and try again."))
        }
        state = AntigravityInstallState(totalBytes: asset?.archiveBytes, version: asset?.version)
    }

    /// Keeps the downloaded release `executable` runs from until the lease is released. Nil for an
    /// executable outside the downloaded runtime.
    public func lease(for executable: URL) -> ACPLaunchLease? {
        guard paths.isManaged(executable) else { return nil }
        let key = (AntigravityPaths.canonicalPath(executable) as NSString).deletingLastPathComponent
        leases[key, default: 0] += 1
        leaseCount += 1
        return ACPLaunchLease { [weak self] in
            guard let self else { return }
            self.leaseCount -= 1
            let remaining = (self.leases[key] ?? 1) - 1
            self.leases[key] = remaining > 0 ? remaining : nil
        }
    }

    private func apply(_ progress: AntigravityInstallProgress, operation: UUID) {
        guard state.operationID == operation, state.isRunning else { return }
        switch progress {
        case .downloaded(let bytes):
            state.downloadedBytes = bytes
        case .extracting:
            state.phase = .extracting
            state.message = String(localized: "Extracting the verified runtime.")
        case .verifying:
            state.phase = .verifying
            state.message = String(localized: "Checking the downloaded runtime.")
        }
    }

    private enum InstallOutcome: Sendable {
        case installed(AntigravityExecutable)
        case cancelled
        case failed(String)
    }

    private func finish(_ operation: UUID, asset: AntigravityReleaseAsset, outcome: InstallOutcome) {
        guard state.operationID == operation else { return }
        task = nil
        state.canRemove = FileManager.default.fileExists(atPath: paths.managedDirectory.path)
        let cancelled = cancelledOperation == operation
        cancelledOperation = nil
        switch outcome {
        case .installed(let installed):
            // An installation that finished just as it was cancelled is reported as installed.
            state.phase = .succeeded
            state.installedVersion = installed.version ?? asset.version
            state.downloadedBytes = asset.archiveBytes
            state.message = nil
            let inUse = Set(leases.keys)
            let installer = installer
            DispatchQueue.global(qos: .utility).async { installer.pruneReleases(keeping: asset.sha256, inUse: inUse) }
        case .failed(let message) where !cancelled:
            state.phase = .failed
            state.message = message
        case .cancelled, .failed:
            state.phase = .cancelled
            state.message = String(localized: "Installation cancelled. The previous runtime is unchanged.")
        }
    }
}

// MARK: - Installer

/// The installation steps, off the main actor. Every dependency that reaches outside (network, code
/// signing, starting the agent, free space) is injected so tests can replace it.
public struct AntigravityInstaller: Sendable {
    nonisolated static let recordName = ".install-complete.json"
    private nonisolated static let recordMaxBytes = 8 * 1_024
    private nonisolated static let validationTimeout: TimeInterval = 90

    var paths: AntigravityPaths
    var download: AntigravityDownloader
    var verifySignature: @Sendable (URL, String) throws -> Void
    var validate: @Sendable (AntigravityExecutable, String) async throws -> Void
    var freeSpace: @Sendable (URL) -> Int64?

    nonisolated init(
        paths: AntigravityPaths, download: @escaping AntigravityDownloader = AntigravityDownload.urlSession,
        verifySignature: @escaping @Sendable (URL, String) throws -> Void = AntigravityInstaller.verifyCodeSignature,
        validate: @escaping @Sendable (AntigravityExecutable, String) async throws -> Void = {
            try await AntigravityValidation.check($0, version: $1)
        },
        freeSpace: @escaping @Sendable (URL) -> Int64? = AntigravityInstaller.availableSpace
    ) {
        self.paths = paths
        self.download = download
        self.verifySignature = verifySignature
        self.validate = validate
        self.freeSpace = freeSpace
    }

    /// What the release folder's record says; written last, so a folder without it is incomplete.
    struct Record: Codable, Equatable {
        struct File: Codable, Equatable {
            var name: String
            var bytes: Int64
            var sha256: String
        }

        var releaseId: String
        var version: String
        var executable: File
        var harness: File
    }

    // MARK: Installing

    nonisolated func install(
        _ asset: AntigravityReleaseAsset, progress: @escaping @Sendable (AntigravityInstallProgress) -> Void
    ) async throws -> AntigravityExecutable {
        let manager = FileManager.default
        do {
            try manager.createDirectory(at: paths.versionsDirectory, withIntermediateDirectories: true)
        } catch {
            throw AntigravityInstallError("install", String(localized: "Couldn’t create Antigravity’s folder in Coincide’s data folder."))
        }
        let destination = paths.versionsDirectory.appendingPathComponent(asset.sha256, isDirectory: true)
        if manager.fileExists(atPath: destination.path) {
            // The release was unpacked before (a reinstall, or an install another window finished).
            let existing = try completedRelease(asset.sha256)
            guard existing.version == asset.version else {
                throw AntigravityInstallError(
                    "verify", String(localized: "The downloaded release has the wrong version. Remove it before installing again."))
            }
            progress(.verifying)
            try await Self.blocking { isCancelled in
                for file in asset.files {
                    try verifyFile(destination.appendingPathComponent(file.name), file, isCancelled: isCancelled)
                }
            }
            try await validated(existing, version: asset.version)
            try activate(asset.sha256)
            return existing
        }

        if let available = freeSpace(paths.versionsDirectory), available < asset.requiredFreeSpace {
            let megabytes = (asset.requiredFreeSpace + 1_048_575) / 1_048_576
            throw AntigravityInstallError(
                "download", String(localized: "Antigravity needs at least \(megabytes) MB of free space to install."))
        }
        let staging = paths.versionsDirectory.appendingPathComponent(".install-\(UUID().uuidString)", isDirectory: true)
        let runtime = staging.appendingPathComponent("runtime", isDirectory: true)
        do {
            try manager.createDirectory(at: runtime, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        } catch {
            throw AntigravityInstallError("install", String(localized: "Couldn’t create Antigravity’s folder in Coincide’s data folder."))
        }
        defer { try? manager.removeItem(at: staging) }

        let archive = staging.appendingPathComponent("download.zip")
        let sink = try AntigravityArchiveSink(file: archive, asset: asset, progress: progress)
        do {
            try await download(asset.url, sink)
        } catch {
            sink.close()
            if Task.isCancelled { throw CancellationError() }
            if let error = error as? AntigravityInstallError { throw error }
            throw AntigravityInstallError(
                "download", String(localized: "Couldn’t download Antigravity from Google. Check your internet connection and try again."))
        }
        try sink.finish()

        progress(.extracting)
        try await Self.blocking { isCancelled in try extract(archive, into: runtime, asset: asset, isCancelled: isCancelled) }
        try? manager.removeItem(at: archive)
        for file in asset.files {
            guard chmod(runtime.appendingPathComponent(file.name).path, 0o755) == 0 else {
                throw AntigravityInstallError("extract", String(localized: "Couldn’t extract the Antigravity runtime."))
            }
        }

        progress(.verifying)
        try await Self.blocking { _ in
            for file in asset.files { try verifySignature(runtime.appendingPathComponent(file.name), AntigravityRelease.signingRequirement(for: file)) }
        }
        let candidate = AntigravityExecutable(
            executable: runtime.appendingPathComponent(asset.executable.name), harness: runtime.appendingPathComponent(asset.harness.name),
            version: asset.version, releaseDirectory: runtime)
        try await validated(candidate, version: asset.version)

        let record = Record(
            releaseId: asset.sha256, version: asset.version,
            executable: .init(name: asset.executable.name, bytes: asset.executable.bytes, sha256: asset.executable.sha256),
            harness: .init(name: asset.harness.name, bytes: asset.harness.bytes, sha256: asset.harness.sha256))
        let recordData = try JSONEncoder().encode(record)
        guard manager.createFile(atPath: runtime.appendingPathComponent(Self.recordName).path, contents: recordData, attributes: [.posixPermissions: 0o600])
        else { throw AntigravityInstallError("install", String(localized: "Couldn’t record the Antigravity installation.")) }

        if rename(runtime.path, destination.path) != 0 {
            // Another installation published the same release meanwhile; use it if it is complete.
            guard let existing = try? completedRelease(asset.sha256), existing.version == asset.version else {
                throw AntigravityInstallError(
                    "activate", String(localized: "Couldn’t publish the Antigravity runtime. The previous release is unchanged. Try again."))
            }
            try await validated(existing, version: asset.version)
        }
        try activate(asset.sha256)
        return try completedRelease(asset.sha256)
    }

    /// Unpacks exactly the two pinned files, refusing anything unexpected (T3 Code's checks), and
    /// checks each file's SHA-256 as it is written.
    nonisolated func extract(_ archive: URL, into directory: URL, asset: AntigravityReleaseAsset, isCancelled: () -> Bool) throws {
        let zip: AntigravityZip
        do {
            zip = try AntigravityZip(url: archive)
        } catch {
            throw AntigravityInstallError("extract", String(localized: "Couldn’t open the verified archive."))
        }
        guard zip.entries.count == asset.files.count else {
            throw AntigravityInstallError(
                "extract", String(localized: "The archive must contain exactly the Antigravity executable and its harness."))
        }
        var seen = Set<String>()
        for entry in zip.entries {
            guard let expected = asset.files.first(where: { $0.name == entry.name }), !seen.contains(entry.name),
                !entry.name.contains("/"), !entry.name.contains("\\"),
                entry.unixFileType == 0 || entry.unixFileType == 0o100000, !entry.isDOSDirectory, !entry.isEncrypted,
                entry.method == 0 || entry.method == 8, entry.uncompressedSize == UInt64(expected.bytes)
            else {
                throw AntigravityInstallError(
                    "extract", String(localized: "The archive contains an unexpected, unsafe, or incorrectly sized member."))
            }
            seen.insert(entry.name)
            let target = directory.appendingPathComponent(entry.name)
            let descriptor = open(target.path, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, 0o700)
            guard descriptor >= 0 else {
                throw AntigravityInstallError("extract", String(localized: "Couldn’t extract the Antigravity runtime."))
            }
            let handle = FileHandle(fileDescriptor: descriptor, closeOnDealloc: true)
            var hasher = SHA256()
            do {
                try zip.extract(entry, isCancelled: isCancelled) { data in
                    hasher.update(data: data)
                    try handle.write(contentsOf: data)
                }
                try handle.close()
            } catch is CancellationError {
                throw CancellationError()
            } catch let failure as AntigravityZip.Failure {
                throw AntigravityInstallError(
                    "extract",
                    failure.reason == "member is larger than recorded"
                        ? String(localized: "An archive member exceeded its pinned size.")
                        : failure.reason == "member is smaller than recorded" || failure.reason == "member data is truncated"
                            ? String(localized: "An archive member was truncated.")
                            : String(localized: "The archive is damaged. Nothing was installed."))
            } catch {
                throw AntigravityInstallError(
                    "extract", String(localized: "Couldn’t extract the Antigravity runtime. Check free disk space and try again."))
            }
            guard Self.hex(hasher.finalize()) == expected.sha256 else {
                throw AntigravityInstallError(
                    "verify", String(localized: "An extracted Antigravity file failed its SHA-256 check. Nothing was installed."))
            }
        }
        guard seen == Set(asset.files.map(\.name)) else {
            throw AntigravityInstallError(
                "extract", String(localized: "The archive is missing the Antigravity executable or its harness."))
        }
    }

    /// Checks a file on disk against its pinned SHA-256 and signature before it runs again.
    nonisolated func verifyFile(_ url: URL, _ file: AntigravityReleaseAsset.File, isCancelled: () -> Bool) throws {
        guard let digest = try? Self.sha256(of: url, isCancelled: isCancelled), digest == file.sha256 else {
            if isCancelled() { throw CancellationError() }
            throw AntigravityInstallError(
                "verify", String(localized: "A downloaded Antigravity file no longer matches its SHA-256. Remove the runtime and install it again."))
        }
        try verifySignature(url, AntigravityRelease.signingRequirement(for: file))
    }

    private nonisolated func validated(_ executable: AntigravityExecutable, version: String) async throws {
        let validate = validate
        try await Self.withTimeout(
            Self.validationTimeout,
            timeoutError: AntigravityInstallError(
                "verify", String(localized: "The downloaded Antigravity runtime didn’t answer in time. Try again."))
        ) { try await validate(executable, version) }
    }

    /// Points `current` at a release in one step, so a launch always sees a complete one.
    nonisolated func activate(_ releaseID: String) throws {
        let temporary = paths.managedDirectory.appendingPathComponent(".current-\(UUID().uuidString)")
        do {
            try FileManager.default.createSymbolicLink(atPath: temporary.path, withDestinationPath: "versions/" + releaseID)
        } catch {
            throw AntigravityInstallError(
                "activate", String(localized: "Couldn’t activate Antigravity. The previous runtime is unchanged. Try again."))
        }
        guard rename(temporary.path, paths.currentLink.path) == 0 else {
            try? FileManager.default.removeItem(at: temporary)
            throw AntigravityInstallError(
                "activate", String(localized: "Couldn’t activate Antigravity. The previous runtime is unchanged. Try again."))
        }
    }

    // MARK: Reading what is installed

    /// The release `current` points at, or nil when nothing is installed.
    nonisolated func activeRelease() throws -> AntigravityExecutable? {
        let link = paths.currentLink.path
        guard let destination = try? FileManager.default.destinationOfSymbolicLink(atPath: link) else {
            if (try? FileManager.default.attributesOfItem(atPath: link)) != nil { throw AntigravityInstallError.incomplete }
            return nil
        }
        guard destination.hasPrefix("versions/") else { throw AntigravityInstallError.incomplete }
        return try completedRelease(String(destination.dropFirst("versions/".count)))
    }

    /// A release folder whose record and files agree (T3 Code's `completedRelease`).
    nonisolated func completedRelease(_ releaseID: String) throws -> AntigravityExecutable {
        guard Self.isReleaseID(releaseID) else { throw AntigravityInstallError.incomplete }
        let directory = paths.versionsDirectory.appendingPathComponent(releaseID, isDirectory: true)
        let recordURL = directory.appendingPathComponent(Self.recordName)
        guard let attributes = try? FileManager.default.attributesOfItem(atPath: recordURL.path),
            attributes[.type] as? FileAttributeType == .typeRegular,
            (attributes[.size] as? NSNumber)?.intValue ?? .max <= Self.recordMaxBytes,
            let data = try? Data(contentsOf: recordURL), let record = try? JSONDecoder().decode(Record.self, from: data),
            record.releaseId == releaseID, record.executable.name == AntigravityRelease.executableName,
            record.harness.name == AntigravityRelease.harnessName, record.executable.bytes > 0, record.harness.bytes > 0,
            !record.version.trimmingCharacters(in: .whitespaces).isEmpty,
            Self.isExecutableFile(directory.appendingPathComponent(record.executable.name), bytes: record.executable.bytes),
            Self.isExecutableFile(directory.appendingPathComponent(record.harness.name), bytes: record.harness.bytes)
        else { throw AntigravityInstallError.incomplete }
        return AntigravityExecutable(
            executable: directory.appendingPathComponent(record.executable.name),
            harness: directory.appendingPathComponent(record.harness.name), version: record.version, releaseDirectory: directory)
    }

    // MARK: Cleaning up

    /// Removes releases other than `releaseID` that no launch uses.
    nonisolated func pruneReleases(keeping releaseID: String, inUse: Set<String>) {
        let manager = FileManager.default
        let inUse = Set(inUse.map { AntigravityPaths.canonicalPath(URL(fileURLWithPath: $0)) })
        for name in (try? manager.contentsOfDirectory(atPath: paths.versionsDirectory.path)) ?? []
        where Self.isReleaseID(name) && name != releaseID {
            let directory = paths.versionsDirectory.appendingPathComponent(name, isDirectory: true)
            guard !inUse.contains(AntigravityPaths.canonicalPath(directory)) else { continue }
            try? manager.removeItem(at: directory)
        }
    }

    /// Removes staging folders and link swaps an interrupted installation left behind.
    nonisolated func removeLeftovers(olderThan age: TimeInterval) {
        let manager = FileManager.default
        for (directory, prefix) in [(paths.versionsDirectory, ".install-"), (paths.managedDirectory, ".current-")] {
            for name in (try? manager.contentsOfDirectory(atPath: directory.path)) ?? [] where name.hasPrefix(prefix) {
                let url = directory.appendingPathComponent(name)
                let attributes = try? manager.attributesOfItem(atPath: url.path)
                let modified = attributes?[.modificationDate] as? Date ?? .distantPast
                if Date().timeIntervalSince(modified) > age { try? manager.removeItem(at: url) }
            }
        }
    }

    // MARK: Helpers

    nonisolated static func isReleaseID(_ value: String) -> Bool {
        value.utf8.count == 64 && value.utf8.allSatisfy { (0x30...0x39).contains($0) || (0x61...0x66).contains($0) }
    }

    /// A regular file (not a link) of exactly `bytes` bytes that its owner may run.
    nonisolated static func isExecutableFile(_ url: URL, bytes: Int64) -> Bool {
        var info = stat()
        guard lstat(url.path, &info) == 0 else { return false }
        return info.st_mode & S_IFMT == S_IFREG && Int64(info.st_size) == bytes && info.st_mode & 0o111 != 0
    }

    nonisolated static func sha256(of url: URL, isCancelled: () -> Bool) throws -> String {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        var hasher = SHA256()
        while let chunk = try handle.read(upToCount: 1 << 20), !chunk.isEmpty {
            if isCancelled() { throw CancellationError() }
            hasher.update(data: chunk)
        }
        return hex(hasher.finalize())
    }

    nonisolated static func hex<D: Sequence>(_ digest: D) -> String where D.Element == UInt8 {
        digest.map { String(format: "%02x", $0) }.joined()
    }

    /// Checks `url`'s code signature against `requirement` (all architectures, strict).
    public nonisolated static func verifyCodeSignature(_ url: URL, requirement text: String) throws {
        var code: SecStaticCode?
        var requirement: SecRequirement?
        let flags = SecCSFlags(rawValue: SecCSFlags.RawValue(kSecCSCheckAllArchitectures | kSecCSStrictValidate))
        guard SecStaticCodeCreateWithPath(url as CFURL, [], &code) == errSecSuccess, let code,
            SecRequirementCreateWithString(text as CFString, [], &requirement) == errSecSuccess, let requirement,
            SecStaticCodeCheckValidity(code, flags, requirement) == errSecSuccess
        else {
            throw AntigravityInstallError(
                "verify", String(localized: "An Antigravity file isn’t signed by Google. Nothing was installed."))
        }
    }

    public nonisolated static func availableSpace(_ url: URL) -> Int64? {
        (try? url.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey]))?.volumeAvailableCapacityForImportantUsage
    }

    /// Runs blocking work on a background queue; `isCancelled` turns true once the task is cancelled.
    nonisolated static func blocking<T: Sendable>(_ work: @escaping @Sendable (_ isCancelled: () -> Bool) throws -> T) async throws -> T {
        let flag = CancellationFlag()
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                DispatchQueue.global(qos: .userInitiated).async {
                    continuation.resume(with: Result { try work { flag.isSet } })
                }
            }
        } onCancel: {
            flag.set()
        }
    }

    /// `body`, or `timeoutError` once `seconds` pass (the body is cancelled then).
    nonisolated static func withTimeout<T: Sendable>(
        _ seconds: TimeInterval, timeoutError: Error & Sendable, _ body: @escaping @Sendable () async throws -> T
    ) async throws -> T {
        try await withThrowingTaskGroup(of: T.self) { group in
            group.addTask { try await body() }
            group.addTask {
                try await Task.sleep(for: .seconds(seconds))
                throw timeoutError
            }
            defer { group.cancelAll() }
            guard let first = try await group.next() else { throw CancellationError() }
            return first
        }
    }
}

private final class CancellationFlag: @unchecked Sendable {
    private let lock = NSLock()
    private var value = false

    nonisolated var isSet: Bool { lock.withLock { value } }
    nonisolated func set() { lock.withLock { value = true } }
}

/// Writes the archive as it downloads, hashing it on the way, and refuses anything that does not
/// match the pinned size (T3 Code's checks, including an encoded Content-Length when the body is
/// compressed in transit).
final class AntigravityArchiveSink: AntigravityDownloadSink, @unchecked Sendable {
    private let asset: AntigravityReleaseAsset
    private let progress: @Sendable (AntigravityInstallProgress) -> Void
    private let lock = NSLock()
    private var handle: FileHandle?
    private var hasher = SHA256()
    private var received: Int64 = 0
    private var lastReport = Date.distantPast

    nonisolated init(file: URL, asset: AntigravityReleaseAsset, progress: @escaping @Sendable (AntigravityInstallProgress) -> Void) throws {
        self.asset = asset
        self.progress = progress
        let descriptor = open(file.path, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, 0o600)
        guard descriptor >= 0 else {
            throw AntigravityInstallError("download", String(localized: "Couldn’t save the Antigravity download."))
        }
        handle = FileHandle(fileDescriptor: descriptor, closeOnDealloc: true)
    }

    nonisolated func receive(response: HTTPURLResponse) throws {
        guard (200..<300).contains(response.statusCode) else {
            throw AntigravityInstallError(
                "download", String(localized: "Google’s download server answered with HTTP \(response.statusCode). Try again later."))
        }
        let encoding = (response.value(forHTTPHeaderField: "Content-Encoding") ?? "identity").trimmingCharacters(in: .whitespaces).lowercased()
        if encoding.isEmpty || encoding == "identity", let length = response.value(forHTTPHeaderField: "Content-Length").flatMap(Int64.init),
            length != asset.archiveBytes
        {
            throw AntigravityInstallError("download", String(localized: "The Antigravity download size didn’t match the pinned release."))
        }
    }

    nonisolated func receive(_ data: Data) throws {
        let (total, report) = try lock.withLock { () -> (Int64, Bool) in
            received += Int64(data.count)
            guard received <= asset.archiveBytes else {
                throw AntigravityInstallError("download", String(localized: "The Antigravity download exceeded the pinned release size."))
            }
            hasher.update(data: data)
            do {
                try handle?.write(contentsOf: data)
            } catch {
                throw AntigravityInstallError("download", String(localized: "Couldn’t save the Antigravity download. Check free disk space."))
            }
            let now = Date()
            let report = now.timeIntervalSince(lastReport) >= 0.25 || received == asset.archiveBytes
            if report { lastReport = now }
            return (received, report)
        }
        if report { progress(.downloaded(total)) }
    }

    nonisolated func close() {
        lock.withLock {
            try? handle?.close()
            handle = nil
        }
    }

    /// Fails closed unless exactly the pinned bytes arrived.
    nonisolated func finish() throws {
        try lock.withLock {
            do {
                try handle?.close()
            } catch {
                throw AntigravityInstallError("download", String(localized: "Couldn’t save the Antigravity download. Check free disk space."))
            }
            handle = nil
            guard received == asset.archiveBytes, AntigravityInstaller.hex(hasher.finalize()) == asset.sha256 else {
                throw AntigravityInstallError(
                    "download", String(localized: "The Antigravity download failed its size or SHA-256 check. Nothing was installed."))
            }
        }
    }
}

// MARK: - Downloading

/// Downloads with `URLSession`, streaming each chunk to the sink as it arrives.
public enum AntigravityDownload {
    public nonisolated static let urlSession: AntigravityDownloader = { url, sink in
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 60
        configuration.timeoutIntervalForResource = 45 * 60
        configuration.requestCachePolicy = .reloadIgnoringLocalAndRemoteCacheData
        configuration.urlCache = nil
        let delegate = Delegate(sink: sink)
        let queue = OperationQueue()
        queue.maxConcurrentOperationCount = 1
        let session = URLSession(configuration: configuration, delegate: delegate, delegateQueue: queue)
        defer { session.invalidateAndCancel() }
        let task = session.dataTask(with: URLRequest(url: url))
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                delegate.begin(task, continuation)
            }
        } onCancel: {
            task.cancel()
        }
    }

    private final class Delegate: NSObject, URLSessionDataDelegate, @unchecked Sendable {
        private let sink: AntigravityDownloadSink
        private let lock = NSLock()
        private var continuation: CheckedContinuation<Void, Error>?
        private var failure: Error?

        nonisolated init(sink: AntigravityDownloadSink) {
            self.sink = sink
        }

        nonisolated func begin(_ task: URLSessionDataTask, _ continuation: CheckedContinuation<Void, Error>) {
            lock.withLock { self.continuation = continuation }
            task.resume()
        }

        nonisolated func urlSession(
            _ session: URLSession, dataTask: URLSessionDataTask, didReceive response: URLResponse,
            completionHandler: @escaping @Sendable (URLSession.ResponseDisposition) -> Void
        ) {
            do {
                guard let response = response as? HTTPURLResponse else { throw URLError(.badServerResponse) }
                try sink.receive(response: response)
                completionHandler(.allow)
            } catch {
                lock.withLock { failure = error }
                completionHandler(.cancel)
            }
        }

        nonisolated func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
            guard lock.withLock({ failure == nil }) else { return }
            do {
                try sink.receive(data)
            } catch {
                lock.withLock { failure = error }
                dataTask.cancel()
            }
        }

        /// Only HTTPS redirects are followed.
        nonisolated func urlSession(
            _ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
            newRequest request: URLRequest, completionHandler: @escaping @Sendable (URLRequest?) -> Void
        ) {
            completionHandler(request.url?.scheme?.lowercased() == "https" ? request : nil)
        }

        nonisolated func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
            let (continuation, failure) = lock.withLock { () -> (CheckedContinuation<Void, Error>?, Error?) in
                defer { self.continuation = nil }
                return (self.continuation, self.failure ?? error)
            }
            if let failure { continuation?.resume(throwing: failure) } else { continuation?.resume() }
        }
    }
}
