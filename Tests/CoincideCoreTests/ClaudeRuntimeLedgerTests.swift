import Darwin
import Foundation
import Testing
@testable import CoincideCore

private struct ClaudeRuntimeLedgerFixture {
    let root: URL, workspace: URL, alias: URL
    let runtime: ClaudeRuntimeConfiguration
    let snapshot: WorkspaceSnapshot
    init() throws {
        let requested = FileManager.default.temporaryDirectory.appendingPathComponent("coincide-claude-ledger-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: requested, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        guard let pointer = requested.path.withCString({ realpath($0, nil) }) else { throw CoincideError("The private Claude ledger fixture is unavailable.") }
        root = URL(fileURLWithPath: String(cString: pointer)); free(pointer)
        workspace = root.appendingPathComponent("Workspace 工作")
        alias = root.appendingPathComponent("Registered Alias")
        try FileManager.default.createDirectory(at: workspace, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        try FileManager.default.createSymbolicLink(at: alias, withDestinationURL: workspace)
        runtime = .init(executable: root.appendingPathComponent("never-launched").path,
            configurationDirectory: root.appendingPathComponent("Private Claude").path, workspacePath: workspace.path)
        let project = WorkspaceProject(path: workspace.path)
        var thread = CodingThread(project: project)
        thread.workspacePath = workspace.path; thread.provider = .claude; thread.claudeRuntimeConfiguration = runtime; thread.checkpointPolicy = .disabled
        var value = WorkspaceSnapshot(); value.projects = [project]; value.threads = [thread]
        snapshot = value
    }
    func cleanup() { try? FileManager.default.removeItem(at: root) }
}

@Test(arguments: ["headerProvider", "headerPath", "queued", "active", "historical"])
func claudeRuntimeLedgerRejectsMalformedCapturedNamespaceAtEveryAdmissionScope(scope: String) throws {
    let fixture = try ClaudeRuntimeLedgerFixture(); defer { fixture.cleanup() }
    var valid = fixture.snapshot
    let configuration = ProviderConfiguration(thread: valid.threads[0]), runID = UUID(), now = Date()
    switch scope {
    case "queued":
        valid.threads[0].queuedTurns = [.init(id: runID, text: "Retain captured FIFO", configuration: configuration, createdAt: now)]
        valid.threads[0].queuePaused = true
    case "active":
        // Older workspaces can retain an active run before runHistory exists.
        // Header validation must not stand in for its independently captured cwd.
        valid.threads[0].activeRun = .init(id: runID, configuration: configuration, startedAt: now)
        valid.threads[0].state = .running
    case "historical":
        var record = ThreadRunRecord(run: .init(id: runID, configuration: configuration, startedAt: now), origin: .legacy)
        record.status = .completed; record.endedAt = now; record.endReason = .providerCompleted
        valid.threads[0].runHistory = [record]
    default: break
    }
    try WorkspaceJournal.validate(valid)
    var malformed = valid
    switch scope {
    case "headerProvider": malformed.threads[0].provider = .codex
    case "headerPath": malformed.threads[0].workspacePath = fixture.alias.path
    case "queued": malformed.threads[0].queuedTurns[0].configuration.workspacePath = fixture.alias.path
    case "active": malformed.threads[0].activeRun?.configuration.workspacePath = fixture.alias.path
    case "historical": malformed.threads[0].runHistory?[0].configuration.workspacePath = fixture.alias.path
    default: Issue.record("Unknown bounded ledger scenario.")
    }
    // Even a symlink to the same physical directory cannot change the exact
    // registered spelling after acceptance without a matching captured binding.
    #expect(throws: CoincideError.self) { try WorkspaceJournal.validate(malformed) }
}

@Test func claudeRuntimeLedgerAcceptsLegacyNilAndPreservesExplicitRegisteredSymlinkCapture() throws {
    let fixture = try ClaudeRuntimeLedgerFixture(); defer { fixture.cleanup() }
    var legacy = fixture.snapshot; legacy.threads[0].claudeRuntimeConfiguration = nil
    try WorkspaceJournal.validate(legacy)
    let encodedLegacy = try JSONEncoder().encode(legacy), decodedLegacy = try JSONDecoder().decode(WorkspaceSnapshot.self, from: encodedLegacy)
    try WorkspaceJournal.validate(decodedLegacy)
    #expect(decodedLegacy.threads[0].claudeRuntimeConfiguration == nil)
    let aliasRuntime = ClaudeRuntimeConfiguration(executable: fixture.runtime.executable, configurationDirectory: fixture.runtime.configurationDirectory,
        workspacePath: fixture.workspace.path, registeredWorkspacePath: fixture.alias.path)
    var aliased = fixture.snapshot
    aliased.threads[0].workspacePath = fixture.alias.path; aliased.threads[0].claudeRuntimeConfiguration = aliasRuntime
    let captured = ProviderConfiguration(thread: aliased.threads[0]), queuedID = UUID()
    aliased.threads[0].queuedTurns = [.init(id: queuedID, text: "Alias remains exact 工作", configuration: captured, createdAt: Date())]
    aliased.threads[0].queuePaused = true
    try WorkspaceJournal.validate(aliased)
    let encoded = try JSONEncoder().encode(aliased), reopened = try JSONDecoder().decode(WorkspaceSnapshot.self, from: encoded)
    try WorkspaceJournal.validate(reopened)
    #expect(reopened == aliased)
    #expect(reopened.threads[0].workspacePath == fixture.alias.path)
    #expect(reopened.threads[0].claudeRuntimeConfiguration?.workspacePath == fixture.workspace.path)
    #expect(reopened.threads[0].queuedTurns.first?.configuration.claudeRuntimeConfiguration?.registeredWorkspacePath == fixture.alias.path)
}
