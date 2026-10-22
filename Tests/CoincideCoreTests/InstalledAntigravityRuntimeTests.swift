import Foundation
import Testing
@testable import CoincideCore

/// Explicit opt-in: downloads only the pinned public pair into private scratch
/// space and performs initialization. No account, browser or model request.
@Test(.enabled(if: ProcessInfo.processInfo.environment["COINCIDE_VERIFY_ANTIGRAVITY_INSTALLATION"] == "1"))
func installedManagedAntigravityArchiveVerifiesAndInitializesWithoutAuthentication() async throws {
    let release = try #require(AntigravityManagedRelease.current)
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("coincide-installed-antigravity-" + UUID().uuidString, isDirectory: true)
        .standardizedFileURL.resolvingSymlinksInPath()
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
    let service = AntigravityInstallation(rootURL: root.appendingPathComponent("managed", isDirectory: true), release: release)
    do {
        let operationID = try service.start()
        for await state in service.updates() where state.operationID == operationID {
            if !state.phase.isWorking { break }
        }
        try await service.cancel(operationID: operationID)
        let state = service.state()
        #expect(state.phase == .succeeded, "Pinned runtime verification: \(state.message ?? state.phase.rawValue)")
        guard state.phase == .succeeded else { throw CoincideError("The pinned runtime did not verify.") }
        let lease = try service.acquire(configuration: .init(runtimeSelection: .managed))
        #expect(lease.releaseID == release.sha256)
        #expect(lease.pair.executable.deletingLastPathComponent() == lease.pair.harness.deletingLastPathComponent())
        lease.release()
        try service.remove(); await service.shutdown()
        try FileManager.default.removeItem(at: root)
    } catch {
        // The service owns and validates its cleanup. Do not recursively delete
        // a directory whose installation ownership could not be established.
        if let operationID = service.state().operationID { try? await service.cancel(operationID: operationID) }
        try? service.remove()
        await service.shutdown()
        if !FileManager.default.fileExists(atPath: service.rootURL.path) { try? FileManager.default.removeItem(at: root) }
        throw error
    }
}
