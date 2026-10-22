import Darwin
import Foundation
import Testing
@testable import CoincideCore

/// Real owned executable → loopback HTTP/SSE → production factory → SQLite.
/// The peer has no vendor dependency, model, account or access to user files.
@Test(.timeLimit(.minutes(1)))
func openCodeV2HistoryHTTPForkAndRewindUseWholeSteeredRunsAndPreserveGitDraftAndCapturedSettings() async throws {
    let f = try await OpenCodeHistoryHTTPFixture.make()
    let engine = try f.engine()
    do {
        let seeded = try await f.seed(engine)
        let source = try await f.thread(engine, seeded.threadID)
        let nativeID = try #require(source.providerThreadID)
        let nativeBefore = try f.nativeSession(nativeID)
        let fork = try await engine.reviewConversationHistory(threadID: source.id, runID: seeded.runs[1], kind: .forkAfterRun)
        let evidence = try #require(fork.openCodeV2)
        #expect(fork.reviewedHeadTurnID == nil && fork.expectedResultHeadTurnID == nil)
        #expect(fork.boundary == .beforeMessage(seeded.openings[2]))
        #expect(evidence.inputs.map(\.runID) == seeded.runs)
        #expect(evidence.inputs[1].steeringMessageIDs.count == 2)
        #expect(evidence.source.messages.contains { $0.kind == .compaction })
        #expect(evidence.source.messages.contains { $0.kind == .synthetic })
        #expect(fork.targetConfiguration.openCodeConfiguration?.agentID == "plan")
        #expect(fork.targetConfiguration.openCodeConfiguration?.model?.variant == "fast")
        #expect(source.openCodeConfiguration?.agentID == "build")
        let acceptance = try await engine.beginConversationHistory(fork)
        let repeated = try await engine.beginConversationHistory(fork)
        #expect(acceptance == repeated)
        try await historyHTTPEventually("the copied native prefix") { await f.operation(engine, fork.id)?.phase == .applied }
        let forkedUpdate = await engine.current()
        let operation = try #require(forkedUpdate.snapshot.conversationHistoryOperation(fork.id))
        let target = try #require(forkedUpdate.snapshot.threads.first { $0.id == fork.targetThreadID })
        let copied = try #require(operation.result?.openCodeV2)
        #expect(operation.result?.historyMode == .messageOrdered && operation.result?.headTurnID == nil)
        try evidence.validateResult(copied, kind: .forkAfterRun)
        #expect(copied.reference.nativeThreadID != nativeID)
        #expect(Set(copied.messages.map(\.id)).isDisjoint(with: Set(evidence.source.messages.map(\.id))))
        #expect(target.visibleMessages.map(\.text) == fork.prefix.map(\.text))
        #expect(target.visibleMessages.filter { $0.role == .user }.map(\.text) == ["History opening 1 工作 🌍", "History opening 2 工作 🌍", "Steer first", "Steer second"])
        #expect(target.openCodeConfiguration == fork.targetConfiguration.openCodeConfiguration)
        #expect(target.activeRun == nil && target.queuedTurns.isEmpty && target.draft.isEmpty)
        #expect(try f.nativeSession(nativeID) == nativeBefore)
        let afterFork = try await f.thread(engine, source.id)
        #expect(afterFork.messages == source.messages && afterFork.runHistory == source.runHistory)
        #expect(afterFork.draft == source.draft && afterFork.openCodeConfiguration == source.openCodeConfiguration)
        let targetNative = try f.nativeSession(copied.reference.nativeThreadID)
        let targetMessages = try #require(targetNative["messages"].array)
        let targetCompactions = targetMessages.filter { $0["type"] == .string("compaction") }
        #expect(targetCompactions.count == 2)
        #expect(targetCompactions.allSatisfy { $0["metadata"]["keepID"] == targetMessages.first?["id"] })
        #expect(targetNative["info"]["location"] == nativeBefore["info"]["location"])

        let rewind = try await engine.reviewConversationHistory(threadID: source.id, runID: seeded.runs[1], kind: .rewindBeforeRun)
        let cut = try #require(rewind.openCodeV2)
        try f.options(["holdStageACK": .bool(true)])
        try await engine.beginConversationHistory(rewind)
        try await historyHTTPEventually("stage side effect before its held reply") { f.marker("stage-applied") }
        // The real first mutation has happened, but its HTTP reply is held. The
        // durable dispatch must already exist; neither commit nor local trim may.
        let saved = try await WorkspaceDatabase(url: f.database).load()
        #expect(saved.conversationHistoryOperation(rewind.id)?.phase == .dispatching)
        #expect(try f.rows("commit").isEmpty)
        let held = try await f.thread(engine, source.id)
        #expect(held.visibleMessages == source.visibleMessages && held.draft == source.draft)
        let stages = try f.rows("stage")
        let stage = try #require(stages.first)
        #expect(stage["files"] == .bool(false) && stage["cut"] == .string(seeded.openings[1]))
        let aliasProject = try #require(saved.projects.first { $0.id == source.projectID })
        var candidate = CodingThread(project: aliasProject, model: source.model)
        candidate.provider = .opencode; candidate.workspacePath = source.workspacePath
        candidate.openCodeConfiguration = source.openCodeConfiguration
        candidate.providerThreadID = nativeID; candidate.permission = source.permission
        candidate.checkpointPolicy = .disabled
        let alias = candidate
        // This is a fresh, empty conversation in the existing project, with the
        // exact captured native identity. It must fail the history scope guard,
        // rather than an unrelated new-thread validation rule.
        #expect(alias.messages.isEmpty && alias.queuedTurns.isEmpty && alias.activeRun == nil)
        #expect(alias.providerThreadID == source.providerThreadID && alias.openCodeConfiguration == source.openCodeConfiguration)
        let beforeAlias = try f.mutations()
        do {
            try await engine.dispatch(.createThread(alias))
            Issue.record("An alias of a native session with a dispatching history action was registered.")
            // If registration regresses, still exercise submission so this
            // test cannot silently send a second input to the staged session.
            do {
                try await engine.dispatch(.submit(threadID: alias.id, text: "Must not reach the staged native session"))
                Issue.record("A native-session alias submitted during a held history mutation.")
            } catch let error as WorkspaceCommandError { #expect(error.message.localizedCaseInsensitiveContains("history")) }
        } catch let error as WorkspaceCommandError { #expect(error.message.localizedCaseInsensitiveContains("history")) }
        let afterAlias = await engine.current().snapshot
        #expect(!afterAlias.threads.contains { $0.id == alias.id })
        #expect(try f.mutations() == beforeAlias)
        let editedDraft = "Edited while native stage reply is held 工作"
        try await engine.dispatch(.editThread(source.id, .draft(editedDraft)))
        let editable = try await f.thread(engine, source.id)
        #expect(editable.draft == editedDraft && editable.visibleMessages == source.visibleMessages)
        #expect(try f.mutations() == beforeAlias)
        try f.options([:])
        try await historyHTTPEventually("the committed native and local prefix") { await f.operation(engine, rewind.id)?.phase == .applied }
        let rewound = try await f.thread(engine, source.id)
        let result = try #require(await f.operation(engine, rewind.id)?.result)
        #expect(result.historyMode == .messageOrdered && result.headTurnID == nil)
        try cut.validateResult(try #require(result.openCodeV2), kind: .rewindBeforeRun)
        #expect(rewound.visibleMessages.map(\.text) == rewind.prefix.map(\.text))
        #expect(rewound.runHistory?.count == 3)
        #expect(rewound.runHistory?.filter { $0.removedByHistoryOperationID == rewind.id }.map(\.id) == Array(seeded.runs.suffix(2)))
        #expect(rewound.draft == editedDraft && rewound.model == source.model)
        #expect(rewound.permission == source.permission && rewound.openCodeConfiguration == source.openCodeConfiguration)
        #expect(try f.rows("stage").count == 1 && f.rows("commit").count == 1)
        #expect(try f.rows("clear").isEmpty)
        #expect(try f.rows("prompt").count == 5 && f.rows("fork").count == 1)
        let pages = try f.rows("history-page")
        #expect(pages.contains { $0["count"] == .number(0) })
        #expect(pages.contains { $0["cursorPresent"] == .bool(true) })
        #expect(pages.allSatisfy { !($0["cursorPresent"] == .bool(true) && $0["orderPresent"] == .bool(true)) })
        try await f.assertFilesUnchanged()
        await engine.shutdown()
        try await f.assertDrained()
        let durable = await engine.current().snapshot
        let rebuilt = try await WorkspaceDatabase(url: f.database).rebuildProjection().snapshot
        #expect(rebuilt == durable)
        let reopened = try f.engine()
        _ = try await reopened.load()
        let reopenedSource = try await f.thread(reopened, source.id)
        #expect(reopenedSource.messages == rewound.messages && reopenedSource.runHistory == rewound.runHistory)
        #expect(reopenedSource.draft == editedDraft)
        await reopened.shutdown()
        #expect(try f.rows("prompt").count == 5 && f.rows("stage").count == 1 && f.rows("commit").count == 1)
        try await f.assertDrained(); try f.remove()
    } catch { try? f.options([:]); await engine.shutdown(); try? f.saveDiagnostic(await engine.current()); try? f.remove(); throw error }
}

private enum HistoryHTTPLostReply: String, CaseIterable, Sendable {
    case beforeStage, afterStage, afterCommit
}

@Test(arguments: HistoryHTTPLostReply.allCases)
private func openCodeV2HistoryHTTPLostRepliesReopenAndInspectWithoutReplayingNativeMutation(loss: HistoryHTTPLostReply) async throws {
    let f = try await OpenCodeHistoryHTTPFixture.make()
    let engine = try f.engine()
    var reopened: WorkspaceEngine?
    do {
        let seeded = try await f.seed(engine), source = try await f.thread(engine, seeded.threadID)
        let review = try await engine.reviewConversationHistory(threadID: source.id, runID: seeded.runs[1], kind: .rewindBeforeRun)
        let evidence = try #require(review.openCodeV2)
        let key = loss == .beforeStage ? "dropStageBefore" : loss == .afterStage ? "dropStageACK" : "dropCommitACK"
        try f.options([key: .bool(true)])
        try await engine.beginConversationHistory(review)
        try await historyHTTPEventually("the uncertain original mutation") { await f.operation(engine, review.id)?.phase == .unconfirmed }
        let unknown = try await f.thread(engine, source.id)
        #expect(unknown.visibleMessages == source.visibleMessages && unknown.draft == source.draft)
        await #expect(throws: WorkspaceCommandError.self) { try await engine.dispatch(.submit(threadID: source.id, text: "Must stay held")) }
        #expect(try f.rows("stage").count == 1)
        #expect(try f.rows("commit").count == (loss == .afterCommit ? 1 : 0))
        #expect(try f.rows("clear").isEmpty)
        await engine.shutdown(); try await f.assertDrained()
        let writes = try f.mutations()
        let next = try f.engine(); reopened = next
        _ = try await next.load()
        #expect(await f.operation(next, review.id)?.phase == .unconfirmed)
        #expect(try f.mutations() == writes)
        try f.options([:])
        if loss == .afterStage {
            let inspected = try await next.inspectConversationHistoryMaintenance(operationID: review.id)
            #expect(try f.mutations() == writes, "Inspect and restart must perform no external mutation.")
            #expect(inspected.reference == review.sourceReference)
            #expect(inspected.messages == evidence.source.messages)
            #expect(inspected.stage?.messageID == seeded.openings[1] && inspected.stage?.isHistoryOnly == true)
            try f.options(["clearACKFirst": .bool(true), "holdClearTerminal": .bool(true)])
            try await next.clearConversationHistoryMaintenance(operationID: review.id, expected: inspected)
            try await historyHTTPEventually("the empty maintenance execution start") { f.marker("clear-started") }
            let beforeTerminal = await next.current().snapshot
            let maintenance = try #require(beforeTerminal.conversationHistoryOperation(review.id)?.maintenance)
            #expect(maintenance.phase == .dispatching && maintenance.result == nil)
            #expect(beforeTerminal.conversationHistoryOperation(review.id)?.phase == .unconfirmed)
            let held = try #require(beforeTerminal.threads.first { $0.id == source.id })
            #expect(held.activeRun == nil && held.runHistory == source.runHistory)
            #expect(held.visibleMessages == source.visibleMessages && held.draft == source.draft)
            await #expect(throws: WorkspaceCommandError.self) { try await next.dispatch(.submit(threadID: source.id, text: "No fake maintenance completion")) }
            try f.options([:])
            try await historyHTTPEventually("the owned native maintenance receipt") { await f.operation(next, review.id)?.maintenance?.phase == .applied }
            let clearResult = try #require(await f.operation(next, review.id)?.maintenance?.result)
            let receipt = try #require(clearResult.maintenance)
            #expect(clearResult.stage == nil && clearResult.messages.count == inspected.messages.count + 1)
            #expect(Array(clearResult.messages.dropLast()) == inspected.messages)
            #expect(clearResult.messages.last?.id == receipt.idleMessageID && clearResult.messages.last?.kind == .idle)
            #expect(receipt.priorInventoryDigest == inspected.inventoryDigest)
            #expect(try f.rows("clear").count == 1 && f.rows("clear-execution-started").count == 1)
            let afterClearWrites = try f.mutations()
            try await next.reconcileConversationHistory(operationID: review.id)
            #expect(try f.mutations() == afterClearWrites)
            #expect(await f.operation(next, review.id)?.phase == .failed)
            #expect(await f.operation(next, review.id)?.maintenance?.result?.maintenance == receipt)
            let restored = try await f.thread(next, source.id)
            #expect(restored.visibleMessages == source.visibleMessages && restored.runHistory == source.runHistory)
        } else {
            try await next.reconcileConversationHistory(operationID: review.id)
            #expect(await f.operation(next, review.id)?.phase == (loss == .afterCommit ? .applied : .failed))
            let current = try await f.thread(next, source.id)
            #expect(current.visibleMessages == (loss == .afterCommit ? review.prefix : source.visibleMessages))
            #expect(try f.mutations() == writes)
        }
        let final = try await f.thread(next, source.id)
        #expect(final.draft == source.draft && final.openCodeConfiguration == source.openCodeConfiguration)
        #expect(final.runHistory?.count == 3)
        #expect(try f.rows("prompt").count == 5 && f.rows("stage").count == 1)
        try await f.assertFilesUnchanged()
        await next.shutdown(); try await f.assertDrained()
        let saved = await next.current().snapshot
        let replayed = try await WorkspaceDatabase(url: f.database).rebuildProjection().snapshot
        #expect(saved == replayed)
        try f.remove()
    } catch {
        try? f.options([:]); await reopened?.shutdown(); await engine.shutdown()
        try? f.saveDiagnostic(await (reopened ?? engine).current()); try? f.remove(); throw error
    }
}

@Test(arguments: [false, true])
func openCodeV2HistoryHTTPLostClearACKRequiresItsExactEmptyExecutionEvidence(missingTerminal: Bool) async throws {
    let f = try await OpenCodeHistoryHTTPFixture.make(), engine = try f.engine()
    do {
        let seeded = try await f.seed(engine)
        let review = try await engine.reviewConversationHistory(threadID: seeded.threadID, runID: seeded.runs[1], kind: .rewindBeforeRun)
        try f.options(["dropStageACK": .bool(true)])
        try await engine.beginConversationHistory(review)
        try await historyHTTPEventually("the retained native stage") { await f.operation(engine, review.id)?.phase == .unconfirmed }
        let stage = try await engine.inspectConversationHistoryMaintenance(operationID: review.id)
        try f.options(["dropClearACK": .bool(true), "omitClearTerminal": .bool(missingTerminal)])
        try await engine.clearConversationHistoryMaintenance(operationID: review.id, expected: stage)
        if missingTerminal {
            try await historyHTTPEventually("the clear side effect without a terminal") { f.marker("clear-no-terminal") }
            // Explicit shutdown is the bounded uncertainty boundary: no native
            // terminal or HTTP reply is invented to complete this operation.
            await engine.shutdown()
            let saved = try await WorkspaceDatabase(url: f.database).load()
            #expect(saved.conversationHistoryOperation(review.id)?.phase == .unconfirmed)
            #expect(saved.conversationHistoryOperation(review.id)?.maintenance?.result == nil)
        } else {
            try await historyHTTPEventually("conclusive native clear despite a lost HTTP reply") { await f.operation(engine, review.id)?.maintenance?.phase == .applied }
            let receipt = try #require(await f.operation(engine, review.id)?.maintenance?.result?.maintenance)
            let terminalRows = try f.rows("clear-execution-terminal")
            let terminal = try #require(terminalRows.first)
            #expect(terminal["idleMessageID"] == .string(receipt.idleMessageID))
            #expect(await f.operation(engine, review.id)?.phase == .unconfirmed)
            await engine.shutdown()
        }
        #expect(try f.rows("clear").count == 1 && f.rows("stage").count == 1 && f.rows("commit").isEmpty)
        #expect(try f.rows("prompt").count == 5)
        try await f.assertFilesUnchanged(); try await f.assertDrained(); try f.remove()
    } catch { try? f.options([:]); await engine.shutdown(); try? f.saveDiagnostic(await engine.current()); try? f.remove(); throw error }
}

@Test
func openCodeV2HistoryHTTPSameUserHeadWithChangedSyntheticTailRejectsReviewedCutBeforeAnyWrite() async throws {
    let f = try await OpenCodeHistoryHTTPFixture.make(), engine = try f.engine()
    do {
        let seeded = try await f.seed(engine)
        let source = try await f.thread(engine, seeded.threadID)
        let review = try await engine.reviewConversationHistory(threadID: source.id, runID: seeded.runs[1], kind: .rewindBeforeRun)
        try f.options(["changeTail": .bool(true)])
        try await engine.beginConversationHistory(review)
        try await historyHTTPEventually("the changed complete native inventory") { await f.operation(engine, review.id)?.phase == .failed }
        let current = try await f.thread(engine, source.id)
        #expect(current.messages == source.messages && current.runHistory == source.runHistory && current.draft == source.draft)
        #expect(try f.rows("stage").isEmpty && f.rows("commit").isEmpty && f.rows("fork").isEmpty && f.rows("clear").isEmpty)
        let nativeID = try #require(source.providerThreadID)
        let native = try f.nativeSession(nativeID)
        #expect(native["messages"].array?.last?["type"] == .string("synthetic"))
        try await f.assertFilesUnchanged()
        await engine.shutdown(); try await f.assertDrained(); try f.remove()
    } catch { await engine.shutdown(); try? f.saveDiagnostic(await engine.current()); try? f.remove(); throw error }
}

private struct OpenCodeHistoryHTTPFixture: Sendable {
    struct Seed: Sendable { let threadID: UUID; let runs: [UUID]; let openings: [String] }
    let git: CheckpointFixture
    let workspace: URL
    let database: URL
    let executable: URL
    let before: CheckpointUserState
    let originalCheckout: CheckpointUserState
    var root: URL { git.root }
    static func make() async throws -> Self {
        let git = try await CheckpointFixture.make()
        do {
            try git.write(".gitignore", "ignored.txt\n"); try await git.commitAll()
            let workspace = git.root.appendingPathComponent("checkout's 工作 & space")
            _ = try await git.run(["worktree", "add", "-b", "native-history", workspace.path])
            let originalCheckout = try await git.state()
            try Data("Staged sentinel\n".utf8).write(to: workspace.appendingPathComponent("tracked.txt"))
            _ = try await git.run(["add", "--", "tracked.txt"], at: workspace)
            for (path, text) in [("tracked.txt", "Working sentinel\n"), ("untracked.txt", "Untracked 工作\n"), ("ignored.txt", "Ignored sentinel\n")] {
                try Data(text.utf8).write(to: workspace.appendingPathComponent(path))
            }
            let before = try await git.state(at: workspace)
            let executable = git.root.appendingPathComponent("native-history-peer")
            let source = try #require(Bundle.module.url(forResource: "opencode_v2_history_http", withExtension: "py", subdirectory: "Fixtures"))
            try FileManager.default.copyItem(at: source, to: executable)
            try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: executable.path)
            let sidecar = JSONValue.object(["directory": .string(workspace.standardizedFileURL.resolvingSymlinksInPath().path)])
            try JSONEncoder().encode(sidecar).write(to: git.root.appendingPathComponent("fixture-directory.json"), options: .atomic)
            return .init(git: git, workspace: workspace, database: git.root.appendingPathComponent("history.sqlite"), executable: executable,
                         before: before, originalCheckout: originalCheckout)
        } catch { git.cleanup(); throw error }
    }
    func engine() throws -> WorkspaceEngine {
        do { return try .init(url: database, identityResolver: { _ in nil }) }
        catch { if processesStopped { git.cleanup() }; throw error }
    }
    func thread(_ engine: WorkspaceEngine, _ id: UUID) async throws -> CodingThread {
        let update = await engine.current()
        return try #require(update.snapshot.threads.first { $0.id == id })
    }
    func operation(_ engine: WorkspaceEngine, _ id: UUID) async -> ConversationHistoryOperation? {
        await engine.current().snapshot.conversationHistoryOperation(id)
    }
    func seed(_ engine: WorkspaceEngine) async throws -> Seed {
        _ = try await engine.load()
        let project = WorkspaceProject(path: workspace.path)
        let selection = OpenCodeModelSelection(providerID: "synthetic", id: "history-model", variant: "balanced")
        let menu = ProviderModel(id: selection.catalogID, name: "Synthetic history model", openCodeSelection: .init(providerID: "synthetic", id: "history-model"), openCodeVariants: ["balanced", "fast"])
        var initial = CodingThread(project: project)
        initial.provider = .opencode; initial.model = selection.catalogID; initial.checkpointPolicy = .disabled
        initial.openCodeConfiguration = .init(executable: executable.path, model: selection, agentID: "build")
        try await engine.dispatch(.addProject(project)); try await engine.dispatch(.createThread(initial))
        let threadID = initial.id
        var runs: [UUID] = [], openings: [String] = []
        for index in 1...3 {
            if index == 2 {
                try await engine.dispatch(.editThread(threadID, .openCodeVariant(model: menu, variant: "fast")))
                try await engine.dispatch(.editThread(threadID, .openCodeAgent("plan")))
            } else if index == 3 {
                try await engine.dispatch(.editThread(threadID, .openCodeVariant(model: menu, variant: "balanced")))
                try await engine.dispatch(.editThread(threadID, .openCodeAgent("build")))
            }
            let text = "History opening \(index) 工作 🌍"
            try await engine.dispatch(.submit(threadID: threadID, text: text))
            try await historyHTTPEventually("native opening \(index)") {
                guard let current = try? await thread(engine, threadID), let run = current.activeRun,
                      run.nativeTurnID != nil, current.messages.contains(where: { $0.text == "Reply to " + text }) else { return false }
                return (try? rows("input-observed").contains { $0["inputID"] == .string(run.nativeTurnID!) }) == true
            }
            let activeThread = try await thread(engine, threadID), active = try #require(activeThread.activeRun)
            let input = try #require(active.nativeTurnID)
            runs.append(active.id); openings.append(input)
            if index == 2 {
                for steeringText in ["Steer first", "Steer second"] {
                    try await engine.steerPrompt(threadID: threadID, text: steeringText, expectedRunID: active.id)
                    try await historyHTTPEventually("the exact native steering input") {
                        let update = await engine.current()
                        return update.snapshot.promptSteerings?.last?.phase == .delivered &&
                            update.snapshot.threads.first { $0.id == threadID }?.messages.contains { $0.text == "Reply to " + steeringText } == true
                    }
                }
            }
            try release("finish-" + input)
            try await historyHTTPEventually("the exact completed history run") {
                guard let current = try? await thread(engine, threadID) else { return false }
                return current.activeRun == nil && current.runHistory?.last?.id == active.id && current.runHistory?.last?.status == .completed && current.heldPostRunCheckpoint == nil
            }
        }
        try await engine.dispatch(.editThread(threadID, .draft("Latest unsent draft 工作")))
        try await engine.dispatch(.editThread(threadID, .permission(.fullAccess)))
        let current = try await thread(engine, threadID)
        #expect(current.activeHistoryRuns.map(\.id) == runs)
        #expect(current.activeHistoryRuns.map(\.turnIDs) == openings.map { [$0] })
        #expect(current.messages.filter { $0.role == .user }.count == 5)
        #expect(try rows("prompt").count == 5)
        return .init(threadID: threadID, runs: runs, openings: openings)
    }
    func marker(_ name: String) -> Bool { FileManager.default.fileExists(atPath: root.appendingPathComponent(name).path) }
    func release(_ name: String) throws { try Data().write(to: root.appendingPathComponent(name), options: .atomic) }
    func options(_ fields: [String: JSONValue]) throws { try JSONEncoder().encode(JSONValue.object(fields)).write(to: root.appendingPathComponent("options.json"), options: .atomic) }
    func rows(_ kind: String) throws -> [JSONValue] {
        let path = root.appendingPathComponent("wire.jsonl")
        guard FileManager.default.fileExists(atPath: path.path) else { return [] }
        let data = try Data(contentsOf: path)
        guard let end = data.lastIndex(of: 10) else { return [] }
        return try data[...end].split(separator: 10).map { try JSONDecoder().decode(JSONValue.self, from: Data($0)) }.filter { $0["kind"] == .string(kind) }
    }
    func nativeSession(_ id: String) throws -> JSONValue {
        try JSONDecoder().decode(JSONValue.self, from: Data(contentsOf: root.appendingPathComponent("native.json")))["sessions"][id]
    }
    func mutations() throws -> [JSONValue] {
        try ["prompt", "stage", "commit", "clear", "fork", "configure", "permissions", "create"].flatMap { try rows($0) }
    }
    func assertFilesUnchanged() async throws {
        #expect(try await git.state(at: workspace) == before)
        #expect(try await git.state() == originalCheckout)
    }
    var processesStopped: Bool {
        guard let processes = try? rows("process") else { return false }
        return processes.allSatisfy { value in
            guard case .number(let pid) = value["pid"], pid > 0, pid < Double(Int32.max) else { return false }
            return Darwin.kill(Int32(pid), 0) == -1 && errno == ESRCH
        }
    }
    func assertDrained() async throws {
        try await historyHTTPEventually("every exact owned HTTP/SSE process to exit") { processesStopped }
        let processes = try rows("process"), closed = try rows("closed")
        #expect(!processes.isEmpty && closed.count == processes.count)
        #expect(Set(processes.compactMap { value -> Int32? in
            guard case .number(let pid) = value["pid"] else { return nil }; return Int32(pid)
        }) == Set(closed.compactMap { value -> Int32? in
            guard case .number(let pid) = value["pid"] else { return nil }; return Int32(pid)
        }))
        #expect(processes.allSatisfy { $0["exactArguments"] == .bool(true) && $0["freshCredential"] == .bool(true) })
        #expect(closed.allSatisfy { $0["stdinEOF"] == .bool(true) && $0["streamClosed"] == .bool(true) && $0["httpStopped"] == .bool(true) })
        #expect(try rows("request").allSatisfy { $0["authenticated"] == .bool(true) })
        #expect(try rows("catalog-location").allSatisfy { $0["matched"] == .bool(true) })
        #expect(try rows("fixture-handler-failed").isEmpty)
        let wire = try String(contentsOf: root.appendingPathComponent("wire.jsonl"), encoding: .utf8).lowercased()
        #expect(!wire.contains("authorization") && !wire.contains("password") && !wire.contains("http://"))
    }
    func remove() throws {
        guard processesStopped else { throw CoincideError("The private history peer is still alive; its scratch files were preserved.") }
        git.cleanup()
    }
    func saveDiagnostic(_ update: WorkspaceUpdate) throws {
        let path = FileManager.default.temporaryDirectory.appendingPathComponent("coincide-history-http-diagnostic-\(UUID()).json")
        let value: JSONValue = .object(["error": update.error.map(JSONValue.string) ?? .null,
            "history": .array((update.snapshot.conversationHistoryOperations ?? []).map { .object(["phase": .string($0.phase.rawValue), "maintenance": $0.maintenance.map { .string($0.phase.rawValue) } ?? .null]) }),
            "requests": .array(Array(try rows("request").suffix(100))), "prompts": .array(try rows("prompt")),
            "stage": .array(try rows("stage")), "commit": .array(try rows("commit")), "clear": .array(try rows("clear"))])
        try JSONEncoder().encode(value).write(to: path, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: path.path)
        print("Synthetic OpenCode history diagnostics: \(path.path)")
    }
}

private func historyHTTPEventually(_ boundary: String, _ predicate: @escaping @Sendable () async -> Bool) async throws {
    let deadline = ContinuousClock.now + .seconds(8)
    while !(await predicate()) {
        guard ContinuousClock.now < deadline else { throw CoincideError("The private OpenCode history fixture did not reach \(boundary).") }
        try await Task.sleep(for: .milliseconds(10))
    }
}
