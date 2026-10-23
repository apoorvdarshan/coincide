import Foundation
import Darwin
import Testing
@testable import CoincideCore

private func remoteComposerPhysicalRoot(_ candidate: URL) throws -> URL {
    try FileManager.default.createDirectory(at: candidate, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
    guard let pointer = realpath(candidate.path, nil) else { throw CoincideError("The private fixture directory could not be bound.") }
    defer { free(pointer) }; return URL(fileURLWithPath: String(cString: pointer))
}

private struct RemoteComposerHostFixture {
    let root: URL, data: URL
    let service: RemoteEnvironmentService
    let options: RemoteEnvironmentOptions
    let current: CodingThread, project: WorkspaceProject
    let uploaded: ChatAttachment
    let input: RemoteComposerSubmission
    static func make() async throws -> Self {
        let root = try remoteComposerPhysicalRoot(FileManager.default.temporaryDirectory.appendingPathComponent("coincide-remote-composer-host-" + UUID().uuidString))
        let data = root.appendingPathComponent("Host"), source = root.appendingPathComponent("Source")
        try FileManager.default.createDirectory(at: data, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        try FileManager.default.createDirectory(at: source, withIntermediateDirectories: true)
        let options = RemoteEnvironmentOptions(codexExecutable: "/usr/bin/true", codexHome: root.appendingPathComponent("CodexHome").path,
            claudeExecutable: "/usr/bin/true", claudeConfigurationDirectory: root.appendingPathComponent("ClaudeHome").path,
            githubExecutable: "/usr/bin/true", githubConfigurationDirectory: root.appendingPathComponent("GhHome").path)
        let project = WorkspaceProject(path: source.path)
        var thread = CodingThread(project: project); thread.checkpointPolicy = .disabled
        let preparation = GitWorktreeRequest(sourcePath: source.path, destinationRoot: data.appendingPathComponent("Worktrees").path, selection: .createBranch(name: "held-composer", baseRef: "HEAD"))
        thread.workspacePreparation = .init(request: preparation); thread.workspacePreparation?.phase = .interrupted; thread.workspacePath = preparation.destinationPath
        thread.draft = "Original host draft a\u{301}\u{327}"
        thread.codexRuntimeConfiguration = .init(selection: .custom, executable: "/usr/bin/true", homeDirectory: options.codexHome!)
        thread.draftAttachments = (0..<2).map { .init(id: UUID(), name: "Host \($0).txt", mimeType: "text/plain", byteCount: 3, digest: String(repeating: "a", count: 64), fileExtension: "txt") }
        var snapshot = WorkspaceSnapshot(); snapshot.projects = [project]; snapshot.threads = [thread]
        _ = try RemoteEnvironmentIdentity.load(dataDirectory: data, expected: nil)
        try await WorkspaceDatabase(url: data.appendingPathComponent("workspace.sqlite")).save(snapshot, event: "remote.composer.fixture")
        let service = try RemoteEnvironmentService(dataDirectory: data, options: options, providerFactory: { _ in Issue.record("An interrupted checkout must not release a provider"); throw CancellationError() })
        do {
            let initial = try await service.snapshot(.init(environmentID: service.environmentID))
            let current = try #require(initial.workspace.threads.first), target = RemoteAttachmentTarget(environmentID: service.environmentID, projectID: project.id, threadID: current.id)
            let bytes = Data("Private local paste a\u{301} 😀".utf8)
            let upload = RemoteAttachmentUploadRequest(target: target, name: "pasted-text.txt", byteCount: bytes.count, digest: RemoteAttachmentJournal.digest(bytes))
            _ = try await service.beginAttachmentUpload(upload)
            _ = try await service.appendAttachmentChunk(.init(upload: upload, index: 0, data: bytes, digest: upload.digest))
            let reference = try #require(try await service.finalizeAttachmentUpload(upload).attachment)
            let host = try #require(await service.descriptor().hostID)
            let input = RemoteComposerSubmission(target: target, hostID: host, threadCreatedAt: current.createdAt, projectCreatedAt: project.createdAt,
                text: "Explicit remote input", expectedConfiguration: .init(thread: current), expectedHostDraftDigest: RemoteComposerSubmission.textDigest(current.draft),
                expectedDraftAttachments: current.draftAttachments, selectedDraftAttachmentIDs: [current.draftAttachments[1].id], uploadedAttachmentIDs: [reference.id],
                selectionDigest: String(repeating: "b", count: 64), orderedAttachmentIDs: [reference.id, current.draftAttachments[1].id])
            return .init(root: root, data: data, service: service, options: options, current: current, project: project, uploaded: reference, input: input)
        } catch { await service.close(); throw error }
    }
    func close() async { await service.close(); try? FileManager.default.removeItem(at: root) }
}

@Test func remoteComposerSelectedInputKeepsOmittedHostReferencesAndOriginalReceiptNeverRepeatsAcrossRestart() async throws {
    let f = try await RemoteComposerHostFixture.make()
    do {
        let request = RemoteEnvironmentCommandRequest(environmentID: f.service.environmentID, id: UUID(), command: .submitComposerDraft(f.input))
        async let a = f.service.command(request)
        async let b = f.service.command(request)
        let (first, duplicate) = try await (a, b)
        #expect(first == duplicate)
        try #require(first.receipt.rejection == nil)
        let result = try await f.service.snapshot(.init(environmentID: f.service.environmentID))
        let thread = try #require(result.workspace.threads.first)
        try #require(thread.queuedTurns.count == 1)
        #expect(thread.activeRun == nil)
        #expect(thread.queuedTurns[0].attachments?.map(\.id) == [f.uploaded.id, f.current.draftAttachments[1].id])
        #expect(thread.draftAttachments.map(\.id) == [f.current.draftAttachments[0].id])
        await f.service.close()
        let reopened = try RemoteEnvironmentService(dataDirectory: f.data, expectedEnvironmentID: f.service.environmentID, options: f.options,
            providerFactory: { _ in Issue.record("Receipt inspection cannot resend"); throw CancellationError() })
        do {
            #expect(try await reopened.command(request) == first)
            #expect(try await reopened.receipt(request).receipt == first.receipt)
            let staleHost = try await reopened.command(.init(environmentID: f.service.environmentID, id: UUID(), command: .submitComposerDraft(f.input)))
            #expect(staleHost.receipt.rejection != nil)
            #expect(try await reopened.snapshot(.init(environmentID: f.service.environmentID)).workspace.threads[0].queuedTurns.count == 1)
        } catch { await reopened.close(); throw error }
        await reopened.close()
    } catch { await f.close(); throw error }
    await f.close()
}

@Test(arguments: ["text-bytes", "reference", "configuration", "thread-birth", "project-birth"])
func remoteComposerHostCASRefusesLateChangesBeforeAnyInputCapture(change: String) async throws {
    let f = try await RemoteComposerHostFixture.make()
    do {
        var snapshot = try await f.service.snapshot(.init(environmentID: f.service.environmentID)).workspace
        switch change {
        case "text-bytes": snapshot.threads[0].draft = "Original host draft a\u{327}\u{301}"
        case "reference": snapshot.threads[0].draftAttachments[0].name = "Changed.txt"
        case "configuration": snapshot.threads[0].permission = .fullAccess
        case "thread-birth": snapshot.threads[0].createdAt.addTimeInterval(1)
        case "project-birth": snapshot.projects[0].createdAt = Date().addingTimeInterval(1)
        default: break
        }
        let record = RemoteAttachmentRecord(upload: .init(target: f.input.target, name: f.uploaded.name, byteCount: f.uploaded.byteCount, digest: f.uploaded.digest), attachment: f.uploaded, claimedBy: nil, cancelled: false)
        let preparation = RemoteEnvironmentPreparation.attachments(.init(target: f.input.target, incarnation: UUID(), records: [record]))
        let request = RemoteEnvironmentCommandRequest(environmentID: f.service.environmentID, id: UUID(), command: .submitComposerDraft(f.input))
        #expect(throws: (any Error).self) { _ = try RemoteEnvironmentAdmission.commands(request, preparation: preparation, snapshot: snapshot) }
        #expect(snapshot.threads[0].queuedTurns.isEmpty)
    } catch { await f.close(); throw error }
    await f.close()
}

@Test func remoteComposerCapabilityDefaultsFalseAndLegacyAttachmentRequestBytesStayExact() throws {
    enum Legacy: Codable { case submitWithAttachments(target: RemoteAttachmentTarget, text: String, expectedConfiguration: ProviderConfiguration, expectedDraftAttachments: [ChatAttachment], uploadedAttachmentIDs: [UUID]) }
    let project = WorkspaceProject(path: "/private/remote-composer-legacy"), target = RemoteAttachmentTarget(environmentID: UUID(), projectID: UUID(), threadID: UUID())
    let config = ProviderConfiguration(thread: CodingThread(project: project)), text = "a\u{301}\u{327}"
    let legacy = Legacy.submitWithAttachments(target: target, text: text, expectedConfiguration: config, expectedDraftAttachments: [], uploadedAttachmentIDs: [])
    let actual = RemoteEnvironmentCommand.submitWithAttachments(target: target, text: text, expectedConfiguration: config, expectedDraftAttachments: [], uploadedAttachmentIDs: [])
    #expect(try RemoteAttachmentProtocol.payload(legacy) == RemoteAttachmentProtocol.payload(actual))
    var encoded = try #require(JSONSerialization.jsonObject(with: JSONEncoder().encode(RemoteEnvironmentCapabilities())) as? [String: Any])
    encoded.removeValue(forKey: "supportsRemoteComposerDraftSelection")
    let decoded = try JSONDecoder().decode(RemoteEnvironmentCapabilities.self, from: JSONSerialization.data(withJSONObject: encoded))
    #expect(!decoded.supportsRemoteComposerDraftSelection)
    let descriptor = RemoteEnvironmentDescriptor(environmentID: UUID(), label: "Old host")
    #expect(descriptor.hostID == nil)
}
