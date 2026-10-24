import Darwin
import Foundation
import Testing
@testable import CoincideCore

/// Historical adapter/owned child/real loopback HTTP+SSE/SQLite, without a
/// vendor executable, account or model. Native copies persist across hosts.
@Test(.timeLimit(.minutes(1)))
func openCodeV1HistoryHTTPRepeatedAdoptionsResolveImmutableRunsAndPublishCandidateBeforeFurtherWire() async throws {
    let f = try await V1HistoryHTTPFixture.make(), engine = try f.engine()
    do {
        let seed = try await f.seed(engine)
        let source = try await f.thread(engine, seed.threadID)
        let originalID = try #require(source.providerThreadID)
        let original = try f.native(originalID)
        let first = try await engine.reviewConversationHistory(threadID: source.id, runID: seed.runs[2], kind: .rewindBeforeRun)
        let firstEvidence = try #require(first.openCodeV1)
        #expect(first.reviewedHeadTurnID == nil && first.expectedResultHeadTurnID == nil)
        #expect(first.boundary == .beforeMessage(seed.openings[2]))
        try f.options(["holdForkACK": .bool(true), "holdCandidateProof": .bool(true)])
        try await engine.beginConversationHistory(first)
        try await v1HistoryHTTPEventually("the native copy before its held acknowledgement") { f.exists("fork-created") }
        let dispatched = try await WorkspaceDatabase(url: f.database).load()
        #expect(dispatched.conversationHistoryOperation(first.id)?.phase == .dispatching)
        #expect(dispatched.conversationHistoryOperation(first.id)?.openCodeV1Candidate == nil)
        let firstForks = try f.rows("fork"), forkRow = try #require(firstForks.first)
        let adoptedID = try #require(forkRow["targetID"].string)
        #expect(try f.rows("candidate-proof").isEmpty)
        let beforeACK = try await f.thread(engine, source.id)
        #expect(beforeACK.providerThreadID == originalID && beforeACK.messages == source.messages)
        try f.options(["holdCandidateProof": .bool(true)])
        try await v1HistoryHTTPEventually("the first post-candidate native read") { f.exists("candidate-proof-entered") }
        let candidateSaved = try await WorkspaceDatabase(url: f.database).load()
        let candidate = try #require(candidateSaved.conversationHistoryOperation(first.id)?.openCodeV1Candidate)
        #expect(candidateSaved.conversationHistoryOperation(first.id)?.phase == .dispatching)
        #expect(candidate.reference.nativeThreadID == adoptedID && candidate.sourceInventoryDigest == firstEvidence.source.inventoryDigest)
        #expect(try f.rows("policy").filter { $0["sessionID"] == .string(adoptedID) }.isEmpty)
        let stillOriginal = try await f.thread(engine, source.id)
        #expect(stillOriginal.providerThreadID == originalID && stillOriginal.visibleMessages == source.visibleMessages)
        let project = try #require(candidateSaved.projects.first { $0.id == source.projectID })
        for nativeID in [originalID, adoptedID] {
            var proposed = CodingThread(project: project, model: source.model)
            proposed.provider = .opencode; proposed.workspacePath = source.workspacePath
            proposed.openCodeConfiguration = source.openCodeConfiguration; proposed.providerThreadID = nativeID
            proposed.checkpointPolicy = .disabled
            let alias = proposed, writes = try f.mutations()
            do { try await engine.dispatch(.createThread(alias)); Issue.record("A source/candidate native alias was registered during a history copy.") }
            catch let error as WorkspaceCommandError { #expect(error.message.localizedCaseInsensitiveContains("history")) }
            let state = await engine.current().snapshot
            #expect(!state.threads.contains { $0.id == alias.id })
            #expect(try f.mutations() == writes)
        }
        let draft = "Latest draft while native candidate proof is held 工作"
        try await engine.dispatch(.editThread(source.id, .draft(draft)))
        try f.options([:])
        try await v1HistoryHTTPEventually("atomic adoption of the proved copied prefix") { await f.operation(engine, first.id)?.phase == .applied }
        let adopted = try await f.thread(engine, source.id)
        #expect(adopted.providerThreadID == adoptedID && adoptedID != originalID)
        #expect(adopted.visibleMessages.map(\.text) == first.prefix.map(\.text))
        #expect(adopted.draft == draft && adopted.openCodeConfiguration == source.openCodeConfiguration && adopted.permission == source.permission)
        #expect(adopted.activeHistoryRuns.map(\.id) == Array(seed.runs.prefix(2)))
        #expect(adopted.runHistory?.first?.providerThreadID == originalID)
        #expect(adopted.runHistory?.first?.turnIDs == [seed.openings[0]])
        #expect(try f.native(originalID) == original)
        let firstOperation = try #require(await f.operation(engine, first.id))
        let firstResult = try #require(firstOperation.result?.openCodeV1)
        try firstEvidence.validateResult(firstResult, kind: .rewindBeforeRun)
        try f.assertCopy(source: original, resultID: adoptedID, count: firstEvidence.retainedMessageCount)
        let nativeAdopted = try f.native(adoptedID)
        let permission = try #require(nativeAdopted["info"]["permission"].array)
        #expect(permission.last { $0["permission"] == .string("*") && $0["pattern"] == .string("*") }?["action"] == .string("allow"))

        // A new input executes in B, while retained runs retain A's immutable
        // references. Later cuts must resolve the prior positional copy map.
        let fourth = try await f.send(engine, threadID: source.id, text: "New B input 工作")
        let afterNewRun = try await f.thread(engine, source.id)
        #expect(afterNewRun.providerThreadID == adoptedID && afterNewRun.activeHistoryRuns.map(\.id) == Array(seed.runs.prefix(2)) + [fourth.runID])
        #expect(afterNewRun.draft.isEmpty)
        let subsequentDraft = "New unsent draft after the B input 工作"
        try await engine.dispatch(.editThread(source.id, .draft(subsequentDraft)))
        let adoptedNative = try f.native(adoptedID)
        let fork = try await engine.reviewConversationHistory(threadID: source.id, runID: seed.runs[1], kind: .forkAfterRun)
        let forkEvidence = try #require(fork.openCodeV1)
        #expect(forkEvidence.inputs[0].originalReference.nativeThreadID == originalID)
        #expect(forkEvidence.inputs[0].originalMessageID == seed.openings[0])
        #expect(forkEvidence.inputs[0].openingMessageID != seed.openings[0])
        #expect(fork.boundary == .beforeMessage(fourth.inputID))
        let accepted = try await engine.beginConversationHistory(fork)
        let duplicate = try await engine.beginConversationHistory(fork)
        #expect(accepted == duplicate)
        try await v1HistoryHTTPEventually("a fork using the retained original-run map") { await f.operation(engine, fork.id)?.phase == .applied }
        let forkUpdate = await engine.current().snapshot
        let target = try #require(forkUpdate.threads.first { $0.id == fork.targetThreadID })
        let copiedID = try #require(target.providerThreadID)
        #expect(target.visibleMessages.map(\.text) == fork.prefix.map(\.text))
        #expect(target.openCodeConfiguration == fork.targetConfiguration.openCodeConfiguration)
        #expect(target.openCodeConfiguration?.agentID == "plan" && target.openCodeConfiguration?.model?.variant == "fast")
        #expect(target.activeRun == nil && target.queuedTurns.isEmpty && target.draft.isEmpty)
        try f.assertCopy(source: adoptedNative, resultID: copiedID, count: forkEvidence.retainedMessageCount)
        #expect(try f.native(adoptedID) == adoptedNative && f.native(originalID) == original)

        let second = try await engine.reviewConversationHistory(threadID: source.id, runID: seed.runs[1], kind: .rewindBeforeRun)
        let secondEvidence = try #require(second.openCodeV1)
        #expect(secondEvidence.selectedOpeningMessageID == forkEvidence.inputs[1].openingMessageID)
        try await engine.beginConversationHistory(second)
        try await v1HistoryHTTPEventually("a second immutable-reference rewind") { await f.operation(engine, second.id)?.phase == .applied }
        let twice = try await f.thread(engine, source.id), twiceID = try #require(twice.providerThreadID)
        #expect(twiceID != originalID && twiceID != adoptedID && twiceID != copiedID)
        #expect(twice.activeHistoryRuns.map(\.id) == [seed.runs[0]])
        #expect(twice.activeHistoryRuns.first?.providerThreadID == originalID && twice.activeHistoryRuns.first?.turnIDs == [seed.openings[0]])
        #expect(twice.draft == subsequentDraft && twice.openCodeConfiguration == source.openCodeConfiguration)
        #expect(try f.native(originalID) == original && f.native(adoptedID) == adoptedNative)
        let chained = try await engine.reviewConversationHistory(threadID: source.id, runID: seed.runs[0], kind: .forkAfterRun)
        let chain = try #require(chained.openCodeV1)
        #expect(chain.boundary == .head && chain.inputs[0].originalReference.nativeThreadID == originalID)
        #expect(chain.inputs[0].openingMessageID != seed.openings[0] && chain.inputs[0].openingMessageID != forkEvidence.inputs[0].openingMessageID)
        await engine.discardConversationHistoryReview(reviewID: chained.id)
        #expect(try f.rows("fork").count == 3 && f.rows("prompt").count == 4)
        let pages = try f.rows("history-page")
        #expect(pages.contains { $0["before"] == .bool(true) } && pages.contains { $0["hasOlder"] == .bool(true) })
        try await f.assertFilesUnchanged()
        await engine.shutdown(); try await f.assertDrained()
        let saved = await engine.current().snapshot, rebuilt = try await WorkspaceDatabase(url: f.database).rebuildProjection().snapshot
        #expect(saved == rebuilt)
        let reopened = try f.engine(); _ = try await reopened.load()
        let restored = try await f.thread(reopened, source.id)
        #expect(restored.providerThreadID == twiceID && restored.messages == twice.messages && restored.runHistory == twice.runHistory && restored.draft == subsequentDraft)
        await reopened.shutdown(); try await f.assertDrained()
        #expect(try f.rows("fork").count == 3 && f.rows("prompt").count == 4)
        try f.remove()
    } catch { try? f.options([:]); await engine.shutdown(); try? f.diagnostic(await engine.current()); try? f.remove(); throw error }
}

@Test(arguments: [false, true])
func openCodeV1HistoryHTTPLostReplyRestartsWithoutReplayAndOnlyKnownProvedCandidateCanBeAdopted(knownCandidate: Bool) async throws {
    let f = try await V1HistoryHTTPFixture.make(), engine = try f.engine()
    var reopened: WorkspaceEngine?
    do {
        let seed = try await f.seed(engine), original = try await f.thread(engine, seed.threadID)
        let originalID = try #require(original.providerThreadID), nativeOriginal = try f.native(originalID)
        let review = try await engine.reviewConversationHistory(threadID: original.id, runID: seed.runs[2], kind: .rewindBeforeRun)
        try f.options([knownCandidate ? "dropCandidateProofAfterPolicy" : "dropForkACK": .bool(true)])
        try await engine.beginConversationHistory(review)
        try await v1HistoryHTTPEventually("the uncertain native copy") { await f.operation(engine, review.id)?.phase == .unconfirmed }
        let operation = try #require(await f.operation(engine, review.id))
        #expect((operation.openCodeV1Candidate != nil) == knownCandidate)
        let held = try await f.thread(engine, original.id)
        #expect(held.providerThreadID == originalID && held.messages == original.messages && held.runHistory == original.runHistory && held.draft == original.draft)
        await #expect(throws: WorkspaceCommandError.self) { try await engine.dispatch(.submit(threadID: original.id, text: "Must stay held")) }
        #expect(try f.rows("fork").count == 1)
        await engine.shutdown(); try await f.assertDrained()
        let writes = try f.mutations()
        let next = try f.engine(); reopened = next; _ = try await next.load()
        #expect(await f.operation(next, review.id)?.phase == .unconfirmed)
        #expect(try f.mutations() == writes)
        try f.options([:])
        if knownCandidate {
            try await next.reconcileConversationHistory(operationID: review.id)
            #expect(await f.operation(next, review.id)?.phase == .applied)
            let adopted = try await f.thread(next, original.id)
            #expect(adopted.providerThreadID == operation.openCodeV1Candidate?.reference.nativeThreadID)
            #expect(adopted.visibleMessages.map(\.text) == review.prefix.map(\.text))
            #expect(adopted.runHistory?.count == 3 && adopted.activeHistoryRuns.map(\.id) == Array(seed.runs.prefix(2)))
        } else {
            // There is a real orphan in native storage, but no response-owned
            // candidate. Neither title/ID enumeration nor a retry may adopt it.
            do { try await next.reconcileConversationHistory(operationID: review.id); Issue.record("A lost fork acknowledgement was guessed into an adopted conversation.") }
            catch is ProviderHistoryError { }
            #expect(await f.operation(next, review.id)?.phase == .unconfirmed)
            let observed = try await next.inspectOpenCodeV1Original(operationID: review.id)
            try await next.keepOpenCodeV1Original(operationID: review.id, expected: observed)
            let kept = try #require(await f.operation(next, review.id))
            #expect(kept.phase == .failed && kept.openCodeV1Candidate == nil)
            #expect(kept.error?.localizedCaseInsensitiveContains("separate") == true)
            let unchanged = try await f.thread(next, original.id)
            #expect(unchanged.providerThreadID == originalID && unchanged.messages == original.messages && unchanged.runHistory == original.runHistory)
            #expect(try f.nativeSessionCount() == 2, "The unidentified native copy is preserved, never deleted or adopted.")
        }
        let final = try await f.thread(next, original.id)
        #expect(final.draft == original.draft && final.openCodeConfiguration == original.openCodeConfiguration && final.permission == original.permission)
        #expect(try f.mutations() == writes)
        #expect(try f.native(originalID) == nativeOriginal)
        try await f.assertFilesUnchanged()
        await next.shutdown(); try await f.assertDrained()
        let saved = await next.current().snapshot, replayed = try await WorkspaceDatabase(url: f.database).rebuildProjection().snapshot
        #expect(saved == replayed)
        try f.remove()
    } catch { try? f.options([:]); await reopened?.shutdown(); await engine.shutdown(); try? f.diagnostic(await (reopened ?? engine).current()); try? f.remove(); throw error }
}

@Test(arguments: ["same-count", "reused-part"])
func openCodeV1HistoryHTTPRejectsWrongCopiesWithoutAdoptingOrReplayingThem(badCopy: String) async throws {
    let f = try await V1HistoryHTTPFixture.make(), engine = try f.engine()
    do {
        let seed = try await f.seed(engine), source = try await f.thread(engine, seed.threadID)
        let review = try await engine.reviewConversationHistory(threadID: source.id, runID: seed.runs[2], kind: .rewindBeforeRun)
        try f.options(["badCopy": .string(badCopy)])
        try await engine.beginConversationHistory(review)
        try await v1HistoryHTTPEventually("the rejected copied proof") { await f.operation(engine, review.id)?.phase == .unconfirmed }
        let operation = try #require(await f.operation(engine, review.id))
        #expect(operation.openCodeV1Candidate != nil)
        let writes = try f.mutations()
        do { try await engine.reconcileConversationHistory(operationID: review.id); Issue.record("An invalid same-count or reused-identity copy was adopted.") }
        catch is ProviderHistoryError { }
        #expect(await f.operation(engine, review.id)?.phase == .unconfirmed)
        let observed = try await engine.inspectOpenCodeV1Original(operationID: review.id)
        try await engine.keepOpenCodeV1Original(operationID: review.id, expected: observed)
        let kept = try #require(await f.operation(engine, review.id))
        #expect(kept.phase == .failed && kept.openCodeV1Candidate == operation.openCodeV1Candidate)
        let current = try await f.thread(engine, source.id)
        #expect(current.providerThreadID == source.providerThreadID && current.messages == source.messages && current.runHistory == source.runHistory && current.draft == source.draft)
        #expect(try f.mutations() == writes && f.rows("fork").count == 1)
        try await f.assertFilesUnchanged(); await engine.shutdown(); try await f.assertDrained(); try f.remove()
    } catch { await engine.shutdown(); try? f.diagnostic(await engine.current()); try? f.remove(); throw error }
}

@Test
func openCodeV1HistoryHTTPSameCountAndUserHeadWithChangedAssistantTailInvalidatesReviewBeforeFork() async throws {
    let f = try await V1HistoryHTTPFixture.make(), engine = try f.engine()
    do {
        let seed = try await f.seed(engine), source = try await f.thread(engine, seed.threadID)
        let review = try await engine.reviewConversationHistory(threadID: source.id, runID: seed.runs[1], kind: .rewindBeforeRun)
        try f.options(["staleTail": .bool(true)])
        try await engine.beginConversationHistory(review)
        try await v1HistoryHTTPEventually("the changed full native inventory") { await f.operation(engine, review.id)?.phase == .failed }
        #expect(try f.rows("fork").isEmpty)
        let current = try await f.thread(engine, source.id)
        #expect(current.messages == source.messages && current.runHistory == source.runHistory && current.providerThreadID == source.providerThreadID && current.draft == source.draft)
        #expect(try f.rows("prompt").count == 3)
        try await f.assertFilesUnchanged(); await engine.shutdown(); try await f.assertDrained(); try f.remove()
    } catch { await engine.shutdown(); try? f.diagnostic(await engine.current()); try? f.remove(); throw error }
}

private struct V1HistoryHTTPFixture: Sendable {
    struct Input: Sendable { let runID: UUID; let inputID: String }
    struct Seed: Sendable { let threadID: UUID; let runs: [UUID]; let openings: [String] }
    let git: CheckpointFixture, workspace: URL, executable: URL, database: URL
    let before: CheckpointUserState, mainBefore: CheckpointUserState
    var root: URL { git.root }
    static func make() async throws -> Self {
        let git = try await CheckpointFixture.make()
        do {
            try git.write(".gitignore", "ignored.txt\n"); try await git.commitAll()
            let workspace = git.root.appendingPathComponent("history checkout's 工作 & space")
            _ = try await git.run(["worktree", "add", "-b", "history-native-one", workspace.path])
            let mainBefore = try await git.state()
            try Data("Staged history sentinel\n".utf8).write(to: workspace.appendingPathComponent("tracked.txt"))
            _ = try await git.run(["add", "--", "tracked.txt"], at: workspace)
            for (path, text) in [("tracked.txt", "Working history sentinel\n"), ("untracked.txt", "Untracked 工作\n"), ("ignored.txt", "Ignored history sentinel\n")] {
                try Data(text.utf8).write(to: workspace.appendingPathComponent(path))
            }
            let before = try await git.state(at: workspace), executable = git.root.appendingPathComponent("native-one-history-peer")
            let source = try #require(Bundle.module.url(forResource: "opencode_v1_history_http", withExtension: "py", subdirectory: "Fixtures"))
            try FileManager.default.copyItem(at: source, to: executable)
            try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: executable.path)
            let sidecar = JSONValue.object(["directory": .string(workspace.standardizedFileURL.resolvingSymlinksInPath().path)])
            try JSONEncoder().encode(sidecar).write(to: git.root.appendingPathComponent("fixture-directory.json"), options: .atomic)
            return .init(git: git, workspace: workspace, executable: executable, database: git.root.appendingPathComponent("v1-history.sqlite"), before: before, mainBefore: mainBefore)
        } catch { git.cleanup(); throw error }
    }
    func engine() throws -> WorkspaceEngine { try .init(url: database, providerFactory: { try makeLegacyNativeAdapterFixtureSession($0) }, identityResolver: { _ in nil }) }
    func thread(_ engine: WorkspaceEngine, _ id: UUID) async throws -> CodingThread {
        let current = await engine.current().snapshot
        return try #require(current.threads.first { $0.id == id })
    }
    func operation(_ engine: WorkspaceEngine, _ id: UUID) async -> ConversationHistoryOperation? { await engine.current().snapshot.conversationHistoryOperation(id) }
    func seed(_ engine: WorkspaceEngine) async throws -> Seed {
        let project = WorkspaceProject(path: workspace.path)
        let selection = OpenCodeModelSelection(providerID: "synthetic", id: "history-model/with-slash", variant: "balanced")
        let menu = ProviderModel(id: selection.catalogID, name: "Private history model", openCodeSelection: .init(providerID: selection.providerID, id: selection.id), openCodeVariants: ["balanced", "fast"])
        var initial = CodingThread(project: project, model: selection.catalogID)
        initial.provider = .opencode; initial.checkpointPolicy = .disabled
        initial.openCodeConfiguration = .init(generation: .v1, executable: executable.path, model: selection, agentID: "build")
        let id = initial.id
        try await saveLegacyProviderFixture(project: project, threads: [initial], at: database)
        _ = try await engine.load()
        var inputs: [Input] = []
        for number in 1...3 {
            try await engine.dispatch(.editThread(id, .openCodeVariant(model: menu, variant: number == 2 ? "fast" : "balanced")))
            try await engine.dispatch(.editThread(id, .openCodeAgent(number == 2 ? "plan" : "build")))
            inputs.append(try await send(engine, threadID: id, text: "A opening \(number) 工作 🌍"))
        }
        try await engine.dispatch(.editThread(id, .draft("Latest unsent native-one draft 工作")))
        try await engine.dispatch(.editThread(id, .permission(.fullAccess)))
        let source = try await thread(engine, id)
        #expect(source.activeHistoryRuns.map(\.id) == inputs.map(\.runID))
        #expect(source.activeHistoryRuns.map(\.turnIDs) == inputs.map { [$0.inputID] })
        return .init(threadID: id, runs: inputs.map(\.runID), openings: inputs.map(\.inputID))
    }
    func send(_ engine: WorkspaceEngine, threadID: UUID, text: String) async throws -> Input {
        try await engine.dispatch(.submit(threadID: threadID, text: text))
        try await v1HistoryHTTPEventually("the exact native user and assistant snapshots") {
            guard let source = try? await thread(engine, threadID), let run = source.activeRun,
                  let input = run.nativeTurnID, source.messages.contains(where: { $0.text == "Reply to " + text }) else { return false }
            return (try? rows("input-observed").contains { $0["inputID"] == .string(input) }) == true
        }
        let source = try await thread(engine, threadID), run = try #require(source.activeRun), input = try #require(run.nativeTurnID)
        try Data().write(to: root.appendingPathComponent("finish-" + input), options: .atomic)
        try await v1HistoryHTTPEventually("the completed local run after native idle") {
            guard let current = try? await thread(engine, threadID) else { return false }
            return current.activeRun == nil && current.runHistory?.last?.id == run.id && current.runHistory?.last?.status == .completed && current.heldPostRunCheckpoint == nil
        }
        return .init(runID: run.id, inputID: input)
    }
    func exists(_ name: String) -> Bool { FileManager.default.fileExists(atPath: root.appendingPathComponent(name).path) }
    func options(_ value: [String: JSONValue]) throws { try JSONEncoder().encode(JSONValue.object(value)).write(to: root.appendingPathComponent("options.json"), options: .atomic) }
    func rows(_ kind: String) throws -> [JSONValue] {
        let path = root.appendingPathComponent("wire.jsonl")
        guard FileManager.default.fileExists(atPath: path.path) else { return [] }
        let data = try Data(contentsOf: path)
        guard let end = data.lastIndex(of: 10) else { return [] }
        return try data[...end].split(separator: 10).map { try JSONDecoder().decode(JSONValue.self, from: Data($0)) }.filter { $0["kind"] == .string(kind) }
    }
    func state() throws -> JSONValue { try JSONDecoder().decode(JSONValue.self, from: Data(contentsOf: root.appendingPathComponent("native.json"))) }
    func native(_ id: String) throws -> JSONValue { try state()["sessions"][id] }
    func nativeSessionCount() throws -> Int { try state()["sessions"].object?.count ?? 0 }
    func mutations() throws -> [JSONValue] { try ["create", "prompt", "fork", "policy", "abort", "unsupported-mutation"].flatMap { try rows($0) } }
    func assertCopy(source: JSONValue, resultID: String, count: Int) throws {
        let original = try #require(source["messages"].array)
        let result = try native(resultID)
        let copied = try #require(result["messages"].array)
        #expect(copied.count == count)
        let oldMessages = Set(original.compactMap { $0["info"]["id"].string })
        let oldParts = Set(original.flatMap { $0["parts"].array ?? [] }.compactMap { $0["id"].string })
        let newMessages = copied.compactMap { $0["info"]["id"].string }
        let newParts = copied.flatMap { $0["parts"].array ?? [] }.compactMap { $0["id"].string }
        #expect(Set(newMessages).count == copied.count && Set(newMessages).isDisjoint(with: oldMessages))
        #expect(Set(newParts).count == newParts.count && Set(newParts).isDisjoint(with: oldParts))
        var users: Set<String> = []
        for (index, entry) in copied.enumerated() {
            let id = try #require(entry["info"]["id"].string)
            #expect(entry["info"]["sessionID"] == .string(resultID))
            if entry["info"]["role"] == .string("user") { users.insert(id) }
            else { #expect(users.contains(entry["info"]["parentID"].string ?? "")) }
            let parts = try #require(entry["parts"].array), old = try #require(original[index]["parts"].array)
            #expect(parts.count == old.count)
            for (part, previous) in zip(parts, old) {
                #expect(part["messageID"] == .string(id) && part["sessionID"] == .string(resultID))
                if part["type"] == .string("compaction") { #expect(part["tail_start_id"] == previous["tail_start_id"]) }
                if part["type"] == .string("tool") { #expect(part["callID"] == previous["callID"] && part["state"] == previous["state"]) }
            }
        }
    }
    func assertFilesUnchanged() async throws { #expect(try await git.state(at: workspace) == before); #expect(try await git.state() == mainBefore) }
    var stopped: Bool {
        guard let started = try? rows("process") else { return false }
        return started.allSatisfy { row in
            guard case .number(let pid) = row["pid"], pid > 0, pid < Double(Int32.max) else { return false }
            return kill(Int32(pid), 0) == -1 && errno == ESRCH
        }
    }
    func assertDrained() async throws {
        try await v1HistoryHTTPEventually("all exact owned native-one process exits") { stopped }
        let started = try rows("process"), closed = try rows("closed")
        #expect(!started.isEmpty && started.count == closed.count)
        func pids(_ values: [JSONValue]) -> Set<Int32> {
            Set(values.compactMap { if case .number(let pid) = $0["pid"] { return Int32(pid) }; return nil })
        }
        #expect(pids(started) == pids(closed))
        #expect(started.allSatisfy { $0["exactArguments"] == .bool(true) && $0["freshCredential"] == .bool(true) && $0["noInheritedService"] == .bool(true) })
        #expect(closed.allSatisfy { $0["streamClosed"] == .bool(true) && $0["httpStopped"] == .bool(true) })
        let requests = try rows("request")
        #expect(requests.allSatisfy { $0["authenticated"] == .bool(true) && $0["directoryMatched"] == .bool(true) })
        #expect(requests.allSatisfy { $0["method"] != .string("DELETE") && $0["path"].string?.hasPrefix("/api/") != true && $0["path"].string?.hasSuffix("/revert") != true && $0["path"].string?.hasSuffix("/unrevert") != true })
        #expect(try rows("unsupported-mutation").isEmpty && rows("fixture-handler-failed").isEmpty)
        let wire = try String(contentsOf: root.appendingPathComponent("wire.jsonl"), encoding: .utf8).lowercased()
        #expect(!wire.contains("authorization") && !wire.contains("password") && !wire.contains("http://"))
    }
    func remove() throws { guard stopped else { throw CoincideError("A private native-one history process remains alive; scratch was preserved.") }; git.cleanup() }
    func diagnostic(_ update: WorkspaceUpdate) throws {
        let path = FileManager.default.temporaryDirectory.appendingPathComponent("coincide-v1-history-diagnostic-\(UUID()).json")
        let value: JSONValue = .object(["error": update.error.map(JSONValue.string) ?? .null,
            "threads": .array(update.snapshot.threads.prefix(3).map { thread in
                .object(["state": .string(thread.state.rawValue), "provider": .string(thread.provider.rawValue),
                    "generation": thread.openCodeConfiguration.map { .string($0.generation.rawValue) } ?? .null,
                    "selectedExecutableMatches": .bool(thread.openCodeConfiguration?.executable == executable.path),
                    "activeRun": .bool(thread.activeRun != nil), "runtime": .bool(thread.runtimeID != nil),
                    "nativeSession": .bool(thread.providerThreadID != nil), "queuePaused": .bool(thread.queuePaused),
                    "queued": .number(Double(thread.queuedTurns.count)),
                    "messages": .array(thread.messages.suffix(8).map { message in
                        .object(["role": .string(message.role.rawValue), "text": .string(String(message.text.prefix(2_048)))])
                    })])
            }), "processes": .array(try rows("process")), "closed": .array(try rows("closed")),
            "history": .array((update.snapshot.conversationHistoryOperations ?? []).map { .object(["phase": .string($0.phase.rawValue), "candidate": .bool($0.openCodeV1Candidate != nil)]) }),
            "requests": .array(Array(try rows("request").suffix(100))), "forks": .array(try rows("fork")), "prompts": .array(try rows("prompt"))])
        try JSONEncoder().encode(value).write(to: path, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: path.path)
        print("Synthetic native-one history diagnostic: \(path.path)")
    }
}

private func v1HistoryHTTPEventually(_ boundary: String, _ condition: @escaping @Sendable () async -> Bool) async throws {
    let deadline = ContinuousClock.now + .seconds(8)
    while !(await condition()) {
        guard ContinuousClock.now < deadline else { throw CoincideError("The private OpenCode 1 history fixture did not reach \(boundary).") }
        try await Task.sleep(for: .milliseconds(10))
    }
}
