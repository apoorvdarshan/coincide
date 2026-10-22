import AppKit
import CoincideCore
import Foundation
import SwiftUI
import Testing
@testable import Coincide

struct NativeSetupProviderCall: Sendable, Equatable {
    let prompt: String, path: String, model: String
    let permission: PermissionMode
}
actor NativeSetupProvider: ProviderSession {
    nonisolated let events: AsyncStream<ProviderEvent>
    private let sink: AsyncStream<ProviderEvent>.Continuation
    private var runID: UUID?
    private(set) var calls: [NativeSetupProviderCall] = []
    init() { let pair = AsyncStream<ProviderEvent>.makeStream(); events = pair.stream; sink = pair.continuation }
    func models() -> [ProviderModel] { [] }
    func send(text: String, thread: CodingThread) {
        runID = thread.activeRun?.id
        calls.append(.init(prompt: text, path: thread.workspacePath, model: thread.model, permission: thread.permission))
        emit(.thread("native-setup-fixture")); emit(.turn(UUID().uuidString))
    }
    func finish() { emit(.completed(.idle)) }
    func interrupt() { emit(.completed(.interrupted)) }
    func respond(_ request: ApprovalRequest, allow: Bool) { }
    func answer(_ request: ApprovalRequest, answers: [String: String]) { }
    func close() { sink.finish() }
    private func emit(_ event: ProviderEvent) {
        if let runID { sink.yield(.context(runID: runID, event: event)) } else { sink.yield(event) }
    }
}
actor NativeSetupOutput {
    var latest: ProjectScriptOutputSnapshot?
    func receive(_ snapshot: ProjectScriptOutputSnapshot) { latest = snapshot }
}

@MainActor struct NativeSetupFixture {
    let root: URL, source: URL, database: URL, helper: URL
    let project: WorkspaceProject, thread: CodingThread
    let provider: NativeSetupProvider
    let engine: WorkspaceEngine, store: WorkspaceStore
    let configuration: Data
    static func make(command: String, settleCommand: String? = nil) async throws -> Self {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("coincide-native-setup-" + UUID().uuidString).resolvingSymlinksInPath()
        let source = root.appendingPathComponent("Source ' workspace")
        try FileManager.default.createDirectory(at: source, withIntermediateDirectories: true)
        do {
            var scripts: [ProjectScript] = try [
                .init(name: "Manual fixture", command: "printf forbidden > manual-must-not-run"),
                .init(name: "Prepare checkout", command: command, runOnWorktreeCreate: true, runsAsynchronously: false),
                .init(name: "Later setup", command: "printf forbidden > later-must-not-run", runOnWorktreeCreate: true)
            ]
            if let settleCommand {
                scripts += try [
                    .init(name: "Settle checkout", command: settleCommand, runOnSettle: true),
                    .init(name: "Later settle", command: "printf forbidden > later-settle-must-not-run", runOnSettle: true)
                ]
            }
            let configuration = try JSONEncoder().encode(ProjectConfiguration(scripts: scripts))
            try configuration.write(to: source.appendingPathComponent("t3.json"))
            try Data("Committed base\n".utf8).write(to: source.appendingPathComponent("notes.txt"))
            try await git(["-c", "init.templateDir=", "init", "--initial-branch=main", "--", source.path], cwd: root)
            for (key, value) in [("user.name", "Coincide Fixture"), ("user.email", "fixture@example.invalid"), ("commit.gpgsign", "false"), ("core.hooksPath", "/dev/null")] {
                try await git(["config", "--local", key, value], cwd: source)
            }
            try await git(["add", "--", "t3.json", "notes.txt"], cwd: source)
            try await git(["commit", "-m", "Synthetic setup fixture"], cwd: source)
            try Data("Dirty source kept\n".utf8).write(to: source.appendingPathComponent("notes.txt"))
            try Data("Untracked source kept\n".utf8).write(to: source.appendingPathComponent("untracked.txt"))
            let project = WorkspaceProject(path: source.path)
            // The injected peer owns the protocol; Store still checks that its executable exists.
            let agent = ACPAgentConfiguration(name: "Synthetic setup provider", executable: "/usr/bin/true")
            var thread = CodingThread(project: project); thread.draft = "Keep the unsent setup discussion"; thread.model = "first-model"
            thread.provider = .acp; thread.acpAgent = agent
            var snapshot = WorkspaceSnapshot(); snapshot.projects = [project]; snapshot.threads = [thread]
            snapshot.acpAgents = [agent]
            let database = root.appendingPathComponent("workspace.sqlite")
            _ = try await WorkspaceDatabase(url: database).commit(snapshot, event: "fixture", commandID: UUID())
            let checkout = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            #if DEBUG
            let helper = checkout.appendingPathComponent(".build/debug/CoincideScriptHelper")
            #else
            let helper = checkout.appendingPathComponent(".build/release/CoincideScriptHelper")
            #endif
            #expect(FileManager.default.isExecutableFile(atPath: helper.path))
            let provider = NativeSetupProvider()
            let engine = try makeEngine(database: database, helper: helper, home: root, provider: provider)
            let store = WorkspaceStore(engine: engine); await store.load()
            return .init(root: root, source: source, database: database, helper: helper, project: project, thread: thread,
                         provider: provider, engine: engine, store: store, configuration: configuration)
        } catch { try? FileManager.default.removeItem(at: root); throw error }
    }
    static func makeEngine(database: URL, helper: URL, home: URL, provider: NativeSetupProvider) throws -> WorkspaceEngine {
        try WorkspaceEngine(url: database, providerFactory: { _ in provider }, identityResolver: { _ in nil },
            projectScriptFactory: { plan in
                try NativeProjectScriptExecutionSession(plan: plan, helperURL: helper,
                    environment: ["PATH": "/usr/bin:/bin:/usr/sbin:/sbin", "HOME": home.path, "LANG": "en_US.UTF-8"])
            })
    }
    static func git(_ arguments: [String], cwd: URL) async throws {
        let executable = try #require(ProcessChannel.findExecutable("git"))
        let result = try await CommandRunner.run(executable.path, arguments, cwd: cwd,
            environment: ["PATH": "/usr/bin:/bin:/usr/sbin:/sbin", "GIT_CONFIG_NOSYSTEM": "1", "GIT_CONFIG_GLOBAL": "/dev/null"])
        guard result.status == 0 else { throw CoincideError("The synthetic native setup Git fixture failed.") }
    }
    func cleanup() async { await store.shutdown(); try? FileManager.default.removeItem(at: root) }
    func checkSource() throws {
        #expect(try Data(contentsOf: source.appendingPathComponent("t3.json")) == configuration)
        #expect(try String(contentsOf: source.appendingPathComponent("notes.txt"), encoding: .utf8) == "Dirty source kept\n")
        #expect(try String(contentsOf: source.appendingPathComponent("untracked.txt"), encoding: .utf8) == "Untracked source kept\n")
    }
}
@MainActor func waitNativeSetup(_ condition: () async throws -> Bool) async throws {
    let deadline = ContinuousClock.now + .seconds(10)
    while try await !condition() {
        guard ContinuousClock.now < deadline else { throw CoincideError("The native setup fixture did not settle.") }
        try await Task.sleep(for: .milliseconds(10))
    }
}

@MainActor @Test(.timeLimit(.minutes(1)))
func nativeWorkspaceSetupReviewRunsOnlyFirstRoleAndDrainsAcrossWindowsBeforeReleasingCapturedQueue() async throws {
    let command = #"""
    /bin/sh -c 'trap "" HUP TERM; while :; do printf running > setup-alive.txt; /bin/sleep 0.05; done' &
    while [ ! -f setup-alive.txt ]; do /bin/sleep 0.01; done
    printf '%s\n' "$PWD" "$T3CODE_PROJECT_ROOT" "$T3CODE_WORKTREE_PATH" > setup-context.txt
    printf 'SETUP_NATIVE_OK😀\n'
    printf once >> setup-executions
    exit 7
    """#
    let fixture = try await NativeSetupFixture.make(command: command), store = fixture.store, id = fixture.thread.id
    let firstWindow = TerminalWorkspaceStore(), secondWindow = TerminalWorkspaceStore()
    store.registerTerminals(firstWindow); store.registerTerminals(secondWindow)
    var firstReader: Task<Void, Never>?, secondReader: Task<Void, Never>?
    do {
        await store.prepareWorktree(for: id, selection: .createBranch(name: "native-setup", baseRef: "HEAD"), reviewSetup: true)
        try await waitNativeSetup { store.thread(id)?.workspacePreparation?.setup?.canApprove == true }
        let thread = try #require(store.thread(id)), run = try #require(thread.workspacePreparation?.setup), plan = try #require(run.plan)
        let checkout = URL(fileURLWithPath: thread.workspacePath), alive = checkout.appendingPathComponent("setup-alive.txt")
        #expect(plan.scriptIndex == 1 && plan.script.command == command)
        #expect(store.workspaceReady(for: thread) && store.canOpenTerminal(for: thread))
        #expect(!store.snapshot.providerReady(for: thread) && thread.draft == "Keep the unsent setup discussion")
        #expect(!FileManager.default.fileExists(atPath: alive.path))
        let firstOutput = NativeSetupOutput(), secondOutput = NativeSetupOutput()
        let streamA = try await store.projectScriptOutput(threadID: id, runID: run.id)
        let streamB = try await store.projectScriptOutput(threadID: id, runID: run.id)
        firstReader = Task { for await snapshot in streamA { await firstOutput.receive(snapshot) } }
        secondReader = Task { for await snapshot in streamB { await secondOutput.receive(snapshot) } }
        #expect(await store.submit("First waiting prompt", threadID: id).value)
        store.setModel("second-model", id: id); store.setPermission(.fullAccess, id: id)
        #expect(await store.submit("Second waiting prompt", threadID: id).value)
        store.setDraft("Unsent while reviewing setup", id: id)
        #expect(await fixture.provider.calls.isEmpty)
        try await store.approveProjectScript(threadID: id, runID: run.id, expectedPlan: plan)
        try await waitNativeSetup { store.thread(id)?.workspacePreparation?.setup?.commandExit == .exited(7) }
        #expect(store.thread(id)?.workspacePreparation?.setup?.phase == .failed)
        #expect(await fixture.provider.calls.isEmpty)
        _ = NSApplication.shared
        let failed = try #require(store.thread(id)?.workspacePreparation?.setup)
        let narrow = NSHostingController(rootView: WorkspaceSetupBanner(store: store, threadID: id, run: failed))
        #expect(narrow.sizeThatFits(in: CGSize(width: 320, height: 400)).width <= 320)
        try await waitNativeSetup {
            let first = await firstOutput.latest, second = await secondOutput.latest
            return first?.text.contains("SETUP_NATIVE_OK😀") == true && second?.text.contains("SETUP_NATIVE_OK😀") == true
        }
        #expect(try String(contentsOf: checkout.appendingPathComponent("setup-context.txt"), encoding: .utf8) ==
                [checkout.path, fixture.source.path, checkout.path].joined(separator: "\n") + "\n")
        #expect(try String(contentsOf: checkout.appendingPathComponent("setup-executions"), encoding: .utf8) == "once")
        #expect(!FileManager.default.fileExists(atPath: checkout.appendingPathComponent("manual-must-not-run").path))
        #expect(!FileManager.default.fileExists(atPath: checkout.appendingPathComponent("later-must-not-run").path))
        store.unregisterTerminals(firstWindow); firstReader?.cancel(); _ = await firstReader?.value
        try? FileManager.default.removeItem(at: alive)
        try await waitNativeSetup { FileManager.default.fileExists(atPath: alive.path) }
        #expect(await secondOutput.latest?.isClosed == false, "A disappeared window must not close the app-owned setup job.")
        try await store.skipProjectScript(threadID: id, runID: run.id)
        try await waitNativeSetup { await fixture.provider.calls.count == 1 }
        try await waitNativeSetup { await secondOutput.latest?.isClosed == true }
        try? FileManager.default.removeItem(at: alive)
        try await Task.sleep(for: .milliseconds(250))
        #expect(!FileManager.default.fileExists(atPath: alive.path))
        #expect(await fixture.provider.calls.first == .init(prompt: "First waiting prompt", path: checkout.path, model: "first-model", permission: .supervised))
        await fixture.provider.finish()
        try await waitNativeSetup { await fixture.provider.calls.count == 2 }
        #expect(await fixture.provider.calls.last == .init(prompt: "Second waiting prompt", path: checkout.path, model: "second-model", permission: .fullAccess))
        await fixture.provider.finish()
        try await waitNativeSetup { store.thread(id)?.isBusy == false }
        #expect(store.thread(id)?.draft == "Unsent while reviewing setup")
        try fixture.checkSource()
    } catch {
        firstReader?.cancel(); secondReader?.cancel(); await fixture.cleanup()
        _ = await firstReader?.value; _ = await secondReader?.value; throw error
    }
    firstReader?.cancel(); secondReader?.cancel(); await fixture.cleanup()
    _ = await firstReader?.value; _ = await secondReader?.value
}

@MainActor @Test(.timeLimit(.minutes(1)))
func nativeWorkspaceSetupChangedReviewRequiresFreshPlanAndRestartNeverRunsApproval() async throws {
    let fixture = try await NativeSetupFixture.make(command: "printf forbidden > must-not-run"), store = fixture.store, id = fixture.thread.id
    do {
        await store.prepareWorktree(for: id, selection: .createBranch(name: "review-change", baseRef: "HEAD"), reviewSetup: true)
        try await waitNativeSetup { store.thread(id)?.workspacePreparation?.setup?.canApprove == true }
        let current = try #require(store.thread(id)), original = try #require(current.workspacePreparation?.setup), plan = try #require(original.plan)
        let checkout = URL(fileURLWithPath: current.workspacePath)
        let updated = try ProjectConfiguration(scripts: [.init(name: "Revised setup", command: "printf revised > must-not-run", runOnWorktreeCreate: true, runsAsynchronously: false)])
        try JSONEncoder().encode(updated).write(to: checkout.appendingPathComponent("t3.json"), options: .atomic)
        try await store.approveProjectScript(threadID: id, runID: original.id, expectedPlan: plan)
        try await waitNativeSetup { store.thread(id)?.workspacePreparation?.setup?.phase == .failed }
        #expect(!FileManager.default.fileExists(atPath: checkout.appendingPathComponent("must-not-run").path))
        try await store.retryProjectScript(threadID: id, runID: original.id)
        try await waitNativeSetup { store.thread(id)?.workspacePreparation?.setup?.canApprove == true }
        let fresh = try #require(store.thread(id)?.workspacePreparation?.setup)
        #expect(fresh.id != original.id && fresh.plan?.script.name == "Revised setup")
        await #expect(throws: CancellationError.self) { try await store.approveProjectScript(threadID: id, runID: original.id, expectedPlan: plan) }
        await store.shutdown()
        let provider = NativeSetupProvider()
        let engine = try NativeSetupFixture.makeEngine(database: fixture.database, helper: fixture.helper, home: fixture.root, provider: provider)
        let reopened = WorkspaceStore(engine: engine); await reopened.load()
        do {
            #expect(reopened.thread(id)?.workspacePreparation?.setup?.id == fresh.id)
            #expect(reopened.thread(id)?.workspacePreparation?.setup?.canApprove == true)
            #expect(reopened.thread(id)?.draft == "Keep the unsent setup discussion")
            #expect(!FileManager.default.fileExists(atPath: checkout.appendingPathComponent("must-not-run").path))
            #expect(await provider.calls.isEmpty)
            try await reopened.skipProjectScript(threadID: id, runID: fresh.id)
            try await waitNativeSetup { reopened.thread(id)?.workspacePreparation?.setup?.phase == .skipped }
            try fixture.checkSource()
        } catch { await reopened.shutdown(); throw error }
        await reopened.shutdown()
    } catch { await fixture.cleanup(); throw error }
    await fixture.cleanup()
}

@MainActor @Test(.timeLimit(.minutes(1)))
func nativeWorkspaceSetupReviewAndWorktreeFormsFitSmallDisplaysInBothAppearances() async throws {
    let fixture = try await NativeSetupFixture.make(command: "printf 'Reviewed setup command 😀\\n'; exit 7")
    do {
        await fixture.store.prepareWorktree(for: fixture.thread.id, selection: .createBranch(name: "native-review-layout", baseRef: "HEAD"), reviewSetup: true)
        try await waitNativeSetup { fixture.store.thread(fixture.thread.id)?.workspacePreparation?.setup?.canApprove == true }
        let plan = try #require(fixture.store.thread(fixture.thread.id)?.workspacePreparation?.setup?.plan)
        _ = NSApplication.shared
        for scheme in [ColorScheme.light, .dark] {
            let review = AnyView(WorkspaceSetupReviewSheet(store: fixture.store, threadID: fixture.thread.id, plan: plan, close: { }))
            let worktree = AnyView(WorktreeSetupSheet(store: fixture.store, threadID: fixture.thread.id, cancel: { }, choose: { _, _, _ in }))
            for (name, content) in [("review", review), ("worktree", worktree)] {
                let width: CGFloat = name == "review" ? 500 : 520
                let view = content.environment(\.colorScheme, scheme)
                    .background(Color(nsColor: .windowBackgroundColor))
                let controller = NSHostingController(rootView: view)
                let size = controller.sizeThatFits(in: CGSize(width: width, height: 620))
                #expect(size.width <= width && size.height <= 620 && size.height > 200)
                try await captureNativeScriptPreview(view, name: "setup-\(name)", width: width, height: size.height, scheme: scheme)
            }
        }
        #expect(fixture.store.thread(fixture.thread.id)?.workspacePreparation?.setup?.canApprove == true)
        #expect(await fixture.provider.calls.isEmpty)
    } catch { await fixture.cleanup(); throw error }
    await fixture.cleanup()
}

@MainActor func captureNativeScriptPreview<Content: View>(_ content: Content, name: String, width: CGFloat,
                                                        height: CGFloat, scheme: ColorScheme) async throws {
    let environment = ProcessInfo.processInfo.environment
    guard environment["COINCIDE_RENDER_SETUP"] == "1" || environment["COINCIDE_RENDER_SETTLEMENT"] == "1" else { return }
    let view = content.background(Color(nsColor: .windowBackgroundColor))
    let hosting = NSHostingView(rootView: view.frame(width: width, height: height))
    let window = NSWindow(contentRect: NSRect(x: -10_000, y: -10_000, width: width, height: height),
                          styleMask: .borderless, backing: .buffered, defer: false)
    let nativeAppearance = try #require(NSAppearance(named: scheme == .light ? .aqua : .darkAqua))
    window.appearance = nativeAppearance; hosting.appearance = nativeAppearance
    window.isReleasedWhenClosed = false; window.contentView = hosting
    defer { window.close() }
    hosting.layoutSubtreeIfNeeded(); try await Task.sleep(for: .milliseconds(100)); hosting.layoutSubtreeIfNeeded()
    let bitmap = try #require(hosting.bitmapImageRepForCachingDisplay(in: hosting.bounds))
    nativeAppearance.performAsCurrentDrawingAppearance { hosting.cacheDisplay(in: hosting.bounds, to: bitmap) }
    let data = try #require(bitmap.representation(using: .png, properties: [:]))
    let appearance = scheme == .light ? "light" : "dark"
    let path = FileManager.default.temporaryDirectory.appendingPathComponent("coincide-\(name)-\(appearance).png")
    try data.write(to: path)
    print("Native script form preview: \(path.path)")
}
