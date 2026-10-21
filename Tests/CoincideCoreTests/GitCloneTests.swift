import Foundation
import Testing
import Darwin
@testable import CoincideCore

private actor CloneProgressLog {
    var values: [GitCloneProgress] = []
    func append(_ value: GitCloneProgress) { values.append(value) }
    func contains(_ predicate: @Sendable (GitCloneProgress) -> Bool) -> Bool { values.contains(where: predicate) }
    func count() -> Int { values.count }
}

@discardableResult private func cloneGit(_ root: URL, _ args: [String]) async throws -> String {
    let result = try await CommandRunner.run("git", ["-C", root.path] + args)
    guard result.status == 0 else { throw CoincideError("Clone fixture Git failed: " + String(decoding: result.error, as: UTF8.self)) }
    return result.text.trimmingCharacters(in: .newlines)
}
private func cloneSource(_ parent: URL) async throws -> URL {
    let source = parent.appendingPathComponent("source repo")
    try FileManager.default.createDirectory(at: source, withIntermediateDirectories: true)
    try await cloneGit(source, ["init", "--initial-branch=main"])
    for (key, value) in [("user.name", "Coincide Test"), ("user.email", "test@example.invalid"), ("commit.gpgSign", "false"), ("core.hooksPath", "/dev/null")] {
        try await cloneGit(source, ["config", "--local", key, value])
    }
    try "native clone 🌍\n".write(to: source.appendingPathComponent("hello world.txt"), atomically: true, encoding: .utf8)
    try await cloneGit(source, ["add", "--", "."]); try await cloneGit(source, ["commit", "-m", "Fixture"])
    let bare = parent.appendingPathComponent("remote.git")
    try await cloneGit(parent, ["clone", "--bare", "--", source.path, bare.path])
    return bare
}
private func cloneEventually(_ condition: @escaping @Sendable () async -> Bool) async throws {
    let deadline = ContinuousClock.now.advanced(by: .seconds(5))
    while !(await condition()) {
        guard ContinuousClock.now < deadline else { throw CoincideError("Clone fixture did not reach its expected state.") }
        try await Task.sleep(for: .milliseconds(10))
    }
}

@Test func gitClonePlanValidatesCredentialFreeSourcesAndJournalPathsWithoutMutatingDisk() throws {
    let parent = try temporaryWorkspace(); defer { try? FileManager.default.removeItem(at: parent) }
    let destination = parent.appendingPathComponent("clone with spaces $(literal)")
    let valid = ["https://github.com/example/repo.git", "http://localhost:1234/repo.git", "ssh://git@example.invalid:2222/repo.git",
                 "git://example.invalid/repo.git", "ssh://git@[::1]:2222/repo.git", "git@example.invalid:org/repo.git", "example.invalid:org/repo.git",
                 "file:///tmp/local%20repo.git", "/tmp/local repo.git", "./local:repo", "../relative repo", "~/repo"]
    for source in valid {
        let plan = try GitClonePlan.prepare(source: source, destination: destination)
        try plan.validate()
        #expect(plan.stagingPath.hasPrefix(parent.resolvingSymlinksInPath().path + "/.coincide-clone-"))
        #expect(!FileManager.default.fileExists(atPath: plan.stagingPath))
        #expect(try JSONDecoder().decode(GitClonePlan.self, from: JSONEncoder().encode(plan)) == plan)
        if source == "./local:repo" { #expect(plan.source.hasPrefix("/")) }
    }
    for source in ["", "--upload-pack=touch /tmp/no", "-repo", "ext::touch pwned", "https://user:password@example.invalid/r",
                   "https://user@example.invalid/r", "https://example.invalid/r?token=secret", "https://example.invalid/r#secret",
                   "ssh://user:password@example.invalid/r", "ssh://user%3Apassword@example.invalid/r", "ssh://-option@example.invalid/r",
                   "ssh://host:99999/r", "ftp://example.invalid/r", "custom://host/r", "file://user@localhost/tmp/r",
                   "https://host/r%0aarg", "https://host/r\n", "git@example.invalid:r?token=secret", "git@example.invalid:r#fragment",
                   "user:password@host:repo", "user@-option:repo", "host:-option", "bad\0source"] {
        #expect(throws: (any Error).self) { try GitClonePlan.prepare(source: source, destination: destination) }
    }
    let plan = try GitClonePlan.prepare(source: valid[0], destination: destination)
    try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: true)
    try plan.validate() // Completed/missing projects remain decodable; validation does not enforce absence.
    #expect(throws: (any Error).self) { try GitClonePlan.prepare(source: valid[0], destination: destination) }
    var object = try #require(JSONSerialization.jsonObject(with: JSONEncoder().encode(plan)) as? [String: Any])
    object["stagingPath"] = parent.appendingPathComponent("not-owned").path
    let invalid = try JSONDecoder().decode(GitClonePlan.self, from: JSONSerialization.data(withJSONObject: object))
    #expect(throws: (any Error).self) { try invalid.validate() }
    #expect(try FileManager.default.contentsOfDirectory(atPath: parent.path) == [destination.lastPathComponent])
}

@Test func gitCloneRealBareRemotePromotesRepositoryPreservesRemoteAndCompletesIdempotently() async throws {
    let parent = try temporaryWorkspace(); defer { try? FileManager.default.removeItem(at: parent) }
    let remote = try await cloneSource(parent), destination = parent.appendingPathComponent("native checkout")
    let plan = try GitClonePlan.prepare(source: remote.absoluteString, destination: destination)
    let service = GitCloneService(plan: plan), progress = CloneProgressLog()
    #expect(try await !service.isCompleted())
    try await service.run { await progress.append($0) }
    #expect(try await service.isCompleted())
    #expect(try String(contentsOf: destination.appendingPathComponent("hello world.txt"), encoding: .utf8) == "native clone 🌍\n")
    #expect(try await cloneGit(destination, ["remote", "get-url", "origin"]) == remote.absoluteString)
    #expect(try await GitService(root: destination).status().branch == "main")
    #expect(try await GitService(root: destination).status().isClean)
    #expect(await progress.contains { $0.stage == .checkout && $0.percent == 100 })
    let head = try await cloneGit(destination, ["rev-parse", "HEAD"])
    try "user edit".write(to: destination.appendingPathComponent("hello world.txt"), atomically: true, encoding: .utf8)
    try await service.run { _ in Issue.record("An idempotent completed clone must not run another process or update progress.") }
    #expect(try await cloneGit(destination, ["rev-parse", "HEAD"]) == head)
    #expect(try String(contentsOf: destination.appendingPathComponent("hello world.txt"), encoding: .utf8) == "user edit")
    #expect(try FileManager.default.attributesOfItem(atPath: plan.stagingPath)[.posixPermissions] as? Int == 0o700)
    #expect(try FileManager.default.attributesOfItem(atPath: destination.appendingPathComponent(".git/coincide-clone.json").path)[.posixPermissions] as? Int == 0o600)
    // A replacement copy may carry the marker, but its device/inode does not identify the promoted checkout.
    let replaced = parent.appendingPathComponent("original moved by user")
    try FileManager.default.moveItem(at: destination, to: replaced)
    try FileManager.default.copyItem(at: replaced, to: destination)
    #expect(try await !service.isCompleted())
    await #expect(throws: (any Error).self) { try await service.run { _ in } }
    #expect(try String(contentsOf: destination.appendingPathComponent("hello world.txt"), encoding: .utf8) == "user edit")
}

@Test func gitCloneRecoversCompletedStagingAfterInterruptedPromotionAndNeverOverwritesDestinationRaces() async throws {
    let parent = try temporaryWorkspace(); defer { try? FileManager.default.removeItem(at: parent) }
    let remote = try await cloneSource(parent), destination = parent.appendingPathComponent("recovered")
    let plan = try GitClonePlan.prepare(source: remote.path, destination: destination), service = GitCloneService(plan: plan)
    try await service.run { _ in }
    let checkout = URL(fileURLWithPath: plan.stagingPath).appendingPathComponent("checkout")
    try FileManager.default.moveItem(at: destination, to: checkout) // Exact crash boundary before promotion.
    #expect(try await !service.isCompleted())
    try "other person's data".write(to: destination, atomically: true, encoding: .utf8)
    await #expect(throws: (any Error).self) { try await service.run { _ in } }
    #expect(try String(contentsOf: destination, encoding: .utf8) == "other person's data")
    #expect(FileManager.default.fileExists(atPath: checkout.appendingPathComponent("hello world.txt").path))
    try FileManager.default.removeItem(at: destination) // Fixture-owned racing file only.
    try await service.run { _ in }
    #expect(try await service.isCompleted())
    let racePlan = try GitClonePlan.prepare(source: remote.path, destination: parent.appendingPathComponent("race"))
    let raceTarget = URL(fileURLWithPath: racePlan.destinationPath)
    let created = CloneRaceOnce(target: raceTarget)
    await #expect(throws: (any Error).self) {
        try await GitCloneService(plan: racePlan).run { _ in try? await created.create() }
    }
    #expect(try String(contentsOf: raceTarget.appendingPathComponent("preserve.txt"), encoding: .utf8) == "race content")
    let raceCheckout = URL(fileURLWithPath: racePlan.stagingPath).appendingPathComponent("checkout")
    #expect(FileManager.default.fileExists(atPath: raceCheckout.appendingPathComponent(".git/coincide-clone.json").path))
}

private actor CloneRaceOnce {
    let target: URL
    var created = false
    init(target: URL) { self.target = target }
    func create() throws {
        guard !created else { return }; created = true
        try FileManager.default.createDirectory(at: target, withIntermediateDirectories: true)
        try "race content".write(to: target.appendingPathComponent("preserve.txt"), atomically: true, encoding: .utf8)
    }
}

@Test func gitCloneParserHandlesSplitCRLFStagesRatesRedactionAndUnboundedRemoteNoise() throws {
    var parser = GitCloneProgressParser(), updates: [GitCloneProgress] = []
    for fragment in ["remote: Enum", "erating objects: 10, done.\rremote: Counting objects:  50% (5/10)\r\nReceiv", "ing objects: 101% (10/10), 1.2 MiB | 4.2 MiB/s, done.\rResolving deltas:  -1% (1/2)\r", "Updating files: 100% (10/10), done.\n"] {
        updates += parser.consume(Data(fragment.utf8))
    }
    #expect(updates.map(\.stage) == [.counting, .counting, .receiving, .resolving, .checkout])
    #expect(updates[1].percent == 50 && updates[2].percent == 100 && updates[2].detail == "1.2 MiB | 4.2 MiB/s")
    #expect(updates.last?.percent == 100 && updates.last?.detail == nil)
    _ = parser.consume(Data((String(repeating: "x", count: 2_000_000) + "\n").utf8))
    #expect(parser.pendingByteCount == 0 && parser.discardedBytes > 0 && parser.tail.joined().utf8.count <= 4_096)
    _ = parser.consume(Data("fatal: cannot fetch 'https://private-user:private-pass@host/repo?token=private-token#secret'\nfatal: final error".utf8))
    _ = parser.finish()
    let error = try #require(parser.errorDetail)
    #expect(error.contains("https://host/repo") && error.contains("final error"))
    for secret in ["private-user", "private-pass", "private-token", "#secret"] { #expect(!error.contains(secret)) }
}

private func cloneProcessFixture(_ parent: URL, mode: String, plan: GitClonePlan, stallAfter: Duration = .milliseconds(60), testHooks: GitCloneProcessTestHooks? = nil) throws -> GitCloneService {
    let script = parent.appendingPathComponent("clone-fixture.py")
    if !FileManager.default.fileExists(atPath: script.path) {
        let python = ProcessChannel.findExecutable("python3")?.path ?? "/usr/bin/python3"
        let code = #"""
        import os, signal, subprocess, sys, time
        root = sys.argv[-1]
        os.makedirs(root + '/.git')
        with open(root + '/partial.txt', 'w') as f: f.write('preserve partial checkout')
        with open(os.environ['CLONE_ARGV'], 'w') as f: f.write('\n'.join(sys.argv[1:]))
        mode = os.environ['CLONE_MODE']
        if mode == 'fail':
            sys.stderr.write('fatal: failed https://user:password@host/repo?token=secret\n')
            sys.exit(17)
        if mode == 'pressurefail':
            payload = ''.join('Receiving objects: %d%% (%d/40000), data 🌍\r' % (i % 100, i) for i in range(40000))
            sys.stdout.write('password=stdout-secret\n'); sys.stdout.flush()
            sys.stderr.buffer.write(payload.encode()); sys.stderr.flush()
            sys.stderr.write('fatal: final pressure 🌍 https://private-user:private-password@host/repo?token=private-token\n'); sys.stderr.flush()
            sys.exit(17)
        sys.stderr.write('Receiving objects: 25% (1/4), 1 MiB | 2 MiB/s\r'); sys.stderr.flush()
        if mode == 'gated':
            with open(os.environ['CLONE_READY'], 'w') as f: f.write('ready')
            while not os.path.exists(os.environ['CLONE_RELEASE']): time.sleep(.01)
            with open(root + '/after-gate.txt', 'w') as f: f.write('written to original cwd')
            sys.exit(0)
        if mode == 'complete':
            with open(root + '/hello.txt', 'w') as f: f.write('complete fixture')
            sys.exit(0)
        if mode == 'observerloss':
            holder = "import os,time; open(os.environ['CLONE_READY'],'w').write('ready'); deadline=time.monotonic()+10;\nwhile not os.path.exists(os.environ['CLONE_RELEASE']) and time.monotonic()<deadline: time.sleep(.01)\nopen(os.environ['CLONE_HELPER_DONE'],'w').write('done')"
            subprocess.Popen([sys.executable, '-c', holder])
            while not os.path.exists(os.environ['CLONE_READY']): time.sleep(.01)
            sys.exit(0)
        if mode == 'pressureblocked':
            payload = b'Receiving objects: 25% (1/4), data\r' * 50000
            while True: sys.stderr.buffer.write(payload); sys.stderr.flush()
        child = subprocess.Popen([sys.executable, '-c', "import os,signal,time; signal.signal(signal.SIGTERM,signal.SIG_IGN); p=os.environ['CLONE_HEARTBEAT'];\nwhile True:\n open(p,'w').write(str(time.monotonic())); time.sleep(.02)"])
        with open(os.environ['CLONE_PID'], 'w') as f: f.write(str(child.pid))
        while True: time.sleep(.1)
        """#
        try ("#!" + python + "\n" + code + "\n").write(to: script, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: script.path)
    }
    var env = ProcessChannel.environment()
    env["CLONE_MODE"] = mode; env["CLONE_ARGV"] = parent.appendingPathComponent("argv.txt").path
    env["CLONE_PID"] = parent.appendingPathComponent("child.pid").path; env["CLONE_HEARTBEAT"] = parent.appendingPathComponent("heartbeat.txt").path
    env["CLONE_READY"] = parent.appendingPathComponent("clone.ready").path; env["CLONE_RELEASE"] = parent.appendingPathComponent("clone.release").path
    env["CLONE_HELPER_DONE"] = parent.appendingPathComponent("clone.helper-done").path
    return GitCloneService(plan: plan, stallAfter: stallAfter, executable: script, environment: env, testHooks: testHooks)
}

@Test func gitCloneCancellationStopsOwnedDescendantsWaitsForExitPreservesPartialsAndRetryUsesNewAttempt() async throws {
    let parent = try temporaryWorkspace(); defer { try? FileManager.default.removeItem(at: parent) }
    let destination = parent.appendingPathComponent("cancelled"), plan = try GitClonePlan.prepare(source: "https://example.invalid/repo", destination: destination)
    let service = try cloneProcessFixture(parent, mode: "blocked", plan: plan), progress = CloneProgressLog()
    let task = Task { try await service.run { await progress.append($0) } }
    do {
        try await cloneEventually { FileManager.default.fileExists(atPath: parent.appendingPathComponent("heartbeat.txt").path) }
        try await cloneEventually { await progress.contains { $0.stalled && $0.stage == .receiving } }
    } catch { task.cancel(); _ = await task.result; throw error }
    await #expect(throws: (any Error).self) { try await service.run { _ in } }
    let start = ContinuousClock.now; task.cancel()
    switch await task.result { case .success: Issue.record("Cancelled clone reported success."); case .failure(let error): #expect(error is CancellationError) }
    #expect(start.duration(to: .now) < .seconds(4))
    let heartbeat = parent.appendingPathComponent("heartbeat.txt"), stopped = try String(contentsOf: heartbeat, encoding: .utf8)
    try await Task.sleep(for: .milliseconds(100))
    #expect(try String(contentsOf: heartbeat, encoding: .utf8) == stopped) // SIGTERM-ignoring descendant was killed.
    #expect(try await !service.isCompleted() && !FileManager.default.fileExists(atPath: destination.path))
    let partial = URL(fileURLWithPath: plan.stagingPath).appendingPathComponent("checkout/partial.txt")
    #expect(try String(contentsOf: partial, encoding: .utf8) == "preserve partial checkout")
    await #expect(throws: (any Error).self) { try await service.run { _ in } }
    let retry = try GitClonePlan.prepare(source: plan.source, destination: destination)
    #expect(retry.id != plan.id && retry.stagingPath != plan.stagingPath)
    try await cloneProcessFixture(parent, mode: "complete", plan: retry).run { _ in }
    #expect(try await GitCloneService(plan: retry).isCompleted())
    #expect(try String(contentsOf: partial, encoding: .utf8) == "preserve partial checkout")
    let argv = try String(contentsOf: parent.appendingPathComponent("argv.txt"), encoding: .utf8)
    #expect(argv.contains("clone\n--progress\n--no-recurse-submodules\n--\n" + plan.source + "\n"))
}

@Test func gitCloneFailureRedactsErrorsAndUnknownOrSymlinkStagingIsNeverOverwritten() async throws {
    let parent = try temporaryWorkspace(); defer { try? FileManager.default.removeItem(at: parent) }
    let plan = try GitClonePlan.prepare(source: "https://example.invalid/repo", destination: parent.appendingPathComponent("failed"))
    do { try await cloneProcessFixture(parent, mode: "fail", plan: plan).run { _ in }; Issue.record("Fixture failure was accepted.") }
    catch {
        let text = String(describing: error)
        #expect(!text.contains("password") && !text.contains("token=secret") && !text.contains("user@"))
    }
    let checkout = URL(fileURLWithPath: plan.stagingPath).appendingPathComponent("checkout/partial.txt")
    #expect(try String(contentsOf: checkout, encoding: .utf8) == "preserve partial checkout")
    let unknown = try GitClonePlan.prepare(source: plan.source, destination: parent.appendingPathComponent("unknown"))
    let unrelated = parent.appendingPathComponent("unrelated")
    try FileManager.default.createDirectory(at: unrelated, withIntermediateDirectories: true)
    try "precious".write(to: unrelated.appendingPathComponent("data"), atomically: true, encoding: .utf8)
    try FileManager.default.createSymbolicLink(atPath: unknown.stagingPath, withDestinationPath: unrelated.path)
    await #expect(throws: (any Error).self) { try await GitCloneService(plan: unknown).run { _ in } }
    #expect(try String(contentsOf: unrelated.appendingPathComponent("data"), encoding: .utf8) == "precious")
    #expect(try FileManager.default.contentsOfDirectory(atPath: unrelated.path) == ["data"])
}

@Test func gitCloneBackpressurePreservesEveryProgressFrameUTF8AndRedactionBeyondTheBufferLimit() async throws {
    let parent = try temporaryWorkspace(); defer { try? FileManager.default.removeItem(at: parent) }
    let plan = try GitClonePlan.prepare(source: "https://example.invalid/repo", destination: parent.appendingPathComponent("pressure"))
    let service = try cloneProcessFixture(parent, mode: "pressurefail", plan: plan, stallAfter: .seconds(20)), progress = CloneProgressLog()
    do {
        try await service.run { value in
            if value.stage == .connecting { try? await Task.sleep(for: .milliseconds(100)) }
            await progress.append(value)
        }
        Issue.record("Failure fixture unexpectedly succeeded.")
    } catch {
        let error = String(describing: error)
        #expect(error.contains("final pressure 🌍") && error.contains("https://host/repo"))
        for secret in ["private-user", "private-password", "private-token", "stdout-secret"] { #expect(!error.contains(secret)) }
    }
    #expect(await progress.count() == 40_001) // Connecting plus every redraw, with no dropped raw chunks.
    #expect(await progress.contains { $0.detail == "data 🌍" && $0.percent == 99 })
}

@Test func gitCloneCancellationUnderContinuousOutputPressureUnblocksProducersAndAwaitsExit() async throws {
    let parent = try temporaryWorkspace(); defer { try? FileManager.default.removeItem(at: parent) }
    let plan = try GitClonePlan.prepare(source: "https://example.invalid/repo", destination: parent.appendingPathComponent("pressure-cancel"))
    let service = try cloneProcessFixture(parent, mode: "pressureblocked", plan: plan), progress = CloneProgressLog()
    let task = Task {
        try await service.run { value in
            if value.stage == .receiving { try? await Task.sleep(for: .milliseconds(20)) }
            await progress.append(value)
        }
    }
    do { try await cloneEventually { await progress.contains { $0.stage == .receiving } } }
    catch { task.cancel(); _ = await task.result; throw error }
    let start = ContinuousClock.now; task.cancel()
    switch await task.result { case .success: Issue.record("Cancelled pressure fixture succeeded."); case .failure(let error): #expect(error is CancellationError) }
    #expect(start.duration(to: .now) < .seconds(4))
    #expect(try await !service.isCompleted())
    #expect(FileManager.default.fileExists(atPath: plan.stagingPath + "/checkout/partial.txt"))
}

@Test(arguments: ["checkout", "staging", "parent"])
func gitCloneDirectoryReplacementNeverMarksOrPromotesForeignDirectories(_ replacement: String) async throws {
    let root = try temporaryWorkspace(); defer { try? FileManager.default.removeItem(at: root) }
    let parent = root.appendingPathComponent("parent"), manager = FileManager.default
    try manager.createDirectory(at: parent, withIntermediateDirectories: true)
    let destination = parent.appendingPathComponent("destination")
    let plan = try GitClonePlan.prepare(source: "https://example.invalid/repo", destination: destination)
    let service = try cloneProcessFixture(root, mode: "gated", plan: plan)
    let task = Task { try await service.run { _ in } }
    do { try await cloneEventually { FileManager.default.fileExists(atPath: root.appendingPathComponent("clone.ready").path) } }
    catch { task.cancel(); _ = await task.result; throw error }
    let staging = URL(fileURLWithPath: plan.stagingPath), checkout = staging.appendingPathComponent("checkout")
    let moved = root.appendingPathComponent("original-" + replacement)
    let originalCheckout: URL
    do {
        switch replacement {
        case "checkout":
            try manager.moveItem(at: checkout, to: moved); originalCheckout = moved
        case "staging":
            try manager.moveItem(at: staging, to: moved); originalCheckout = moved.appendingPathComponent("checkout")
        default:
            try manager.moveItem(at: parent, to: moved)
            originalCheckout = moved.appendingPathComponent(staging.lastPathComponent).appendingPathComponent("checkout")
        }
        try manager.createDirectory(at: checkout.appendingPathComponent(".git"), withIntermediateDirectories: true)
        try "foreign data".write(to: checkout.appendingPathComponent("preserve.txt"), atomically: true, encoding: .utf8)
        try "release".write(to: root.appendingPathComponent("clone.release"), atomically: true, encoding: .utf8)
    } catch { task.cancel(); _ = await task.result; throw error }
    switch await task.result {
    case .success: Issue.record("A replaced clone directory was accepted.")
    case .failure(let error): #expect(String(describing: error).contains("moved or replaced"))
    }
    #expect(try String(contentsOf: originalCheckout.appendingPathComponent("after-gate.txt"), encoding: .utf8) == "written to original cwd")
    #expect(try String(contentsOf: checkout.appendingPathComponent("preserve.txt"), encoding: .utf8) == "foreign data")
    #expect(!manager.fileExists(atPath: checkout.appendingPathComponent("after-gate.txt").path))
    #expect(!manager.fileExists(atPath: checkout.appendingPathComponent(".git/coincide-clone.json").path))
    #expect(!manager.fileExists(atPath: originalCheckout.appendingPathComponent(".git/coincide-clone.json").path))
    #expect(!manager.fileExists(atPath: destination.path))
}

private final class CloneSignalLog: @unchecked Sendable {
    private let lock = NSLock()
    private var signals: [Int32] = []
    func record(_ signal: Int32) { lock.withLock { signals.append(signal) } }
    var count: Int { lock.withLock { signals.count } }
}

@Test func gitCloneLostChildOwnershipNeverSignalsAnUnknownGroupAndClosesOnlyItsReaders() async throws {
    let root = try temporaryWorkspace(); defer { try? FileManager.default.removeItem(at: root) }
    let plan = try GitClonePlan.prepare(source: "https://example.invalid/repo", destination: root.appendingPathComponent("observer-loss"))
    let signals = CloneSignalLog()
    let hooks = GitCloneProcessTestHooks(observeExit: { pid in
        // Model another reaper observing/reaping the actual fixture child. An unrelated helper
        // retains its pipes until explicitly released; production must close only its readers.
        var raw: Int32 = 0, result: pid_t
        repeat { result = waitpid(pid, &raw, 0) } while result == -1 && errno == EINTR
        errno = ECHILD; return -1
    }, signalGroup: { _, signal in signals.record(signal) })
    let service = try cloneProcessFixture(root, mode: "observerloss", plan: plan, testHooks: hooks)
    await #expect(throws: (any Error).self) { try await service.run { _ in } }
    #expect(FileManager.default.fileExists(atPath: root.appendingPathComponent("clone.ready").path))
    #expect(!FileManager.default.fileExists(atPath: root.appendingPathComponent("clone.helper-done").path))
    #expect(signals.count == 0)
    #expect(!FileManager.default.fileExists(atPath: plan.destinationPath))
    // Release the holder and await natural exit without a timing race or any PID signal.
    try "release".write(to: root.appendingPathComponent("clone.release"), atomically: true, encoding: .utf8)
    try await cloneEventually { FileManager.default.fileExists(atPath: root.appendingPathComponent("clone.helper-done").path) }
    #expect(signals.count == 0)
}

@Test func gitCloneOwnershipMetadataFIFOsAreRejectedWithoutBlockingBeforeFileTypeValidation() async throws {
    let root = try temporaryWorkspace(); defer { try? FileManager.default.removeItem(at: root) }
    let plan = try GitClonePlan.prepare(source: "https://example.invalid/repo", destination: root.appendingPathComponent("fifo-metadata"))
    let service = try cloneProcessFixture(root, mode: "complete", plan: plan)
    try await service.run { _ in }
    let marker = URL(fileURLWithPath: plan.destinationPath).appendingPathComponent(".git/coincide-clone.json")
    try FileManager.default.removeItem(at: marker)
    #expect(mkfifo(marker.path, 0o600) == 0)
    let started = ContinuousClock.now
    await #expect(throws: (any Error).self) { _ = try await service.isCompleted() }
    #expect(started.duration(to: .now) < .seconds(1))
    let partial = try GitClonePlan.prepare(source: plan.source, destination: root.appendingPathComponent("fifo-plan"))
    await #expect(throws: (any Error).self) { try await cloneProcessFixture(root, mode: "fail", plan: partial).run { _ in } }
    let owner = URL(fileURLWithPath: partial.stagingPath).appendingPathComponent("plan.json")
    let ownerData = try Data(contentsOf: owner)
    try FileManager.default.removeItem(at: owner)
    #expect(mkfifo(owner.path, 0o600) == 0)
    let retryStarted = ContinuousClock.now
    await #expect(throws: (any Error).self) { try await GitCloneService(plan: partial).run { _ in } }
    #expect(retryStarted.duration(to: .now) < .seconds(1))
    try FileManager.default.removeItem(at: owner); try ownerData.write(to: owner)
    let lock = URL(fileURLWithPath: partial.stagingPath).appendingPathComponent("lock")
    try FileManager.default.removeItem(at: lock)
    #expect(mkfifo(lock.path, 0o600) == 0)
    let lockStarted = ContinuousClock.now
    await #expect(throws: (any Error).self) { try await GitCloneService(plan: partial).run { _ in } }
    #expect(lockStarted.duration(to: .now) < .seconds(1))
    var node = stat(); #expect(lstat(lock.path, &node) == 0 && node.st_mode & S_IFMT == S_IFIFO)
}
