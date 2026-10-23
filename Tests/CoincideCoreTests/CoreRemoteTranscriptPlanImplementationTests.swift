import Foundation
import Testing
@testable import CoincideCore

private actor RemoteTranscriptPlanPeer: ProviderSession {
    nonisolated let events: AsyncStream<ProviderEvent>
    private let sink: AsyncStream<ProviderEvent>.Continuation
    private(set) var inputs: [String] = []
    private(set) var permissions: [PermissionMode] = []
    init() { let pair = AsyncStream<ProviderEvent>.makeStream(); events = pair.stream; sink = pair.continuation }
    func models() -> [ProviderModel] { [] }
    func send(text: String, thread: CodingThread) { inputs.append(text); permissions.append(thread.activeRun?.configuration.permission ?? thread.permission) }
    func interrupt() {}
    func respond(_ request: ApprovalRequest, allow: Bool) {}
    func answer(_ request: ApprovalRequest, answers: [String: String]) {}
    func close() { sink.finish() }
}

private struct RemoteTranscriptPlanServiceFixture {
    let root: URL, data: URL, workspace: URL, launchMarker: URL
    let service: RemoteEnvironmentService
    let peer: RemoteTranscriptPlanPeer
    let target: RemoteWorkspaceTarget
    let binding: RemoteProjectionBinding
    let message: RemoteMessageSummary
    let reference: RemoteProjectionContentReference
    let plan: String
    let options: RemoteEnvironmentOptions

    static func make(draft: String = "", attachments: [ChatAttachment] = [], scratch: Bool = false) async throws -> Self {
        let temporary = FileManager.default.temporaryDirectory.resolvingSymlinksInPath()
        let root = temporary.appendingPathComponent("coincide-remote-plan-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        var owned: RemoteEnvironmentService?
        do {
            let data = root.appendingPathComponent("Host"), workspace = root.appendingPathComponent("Workspace")
            try FileManager.default.createDirectory(at: data, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
            try FileManager.default.createDirectory(at: workspace, withIntermediateDirectories: false)
            let binary = root.appendingPathComponent("must-not-run-provider"), marker = root.appendingPathComponent("provider-was-launched")
            try ("#!/bin/sh\nprintf unexpected > " + CLIShim.shellWord(marker.path) + "\nexit 89\n").write(to: binary, atomically: true, encoding: .utf8)
            try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: binary.path)
            let home = root.appendingPathComponent("PrivateCodexHome")
            let allocation = scratch ? try ScratchWorkspaceService(dataRoot: data).prepare(commandID: UUID(), threadID: UUID(), namingText: "Preserve remote source code") : nil
            let project = allocation?.project ?? WorkspaceProject(path: workspace.path)
            var thread = CodingThread(project: project, model: "captured-model")
            if let allocation {
                thread.id = allocation.threadID; thread.createdAt = allocation.receipt.createdAt
                thread.workspacePath = allocation.workspacePath; thread.scratchWorkspace = allocation.receipt
            }
            thread.permission = .supervised; thread.checkpointPolicy = .disabled
            thread.draft = draft; thread.draftAttachments = attachments
            thread.providerMetadata = .object(["codexInteractionModes": .object([
                "supported": .bool(true), "profile": .string("codex-0.163"), "modes": .array([.string("default"), .string("plan")])])])
            thread.codexRuntimeConfiguration = .init(selection: .custom, executable: binary.path, homeDirectory: home.path)
            let plan = "# Exact remote plan\r\n\r\nPreserve cafe\u{301} and 🌍.\r\n"
            var source = ChatMessage(id: "remote-native-plan", role: .tool, text: plan)
            source.providerEntity = .init(key: .init(sessionID: "native-session", type: "plan", id: "plan"),
                fields: .object(["content": .string(plan), "nativeKind": .string("proposed_plan"), "status": .string("completed")]))
            thread.messages = [source]
            var snapshot = WorkspaceSnapshot(); snapshot.projects = [project]; snapshot.threads = [thread]
            // The host intentionally refuses a pre-existing unidentified DB.
            // Establish its private durable identity before seeding the fixture.
            _ = try RemoteEnvironmentIdentity.load(dataDirectory: data, expected: nil)
            try await WorkspaceDatabase(url: data.appendingPathComponent("workspace.sqlite")).save(snapshot, event: "fixture.remote-plan")
            let peer = RemoteTranscriptPlanPeer(), options = RemoteEnvironmentOptions(codexExecutable: binary.path, codexHome: home.path,
                claudeExecutable: binary.path, claudeConfigurationDirectory: root.appendingPathComponent("UnusedClaudeHome").path,
                githubExecutable: binary.path, githubConfigurationDirectory: root.appendingPathComponent("UnusedGitHubHome").path)
            let service = try RemoteEnvironmentService(dataDirectory: data, options: options, providerFactory: { _ in peer })
            owned = service
            let initial = try await service.snapshot(.init(environmentID: service.environmentID))
            let current = try #require(initial.workspace.threads.first { $0.id == thread.id })
            let target = try await service.bindWorkspace(.init(environmentID: service.environmentID, projectID: current.projectID,
                threadID: current.id, configuration: .init(thread: current)))
            let binding = try await service.openProjection(.init(environmentID: service.environmentID, scope: .thread(thread.id)))
            let messages = try await service.projectionMessages(.init(binding: binding, threadID: thread.id))
            let message = try #require(messages.items.first { $0.id == source.id }), reference = try #require(message.presentation)
            return .init(root: root, data: data, workspace: URL(fileURLWithPath: thread.workspacePath), launchMarker: marker, service: service, peer: peer,
                target: target, binding: binding, message: message, reference: reference, plan: plan, options: options)
        } catch { await owned?.close(); try? FileManager.default.removeItem(at: root); throw error }
    }
    func request(id: UUID = UUID(), binding: RemoteProjectionBinding? = nil, reference: RemoteProjectionContentReference? = nil) -> RemoteEnvironmentCommandRequest {
        .init(environmentID: service.environmentID, id: id,
            command: .implementTranscriptPlan(target: target, binding: binding ?? self.binding, messageID: message.id, presentation: reference ?? self.reference))
    }
    func close() async { await service.close(); try? FileManager.default.removeItem(at: root) }
}

@Test(.timeLimit(.minutes(1)))
func remoteTranscriptPlanCommandUsesExactHostSourceOnceAndOriginalReceiptSurvivesRestart() async throws {
    let f = try await RemoteTranscriptPlanServiceFixture.make(), request = f.request()
    do {
        async let first = f.service.command(request)
        async let concurrent = f.service.command(request)
        let (accepted, duplicate) = try await (first, concurrent)
        #expect(f.target.rootID != nil && accepted.receipt.commandID == request.id)
        try #require(accepted.receipt.rejection == nil)
        #expect(accepted == duplicate)
        let deadline = ContinuousClock.now + .seconds(5)
        while await f.peer.inputs.isEmpty {
            guard ContinuousClock.now < deadline else { throw CoincideError("The synthetic remote plan input did not arrive.") }
            try await Task.sleep(for: .milliseconds(5))
        }
        let inputs = await f.peer.inputs, permissions = await f.peer.permissions
        #expect(inputs.count == 1 && inputs[0].utf8.elementsEqual(TranscriptPlanText.implementationPrompt(f.plan).utf8))
        #expect(permissions == [.supervised])
        #expect(try await f.service.command(request) == accepted)
        #expect(try await f.service.receipt(request).receipt == accepted.receipt)
        await f.service.close()
        let reopened = try RemoteEnvironmentService(dataDirectory: f.data, expectedEnvironmentID: f.service.environmentID,
            options: f.options, providerFactory: { _ in Issue.record("A saved remote plan receipt cannot restart a provider."); throw CancellationError() })
        do {
            #expect(try await reopened.command(request) == accepted)
            #expect(try await reopened.receipt(request).receipt == accepted.receipt)
            await reopened.close()
        } catch { await reopened.close(); throw error }
        #expect(await f.peer.inputs.count == 1)
        #expect(!FileManager.default.fileExists(atPath: f.launchMarker.path))
    } catch { await f.close(); throw error }
    await f.close()
}

private enum RemoteTranscriptPlanRefusal: String, CaseIterable, Sendable { case foreignView, changedSourceReference, changedDraft, replacedPhysicalRoot }

@Test(.timeLimit(.minutes(1)), arguments: RemoteTranscriptPlanRefusal.allCases)
private func remoteTranscriptPlanCommandRefusesStaleClaimsWithoutProviderInput(mode: RemoteTranscriptPlanRefusal) async throws {
    let f = try await RemoteTranscriptPlanServiceFixture.make()
    do {
        var binding = f.binding, reference = f.reference
        switch mode {
        case .foreignView:
            binding = try await f.service.openProjection(.init(environmentID: f.service.environmentID, scope: .thread(f.target.threadID)))
        case .changedSourceReference:
            reference = .init(id: reference.id, kind: reference.kind, totalBytes: reference.totalBytes,
                digest: RemoteProjectionProtocol.digest(Data("Different source revision".utf8)))
        case .changedDraft:
            let edit = try await f.service.command(.init(environmentID: f.service.environmentID,
                command: .editThread(threadID: f.target.threadID, edit: .draft("Keep this authored draft"), expectedConfiguration: f.target.configuration)))
            #expect(edit.receipt.rejection == nil)
        case .replacedPhysicalRoot:
            try FileManager.default.moveItem(at: f.workspace, to: f.root.appendingPathComponent("PreservedOriginalWorkspace"))
            try FileManager.default.createDirectory(at: f.workspace, withIntermediateDirectories: false)
        }
        let request = f.request(binding: binding, reference: reference)
        let refused = try await f.service.command(request)
        #expect(refused.receipt.commandID == request.id && refused.receipt.rejection != nil)
        #expect(try await f.service.receipt(request).receipt == refused.receipt)
        let current = try await f.service.snapshot(.init(environmentID: f.service.environmentID))
        let thread = try #require(current.workspace.threads.first { $0.id == f.target.threadID })
        #expect(thread.messages.count == 1 && thread.activeRun == nil && thread.queuedTurns.isEmpty)
        if mode == .changedDraft { #expect(thread.draft == "Keep this authored draft") }
        #expect(await f.peer.inputs.isEmpty)
        #expect(!FileManager.default.fileExists(atPath: f.launchMarker.path))
    } catch { await f.close(); throw error }
    await f.close()
}


@Test(.timeLimit(.minutes(1)), arguments: [false, true])
func remoteTranscriptPlanNewConversationKeepsSourceDraftAndUsesOriginalDurableOuterUUIDAcrossRestart(scratch: Bool) async throws {
    let attachment = ChatAttachment(id: UUID(), name: "kept.txt", mimeType: "text/plain", byteCount: 1,
        digest: String(repeating: "a", count: 64), fileExtension: "txt")
    let authored = "  Keep private source draft e\u{301}\n "
    let f = try await RemoteTranscriptPlanServiceFixture.make(draft: authored, attachments: [attachment], scratch: scratch)
    let destinationID = UUID(), request = RemoteEnvironmentCommandRequest(environmentID: f.service.environmentID, id: UUID(),
        command: .implementTranscriptPlanInNewConversation(target: f.target, binding: f.binding, messageID: f.message.id,
            presentation: f.reference, destinationID: destinationID))
    do {
        let descriptor = await f.service.descriptor()
        #expect(descriptor.capabilities.supportsTranscriptPlanNewConversation)
        async let first = f.service.command(request)
        async let duplicate = f.service.command(request)
        let (accepted, same) = try await (first, duplicate)
        #expect(accepted == same && accepted.receipt.rejection == nil)
        let deadline = ContinuousClock.now + .seconds(3)
        while await f.peer.inputs.isEmpty {
            guard ContinuousClock.now < deadline else { throw CoincideError("The controlled remote fresh-plan input was not delivered.") }
            try await Task.sleep(for: .milliseconds(5))
        }
        let current = try await f.service.snapshot(.init(environmentID: f.service.environmentID))
        let source = try #require(current.workspace.threads.first { $0.id == f.target.threadID })
        let created = try #require(current.workspace.threads.first { $0.id == destinationID })
        #expect(source.draft.utf8.elementsEqual(authored.utf8) && source.draftAttachments == [attachment])
        #expect(source.messages.filter { $0.role == .user }.isEmpty)
        #expect(created.messages.count == 1 && created.messages[0].text.utf8.elementsEqual(TranscriptPlanText.implementationPrompt(f.plan).utf8))
        #expect(created.activeRun?.id == request.id && created.activeRun?.configuration.agentModeID == "default")
        #expect(created.providerThreadID == nil && created.transcriptPlanSource?.threadID == source.id && created.draftAttachments.isEmpty)
        if scratch {
            let sourceClaim = try #require(source.scratchWorkspace), grant = try #require(created.scratchWorkspace)
            #expect(grant.commandID == request.id && grant.threadID == destinationID && grant.sharedFrom == sourceClaim.commandID)
            #expect(grant.identity == sourceClaim.identity && grant != sourceClaim)
            #expect(created.workspacePath.utf8.elementsEqual(source.workspacePath.utf8))
            try ScratchWorkspaceService(dataRoot: f.data).validate(thread: created)
        } else { #expect(created.scratchWorkspace == nil) }
        #expect(try await f.service.receipt(request).receipt == accepted.receipt)
        await f.service.close()
        let reopened = try RemoteEnvironmentService(dataDirectory: f.data, expectedEnvironmentID: f.service.environmentID,
            options: f.options, providerFactory: { _ in Issue.record("An accepted remote fresh-plan request must not replay"); throw CancellationError() })
        do {
            let recovered = try await reopened.command(request)
            #expect(recovered == accepted)
            let saved = try await reopened.snapshot(.init(environmentID: reopened.environmentID))
            #expect(saved.workspace.threads.filter { $0.id == destinationID }.count == 1)
            #expect(saved.workspace.threads.first { $0.id == f.target.threadID }?.draft.utf8.elementsEqual(authored.utf8) == true)
            await reopened.close()
        } catch { await reopened.close(); throw error }
        #expect(await f.peer.inputs.count == 1)
        #expect(!FileManager.default.fileExists(atPath: f.launchMarker.path))
    } catch { await f.close(); throw error }
    await f.close()
}

@Test func remoteTranscriptPlanNewConversationCapabilityIsAbsentForLegacyHelpers() throws {
    let legacy = RemoteEnvironmentCapabilities(supportsTranscriptPlanImplementation: true)
    var object = try JSONDecoder().decode(JSONValue.self, from: JSONEncoder().encode(legacy)).object ?? [:]
    object.removeValue(forKey: "supportsTranscriptPlanNewConversation")
    let restored = try JSONDecoder().decode(RemoteEnvironmentCapabilities.self, from: JSONEncoder().encode(JSONValue.object(object)))
    #expect(restored.supportsTranscriptPlanImplementation && !restored.supportsTranscriptPlanNewConversation)
}
