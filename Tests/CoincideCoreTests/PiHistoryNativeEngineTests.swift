import Darwin
import Foundation
import Testing
@testable import CoincideCore

/// The provider is the real native Pi actor. Only its stdio executable is a
/// private synthetic peer; Engine admission, journal, parser and readers are real.
private final class PiWarmHistoryFactory: @unchecked Sendable {
    private let lock = NSLock()
    private let workers: URL
    private var constructed = 0
    init(workers: URL) { self.workers = workers }
    var count: Int { lock.withLock { constructed } }
    func make(_ thread: CodingThread) throws -> any ProviderSession {
        guard thread.provider == .pi, let configuration = thread.piConfiguration,
              let runtime = configuration.runtime else { throw PiConfiguration.invalid() }
        let session = PiSession(executable: URL(fileURLWithPath: runtime.executable),
            cwd: URL(fileURLWithPath: thread.workspacePath), configuration: configuration,
            permission: thread.permission, freshIntent: thread.activeRun?.configuration.piFreshSessionIntent,
            historyWorkerRootURL: workers)
        lock.withLock { constructed += 1 }
        return session
    }
}

private struct PiWarmHistoryFixture {
    let root: URL
    private(set) var checkout: URL
    private(set) var git: CheckpointFixture?
    let database: URL
    let thread: CodingThread
    let engine: WorkspaceEngine
    let factory: PiWarmHistoryFactory

    init(automaticCheckpoints: Bool = false) async throws {
        let requested = FileManager.default.temporaryDirectory.appendingPathComponent("coincide-pi-warm-history-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: requested, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        // Git plans retain Foundation's canonical spelling. Capture Pi's
        // independent physical cwd through PiRuntimeConfiguration below.
        // Starting managed paths at a POSIX /private/var spelling would let
        // Foundation normalize them only after the worktree was created.
        root = requested.standardizedFileURL.resolvingSymlinksInPath()
        guard CheckpointFiles.canonical(root.path) == root.path else {
            throw CoincideError("The private Pi fixture root has no stable Git path spelling.")
        }
        checkout = root.appendingPathComponent(automaticCheckpoints ? "MainCheckout" : "Checkout")
        try FileManager.default.createDirectory(at: checkout, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        let executable = root.appendingPathComponent("pi-history-peer")
        let resource = try #require(Bundle.module.url(forResource: "pi_history_operations_rpc_server", withExtension: "py", subdirectory: "Fixtures"))
        try FileManager.default.copyItem(at: resource, to: executable)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: executable.path)
        let home = root.appendingPathComponent("PrivateHome"), agent = root.appendingPathComponent("PrivateAgent")
        for directory in [home, agent] {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        }
        if automaticCheckpoints {
            let executable = try #require(ProcessChannel.findExecutable("git"))
            let hooks = root.appendingPathComponent("NoHooks")
            try FileManager.default.createDirectory(at: hooks, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
            var environment = ProcessChannel.environment()
            for key in environment.keys where key.hasPrefix("GIT_") { environment.removeValue(forKey: key) }
            environment["HOME"] = home.path; environment["XDG_CONFIG_HOME"] = home.appendingPathComponent(".config").path
            environment["GIT_CONFIG_NOSYSTEM"] = "1"; environment["GIT_CONFIG_GLOBAL"] = "/dev/null"; environment["GIT_OPTIONAL_LOCKS"] = "0"
            let git = CheckpointFixture(root: root, repository: checkout, git: executable, environment: environment)
            _ = try await git.run(["init", "--initial-branch=main"])
            for (key, value) in [("user.name", "Pi History Fixture"), ("user.email", "fixture@example.invalid"),
                                 ("commit.gpgsign", "false"), ("tag.gpgsign", "false"), ("core.hooksPath", hooks.path)] {
                _ = try await git.run(["config", key, value])
            }
            try git.write("tracked.txt", "v0: completed first-run files 工作\n")
            try await git.commitAll()
            self.git = git
        } else { git = nil }
        let project = WorkspaceProject(path: checkout.path), instance = UUID()
        let runtime = try PiRuntimeConfiguration.capture(workspacePath: project.path, executable: executable.path,
            instanceID: instance, environment: ["HOME": home.path, "PI_CODING_AGENT_DIR": agent.path, "PATH": "/usr/bin:/bin"])
        let configuration = PiConfiguration(instanceID: instance, executable: executable.path,
            model: .init(provider: "native", modelID: "baseline"), thinkingLevel: "medium", runtime: runtime)
        var thread = CodingThread(project: project)
        thread.provider = .pi; thread.piConfiguration = configuration; thread.model = configuration.model!.catalogID
        thread.permission = .supervised; thread.checkpointPolicy = automaticCheckpoints ? .automatic : .disabled
        self.thread = thread
        database = root.appendingPathComponent("workspace.sqlite")
        factory = .init(workers: root.appendingPathComponent("Workers"))
        let factory = factory, git = git
        engine = try WorkspaceEngine(url: database, providerFactory: { try factory.make($0) }, identityResolver: { _ in nil },
            worktreeFactory: { request in
                if let git { return GitWorktreeService(request: request, environment: git.environment, gitExecutable: git.git) }
                return GitWorktreeService(request: request)
            },
            checkpointFactory: { root in
                if let git { return git.service(at: root) }
                return GitCheckpointService(root: root)
            })
        _ = try await engine.load()
        try await engine.dispatch(.addProjectWithThread(project: project, thread: thread))
        if let git {
            try await engine.beginWorktreePreparation(threadID: thread.id,
                selection: .createBranch(name: "pi-history-files", baseRef: "refs/heads/main"))
            let localEngine = engine, threadID = thread.id
            try await piWarmHistoryEventually(phase: "worktree-ready") {
                await localEngine.current().snapshot.threads.first { $0.id == threadID }?.workspacePreparation?.isReady == true
            }
            let snapshot = await engine.current().snapshot
            let prepared = try #require(snapshot.threads.first { $0.id == thread.id })
            let ownership = try #require(prepared.workspacePreparation)
            #expect(ownership.plan?.request == ownership.request && ownership.result?.destinationPath == prepared.workspacePath)
            #expect(prepared.workspacePath != project.path && ownership.request.sourcePath == project.path)
            #expect(prepared.piConfiguration?.runtime?.registeredWorkspacePath == prepared.workspacePath)
            checkout = URL(fileURLWithPath: prepared.workspacePath)
            self.git = .init(root: root, repository: checkout, git: git.git, environment: git.environment)
        }
    }
    func current() async throws -> CodingThread {
        let snapshot = await engine.current().snapshot
        return try #require(snapshot.threads.first { $0.id == thread.id })
    }
    @discardableResult func submit(_ text: String, phase: String = "explicit-input") async throws -> UUID {
        let runID = UUID()
        try await engine.dispatch(.submit(threadID: thread.id, text: text), id: runID)
        do {
            try await piWarmHistoryEventually(phase: "submit-" + phase) {
                let source = try await current()
                return source.activeRun == nil && source.runHistory?.contains(where: {
                    $0.id == runID && $0.status == .completed && $0.pi?.captureStatus == .proven &&
                    (thread.effectiveCheckpointPolicy != .automatic ||
                        ($0.checkpoints?.baseline.phase == .ready && $0.checkpoints?.postRun?.phase == .ready))
                }) == true
            }
        } catch {
            // Only local enum values, counts and booleans enter the failure.
            // Never include private wire payloads, file paths or raw errors.
            let update = await engine.current()
            let source = update.snapshot.threads.first { $0.id == thread.id }
            let record = source?.runHistory?.first { $0.id == runID }
            let baseline = record?.checkpoints?.baseline
            let post = record?.checkpoints?.postRun
            let wire = (try? frames()) ?? []
            let promptCount = wire.filter { $0["type"] == .string("prompt") }.count
            let stateCount = wire.filter { $0["type"] == .string("get_state") }.count
            let entryCount = wire.filter { $0["type"] == .string("get_entries") }.count
            let fields = ["phase=" + phase, "state=" + (source?.state.rawValue ?? "absent"),
                "run=" + (record?.status.rawValue ?? "absent"), "pi=" + (record?.pi?.captureStatus.rawValue ?? "absent"),
                "baseline=" + (baseline?.phase.rawValue ?? "absent"), "baselineReason=" + (baseline?.unavailableReason?.rawValue ?? "absent"),
                "post=" + (post?.phase.rawValue ?? "absent"), "postReason=" + (post?.unavailableReason?.rawValue ?? "absent"),
                "active=\(source?.activeRun != nil)", "queued=\(source?.queuedTurns.count ?? 0)", "paused=\(source?.queuePaused == true)",
                "infra=\(update.error != nil)", "prompt=\(promptCount)", "stateReads=\(stateCount)", "entryReads=\(entryCount)"]
            throw CoincideError("The private warm Pi submit boundary failed: " + fields.joined(separator: ","))
        }
        return runID
    }
    func setOptions(_ value: [String: JSONValue]) throws {
        try JSONEncoder().encode(JSONValue.object(value)).write(to: root.appendingPathComponent("operations-options.json"), options: .atomic)
    }
    func frames() throws -> [JSONValue] {
        let file = root.appendingPathComponent("operations-wire.jsonl")
        guard FileManager.default.fileExists(atPath: file.path) else { return [] }
        let data = try Data(contentsOf: file)
        guard let end = data.lastIndex(of: 10) else { return [] }
        return try data[...end].split(separator: 10).map { try JSONDecoder().decode(JSONValue.self, from: Data($0)) }
    }
    func launches() throws -> [Int32] {
        try frames().compactMap { frame in
            guard frame["kind"] == .string("launch"), frame["argv"].array?.first == .string("--mode"),
                  case .number(let pid) = frame["pid"], let value = Int32(exactly: pid) else { return nil }
            return value
        }
    }
    func finish() async {
        await engine.shutdown()
        do {
            for pid in try launches() { #expect(kill(pid, 0) != 0 && errno == ESRCH) }
        } catch { Issue.record("The private Pi launch receipt could not be inspected.") }
        try? FileManager.default.removeItem(at: root)
    }
}

private func piWarmHistoryEventually(phase: String = "history-settlement", _ predicate: () async throws -> Bool) async throws {
    let deadline = ContinuousClock.now + .seconds(8)
    while !(try await predicate()) {
        guard ContinuousClock.now < deadline else { throw CoincideError("The private warm Pi history boundary did not settle: " + phase) }
        try await Task.sleep(for: .milliseconds(5))
    }
}

@Test(.timeLimit(.minutes(1)))
func piHistoryNativeEngineVetoRetainsOwnedSourceProcessAndSingleReaderForNextExplicitInput() async throws {
    let f = try await PiWarmHistoryFixture()
    do {
        _ = try await f.submit("Warm source first input 工作")
        let second = try await f.submit("Warm source second input 😀")
        let before = try await f.current(), runtimeID = try #require(before.runtimeID), nativeFile = try #require(before.providerThreadID)
        let originalLaunches = try f.launches()
        let pid = try #require(originalLaunches.first), bytes = try Data(contentsOf: URL(fileURLWithPath: nativeFile))
        #expect(f.factory.count == 1)
        try f.setOptions(["forkDialog": .bool(true)])
        let review = try await f.engine.reviewConversationHistory(threadID: f.thread.id, runID: second, kind: .rewindBeforeRun)
        #expect(review.pi?.source.reference.nativeThreadID == nativeFile)
        try await f.engine.beginConversationHistory(review)
        try await piWarmHistoryEventually {
            await f.engine.current().snapshot.conversationHistoryOperation(review.id)?.piControls?.requests.count == 1
        }
        let pending = await f.engine.current().snapshot.conversationHistoryOperation(review.id)
        let controls = try #require(pending?.piControls), request = try #require(controls.requests.first)
        try await f.engine.respondPiHistory(operationID: review.id, sessionID: controls.sessionID, requestID: request.id, response: .decision(false))
        try await piWarmHistoryEventually {
            await f.engine.current().snapshot.conversationHistoryOperation(review.id)?.phase == .failed
        }
        let vetoed = try await f.current(), operation = await f.engine.current().snapshot.conversationHistoryOperation(review.id)
        #expect(vetoed.runtimeID == runtimeID && vetoed.providerThreadID == nativeFile && vetoed.activeRun == nil)
        #expect(vetoed.messages == before.messages && vetoed.runHistory == before.runHistory)
        #expect(operation?.piCandidates == nil && operation?.piControls == nil && operation?.result == nil)
        #expect(f.factory.count == 1 && kill(pid, 0) == 0)
        let unchanged = try Data(contentsOf: URL(fileURLWithPath: nativeFile))
        #expect(unchanged == bytes)
        let afterVeto = try f.frames()
        #expect(afterVeto.filter { $0["type"] == .string("prompt") }.count == 2)
        #expect(afterVeto.filter { $0["type"] == .string("fork") }.count == 1)
        #expect(!afterVeto.contains { $0["kind"] == .string("closed") && $0["pid"] == .number(Double(pid)) })

        let successor = try await f.submit("One explicit input after conclusive native veto λ")
        let final = try await f.current(), record = try #require(final.runHistory?.first { $0.id == successor })
        #expect(final.runtimeID == runtimeID && final.providerThreadID == nativeFile && f.factory.count == 1)
        #expect(record.turnIDs.isEmpty && record.pi?.captureStatus == .proven && record.pi?.nativeSessionFile == nativeFile)
        let frames = try f.frames()
        #expect(frames.filter { $0["type"] == .string("prompt") }.count == 3)
        #expect(try f.launches() == [pid])
        let saved = try await WorkspaceDatabase(url: f.database).load()
        #expect(saved.threads.first { $0.id == f.thread.id }?.runHistory == final.runHistory)
        try WorkspaceJournal.validate(saved)
    } catch { await f.finish(); throw error }
    await f.finish()
}

@Test(.timeLimit(.minutes(1)))
func piHistoryNativeEngineWarmRewindDrainsSourceAndNextExplicitInputOpensOnlyTheAdoptedBranch() async throws {
    let f = try await PiWarmHistoryFixture()
    do {
        let first = try await f.submit("Warm branch retained first input 工作")
        let second = try await f.submit("Warm branch discarded second input 😀")
        let before = try await f.current(), nativeFile = try #require(before.providerThreadID), runtimeID = try #require(before.runtimeID)
        let originalLaunches = try f.launches()
        let pid = try #require(originalLaunches.first), bytes = try Data(contentsOf: URL(fileURLWithPath: nativeFile))
        let review = try await f.engine.reviewConversationHistory(threadID: f.thread.id, runID: second, kind: .rewindBeforeRun)
        try await f.engine.beginConversationHistory(review)
        try await piWarmHistoryEventually {
            await f.engine.current().snapshot.conversationHistoryOperation(review.id)?.phase == .applied
        }
        let adopted = try await f.current(), target = try #require(adopted.providerThreadID)
        let saved = try await WorkspaceDatabase(url: f.database).load(), operation = try #require(saved.conversationHistoryOperation(review.id))
        #expect(target != nativeFile && adopted.runtimeID == nil && adopted.activeRun == nil && adopted.queuedTurns.isEmpty)
        #expect(adopted.activeHistoryRuns.map(\.id) == [first] && adopted.runHistory == saved.threads.first { $0.id == f.thread.id }?.runHistory)
        #expect(adopted.piConfiguration == before.piConfiguration && adopted.permission == before.permission)
        #expect(operation.piCandidates?.map(\.stage) == [.finalBranch] && operation.piControls == nil)
        #expect(operation.result?.pi?.snapshot.reference.nativeThreadID == target)
        #expect(f.factory.count == 1 && kill(pid, 0) != 0 && errno == ESRCH)
        let sourceBytes = try Data(contentsOf: URL(fileURLWithPath: nativeFile))
        #expect(sourceBytes == bytes)
        let beforeSend = try f.frames()
        #expect(beforeSend.filter { $0["type"] == .string("prompt") }.count == 2)
        #expect(beforeSend.filter { $0["type"] == .string("fork") }.count == 1)
        let branch = try PiHistoryFileReader().read(filePath: target, expectedWorkspacePath: before.piConfiguration!.runtime!.workspacePath).graph
        #expect(branch.header.raw["parentSession"] == .string(nativeFile))
        let retainedIDs = Set(operation.result!.pi!.snapshot.entries.map(\.id))
        let retainedOpening = try #require(before.runHistory?.first { $0.id == first }?.pi?.openingUserEntryID)
        let discardedOpening = try #require(before.runHistory?.first { $0.id == second }?.pi?.openingUserEntryID)
        #expect(retainedIDs.contains(retainedOpening) && !retainedIDs.contains(discardedOpening))

        let successor = try await f.submit("One explicit input in the adopted native branch λ")
        let final = try await f.current(), proof = try #require(final.runHistory?.first { $0.id == successor }?.pi)
        #expect(final.providerThreadID == target && final.runtimeID != nil && final.runtimeID != runtimeID && f.factory.count == 2)
        #expect(proof.nativeSessionFile == target && proof.captureStatus == .proven && proof.preparation.baseline.entries == operation.result?.pi?.snapshot.entries)
        let frames = try f.frames(), pids = try f.launches()
        #expect(pids.count == 2 && pids.first == pid && pids.last != pid)
        #expect(frames.filter { $0["type"] == .string("prompt") }.count == 3)
        let switches = frames.filter { $0["type"] == .string("switch_session") }
        #expect(switches.count == 1 && switches.first?["sessionPath"] == .string(target))
        let stillOriginal = try Data(contentsOf: URL(fileURLWithPath: nativeFile))
        #expect(stillOriginal == bytes)
        try WorkspaceJournal.validate(await f.engine.current().snapshot)
    } catch { await f.finish(); throw error }
    await f.finish()
}

private struct PiWarmGitBoundary {
    let first: UUID
    let second: UUID
    let source: CodingThread
    let firstPost: GitCheckpointReceipt
    let secondBaseline: GitCheckpointReceipt
    let nativeFile: String
    let nativeBytes: Data
    let gitState: CheckpointUserState
    let mainState: CheckpointUserState
}

private func preparePiWarmGitBoundary(_ f: PiWarmHistoryFixture) async throws -> PiWarmGitBoundary {
    let git = try #require(f.git)
    let first = try await f.submit("First completed Pi input with v0 files 工作", phase: "git-first")
    try git.write("tracked.txt", "v1: external edits before the second input 😀\n")
    let second = try await f.submit("Second Pi input to recall exactly λ", phase: "git-second")
    let source = try await f.current(), nativeFile = try #require(source.providerThreadID)
    let firstPost = try #require(source.runHistory?.first { $0.id == first }?.checkpoints?.postRun?.receipt)
    let secondBaseline = try #require(source.runHistory?.first { $0.id == second }?.checkpoints?.baseline.receipt)
    let secondPost = try #require(source.runHistory?.first { $0.id == second }?.checkpoints?.postRun?.receipt)
    let v0 = try await git.blob(firstPost, "tracked.txt"), v1 = try await git.blob(secondBaseline, "tracked.txt")
    let v1Post = try await git.blob(secondPost, "tracked.txt")
    #expect(v0 == Data("v0: completed first-run files 工作\n".utf8))
    #expect(v1 == Data("v1: external edits before the second input 😀\n".utf8) && v1Post == v1 && v0 != v1)
    let paths = try await git.paths(firstPost)
    #expect(paths == ["tracked.txt"])
    #expect(!nativeFile.hasPrefix(f.checkout.path + "/") && !f.database.path.hasPrefix(f.checkout.path + "/"))
    try git.write("tracked.txt", "v2: external edits after the second input 工作\n")
    return .init(first: first, second: second, source: source, firstPost: firstPost, secondBaseline: secondBaseline,
        nativeFile: nativeFile, nativeBytes: try Data(contentsOf: URL(fileURLWithPath: nativeFile)), gitState: try await git.state(),
        mainState: try await git.state(at: f.root.appendingPathComponent("MainCheckout")))
}

@Test(.timeLimit(.minutes(1)), arguments: ["conversationOnly", "filesAndRecall", "filesOnly"])
func piHistoryNativeEngineRealGitRewindKeepsIndependentNativeFilesAndLatestDraftWithExactPreviousPost(_ shape: String) async throws {
    let f = try await PiWarmHistoryFixture(automaticCheckpoints: true)
    do {
        let git = try #require(f.git), boundary = try await preparePiWarmGitBoundary(f)
        let latest = "The latest independently saved Pi draft 工作 😀"
        try await f.engine.dispatch(.editThread(f.thread.id, .draft(latest)))
        let keep = try await f.engine.reviewConversationHistory(threadID: f.thread.id, runID: boundary.second,
            kind: .rewindBeforeRun, recallPromptOnSuccess: shape == "filesAndRecall")
        let snapshot = await f.engine.current().snapshot
        guard case .available(let target) = try snapshot.conversationHistoryFileTarget(for: keep) else {
            throw CoincideError("The exact Pi previous-post file boundary was unavailable.")
        }
        #expect(target.stage == .postRun && target.checkpointRunID == boundary.first)
        #expect(target.receipt == boundary.firstPost && target.receipt != boundary.secondBaseline)
        let beforeFrames = try f.frames()
        #expect(beforeFrames.filter { $0["type"] == .string("prompt") }.count == 2 && f.factory.count == 1)

        if shape == "filesOnly" {
            let review = try await f.engine.reviewCheckpointRestore(threadID: f.thread.id, runID: target.checkpointRunID,
                stage: target.stage, expectedAttemptID: target.attemptID)
            #expect(review.gitReview.targetReceipt == boundary.firstPost)
            await f.engine.discardConversationHistoryReview(reviewID: keep.id)
            try await f.engine.beginCheckpointRestore(review)
            try await piWarmHistoryEventually {
                await f.engine.current().snapshot.checkpointRestoreOperation(review.id)?.phase == .applied
            }
            let restored = try await f.current(), state = await f.engine.current().snapshot
            #expect(restored.providerThreadID == boundary.nativeFile && restored.messages == boundary.source.messages)
            #expect(restored.runHistory == boundary.source.runHistory && restored.draft == latest)
            #expect(state.conversationHistoryOperations == nil && restored.activeRun == nil && restored.queuedTurns.isEmpty)
            let bytes = try Data(contentsOf: f.checkout.appendingPathComponent("tracked.txt"))
            #expect(bytes == Data("v0: completed first-run files 工作\n".utf8))
            let frames = try f.frames()
            #expect(!frames.contains { $0["type"] == .string("fork") || $0["kind"] == .string("cliClone") })
            #expect(frames.filter { $0["type"] == .string("prompt") }.count == 2 && f.factory.count == 1)
            try WorkspaceJournal.validate(state)
        } else {
            let review: ConversationHistoryReview
            if shape == "filesAndRecall" {
                review = try await f.engine.reviewConversationHistoryRestoringFiles(keep)
                await f.engine.discardConversationHistoryReview(reviewID: keep.id)
                #expect(review.files?.target == target && review.files?.target.receipt == boundary.firstPost)
            } else { review = keep }
            try await f.engine.beginConversationHistory(review)
            try await piWarmHistoryEventually {
                let operation = await f.engine.current().snapshot.conversationHistoryOperation(review.id)
                return operation?.phase == .applied && (shape != "filesAndRecall" || operation?.files?.phase == .applied)
            }
            let adopted = try await f.current(), state = await f.engine.current().snapshot
            let operation = try #require(state.conversationHistoryOperation(review.id))
            #expect(adopted.providerThreadID != boundary.nativeFile && adopted.activeHistoryRuns.map(\.id) == [boundary.first])
            #expect(adopted.runHistory?.allSatisfy { $0.providerThreadID == boundary.nativeFile && $0.turnIDs.isEmpty } == true)
            #expect(adopted.runHistory?.map(\.pi) == boundary.source.runHistory?.map(\.pi))
            #expect(adopted.piConfiguration == boundary.source.piConfiguration && adopted.permission == boundary.source.permission)
            #expect(adopted.draft == latest && adopted.activeRun == nil && adopted.queuedTurns.isEmpty)
            let bytes = try Data(contentsOf: f.checkout.appendingPathComponent("tracked.txt"))
            if shape == "filesAndRecall" {
                #expect(bytes == Data("v0: completed first-run files 工作\n".utf8))
                #expect(operation.allExternalWorkSucceeded && operation.needsPromptRecall && operation.recalledAt == nil)
                guard case .available(let adoptedTarget) = try state.conversationHistoryFileTarget(for: review,
                    includingRemovedByHistoryOperationID: review.id) else {
                    throw CoincideError("The Pi file receipt lost its immutable origin after native adoption.")
                }
                #expect(adoptedTarget == target)
                try await f.engine.dispatch(.recallConversationHistoryPrompt(operationID: review.id))
                let recalled = try await f.current(), once = await f.engine.current().snapshot
                #expect(recalled.draft == latest + "\n\nSecond Pi input to recall exactly λ")
                #expect(recalled.activeRun == nil && recalled.queuedTurns.isEmpty)
                try await f.engine.dispatch(.recallConversationHistoryPrompt(operationID: review.id))
                #expect(await f.engine.current().snapshot == once)
                try WorkspaceJournal.validate(once)
            } else {
                #expect(bytes == Data("v2: external edits after the second input 工作\n".utf8))
                #expect(operation.files == nil && !operation.needsPromptRecall && operation.recalledAt == nil)
                let unchanged = try await git.state()
                #expect(unchanged == boundary.gitState)
                try WorkspaceJournal.validate(state)
            }
            let frames = try f.frames()
            #expect(frames.filter { $0["type"] == .string("fork") }.count == 1)
            #expect(frames.filter { $0["type"] == .string("prompt") }.count == 2 && f.factory.count == 1)
        }
        let nativeBytes = try Data(contentsOf: URL(fileURLWithPath: boundary.nativeFile))
        #expect(nativeBytes == boundary.nativeBytes)
        let finalGit = try await git.state()
        #expect(finalGit.head == boundary.gitState.head && finalGit.branches == boundary.gitState.branches)
        let mainState = try await git.state(at: f.root.appendingPathComponent("MainCheckout"))
        #expect(mainState == boundary.mainState)
        let saved = try await WorkspaceDatabase(url: f.database).load()
        let replay = try await WorkspaceDatabase(url: f.database).rebuildProjection().snapshot
        #expect(saved == replay)
    } catch { await f.finish(); throw error }
    await f.finish()
}

@Test(.timeLimit(.minutes(1)))
func piHistoryNativeEngineStaleRealGitReviewRefusesProviderForkAndKeepsNativeSourceAndExternalFiles() async throws {
    let f = try await PiWarmHistoryFixture(automaticCheckpoints: true)
    do {
        let git = try #require(f.git), boundary = try await preparePiWarmGitBoundary(f)
        let keep = try await f.engine.reviewConversationHistory(threadID: f.thread.id, runID: boundary.second,
            kind: .rewindBeforeRun, recallPromptOnSuccess: true)
        let review = try await f.engine.reviewConversationHistoryRestoringFiles(keep)
        await f.engine.discardConversationHistoryReview(reviewID: keep.id)
        try git.write("tracked.txt", "v3: an external edit after the exact file review 😀\n")
        let currentFiles = try await git.state()
        try await f.engine.beginConversationHistory(review)
        try await piWarmHistoryEventually {
            await f.engine.current().snapshot.conversationHistoryOperation(review.id)?.phase == .failed
        }
        let final = try await f.current(), snapshot = await f.engine.current().snapshot
        let operation = try #require(snapshot.conversationHistoryOperation(review.id))
        #expect(final.providerThreadID == boundary.nativeFile && final.messages == boundary.source.messages && final.runHistory == boundary.source.runHistory)
        #expect(operation.piCandidates == nil && operation.result == nil && operation.files?.phase == .waitingForProvider)
        #expect(!operation.needsPromptRecall && operation.recalledAt == nil)
        let frames = try f.frames(), nativeBytes = try Data(contentsOf: URL(fileURLWithPath: boundary.nativeFile))
        #expect(!frames.contains { $0["type"] == .string("fork") || $0["kind"] == .string("cliClone") })
        #expect(frames.filter { $0["type"] == .string("prompt") }.count == 2 && f.factory.count == 1)
        #expect(nativeBytes == boundary.nativeBytes)
        let stillCurrentFiles = try await git.state()
        #expect(stillCurrentFiles == currentFiles)
        let mainState = try await git.state(at: f.root.appendingPathComponent("MainCheckout"))
        #expect(mainState == boundary.mainState)
        try WorkspaceJournal.validate(snapshot)
    } catch { await f.finish(); throw error }
    await f.finish()
}
