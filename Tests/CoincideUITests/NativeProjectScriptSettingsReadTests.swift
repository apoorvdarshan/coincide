import Darwin
import Foundation
import Testing
import CoincideCore
@testable import Coincide

private final class ScriptSettingsReadProbe: @unchecked Sendable {
    private let lock = NSLock()
    private var didStart = false
    private var didFinish = false
    private var observedCancellation = false
    let started: AsyncStream<Void>
    private let signal: AsyncStream<Void>.Continuation

    init() {
        let pair = AsyncStream<Void>.makeStream(bufferingPolicy: .bufferingNewest(1))
        started = pair.stream; signal = pair.continuation
    }
    func begin() {
        lock.withLock { didStart = true }
        signal.yield(()); signal.finish()
    }
    func finish(cancelled: Bool) {
        lock.withLock { didFinish = true; observedCancellation = cancelled }
    }
    var state: (started: Bool, finished: Bool, cancelled: Bool) {
        lock.withLock { (didStart, didFinish, observedCancellation) }
    }
}

/// The private file lock remains held throughout shutdown. The real reader must
/// observe cancellation and be joined; releasing the lock cannot make this pass.
@MainActor @Test(.timeLimit(.minutes(1)))
func nativeProjectScriptShutdownJoinsActualSettingsReaderWhilePrivateFileLockRemainsHeld() async throws {
    let root = try projectActionsPhysicalTemporaryDirectory()
        .appendingPathComponent("coincide-script-settings-drain-" + UUID().uuidString)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
    defer { try? FileManager.default.removeItem(at: root) }
    let checkout = root.appendingPathComponent("Checkout"), settings = root.appendingPathComponent("Settings")
    try FileManager.default.createDirectory(at: checkout, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
    let project = WorkspaceProject(path: checkout.path), thread = CodingThread(project: project)
    let key = ProjectSettingsKey.primary(for: project)
    let document = ProjectSettingsDocument(key: key, actions: [])
    try ProjectSettingsFiles.save(document, root: settings)
    #expect(try ProjectSettingsFiles.load(root: settings, key: key) == document)

    let descriptor = Darwin.open(settings.appendingPathComponent(".project-settings.lock").path, O_RDWR | O_NOFOLLOW | O_CLOEXEC)
    try #require(descriptor >= 0)
    var held = false
    defer {
        if held { _ = flock(descriptor, LOCK_UN) }
        _ = Darwin.close(descriptor)
    }
    try #require(flock(descriptor, LOCK_EX | LOCK_NB) == 0)
    held = true
    let probe = ScriptSettingsReadProbe(), files = WorkspaceFileService(root: checkout)
    var windowAuthorizations = 0
    let service = NativeProjectScriptService(
        resolve: { _ in .init(projectRoot: checkout.path, files: files, settingsKeys: [key]) },
        authorize: { _, _ in true },
        authorizeWindow: { _ in windowAuthorizations += 1; return true },
        settingsRoot: settings,
        settingsRead: { keys in
            probe.begin()
            var cancelled = false
            defer { probe.finish(cancelled: cancelled) }
            do { return try ProjectSettingsFiles.load(root: settings, keys: keys)?.document }
            catch { cancelled = error is CancellationError; throw error }
        })
    let load = Task { try await service.load(for: thread) }
    for await _ in probe.started { break }
    #expect(probe.state.started && !probe.state.finished)

    await service.shutdown()
    // Assert before unlocking: an untracked detached read would still be alive.
    let joined = probe.state
    #expect(joined.finished)
    #expect(joined.cancelled)
    #expect(windowAuthorizations == 0, "Discovery and shutdown never request a terminal launch.")
    _ = flock(descriptor, LOCK_UN); held = false
    switch await load.result {
    case .success: Issue.record("The settings result was published after script-service shutdown.")
    case .failure(let error): #expect(error is CancellationError)
    }
    await files.close()
}
