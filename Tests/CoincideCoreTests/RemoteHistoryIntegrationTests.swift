import CryptoKit
import Darwin
import Foundation
import Testing
@testable import CoincideCore

/// Actual helper, native provider history codecs, private SQLite and local Git.
/// Native histories are synthetic, durable and task-owned; no installed CLI runs.
private struct RemoteHistoryNativeFixture: Sendable {
    let root: URL, source: URL, workspace: URL, data: URL, host: URL, proxy: URL
    let environmentID: UUID, snapshot: WorkspaceSnapshot, nativeID: String
    let runIDs: [UUID], assistantIDs: [String], transcript: URL?
    var thread: CodingThread { snapshot.threads[0] }
    var environment: [String: String] {
        ["PATH": "/usr/bin:/bin:/usr/sbin:/sbin", "HOME": root.appendingPathComponent("home").path,
         "LANG": "en_US.UTF-8", "LC_ALL": "en_US.UTF-8", "GIT_CONFIG_NOSYSTEM": "1", "GIT_CONFIG_GLOBAL": "/dev/null",
         "GIT_CONFIG_SYSTEM": "/dev/null", "GIT_ALLOW_PROTOCOL": "", "GIT_TERMINAL_PROMPT": "0",
         "GIT_AUTHOR_NAME": "Private history", "GIT_AUTHOR_EMAIL": "history@example.invalid",
         "GIT_COMMITTER_NAME": "Private history", "GIT_COMMITTER_EMAIL": "history@example.invalid"]
    }
    var arguments: [String] {
        ["--stdio", "--data-directory", data.path, "--expected-environment-id", environmentID.uuidString,
         "--codex-executable", root.appendingPathComponent("private-codex").path, "--codex-home", root.appendingPathComponent("codex-home").path,
         "--claude-executable", root.appendingPathComponent("private-claude").path, "--claude-configuration-directory", root.appendingPathComponent("claude-home").path]
    }
    static func quote(_ text: String) -> String { "'" + text.replacingOccurrences(of: "'", with: "'\\''") + "'" }
    static func make(provider: ProviderKind = .codex, files: Bool = false, largePrefix: Bool = false, oversized: Bool = false) async throws -> Self {
        let fm = FileManager.default
        let root = fm.temporaryDirectory.appendingPathComponent("coincide-remote-history-\(UUID())").resolvingSymlinksInPath()
        try fm.createDirectory(at: root, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        do {
            for name in ["source", "data", "home", "codex-home", "claude-home"] {
                try fm.createDirectory(at: root.appendingPathComponent(name), withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
            }
            let source = root.appendingPathComponent("source"), workspace = root.appendingPathComponent("isolated"), data = root.appendingPathComponent("data")
            let peer = try #require(Bundle.module.url(forResource: "remote_history_codex", withExtension: "py", subdirectory: "Fixtures"))
            let claudePeer = try #require(Bundle.module.url(forResource: "remote_history_claude", withExtension: "py", subdirectory: "Fixtures"))
            let proxy = try #require(Bundle.module.url(forResource: "remote_history_proxy", withExtension: "py", subdirectory: "Fixtures"))
            #if DEBUG
            let mode = "debug"
            #else
            let mode = "release"
            #endif
            let checkout = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            let helper = checkout.appendingPathComponent(".build/\(mode)/CoincideEnvironment").resolvingSymlinksInPath()
            guard fm.isExecutableFile(atPath: helper.path) else { throw CoincideError("Build the matching native helper before history acceptance") }
            let host = root.appendingPathComponent("native-host")
            for (path, script) in [
                (host, "#!/bin/sh\numask 077\nprintf '%s\\n' \"$$\" >> \(quote(root.appendingPathComponent("host-pids.txt").path))\nexec \(quote(helper.path)) \"$@\"\n"),
                (root.appendingPathComponent("private-codex"), "#!/bin/sh\nexec /usr/bin/python3 \(quote(peer.path)) \(quote(root.path)) \"$@\"\n"),
                (root.appendingPathComponent("private-claude"), "#!/bin/sh\nexec /usr/bin/python3 \(quote(claudePeer.path)) \(quote(root.path)) \"$@\"\n")
            ] {
                try script.write(to: path, atomically: false, encoding: .utf8); try fm.setAttributes([.posixPermissions: 0o700], ofItemAtPath: path.path)
            }
            let identity = try RemoteEnvironmentService(dataDirectory: data, providerFactory: { _ in throw CoincideError("Descriptor must not construct a history runtime") })
            let environmentID = await identity.descriptor().environmentID; await identity.close()
            var empty = WorkspaceSnapshot()
            let seed = Self(root: root, source: source, workspace: workspace, data: data, host: host, proxy: proxy,
                environmentID: environmentID, snapshot: empty, nativeID: "", runIDs: [], assistantIDs: [], transcript: nil)
            _ = try await seed.git(["init", "--initial-branch=main"], at: source)
            _ = try await seed.git(["config", "commit.gpgsign", "false"], at: source)
            try Data("Committed main checkout\n".utf8).write(to: source.appendingPathComponent("tracked.txt"))
            try Data("ignored.txt\n".utf8).write(to: source.appendingPathComponent(".gitignore"))
            _ = try await seed.git(["add", "."], at: source); _ = try await seed.git(["commit", "-m", "Private history seed"], at: source)
            _ = try await seed.git(["worktree", "add", "-b", "private-history", workspace.path], at: source)
            let project = WorkspaceProject(path: source.path), nativeID = provider == .claude ? UUID().uuidString.lowercased() : "native-source"
            var thread = CodingThread(project: project, model: "history-current")
            thread.workspacePath = workspace.path; thread.provider = provider; thread.providerThreadID = nativeID
            thread.permission = .supervised; thread.checkpointPolicy = .disabled; thread.draft = "Newest unsent history draft 🌍\n"
            let runtime = try ClaudeRuntimeConfiguration.capture(workspacePath: workspace.path, executable: root.appendingPathComponent("private-claude").path,
                configurationDirectory: root.appendingPathComponent("claude-home").path, environment: seed.environment)
            if provider == .claude { thread.claudeRuntimeConfiguration = runtime }
            else { thread.codexRuntimeConfiguration = .init(selection: .custom, executable: root.appendingPathComponent("private-codex").path,
                homeDirectory: root.appendingPathComponent("codex-home").path) }
            let runIDs = (0..<3).map { _ in UUID() }, assistants = (0..<3).map { _ in UUID().uuidString.lowercased() }
            let checkpoint = GitCheckpointService(root: workspace, environment: seed.environment, gitExecutable: URL(fileURLWithPath: "/usr/bin/git"))
            var nativeRecords: [JSONValue] = [], parent: String?
            for index in runIDs.indices {
                var baseline: GitCheckpointReceipt?, post: GitCheckpointReceipt?
                if files {
                    try Data("Before native run \(index + 1)\n".utf8).write(to: workspace.appendingPathComponent("tracked.txt"))
                    baseline = try await checkpoint.capture(checkpoint.prepare())
                    try Data("After native run \(index + 1)\n".utf8).write(to: workspace.appendingPathComponent("tracked.txt"))
                    post = try await checkpoint.capture(checkpoint.prepare())
                }
                var configuration = ProviderConfiguration(thread: thread); configuration.model = "history-offline"
                if index == 0 { configuration.nativeThreadID = nil }
                let when = Date(timeIntervalSince1970: Double(1_800_000_000 + index * 10))
                var record = ThreadRunRecord(run: .init(id: runIDs[index], configuration: configuration, startedAt: when,
                    nativeTurnID: provider == .codex ? "native-\(index + 1)" : nil), origin: .user, userMessageID: "history-user-\(index)")
                record.providerThreadID = nativeID; record.status = .completed; record.endedAt = when.addingTimeInterval(1)
                record.endReason = .providerCompleted; record.messageAttributionVersion = 1
                if let baseline, let post {
                    record.checkpoints = .init(baseline: attempt(baseline), providerReleased: true)
                    record.checkpoints?.postRun = attempt(post)
                }
                var input = ChatMessage(id: "history-user-\(index)", role: .user, text: "Original history prompt \(index + 1) 🌍")
                var reply = ChatMessage(id: "history-reply-\(index)", role: .assistant, text: largePrefix && index == 0
                    ? String(repeating: "Prefix 🌍 \"\\\n", count: 40_000) : "Original history reply \(index + 1)")
                input.createdAt = when; reply.createdAt = when.addingTimeInterval(1)
                input.runReference = .init(threadID: thread.id, runID: runIDs[index]); reply.runReference = input.runReference
                if provider == .claude {
                    let opening = ClaudeInputIdentity.opening(runID: runIDs[index])
                    var evidence = try ClaudeRunHistoryEvidence(runID: runIDs[index], runtimeIdentity: runtime.runtimeIdentity, nativeSessionID: nativeID)
                    try evidence.observe(nativeSessionID: nativeID, inputIDs: [opening], rootAssistantMessageID: assistants[index]); try evidence.finish(.completed)
                    record.claude = evidence
                    nativeRecords.append(nativeRecord(id: opening, parent: parent, kind: "user", text: input.text, sessionID: nativeID, cwd: runtime.workspacePath))
                    nativeRecords.append(nativeRecord(id: assistants[index], parent: opening, kind: "assistant", text: reply.text, sessionID: nativeID, cwd: runtime.workspacePath))
                    parent = assistants[index]
                }
                thread.messages += [input, reply]
                if thread.runHistory == nil { thread.runHistory = [] }; thread.runHistory!.append(record)
            }
            if oversized {
                for index in 0..<600 {
                    var row = ChatMessage(id: "history-large-tail-\(index)", role: .assistant, text: String(repeating: "x", count: 32 * 1_024))
                    row.runReference = .init(threadID: thread.id, runID: runIDs[2]); thread.messages.append(row)
                }
            }
            empty.projects = [project]; empty.threads = [thread]
            try WorkspaceJournal.validate(empty)
            try await WorkspaceDatabase(url: data.appendingPathComponent("workspace.sqlite")).save(empty, event: "private-native-history-seed")
            try seed.writeJSON(.object(["threads": .object(["native-source": .object(["turns": .array(["native-1", "native-2", "native-3"].map(JSONValue.string))])]), "writes": .object([:])]), name: "native-state.json")
            try seed.writeJSON(.object(["outcome": .string("ack")]), name: "settings.json")
            var transcript: URL?
            if provider == .claude {
                let folder = root.appendingPathComponent("claude-home/projects").appendingPathComponent(runtime.projectKey)
                try fm.createDirectory(at: folder, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
                let file = folder.appendingPathComponent(nativeID + ".jsonl")
                var bytes = Data()
                for row in nativeRecords { bytes.append(try RemoteHistoryProtocol.payload(row)); bytes.append(10) }
                try bytes.write(to: file); try fm.setAttributes([.posixPermissions: 0o600], ofItemAtPath: file.path); transcript = file
            }
            try Data("Current staged bytes\n".utf8).write(to: workspace.appendingPathComponent("tracked.txt"))
            _ = try await seed.git(["add", "tracked.txt"])
            try Data("Current working bytes\n".utf8).write(to: workspace.appendingPathComponent("tracked.txt"))
            try Data("Keep ignored bytes\n".utf8).write(to: workspace.appendingPathComponent("ignored.txt"))
            try Data("Current untracked bytes\n".utf8).write(to: workspace.appendingPathComponent("new.txt"))
            return .init(root: root, source: source, workspace: workspace, data: data, host: host, proxy: proxy, environmentID: environmentID,
                snapshot: empty, nativeID: nativeID, runIDs: runIDs, assistantIDs: assistants, transcript: transcript)
        } catch { try? fm.removeItem(at: root); throw error }
    }
    static func attempt(_ receipt: GitCheckpointReceipt) -> ThreadRunCheckpointAttempt {
        var value = ThreadRunCheckpointAttempt(id: receipt.plan.id, workspacePath: receipt.plan.workspacePath, phase: .ready, now: receipt.capturedAt)
        value.plan = receipt.plan; value.receipt = receipt; return value
    }
    static func nativeRecord(id: String, parent: String?, kind: String, text: String, sessionID: String, cwd: String) -> JSONValue {
        .object(["type": .string(kind), "uuid": .string(id), "parentUuid": parent.map(JSONValue.string) ?? .null, "sessionId": .string(sessionID),
            "cwd": .string(cwd), "isSidechain": .bool(false), "message": .object(["role": .string(kind), "content": .string(text)])])
    }
    @discardableResult func git(_ args: [String], at directory: URL? = nil) async throws -> String {
        let result = try await CommandRunner.run("/usr/bin/git", ["--literal-pathspecs", "-C", (directory ?? workspace).path] + args,
            timeout: .seconds(10), environment: environment)
        guard result.status == 0 else { throw CoincideError("Private native-history Git fixture failed") }
        return result.text.trimmingCharacters(in: .newlines)
    }
    func writeJSON(_ value: JSONValue, name: String) throws {
        let file = root.appendingPathComponent(name); try RemoteHistoryProtocol.payload(value).write(to: file, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: file.path)
    }
    func json(_ name: String) throws -> JSONValue { try JSONDecoder().decode(JSONValue.self, from: Data(contentsOf: root.appendingPathComponent(name))) }
    func rows(_ name: String, kind: String? = nil) throws -> [JSONValue] {
        let file = root.appendingPathComponent(name)
        guard FileManager.default.fileExists(atPath: file.path) else { return [] }
        return try Data(contentsOf: file).split(separator: 10).map { try JSONDecoder().decode(JSONValue.self, from: Data($0)) }.filter { kind == nil || $0["kind"].string == kind }
    }
    func connection(dropping: UUID? = nil) throws -> JSONRPCConnection {
        if let dropping { return try .init(executable: URL(fileURLWithPath: "/usr/bin/python3"), arguments: [proxy.path, root.path, dropping.uuidString, host.path] + arguments,
            cwd: root, dialect: .jsonRPC2, maximumFrameSize: RemoteEnvironmentProtocol.maximumFrameBytes, environment: environment, drainProcessOnClose: true) }
        return try .init(executable: host, arguments: arguments, cwd: root, dialect: .jsonRPC2, maximumFrameSize: RemoteEnvironmentProtocol.maximumFrameBytes,
            environment: environment, drainProcessOnClose: true)
    }
    func target(_ client: RemoteEnvironmentClient, threadID: UUID? = nil) async throws -> RemoteWorkspaceTarget {
        let id = threadID ?? thread.id
        let binding = try await client.openProjection(scope: .control(id))
        let detail = try await client.projectionThread(.init(binding: binding, threadID: id))
        let bytes = try await client.projectionDocument(detail.thread.configuration, binding: binding)
        let configuration = try JSONDecoder().decode(ProviderConfiguration.self, from: bytes)
        _ = try await client.projectionRelease(.init(binding: binding))
        return try await client.bindHistoryWorkspace(.init(environmentID: environmentID, projectID: thread.projectID, threadID: id, configuration: configuration))
    }
    func durable() async throws -> WorkspaceSnapshot { try await WorkspaceDatabase(url: data.appendingPathComponent("workspace.sqlite")).load() }
    func releaseMutation() { _ = FileManager.default.createFile(atPath: root.appendingPathComponent("release-mutation").path, contents: Data(), attributes: [.posixPermissions: 0o600]) }
    func finish(_ client: RemoteEnvironmentClient) async throws {
        releaseMutation(); await client.close()
        var pids: [Int32] = []
        for name in ["host-pids.txt", "proxy-pids.txt"] {
            let f = root.appendingPathComponent(name)
            if FileManager.default.fileExists(atPath: f.path) { pids += try String(contentsOf: f, encoding: .utf8).split(whereSeparator: \.isNewline).compactMap { Int32($0) } }
        }
        for name in ["codex-wire.jsonl", "claude-wire.jsonl"] {
            let launches = try rows(name, kind: "launch")
            for row in launches { if case .number(let value) = row["pid"], let pid = Int32(exactly: value) { pids.append(pid) } }
            #expect(try rows(name, kind: "exit").count == launches.count)
            #expect(try rows(name, kind: "fixture-error").isEmpty)
        }
        let owned = pids
        try await remoteHistoryEventually { owned.allSatisfy { kill($0, 0) == -1 && errno == ESRCH } }
        try FileManager.default.removeItem(at: root)
    }
    func failed(_ client: RemoteEnvironmentClient) async {
        releaseMutation(); await client.close(); print("Private native history fixture retained at \(root.path)")
    }
}
private final class RemoteHistoryNativeConnections: @unchecked Sendable {
    let fixture: RemoteHistoryNativeFixture, dropped: UUID?
    private let lock = NSLock(); private var launches = 0
    init(_ fixture: RemoteHistoryNativeFixture, dropped: UUID? = nil) { self.fixture = fixture; self.dropped = dropped }
    func make() throws -> JSONRPCConnection { try lock.withLock { let value = launches == 0 ? dropped : nil; launches += 1; return try fixture.connection(dropping: value) } }
}
private func remoteHistoryEventually(_ predicate: @escaping @Sendable () async throws -> Bool) async throws {
    let deadline = ContinuousClock.now + .seconds(12)
    while try await !predicate() {
        guard ContinuousClock.now < deadline else { throw CoincideError("The private native history boundary was not reached") }
        try await Task.sleep(for: .milliseconds(10))
    }
}
private func remoteHistoryOperation(_ client: RemoteEnvironmentClient, target: RemoteWorkspaceTarget, id: UUID) async throws -> RemoteHistoryOperationView {
    guard case .operation(let value) = try await client.readHistory(.init(target: target, query: .operation(operationID: id))).value else { throw CoincideError("Expected native remote history operation") }
    return value
}
private func remoteHistoryBegin(_ target: RemoteWorkspaceTarget, _ review: RemoteHistoryReview) -> RemoteEnvironmentCommand {
    .history(target: target, action: .begin(reviewID: review.id, digest: review.digest, title: nil))
}
private func remoteHistoryApplied(_ f: RemoteHistoryNativeFixture, _ id: UUID, files: Bool = false) async throws {
    try await remoteHistoryEventually {
        guard let operation = try await f.durable().conversationHistoryOperation(id) else { return false }
        return operation.phase == .applied && (!files || operation.files?.phase == .applied)
    }
}
private func remoteHistoryConsumeClaude(_ f: RemoteHistoryNativeFixture, _ client: RemoteEnvironmentClient, id: UUID) async throws {
    let target = try await f.target(client, threadID: id)
    #expect(try await client.command(.submit(threadID: id, text: "Consume the explicit private history choice", expectedConfiguration: target.configuration)).receipt.rejection == nil)
    try await remoteHistoryEventually {
        let owner = try #require(await f.durable().threads.first { $0.id == id })
        return owner.activeRun == nil && owner.messages.contains { $0.role == .assistant && $0.text == "Private history consumer complete" }
    }
    #expect(try f.rows("claude-wire.jsonl", kind: "input").count == 1)
}

@Test(.timeLimit(.minutes(2)), arguments: [ProviderKind.codex, .claude])
func remoteHistoryNativeForkUsesHostReviewOriginalReceiptAndPrivateProviderWithoutChangingSourceOrFiles(provider: ProviderKind) async throws {
    let f = try await RemoteHistoryNativeFixture.make(provider: provider), connections = RemoteHistoryNativeConnections(f)
    let client = RemoteEnvironmentClient(factory: { try connections.make() }, expectedEnvironmentID: f.environmentID)
    do {
        _ = try await client.connectProjection(); let target = try await f.target(client)
        let review = try await client.reviewHistory(.init(target: target, runID: f.runIDs[0], kind: .forkAfterRun))
        let before = try await f.durable(), sourceBefore = try #require(before.threads.first { $0.id == f.thread.id })
        let fileBefore = try Data(contentsOf: f.workspace.appendingPathComponent("tracked.txt")), indexBefore = try await f.git(["ls-files", "--stage"])
        let nativeBefore = try f.transcript.map { try Data(contentsOf: $0) }
        let id = UUID(), command = remoteHistoryBegin(target, review)
        #expect(try await client.command(command, id: id).receipt.rejection == nil)
        try await remoteHistoryApplied(f, review.id)
        let snapshot = try await f.durable(), forkID = try #require(review.value.targetThreadID)
        let fork = try #require(snapshot.threads.first { $0.id == forkID }), source = try #require(snapshot.threads.first { $0.id == f.thread.id })
        #expect(snapshot.threads.count == 2 && fork.forkedFromHistoryOperationID == review.id && fork.providerThreadID != f.nativeID)
        #expect(fork.messages == Array(sourceBefore.messages.prefix(2)) && fork.messages.allSatisfy { $0.runReference?.threadID == f.thread.id })
        #expect(source.messages == sourceBefore.messages && source.runHistory == sourceBefore.runHistory && source.draft == sourceBefore.draft)
        #expect(try Data(contentsOf: f.workspace.appendingPathComponent("tracked.txt")) == fileBefore)
        #expect(try await f.git(["ls-files", "--stage"]) == indexBefore)
        #expect(try await client.receipt(for: command, id: id).receipt?.commandID == id)
        #expect(try await client.receipt(for: command, id: review.id).receipt == nil)
        if provider == .codex {
            #expect(try f.rows("codex-wire.jsonl", kind: "mutation-committed").count == 1)
            #expect(try f.json("native-state.json")["threads"]["native-fork"]["turns"].array?.map(\.string) == ["native-1"])
        } else {
            #expect(try f.transcript.map { try Data(contentsOf: $0) } == nativeBefore)
            #expect(try f.rows("claude-wire.jsonl", kind: "launch").isEmpty)
            try await remoteHistoryConsumeClaude(f, client, id: forkID)
            #expect(try f.transcript.map { try Data(contentsOf: $0) } == nativeBefore)
        }
        try await f.finish(client)
    } catch { await f.failed(client); throw error }
}

@Test(.timeLimit(.minutes(2)), arguments: ["codex-keep", "codex-restore", "claude-keep", "claude-restore"])
func remoteHistoryNativeRewindKeepsAuditAndNewestDraftAndUsesExactPreviousPostWhenFilesWereReviewed(choice: String) async throws {
    let restore = choice.hasSuffix("restore"), provider: ProviderKind = choice.hasPrefix("claude") ? .claude : .codex
    let f = try await RemoteHistoryNativeFixture.make(provider: provider, files: restore), connections = RemoteHistoryNativeConnections(f)
    let client = RemoteEnvironmentClient(factory: { try connections.make() }, expectedEnvironmentID: f.environmentID)
    do {
        _ = try await client.connectProjection(); let target = try await f.target(client)
        let head = try await f.git(["rev-parse", "HEAD"]), before = try Data(contentsOf: f.workspace.appendingPathComponent("tracked.txt"))
        let review = try await client.reviewHistory(.init(target: target, runID: f.runIDs[1], kind: .rewindBeforeRun,
            files: restore ? .restore : .keep, recallPromptOnSuccess: true))
        #expect((review.value.files != nil) == restore)
        let draft = "Newest draft saved after history review 🌍 e\u{301}"
        #expect(try await client.command(.editThread(threadID: f.thread.id, edit: .draft(draft), expectedConfiguration: target.configuration)).receipt.rejection == nil)
        #expect(try await client.command(remoteHistoryBegin(target, review)).receipt.rejection == nil)
        try await remoteHistoryApplied(f, review.id, files: restore)
        let durable = try await f.durable(), source = try #require(durable.threads.first { $0.id == f.thread.id })
        #expect(source.messages.count == 6 && source.visibleMessages.count == 2 && source.runHistory?.count == 3 && source.activeHistoryRuns.count == 1)
        #expect(source.draft.utf8.elementsEqual(draft.utf8) && source.model == f.thread.model)
        let current = try await f.target(client)
        let operation = try await remoteHistoryOperation(client, target: current, id: review.id)
        #expect(operation.operation.phase == "applied" && operation.needsPromptRecall && !operation.recalled)
        guard case .recall(let recall) = try await client.readHistory(.init(target: current, query: .recall(operationID: review.id))).value else { throw CoincideError("Expected original prompt recall payload") }
        let recalled: Data
        if recall.text.complete { recalled = Data(recall.text.preview.utf8) }
        else { recalled = try await client.historyDocument(try #require(recall.text.content), binding: recall.binding, target: current) }
        #expect(RemoteProjectionProtocol.digest(recalled) == RemoteProjectionProtocol.digest(Data("Original history prompt 2 🌍".utf8)))
        #expect(try await client.command(.history(target: current, action: .recallPrompt(operationID: review.id))).receipt.rejection == nil)
        let afterRecall = try await f.durable().threads[0]
        let expectedDraft = draft + "\n\nOriginal history prompt 2 🌍"
        #expect(afterRecall.draft.utf8.elementsEqual(expectedDraft.utf8))
        #expect(try await client.command(.history(target: current, action: .recallPrompt(operationID: review.id))).receipt.rejection == nil)
        #expect(try await f.durable().threads[0].draft.utf8.elementsEqual(expectedDraft.utf8))
        let file = try Data(contentsOf: f.workspace.appendingPathComponent("tracked.txt"))
        #expect(file == (restore ? Data("After native run 1\n".utf8) : before))
        #expect(try await f.git(["rev-parse", "HEAD"]) == head)
        #expect(try String(contentsOf: f.source.appendingPathComponent("tracked.txt"), encoding: .utf8) == "Committed main checkout\n")
        #expect(try String(contentsOf: f.workspace.appendingPathComponent("ignored.txt"), encoding: .utf8) == "Keep ignored bytes\n")
        if restore { #expect(!FileManager.default.fileExists(atPath: f.workspace.appendingPathComponent("new.txt").path)) }
        if provider == .claude { try await remoteHistoryConsumeClaude(f, client, id: f.thread.id) }
        try await f.finish(client)
    } catch { await f.failed(client); throw error }
}

@Test(.timeLimit(.minutes(2)))
func remoteHistoryNativeLostOuterReplyRecoversOnlyOriginalReceiptAndNeverForksOrPublishesAgainAfterReconnect() async throws {
    let f = try await RemoteHistoryNativeFixture.make(), id = UUID(), connections = RemoteHistoryNativeConnections(f, dropped: id)
    let client = RemoteEnvironmentClient(factory: { try connections.make() }, expectedEnvironmentID: f.environmentID)
    do {
        _ = try await client.connectProjection(); let target = try await f.target(client)
        let review = try await client.reviewHistory(.init(target: target, runID: f.runIDs[0], kind: .forkAfterRun)), command = remoteHistoryBegin(target, review)
        await #expect(throws: RemoteEnvironmentClientError(.commandUncertain, commandID: id)) { _ = try await client.command(command, id: id) }
        _ = try await client.reconnectProjection()
        #expect(try await client.receipt(for: command, id: id).receipt?.commandID == id)
        #expect(try await client.receipt(for: command, id: review.id).receipt == nil)
        await #expect(throws: RemoteEnvironmentClientError(.commandAlreadyAttempted, commandID: id)) { _ = try await client.command(command, id: id) }
        let snapshot = try await f.durable()
        #expect(snapshot.threads.count == 2 && snapshot.conversationHistoryOperations?.count == 1 && snapshot.conversationHistoryOperation(review.id)?.phase == .applied)
        #expect(try f.rows("codex-wire.jsonl", kind: "mutation-committed").count == 1)
        #expect(try f.rows("codex-wire.jsonl", kind: "method").filter { $0["method"].string == "turn/start" }.isEmpty)
        try await f.finish(client)
    } catch { await f.failed(client); throw error }
}

@Test(.timeLimit(.minutes(2)), arguments: ["lost-before", "lost-after"])
func remoteHistoryNativeInspectsUncertainNativeRewindWithoutRepeatingItOrStartingFiles(outcome: String) async throws {
    let f = try await RemoteHistoryNativeFixture.make(files: true), connections = RemoteHistoryNativeConnections(f)
    let client = RemoteEnvironmentClient(factory: { try connections.make() }, expectedEnvironmentID: f.environmentID)
    do {
        try f.writeJSON(.object(["outcome": .string(outcome)]), name: "settings.json")
        _ = try await client.connectProjection(); let target = try await f.target(client)
        let before = try Data(contentsOf: f.workspace.appendingPathComponent("tracked.txt"))
        let review = try await client.reviewHistory(.init(target: target, runID: f.runIDs[1], kind: .rewindBeforeRun, files: .restore))
        #expect(try await client.command(remoteHistoryBegin(target, review)).receipt.rejection == nil)
        try await remoteHistoryEventually { try await f.durable().conversationHistoryOperation(review.id)?.phase == .unconfirmed }
        #expect(try Data(contentsOf: f.workspace.appendingPathComponent("tracked.txt")) == before)
        _ = try await client.reconnectProjection(); let current = try await f.target(client)
        #expect(try await client.command(.history(target: current, action: .inspectProvider(operationID: review.id))).receipt.rejection == nil)
        let expected: ConversationHistoryPhase = outcome == "lost-after" ? .applied : .failed
        try await remoteHistoryEventually { try await f.durable().conversationHistoryOperation(review.id)?.phase == expected }
        #expect(try f.rows("codex-wire.jsonl", kind: "mutation-request").count == 1)
        #expect(try f.rows("codex-wire.jsonl", kind: "mutation-committed").count == (outcome == "lost-after" ? 1 : 0))
        #expect(try Data(contentsOf: f.workspace.appendingPathComponent("tracked.txt")) == before)
        let operation = try #require(await f.durable().conversationHistoryOperation(review.id))
        #expect(operation.files?.phase != .applied)
        try await f.finish(client)
    } catch { await f.failed(client); throw error }
}

@Test(.timeLimit(.minutes(2)), arguments: ["digest", "configuration", "head", "root", "discard"])
func remoteHistoryNativeRefusesChangedReviewConfigurationNativeHeadAndPhysicalRootBeforeProviderMutation(change: String) async throws {
    let f = try await RemoteHistoryNativeFixture.make(), connections = RemoteHistoryNativeConnections(f)
    let client = RemoteEnvironmentClient(factory: { try connections.make() }, expectedEnvironmentID: f.environmentID)
    do {
        _ = try await client.connectProjection(); let target = try await f.target(client)
        let review = try await client.reviewHistory(.init(target: target, runID: f.runIDs[1], kind: .rewindBeforeRun))
        switch change {
        case "configuration": #expect(try await client.command(.editThread(threadID: f.thread.id, edit: .model("different-current"), expectedConfiguration: target.configuration)).receipt.rejection == nil)
        case "head":
            try f.writeJSON(.object(["threads": .object(["native-source": .object(["turns": .array(["native-1", "native-2", "native-3", "external-native-head"].map(JSONValue.string))])]), "writes": .object([:])]), name: "native-state.json")
        case "root":
            try FileManager.default.moveItem(at: f.workspace, to: f.root.appendingPathComponent("retained-original"))
            try FileManager.default.createDirectory(at: f.workspace, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
            try Data("Replacement preserved\n".utf8).write(to: f.workspace.appendingPathComponent("tracked.txt"))
        case "discard": #expect(try await client.discardHistoryReview(.init(target: target, reviewID: review.id, digest: review.digest)).discarded)
        default: break
        }
        let command = RemoteEnvironmentCommand.history(target: target, action: .begin(reviewID: review.id, digest: change == "digest" ? String(repeating: "0", count: 64) : review.digest, title: nil))
        let commandID = UUID(), result = try await client.command(command, id: commandID)
        if change == "head" {
            // The journal admits an intent before the native adapter reads its
            // current head. That later proof must fail before thread/revert.
            #expect(result.receipt.rejection == nil)
            try await remoteHistoryEventually { try await f.durable().conversationHistoryOperation(review.id)?.phase == .failed }
            #expect(try await client.receipt(for: command, id: commandID).receipt == result.receipt)
            await #expect(throws: RemoteEnvironmentClientError(.commandAlreadyAttempted, commandID: commandID)) {
                _ = try await client.command(command, id: commandID)
            }
        } else { #expect(result.receipt.rejection != nil) }
        #expect(try f.rows("codex-wire.jsonl", kind: "mutation-request").isEmpty)
        #expect(try await f.durable().threads.count == 1)
        if change == "root" { #expect(try String(contentsOf: f.workspace.appendingPathComponent("tracked.txt"), encoding: .utf8) == "Replacement preserved\n") }
        try await f.finish(client)
    } catch { await f.failed(client); throw error }
}

@Test(.timeLimit(.minutes(2)))
func remoteHistoryNativeProviderSuccessWithChangedFilesRequiresExplicitInspectionAndAcknowledgementWithoutRepeatingEitherStage() async throws {
    let f = try await RemoteHistoryNativeFixture.make(files: true), connections = RemoteHistoryNativeConnections(f)
    let client = RemoteEnvironmentClient(factory: { try connections.make() }, expectedEnvironmentID: f.environmentID)
    do {
        try f.writeJSON(.object(["holdMutation": .bool(true)]), name: "settings.json")
        _ = try await client.connectProjection(); let target = try await f.target(client)
        let review = try await client.reviewHistory(.init(target: target, runID: f.runIDs[1], kind: .rewindBeforeRun, files: .restore))
        #expect(try await client.command(remoteHistoryBegin(target, review)).receipt.rejection == nil)
        try await remoteHistoryEventually { FileManager.default.fileExists(atPath: f.root.appendingPathComponent("mutation-entered").path) }
        let changed = Data("Private edit after provider dispatch\n".utf8)
        try changed.write(to: f.workspace.appendingPathComponent("tracked.txt")); f.releaseMutation()
        try await remoteHistoryEventually {
            guard let operation = try await f.durable().conversationHistoryOperation(review.id) else { return false }
            return operation.phase == .applied && (operation.files?.phase == .failed || operation.files?.phase == .unconfirmed)
        }
        let current = try await f.target(client)
        let prior = try #require(await f.durable().conversationHistoryOperation(review.id))
        let inspect = try await client.command(.history(target: current, action: .inspectFiles(operationID: review.id)))
        #expect((inspect.receipt.rejection == nil) == (prior.files?.phase == .unconfirmed))
        #expect(try await client.command(.history(target: current, action: .acknowledgeFiles(operationID: review.id))).receipt.rejection == nil)
        let operation = try #require(await f.durable().conversationHistoryOperation(review.id))
        #expect(operation.phase == .applied && operation.files?.acknowledgedAt != nil)
        #expect(try Data(contentsOf: f.workspace.appendingPathComponent("tracked.txt")) == changed)
        #expect(try f.rows("codex-wire.jsonl", kind: "mutation-committed").count == 1)
        try await f.finish(client)
    } catch { await f.failed(client); throw error }
}

@Test(.timeLimit(.minutes(2)))
func remoteHistoryNativeOversizedWorkspaceKeepsFullProofOnHostAndPagesExactLargePrefixWithoutNativeMutation() async throws {
    let f = try await RemoteHistoryNativeFixture.make(largePrefix: true, oversized: true), connections = RemoteHistoryNativeConnections(f)
    let client = RemoteEnvironmentClient(factory: { try connections.make() }, expectedEnvironmentID: f.environmentID)
    do {
        #expect(try JSONEncoder().encode(f.snapshot).count > RemoteEnvironmentProtocol.maximumFrameBytes)
        _ = try await client.connectProjection(); let target = try await f.target(client)
        let before = try await f.durable()
        let review = try await client.reviewHistory(.init(target: target, runID: f.runIDs[0], kind: .forkAfterRun))
        let header = try RemoteHistoryProtocol.payload(review)
        #expect(header.count <= RemoteHistoryProtocol.maximumResultBytes)
        let object = try #require(JSONSerialization.jsonObject(with: header) as? [String: Any])
        let value = try #require(object["value"] as? [String: Any])
        #expect(value["sourceReference"] == nil && value["sourceFingerprint"] == nil && value["prefix"] == nil && value["claude"] == nil && value["pi"] == nil)
        guard case .messages(let page) = try await client.readHistory(.init(target: target, query: .prefix(binding: review.binding, newestFirst: false, cursor: nil))).value else { throw CoincideError("Expected bounded review-prefix page") }
        #expect(page.items.map(\.id) == Array(f.thread.messages.prefix(2)).map(\.id))
        let reply = try #require(page.items.last), reference = try #require(reply.text.content)
        let bytes = try await client.historyDocument(reference, binding: review.binding, target: target)
        #expect(RemoteProjectionProtocol.digest(bytes) == RemoteProjectionProtocol.digest(Data(f.thread.messages[1].text.utf8)))
        #expect(bytes.count > RemoteHistoryProtocol.maximumResultBytes)
        #expect(try f.rows("codex-wire.jsonl", kind: "mutation-request").isEmpty)
        let after = try await f.durable()
        #expect(try RemoteHistoryProtocol.payload(after) == RemoteHistoryProtocol.payload(before))
        #expect(try await client.discardHistoryReview(.init(target: target, reviewID: review.id, digest: review.digest)).discarded)
        try await f.finish(client)
    } catch { await f.failed(client); throw error }
}
