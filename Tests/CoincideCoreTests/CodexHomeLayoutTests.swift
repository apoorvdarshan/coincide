import Darwin
import Foundation
import Testing
@testable import CoincideCore

private actor CodexHomeCancellationGate {
    private var released = false
    private var continuation: CheckedContinuation<Void, Never>?
    func wait() async {
        guard !released else { return }
        await withCheckedContinuation { continuation = $0 }
    }
    func release() {
        released = true
        continuation?.resume(); continuation = nil
    }
}

private struct CodexHomeFixture: Sendable {
    let root: URL
    var shared: URL { root.appendingPathComponent("shared", isDirectory: true) }
    var overlay: URL { root.appendingPathComponent("overlay", isDirectory: true) }
    let sharedNames = ["sessions", "archived_sessions", "sqlite", "shell_snapshots", "worktrees", "skills", "plugins", "cache", "logs", "mcp-oauth-locks"]
    init() throws {
        guard let temporary = realpath(FileManager.default.temporaryDirectory.path, nil) else { throw CoincideError("The private fixture temporary root could not be resolved.") }
        defer { free(temporary) }
        root = URL(fileURLWithPath: String(cString: temporary), isDirectory: true).appendingPathComponent("coincide-codex-home-\(UUID())", isDirectory: true)
        try directory(root); try directory(shared); try directory(overlay)
    }
    func directory(_ path: URL) throws { try FileManager.default.createDirectory(at: path, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700]) }
    func file(_ path: URL, _ text: String = "synthetic private fixture") throws {
        try Data(text.utf8).write(to: path, options: .withoutOverwriting)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: path.path)
    }
    func link(_ path: URL, to target: String) throws { try FileManager.default.createSymbolicLink(atPath: path.path, withDestinationPath: target) }
    func target(_ path: URL) throws -> String { try FileManager.default.destinationOfSymbolicLink(atPath: path.path) }
    func identity(_ path: URL) throws -> GitWorktreeNodeIdentity {
        var value = stat(); guard lstat(path.path, &value) == 0 else { throw CoincideError("A private fixture node was not found.") }; return worktreeIdentity(value)
    }
    func missing(_ path: URL) -> Bool { var value = stat(); return lstat(path.path, &value) != 0 && errno == ENOENT }
    func prepare() throws -> CodexHomeLayout.Prepared { try CodexHomeLayout.prepare(sharedHome: shared, overlayHome: overlay) }
    func remove() { try? FileManager.default.removeItem(at: root) }
}

@Test func codexHomeSharesTheExactT3HistorySetAndDiscoveredEntries() throws {
    let fixture = try CodexHomeFixture(); defer { fixture.remove() }
    for name in ["config.toml", "history.jsonl", "future-state.bin"] { try fixture.file(fixture.shared.appendingPathComponent(name), name) }
    try fixture.directory(fixture.shared.appendingPathComponent("future-directory"))
    let prepared = try fixture.prepare()
    let expected = Set(fixture.sharedNames + ["config.toml", "history.jsonl", "future-state.bin", "future-directory"])
    for name in expected {
        #expect(try fixture.target(fixture.overlay.appendingPathComponent(name)) == fixture.shared.path + "/" + name)
    }
    let actualShared = try Set(FileManager.default.contentsOfDirectory(atPath: fixture.shared.path))
    #expect(actualShared == expected, "Every discovered shared entry and all ten required directories must be retained.")
    #expect(prepared.sharedHome.path == fixture.shared.path && prepared.effectiveHome.path == fixture.overlay.path)
    #expect(prepared.continuationIdentity == "codex:home:" + fixture.shared.path)
    #expect(prepared.preservedRuntimeEntries.isEmpty)
    let firstIdentities = try expected.map { try fixture.identity(fixture.overlay.appendingPathComponent($0)) }
    #expect(try fixture.prepare() == prepared)
    let secondIdentities = try expected.map { try fixture.identity(fixture.overlay.appendingPathComponent($0)) }
    #expect(firstIdentities == secondIdentities, "Idempotence preserves existing link inodes.")
    let secondOverlay = fixture.root.appendingPathComponent("second-overlay")
    let second = try CodexHomeLayout.prepare(sharedHome: fixture.shared, overlayHome: secondOverlay)
    #expect(second.continuationIdentity == prepared.continuationIdentity && second.effectiveHome != prepared.effectiveHome)
}

@Test func codexHomeKeepsAuthModelCacheAndFourLocalEntriesPrivateWithoutReadingAuth() throws {
    let fixture = try CodexHomeFixture(); defer { fixture.remove() }
    for home in [fixture.shared, fixture.overlay] {
        try fixture.file(home.appendingPathComponent("auth.json"), "synthetic unreadable auth sentinel")
        try fixture.file(home.appendingPathComponent("models_cache.json"), "synthetic model cache")
        for name in ["log", "memories", "tmp"] {
            try fixture.directory(home.appendingPathComponent(name)); try fixture.file(home.appendingPathComponent(name + "/retained"), home.lastPathComponent + name)
        }
        try fixture.file(home.appendingPathComponent(".DS_Store"), "native-local fixture")
    }
    let paths = [fixture.shared, fixture.overlay].flatMap { home in ["auth.json", "models_cache.json", "log", "memories", "tmp", ".DS_Store"].map { home.appendingPathComponent($0) } }
    let identities = try paths.map(fixture.identity)
    // The materializer must inspect metadata only, never open either auth file.
    for home in [fixture.shared, fixture.overlay] { #expect(chmod(home.appendingPathComponent("auth.json").path, 0) == 0) }
    // The real cache remains private through the 0700 overlay even if the native CLI used 0644.
    #expect(chmod(fixture.overlay.appendingPathComponent("models_cache.json").path, 0o644) == 0)
    _ = try fixture.prepare()
    #expect(try paths.map(fixture.identity) == identities)
    #expect(try String(contentsOf: fixture.overlay.appendingPathComponent("models_cache.json"), encoding: .utf8) == "synthetic model cache")
    for name in ["log", "memories", "tmp"] {
        #expect(try String(contentsOf: fixture.overlay.appendingPathComponent(name + "/retained"), encoding: .utf8) == "overlay" + name)
    }
}

@Test func codexHomeDoesNotCopySharedAuthenticationToAnEmptyOverlay() throws {
    let fixture = try CodexHomeFixture(); defer { fixture.remove() }
    try fixture.file(fixture.shared.appendingPathComponent("auth.json"))
    try fixture.file(fixture.shared.appendingPathComponent("models_cache.json"))
    _ = try fixture.prepare()
    #expect(fixture.missing(fixture.overlay.appendingPathComponent("auth.json")))
    #expect(fixture.missing(fixture.overlay.appendingPathComponent("models_cache.json")))
}

@Test func codexHomePreservesTheSharedConfigSymlinkAndExactRelativeOverlayLinks() throws {
    let fixture = try CodexHomeFixture(); defer { fixture.remove() }
    let external = fixture.root.appendingPathComponent("real-config.toml")
    try fixture.file(external, "shared linked config")
    try fixture.link(fixture.shared.appendingPathComponent("config.toml"), to: "../real-config.toml")
    try fixture.directory(fixture.shared.appendingPathComponent("sessions"))
    try fixture.link(fixture.overlay.appendingPathComponent("sessions"), to: "../shared/sessions")
    let configID = try fixture.identity(fixture.shared.appendingPathComponent("config.toml")), sessionsID = try fixture.identity(fixture.overlay.appendingPathComponent("sessions"))
    _ = try fixture.prepare()
    #expect(try fixture.identity(fixture.shared.appendingPathComponent("config.toml")) == configID)
    #expect(try fixture.identity(fixture.overlay.appendingPathComponent("sessions")) == sessionsID)
    #expect(try fixture.target(fixture.overlay.appendingPathComponent("config.toml")) == fixture.shared.path + "/config.toml")
    #expect(try String(contentsOf: fixture.overlay.appendingPathComponent("config.toml"), encoding: .utf8) == "shared linked config")
}

@Test func codexHomeRemovesOnlyTheExpectedSharedModelCacheLink() throws {
    let fixture = try CodexHomeFixture(); defer { fixture.remove() }
    try fixture.file(fixture.shared.appendingPathComponent("models_cache.json"), "shared cache retained")
    try fixture.link(fixture.overlay.appendingPathComponent("models_cache.json"), to: "../shared/models_cache.json")
    _ = try fixture.prepare()
    #expect(fixture.missing(fixture.overlay.appendingPathComponent("models_cache.json")))
    #expect(try String(contentsOf: fixture.shared.appendingPathComponent("models_cache.json"), encoding: .utf8) == "shared cache retained")
    let foreign = fixture.root.appendingPathComponent("foreign-cache")
    try fixture.file(foreign, "foreign retained")
    try fixture.link(fixture.overlay.appendingPathComponent("models_cache.json"), to: foreign.path)
    let identity = try fixture.identity(fixture.overlay.appendingPathComponent("models_cache.json"))
    #expect(throws: CodexHomeLayoutError.entryConflict) { try fixture.prepare() }
    #expect(try fixture.identity(fixture.overlay.appendingPathComponent("models_cache.json")) == identity)
    #expect(try String(contentsOf: foreign, encoding: .utf8) == "foreign retained")
}

@Test func codexHomeRejectsPrivateAuthSymlinksAndHardlinksBeforeSharing() throws {
    let fixture = try CodexHomeFixture(); defer { fixture.remove() }
    let target = fixture.root.appendingPathComponent("foreign-auth"), auth = fixture.overlay.appendingPathComponent("auth.json")
    try fixture.file(target)
    try fixture.link(auth, to: target.path)
    #expect(throws: CodexHomeLayoutError.privateAuthSymlink) { try fixture.prepare() }
    #expect(try fixture.target(auth) == target.path && fixture.missing(fixture.overlay.appendingPathComponent("sessions")))
    try FileManager.default.removeItem(at: auth)
    #expect(Darwin.link(target.path, auth.path) == 0)
    #expect(throws: CodexHomeLayoutError.entryConflict) { try fixture.prepare() }
    #expect(fixture.missing(fixture.overlay.appendingPathComponent("sessions")))
}

@Test func codexHomePreflightsRealAndForeignLinkConflictsWithoutDeletingAnything() throws {
    let fixture = try CodexHomeFixture(); defer { fixture.remove() }
    let entry = fixture.overlay.appendingPathComponent("sessions")
    try fixture.directory(entry); try fixture.file(entry.appendingPathComponent("native-data"), "must survive")
    #expect(throws: CodexHomeLayoutError.entryConflict) { try fixture.prepare() }
    #expect(try String(contentsOf: entry.appendingPathComponent("native-data"), encoding: .utf8) == "must survive")
    #expect(fixture.missing(fixture.shared.appendingPathComponent("cache")))
    try FileManager.default.removeItem(at: entry)
    try fixture.link(entry, to: fixture.root.appendingPathComponent("foreign-sessions").path)
    let identity = try fixture.identity(entry)
    #expect(throws: CodexHomeLayoutError.entryConflict) { try fixture.prepare() }
    #expect(try fixture.identity(entry) == identity && fixture.missing(fixture.overlay.appendingPathComponent("cache")))
}

@Test func codexHomeRejectsPhysicalAliasesNestedHomesAndPrivateSharingCycles() throws {
    let fixture = try CodexHomeFixture(); defer { fixture.remove() }
    #expect(throws: CodexHomeLayoutError.homeConflict) { try CodexHomeLayout.prepare(sharedHome: fixture.shared, overlayHome: fixture.shared) }
    let alias = fixture.root.appendingPathComponent("alias")
    try fixture.link(alias, to: fixture.shared.path)
    #expect(throws: CodexHomeLayoutError.homeConflict) { try CodexHomeLayout.prepare(sharedHome: fixture.shared, overlayHome: alias) }
    #expect(throws: CodexHomeLayoutError.homeConflict) { try CodexHomeLayout.prepare(sharedHome: fixture.shared, overlayHome: fixture.shared.appendingPathComponent("nested")) }
    #expect(fixture.missing(fixture.shared.appendingPathComponent("nested")))
    try fixture.link(fixture.shared.appendingPathComponent("cycle"), to: fixture.overlay.path)
    #expect(throws: CodexHomeLayoutError.homeConflict) { try fixture.prepare() }
    #expect(fixture.missing(fixture.overlay.appendingPathComponent("sessions")))
}

@Test func codexHomeUsesPhysicalAncestorIdentityForExistingAndNotYetCreatedDirectories() throws {
    let fixture = try CodexHomeFixture(); defer { fixture.remove() }
    let alias = fixture.root.appendingPathComponent("ancestor-alias")
    try fixture.link(alias, to: fixture.root.path)
    let throughAlias = try CodexHomeLayout.prepare(sharedHome: alias.appendingPathComponent("shared"),
                                                  overlayHome: alias.appendingPathComponent("future/overlay"))
    #expect(throughAlias.sharedHome.path == fixture.shared.path)
    #expect(throughAlias.effectiveHome.path == fixture.root.path + "/future/overlay")
    #expect(throughAlias.continuationIdentity == "codex:home:" + fixture.shared.path)
    #expect(try fixture.target(throughAlias.effectiveHome.appendingPathComponent("sessions")) == fixture.shared.path + "/sessions")
    let normal = try CodexHomeLayout.prepare(sharedHome: fixture.shared, overlayHome: fixture.root.appendingPathComponent("future/overlay"))
    #expect(normal == throughAlias)
}

@Test func codexHomeRejectsNonlocalURLsAndLexicalTraversal() throws {
    let fixture = try CodexHomeFixture(); defer { fixture.remove() }
    for invalid in [URL(string: "https://example.com/shared")!, URL(string: "file://foreign.invalid/private/shared")!, URL(string: "file:///private/shared?credential=synthetic")!, URL(string: "file:///private/shared#fragment")!, URL(fileURLWithPath: "/")] {
        #expect(throws: CodexHomeLayoutError.invalidPath) { try CodexHomeLayout.prepare(sharedHome: invalid, overlayHome: fixture.overlay) }
    }
    let traversal = URL(string: "file://" + fixture.root.path + "/shared/../shared")!
    #expect(throws: CodexHomeLayoutError.invalidPath) { try CodexHomeLayout.prepare(sharedHome: traversal, overlayHome: fixture.overlay) }
    #expect(fixture.missing(fixture.overlay.appendingPathComponent("sessions")))
}

@Test func codexHomePreservesNativeLocksWithReceiptIdentityAndResumesAnInterruptedMove() throws {
    let fixture = try CodexHomeFixture(); defer { fixture.remove() }
    let mcp = fixture.overlay.appendingPathComponent("mcp-oauth-locks"), sqlite = fixture.overlay.appendingPathComponent(".sqlite-maintenance.lock")
    try fixture.directory(mcp); try fixture.file(mcp.appendingPathComponent("native-lock"), "retained mcp data")
    try fixture.file(sqlite, "retained sqlite lock"); try fixture.file(fixture.shared.appendingPathComponent(".sqlite-maintenance.lock"), "shared lock")
    let mcpID = try fixture.identity(mcp), sqliteID = try fixture.identity(sqlite)
    let prepared = try fixture.prepare()
    #expect(prepared.preservedRuntimeEntries.count == 2)
    let retainedMCP = try #require(prepared.preservedRuntimeEntries.first { $0.lastPathComponent == "mcp-oauth-locks" })
    let retainedSQLite = try #require(prepared.preservedRuntimeEntries.first { $0.lastPathComponent == ".sqlite-maintenance.lock" })
    #expect(try fixture.identity(retainedMCP) == mcpID && fixture.identity(retainedSQLite) == sqliteID)
    #expect(try String(contentsOf: retainedMCP.appendingPathComponent("native-lock"), encoding: .utf8) == "retained mcp data")
    #expect(try String(contentsOf: retainedSQLite, encoding: .utf8) == "retained sqlite lock")
    #expect(try fixture.prepare() == prepared)
    // Simulate a crash after recording an intent but before moving the exact old inode.
    try FileManager.default.removeItem(at: sqlite)
    try FileManager.default.moveItem(at: retainedSQLite, to: sqlite)
    let recovered = try fixture.prepare()
    let recoveredID = try fixture.identity(retainedSQLite)
    #expect(recovered == prepared && recoveredID == sqliteID)
    #expect(try fixture.target(sqlite) == fixture.shared.path + "/.sqlite-maintenance.lock")
    #expect(try String(contentsOf: fixture.shared.appendingPathComponent(".sqlite-maintenance.lock"), encoding: .utf8) == "shared lock")
}

@Test func codexHomeDoesNotInventSQLiteLockSharingWhenAbsentFromSharedHome() throws {
    let fixture = try CodexHomeFixture(); defer { fixture.remove() }
    let lock = fixture.overlay.appendingPathComponent(".sqlite-maintenance.lock")
    try fixture.file(lock, "private native lock retained")
    let identity = try fixture.identity(lock), prepared = try fixture.prepare()
    #expect(prepared.preservedRuntimeEntries.isEmpty)
    #expect(try fixture.identity(lock) == identity && fixture.missing(fixture.shared.appendingPathComponent(".sqlite-maintenance.lock")))
}

@Test func codexHomeRejectsAnActivelyHeldNativeFileLockAndRecoversWithoutDataLoss() throws {
    let fixture = try CodexHomeFixture(); defer { fixture.remove() }
    let native = fixture.overlay.appendingPathComponent(".sqlite-maintenance.lock")
    try fixture.file(fixture.shared.appendingPathComponent(".sqlite-maintenance.lock"), "shared native lock")
    try fixture.file(native, "held native lock retained")
    let original = try fixture.identity(native)
    let descriptor = Darwin.open(native.path, O_RDWR | O_NOFOLLOW | O_CLOEXEC)
    #expect(descriptor >= 0); guard descriptor >= 0 else { return }
    defer { Darwin.close(descriptor) }
    #expect(flock(descriptor, LOCK_EX | LOCK_NB) == 0)
    #expect(throws: CodexHomeLayoutError.busy) { try fixture.prepare() }
    #expect(try fixture.identity(native) == original)
    #expect(try String(contentsOf: native, encoding: .utf8) == "held native lock retained")
    #expect(flock(descriptor, LOCK_UN) == 0)
    let prepared = try fixture.prepare()
    let retained = try #require(prepared.preservedRuntimeEntries.first)
    #expect(prepared.preservedRuntimeEntries.count == 1)
    #expect(try fixture.identity(retained) == original)
    #expect(try String(contentsOf: retained, encoding: .utf8) == "held native lock retained")
}

@Test func codexHomeRefusesTamperedReceiptsAndRetainedEntries() throws {
    let fixture = try CodexHomeFixture(); defer { fixture.remove() }
    try fixture.directory(fixture.overlay.appendingPathComponent("mcp-oauth-locks"))
    let prepared = try fixture.prepare()
    let retained = try #require(prepared.preservedRuntimeEntries.first)
    let foreign = fixture.root.appendingPathComponent("foreign-replacement")
    try fixture.directory(foreign)
    try FileManager.default.removeItem(at: retained)
    try FileManager.default.moveItem(at: foreign, to: retained)
    #expect(throws: CodexHomeLayoutError.ownershipLost) { try fixture.prepare() }
    let marker = fixture.overlay.appendingPathComponent(".coincide-codex-home-layout.json")
    let metadataData = try Data(contentsOf: marker)
    let decoded = try JSONSerialization.jsonObject(with: metadataData) as? [String: Any]
    var object = try #require(decoded)
    object["sharedPath"] = fixture.root.appendingPathComponent("foreign").path
    try JSONSerialization.data(withJSONObject: object).write(to: marker)
    #expect(throws: CodexHomeLayoutError.ownershipLost) { try fixture.prepare() }
    #expect(FileManager.default.fileExists(atPath: retained.path))
}

@Test func codexHomeSerializesMaterializersWithBoundedOwnedLockAndRejectsForeignLockLinks() throws {
    let fixture = try CodexHomeFixture(); defer { fixture.remove() }
    _ = try fixture.prepare()
    let lock = fixture.overlay.appendingPathComponent(".coincide-codex-home-layout.lock")
    let file = Darwin.open(lock.path, O_RDWR | O_NOFOLLOW | O_CLOEXEC)
    #expect(file >= 0); guard file >= 0 else { return }
    defer { Darwin.close(file) }
    #expect(flock(file, LOCK_EX | LOCK_NB) == 0)
    #expect(throws: CodexHomeLayoutError.busy) { try fixture.prepare() }
    #expect(flock(file, LOCK_UN) == 0)
    _ = try fixture.prepare()
    try FileManager.default.removeItem(at: lock)
    let foreign = fixture.root.appendingPathComponent("foreign-lock"); try fixture.file(foreign, "foreign bytes retained")
    try fixture.link(lock, to: foreign.path)
    #expect(throws: CodexHomeLayoutError.ownershipLost) { try fixture.prepare() }
    #expect(try String(contentsOf: foreign, encoding: .utf8) == "foreign bytes retained")
}

@Test func codexHomeCancellationDoesNotCreateSharedLinksOrLeakPrivatePathsInErrors() async throws {
    let fixture = try CodexHomeFixture(); defer { fixture.remove() }
    let gate = CodexHomeCancellationGate()
    let task = Task.detached {
        await gate.wait()
        return try fixture.prepare()
    }
    task.cancel(); await gate.release()
    do { _ = try await task.value; Issue.record("A cancelled layout unexpectedly succeeded.") }
    catch { #expect(error as? CodexHomeLayoutError == .cancelled) }
    #expect(fixture.missing(fixture.overlay.appendingPathComponent("sessions")))
    for error in [CodexHomeLayoutError.invalidPath, .homeConflict, .privateAuthSymlink, .entryConflict, .ownershipLost, .busy, .io, .cancelled] {
        #expect(!error.localizedDescription.contains(fixture.root.path) && !error.localizedDescription.contains("synthetic"))
    }
}
