import CoincideCore
import Foundation
import Testing
@testable import Coincide

@MainActor private final class EditorDiscoveryGate {
    private(set) var enteredCount = 0
    private(set) var cancellationObserved = false
    private var continuations: [CheckedContinuation<Void, Never>] = []
    var entered: Bool { enteredCount > 0 }
    func wait() async {
        enteredCount += 1
        await withTaskCancellationHandler {
            await withCheckedContinuation { continuations.append($0) }
        } onCancel: { Task { @MainActor in self.cancellationObserved = true } }
    }
    func release() { let pending = continuations; continuations = []; for continuation in pending { continuation.resume() } }
}

@MainActor private final class EditorHandoffRecorder {
    private(set) var plans: [ExternalEditorLaunchPlan] = []
    func record(_ plan: ExternalEditorLaunchPlan) { plans.append(plan) }
}

@MainActor private struct EditorUIFixture {
    let root: URL
    let checkout: URL
    let databaseURL: URL
    let engine: WorkspaceEngine
    let store: WorkspaceStore
    let project: WorkspaceProject
    let thread: CodingThread
    let defaults: UserDefaults
    let defaultsDomain: String

    static func make(shared: Bool = false) async throws -> Self {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("coincide-editor-ui-" + UUID().uuidString).resolvingSymlinksInPath()
        let checkout = root.appendingPathComponent("Checkout")
        try FileManager.default.createDirectory(at: checkout, withIntermediateDirectories: true)
        try Data("Saved bytes\n".utf8).write(to: checkout.appendingPathComponent("notes.txt"))
        let project = WorkspaceProject(path: checkout.path), thread = CodingThread(project: project)
        var snapshot = WorkspaceSnapshot(); snapshot.projects = [project]; snapshot.threads = [thread]
        if shared {
            let alias = WorkspaceProject(path: checkout.path)
            snapshot.projects.append(alias); snapshot.threads.append(CodingThread(project: alias))
        }
        let databaseURL = root.appendingPathComponent("workspace.sqlite"), database = try WorkspaceDatabase(url: databaseURL)
        _ = try await database.commit(snapshot, event: "fixture", commandID: UUID())
        let engine = try WorkspaceEngine(url: databaseURL, identityResolver: { _ in nil })
        let store = WorkspaceStore(engine: engine); await store.load()
        let domain = "coincide.external-editor-tests." + UUID().uuidString
        let defaults = try #require(UserDefaults(suiteName: domain))
        return .init(root: root, checkout: checkout, databaseURL: databaseURL, engine: engine, store: store,
                     project: project, thread: thread, defaults: defaults, defaultsDomain: domain)
    }
    func service(discovery: @escaping NativeExternalEditorService.Discovery = { [] }, recorder: EditorHandoffRecorder,
                 handoff: NativeExternalEditorService.Handoff? = nil) -> NativeExternalEditorService {
        let store = store
        return .init(defaults: defaults, resolveWorkspace: { [weak store] root in
            guard let store else { throw CancellationError() }
            return try store.fileService(path: root.path)
        }, authorize: { [weak store] root, captured in
            guard let store, store.canAccessWorkspaceFiles(root.path), let current = try? store.fileService(path: root.path) else { return false }
            return current === captured
        }, discovery: discovery, handoff: handoff ?? { recorder.record($0); return Task<Void, any Error> { } })
    }
    func cleanup() async {
        await store.shutdown()
        defaults.removePersistentDomain(forName: defaultsDomain)
        try? FileManager.default.removeItem(at: root)
    }
}

@MainActor private func waitForEditorState(_ condition: () -> Bool) async throws {
    let deadline = ContinuousClock.now + .seconds(5)
    while !condition() {
        guard ContinuousClock.now < deadline else { throw CoincideError("The isolated external-editor fixture did not settle.") }
        try await Task.sleep(for: .milliseconds(10))
    }
}

@MainActor @Test(.timeLimit(.minutes(1)))
func externalEditorDefaultHandoffRetainsDirtyBuffersAndRejectsInvalidPreferencesAndUnauthorizedRoots() async throws {
    let fixture = try await EditorUIFixture.make(), recorder = EditorHandoffRecorder()
    fixture.defaults.set("not-an-editor", forKey: NativeExternalEditorService.preferredEditorDefaultsKey)
    let editors = fixture.service(recorder: recorder)
    do {
        #expect(editors.preferredEditorID == nil)
        let available = await editors.availableEditors()
        #expect(available.map(\.id) == [.fileManager])
        let browser = try fixture.store.fileBrowser(path: fixture.checkout.path)
        #expect(await browser.open("notes.txt")); browser.setContents("Unsaved native edits")
        let target = ExternalEditorTarget(workspaceRoot: fixture.checkout, relativePath: "notes.txt", location: try .init(line: 3))
        try await editors.open(target)
        #expect(recorder.plans.count == 1)
        if case .defaultApplication(let url) = recorder.plans[0] { #expect(url.path == fixture.checkout.appendingPathComponent("notes.txt").path) }
        else { Issue.record("The no-installation fallback did not use the default file application.") }
        #expect(browser.isDirty && browser.contents == "Unsaved native edits")
        #expect(try String(contentsOf: fixture.checkout.appendingPathComponent("notes.txt"), encoding: .utf8) == "Saved bytes\n")
        try await editors.reveal(target)
        if let plan = recorder.plans.last, case .reveal(let url) = plan { #expect(url.path == fixture.checkout.appendingPathComponent("notes.txt").path) }
        else { Issue.record("Reveal did not produce a distinct file-manager handoff.") }
        let unauthorized = ExternalEditorTarget(workspaceRoot: fixture.root)
        await #expect(throws: (any Error).self) { try await editors.open(unauthorized) }
        await #expect(throws: (any Error).self) { try await editors.open(target, editor: .cursor) }
        #expect(recorder.plans.count == 2)
        editors.preferredEditorID = .fileManager
        #expect(fixture.defaults.string(forKey: NativeExternalEditorService.preferredEditorDefaultsKey) == "file-manager")
        await editors.shutdown()
        let metadata = try await fixture.store.fileService(path: fixture.checkout.path).metadata(relativePath: "notes.txt")
        #expect(metadata.kind == .file, "Closing the launcher must not close the Store-owned workspace service.")
    } catch { await editors.shutdown(); await fixture.cleanup(); throw error }
    await fixture.cleanup()
}

@MainActor @Test(.timeLimit(.minutes(1)))
func externalEditorCancellationBeforeHandoffNeverLaunchesAndLeavesSavedFilesIntact() async throws {
    let fixture = try await EditorUIFixture.make(), gate = EditorDiscoveryGate(), recorder = EditorHandoffRecorder()
    let editors = fixture.service(discovery: { await gate.wait(); return [] }, recorder: recorder)
    let task = Task { try await editors.open(.init(workspaceRoot: fixture.checkout, relativePath: "notes.txt")) }
    do {
        try await waitForEditorState { gate.entered }
        task.cancel(); gate.release()
        await #expect(throws: CancellationError.self) { try await task.value }
        #expect(recorder.plans.isEmpty)
        #expect(try String(contentsOf: fixture.checkout.appendingPathComponent("notes.txt"), encoding: .utf8) == "Saved bytes\n")
        await editors.shutdown()
    } catch { task.cancel(); gate.release(); _ = await task.result; await editors.shutdown(); await fixture.cleanup(); throw error }
    await fixture.cleanup()
}

@MainActor @Test(.timeLimit(.minutes(1)))
func externalEditorLastOwnerRemovalAndSameIDReaddCannotReviveAnOldLaunchCapability() async throws {
    let fixture = try await EditorUIFixture.make(), gate = EditorDiscoveryGate(), recorder = EditorHandoffRecorder()
    let editors = fixture.service(discovery: { await gate.wait(); return [] }, recorder: recorder)
    let task = Task { try await editors.open(.init(workspaceRoot: fixture.checkout, relativePath: "notes.txt")) }
    do {
        try await waitForEditorState { gate.entered }
        let oldService = try fixture.store.fileService(path: fixture.checkout.path)
        try await fixture.store.removeProject(#require(fixture.store.projectRemovalRequest(fixture.project.id)))
        _ = try await fixture.engine.dispatch(.addProjectWithThread(project: fixture.project, thread: fixture.thread))
        try await waitForEditorState { fixture.store.snapshot.projects.contains { $0.id == fixture.project.id } }
        let current = try fixture.store.fileService(path: fixture.checkout.path)
        #expect(current !== oldService)
        gate.release()
        await #expect(throws: CancellationError.self) { try await task.value }
        #expect(recorder.plans.isEmpty && fixture.store.canAccessWorkspaceFiles(fixture.checkout.path))
        #expect(try String(contentsOf: fixture.checkout.appendingPathComponent("notes.txt"), encoding: .utf8) == "Saved bytes\n")
        await editors.shutdown()
    } catch { task.cancel(); gate.release(); _ = await task.result; await editors.shutdown(); await fixture.cleanup(); throw error }
    await fixture.cleanup()
}

@MainActor @Test(.timeLimit(.minutes(1)))
func externalEditorSharedCheckoutSurvivorRetainsTheCapturedLaunchCapability() async throws {
    let fixture = try await EditorUIFixture.make(shared: true), gate = EditorDiscoveryGate(), recorder = EditorHandoffRecorder()
    let editors = fixture.service(discovery: { await gate.wait(); return [] }, recorder: recorder)
    let task = Task { try await editors.open(.init(workspaceRoot: fixture.checkout, relativePath: "notes.txt")) }
    do {
        try await waitForEditorState { gate.entered }
        let original = try fixture.store.fileService(path: fixture.checkout.path)
        try await fixture.store.removeProject(#require(fixture.store.projectRemovalRequest(fixture.project.id)))
        #expect(original === (try fixture.store.fileService(path: fixture.checkout.path)))
        gate.release(); try await task.value
        #expect(recorder.plans.count == 1 && fixture.store.snapshot.projects.count == 1)
        await editors.shutdown()
    } catch { task.cancel(); gate.release(); _ = await task.result; await editors.shutdown(); await fixture.cleanup(); throw error }
    await fixture.cleanup()
}

@MainActor @Test(.timeLimit(.minutes(1)))
func externalEditorRevalidatesTheFilesystemAfterDiscoveryBeforeHandingOff() async throws {
    let fixture = try await EditorUIFixture.make(), gate = EditorDiscoveryGate(), recorder = EditorHandoffRecorder()
    let editors = fixture.service(discovery: { await gate.wait(); return [] }, recorder: recorder)
    let task = Task { try await editors.open(.init(workspaceRoot: fixture.checkout, relativePath: "notes.txt")) }
    do {
        try await waitForEditorState { gate.entered }
        let outside = fixture.root.appendingPathComponent("outside.txt"), target = fixture.checkout.appendingPathComponent("notes.txt")
        try Data("Outside bytes\n".utf8).write(to: outside)
        try FileManager.default.removeItem(at: target)
        try FileManager.default.createSymbolicLink(at: target, withDestinationURL: outside)
        gate.release()
        await #expect(throws: WorkspaceFileError.self) { try await task.value }
        #expect(recorder.plans.isEmpty)
        #expect(try String(contentsOf: outside, encoding: .utf8) == "Outside bytes\n")
        await editors.shutdown()
    } catch { task.cancel(); gate.release(); _ = await task.result; await editors.shutdown(); await fixture.cleanup(); throw error }
    await fixture.cleanup()
}

@MainActor @Test(.timeLimit(.minutes(1)))
func externalEditorFixtureDiscoveryBuildsAClassicCursorHandoffAndRefreshDropsAChangedInstallation() async throws {
    let fixture = try await EditorUIFixture.make(), recorder = EditorHandoffRecorder()
    let applications = fixture.root.appendingPathComponent("Fixture Applications"), cursor = applications.appendingPathComponent("Cursor.app")
    let main = cursor.appendingPathComponent("Contents/MacOS/Application"), cli = cursor.appendingPathComponent("Contents/Resources/app/bin/cursor")
    for url in [main, cli] {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("#!/bin/sh\nexit 97\n".utf8).write(to: url)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: url.path)
    }
    let info = ["CFBundlePackageType": "APPL", "CFBundleIdentifier": "com.todesktop.230313mzl4w4u92", "CFBundleExecutable": "Application"]
    try PropertyListSerialization.data(fromPropertyList: info, format: .xml, options: 0).write(to: cursor.appendingPathComponent("Contents/Info.plist"))
    let editors = fixture.service(discovery: { try ExternalEditorCatalog.discover(applicationDirectories: [applications]) }, recorder: recorder)
    do {
        let available = await editors.availableEditors()
        #expect(available.map(\.id) == [.cursor, .fileManager])
        editors.preferredEditorID = .cursor
        try await editors.open(.init(workspaceRoot: fixture.checkout, relativePath: "notes.txt", location: try .init(line: 5, column: 2)))
        #expect(recorder.plans.count == 1)
        if case .command(let executable, let arguments) = recorder.plans[0] {
            #expect(executable.path == cli.path && arguments == ["--classic", "--goto", fixture.checkout.appendingPathComponent("notes.txt").path + ":5:2"])
        } else { Issue.record("The fixture Cursor open did not reach the recording command handoff.") }
        try FileManager.default.removeItem(at: cli)
        let refreshed = await editors.availableEditors(forceRefresh: true)
        #expect(refreshed.map(\.id) == [.fileManager])
        await #expect(throws: ExternalEditorError.self) { try await editors.open(.init(workspaceRoot: fixture.checkout), editor: .cursor) }
        #expect(recorder.plans.count == 1)
        await editors.shutdown()
    } catch { await editors.shutdown(); await fixture.cleanup(); throw error }
    await fixture.cleanup()
}

@MainActor @Test(.timeLimit(.minutes(1)))
func externalEditorHandoffFailuresAreReportedWithoutAutomaticRetriesOrSavedFileChanges() async throws {
    let fixture = try await EditorUIFixture.make(), recorder = EditorHandoffRecorder()
    var failNextHandoff = true
    let editors = fixture.service(recorder: recorder, handoff: { plan in
        recorder.record(plan)
        let fail = failNextHandoff; failNextHandoff = false
        return Task<Void, any Error> {
            if fail { throw ExternalEditorError(.launchFailed, "The synthetic launch handoff failed.") }
        }
    })
    let target = ExternalEditorTarget(workspaceRoot: fixture.checkout, relativePath: "notes.txt")
    do {
        await #expect(throws: ExternalEditorError.self) { try await editors.open(target) }
        #expect(recorder.plans.count == 1)
        try await editors.open(target)
        #expect(recorder.plans.count == 2)
        #expect(try String(contentsOf: fixture.checkout.appendingPathComponent("notes.txt"), encoding: .utf8) == "Saved bytes\n")
        await editors.shutdown()
    } catch { await editors.shutdown(); await fixture.cleanup(); throw error }
    await fixture.cleanup()
}

@MainActor @Test(.timeLimit(.minutes(1)))
func externalEditorConcurrentDiscoveryIsSharedAndCancellingOneWaiterDoesNotCancelTheOther() async throws {
    let fixture = try await EditorUIFixture.make(), gate = EditorDiscoveryGate(), recorder = EditorHandoffRecorder()
    let editors = fixture.service(discovery: { await gate.wait(); return [] }, recorder: recorder)
    var firstFinished = false
    let first = Task {
        defer { firstFinished = true }
        try await editors.open(.init(workspaceRoot: fixture.checkout, relativePath: "notes.txt"))
    }
    var secondStarted = false
    var second: Task<[ExternalEditorDescriptor], Never>?
    do {
        try await waitForEditorState { gate.entered }
        let next = Task {
            secondStarted = true
            return await editors.availableEditors()
        }
        second = next
        try await waitForEditorState { secondStarted }
        first.cancel()
        try await waitForEditorState { firstFinished }
        await #expect(throws: CancellationError.self) { try await first.value }
        #expect(!gate.cancellationObserved, "One caller must not cancel a discovery scan shared by another caller.")
        gate.release()
        let available = await next.value
        #expect(available.map(\.id) == [.fileManager] && recorder.plans.isEmpty)
        try await editors.open(.init(workspaceRoot: fixture.checkout, relativePath: "notes.txt"))
        #expect(gate.enteredCount == 1 && recorder.plans.count == 1)
        await editors.shutdown()
    } catch {
        first.cancel(); second?.cancel(); gate.release(); _ = await first.result; _ = await second?.result
        await editors.shutdown(); await fixture.cleanup(); throw error
    }
    await fixture.cleanup()
}

@MainActor @Test(.timeLimit(.minutes(1)))
func externalEditorShutdownDrainsDiscoveryBeforeHandoffAndKeepsStoreOwnedFileAccessAlive() async throws {
    let fixture = try await EditorUIFixture.make(), gate = EditorDiscoveryGate(), recorder = EditorHandoffRecorder()
    let editors = fixture.service(discovery: { await gate.wait(); return [] }, recorder: recorder)
    let opening = Task { try await editors.open(.init(workspaceRoot: fixture.checkout, relativePath: "notes.txt")) }
    var shutdown: Task<Void, Never>?
    var finished = false
    do {
        try await waitForEditorState { gate.entered }
        let closing = Task { await editors.shutdown(); finished = true }
        shutdown = closing
        try await waitForEditorState { gate.cancellationObserved }
        #expect(!finished && recorder.plans.isEmpty, "Shutdown must drain its cancelled discovery work before completing.")
        gate.release(); await closing.value
        await #expect(throws: CancellationError.self) { try await opening.value }
        let metadata = try await fixture.store.fileService(path: fixture.checkout.path).metadata(relativePath: "notes.txt")
        #expect(finished && recorder.plans.isEmpty && metadata.kind == .file)
        await #expect(throws: ExternalEditorError.self) { try await editors.open(.init(workspaceRoot: fixture.checkout)) }
    } catch {
        opening.cancel(); gate.release(); _ = await opening.result; await shutdown?.value
        await editors.shutdown(); await fixture.cleanup(); throw error
    }
    await fixture.cleanup()
}

@MainActor @Test(.timeLimit(.minutes(1)))
func externalEditorAcceptedHandoffCompletionRemainsIndependentOfRemovalShutdownAndCallerCancellation() async throws {
    let fixture = try await EditorUIFixture.make(), completion = EditorDiscoveryGate(), recorder = EditorHandoffRecorder()
    let editors = fixture.service(recorder: recorder, handoff: { plan in
        recorder.record(plan)
        return Task<Void, any Error> { await completion.wait() }
    })
    let opening = Task { try await editors.open(.init(workspaceRoot: fixture.checkout, relativePath: "notes.txt")) }
    var shutdown: Task<Void, Never>?
    var finished = false
    do {
        try await waitForEditorState { completion.entered }
        #expect(recorder.plans.count == 1)
        try await fixture.store.removeProject(#require(fixture.store.projectRemovalRequest(fixture.project.id)))
        let closing = Task { await editors.shutdown(); finished = true }
        shutdown = closing
        try await waitForEditorState { finished }
        opening.cancel()
        #expect(!completion.cancellationObserved && !fixture.store.canAccessWorkspaceFiles(fixture.checkout.path))
        completion.release(); try await opening.value; await closing.value
        #expect(recorder.plans.count == 1)
        #expect(try String(contentsOf: fixture.checkout.appendingPathComponent("notes.txt"), encoding: .utf8) == "Saved bytes\n")
    } catch {
        completion.release(); opening.cancel(); _ = await opening.result; await shutdown?.value
        await editors.shutdown(); await fixture.cleanup(); throw error
    }
    await fixture.cleanup()
}
