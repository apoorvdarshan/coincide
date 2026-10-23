import Foundation
import Testing
@testable import CoincideCore

private final class RemoteLifecycleProviderTripwire: @unchecked Sendable {
    private let lock = NSLock(); private var launches = 0
    var count: Int { lock.withLock { launches } }
    func session() throws -> any ProviderSession { lock.withLock { launches += 1 }; throw CoincideError("The lifecycle fixture must never launch a provider.") }
}

@Test(.timeLimit(.minutes(1)))
func remoteLifecycleEngineRejectsOldIncarnationsEvenAfterExactIDsAndMetadataAreRecreated() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("coincide-lifecycle-incarnation-" + UUID().uuidString).resolvingSymlinksInPath()
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
    let project = WorkspaceProject(path: root.path), thread = CodingThread(project: project)
    var snapshot = WorkspaceSnapshot(); snapshot.projects = [project]; snapshot.threads = [thread]
    let database = root.appendingPathComponent("workspace.sqlite"), probe = RemoteLifecycleProviderTripwire()
    try await WorkspaceDatabase(url: database).save(snapshot, event: "fixture")
    let engine = try WorkspaceEngine(url: database, providerFactory: { _ in try probe.session() }, identityResolver: { _ in nil })
    let environmentID = UUID()
    let service = RemoteLifecycleService(environmentID: environmentID, read: { try await engine.readRemoteLifecycle($0) }, bind: { $0 })
    do {
        _ = try await engine.load()
        let target = RemoteWorkspaceTarget(environmentID: environmentID, projectID: project.id, threadID: thread.id, configuration: .init(thread: thread))
        let state = try #require(await service.read(.init(environmentID: environmentID, target: target)).thread)
        let prepared = try await service.prepare(state.capture, action: .setAutoSettle(enabled: false))
        let request = RemoteEnvironmentCommandRequest(environmentID: environmentID, command: .lifecycle(capture: state.capture, action: .setAutoSettle(enabled: false)))
        _ = try await engine.dispatch(.removeProject(projectID: project.id, expectedThreadIDs: [thread.id]))
        _ = try await engine.dispatch(.addProjectWithThread(project: project, thread: thread))
        let refused = try await engine.dispatchRemoteEnvironment(request, preparation: .lifecycle(prepared))
        #expect(refused.commandID == request.id && refused.rejection != nil)
        #expect(try await engine.dispatchRemoteEnvironment(request, preparation: .none) == refused)
        let current = await engine.current()
        #expect(current.error == nil && current.snapshot.threads[0].workspaceLifecycle == nil && probe.count == 0)
    } catch { await service.close(); await engine.shutdown(); try? FileManager.default.removeItem(at: root); throw error }
    await service.close(); await engine.shutdown(); try FileManager.default.removeItem(at: root)
}

@Test(.timeLimit(.minutes(1)))
func remoteLifecycleAutomaticSweepsRequireExplicitNewClientNegotiationAndReadNeverActivatesThem() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("coincide-lifecycle-negotiation-" + UUID().uuidString).resolvingSymlinksInPath()
    let host = root.appendingPathComponent("Host"), workspace = root.appendingPathComponent("Workspace")
    try FileManager.default.createDirectory(at: workspace, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
    let probe = RemoteLifecycleProviderTripwire()
    let service = try RemoteEnvironmentService(dataDirectory: host, providerFactory: { _ in try probe.session() })
    let environmentID = service.environmentID, project = WorkspaceProject(path: workspace.path)
    var thread = CodingThread(project: project); thread.draft = "Keep the explicit unsent draft"
    thread.createdAt = Date().addingTimeInterval(-10 * 86_400); thread.updatedAt = Date().addingTimeInterval(-5 * 86_400)
    var snapshot = WorkspaceSnapshot(); snapshot.projects = [project]; snapshot.threads = [thread]
    let database = host.appendingPathComponent("workspace.sqlite")
    try await WorkspaceDatabase(url: database).save(snapshot, event: "fixture")
    var observer: Task<Bool, Never>?
    do {
        #expect(await service.descriptor().capabilities.supportsWorkspaceLifecycleControls)
        let legacy = RemoteEnvironmentSnapshotRequest(environmentID: environmentID)
        let legacyWire = try RemoteEnvironmentProtocol.encode(legacy)
        #expect(legacyWire["clientSupportsLifecycleControls"] == .null)
        #expect(try await service.snapshot(legacy).workspace.threads[0].settlement == nil)
        let target = RemoteWorkspaceTarget(environmentID: environmentID, projectID: project.id, threadID: thread.id, configuration: .init(thread: thread))
        _ = try await service.readLifecycle(.init(environmentID: environmentID, target: target))
        #expect(try await service.snapshot(.init(environmentID: environmentID, clientSupportsLifecycleControls: false)).workspace.threads[0].settlement == nil)
        let updates = try await service.updates(), id = thread.id
        let owned = Task {
            for await update in updates {
                if update.workspace.threads.contains(where: { $0.id == id && $0.settlement?.phase == .settled }) { return true }
            }
            return false
        }
        observer = owned
        _ = try await service.snapshot(.init(environmentID: environmentID, clientSupportsLifecycleControls: true))
        #expect(await owned.value)
        let final = try await WorkspaceDatabase(url: database).revision().snapshot.threads[0]
        #expect(final.settlement?.script == nil && final.activeRun == nil && final.draft == thread.draft && probe.count == 0)
        var encoded = try #require(RemoteEnvironmentProtocol.encode(await service.descriptor().capabilities).object)
        encoded.removeValue(forKey: "supportsWorkspaceLifecycleControls")
        let old = try RemoteEnvironmentProtocol.decode(RemoteEnvironmentCapabilities.self, from: .object(encoded))
        #expect(!old.supportsWorkspaceLifecycleControls)
    } catch { observer?.cancel(); await service.close(); try? FileManager.default.removeItem(at: root); throw error }
    observer?.cancel(); await service.close(); try FileManager.default.removeItem(at: root)
}
