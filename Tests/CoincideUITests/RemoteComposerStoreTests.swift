import AppKit
@testable import CoincideCore
import Foundation
import Darwin
import Testing
@testable import Coincide

private func remoteComposerUIPhysicalRoot(_ candidate: URL) throws -> URL {
    try FileManager.default.createDirectory(at: candidate, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
    guard let pointer = realpath(candidate.path, nil) else { throw CoincideError("The private fixture directory could not be bound.") }
    defer { free(pointer) }; return URL(fileURLWithPath: String(cString: pointer))
}

private actor RemoteComposerReadGate {
    private var started = false, released = false
    private var observers: [CheckedContinuation<Void, Never>] = []
    private var held: CheckedContinuation<Void, Never>?
    func pause() async { started = true; observers.forEach { $0.resume() }; observers = []; if !released { await withCheckedContinuation { held = $0 } } }
    func entered() async { if !started { await withCheckedContinuation { observers.append($0) } } }
    func release() { released = true; held?.resume(); held = nil }
}
@MainActor private final class RemoteComposerFixture {
    let root: URL
    let composer: RemoteComposerStore
    var scope: RemoteComposerScope
    var text = "Original a\u{301}\u{327} draft"
    var readCount = 0
    var gate: RemoteComposerReadGate?
    var hostBytes: Data, host: ChatAttachment?
    var published: [(RemoteComposerScope, String)] = []
    init(attachment: Bool = true) throws {
        root = try remoteComposerUIPhysicalRoot(FileManager.default.temporaryDirectory.appendingPathComponent("coincide-remote-composer-ui-" + UUID().uuidString))
        scope = .init(environmentID: UUID(), hostID: UUID(), threadID: UUID(), projectID: UUID(), threadCreatedAt: Date(), projectCreatedAt: Date(),
            workspacePath: "/private/REMOTE-ONLY-DO-NOT-RESOLVE", configuration: Data(repeating: 0x17, count: 32))
        hostBytes = Data("Exact host attachment a\u{301}\u{327} 😀\n".utf8)
        host = attachment ? ChatAttachment(id: UUID(), name: "Remote note.txt", mimeType: "text/plain", byteCount: hostBytes.count,
            digest: RemoteComposerScope.digest(hostBytes), fileExtension: "txt") : nil
        composer = .init(root: root)
    }
    var access: AttachmentAccess {
        .init(id: scope.key, data: { reference in
            guard let host = self.host, ComposerDraftSnapshot.sameAttachments([host], [reference]) else { throw RemoteAttachmentFailure(.invalidTarget) }
            self.readCount += 1; if let gate = self.gate { await gate.pause() }; return self.hostBytes
        }, open: { _ in Issue.record("No system open is authorized") }, copyImage: { _ in Issue.record("No clipboard access is authorized") }, save: { _ in Issue.record("No save panel is authorized") })
    }
    func select() async throws {
        await composer.select(scope: scope, text: text, host: host.map { [$0] } ?? [], locals: [], remoteAccess: access, localAccess: nil,
            isCurrent: { [weak self] captured in self?.scope.matches(captured) == true },
            publish: { [weak self] captured, text, expected in
                guard let self, self.scope.matches(captured), self.text.utf8.elementsEqual(expected.utf8) else { return false }
                self.text = text; self.published.append((captured, text)); return true
            }, currentText: { [weak self] in self?.text ?? "" })
        try #require(composer.errorMessage == nil)
        try #require(composer.tools?.isLoaded == true)
    }
    func setText(_ value: String) { text = value; composer.setText(value) }
    func cleanup() async { await composer.shutdown(); try? FileManager.default.removeItem(at: root) }
}
@MainActor private func remoteComposerWait(_ condition: () -> Bool) async throws {
    let deadline = ContinuousClock.now + .seconds(3)
    while !condition() { guard ContinuousClock.now < deadline else { throw CoincideError("Expected owned remote composer state") }; try await Task.sleep(for: .milliseconds(5)) }
}

@Test @MainActor func remoteComposerStashCapturesActualHostBytesAndRestoresAfterReloadWithoutRemoteReads() async throws {
    let f = try RemoteComposerFixture(); try await f.select()
    do {
        let tools = try #require(f.composer.tools), original = f.text, reference = try #require(f.host)
        let stash = try #require(tools.stash(threadID: f.scope.threadID)); await stash.value
        #expect(f.composer.draft.isEmpty && f.composer.selected.isEmpty && f.readCount == 1)
        #expect(tools.entries.count == 1 && tools.pending.isEmpty)
        let entryID = try #require(tools.entries.first?.id)
        await f.composer.shutdown()
        let restored = RemoteComposerStore(root: f.root)
        var reloadedText = "Host text must not replace the saved empty local draft"
        await restored.select(scope: f.scope, text: "Host text must not replace the saved empty local draft", host: [reference], locals: [],
            remoteAccess: .init(id: "forbidden-remote", data: { _ in Issue.record("A stashed immutable copy must be local"); throw CancellationError() }, open: { _ in }, copyImage: { _ in }, save: { _ in }),
            localAccess: nil, isCurrent: { $0.matches(f.scope) }, publish: { _, value, expected in guard reloadedText.utf8.elementsEqual(expected.utf8) else { return false }; reloadedText = value; return true }, currentText: { reloadedText })
        do {
            let reloadedTools = try #require(restored.tools)
            #expect(restored.draft.isEmpty && restored.selected.isEmpty && reloadedTools.entries.count == 1)
            let pop = try #require(reloadedTools.restore(entryID, threadID: f.scope.threadID)); await pop.value
            #expect(restored.draft.utf8.elementsEqual(original.utf8) && reloadedTools.entries.isEmpty)
            #expect(ComposerDraftSnapshot.sameAttachments(restored.selected, [reference]))
            #expect(try await restored.access.data(reference) == f.hostBytes)
            restored.expand(reference); await reloadedTools.flush(); _ = await restored.flush()
            #expect(restored.draft.utf8.elementsEqual((original + "\n\n" + String(decoding: f.hostBytes, as: UTF8.self)).utf8))
            #expect(restored.selected.isEmpty)
        } catch { await restored.shutdown(); throw error }
        await restored.shutdown()
    } catch { await f.cleanup(); throw error }
    await f.cleanup()
}

@Test @MainActor func remoteComposerTwentyEntryStashPopsIntoLaterTextAndNeverSends() async throws {
    let f = try RemoteComposerFixture(attachment: false); try await f.select()
    do {
        let tools = try #require(f.composer.tools)
        for index in 0..<21 {
            f.setText("Saved \(index)"); _ = await f.composer.flush()
            let operation = try #require(tools.stash(threadID: f.scope.threadID)); await operation.value
        }
        #expect(tools.entries.count == 20 && tools.entries.allSatisfy { $0.draft.text != "Saved 0" })
        f.setText("Later authored text"); _ = await f.composer.flush()
        let newest = try #require(tools.entries.first), pop = try #require(tools.restore(newest.id, threadID: f.scope.threadID))
        await pop.value
        #expect(f.composer.draft == "Later authored text\n\nSaved 20")
        #expect(tools.entries.count == 19 && tools.pending.isEmpty)
        #expect(f.readCount == 0)
    } catch { await f.cleanup(); throw error }
    await f.cleanup()
}

@Test @MainActor func remoteComposerFoldedPasteRetriesTheSamePrivateBytesAndExpandsWithoutChangingLaterText() async throws {
    let f = try RemoteComposerFixture(attachment: false); try await f.select()
    do {
        let tools = try #require(f.composer.tools)
        let copies = f.root.appendingPathComponent(f.scope.environmentID.uuidString.lowercased()).appendingPathComponent("Copies")
        try Data("Owned failure injection".utf8).write(to: copies)
        let original = f.composer.draft, paste = String(repeating: "é", count: 16_384)
        #expect(ComposerPastePolicy.folds(paste, bypass: false) && !ComposerPastePolicy.folds(paste, bypass: true))
        #expect(tools.paste(paste, threadID: f.scope.threadID, selection: NSRange(location: original.utf16.count, length: 0), expectedText: original))
        await tools.flush()
        let failed = try #require(tools.imports.first)
        #expect(failed.state == .failed && f.composer.draft.utf8.elementsEqual(original.utf8))
        // Remove only the test-owned blocking file, then retry the already captured bytes.
        try FileManager.default.removeItem(at: copies)
        f.setText(original + " later"); _ = await f.composer.flush()
        let retry = try #require(tools.retryImport(failed.id)); await retry.value
        let reference = try #require(f.composer.selected.first)
        #expect(reference.name == "pasted-text.txt" && reference.byteCount == paste.utf8.count)
        #expect(try await f.composer.access.data(reference) == Data(paste.utf8))
        #expect(f.composer.draft == original + " later")
        f.composer.expand(reference); await tools.flush(); _ = await f.composer.flush()
        #expect(f.composer.draft == original + " later\n\n" + paste && f.composer.selected.isEmpty)
    } catch { await f.cleanup(); throw error }
    await f.cleanup()
}

@Test @MainActor func remoteComposerHeldStashNeverRetargetsIdenticalIDsToANewHostOrConfiguration() async throws {
    let f = try RemoteComposerFixture(); try await f.select()
    do {
        let old = f.scope, gate = RemoteComposerReadGate(); f.gate = gate
        let tools = try #require(f.composer.tools), operation = try #require(tools.stash(threadID: old.threadID))
        await gate.entered()
        f.scope = .init(environmentID: old.environmentID, hostID: UUID(), threadID: old.threadID, projectID: old.projectID,
            threadCreatedAt: old.threadCreatedAt, projectCreatedAt: old.projectCreatedAt, workspacePath: old.workspacePath,
            configuration: Data(repeating: 0x21, count: 32))
        f.text = "Identical IDs, newly selected host text"
        try await f.select()
        await gate.release(); await operation.value
        #expect(f.composer.draft == "Identical IDs, newly selected host text")
        #expect(f.composer.scope?.matches(f.scope) == true)
        #expect(!f.published.contains(where: { !$0.0.matches(f.scope) && $0.1.isEmpty }))
        #expect(tools.entries.first?.draft.text == "Original a\u{301}\u{327} draft")
        #expect(tools.pending.isEmpty)
    } catch { await f.cleanup(); throw error }
    await f.cleanup()
}

@Test @MainActor func remoteComposerShutdownJoinsItsOriginalAttachmentReadAndNeverPublishesAfterCancellation() async throws {
    let f = try RemoteComposerFixture(); try await f.select()
    do {
        let gate = RemoteComposerReadGate(); f.gate = gate
        let source = f.composer.access, reference = try #require(f.host)
        let reading = Task { try await source.data(reference) }
        await gate.entered()
        var closed = false
        let closing = Task { await f.composer.shutdown(); closed = true }
        try await remoteComposerWait { !f.composer.canOperate }
        #expect(!closed)
        await gate.release(); _ = await reading.result; await closing.value
        #expect(closed && f.published.isEmpty)
    } catch { await f.cleanup(); throw error }
    await f.cleanup()
}

@Test @MainActor func remoteComposerLocalOriginalReceiptSurvivesLostReplyAndRejectsPayloadCollisionWithoutRepeatingMutation() async throws {
    let root = try remoteComposerUIPhysicalRoot(FileManager.default.temporaryDirectory.appendingPathComponent("coincide-composer-receipt-" + UUID().uuidString))
    let scope = RemoteComposerScope(environmentID: UUID(), hostID: UUID(), threadID: UUID(), projectID: UUID(), threadCreatedAt: Date(), projectCreatedAt: Date(), workspacePath: "/REMOTE-ONLY", configuration: Data(repeating: 1, count: 32))
    let before = ComposerDraftSnapshot(threadID: scope.threadID, projectID: scope.projectID, workspacePath: scope.workspacePath, text: "Authored text", attachments: [])
    let after = ComposerDraftSnapshot(threadID: scope.threadID, projectID: scope.projectID, workspacePath: scope.workspacePath, text: "", attachments: [])
    let replacement = ComposerDraftReplacement(expected: before, text: "", attachments: []), id = UUID()
    let persistence = RemoteComposerPersistence(root: root)
    _ = try await persistence.write(.init(scope: scope, draft: before), expected: nil)
    _ = try await persistence.write(.init(scope: scope, draft: after), expected: before, commandID: id, replacement: replacement)
    let reopened = RemoteComposerPersistence(root: root)
    #expect(try await reopened.receipt(id, replacement: replacement) == .applied)
    let later = ComposerDraftSnapshot(threadID: scope.threadID, projectID: scope.projectID, workspacePath: scope.workspacePath, text: "Later text", attachments: [])
    _ = try await reopened.write(.init(scope: scope, draft: later), expected: after)
    #expect(try await reopened.write(.init(scope: scope, draft: after), expected: before, commandID: id, replacement: replacement) == .applied)
    #expect(try await reopened.record(scope)?.draft.text == "Later text")
    await #expect(throws: (any Error).self) { _ = try await reopened.receipt(id, replacement: .init(expected: before, text: "Changed payload", attachments: [])) }
    try? FileManager.default.removeItem(at: root)
}

@Test @MainActor func remoteComposerConfigurationAdvanceKeepsLocalDraftAndSelectionWhileOldOperationsLoseAuthority() async throws {
    let f = try RemoteComposerFixture(attachment: false); try await f.select()
    do {
        let tools = try #require(f.composer.tools), bytes = String(repeating: "x", count: 32_768)
        #expect(tools.paste(bytes, threadID: f.scope.threadID, selection: NSRange(location: f.text.utf16.count, length: 0), expectedText: f.text))
        await tools.flush(); _ = await f.composer.flush()
        let reference = try #require(f.composer.selected.first), before = f.scope
        f.setText("Later text stays with its captured local attachment"); _ = await f.composer.flush()
        f.scope = .init(environmentID: before.environmentID, hostID: before.hostID, threadID: before.threadID, projectID: before.projectID,
            threadCreatedAt: before.threadCreatedAt, projectCreatedAt: before.projectCreatedAt, workspacePath: before.workspacePath, configuration: Data(repeating: 9, count: 32))
        try await f.select()
        #expect(f.composer.draft == "Later text stays with its captured local attachment")
        #expect(ComposerDraftSnapshot.sameAttachments(f.composer.selected, [reference]))
        #expect(try await f.composer.access.data(reference) == Data(bytes.utf8))
    } catch { await f.cleanup(); throw error }
    await f.cleanup()
}

@Test @MainActor func remoteComposerToolsScopeCapturedBeforeVerifyRefusesAnIdenticalDraftAfterOwnerChanges() async throws {
    let root = try remoteComposerUIPhysicalRoot(FileManager.default.temporaryDirectory.appendingPathComponent("coincide-composer-scope-" + UUID().uuidString))
    let tools = ComposerDraftToolsStore(root: root), gate = RemoteComposerReadGate()
    let thread = UUID(), project = UUID(), bytes = Data("Owned reference".utf8)
    let reference = ChatAttachment(id: UUID(), name: "Original.txt", mimeType: "text/plain", byteCount: bytes.count, digest: RemoteComposerScope.digest(bytes), fileExtension: "txt")
    var snapshot = ComposerDraftSnapshot(threadID: thread, projectID: project, workspacePath: "/REMOTE-ONLY", text: "Saved source", attachments: [reference])
    var epoch = Data([1]), writes = 0, holdVerify = false
    tools.bind(.init(snapshot: { _ in snapshot }, replace: { _, replacement in
        writes += 1; guard replacement.expected.matches(snapshot) else { return .rejected }
        snapshot = .init(threadID: thread, projectID: project, workspacePath: snapshot.workspacePath, text: replacement.text, attachments: replacement.attachments); return .applied
    }, receipt: { _, _ in nil }, importData: { _, _ in reference }, verify: { _ in if holdVerify { await gate.pause() } },
        captureScope: { _ in epoch }, isCurrentScope: { _, captured in captured == epoch }))
    await tools.load()
    let stash = try #require(tools.stash(threadID: thread)); await stash.value
    let entry = try #require(tools.entries.first)
    holdVerify = true
    let pop = try #require(tools.restore(entry.id, threadID: thread)); await gate.entered()
    epoch = Data([2]); snapshot = .init(threadID: thread, projectID: project, workspacePath: snapshot.workspacePath, text: "New owner text", attachments: [])
    await gate.release(); await pop.value
    #expect(writes == 1 && snapshot.text == "New owner text" && tools.entries.count == 1)
    await tools.shutdown(); try? FileManager.default.removeItem(at: root)
}
