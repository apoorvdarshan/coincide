import AppKit
import CoincideCore
import SwiftUI
import Testing
@testable import Coincide

private actor NativeProjectCreationGate {
    private var waiter: CheckedContinuation<ManagedProjectCreationResult, any Error>?
    private var project: WorkspaceProject?
    private var cancelled = false
    private(set) var calls: [(String, URL)] = []
    private(set) var cancellations = 0

    func create(name: String, root: URL) async throws -> ManagedProjectCreationResult {
        calls.append((name, root))
        let path = root.appendingPathComponent("created-project", isDirectory: true)
        try FileManager.default.createDirectory(at: path, withIntermediateDirectories: true)
        try "Preserve partial project files".write(to: path.appendingPathComponent("keep.txt"), atomically: true, encoding: .utf8)
        var value = WorkspaceProject(path: path.path); value.name = name; project = value
        return try await withTaskCancellationHandler {
            try Task.checkCancellation()
            return try await withCheckedThrowingContinuation { continuation in
                if cancelled { continuation.resume(throwing: CancellationError()) }
                else { waiter = continuation }
            }
        } onCancel: { Task { await self.cancel() } }
    }
    func finish(warning: String?) throws {
        guard let project, let continuation = waiter else { throw CoincideError("The fixture creation has not started.") }
        waiter = nil; continuation.resume(returning: .init(project: project, commitWarning: warning))
    }
    private func cancel() {
        cancelled = true; cancellations += 1
        let continuation = waiter; waiter = nil; continuation?.resume(throwing: CancellationError())
    }
}

@MainActor private func waitManagedProjectUI(_ condition: () async throws -> Bool) async throws {
    let end = ContinuousClock.now + .seconds(8)
    while try await !condition() {
        guard ContinuousClock.now < end else { throw CoincideError("The native project creation did not settle.") }
        try await Task.sleep(for: .milliseconds(10))
    }
}

private func managedProjectUIRoot() throws -> URL {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("coincide-project-ui-" + UUID().uuidString)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    return root
}

@MainActor @Test(.timeLimit(.minutes(1)))
func nativeProjectCreationKeepsCommandsResponsiveSelectsItsFirstConversationAndRetainsCommitWarnings() async throws {
    let root = try managedProjectUIRoot(); defer { try? FileManager.default.removeItem(at: root) }
    let database = root.appendingPathComponent("workspace.sqlite"), projects = root.appendingPathComponent("Projects")
    let gate = NativeProjectCreationGate(), engine = try WorkspaceEngine(url: database)
    let store = WorkspaceStore(engine: engine, managedProjectsRoot: projects, projectCreator: { try await gate.create(name: $0, root: $1) })
    await store.load()
    let creation = Task { try await store.createManagedProject(name: "  Café Kit  ") }
    do {
        try await waitManagedProjectUI { await gate.calls.count == 1 }
        #expect(store.snapshot.projects.isEmpty && store.snapshot.threads.isEmpty)
        store.addProject(at: root)
        try await waitManagedProjectUI { store.snapshot.projects.count == 1 }
        let existingID = try #require(store.selectedProjectID)
        store.showArchived = true
        try await gate.finish(warning: "Git author identity is not configured. Commit your staged files after setting it.")
        let result = try await creation.value
        let project = try #require(store.selectedProject), thread = try #require(store.selectedThread)
        #expect(project == result.project && project.name == "Café Kit" && project.id != existingID)
        #expect(thread.projectID == project.id && thread.workspacePath == project.path && store.workspaceReady(for: thread))
        #expect(thread.messages.isEmpty && !thread.isBusy && thread.queuedTurns.isEmpty && !store.showArchived)
        #expect(store.snapshot.projects.count == 2 && store.snapshot.threads.count == 1 && store.errorMessage == nil)
        #expect(result.commitWarning?.contains("identity") == true)
        let calls = await gate.calls
        #expect(calls.first?.0 == "Café Kit" && calls.first?.1 == projects)
        #expect(try String(contentsOf: URL(fileURLWithPath: project.path).appendingPathComponent("keep.txt"), encoding: .utf8) == "Preserve partial project files")
        if ProcessInfo.processInfo.environment["COINCIDE_RENDER_PROJECT"] == "1" {
            try await captureManagedProjectUI(store, result: result)
        }
        await store.shutdown()
        let reopened = WorkspaceStore(databaseURL: database); await reopened.load()
        #expect(reopened.snapshot.projects.contains(project) && reopened.thread(thread.id)?.workspacePath == project.path)
        #expect(reopened.managedProjectsRoot.path == projects.path)
        await reopened.shutdown()
    } catch { creation.cancel(); _ = await creation.result; await store.shutdown(); throw error }
}

@MainActor @Test(.timeLimit(.minutes(1)))
func nativeProjectCreationShutdownCancelsOwnedWorkPreservesFilesAndNeverRegistersAnUnfinishedProject() async throws {
    let root = try managedProjectUIRoot(); defer { try? FileManager.default.removeItem(at: root) }
    let projects = root.appendingPathComponent("Projects"), gate = NativeProjectCreationGate()
    let engine = try WorkspaceEngine(url: root.appendingPathComponent("workspace.sqlite"))
    let store = WorkspaceStore(engine: engine, managedProjectsRoot: projects, projectCreator: { try await gate.create(name: $0, root: $1) })
    await store.load()
    let creation = Task { try await store.createManagedProject(name: "Interrupted Project") }
    do {
        try await waitManagedProjectUI { await gate.calls.count == 1 }
        await store.shutdown()
        switch await creation.result {
        case .success: Issue.record("Shutdown registered an unfinished project.")
        case .failure(let error): #expect(error is CancellationError)
        }
        #expect(await gate.cancellations == 1)
        #expect(store.snapshot.projects.isEmpty && store.snapshot.threads.isEmpty)
        #expect(try String(contentsOf: projects.appendingPathComponent("created-project/keep.txt"), encoding: .utf8) == "Preserve partial project files")
        await #expect(throws: CancellationError.self) { try await store.createManagedProject(name: "After Shutdown") }
        #expect(await gate.calls.count == 1)
    } catch { creation.cancel(); _ = await creation.result; await store.shutdown(); throw error }
}

@MainActor private func captureManagedProjectUI(_ store: WorkspaceStore, result: ManagedProjectCreationResult) async throws {
    _ = NSApplication.shared
    for scheme in [ColorScheme.light, .dark] {
        try await captureManagedProjectView(NewProjectSheet(store: store), scheme: scheme, size: .init(width: 500, height: 290), name: "sheet")
        try await captureManagedProjectView(CreatedProjectWarning(result: result).padding(24), scheme: scheme,
                                            size: .init(width: 500, height: 300), name: "commit-warning")
    }
}

@MainActor @Test(.timeLimit(.minutes(1)))
func nativeProjectRegistrationRacePreservesTheAlreadyOpenedProjectAndReportsThePreparedFolder() async throws {
    let root = try managedProjectUIRoot(); defer { try? FileManager.default.removeItem(at: root) }
    let projects = root.appendingPathComponent("Projects"), gate = NativeProjectCreationGate()
    let engine = try WorkspaceEngine(url: root.appendingPathComponent("workspace.sqlite"))
    let store = WorkspaceStore(engine: engine, managedProjectsRoot: projects, projectCreator: { try await gate.create(name: $0, root: $1) })
    await store.load()
    let creation = Task { try await store.createManagedProject(name: "Already Opened") }
    do {
        try await waitManagedProjectUI { await gate.calls.count == 1 }
        let target = projects.appendingPathComponent("created-project")
        store.addProject(at: target)
        try await waitManagedProjectUI { store.snapshot.projects.count == 1 }
        let existing = try #require(store.selectedProject)
        try await gate.finish(warning: nil)
        switch await creation.result {
        case .success: Issue.record("Creation registered a second project for an already opened folder.")
        case .failure(let error):
            #expect(error.localizedDescription.contains(existing.path))
            #expect(error.localizedDescription.contains("preserved"))
        }
        #expect(store.snapshot.projects == [existing] && store.snapshot.threads.isEmpty)
        #expect(store.selectedProjectID == existing.id && store.errorMessage == nil)
        #expect(try String(contentsOf: target.appendingPathComponent("keep.txt"), encoding: .utf8) == "Preserve partial project files")
        await store.shutdown()
    } catch { creation.cancel(); _ = await creation.result; await store.shutdown(); throw error }
}

@MainActor private func captureManagedProjectView<Content: View>(_ content: Content, scheme: ColorScheme, size: NSSize, name: String) async throws {
    let hosting = NSHostingView(rootView: content.environment(\.colorScheme, scheme).frame(width: size.width, height: size.height)
        .background(scheme == .light ? Color.white : Color(white: 0.12)))
    let window = NSWindow(contentRect: .init(origin: .init(x: -10_000, y: -10_000), size: size), styleMask: .borderless, backing: .buffered, defer: false)
    window.appearance = NSAppearance(named: scheme == .light ? .aqua : .darkAqua); hosting.appearance = window.appearance
    window.isReleasedWhenClosed = false; window.contentView = hosting
    defer { window.close() }
    hosting.layoutSubtreeIfNeeded(); try await Task.sleep(for: .milliseconds(180)); hosting.layoutSubtreeIfNeeded()
    let bitmap = try #require(hosting.bitmapImageRepForCachingDisplay(in: hosting.bounds))
    hosting.cacheDisplay(in: hosting.bounds, to: bitmap)
    let url = FileManager.default.temporaryDirectory.appendingPathComponent("coincide-project-\(name)-\(scheme == .light ? "light" : "dark").png")
    try #require(bitmap.representation(using: .png, properties: [:])).write(to: url)
    print("Native project preview: \(url.path)")
}
