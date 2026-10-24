import AppKit
import CoincideCore
import SwiftUI
import Testing
@testable import Coincide

@MainActor @Test(.timeLimit(.minutes(1))) func nativeGitInspectorInitialCommitBranchAndFailureKeepRepositoryStateVisible() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("coincide-git-ui-" + UUID().uuidString)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }
    let model = GitInspectorStore(path: root.path)
    await model.refresh(); #expect(model.statusError != nil && model.snapshot == nil && !model.isBusy)
    model.initialize(branch: "main")
    #expect(model.operationName != nil)
    await model.waitForOperation()
    #expect(model.operationError == nil && model.statusError == nil && model.snapshot?.isUnborn == true)
    for (key, value) in [("user.name", "Coincide Test"), ("user.email", "test@example.invalid"), ("commit.gpgSign", "false"), ("core.hooksPath", root.appendingPathComponent("no-hooks").path)] {
        let result = try await CommandRunner.run("git", ["-C", root.path, "config", key, value]); #expect(result.status == 0)
    }
    try "native changes\n".write(to: root.appendingPathComponent("native file.txt"), atomically: true, encoding: .utf8)
    await model.refresh()
    model.selected = "native file.txt"; await model.loadDiff()
    #expect(model.files.count == 1 && model.diff.contains("+native changes"))
    model.stage(["native file.txt"]); await model.waitForOperation()
    #expect(model.files[0].isStaged)
    model.staged = true; await model.loadDiff(); #expect(model.diff.contains("+native changes"))
    model.commitMessage = "Initial native commit"; model.commit(); await model.waitForOperation()
    #expect(model.snapshot?.isUnborn == false && model.snapshot?.isClean == true && model.commitMessage.isEmpty && model.selected == nil)
    model.createBranch("native/topic"); await model.waitForOperation()
    #expect(model.snapshot?.branch == "native/topic" && model.branches.count == 2)
    model.pull(); await model.waitForOperation()
    #expect(model.operationError?.contains("no upstream") == true && model.snapshot?.branch == "native/topic" && model.statusError == nil && !model.isBusy)
    model.operationError = nil
    try "a second change\n".write(to: root.appendingPathComponent("native file.txt"), atomically: true, encoding: .utf8)
    await model.refresh(); model.selected = "native file.txt"; model.staged = false; await model.loadDiff()
    #expect(model.diff.contains("+a second change"))
}

@MainActor @Test(.timeLimit(.minutes(1))) func workspaceOwnsGitOperationsAcrossInspectorLifetimesAndStopsThemAtShutdown() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("coincide-git-shutdown-" + UUID().uuidString)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }
    let repository = root.appendingPathComponent("repository"), hooks = root.appendingPathComponent("hooks"), marker = root.appendingPathComponent("started")
    try FileManager.default.createDirectory(at: repository, withIntermediateDirectories: true)
    try FileManager.default.createDirectory(at: hooks, withIntermediateDirectories: true)
    let store = WorkspaceStore(databaseURL: root.appendingPathComponent("workspace.sqlite"))
    let model = store.gitInspector(path: repository.path)
    #expect(store.gitInspector(path: repository.appendingPathComponent(".").path) === model)
    try await model.git.initialize()
    for (key, value) in [("user.name", "Coincide Test"), ("user.email", "test@example.invalid"), ("commit.gpgSign", "false"), ("core.hooksPath", hooks.path)] {
        let result = try await CommandRunner.run("git", ["-C", repository.path, "config", key, value]); #expect(result.status == 0)
    }
    let hook = hooks.appendingPathComponent("pre-commit")
    try "#!/bin/sh\nprintf 'ready' > '\(marker.path)'\nexec /usr/bin/perl -e 'sleep 10'\n".write(to: hook, atomically: true, encoding: .utf8)
    try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: hook.path)
    try "preserve bytes".write(to: repository.appendingPathComponent("file.txt"), atomically: true, encoding: .utf8)
    try await model.git.stage(["file.txt"]); await model.refresh()
    model.commitMessage = "Should be cancelled"; model.commit()
    let deadline = ContinuousClock.now + .seconds(5)
    while !FileManager.default.fileExists(atPath: marker.path), ContinuousClock.now < deadline { try await Task.sleep(for: .milliseconds(10)) }
    #expect(FileManager.default.fileExists(atPath: marker.path))
    let start = ContinuousClock.now; await store.shutdown()
    #expect(ContinuousClock.now - start < .seconds(3) && model.operationName == nil)
    let snapshot = try await model.git.status()
    #expect(snapshot.isUnborn && snapshot.changes.first?.isStaged == true)
    #expect(try String(contentsOf: repository.appendingPathComponent("file.txt"), encoding: .utf8) == "preserve bytes")
    model.createBranch("must-not-start"); await model.waitForOperation()
    #expect(try await model.git.status().branch == "main")
}
