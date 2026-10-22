import CoincideCore
import CoincideTerminal
import Foundation
import Testing
@testable import Coincide

private actor ProjectScriptReadGate {
    private var count = 0
    private var waiter: CheckedContinuation<Void, Never>?
    private var released = false
    private(set) var waiting = false
    func read(_ service: WorkspaceFileService) async throws -> ProjectConfigurationDocument {
        let document = try await ProjectConfigurationService.load(using: service)
        count += 1
        if count > 1 && !released {
            waiting = true
            // Intentionally finishes late even when cancelled: ownership must still
            // reject the captured result, and removal/shutdown must drain this read.
            await withCheckedContinuation { waiter = $0 }
        }
        return document
    }
    func release() { released = true; waiter?.resume(); waiter = nil }
}

@MainActor private func waitScriptUI(_ predicate: () async throws -> Bool) async throws {
    let deadline = ContinuousClock.now + .seconds(8)
    while try await !predicate() {
        guard ContinuousClock.now < deadline else { throw CoincideError("The native script fixture did not settle.") }
        try await Task.sleep(for: .milliseconds(10))
    }
}

@MainActor private struct ProjectScriptFixture {
    let root: URL, projectRoot: URL, checkout: URL, database: URL
    let project: WorkspaceProject, thread: CodingThread
    let engine: WorkspaceEngine, store: WorkspaceStore, terminals: TerminalWorkspaceStore
    static func make(worktree: Bool = false, gate: ProjectScriptReadGate? = nil) async throws -> Self {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("coincide-script-ui-\(UUID())").resolvingSymlinksInPath()
        let projectRoot = root.appendingPathComponent("Project ' space")
        let checkout = worktree ? root.appendingPathComponent("Worktree ' space") : projectRoot
        try FileManager.default.createDirectory(at: projectRoot, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: checkout, withIntermediateDirectories: true)
        let command = #"printf '%s\n' "$PWD" "$T3CODE_PROJECT_ROOT" "${T3CODE_WORKTREE_PATH-unset}" > 'script result.txt'; printf 'NATIVE_SCRIPT_OK\n'"#
        let data = try JSONSerialization.data(withJSONObject: ["scripts": [["name": "Fixture script", "command": command, "runOnWorktreeCreate": true, "runOnSettle": true, "async": false]]])
        try data.write(to: checkout.appendingPathComponent("t3.json"))
        let project = WorkspaceProject(path: projectRoot.path)
        var thread = CodingThread(project: project); thread.workspacePath = checkout.path; thread.draft = "Keep my unsent prompt"
        var snapshot = WorkspaceSnapshot(); snapshot.projects = [project]; snapshot.threads = [thread]
        let database = root.appendingPathComponent("workspace.sqlite"), persistence = try WorkspaceDatabase(url: database)
        _ = try await persistence.commit(snapshot, event: "fixture", commandID: UUID())
        let engine = try WorkspaceEngine(url: database, identityResolver: { _ in nil })
        let store = WorkspaceStore(engine: engine, projectScriptReader: { service in
            if let gate { return try await gate.read(service) }
            return try await ProjectConfigurationService.load(using: service)
        })
        await store.load()
        let terminals = TerminalWorkspaceStore(executable: "/bin/sh", loginShell: false); store.registerTerminals(terminals)
        return .init(root: root, projectRoot: projectRoot, checkout: checkout, database: database, project: project, thread: thread, engine: engine, store: store, terminals: terminals)
    }
    func cleanup() async { await store.shutdown(); try? FileManager.default.removeItem(at: root) }
    var result: URL { checkout.appendingPathComponent("script result.txt") }
}

@MainActor @Test(.timeLimit(.minutes(1)))
func projectScriptsOnlyRunExplicitlyInDedicatedPTYTabsWithCheckoutEnvironmentAndPreservedConversation() async throws {
    for worktree in [false, true] {
        let f = try await ProjectScriptFixture.make(worktree: worktree)
        do {
            try f.terminals.add(for: f.thread)
            let existing = try #require(f.terminals.sessions[f.thread.id]?.first)
            let context = try await f.store.projectScripts().load(for: f.thread)
            #expect(context.document.configuration?.scripts.count == 1)
            #expect(!FileManager.default.fileExists(atPath: f.result.path), "Discovery must not execute setup or settle roles.")
            #expect(f.terminals.sessions[f.thread.id]?.count == 1)
            let before = f.store.thread(f.thread.id), selected = f.store.selectedThreadID
            let session = try await f.store.projectScripts().run(context, scriptIndex: 0, in: f.terminals)
            #expect(session.id != existing.id && f.terminals.sessions[f.thread.id]?.count == 2)
            #expect(f.terminals.selection[f.thread.id] == session.id)
            try await waitScriptUI { if case .exited = session.lifecycle { true } else { false } }
            #expect(session.lifecycle == .exited(0) && session.title == "Fixture script" && session.isCommand)
            #expect(session.visibleText.contains("NATIVE_SCRIPT_OK") && existing.lifecycle == .running)
            let expected = [f.checkout.path, f.projectRoot.path, worktree ? f.checkout.path : "unset"].joined(separator: "\n") + "\n"
            #expect(try String(contentsOf: f.result, encoding: .utf8) == expected)
            #expect(f.store.thread(f.thread.id) == before && f.store.selectedThreadID == selected)
        } catch { await f.cleanup(); throw error }
        await f.cleanup()
    }
}

@MainActor @Test(.timeLimit(.minutes(1)))
func changedScriptRevisionAndClosedWindowNeverLaunchAndReloadUsesNewConfiguration() async throws {
    let f = try await ProjectScriptFixture.make()
    do {
        let service = f.store.projectScripts(), context = try await service.load(for: f.thread)
        let updated = try JSONSerialization.data(withJSONObject: ["scripts": [["name": "New script", "command": "printf 'RELOADED_OK\\n'"]]])
        try updated.write(to: f.checkout.appendingPathComponent("t3.json"), options: .atomic)
        await #expect(throws: CoincideError.self) { try await service.run(context, scriptIndex: 0, in: f.terminals) }
        #expect(f.terminals.sessions.isEmpty && !FileManager.default.fileExists(atPath: f.result.path))
        let fresh = try await service.load(for: f.thread)
        f.store.unregisterTerminals(f.terminals)
        await #expect(throws: CancellationError.self) { try await service.run(fresh, scriptIndex: 0, in: f.terminals) }
        #expect(f.terminals.sessions.isEmpty)
        f.store.registerTerminals(f.terminals)
        let session = try await service.run(fresh, scriptIndex: 0, in: f.terminals)
        try await waitScriptUI { if case .exited = session.lifecycle { true } else { false } }
        #expect(session.title == "New script" && session.visibleText.contains("RELOADED_OK"))
    } catch { await f.cleanup(); throw error }
    await f.cleanup()
}

@MainActor @Test(.timeLimit(.minutes(1)))
func removingAndReaddingTheSameConversationCannotAcceptLateScriptRead() async throws {
    let gate = ProjectScriptReadGate(), f = try await ProjectScriptFixture.make(gate: gate)
    let survivorRoot = f.root.appendingPathComponent("Survivor")
    try FileManager.default.createDirectory(at: survivorRoot, withIntermediateDirectories: true)
    let survivor = WorkspaceProject(path: survivorRoot.path)
    var survivingThread = CodingThread(project: survivor); survivingThread.workspacePath = f.checkout.path
    _ = try await f.engine.dispatch(.addProject(survivor))
    _ = try await f.engine.dispatch(.createThread(survivingThread))
    try await waitScriptUI { f.store.snapshot.projects.contains { $0.id == survivor.id } }
    let service = f.store.projectScripts(), context = try await service.load(for: f.thread)
    let run = Task { try await service.run(context, scriptIndex: 0, in: f.terminals) }
    do {
        try await waitScriptUI { await gate.waiting }
        _ = try await f.engine.dispatch(.removeProject(projectID: f.project.id, expectedThreadIDs: [f.thread.id]))
        try await waitScriptUI { f.store.thread(f.thread.id) == nil }
        _ = try await f.engine.dispatch(.addProjectWithThread(project: f.project, thread: f.thread))
        try await waitScriptUI { f.store.thread(f.thread.id) != nil }
        #expect(context.workspace.files === (try f.store.fileService(path: f.checkout.path)), "A surviving owner keeps the same anchored file session; conversation incarnation must still reject the old Run action.")
        await gate.release()
        await #expect(throws: CancellationError.self) { try await run.value }
        await #expect(throws: CancellationError.self) { try await service.run(context, scriptIndex: 0, in: f.terminals) }
        #expect(f.terminals.sessions.isEmpty && !FileManager.default.fileExists(atPath: f.result.path))
        #expect(f.store.thread(f.thread.id)?.draft == "Keep my unsent prompt")
    } catch { await gate.release(); _ = await run.result; await f.cleanup(); throw error }
    await f.cleanup()
}

@MainActor @Test(.timeLimit(.minutes(1)))
func scriptShutdownCancelsAndDrainsLateReadWithoutStartingProcess() async throws {
    let gate = ProjectScriptReadGate(), f = try await ProjectScriptFixture.make(gate: gate)
    let service = f.store.projectScripts(), context = try await service.load(for: f.thread)
    let run = Task { try await service.run(context, scriptIndex: 0, in: f.terminals) }
    do {
        try await waitScriptUI { await gate.waiting }
        var finished = false
        let shutdown = Task { await f.store.shutdown(); finished = true }
        try await waitScriptUI { !f.store.canOpenTerminal(for: f.thread) }
        #expect(!finished, "Shutdown must wait for an owned configuration read to drain.")
        await gate.release(); await shutdown.value
        await #expect(throws: CancellationError.self) { try await run.value }
        #expect(f.terminals.sessions.isEmpty && !FileManager.default.fileExists(atPath: f.result.path))
    } catch { await gate.release(); _ = await run.result; await f.cleanup(); throw error }
    await f.cleanup()
}

@MainActor @Test(.timeLimit(.minutes(1)))
func scriptLateReadCannotLaunchInAReplacementCheckoutAndPreservesBothFolders() async throws {
    let gate = ProjectScriptReadGate(), f = try await ProjectScriptFixture.make(gate: gate)
    let service = f.store.projectScripts(), context = try await service.load(for: f.thread)
    let run = Task { try await service.run(context, scriptIndex: 0, in: f.terminals) }
    do {
        try await waitScriptUI { await gate.waiting }
        let original = f.root.appendingPathComponent("Preserved original")
        try FileManager.default.moveItem(at: f.checkout, to: original)
        try FileManager.default.createDirectory(at: f.checkout, withIntermediateDirectories: true)
        try Data("Replacement sentinel".utf8).write(to: f.checkout.appendingPathComponent("sentinel.txt"))
        await gate.release()
        await #expect(throws: WorkspaceFileError.self) { try await run.value }
        #expect(f.terminals.sessions.isEmpty && !FileManager.default.fileExists(atPath: f.result.path))
        #expect(!FileManager.default.fileExists(atPath: original.appendingPathComponent("script result.txt").path))
        #expect(FileManager.default.fileExists(atPath: original.appendingPathComponent("t3.json").path))
        #expect(try String(contentsOf: f.checkout.appendingPathComponent("sentinel.txt"), encoding: .utf8) == "Replacement sentinel")
        #expect(f.store.thread(f.thread.id)?.draft == "Keep my unsent prompt")
    } catch { await gate.release(); _ = await run.result; await f.cleanup(); throw error }
    await f.cleanup()
}

@MainActor @Test(.timeLimit(.minutes(1)))
func scriptContextCannotReturnAfterAConversationSwitchesCheckoutAndBack() async throws {
    let gate = ProjectScriptReadGate(), f = try await ProjectScriptFixture.make(gate: gate)
    let service = f.store.projectScripts(), context = try await service.load(for: f.thread)
    let run = Task { try await service.run(context, scriptIndex: 0, in: f.terminals) }
    do {
        try await waitScriptUI { await gate.waiting }
        let other = f.root.appendingPathComponent("Other checkout")
        try FileManager.default.createDirectory(at: other, withIntermediateDirectories: true)
        _ = try await f.engine.dispatch(.editThread(f.thread.id, .workspacePath(other.path)))
        try await waitScriptUI { f.store.thread(f.thread.id)?.workspacePath == other.path }
        _ = try await f.engine.dispatch(.editThread(f.thread.id, .workspacePath(f.checkout.path)))
        try await waitScriptUI { f.store.thread(f.thread.id)?.workspacePath == f.checkout.path }
        await gate.release()
        await #expect(throws: CancellationError.self) { try await run.value }
        await #expect(throws: CancellationError.self) { try await service.run(context, scriptIndex: 0, in: f.terminals) }
        #expect(f.terminals.sessions.isEmpty && !FileManager.default.fileExists(atPath: f.result.path))
    } catch { await gate.release(); _ = await run.result; await f.cleanup(); throw error }
    await f.cleanup()
}

@MainActor @Test(.timeLimit(.minutes(1)))
func scriptProjectRemovalCancelsAndWaitsForTheOwnedConfigurationReadToDrain() async throws {
    let gate = ProjectScriptReadGate(), f = try await ProjectScriptFixture.make(gate: gate)
    let service = f.store.projectScripts(), context = try await service.load(for: f.thread)
    let run = Task { try await service.run(context, scriptIndex: 0, in: f.terminals) }
    do {
        try await waitScriptUI { await gate.waiting }
        let request = try #require(f.store.projectRemovalRequest(f.project.id))
        var finished = false
        let removal = Task { try await f.store.removeProject(request); finished = true }
        try await waitScriptUI { f.store.thread(f.thread.id) == nil }
        #expect(!finished && !f.store.canAccessWorkspaceFiles(f.checkout.path))
        await gate.release(); try await removal.value
        await #expect(throws: CancellationError.self) { try await run.value }
        #expect(finished && f.terminals.sessions.isEmpty && !FileManager.default.fileExists(atPath: f.result.path))
        #expect(FileManager.default.fileExists(atPath: f.checkout.appendingPathComponent("t3.json").path))
    } catch { await gate.release(); _ = await run.result; await f.cleanup(); throw error }
    await f.cleanup()
}

@MainActor @Test(.timeLimit(.minutes(1)))
func aTerminalChildCannotKeepAnUnrelatedProviderInputPipeOpen() async throws {
    let channel = try ProcessChannel(executable: URL(fileURLWithPath: "/bin/sh"),
        arguments: ["-c", "printf 'CHANNEL_READY\\n'; cat >/dev/null; printf 'CHANNEL_INPUT_CLOSED\\n'"])
    var output = "", completed = false
    let reader = Task {
        for await event in channel.events {
            switch event {
            case .stdout(let data): output += String(decoding: data, as: UTF8.self)
            case .exited: completed = true
            case .stderr: break
            }
        }
    }
    do {
        try await waitScriptUI { output.contains("CHANNEL_READY") }
        let terminal = try LocalTerminalSession(directory: FileManager.default.temporaryDirectory, executable: "/bin/sh",
            arguments: ["-c", "exec sleep 120"], commandTitle: "Independent terminal")
        channel.finishInput()
        let deadline = ContinuousClock.now + .seconds(2)
        while !completed && ContinuousClock.now < deadline { try await Task.sleep(for: .milliseconds(10)) }
        #expect(completed && output.contains("CHANNEL_INPUT_CLOSED"), "A terminal must not inherit another child's pipe descriptors and delay its EOF until the terminal exits.")
        #expect(terminal.lifecycle == .running)
        terminal.close(); await terminal.waitForClose()
    } catch { channel.stop(); await reader.value; throw error }
    channel.stop(); await reader.value
}
