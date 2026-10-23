import Foundation
import Testing
@testable import Coincide
@testable import CoincideCore

private final class NativeAgentImportLaunchProbe: @unchecked Sendable {
    private let lock = NSLock()
    private var value = 0
    func called() { lock.withLock { value += 1 } }
    func count() -> Int { lock.withLock { value } }
}
private struct NativeAgentImportCredentials: CodexCredentialStorage {
    func read(instanceID: UUID) -> Data? { Issue.record("Session import must not read credentials."); return nil }
    func createIfAbsent(_ data: Data, instanceID: UUID) -> Bool { Issue.record("Session import must not create credentials."); return false }
    func write(_ data: Data, instanceID: UUID) { Issue.record("Session import must not write credentials.") }
    func delete(instanceID: UUID) { Issue.record("Session import must not delete credentials.") }
}
private actor NativeAgentImportOAuth: CodexOAuthTransport {
    func response(for request: URLRequest, maximumBytes: Int) throws -> CodexOAuthHTTPResponse {
        Issue.record("Session import must not call OAuth."); throw CancellationError()
    }
}

@Test func agentSessionProfileCaptureUsesCurrentAndRegisteredNativeHomesWithoutInventingProviderIdentitiesOrResumeState() throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("coincide-agent-profile-capture-\(UUID())").resolvingSymlinksInPath()
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
    defer { try? FileManager.default.removeItem(at: root) }
    let project = WorkspaceProject(path: root.path)
    let current = CodexRuntimeConfiguration(selection: .custom, executable: root.appendingPathComponent("never-run-current").path,
        homeDirectory: root.appendingPathComponent("CurrentCodex").path)
    var same = CodingThread(project: project); same.providerThreadID = "never-resume-from-discovery"
    same.codexRuntimeConfiguration = .init(instanceID: current.instanceID, selection: .custom, executable: root.appendingPathComponent("never-run-old").path,
        homeDirectory: root.appendingPathComponent("OldCodex").path)
    var other = CodingThread(project: project)
    other.codexRuntimeConfiguration = .init(instanceID: UUID(), selection: .custom, executable: root.appendingPathComponent("never-run-secondary").path,
        homeDirectory: root.appendingPathComponent("SecondaryCodex").path)
    let claudeRoot = root.appendingPathComponent("Claude").path, executable = root.appendingPathComponent("never-run-claude").path
    let profiles = try AgentSessionProfileCapture.profiles(codex: current, captured: [.init(thread: same), .init(thread: other)], workspacePath: root.path,
        environment: ["HOME": root.path, "CODEX_HOME": root.appendingPathComponent("DefaultCodex").path], claude: { path in
            .init(executable: executable, configurationDirectory: claudeRoot, workspacePath: path)
        })
    #expect(profiles.count == 3 && Set(profiles.map(\.id)).count == 3)
    #expect(profiles.first?.id == current.instanceID && profiles.first?.transcriptsRoot == current.homeDirectory)
    #expect(profiles.contains { $0.transcriptsRoot == other.codexRuntimeConfiguration?.homeDirectory })
    #expect(!profiles.contains { $0.transcriptsRoot == same.codexRuntimeConfiguration?.homeDirectory || $0.transcriptsRoot.hasSuffix("DefaultCodex") })
    #expect(profiles.allSatisfy { $0.configuration.nativeThreadID == nil && $0.configuration.claudeLaunchSelection == nil })
    #expect(profiles.contains { $0.source == .claudeAgent && $0.transcriptsRoot == claudeRoot })
}

@MainActor @Test(.timeLimit(.minutes(1)))
func agentSessionNativeWorkspaceImportCreatesOnlySelectedExistingProjectAndImportsPrivateHistoryWithoutLaunchingAnyProvider() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("coincide-agent-workspace-import-\(UUID())").resolvingSymlinksInPath()
    let data = root.appendingPathComponent("AppData"), project = root.appendingPathComponent("Project"), codex = root.appendingPathComponent("Codex")
    let claude = root.appendingPathComponent("Claude"), sessions = codex.appendingPathComponent("sessions/2026/10/23")
    for directory in [data, project, sessions, claude] { try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700]) }
    defer { try? FileManager.default.removeItem(at: root) }
    var sourceBytes: [URL: Data] = [:]
    for index in 0..<2 {
        let rows: [[String: Any]] = [
            ["type": "session_meta", "payload": ["id": UUID().uuidString, "cwd": project.path, "source": "cli"]],
            ["type": "turn_context", "payload": ["model": "offline-captured-model"]],
            ["type": "response_item", "payload": ["type": "message", "role": "user", "content": [["type": "input_text", "text": "Saved synthetic question \(index)"]]]],
            ["type": "response_item", "payload": ["type": "message", "role": "assistant", "content": [["type": "output_text", "text": "Saved synthetic answer \(index)"]]]]
        ]
        var bytes = Data()
        for row in rows { bytes.append(try JSONSerialization.data(withJSONObject: row, options: [.sortedKeys])); bytes.append(10) }
        let file = sessions.appendingPathComponent("rollout-store-\(index).jsonl")
        try bytes.write(to: file); try FileManager.default.setAttributes([.posixPermissions: 0o600, .modificationDate: Date().addingTimeInterval(-60)], ofItemAtPath: file.path)
        sourceBytes[file] = bytes
    }
    let probe = NativeAgentImportLaunchProbe()
    let engine = try WorkspaceEngine(url: data.appendingPathComponent("workspace.sqlite"), appMCPEnabled: false, providerFactory: { _ in
        probe.called(); throw CoincideError("This metadata-only fixture must not launch a provider.")
    })
    let executable = root.appendingPathComponent("must-not-run-claude").path, claudePath = claude.path
    let oauth = NativeAgentImportOAuth(), broker = CodexOwnedRuntimeBroker(storage: NativeAgentImportCredentials(), lockRoot: root.appendingPathComponent("locks"),
        homesRoot: root.appendingPathComponent("homes"), clientFactory: { CodexOAuthClient(transport: oauth) })
    let installation = CodexInstallation(rootURL: root.appendingPathComponent("Tools/Codex"), release: nil,
        downloader: { _, _, _ in Issue.record("Session import must not download a CLI."); throw CancellationError() },
        inspector: { _, _ in Issue.record("Session import must not inspect or execute a CLI."); throw CancellationError() },
        localResolver: { _ in nil })
    let store = WorkspaceStore(engine: engine, managedProjectsRoot: data.appendingPathComponent("Projects"), codexInstallation: installation,
        codexOwnedRuntime: broker, codexHostID: UUID(), codexListenerFactory: {
            Issue.record("Session import must not start an auth listener."); throw CancellationError()
        }, codexAuthorization: { _ in Issue.record("Session import must not open an auth browser."); throw CancellationError() }, claudeRuntimeCapture: { path in
        .init(executable: executable, configurationDirectory: claudePath, workspacePath: path)
    })
    await store.load()
    do {
        // Change a captured preference only. No runtime inspection, provider
        // process, auth request or installed/default transcript home is used.
        store.codexRuntime.selection = .custom; store.codexRuntime.executable = root.appendingPathComponent("must-not-run-codex").path
        store.codexRuntime.homeDirectory = codex.path
        await store.codexRuntime.applySelection()
        #expect(store.codexRuntime.configuration.homeDirectory == codex.path)
        #expect(store.snapshot.projects.isEmpty && store.snapshot.threads.isEmpty)
        await store.agentSessionImports.scan()?.value
        let candidate = try #require(store.agentSessionImports.selectedCandidate)
        #expect(candidate.path == project.path && candidate.projectID == nil && candidate.threadCount == 2)
        #expect(store.snapshot.projects.isEmpty && store.snapshot.threads.isEmpty)
        await store.agentSessionImports.importSelected()?.value
        #expect(store.agentSessionImports.pending == nil && store.agentSessionImports.progress.imported == 2)
        #expect(store.snapshot.projects.count == 1 && store.snapshot.projects[0].path == project.path && store.snapshot.threads.count == 2)
        #expect(store.snapshot.threads.allSatisfy { $0.messages.count == 2 && $0.activeRun == nil && $0.queuedTurns.isEmpty })
        await store.agentSessionImports.scan()?.value; await store.agentSessionImports.importSelected()?.value
        #expect(store.agentSessionImports.progress.imported == 0 && store.agentSessionImports.progress.alreadyImported == 2)
        #expect(store.snapshot.projects.count == 1 && store.snapshot.threads.count == 2)
        let launches = probe.count(); #expect(launches == 0)
        for (url, expected) in sourceBytes { #expect(try Data(contentsOf: url) == expected) }
    } catch { await store.shutdown(); throw error }
    await store.shutdown()
}
