import Darwin
import Foundation

public struct AppUpdatePlan: Codable, Sendable {
    public let release: AppUpdateRelease
    public let target: URL
    public let processID: Int32
    public let nonce: UUID
    public init(release: AppUpdateRelease, target: URL, processID: Int32) {
        self.release = release
        self.target = target
        self.processID = processID
        nonce = UUID()
    }
}

/// Missing consent still forbids installation, but a normally exited app needs a visible failure result.
public struct AppUpdateQuitGate {
    public private(set) var shouldReportFailure = false
    public init() {}

    public mutating func waitForConsent(plan: AppUpdatePlan, job: URL, waitForCleanExit: () throws -> Void) throws {
        shouldReportFailure = false
        try waitForCleanExit()
        shouldReportFailure = true
        let consent = try String(contentsOf: job.appendingPathComponent("clean-quit"), encoding: .utf8)
        guard consent == plan.nonce.uuidString else { throw AppUpdateError.running }
    }
}

public enum AppUpdateStaging {
    /// Owns only this newly created job folder. A failed stage never changes the running application.
    public static func prepare(download: URL, release: AppUpdateRelease, root: URL, target: URL) throws -> URL {
        let team = try AppUpdateSecurity.signingTeam(at: target)
        let current = try AppUpdateSecurity.bundleVersion(at: target)
        let fm = FileManager.default
        try fm.createDirectory(at: root, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        let job = root.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try fm.createDirectory(at: job, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        do {
            let archive = job.appendingPathComponent("release.zip")
            try fm.copyItem(at: download, to: archive)
            try checkArchive(archive, release: release)
            let extraction = job.appendingPathComponent("contents", isDirectory: true)
            try UpdateArchive.extract(archive, to: extraction)
            try AppUpdateSecurity.verifyBundle(extraction.appendingPathComponent("Coincide.app"), release: release, team: team, currentVersion: current)
            return job
        } catch { try? fm.removeItem(at: job); throw error }
    }

    public static func checkArchive(_ archive: URL, release: AppUpdateRelease) throws {
        let size = try archive.resourceValues(forKeys: [.fileSizeKey, .isRegularFileKey, .isSymbolicLinkKey])
        guard size.isRegularFile == true, size.isSymbolicLink != true, let count = size.fileSize, Int64(count) == release.size,
              try AppUpdateSecurity.digest(archive) == release.sha256 else { throw AppUpdateError.verification }
    }
}

public enum AppUpdateInstallation {
    /// A receipt is diagnostic only. Failure to write it cannot turn a completed exchange into a failed installation.
    public static func recordSuccess(version: String, backup: URL, job: URL) {
        try? JSONEncoder().encode(["state": "installed", "version": version, "backup": backup.path])
            .write(to: job.appendingPathComponent("result.json"), options: .atomic)
    }

    /// Re-extract and verify the immutable release bytes after quit; never trust the previously expanded bundle.
    public static func install(plan: AppUpdatePlan, job: URL, team: String, isRunning: () -> Bool) throws -> URL {
        let target = plan.target.standardizedFileURL
        guard target.isFileURL, target.pathExtension == "app", target == target.resolvingSymlinksInPath() else { throw AppUpdateError.incompatible }
        let current = try AppUpdateSecurity.bundleVersion(at: target)
        try AppUpdateSecurity.validateSignature(at: target, team: team, identifier: AppUpdateSecurity.bundleID)
        let archive = job.appendingPathComponent("release.zip")
        try AppUpdateStaging.checkArchive(archive, release: plan.release)
        let expanded = job.appendingPathComponent("install-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: expanded) }
        try UpdateArchive.extract(archive, to: expanded)
        return try exchange(candidate: expanded.appendingPathComponent("Coincide.app"), target: target, isRunning: isRunning) { bundle in
            try AppUpdateSecurity.verifyBundle(bundle, release: plan.release, team: team, currentVersion: current)
        }
    }

    /// Internal seam for filesystem regression tests; production always supplies the strict verifier above.
    static func exchange(candidate: URL, target: URL, isRunning: () -> Bool, verify: (URL) throws -> Void) throws -> URL {
        guard !isRunning() else { throw AppUpdateError.running }
        try verify(candidate)
        let fm = FileManager.default
        let replacement = target.deletingLastPathComponent().appendingPathComponent(".Coincide-backup-\(UUID().uuidString).app")
        var swapped = false
        do {
            // Copy onto the destination volume before the atomic exchange. Incomplete copies cannot replace the app.
            try fm.copyItem(at: candidate, to: replacement)
            try verify(replacement)
            guard !isRunning() else { throw AppUpdateError.running }
            guard renameatx_np(AT_FDCWD, replacement.path, AT_FDCWD, target.path, UInt32(RENAME_SWAP)) == 0 else { throw AppUpdateError.installation }
            swapped = true
            do { try verify(target) }
            catch {
                guard renameatx_np(AT_FDCWD, replacement.path, AT_FDCWD, target.path, UInt32(RENAME_SWAP)) == 0 else {
                    // Keep both bundles for recovery if the filesystem refuses the rollback.
                    throw AppUpdateError.installation
                }
                swapped = false
                throw error
            }
            // `replacement` now holds the original application; deliberately keep it as a recovery backup.
            return replacement
        } catch {
            if !swapped { try? fm.removeItem(at: replacement) }
            throw error
        }
    }

    /// Observe the exact parent process, including its exit status. Abnormal termination never authorizes installation.
    public static func waitForCleanExit(processID: Int32, ready: () -> Void) throws {
        guard processID > 1, processID == getppid() else { throw AppUpdateError.running }
        try observeCleanExit(processID: processID, timeoutSeconds: 7 * 24 * 60 * 60, ready: ready)
    }

    static func observeCleanExit(processID: Int32, timeoutSeconds: Int, ready: () -> Void) throws {
        let queue = kqueue()
        guard queue >= 0 else { throw AppUpdateError.installation }
        defer { close(queue) }
        var event = kevent(ident: UInt(processID), filter: Int16(EVFILT_PROC), flags: UInt16(EV_ADD | EV_ENABLE | EV_ONESHOT),
                           fflags: UInt32(NOTE_EXIT) | UInt32(NOTE_EXITSTATUS), data: 0, udata: nil)
        guard kevent(queue, &event, 1, nil, 0, nil) == 0 else { throw AppUpdateError.running }
        ready()
        var result = kevent()
        var timeout = timespec(tv_sec: timeoutSeconds, tv_nsec: 0)
        guard kevent(queue, nil, 0, &result, 1, &timeout) == 1,
              result.flags & UInt16(EV_ERROR) == 0, result.fflags & UInt32(NOTE_EXIT) != 0,
              result.data == 0 else { throw AppUpdateError.running }
    }
}
