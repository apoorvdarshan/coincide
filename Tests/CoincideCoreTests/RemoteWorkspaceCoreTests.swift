import Foundation
import Testing
@testable import CoincideCore

private struct RemoteWorkspaceCoreFixture {
    let root: URL, workspace: URL, data: URL
    let service: RemoteEnvironmentService
    let target: RemoteWorkspaceTarget
    static func make() async throws -> Self {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("coincide-remote-workspace-core-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        let workspace = root.appendingPathComponent("Workspace")
        try FileManager.default.createDirectory(at: workspace, withIntermediateDirectories: false)
        let data = root.appendingPathComponent("Host")
        let service = try RemoteEnvironmentService(dataDirectory: data, options: .init(codexExecutable: "/usr/bin/true", codexHome: root.appendingPathComponent("NativeHome").path),
            providerFactory: { _ in throw CoincideError("This fixture must never start a provider.") })
        do {
            let projectID = UUID(), threadID = UUID(), id = service.environmentID
            _ = try await service.command(.init(environmentID: id, command: .addProject(id: projectID, path: workspace.path, title: nil)))
            _ = try await service.command(.init(environmentID: id, command: .createThread(id: threadID, projectID: projectID, provider: .codex, title: "Offline workspace", model: "", permission: .supervised)))
            let snapshot = try await service.snapshot(.init(environmentID: id))
            let thread = try #require(snapshot.workspace.threads.first)
            let target = try await service.bindWorkspace(.init(environmentID: id, projectID: projectID, threadID: threadID, configuration: .init(thread: thread)))
            return .init(root: root, workspace: URL(fileURLWithPath: thread.workspacePath), data: data, service: service, target: target)
        } catch { await service.close(); try? FileManager.default.removeItem(at: root); throw error }
    }
    func close() async { await service.close(); try? FileManager.default.removeItem(at: root) }
    func run(_ mutation: RemoteWorkspaceMutation) async throws -> RemoteWorkspaceOperation {
        let request = RemoteWorkspaceMutationRequest(target: target, mutation: mutation)
        _ = try await service.beginWorkspaceOperation(request)
        let deadline = ContinuousClock.now + .seconds(8)
        while ContinuousClock.now < deadline {
            let result = try #require(try await service.workspaceOperation(request))
            if result.state == .finished || result.state == .uncertain { return result }
            try await Task.sleep(for: .milliseconds(5))
        }
        throw CoincideError("The offline remote workspace operation did not finish.")
    }
}

@Test func remoteWorkspaceNativeFilesPreserveRevisionAndMetadataGuardsAcrossModelChanges() async throws {
    let fixture = try await RemoteWorkspaceCoreFixture.make()
    do {
        let created = try await fixture.run(.createFile(path: "Sources/Unicode café.swift", contents: "let café = 1\n"))
        #expect(created.state == .finished && created.failure == nil)
        let read = try await fixture.service.readWorkspace(.init(target: fixture.target,
            query: .readFile(path: "Sources/Unicode café.swift", allowMissing: false, maxBytes: 2_000_000)))
        guard case .document(let document) = read.value else { throw CoincideError("Expected text document.") }
        let revision = try #require(document.revision)
        let listing = try await fixture.service.readWorkspace(.init(target: fixture.target, query: .list(directoryPath: "Sources")))
        guard case .entries(let entries) = listing.value else { throw CoincideError("Expected native entries.") }
        #expect(entries.entries.map(\.path) == ["Sources/Unicode café.swift"])
        let matches = try await fixture.service.readWorkspace(.init(target: fixture.target,
            query: .searchContents(query: "café", limit: 10, caseSensitive: true, wholeWord: false, useRegex: false)))
        guard case .contents(let content) = matches.value else { throw CoincideError("Expected native content search.") }
        #expect(content.matches.first?.path == document.relativePath)
        let changed = try await fixture.service.command(.init(environmentID: fixture.target.environmentID,
            command: .editThread(threadID: fixture.target.threadID, edit: .model("changed-model"), expectedConfiguration: fixture.target.configuration)))
        #expect(changed.receipt.rejection == nil)
        let saved = try await fixture.run(.saveFile(path: document.relativePath, contents: "let café = 2\n", revision: revision))
        #expect(saved.state == .finished && saved.failure == nil, "An unrelated model change keeps the same editor/root.")
        let stale = try await fixture.run(.saveFile(path: document.relativePath, contents: "must not overwrite", revision: revision))
        #expect(stale.state == .finished && stale.failure?.kind == .conflict)
        #expect(try String(contentsOf: fixture.workspace.appendingPathComponent(document.relativePath), encoding: .utf8) == "let café = 2\n")
        let denied = try await fixture.run(.createFile(path: ".git/config", contents: "must not create metadata"))
        #expect(denied.state == .finished && denied.failure?.kind == .invalidRequest)
        await #expect(throws: RemoteWorkspaceFailure(.invalidRequest)) {
            try await fixture.service.readWorkspace(.init(target: fixture.target, query: .list(directoryPath: "../")))
        }
        await fixture.close()
    } catch { await fixture.close(); throw error }
}

@Test func remoteWorkspaceRootPinsSurviveRestartAndRefusePhysicalReplacement() async throws {
    let fixture = try await RemoteWorkspaceCoreFixture.make()
    do {
        await fixture.service.close()
        let reopened = try RemoteEnvironmentService(dataDirectory: fixture.data, expectedEnvironmentID: fixture.target.environmentID)
        do {
            #expect(try await reopened.bindWorkspace(fixture.target).rootID == fixture.target.rootID)
            let old = fixture.workspace.appendingPathExtension("old")
            try FileManager.default.moveItem(at: fixture.workspace, to: old)
            try FileManager.default.createDirectory(at: fixture.workspace, withIntermediateDirectories: false)
            await #expect(throws: RemoteWorkspaceFailure(.staleRoot)) { try await reopened.bindWorkspace(fixture.target) }
            await #expect(throws: RemoteWorkspaceFailure(.staleRoot)) {
                try await reopened.readWorkspace(.init(target: fixture.target, query: .list(directoryPath: "")))
            }
            await reopened.close()
        } catch { await reopened.close(); throw error }
        await fixture.close()
    } catch { await fixture.close(); throw error }
}

@Test func remoteWorkspaceCrashJournalIsExactAndNeverReplaysAcceptedOrRunningIntents() async throws {
    let fixture = try await RemoteWorkspaceCoreFixture.make()
    do {
        await fixture.service.close()
        let request = RemoteWorkspaceMutationRequest(target: fixture.target, mutation: .createFile(path: "never-replay.txt", contents: "retained intent"))
        let accepted = try RemoteWorkspaceJournal(directory: fixture.data)
        var running = try accepted.insert(request); running.state = .running; try accepted.store(running)
        let reopened = try RemoteEnvironmentService(dataDirectory: fixture.data, expectedEnvironmentID: fixture.target.environmentID)
        do {
            let result = try #require(try await reopened.workspaceOperation(request))
            #expect(result.state == .uncertain && result.failure?.kind == .interrupted)
            #expect(try await reopened.beginWorkspaceOperation(request) == result)
            #expect(!FileManager.default.fileExists(atPath: fixture.workspace.appendingPathComponent("never-replay.txt").path))
            let different = RemoteWorkspaceMutationRequest(id: request.id, target: fixture.target, mutation: .createFile(path: "never-replay.txt", contents: "different intent"))
            await #expect(throws: RemoteWorkspaceFailure(.commandCollision)) { try await reopened.workspaceOperation(different) }
            await #expect(throws: RemoteWorkspaceFailure(.commandCollision)) { try await reopened.beginWorkspaceOperation(different) }
            await reopened.close()
        } catch { await reopened.close(); throw error }
        await fixture.close()
    } catch { await fixture.close(); throw error }
}

@Test func remoteWorkspaceNativeTwoMegabyteEditorIntentHasSeparateEscapedWireLimit() throws {
    let configuration = ProviderConfiguration(thread: CodingThread(project: .init(path: "/fixture/remote-editor")))
    let target = RemoteWorkspaceTarget(environmentID: UUID(), projectID: UUID(), threadID: UUID(), configuration: configuration, rootID: UUID())
    let contents = String(repeating: "\u{0001}", count: 2_000_000)
    let request = RemoteWorkspaceMutationRequest(target: target, mutation: .createFile(path: "large.txt", contents: contents))
    let bytes = try RemoteWorkspaceJournal.payload(request)
    #expect(bytes.count > RemoteEnvironmentProtocol.maximumRequestBytes)
    #expect(bytes.count < RemoteEnvironmentProtocol.maximumWorkspaceRequestBytes)
    #expect(try JSONDecoder().decode(RemoteWorkspaceMutationRequest.self, from: bytes) == request)
}
