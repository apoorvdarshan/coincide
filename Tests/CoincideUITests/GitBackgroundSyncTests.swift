import AppKit
import CoincideCore
import Darwin
import SwiftUI
import Testing
@testable import Coincide

@discardableResult private func syncGit(_ root: URL, _ args: [String]) async throws -> String {
    let result = try await CommandRunner.run("git", ["-C", root.path] + args)
    guard result.status == 0 else { throw CoincideError("Fixture Git failed: " + String(decoding: result.error, as: UTF8.self)) }
    return result.text.trimmingCharacters(in: .whitespacesAndNewlines)
}

@MainActor private final class SyncProbe {
    var busy: Set<String> = []
    var changed: [String] = []
}

@MainActor @Test(.timeLimit(.minutes(1)), arguments: [false, true])
func backgroundSyncPublishesItsInspectorLeaseAndJoinsHeldFetchOnShutdown(cancelFetch: Bool) async throws {
    let f = try await StackedActionFixture.make()
    let suite = "coincide.sync.lease." + UUID().uuidString
    let defaults = try #require(UserDefaults(suiteName: suite))
    defer { defaults.removePersistentDomain(forName: suite) }
    let entered = f.root.appendingPathComponent("fetch-entered"), release = f.root.appendingPathComponent("fetch-release")
    let wrapper = f.root.appendingPathComponent("private-upload-pack")
    func quote(_ value: String) -> String { "'" + value.replacingOccurrences(of: "'", with: "'\\''") + "'" }
    let execPath = try await syncGit(f.repository, ["--exec-path"])
    let native = URL(fileURLWithPath: execPath).appendingPathComponent("git-upload-pack")
    let shell = "#!/bin/sh\ntrap 'exit 130' HUP INT TERM\nprintf '%s\\n' \"$$\" > " + quote(entered.path) +
        "\nattempt=0\nwhile [ ! -f " + quote(release.path) + " ] && [ \"$attempt\" -lt 500 ]; do /bin/sleep 0.02; attempt=$((attempt + 1)); done\n" +
        "[ -f " + quote(release.path) + " ] || exit 79\nexec " + quote(native.path) + " \"$@\"\n"
    try shell.write(to: wrapper, atomically: true, encoding: .utf8)
    try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: wrapper.path)
    try await syncGit(f.repository, ["config", "--local", "remote.origin.uploadpack", wrapper.path])
    let target = GitBackgroundSyncStore.Target(path: f.repository.path, projectID: f.workspace.snapshot.projects.first?.id)
    let sync = GitBackgroundSyncStore(dependencies: .init(demandTargets: { [target] }, launchTargets: { [] },
        canSync: { f.workspace.canEditWorkspace($0) }, didChange: { _ in }, inspector: { _ in f.inspector }),
        preferences: .init(defaults: defaults))
    let fetch = Task { await sync.sync(target, fetch: true) }
    do {
        let deadline = ContinuousClock.now + .seconds(5)
        while !FileManager.default.fileExists(atPath: entered.path), ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(20))
        }
        #expect(FileManager.default.fileExists(atPath: entered.path))
        let pid = try #require(Int32(String(contentsOf: entered, encoding: .utf8).trimmingCharacters(in: .whitespacesAndNewlines)))
        #expect(pid > 1 && kill(pid, 0) == 0 && f.inspector.operationName != nil)
        #expect(f.inspector.runExclusive("A competing mutation must not begin", operation: { Issue.record("Background fetch lost its registered lease") }) == nil)
        if cancelFetch { await sync.shutdown() }
        else { try Data().write(to: release) }
        let result = await fetch.value
        if cancelFetch { #expect(result == .skipped("cancelled")) }
        else { #expect(result == .fetched(pulled: false, decision: .skip(.disabled))) }
        #expect(f.inspector.operationName == nil, "Shutdown must release the inspector lease only after its owned fetch joins.")
        // CommandRunner owns the direct Git child, not upload-pack descendants.
        // Release and join this fixture's separate helper after inspecting shutdown.
        if cancelFetch { try Data().write(to: release) }
        let cleanupDeadline = ContinuousClock.now + .seconds(5)
        while kill(pid, 0) == 0, ContinuousClock.now < cleanupDeadline {
            try await Task.sleep(for: .milliseconds(20))
        }
        let processStatus = kill(pid, 0), processError = errno
        #expect(processStatus == -1, "The exact private upload-pack PID must be gone after its explicit fixture release.")
        #expect(processError == ESRCH, "The private upload-pack must be absent, not merely inaccessible.")
        await sync.shutdown()
    } catch {
        try? Data().write(to: release)
        await sync.shutdown(); _ = await fetch.value; await f.finish(); throw error
    }
    await f.finish()
}

@MainActor @Test(.timeLimit(.minutes(1))) func backgroundSyncFetchesAndOnlyFastForwardsACleanDefaultBranchWhenEnabled() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("coincide-sync-" + UUID().uuidString).standardizedFileURL.resolvingSymlinksInPath()
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }
    let remote = root.appendingPathComponent("remote.git"), local = root.appendingPathComponent("local"), other = root.appendingPathComponent("other")
    try await syncGit(root, ["init", "-q", "--bare", "--initial-branch=main", remote.path])
    try await syncGit(root, ["clone", "-q", "--", remote.path, local.path])
    for repository in [local] {
        for (key, value) in [("user.name", "Coincide Test"), ("user.email", "test@example.invalid"), ("commit.gpgSign", "false"), ("core.hooksPath", root.appendingPathComponent("no-hooks").path)] {
            try await syncGit(repository, ["config", "--local", key, value])
        }
    }
    try "one\n".write(to: local.appendingPathComponent("file.txt"), atomically: true, encoding: .utf8)
    try await syncGit(local, ["add", "file.txt"]); try await syncGit(local, ["commit", "-q", "-m", "one"])
    try await syncGit(local, ["push", "-q", "-u", "origin", "main"]); try await syncGit(local, ["remote", "set-head", "origin", "main"])
    try await syncGit(root, ["clone", "-q", "--", remote.path, other.path])
    for (key, value) in [("user.name", "Other"), ("user.email", "other@example.invalid"), ("commit.gpgSign", "false")] { try await syncGit(other, ["config", "--local", key, value]) }
    func advanceRemote(_ text: String) async throws {
        try text.write(to: other.appendingPathComponent("file.txt"), atomically: true, encoding: .utf8)
        try await syncGit(other, ["commit", "-q", "-am", text]); try await syncGit(other, ["push", "-q", "origin", "main"])
    }
    let suite = "coincide.sync.tests." + UUID().uuidString, defaults = try #require(UserDefaults(suiteName: suite))
    defer { defaults.removePersistentDomain(forName: suite) }
    let preferences = SourceControlSyncPreferences(defaults: defaults)
    let probe = SyncProbe(), projectID = UUID(), target = GitBackgroundSyncStore.Target(path: local.path, projectID: projectID)
    let sync = GitBackgroundSyncStore(dependencies: .init(demandTargets: { [target] }, launchTargets: { [target] },
        canSync: { !probe.busy.contains($0) }, didChange: { probe.changed.append($0) }), preferences: preferences)
    #expect(preferences.fetchInterval == .seconds30 && !preferences.autoPullDefault && preferences.override(for: projectID) == .inherit)

    // Fetch keeps ahead/behind current; auto-pull is off by default.
    try await advanceRemote("two\n")
    #expect(await sync.sync(target, fetch: true) == .fetched(pulled: false, decision: .skip(.disabled)))
    #expect(try await GitService(root: local).status().behind == 1 && probe.changed == [local.path])

    // Enabled through the project override: a clean default branch that is only behind fast-forwards.
    preferences.setOverride(.enabled, for: projectID)
    #expect(await sync.sync(target, fetch: true) == .fetched(pulled: true, decision: .pull))
    #expect(try String(contentsOf: local.appendingPathComponent("file.txt"), encoding: .utf8) == "two\n")
    #expect(sync.states[local.path]?.lastPull != nil && sync.states[local.path]?.failures == 0)

    // Dirty, ahead, feature-branch and busy checkouts are left alone.
    try await advanceRemote("three\n")
    try "local edit\n".write(to: local.appendingPathComponent("scratch.txt"), atomically: true, encoding: .utf8)
    #expect(await sync.sync(target, fetch: true) == .fetched(pulled: false, decision: .skip(.dirty)))
    try FileManager.default.removeItem(at: local.appendingPathComponent("scratch.txt"))
    try await syncGit(local, ["switch", "-q", "-c", "topic", "main"]); try await syncGit(local, ["branch", "-q", "--set-upstream-to=origin/main"])
    #expect(await sync.sync(target, fetch: true) == .fetched(pulled: false, decision: .skip(.notDefaultBranch)))
    try await syncGit(local, ["switch", "-q", "main"])
    probe.busy.insert(local.path)
    #expect(await sync.sync(target, fetch: true) == .skipped("busy"))
    probe.busy.removeAll()
    preferences.setOverride(.disabled, for: projectID); preferences.autoPullDefault = true
    #expect(await sync.sync(target, fetch: true) == .fetched(pulled: false, decision: .skip(.disabled)))
    preferences.setOverride(.inherit, for: projectID)
    await sync.launchPass()
    #expect(try String(contentsOf: local.appendingPathComponent("file.txt"), encoding: .utf8) == "three\n")

    // Failures back off; shutdown stops the loop and later passes do nothing.
    try await syncGit(local, ["remote", "set-url", "origin", root.appendingPathComponent("missing.git").path])
    guard case .failed = await sync.sync(target, fetch: true) else { Issue.record("A missing remote must fail."); return }
    #expect(sync.states[local.path]?.failures == 1)
    preferences.fetchInterval = .off
    #expect(preferences.fetchInterval == .off)
    sync.start(); await sync.shutdown()
    #expect(!sync.isRunning)
    #expect(await sync.sync(target, fetch: true) == .skipped("busy"))
}
