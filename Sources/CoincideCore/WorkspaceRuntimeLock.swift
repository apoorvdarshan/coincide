import Darwin
import Foundation

/// One execution runtime owns a workspace; other database readers remain allowed.
final class WorkspaceRuntimeLock: @unchecked Sendable {
    private let mutex = NSLock()
    private var descriptor: Int32
    init(url: URL) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        descriptor = Darwin.open(url.path, O_RDWR | O_CREAT | O_CLOEXEC, mode_t(0o600))
        guard descriptor >= 0 else { throw CoincideError("Could not open the workspace runtime lock.") }
        guard flock(descriptor, LOCK_EX | LOCK_NB) == 0 else {
            Darwin.close(descriptor); descriptor = -1
            throw CoincideError("Another Coincide runtime already owns this workspace. Close that instance before opening another.")
        }
    }
    func release() {
        mutex.lock(); defer { mutex.unlock() }
        guard descriptor >= 0 else { return }
        flock(descriptor, LOCK_UN); Darwin.close(descriptor); descriptor = -1
    }
    deinit { release() }
}
