import AppKit
import CryptoKit
import Foundation
import Testing
@testable import Coincide
@testable import CoincideCore

private actor ComposerToolsGate {
    private var entered = false
    private var continuation: CheckedContinuation<Void, Never>?
    private var observers: [CheckedContinuation<Void, Never>] = []
    func pause() async {
        entered = true; observers.forEach { $0.resume() }; observers = []
        await withCheckedContinuation { continuation = $0 }
    }
    func wait() async { if !entered { await withCheckedContinuation { observers.append($0) } } }
    func release() { continuation?.resume(); continuation = nil }
}

@MainActor private final class ComposerToolsFixture {
    let root: URL
    let threadID = UUID(), projectID = UUID()
    var drafts: [UUID: ComposerDraftSnapshot] = [:]
    var receipts: [UUID: ComposerDraftToolsOutcome] = [:]
    var commands: [(UUID, ComposerDraftReplacement)] = []
    var captured: [(Data, String)] = []
    var importFailure = false, loseReply = false, missingAttachment = false
    var replaceGate: ComposerToolsGate?, verifyGate: ComposerToolsGate?, importGate: ComposerToolsGate?
    var replaceCancelled = false
    init() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("coincide-composer-tools-\(UUID())").resolvingSymlinksInPath()
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        set(threadID, text: "Authored e\u{301} draft  ")
    }
    func set(_ id: UUID, text: String, attachments: [ChatAttachment] = [], path: String = "/private/synthetic-workspace") {
        drafts[id] = .init(threadID: id, projectID: projectID, workspacePath: path, text: text, attachments: attachments)
    }
    func tools() async -> ComposerDraftToolsStore {
        let tools = ComposerDraftToolsStore(root: root.appendingPathComponent("DraftTools")); tools.bind(transport); await tools.load(); return tools
    }
    var transport: ComposerDraftToolsTransport {
        .init(snapshot: { self.drafts[$0] }, replace: { id, replacement in
            self.commands.append((id, replacement))
            if let gate = self.replaceGate { await gate.pause(); self.replaceGate = nil }
            self.replaceCancelled = Task.isCancelled
            let result: ComposerDraftToolsOutcome
            if let latest = self.drafts[replacement.expected.threadID], latest.matches(replacement.expected) {
                self.drafts[latest.threadID] = .init(threadID: latest.threadID, projectID: latest.projectID, workspacePath: latest.workspacePath,
                    text: replacement.text, attachments: replacement.attachments)
                result = .applied
            } else { result = .rejected }
            self.receipts[id] = result
            if self.loseReply { self.loseReply = false; return .unknown }
            return result
        }, receipt: { id, _ in self.receipts[id] }, importData: { bytes, name in
            self.captured.append((bytes, name))
            if let gate = self.importGate { await gate.pause(); self.importGate = nil }
            if self.importFailure { self.importFailure = false; throw CoincideError("Synthetic immutable-copy write failure.") }
            return Self.reference(bytes, name: name)
        }, verify: { _ in
            if let gate = self.verifyGate { await gate.pause(); self.verifyGate = nil }
            if self.missingAttachment { throw CoincideError("This saved attachment is missing. Attach it again.") }
        })
    }
    static func reference(_ data: Data, name: String) -> ChatAttachment {
        .init(id: UUID(), name: name, mimeType: "text/plain", byteCount: data.count,
            digest: SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined(), fileExtension: "txt")
    }
    func cleanup() { try? FileManager.default.removeItem(at: root) }
}

@Test func composerLongPasteUsesUtf8BoundaryUniqueNamesAndExactUtf16SelectionWithExplicitBypass() throws {
    #expect(!ComposerPastePolicy.folds(String(repeating: "a", count: 32_767), bypass: false))
    let unicode = String(repeating: "é", count: 16_384)
    #expect(unicode.utf8.count == 32_768 && ComposerPastePolicy.folds(unicode, bypass: false))
    #expect(!ComposerPastePolicy.folds(unicode, bypass: true))
    #expect(ComposerPastePolicy.nextName(["PASTED-TEXT.TXT", "pasted-text-2.txt"]) == "pasted-text-3.txt")
    let original = "before 🦋 after e\u{301}"
    let range = NSRange((original.range(of: "🦋"))!, in: original)
    let result = try #require(ComposerPastePolicy.replacing(range, in: original, with: "literal\ntext"))
    #expect(result.0.utf8.elementsEqual("before literal\ntext after e\u{301}".utf8))
    #expect(result.1 == NSRange(location: range.location + "literal\ntext".utf16.count, length: 0))
    #expect(ComposerPastePolicy.replacing(.init(location: range.location + 1, length: 0), in: original, with: "bad") == nil)
    #expect(ComposerPastePolicy.exceedsInputLimit("x", text: String(repeating: "a", count: 120_000), selection: .init(location: 0, length: 0)))
    #expect(!ComposerPastePolicy.exceedsInputLimit("x", text: String(repeating: "a", count: 120_000), selection: .init(location: 0, length: 1)))
}

@MainActor @Test(.timeLimit(.minutes(1)))
func composerStashIsDurableBeforeClearRestoresAcrossNativeThreadsAndRetainsExactImagesAndNewerDraft() async throws {
    let f = try ComposerToolsFixture(); defer { f.cleanup() }
    let image = ChatAttachment(id: UUID(), name: "Exact image.png", mimeType: "image/png", byteCount: 123, digest: String(repeating: "a", count: 64), fileExtension: "png")
    let original = "Original e\u{301} text with trailing spaces  "
    f.set(f.threadID, text: original, attachments: [image])
    let tools = await f.tools(), gate = ComposerToolsGate(); f.replaceGate = gate
    let stashing = try #require(tools.stash(threadID: f.threadID)); await gate.wait()
    // The write is positive before the draft can be cleared.
    let persisted = try await ComposerDraftPersistence(root: f.root.appendingPathComponent("DraftTools")).load()
    #expect(persisted.entries.count == 1 && persisted.pending.count == 1)
    #expect(persisted.entries[0].draft.text.utf8.elementsEqual(original.utf8))
    f.set(f.threadID, text: "Typed while saving stash", attachments: [image])
    await gate.release(); await stashing.value
    #expect(f.drafts[f.threadID]?.text == "Typed while saving stash" && tools.entries.count == 1 && tools.pending.isEmpty)
    await tools.shutdown()
    let restarted = await f.tools(), other = UUID()
    f.set(other, text: "Newer target draft e\u{301}  ")
    f.verifyGate = ComposerToolsGate(); let verifyGate = try #require(f.verifyGate)
    let entryID = try #require(restarted.entries.first?.id)
    let restoring = try #require(restarted.restore(entryID, threadID: other)); await verifyGate.wait()
    f.set(other, text: "Latest target selection's text  ")
    await verifyGate.release(); await restoring.value
    #expect(f.drafts[other]?.text.utf8.elementsEqual(("Latest target selection's text  \n\n" + original).utf8) == true)
    #expect(f.drafts[other]?.attachments == [image] && restarted.entries.isEmpty)
    #expect(f.drafts[f.threadID]?.text == "Typed while saving stash")
    #expect(f.commands.count == 2)
    await restarted.shutdown()
}

@MainActor @Test(.timeLimit(.minutes(1)))
func composerLostDraftAcknowledgmentChecksOriginalCommandAfterRestartWithoutReplayOrDeletingUnverifiedStash() async throws {
    let f = try ComposerToolsFixture(); defer { f.cleanup() }
    let tools = await f.tools()
    await tools.stash(threadID: f.threadID)?.value
    let entryID = try #require(tools.entries.first?.id)
    f.set(f.threadID, text: "Existing target")
    f.loseReply = true
    await tools.restore(entryID, threadID: f.threadID)?.value
    let accepted = try #require(f.commands.last)
    #expect(tools.pending.map(\.id) == [accepted.0] && tools.entries.count == 1)
    let acceptedText = try #require(f.drafts[f.threadID]?.text)
    await tools.shutdown()
    let restarted = await f.tools()
    #expect(f.commands.count == 2 && restarted.pending.count == 1 && restarted.entries.count == 1)
    await restarted.checkResult(accepted.0)?.value
    #expect(restarted.pending.isEmpty && restarted.entries.isEmpty && f.commands.count == 2)
    #expect(f.drafts[f.threadID]?.text.utf8.elementsEqual(acceptedText.utf8) == true)
    // Missing references must be verified before taking an entry.
    let ref = ComposerToolsFixture.reference(Data("private synthetic copy".utf8), name: "notes.txt")
    f.set(f.threadID, text: "Kept on verification failure", attachments: [ref]); await restarted.stash(threadID: f.threadID)?.value
    f.missingAttachment = true; await restarted.restore(try #require(restarted.entries.first?.id), threadID: f.threadID)?.value
    #expect(restarted.entries.count == 1 && f.drafts[f.threadID]?.text == "")
    #expect(f.commands.count == 3)
    await restarted.shutdown()
}

@MainActor @Test(.timeLimit(.minutes(1)))
func composerFailedImportRetriesOnlyCapturedBytesAndRetainsNewerTypingWithoutSendingOrRereadingSource() async throws {
    let f = try ComposerToolsFixture(); defer { f.cleanup() }
    let url = f.root.appendingPathComponent("original.txt"), original = Data("Original exact bytes e\u{301}".utf8)
    try original.write(to: url); f.importFailure = true
    let tools = await f.tools(); tools.importFiles([url], threadID: f.threadID); await tools.flush()
    let failure = try #require(tools.importItems(f.threadID).first)
    #expect(failure.state == .failed && f.commands.isEmpty && f.captured.count == 1)
    try Data("Different source file after the original pick".utf8).write(to: url)
    f.set(f.threadID, text: "Newer text while retrying  ")
    await tools.retryImport(failure.id)?.value
    #expect(f.captured.count == 2 && f.captured[0].0 == original && f.captured[1].0 == original)
    #expect(f.drafts[f.threadID]?.text == "Newer text while retrying  " && f.drafts[f.threadID]?.attachments.count == 1)
    #expect(tools.importItems(f.threadID).isEmpty && f.commands.count == 1)
    // A delayed large paste never overwrites typing that arrived meanwhile.
    let latest = try #require(f.drafts[f.threadID]), gate = ComposerToolsGate(); f.importGate = gate
    #expect(tools.paste(String(repeating: "λ", count: 16_384), threadID: f.threadID, selection: .init(location: 0, length: 5), expectedText: latest.text))
    await gate.wait(); f.set(f.threadID, text: "Latest typing and selection text", attachments: latest.attachments)
    await gate.release(); await tools.flush()
    #expect(f.drafts[f.threadID]?.text == "Latest typing and selection text" && f.drafts[f.threadID]?.attachments.count == 2)
    #expect(f.captured.last?.1 == "pasted-text.txt" && tools.pending.isEmpty)
    await tools.shutdown()
}

@MainActor @Test(.timeLimit(.minutes(1)))
func composerLargePastePublishesExactSelectionAndUnknownAttachmentRecoveryChecksReceiptWithoutImportReplay() async throws {
    let f = try ComposerToolsFixture(); defer { f.cleanup() }
    let initial = "Keep selected suffix", pasted = String(repeating: "文", count: 11_000)
    f.set(f.threadID, text: initial)
    let tools = await f.tools(), range = NSRange(try #require(initial.range(of: "selected")), in: initial)
    #expect(tools.paste(pasted, threadID: f.threadID, selection: range, expectedText: initial)); await tools.flush()
    #expect(f.drafts[f.threadID]?.text == "Keep  suffix" && f.drafts[f.threadID]?.attachments.count == 1)
    #expect(f.captured.first?.0 == Data(pasted.utf8) && f.captured.first?.1 == "pasted-text.txt")
    let next = try #require(f.drafts[f.threadID]); f.loseReply = true
    #expect(tools.paste(pasted, threadID: f.threadID, selection: .init(location: 0, length: 0), expectedText: next.text))
    await tools.flush()
    #expect(f.captured.last?.1 == "pasted-text-2.txt" && tools.blocksSubmission(f.threadID))
    let command = try #require(f.commands.last?.0), positive = f.receipts.removeValue(forKey: command)
    await tools.shutdown()
    let restarted = await f.tools()
    #expect(f.commands.count == 2 && f.captured.count == 2 && restarted.importItems(f.threadID).count == 1)
    await restarted.checkResult(command)?.value
    #expect(restarted.pending.count == 1 && restarted.blocksSubmission(f.threadID) && f.commands.count == 2)
    f.receipts[command] = positive
    await restarted.checkResult(command)?.value
    #expect(restarted.pending.isEmpty && restarted.importItems(f.threadID).isEmpty && !restarted.blocksSubmission(f.threadID))
    #expect(f.commands.count == 2 && f.captured.count == 2 && f.drafts[f.threadID]?.attachments.count == 2)
    await restarted.shutdown()
}

@MainActor @Test(.timeLimit(.minutes(1)))
func composerShutdownAndProjectSuspensionJoinAcceptedDraftChangeWithoutCancellingOrReplayingIt() async throws {
    let f = try ComposerToolsFixture(); defer { f.cleanup() }
    let tools = await f.tools(), gate = ComposerToolsGate(); f.replaceGate = gate
    let stashing = try #require(tools.stash(threadID: f.threadID)); await gate.wait()
    let closing = Task { await tools.suspend(threadIDs: [f.threadID]) }
    await Task.yield(); #expect(tools.stash(threadID: f.threadID) == nil)
    await gate.release(); await closing.value; await stashing.value
    #expect(!f.replaceCancelled && f.commands.count == 1 && f.drafts[f.threadID]?.text == "")
    tools.resume(threadIDs: [f.threadID]); f.set(f.threadID, text: "Next draft")
    f.replaceGate = ComposerToolsGate(); let shutdownGate = try #require(f.replaceGate)
    let next = try #require(tools.stash(threadID: f.threadID)); await shutdownGate.wait()
    let shutdown = Task { await tools.shutdown() }; await Task.yield()
    await shutdownGate.release(); await next.value; await shutdown.value
    #expect(!f.replaceCancelled && f.commands.count == 2 && tools.pending.isEmpty)
}

@MainActor @Test(.timeLimit(.minutes(1)))
func composerStashCapacityEvictsOnlyAfterDurableWriteAndCorruptPrivateStorageNeverClearsCurrentDraft() async throws {
    let f = try ComposerToolsFixture(); defer { f.cleanup() }
    let tools = await f.tools()
    for index in 0..<21 { f.set(f.threadID, text: "Saved prompt \(index)"); await tools.stash(threadID: f.threadID)?.value }
    #expect(tools.entries.count == 20 && tools.entries.first?.draft.text == "Saved prompt 20" && tools.entries.last?.draft.text == "Saved prompt 1")
    await tools.shutdown()
    let manifest = f.root.appendingPathComponent("DraftTools/prompt-stash.json")
    let damaged = Data("deliberately invalid private manifest".utf8); try damaged.write(to: manifest)
    f.set(f.threadID, text: "Never clear this current draft")
    let broken = await f.tools(); #expect(!broken.isLoaded && broken.errorMessage != nil)
    await broken.stash(threadID: f.threadID)?.value
    #expect(f.drafts[f.threadID]?.text == "Never clear this current draft" && f.commands.count == 21)
    #expect(try Data(contentsOf: manifest) == damaged)
    await broken.shutdown()
}

@MainActor @Test(.timeLimit(.minutes(1)))
func composerRemovedThreadDisposesOnlyItsTransientFailuresAndGlobalStashCanRecoverTheOriginalReceiptFromASurvivingThread() async throws {
    let f = try ComposerToolsFixture(); defer { f.cleanup() }
    let tools = await f.tools(), removedFailureThread = UUID(), survivor = UUID()
    f.set(f.threadID, text: "Saved before project removal"); f.loseReply = true
    await tools.stash(threadID: f.threadID)?.value
    let commandID = try #require(tools.pending.first?.id), entryID = try #require(tools.entries.first?.id)
    f.set(removedFailureThread, text: "Removed thread's draft")
    f.drafts[survivor] = .init(threadID: survivor, projectID: UUID(), workspacePath: "/private/surviving-workspace", text: "Surviving draft", attachments: [])
    let file = f.root.appendingPathComponent("Captured retry.txt"); try Data("Exact private retry payload".utf8).write(to: file)
    f.importFailure = true; tools.importFiles([file], threadID: removedFailureThread); await tools.flush()
    f.importFailure = true; tools.importFiles([file], threadID: survivor); await tools.flush()
    #expect(!tools.isWorking(removedFailureThread) && tools.blocksSubmission(removedFailureThread))
    #expect(tools.importItems(removedFailureThread).count == 1 && tools.importItems(survivor).count == 1)
    await tools.forgetRemovedThreads([f.threadID, removedFailureThread])
    f.drafts.removeValue(forKey: f.threadID); f.drafts.removeValue(forKey: removedFailureThread)
    #expect(!tools.isWorking(removedFailureThread) && tools.importItems(removedFailureThread).isEmpty)
    #expect(tools.importItems(survivor).count == 1 && tools.blocksSubmission(survivor))
    #expect(tools.stashes(survivor).map(\.id) == [entryID] && tools.pending.map(\.id) == [commandID])
    let survivorFailure = try #require(tools.importItems(survivor).first?.id); tools.removeImport(survivorFailure)
    await tools.shutdown()
    let restarted = await f.tools()
    #expect(restarted.pending.map(\.id) == [commandID] && restarted.stashes(survivor).map(\.id) == [entryID] && f.commands.count == 1)
    await restarted.checkResult(commandID)?.value
    #expect(restarted.pending.isEmpty && restarted.entries.count == 1 && f.commands.count == 1)
    await restarted.restore(entryID, threadID: survivor)?.value
    #expect(f.drafts[survivor]?.text == "Surviving draft\n\nSaved before project removal" && restarted.entries.isEmpty)
    #expect(f.commands.count == 2 && f.drafts[f.threadID] == nil)
    await restarted.shutdown()
}
