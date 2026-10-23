import Darwin
import Foundation
import Testing
@testable import Coincide
@testable import CoincideCore

@MainActor @Test func remoteQueuedEditorStashesItsOwnFullVerifiedInputWithoutReplacingTheUnsentComposer() async throws {
    let candidate = FileManager.default.temporaryDirectory.appendingPathComponent("coincide-remote-queued-editor-" + UUID().uuidString)
    try FileManager.default.createDirectory(at: candidate, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
    guard let path = realpath(candidate.path, nil) else { throw CancellationError() }; defer { free(path) }
    let root = URL(fileURLWithPath: String(cString: path)), environment = UUID(), host = UUID()
    let project = WorkspaceProject(path: "/private/REMOTE-ONLY-no-local-access"), thread = CodingThread(project: project)
    let target = RemoteWorkspaceTarget(environmentID: environment, projectID: project.id, threadID: thread.id, configuration: .init(thread: thread))
    let bytes = Data("Exact queued reference e\u{301}\u{327} 😀".utf8)
    let reference = ChatAttachment(id: UUID(), name: "Queued original.txt", mimeType: "text/plain", byteCount: bytes.count, digest: RemoteProjectionProtocol.digest(bytes), fileExtension: "txt")
    let content = RemoteSteeringContentReference(id: UUID(), kind: .text, totalBytes: 1, digest: String(repeating: "a", count: 64))
    let refs = RemoteSteeringContentReference(id: UUID(), kind: .attachments, totalBytes: 1, digest: String(repeating: "b", count: 64))
    let row = RemoteQueuedInputSummary(id: UUID(), createdAt: .now, digest: String(repeating: "c", count: 64), preview: "Queued before", text: content,
        attachments: refs, attachmentCount: 1, provider: .codex, model: "", permission: .supervised, canSteer: false, canEdit: true, reason: nil)
    let capture = RemoteSteeringCapture(binding: .init(environmentID: environment, hostID: host, viewID: UUID(), threadID: thread.id, digest: String(repeating: "d", count: 64)), threadCreatedAt: thread.createdAt, projectCreatedAt: project.createdAt, runID: nil, runtimeID: nil, activeConfigurationDigest: nil)
    let page = RemoteSteeringPage(capture: capture, kind: .queue, operations: [], offset: 0, totalCount: 1, items: [row], nextCursor: nil, complete: true)
    let operations = RemoteSteeringPage(capture: capture, kind: .operations, operations: [], offset: 0, totalCount: 0, items: [], nextCursor: nil, complete: true)
    let state = RemoteSteeringReadResult(target: target, sequence: 1, canSteer: false, interruptsTools: false, reason: nil, page: page, operationPage: operations, activeModel: nil, activePermission: nil, operationCount: 0)
    let editor = RemoteSteeringEditor(source: row, state: state, originals: [reference], text: "Queued before", root: root.appendingPathComponent("Queued"))
    let active = RemoteComposerStore(root: root.appendingPathComponent("Active"))
    let activeUploads = RemoteAttachmentsStore(root: root.appendingPathComponent("ActiveUploads"))
    let uploadTarget = RemoteAttachmentTarget(environmentID: environment, projectID: project.id, threadID: thread.id)
    var activeText = "Separate unsent composer a\u{327}\u{301}", reads = 0
    var valid = true
    let scope = RemoteComposerScope(environmentID: environment, hostID: host, threadID: thread.id, projectID: project.id,
        threadCreatedAt: thread.createdAt, projectCreatedAt: project.createdAt, workspacePath: project.path, configuration: RemoteComposerScope.fingerprint(target.configuration))
    let access = AttachmentAccess(id: "private-queue-owned-source", data: { value in
        guard valid, value.id == reference.id else { throw CancellationError() }; reads += 1; return bytes
    }, open: { _ in Issue.record("No system open is authorized") }, copyImage: { _ in Issue.record("No clipboard is authorized") }, save: { _ in Issue.record("No save panel is authorized") })
    do {
        await editor.uploads.select(target: uploadTarget, transport: nil, hostDraftAttachments: [], supported: true)
        _ = try await editor.uploads.stage(bytes, reference: reference, target: uploadTarget)
        await activeUploads.select(target: uploadTarget, transport: nil, hostDraftAttachments: [], supported: true)
        #expect(editor.uploads.entries.count == 1 && activeUploads.entries.isEmpty)
        // A fresh active-composer cache after an uncertain queue upload must
        // not inherit queued-editor refs, even with identical host/thread IDs.
        await activeUploads.shutdown()
        let reopenedActive = RemoteAttachmentsStore(root: root.appendingPathComponent("ActiveUploads"))
        await reopenedActive.select(target: uploadTarget, transport: nil, hostDraftAttachments: [], supported: true)
        #expect(reopenedActive.entries.isEmpty)
        await reopenedActive.shutdown()
        await active.select(scope: scope, text: activeText, host: [], locals: [], remoteAccess: nil, localAccess: nil,
            isCurrent: { _ in valid }, publish: { _, text, expected in guard activeText.utf8.elementsEqual(expected.utf8) else { return false }; activeText = text; return true }, currentText: { activeText })
        let editScope = RemoteComposerScope(environmentID: environment, hostID: host, threadID: thread.id, projectID: project.id,
            threadCreatedAt: thread.createdAt, projectCreatedAt: project.createdAt, workspacePath: project.path, configuration: RemoteComposerScope.fingerprint(row.digest))
        await editor.composer.select(scope: editScope, text: editor.text, host: [reference], locals: [], remoteAccess: access, localAccess: nil,
            isCurrent: { _ in valid }, publish: { _, text, expected in guard editor.text.utf8.elementsEqual(expected.utf8) else { return false }; editor.text = text; return true }, currentText: { editor.text })
        let tools = try #require(editor.composer.tools), stash = try #require(tools.stash(threadID: thread.id))
        await stash.value
        #expect(editor.text.isEmpty && editor.composer.selected.isEmpty && reads == 1)
        #expect(activeText.utf8.elementsEqual("Separate unsent composer a\u{327}\u{301}".utf8) && active.selected.isEmpty)
        editor.text = "Typed later in queue editor"; editor.composer.setText(editor.text); _ = await editor.composer.flush()
        let entry = try #require(tools.entries.first), pop = try #require(tools.restore(entry.id, threadID: thread.id)); await pop.value
        #expect(editor.text.contains("Queued before") && editor.text.contains("Typed later in queue editor"))
        let restored = try #require(editor.composer.selected.first)
        #expect(try await editor.composer.data(restored) == bytes)
        #expect(reads == 1 && active.selected.isEmpty)
        valid = false
        #expect(!editor.composer.canOperate && !active.canOperate)
    } catch { await editor.composer.shutdown(); await editor.uploads.shutdown(); await active.shutdown(); await activeUploads.shutdown(); throw error }
    await editor.composer.shutdown(); await editor.uploads.shutdown(); await active.shutdown(); await activeUploads.shutdown()
    try FileManager.default.removeItem(at: root)
}
