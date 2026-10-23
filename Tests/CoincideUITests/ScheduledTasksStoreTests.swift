import CoincideCore
import Darwin
import Foundation
import Testing
@testable import Coincide

@MainActor private struct ScheduledStoreFixture {
    let root: URL
    let project: WorkspaceProject
    let thread: CodingThread
    let engine: WorkspaceEngine
    let controller: ScheduledTasksStore
    static func make() async throws -> Self {
        let pointer = try #require(realpath(FileManager.default.temporaryDirectory.path, nil)); defer { free(pointer) }
        let root = URL(fileURLWithPath: String(cString: pointer)).appendingPathComponent("coincide-scheduled-store-" + UUID().uuidString)
        let path = root.appendingPathComponent("Checkout"); try FileManager.default.createDirectory(at: path, withIntermediateDirectories: true)
        let project = WorkspaceProject(path: path.path), thread = CodingThread(project: project, model: "offline-never-started")
        var snapshot = WorkspaceSnapshot(); snapshot.projects = [project]; snapshot.threads = [thread]
        let database = root.appendingPathComponent("workspace.sqlite")
        _ = try await WorkspaceDatabase(url: database).commit(snapshot, event: "fixture", commandID: UUID())
        let engine = try WorkspaceEngine(url: database, providerFactory: { _ in throw CoincideError("No provider is authorized in this fixture.") }, identityResolver: { _ in nil })
        let service = ScheduledTaskService(engine: engine, secrets: MemoryScheduledTaskSecrets())
        let controller = ScheduledTasksStore(engine: engine, service: service)
        await controller.load()
        return .init(root: root, project: project, thread: thread, engine: engine, controller: controller)
    }
    func close() async { await controller.shutdown(); await engine.shutdown(); try? FileManager.default.removeItem(at: root) }
}

@MainActor @Test(.timeLimit(.minutes(1)))
func scheduledTasksControllerCRUDUsesExactCapturedSourceAndStaleDefinitionCannotRetargetAfterAnotherEdit() async throws {
    let f = try await ScheduledStoreFixture.make()
    do {
        let source = try f.controller.source(threadID: f.thread.id)
        let task = try ScheduledTaskDefinition(title: "Explicitly paused", prompt: "Preserve original payload", enabled: false,
            schedule: .interval(everyMilliseconds: 60_000), source: source)
        try await f.controller.save(task, expectedRevision: nil)
        var updated = task; updated.revision = UUID(); updated.prompt = "A newer reviewed payload"
        try await f.controller.save(updated, expectedRevision: task.revision)
        await f.controller.runNow(task)
        #expect(f.controller.error == ScheduledTaskError.staleRevision.localizedDescription)
        #expect(await f.engine.current().snapshot.threads.count == 1)
        await #expect(throws: (any Error).self) { try await f.controller.save(task, expectedRevision: task.revision) }
        let snapshot = await f.engine.current().snapshot
        #expect(snapshot.scheduler?.tasks.first?.prompt == updated.prompt && snapshot.threads.first?.draft == f.thread.draft)
        await f.controller.delete(updated)
        #expect(await f.engine.current().snapshot.scheduler?.tasks.isEmpty == true)
    } catch { await f.close(); throw error }
    await f.close()
}

@MainActor @Test func scheduledTasksControllerRejectsLateEditsAndDoesNotOpenListenerOrProviderOnLoad() async throws {
    let f = try await ScheduledStoreFixture.make()
    do {
        #expect(f.controller.listenerPort == nil && f.controller.ledger.tasks.isEmpty)
        let task = try ScheduledTaskDefinition(title: "Paused", prompt: "Not executed", schedule: .interval(everyMilliseconds: 60_000), source: f.controller.source(threadID: f.thread.id))
        await f.controller.shutdown()
        await #expect(throws: ScheduledTaskError.unavailable) { try await f.controller.save(task, expectedRevision: nil) }
        #expect(await f.engine.current().snapshot.scheduler == nil)
    } catch { await f.close(); throw error }
    await f.close()
}
