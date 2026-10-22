import CryptoKit
import Darwin
import Foundation
import Testing
@testable import CoincideCore

private struct CodexAdmissionFixture: Sendable {
    let root: URL
    let instanceID = UUID()
    let generation = UUID()
    var locks: URL { root.appendingPathComponent("locks") }
    var shared: URL { root.appendingPathComponent("shared") }
    var overlay: URL { root.appendingPathComponent("overlay") }
    init() throws {
        guard let physical = realpath(FileManager.default.temporaryDirectory.path, nil) else { throw CoincideError("The task-owned temporary root is unavailable.") }
        defer { free(physical) }
        root = URL(fileURLWithPath: String(cString: physical)).appendingPathComponent("coincide-codex-admission-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
    }
    func runtime() async throws -> CodexRuntimeAdmissionLease { try await CodexRuntimeAdmission.acquireRuntime(instanceID: instanceID, root: locks) }
    func mutation(timeout: Duration = .milliseconds(80)) async throws -> CodexRuntimeAdmissionLease {
        try await CodexRuntimeAdmission.acquireMutation(instanceID: instanceID, root: locks, timeout: timeout)
    }
    func prepare(_ lease: CodexRuntimeAdmissionLease, cached: CodexHomeLayout.Prepared? = nil, timeout: Duration = .seconds(2)) async throws -> CodexHomeLayout.Prepared {
        try await lease.prepareHome(generation: generation, sharedHome: shared, overlayHome: overlay, cached: cached, timeout: timeout)
    }
    func remove() { try? FileManager.default.removeItem(at: root) }
    func file(_ url: URL, _ text: String) throws {
        try Data(text.utf8).write(to: url, options: .withoutOverwriting)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
    }
    func identity(_ url: URL) throws -> GitWorktreeNodeIdentity {
        var value = stat(); guard lstat(url.path, &value) == 0 else { throw CoincideError("A task-owned fixture entry is missing.") }; return worktreeIdentity(value)
    }
    func peer(lock path: URL, exclusive: Bool) async throws -> ProcessChannel {
        let script = """
        import fcntl, os, sys
        with open(sys.argv[1], 'r+b', buffering=0) as owned:
            fcntl.flock(owned, fcntl.LOCK_EX if sys.argv[2] == 'exclusive' else fcntl.LOCK_SH)
            os.write(1, b'ready\\n')
            sys.stdin.buffer.read(1)
        """
        let process = try ProcessChannel(executable: URL(fileURLWithPath: "/usr/bin/python3"), arguments: ["-c", script, path.path, exclusive ? "exclusive" : "shared"], eventBufferLimit: 8)
        do {
            for await event in process.events {
                switch event {
                case .stdout(let bytes) where String(decoding: bytes, as: UTF8.self).contains("ready"): return process
                case .exited: throw CoincideError("The task-owned admission peer exited before acquiring its lock.")
                default: continue
                }
            }
            throw CoincideError("The task-owned admission peer ended before acquiring its lock.")
        } catch { _ = await process.stopAndDrain(); throw error }
    }
}

@Test func codexRuntimeAdmissionKeepsIndependentSharedOwnersUntilEachReleaseAndFencesMutation() async throws {
    let fixture = try CodexAdmissionFixture(); defer { fixture.remove() }
    let first = try await fixture.runtime(), second = try await fixture.runtime()
    defer { first.release(); second.release() }
    await #expect(throws: CodexRuntimeAdmissionError.busy) { try await fixture.mutation() }
    first.release(); first.release()
    try second.validate()
    await #expect(throws: CodexRuntimeAdmissionError.busy) { try await fixture.mutation() }
    second.release()
    let mutation = try await fixture.mutation()
    await #expect(throws: CodexRuntimeAdmissionError.busy) {
        try await CodexRuntimeAdmission.acquireRuntime(instanceID: fixture.instanceID, root: fixture.locks, timeout: .milliseconds(80))
    }
    mutation.release()
    let next = try await fixture.runtime(); next.release()
    #expect(throws: CodexRuntimeAdmissionError.released) { try first.validate() }
}

@Test func codexRuntimeAdmissionReadsAnAlreadyLiveLayoutWithoutMutatingItsLinksOrCache() async throws {
    let fixture = try CodexAdmissionFixture(); defer { fixture.remove() }
    let first = try await fixture.runtime(), second = try await fixture.runtime(), third = try await fixture.runtime()
    defer { first.release(); second.release(); third.release() }
    let initial = try await fixture.prepare(first)
    try fixture.file(fixture.overlay.appendingPathComponent("models_cache.json"), "private native cache")
    let link = fixture.overlay.appendingPathComponent("sessions"), linkID = try fixture.identity(link)
    let fresh = try await fixture.prepare(second), cached = try await fixture.prepare(third, cached: initial)
    #expect(fresh == initial && cached == initial)
    #expect(try fixture.identity(link) == linkID)
    #expect(try String(contentsOf: fixture.overlay.appendingPathComponent("models_cache.json"), encoding: .utf8) == "private native cache")
    try CodexHomeLayout.validate(initial)
}

@Test func codexRuntimeAdmissionRefusesRepairsUnderSharedUsersThenRepairsAfterTheirDrain() async throws {
    let fixture = try CodexAdmissionFixture(); defer { fixture.remove() }
    let first = try await fixture.runtime(), second = try await fixture.runtime()
    defer { first.release(); second.release() }
    _ = try await fixture.prepare(first)
    try fixture.file(fixture.shared.appendingPathComponent("new-native-state"), "shared native state")
    let mcp = fixture.overlay.appendingPathComponent("mcp-oauth-locks")
    try FileManager.default.removeItem(at: mcp)
    try FileManager.default.createDirectory(at: mcp, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
    try fixture.file(mcp.appendingPathComponent("native-lock"), "must be retained")
    let nativeID = try fixture.identity(mcp)
    await #expect(throws: CodexHomeLayoutError.busy) { try await fixture.prepare(second) }
    #expect(try fixture.identity(mcp) == nativeID)
    #expect(!FileManager.default.fileExists(atPath: fixture.overlay.appendingPathComponent("new-native-state").path))
    first.release()
    let repaired = try await fixture.prepare(second)
    #expect(repaired.preservedRuntimeEntries.count == 1)
    let preserved = try #require(repaired.preservedRuntimeEntries.first)
    #expect(try fixture.identity(preserved) == nativeID)
    #expect(try String(contentsOf: preserved.appendingPathComponent("native-lock"), encoding: .utf8) == "must be retained")
    #expect(try FileManager.default.destinationOfSymbolicLink(atPath: fixture.overlay.appendingPathComponent("new-native-state").path) == fixture.shared.path + "/new-native-state")
}

@Test(.timeLimit(.minutes(1))) func codexRuntimeAdmissionExternalProcessSharedLockBlocksAuthUntilExactPeerDrain() async throws {
    let fixture = try CodexAdmissionFixture(); defer { fixture.remove() }
    let original = try await fixture.runtime()
    let peer = try await fixture.peer(lock: fixture.locks.appendingPathComponent(fixture.instanceID.uuidString.lowercased() + ".runtime.lock"), exclusive: false)
    original.release()
    do {
        await #expect(throws: CodexRuntimeAdmissionError.busy) { try await fixture.mutation() }
        try await peer.write(Data([1])); _ = await peer.stopAndDrain()
        let admitted = try await fixture.mutation(); admitted.release()
    } catch { _ = await peer.stopAndDrain(); throw error }
}

@Test(.timeLimit(.minutes(1))) func codexRuntimeAdmissionReleaseAndCancellationKeepPreparingBorrowFencedUntilItDrains() async throws {
    let fixture = try CodexAdmissionFixture(); defer { fixture.remove() }
    let seed = try await fixture.runtime(); _ = try await fixture.prepare(seed); seed.release()
    let homeKey = SHA256.hash(data: Data(try CodexHomeLayout.resolvedPathForAdmission(fixture.shared).utf8)).map { String(format: "%02x", $0) }.joined()
    let homePath = fixture.locks.appendingPathComponent(fixture.instanceID.uuidString.lowercased() + "." + fixture.generation.uuidString.lowercased() + "." + homeKey + ".home.lock")
    let peer = try await fixture.peer(lock: homePath, exclusive: true)
    let runtime = try await fixture.runtime()
    let operation = Task { try await fixture.prepare(runtime) }
    do {
        let deadline = ContinuousClock.now + .seconds(2)
        while !runtime.hasPendingHomePreparation {
            guard ContinuousClock.now < deadline else { throw CoincideError("The exact task-owned preparation did not enter.") }
            try await Task.sleep(for: .milliseconds(5))
        }
        runtime.release()
        await #expect(throws: CodexRuntimeAdmissionError.busy) { try await fixture.mutation() }
        operation.cancel()
        await #expect(throws: CodexRuntimeAdmissionError.cancelled) { try await operation.value }
        let mutation = try await fixture.mutation(); mutation.release()
        try await peer.write(Data([1])); _ = await peer.stopAndDrain()
    } catch { operation.cancel(); _ = await operation.result; runtime.release(); _ = await peer.stopAndDrain(); throw error }
}

@Test func codexRuntimeAdmissionRejectsReplacedGateAndScopeRebindingWithoutOverwritingProof() async throws {
    let fixture = try CodexAdmissionFixture(); defer { fixture.remove() }
    let first = try await fixture.runtime(); _ = try await fixture.prepare(first); first.release()
    let other = try await fixture.runtime()
    defer { other.release() }
    await #expect(throws: CodexRuntimeAdmissionError.ownershipLost) {
        try await other.prepareHome(generation: fixture.generation, sharedHome: fixture.shared, overlayHome: fixture.root.appendingPathComponent("other-overlay"))
    }
    await #expect(throws: CodexRuntimeAdmissionError.ownershipLost) {
        try await other.prepareHome(generation: UUID(), sharedHome: fixture.shared, overlayHome: fixture.overlay)
    }
    let gate = fixture.locks.appendingPathComponent(fixture.instanceID.uuidString.lowercased() + ".runtime.lock")
    let moved = fixture.root.appendingPathComponent("old-runtime-lock")
    try FileManager.default.moveItem(at: gate, to: moved)
    try fixture.file(gate, "")
    #expect(throws: CodexRuntimeAdmissionError.ownershipLost) { try other.validate() }
    await #expect(throws: CodexRuntimeAdmissionError.ownershipLost) { try await fixture.runtime() }
    #expect(try Data(contentsOf: moved).isEmpty && Data(contentsOf: gate).isEmpty)
}

@Test func codexRuntimeAdmissionInstancesAreIndependentAndMutationCannotPrepareAHome() async throws {
    let fixture = try CodexAdmissionFixture(); defer { fixture.remove() }
    let runtime = try await fixture.runtime(); defer { runtime.release() }
    let other = try await CodexRuntimeAdmission.acquireMutation(instanceID: UUID(), root: fixture.locks)
    defer { other.release() }
    await #expect(throws: CodexRuntimeAdmissionError.invalidScope) { try await fixture.prepare(other) }
    try runtime.validate()
}

@Test func codexHomeInspectionNeverCreatesMissingRootsOrRepairsPrivateCacheLinks() async throws {
    let fixture = try CodexAdmissionFixture(); defer { fixture.remove() }
    #expect(throws: CodexHomeLayoutError.busy) { try CodexHomeLayout.inspect(sharedHome: fixture.shared, overlayHome: fixture.overlay) }
    #expect(try FileManager.default.contentsOfDirectory(atPath: fixture.root.path).isEmpty)
    let runtime = try await fixture.runtime(); defer { runtime.release() }
    let prepared = try await fixture.prepare(runtime)
    let cache = fixture.overlay.appendingPathComponent("models_cache.json")
    try FileManager.default.createSymbolicLink(atPath: cache.path, withDestinationPath: fixture.shared.appendingPathComponent("models_cache.json").path)
    let identity = try fixture.identity(cache)
    #expect(throws: CodexHomeLayoutError.busy) { try CodexHomeLayout.validate(prepared) }
    #expect(try fixture.identity(cache) == identity)
}

@Test func codexHomeInspectionRejectsAuthRedirectsAndCachedProofReplacementWithoutReadingSecrets() async throws {
    let fixture = try CodexAdmissionFixture(); defer { fixture.remove() }
    let runtime = try await fixture.runtime(); defer { runtime.release() }
    let prepared = try await fixture.prepare(runtime)
    let target = fixture.root.appendingPathComponent("synthetic-unreadable-auth")
    try fixture.file(target, "synthetic sentinel never read by the materializer")
    #expect(chmod(target.path, 0) == 0)
    let auth = fixture.overlay.appendingPathComponent("auth.json")
    try FileManager.default.createSymbolicLink(atPath: auth.path, withDestinationPath: target.path)
    #expect(throws: CodexHomeLayoutError.privateAuthSymlink) { try CodexHomeLayout.validate(prepared) }
    try FileManager.default.removeItem(at: auth)
    let marker = fixture.overlay.appendingPathComponent(".coincide-codex-home-layout.json")
    let bytes = try Data(contentsOf: marker)
    try bytes.write(to: marker, options: .atomic)
    try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: marker.path)
    #expect(throws: CodexHomeLayoutError.ownershipLost) { try CodexHomeLayout.validate(prepared) }
}
