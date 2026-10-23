import Foundation
import Testing
@testable import CoincideCore

private func composerDraftAttachment(_ name: String = "Owned note") -> ChatAttachment {
    .init(id: UUID(), name: name, mimeType: "text/plain", byteCount: 3, digest: String(repeating: "a", count: 64), fileExtension: "txt")
}
private func composerDraftCapture(_ thread: CodingThread) -> ComposerDraftSnapshot {
    .init(threadID: thread.id, projectID: thread.projectID, workspacePath: thread.workspacePath,
        text: thread.draft, attachments: thread.draftAttachments)
}
private func composerDraftDecisionFixture() -> WorkspaceSnapshot {
    var snapshot = WorkspaceSnapshot()
    let project = WorkspaceProject(path: "/private/composer-draft-tests")
    var thread = CodingThread(project: project); thread.draft = "a\u{301}\u{327}"
    thread.draftAttachments = [composerDraftAttachment("e\u{301}"), composerDraftAttachment("Second note")]
    snapshot.projects = [project]; snapshot.threads = [thread]
    return snapshot
}

@Test(arguments: ["unicodeText", "attachmentName", "attachmentOrder", "attachmentID", "project", "workspace", "unicodeWorkspace", "missingThread", "archived"])
func composerDraftCASRefusesChangedExactOwnershipTextAndAttachmentMetadata(change: String) throws {
    var snapshot = composerDraftDecisionFixture()
    if change == "unicodeWorkspace" { snapshot.threads[0].workspacePath += "/a\u{301}\u{327}" }
    let captured = composerDraftCapture(snapshot.threads[0])
    let replacement = ComposerDraftReplacement(expected: captured, text: "Saved prompt restored", attachments: [])
    switch change {
    case "unicodeText":
        snapshot.threads[0].draft = "a\u{327}\u{301}"
        #expect(snapshot.threads[0].draft == captured.text)
        #expect(!snapshot.threads[0].draft.utf8.elementsEqual(captured.text.utf8))
    case "attachmentName":
        snapshot.threads[0].draftAttachments[0].name = "\u{e9}"
        #expect(snapshot.threads[0].draftAttachments[0].name == captured.attachments[0].name)
    case "attachmentOrder": snapshot.threads[0].draftAttachments.reverse()
    case "attachmentID": snapshot.threads[0].draftAttachments[0].id = UUID()
    case "project":
        let other = WorkspaceProject(path: "/private/other-checkout")
        snapshot.projects.append(other); snapshot.threads[0].projectID = other.id
    case "workspace": snapshot.threads[0].workspacePath += "/new-checkout"
    case "unicodeWorkspace": snapshot.threads[0].workspacePath = "/private/composer-draft-tests/a\u{327}\u{301}"
    case "missingThread": snapshot.threads.removeAll()
    case "archived": snapshot.threads[0].isArchived = true
    default: Issue.record("Unknown controlled draft mismatch")
    }
    let before = snapshot
    #expect(throws: WorkspaceCommandError.self) {
        _ = try WorkspaceDecision.make(.client(.replaceComposerDraft(replacement)), id: UUID(), snapshot: snapshot, now: Date(), validatingLedger: false)
    }
    #expect(snapshot == before)
}

@Test func composerDraftReplacementPreservesProviderActiveQueueContextAndLiteralCapturedBytes() throws {
    var snapshot = composerDraftDecisionFixture(), thread = snapshot.threads[0]
    thread.providerThreadID = "owned-native-conversation"; thread.model = "captured-model"; thread.permission = .supervised
    thread.providerMetadata = .object(["captured": .string("provider metadata")])
    let configuration = ProviderConfiguration(thread: thread), activeID = UUID(), pendingContext = UUID()
    thread.activeRun = .init(id: activeID, configuration: configuration, startedAt: Date())
    thread.activeRun?.contextTransferIDs = [pendingContext]
    thread.queuedTurns = [.init(id: UUID(), text: "Queued literal Ω\n", configuration: configuration, createdAt: Date(), contextTransferIDs: [pendingContext])]
    thread.queuePaused = true; thread.state = .running
    snapshot.threads[0] = thread
    let captured = composerDraftCapture(thread), newAttachments = [composerDraftAttachment("Restored 工作")]
    let literal = "  Restored a\u{327}\u{301} 工作\n \n"
    let replacement = ComposerDraftReplacement(expected: captured, text: literal, attachments: newAttachments)
    let decision = try WorkspaceDecision.make(.client(.replaceComposerDraft(replacement)), id: UUID(), snapshot: snapshot, now: Date(), validatingLedger: false)
    var expected = thread; expected.draft = literal; expected.draftAttachments = newAttachments
    #expect(decision.snapshot.threads == [expected])
    #expect(decision.effects.isEmpty && decision.closeRuntimes.isEmpty)
    #expect(decision.snapshot.threads[0].draft.utf8.elementsEqual(literal.utf8))
    #expect(decision.snapshot.threads[0].queuedTurns[0].contextTransferIDs == [pendingContext])
    let encoded = try JSONEncoder().encode(replacement)
    let roundTrip = try JSONDecoder().decode(ComposerDraftReplacement.self, from: encoded)
    #expect(roundTrip == replacement && roundTrip.expected.matches(captured))
    let flat = try JSONSerialization.jsonObject(with: encoded) as? [String: Any]
    #expect(flat?["storage"] == nil && flat?["expectedText"] as? String == captured.text)
}

@Test func composerDraftReplacementBoundsAndInvalidAttachmentsKeepTheOriginalDraft() throws {
    let snapshot = composerDraftDecisionFixture(), captured = composerDraftCapture(snapshot.threads[0])
    let exactLimit = String(repeating: "x", count: 8 * 1_024 * 1_024)
    let accepted = try WorkspaceDecision.make(.client(.replaceComposerDraft(.init(expected: captured, text: exactLimit, attachments: []))), id: UUID(), snapshot: snapshot, now: Date(), validatingLedger: false)
    #expect(accepted.snapshot.threads[0].draft.utf8.count == 8 * 1_024 * 1_024)
    var invalid = captured.attachments[0]; invalid.digest = "invalid"
    for replacement in [ComposerDraftReplacement(expected: captured, text: exactLimit + "Ω", attachments: []),
                        .init(expected: captured, text: "Converted paste", attachments: [invalid])] {
        #expect(throws: (any Error).self) {
            _ = try WorkspaceDecision.make(.client(.replaceComposerDraft(replacement)), id: UUID(), snapshot: snapshot, now: Date(), validatingLedger: false)
        }
    }
    #expect(snapshot.threads[0].draft.utf8.elementsEqual(captured.text.utf8))
}

private final class ComposerDraftLaunchProbe: @unchecked Sendable {
    private let lock = NSLock()
    private var launches = 0
    var count: Int { lock.withLock { launches } }
    func make() throws -> any ProviderSession {
        lock.withLock { launches += 1 }
        throw CoincideError("A draft mutation must not launch a provider")
    }
}
private struct ComposerDraftEngineFixture {
    let root: URL
    let database: URL
    let engine: WorkspaceEngine
    let probe: ComposerDraftLaunchProbe
    let threadID: UUID
    static func make() async throws -> Self {
        let root = try temporaryWorkspace(), database = root.appendingPathComponent("drafts.sqlite"), probe = ComposerDraftLaunchProbe()
        let engine = try WorkspaceEngine(url: database, providerFactory: { _ in try probe.make() }, identityResolver: { _ in nil })
        do {
            _ = try await engine.load()
            let project = WorkspaceProject(path: root.path); var thread = CodingThread(project: project); thread.checkpointPolicy = .disabled
            _ = try await engine.dispatch(.addProjectWithThread(project: project, thread: thread))
            return .init(root: root, database: database, engine: engine, probe: probe, threadID: thread.id)
        } catch { await engine.shutdown(); try? FileManager.default.removeItem(at: root); throw error }
    }
    func thread() async throws -> CodingThread {
        let snapshot = await engine.current().snapshot
        return try #require(snapshot.threads.first { $0.id == threadID })
    }
    func reopen() throws -> WorkspaceEngine { try WorkspaceEngine(url: database, providerFactory: { _ in try probe.make() }, identityResolver: { _ in nil }) }
    func close() async { await engine.shutdown(); try? FileManager.default.removeItem(at: root) }
}

@Test(.timeLimit(.minutes(1))) func composerDraftReceiptRecoversOriginalIntentAfterRestartWithoutReplayOrLosingNewerEdits() async throws {
    let f = try await ComposerDraftEngineFixture.make()
    do {
        let old = try await f.engine.attachments.importData(Data("Original note".utf8), name: "original.txt")
        _ = try await f.engine.dispatch(.addAttachments(threadID: f.threadID, attachments: [old]))
        _ = try await f.engine.dispatch(.editThread(f.threadID, .draft("  Stashed 工作 e\u{301}\n")))
        let captured = try await f.thread(), commandID = UUID()
        let replacement = ComposerDraftReplacement(expected: composerDraftCapture(captured), text: "", attachments: [])
        // The caller may lose this return value; recovery uses only its original
        // command UUID and exact payload, without dispatching the intent again.
        let accepted = try await f.engine.dispatch(.replaceComposerDraft(replacement), id: commandID)
        let newer = try await f.engine.attachments.importData(Data("Newer private note".utf8), name: "newer.txt")
        _ = try await f.engine.dispatch(.editThread(f.threadID, .draft("Later authored draft Ω\n ")))
        _ = try await f.engine.dispatch(.addAttachments(threadID: f.threadID, attachments: [newer]))
        let beforeLookup = await f.engine.current()
        #expect(try await f.engine.composerDraftReceipt(commandID: commandID, replacement: replacement) == accepted)
        #expect(try await f.engine.composerDraftReceipt(commandID: UUID(), replacement: replacement) == nil)
        let afterLookup = await f.engine.current()
        #expect(afterLookup.sequence == beforeLookup.sequence && afterLookup.snapshot == beforeLookup.snapshot)
        await f.engine.shutdown()
        let reopened = try f.reopen()
        do {
            let snapshot = try await reopened.load(), restored = try #require(snapshot.threads.first { $0.id == f.threadID })
            #expect(restored.draft.utf8.elementsEqual("Later authored draft Ω\n ".utf8) && restored.draftAttachments == [newer])
            let sequence = await reopened.current().sequence
            #expect(try await reopened.composerDraftReceipt(commandID: commandID, replacement: replacement) == accepted)
            #expect(try await reopened.composerDraftReceipt(commandID: commandID, replacement: replacement) == accepted)
            #expect(await reopened.current().sequence == sequence)
            let changed = ComposerDraftReplacement(expected: replacement.expected, text: "Different intent", attachments: [])
            await #expect(throws: WorkspaceCommitError.commandIDCollision) { _ = try await reopened.composerDraftReceipt(commandID: commandID, replacement: changed) }
            #expect(try await reopened.attachments.data(for: old) == Data("Original note".utf8))
            #expect(try await reopened.attachments.data(for: newer) == Data("Newer private note".utf8))
            #expect(f.probe.count == 0)
            await reopened.shutdown()
        } catch { await reopened.shutdown(); throw error }
    } catch { await f.close(); throw error }; await f.close()
}

@Test(.timeLimit(.minutes(1))) func composerDraftStaleRejectionIsDurableAndExactPayloadReceiptNeverOverwritesCurrentDraft() async throws {
    let f = try await ComposerDraftEngineFixture.make()
    do {
        _ = try await f.engine.dispatch(.editThread(f.threadID, .draft("a\u{301}\u{327}")))
        let captured = try await f.thread(), commandID = UUID()
        let replacement = ComposerDraftReplacement(expected: composerDraftCapture(captured), text: "Would overwrite a newer edit", attachments: [])
        _ = try await f.engine.dispatch(.editThread(f.threadID, .draft("a\u{327}\u{301}")))
        await #expect(throws: WorkspaceCommandError.self) { _ = try await f.engine.dispatch(.replaceComposerDraft(replacement), id: commandID) }
        let receipt = try await f.engine.composerDraftReceipt(commandID: commandID, replacement: replacement)
        #expect(receipt?.rejection != nil)
        #expect(try await f.thread().draft.utf8.elementsEqual("a\u{327}\u{301}".utf8))
        await f.engine.shutdown()
        let reopened = try f.reopen()
        do {
            _ = try await reopened.load()
            #expect(try await reopened.composerDraftReceipt(commandID: commandID, replacement: replacement) == receipt)
            let changed = ComposerDraftReplacement(expected: replacement.expected, text: "Changed rejection payload", attachments: [])
            await #expect(throws: WorkspaceCommitError.commandIDCollision) { _ = try await reopened.composerDraftReceipt(commandID: commandID, replacement: changed) }
            let restored = try #require(await reopened.current().snapshot.threads.first { $0.id == f.threadID })
            #expect(restored.draft.utf8.elementsEqual("a\u{327}\u{301}".utf8) && f.probe.count == 0)
            await reopened.shutdown()
        } catch { await reopened.shutdown(); throw error }
    } catch { await f.close(); throw error }; await f.close()
}

@Test(.timeLimit(.minutes(1))) func composerDraftAbsentReceiptResolutionFencesTheLateOriginalAcrossRestart() async throws {
    let f = try await ComposerDraftEngineFixture.make()
    do {
        _ = try await f.engine.dispatch(.editThread(f.threadID, .draft("Keep this authored draft Ω\n")))
        let captured = try await f.thread(), commandID = UUID()
        let replacement = ComposerDraftReplacement(expected: composerDraftCapture(captured), text: "", attachments: [])
        #expect(try await f.engine.composerDraftReceipt(commandID: commandID, replacement: replacement) == nil)
        let before = await f.engine.current()
        let resolved = try #require(try await f.engine.composerDraftReceipt(commandID: commandID, replacement: replacement, resolvingAbsent: true))
        #expect(resolved.rejection != nil && resolved.eventCount == 0)
        #expect(await f.engine.current().snapshot == before.snapshot)
        await #expect(throws: WorkspaceCommandError.self) { _ = try await f.engine.dispatch(.replaceComposerDraft(replacement), id: commandID) }
        #expect(try await f.thread().draft.utf8.elementsEqual(captured.draft.utf8))
        await f.engine.shutdown()
        let reopened = try f.reopen()
        do {
            _ = try await reopened.load()
            #expect(try await reopened.composerDraftReceipt(commandID: commandID, replacement: replacement, resolvingAbsent: true) == resolved)
            await #expect(throws: WorkspaceCommandError.self) { _ = try await reopened.dispatch(.replaceComposerDraft(replacement), id: commandID) }
            let restored = try #require(await reopened.current().snapshot.threads.first { $0.id == f.threadID })
            #expect(restored.draft.utf8.elementsEqual(captured.draft.utf8) && f.probe.count == 0)
            let changed = ComposerDraftReplacement(expected: replacement.expected, text: "Changed original intent", attachments: [])
            await #expect(throws: WorkspaceCommitError.commandIDCollision) { _ = try await reopened.composerDraftReceipt(commandID: commandID, replacement: changed, resolvingAbsent: true) }
            await reopened.shutdown()
        } catch { await reopened.shutdown(); throw error }
    } catch { await f.close(); throw error }; await f.close()
}

@Test(.timeLimit(.minutes(1)), arguments: ["draft", "attachmentName"])
func composerDraftJournalRebuildPreservesCanonicallyEquivalentExactBytes(field: String) async throws {
    let f = try await ComposerDraftEngineFixture.make()
    do {
        let attachment = try await f.engine.attachments.importData(Data("Exact immutable file".utf8), name: "e\u{301}.txt")
        _ = try await f.engine.dispatch(.addAttachments(threadID: f.threadID, attachments: [attachment]))
        _ = try await f.engine.dispatch(.editThread(f.threadID, .draft("e\u{301}")))
        let original = try await f.thread(), expected = composerDraftCapture(original)
        if field == "draft" {
            _ = try await f.engine.dispatch(.editThread(f.threadID, .draft("\u{e9}")))
        } else {
            var changed = attachment; changed.name = "\u{e9}.txt"
            _ = try await f.engine.dispatch(.replaceComposerDraft(.init(expected: expected, text: original.draft, attachments: [changed])))
        }
        let current = try await f.thread()
        #expect(current.draft == original.draft && current.draftAttachments.first?.name == attachment.name)
        #expect(!composerDraftCapture(current).matches(expected))
        await f.engine.shutdown()
        let replayed = try await WorkspaceDatabase(url: f.database).rebuildProjection().snapshot
        let restored = try #require(replayed.threads.first { $0.id == f.threadID })
        #expect(restored.draft.utf8.elementsEqual(current.draft.utf8))
        #expect(ComposerDraftSnapshot.sameAttachments(restored.draftAttachments, current.draftAttachments))
        #expect(!composerDraftCapture(restored).matches(expected) && f.probe.count == 0)
    } catch { await f.close(); throw error }; await f.close()
}
