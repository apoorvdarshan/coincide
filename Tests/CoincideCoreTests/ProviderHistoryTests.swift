import Foundation
import Testing
@testable import CoincideCore

private struct HistoryPeer: Sendable {
    let root: URL
    let workspace: URL
    let optionsFile: URL
    let wireFile: URL
    let session: CodexSession

    init(options: [String: JSONValue] = [:]) throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("coincide-history-\(UUID())", isDirectory: true).standardizedFileURL.resolvingSymlinksInPath()
        workspace = root.appendingPathComponent("Native workspace 日本語", isDirectory: true)
        optionsFile = root.appendingPathComponent("options.json")
        wireFile = root.appendingPathComponent("wire.jsonl")
        try FileManager.default.createDirectory(at: workspace, withIntermediateDirectories: true)
        var config = options; config["cwd"] = .string(workspace.path)
        try JSONEncoder().encode(JSONValue.object(config)).write(to: optionsFile, options: .atomic)
        let fixture = try #require(Bundle.module.url(forResource: "codex_history", withExtension: "py", subdirectory: "Fixtures"))
        session = try CodexSession(executable: URL(fileURLWithPath: "/usr/bin/python3"), cwd: workspace,
                                   arguments: [fixture.path, optionsFile.path, wireFile.path])
    }
    var source: ProviderConversationReference { get throws { try .init(provider: .codex, nativeThreadID: "native-source") } }
    var thread: CodingThread {
        var value = CodingThread(project: WorkspaceProject(path: workspace.path), model: "reviewed-model")
        value.providerThreadID = "native-source"; value.permission = .auto
        return value
    }
    var configuration: ProviderConfiguration { .init(thread: thread) }
    func writeOptions(_ options: [String: JSONValue]) throws {
        var config = options; config["cwd"] = .string(workspace.path)
        try JSONEncoder().encode(JSONValue.object(config)).write(to: optionsFile, options: .atomic)
    }
    func frames() throws -> [JSONValue] {
        guard FileManager.default.fileExists(atPath: wireFile.path) else { return [] }
        let data = try Data(contentsOf: wireFile)
        // The peer appends one complete line per frame. A concurrent partial
        // trailing line is not evidence yet and is ignored by polling callers.
        return data.split(separator: 10).compactMap { try? JSONDecoder().decode(JSONValue.self, from: Data($0)) }
    }
    func requests(_ method: String) throws -> [JSONValue] { try frames().filter { $0["method"].string == method } }
    func assertNoImplicitWork() throws {
        let methods = try frames().compactMap { $0["method"].string }
        for method in ["thread/start", "thread/resume", "turn/start", "turn/interrupt", "thread/goal/set", "thread/goal/clear"] {
            #expect(!methods.contains(method))
        }
    }
    func gate(_ name: String) -> (entered: URL, release: URL, value: JSONValue) {
        let entered = root.appendingPathComponent(name + ".entered"), release = root.appendingPathComponent(name + ".release")
        return (entered, release, .object(["entered": .string(entered.path), "release": .string(release.path)]))
    }
}

private func withHistoryPeer(options: [String: JSONValue] = [:], _ body: (HistoryPeer) async throws -> Void) async throws {
    let peer = try HistoryPeer(options: options)
    do { try await body(peer); await peer.session.close(); try FileManager.default.removeItem(at: peer.root) }
    catch { await peer.session.close(); try? FileManager.default.removeItem(at: peer.root); throw error }
}

private func historyEventually(_ predicate: () async throws -> Bool) async throws {
    let deadline = ContinuousClock.now + .seconds(8)
    while true {
        if try await predicate() { return }
        guard ContinuousClock.now < deadline else { throw CoincideError("The offline history peer did not reach the expected gate.") }
        try await Task.sleep(for: .milliseconds(5))
    }
}

private actor HistorySignal {
    private(set) var reached = false
    func mark() { reached = true }
}

private actor HistoryObservedEvents {
    private(set) var values: [ProviderEvent] = []
    func append(_ event: ProviderEvent) { values.append(event) }
}

private func historyError(_ expected: ProviderHistoryError.Kind, _ body: () async throws -> Void) async throws {
    do { try await body(); Issue.record("Expected provider history error \(expected.rawValue).") }
    catch let error as ProviderHistoryError { #expect(error.kind == expected) }
}

private func historyTurn(_ id: String, _ status: String = "completed") -> JSONValue {
    .object(["id": .string(id), "status": .string(status), "items": .array([])])
}
private func historyPage(_ turns: [JSONValue], next: String? = nil) -> JSONValue {
    .object(["data": .array(turns), "nextCursor": next.map(JSONValue.string) ?? .null, "backwardsCursor": .null])
}
private func historyUnscoped(_ event: ProviderEvent) -> ProviderEvent {
    if case .context(_, let child) = event { return historyUnscoped(child) }; return event
}
private func historyCompleted(_ iterator: inout AsyncStream<ProviderEvent>.Iterator) async throws {
    while let event = await iterator.next() {
        switch historyUnscoped(event) {
        case .completed(.idle): return
        case .failure(let message), .connectionClosed(let message): throw CoincideError(message)
        default: break
        }
    }
    throw CoincideError("The offline history peer ended before explicit turn completion.")
}

private actor HistoryUnsupportedSession: ProviderSession {
    nonisolated let events = AsyncStream<ProviderEvent> { $0.finish() }
    func models() async throws -> [ProviderModel] { [] }
    func send(text: String, thread: CodingThread) async throws {}
    func interrupt() async throws {}
    func respond(_ request: ApprovalRequest, allow: Bool) async throws {}
    func answer(_ request: ApprovalRequest, answers: [String: String]) async throws {}
    func close() async {}
}

@Test
func providerHistoryOpaqueReferencesAndSnapshotsValidateOnDecode() throws {
    let reference = try ProviderConversationReference(provider: .codex, nativeThreadID: "native-not-an-app-uuid")
    let snapshot = try ProviderConversationSnapshot(reference: reference, workspacePath: "/tmp/Native workspace", historyMode: .paginated, headTurnID: "turn:日本語")
    #expect(try JSONDecoder().decode(ProviderConversationSnapshot.self, from: JSONEncoder().encode(snapshot)) == snapshot)
    for invalid in ["", " \t", "native\nturn", String(repeating: "x", count: 4_097)] {
        #expect(throws: ProviderHistoryError.self) { try ProviderConversationReference(provider: .codex, nativeThreadID: invalid) }
        let data = try JSONEncoder().encode(JSONValue.object(["provider": .string("codex"), "nativeThreadID": .string(invalid)]))
        #expect(throws: ProviderHistoryError.self) { try JSONDecoder().decode(ProviderConversationReference.self, from: data) }
    }
    #expect(throws: ProviderHistoryError.self) { try ProviderConversationSnapshot(reference: reference, workspacePath: "/tmp/../other", historyMode: .paginated) }
    let turn = try ProviderHistoryTurn(id: "native-turn", status: .completed)
    #expect(throws: ProviderHistoryError.self) { try ProviderHistoryPage(reference: reference, turns: [turn, turn]) }
    #expect(throws: ProviderHistoryError.self) { try ProviderHistoryPage(reference: reference, turns: [], nextCursor: "") }
    for boundary in [ProviderHistoryBoundary.head, .throughTurn("opaque:turn"), .beforeTurn("opaque:turn")] {
        #expect(try JSONDecoder().decode(ProviderHistoryBoundary.self, from: JSONEncoder().encode(boundary)) == boundary)
    }
}

@Test
func providerHistoryDefaultAdaptersExplicitlyRejectAllHistoryOperations() async throws {
    let adapter: any ProviderSession = HistoryUnsupportedSession()
    let project = WorkspaceProject(path: "/tmp")
    let reference = try ProviderConversationReference(provider: .claude, nativeThreadID: "native-source")
    try await historyError(.unsupported) { _ = try await adapter.historyCapabilities(threadID: reference.nativeThreadID) }
    try await historyError(.unsupported) { _ = try await adapter.conversationSnapshot(threadID: reference.nativeThreadID) }
    try await historyError(.unsupported) { _ = try await adapter.historyPage(threadID: reference.nativeThreadID) }
    try await historyError(.unsupported) { _ = try await adapter.forkConversation(source: reference, boundary: .beforeTurn("native-2"), configuration: .init(thread: CodingThread(project: project))) }
    try await historyError(.unsupported) { _ = try await adapter.revertConversation(thread: reference, beforeTurnID: "native-2", expectedHeadTurnID: "native-3") }
}

@Test(.timeLimit(.minutes(1)))
func codexHistoryReadOnlySnapshotReportsActualNativeHeadWithoutResuming() async throws {
    try await withHistoryPeer { peer in
        let snapshot = try await peer.session.conversationSnapshot(threadID: "native-source")
        let source = try peer.source
        #expect(snapshot.reference == source)
        #expect(snapshot.workspacePath == peer.workspace.path)
        #expect(snapshot.historyMode == .paginated && snapshot.headTurnID == "native-3")
        let requests = try peer.requests("thread/turns/list")
        #expect(requests.count == 1 && requests.first?["params"]["limit"] == .number(1))
        #expect(try peer.requests("thread/fork").isEmpty)
        #expect(try peer.requests("thread/revert").isEmpty)
        try peer.assertNoImplicitWork()
    }
}

@Test(.timeLimit(.minutes(1)))
func codexHistoryConcurrentReadersShareOneInitialization() async throws {
    try await withHistoryPeer { peer in
        let gate = peer.gate("initialize")
        try peer.writeOptions(["gates": .object(["initialize": gate.value])])
        let first = Task { try await peer.session.historyCapabilities(threadID: "native-source") }
        try await historyEventually { FileManager.default.fileExists(atPath: gate.entered.path) }
        let second = Task { try await peer.session.historyPage(threadID: "native-source", limit: 2) }
        let third = Task { try await peer.session.connect() }
        try Data().write(to: gate.release)
        let capabilities = try await first.value, page = try await second.value
        try await third.value
        #expect(capabilities.historyMode == .paginated)
        #expect(capabilities.canRead && capabilities.canForkHead && capabilities.canForkFromTurn && capabilities.canRevertBeforeTurn)
        #expect(page.turns.map(\.id) == ["native-3", "native-2"])
        #expect(try peer.requests("initialize").count == 1)
        #expect(try peer.requests("initialized").count == 1)
        try peer.assertNoImplicitWork()
    }
}

@Test(.timeLimit(.minutes(1)))
func codexHistoryCancelledInitializationWaiterDoesNotCancelAnotherReader() async throws {
    try await withHistoryPeer { peer in
        let gate = peer.gate("initialize-cancellation"), cancelled = HistorySignal()
        try peer.writeOptions(["gates": .object(["initialize": gate.value])])
        let first = Task {
            do { try await peer.session.connect(); Issue.record("The cancelled initialization waiter completed normally.") }
            catch is CancellationError { await cancelled.mark() }
        }
        try await historyEventually { FileManager.default.fileExists(atPath: gate.entered.path) }
        let second = Task { try await peer.session.historyCapabilities(threadID: "native-source") }
        first.cancel()
        try await historyEventually { await cancelled.reached }
        #expect(!FileManager.default.fileExists(atPath: gate.release.path))
        try Data().write(to: gate.release)
        try await first.value
        let capabilities = try await second.value
        #expect(capabilities.canRead && capabilities.canRevertBeforeTurn)
        #expect(try peer.requests("initialize").count == 1)
        #expect(try peer.requests("initialized").count == 1)
        try peer.assertNoImplicitWork()
    }
}

@Test(.timeLimit(.minutes(1)))
func codexHistoryInitializationFailureDoesNotExposeRemotePrivateDetails() async throws {
    let privateDetail = "synthetic-history-handshake-private-detail"
    let failure: JSONValue = .object(["code": .number(-32000), "message": .string(privateDetail),
                                      "data": .object(["debug": .string(privateDetail)])])
    try await withHistoryPeer(options: ["methodErrors": .object(["initialize": failure])]) { peer in
        do {
            _ = try await peer.session.historyCapabilities(threadID: "native-source")
            Issue.record("Expected a fixed history initialization failure.")
        } catch let error as ProviderHistoryError {
            #expect(error.kind == .invalidResponse)
            #expect(!error.localizedDescription.contains(privateDetail))
        }
        #expect(try peer.requests("initialize").count == 1)
        #expect(try peer.requests("initialized").isEmpty)
        #expect(try peer.requests("thread/read").isEmpty)
        #expect(try peer.requests("thread/fork").isEmpty)
        try peer.assertNoImplicitWork()
    }
}

@Test(.timeLimit(.minutes(1)))
func codexHistoryPagesKeepOpaqueCursorAndRequestOnlyBoundedSummaries() async throws {
    let cursor = "opaque:日本語/+=="
    try await withHistoryPeer(options: ["pages": .object([
        "": historyPage([historyTurn("native-3"), historyTurn("native-2", "interrupted")], next: cursor),
        cursor: historyPage([historyTurn("native-1", "failed")])])]) { peer in
        let first = try await peer.session.historyPage(threadID: "native-source", limit: 2)
        let second = try await peer.session.historyPage(threadID: "native-source", cursor: first.nextCursor, limit: 2)
        #expect(first.nextCursor == cursor)
        #expect(first.turns.map(\.status) == [.completed, .interrupted])
        #expect(second.turns.map(\.status) == [.failed] && second.nextCursor == nil)
        let requests = try peer.requests("thread/turns/list")
        #expect(requests.count == 2)
        #expect(requests.last?["params"]["cursor"] == .string(cursor))
        for request in requests {
            #expect(request["params"]["threadId"] == .string("native-source"))
            #expect(request["params"]["limit"] == .number(2))
            #expect(request["params"]["sortDirection"] == .string("desc"))
            #expect(request["params"]["itemsView"] == .string("summary"))
        }
        let count = requests.count
        for limit in [0, 101] {
            try await historyError(.invalidRequest) { _ = try await peer.session.historyPage(threadID: "native-source", limit: limit) }
        }
        #expect(try peer.requests("thread/turns/list").count == count)
        try peer.assertNoImplicitWork()
    }
}

@Test(.timeLimit(.minutes(1)), arguments: [ProviderHistoryBoundary.head, .throughTurn("native-2"), .beforeTurn("native-2")])
func codexHistoryForkUsesExactBoundaryAndDefersEveryGoal(boundary: ProviderHistoryBoundary) async throws {
    try await withHistoryPeer { peer in
        let source = try peer.source
        let result = try await peer.session.forkConversation(source: source, boundary: boundary, configuration: peer.configuration)
        #expect(result.reference.nativeThreadID == "native-fork")
        #expect(result.reference != source && result.workspacePath == peer.workspace.path)
        let expected = switch boundary {
        case .head: "native-3"
        case .throughTurn: "native-2"
        case .beforeTurn: "native-1"
        case .throughClaudeMessage, .freshClaudeSession: throw ProviderHistoryError(.unsupported)
        }
        #expect(result.headTurnID == expected)
        let request = try #require(peer.requests("thread/fork").first)
        let params = request["params"]
        #expect(params["threadId"] == .string("native-source"))
        #expect(params["cwd"] == .string(peer.workspace.path))
        #expect(params["model"] == .string("reviewed-model"))
        #expect(params["approvalPolicy"] == .string("on-request"))
        #expect(params["approvalsReviewer"] == .string("auto_review"))
        #expect(params["sandbox"] == .string("workspace-write"))
        #expect(params["excludeTurns"] == .bool(true) && params["deferGoalContinuation"] == .bool(true))
        #expect(params["ephemeral"] == .bool(false))
        switch boundary {
        case .head: #expect(params.object?["lastTurnId"] == nil && params.object?["beforeTurnId"] == nil)
        case .throughTurn(let id): #expect(params["lastTurnId"] == .string(id) && params.object?["beforeTurnId"] == nil)
        case .beforeTurn(let id): #expect(params["beforeTurnId"] == .string(id) && params.object?["lastTurnId"] == nil)
        case .throughClaudeMessage, .freshClaudeSession: throw ProviderHistoryError(.unsupported)
        }
        try await historyError(.notIdle) { _ = try await peer.session.forkConversation(source: source, boundary: .head, configuration: peer.configuration) }
        #expect(try peer.requests("thread/fork").count == 1)
        try peer.assertNoImplicitWork()
    }
}

@Test(.timeLimit(.minutes(1)))
func codexHistoryForkFindsSelectedBoundaryAcrossPages() async throws {
    let turns = [historyTurn("native-3"), historyTurn("native-2", "interrupted"), historyTurn("native-1", "failed")]
    try await withHistoryPeer(options: ["turns": .array(turns), "pages": .object([
        "": historyPage([turns[0]], next: "review-page-2"),
        "review-page-2": historyPage(Array(turns.dropFirst()))])]) { peer in
        let result = try await peer.session.forkConversation(source: peer.source, boundary: .throughTurn("native-1"), configuration: peer.configuration)
        #expect(result.headTurnID == "native-1")
        #expect(try peer.requests("thread/turns/list").contains { $0["params"]["cursor"] == .string("review-page-2") })
        #expect(try peer.requests("thread/fork").first?["params"]["lastTurnId"] == .string("native-1"))
        try peer.assertNoImplicitWork()
    }
}

@Test(.timeLimit(.minutes(1)), arguments: ["inProgress", "futureStatus", "missing"])
func codexHistoryForkRejectsUnprovenSelectedBoundary(status: String) async throws {
    let turns = status == "missing" ? [historyTurn("other-native-turn")] : [historyTurn("selected", status)]
    try await withHistoryPeer(options: ["turns": .array(turns)]) { peer in
        try await historyError(.boundaryUnavailable) {
            _ = try await peer.session.forkConversation(source: peer.source, boundary: .throughTurn("selected"), configuration: peer.configuration)
        }
        #expect(try peer.requests("thread/fork").isEmpty)
        try peer.assertNoImplicitWork()
    }
}

@Test(.timeLimit(.minutes(1)), arguments: ["cycle", "empty", "duplicate", "overfull"])
func codexHistoryBoundaryScanRejectsInvalidPagination(kind: String) async throws {
    let pages: [String: JSONValue]
    switch kind {
    case "cycle": pages = ["": historyPage([historyTurn("one")], next: "same"), "same": historyPage([historyTurn("two")], next: "same")]
    case "empty": pages = ["": historyPage([], next: "nonempty-cursor")]
    case "duplicate": pages = ["": historyPage([historyTurn("one")], next: "two"), "two": historyPage([historyTurn("one")])]
    default: pages = ["": historyPage((0..<101).map { historyTurn("native-\($0)") })]
    }
    try await withHistoryPeer(options: ["pages": .object(pages)]) { peer in
        try await historyError(.invalidResponse) { _ = try await peer.session.forkConversation(source: peer.source, boundary: .throughTurn("never-present"), configuration: peer.configuration) }
        #expect(try peer.requests("thread/turns/list").count <= 2)
        #expect(try peer.requests("thread/fork").isEmpty)
        try peer.assertNoImplicitWork()
    }
}

@Test(.timeLimit(.minutes(1)))
func codexHistoryBoundaryScanStopsAtOneHundredPages() async throws {
    try await withHistoryPeer(options: ["infinitePages": .bool(true)]) { peer in
        try await historyError(.limitExceeded) { _ = try await peer.session.forkConversation(source: peer.source, boundary: .throughTurn("never-present"), configuration: peer.configuration) }
        #expect(try peer.requests("thread/turns/list").count == 100)
        #expect(try peer.requests("thread/fork").isEmpty)
        try peer.assertNoImplicitWork()
    }
}

@Test(.timeLimit(.minutes(1)), arguments: ["unknownProfile", "legacy", "unsupportedMethod", "rejectedBoundary"])
func codexHistoryUnsupportedContractsNeverDropSelectedBoundary(kind: String) async throws {
    var options: [String: JSONValue] = [:]
    switch kind {
    case "unknownProfile": options["userAgent"] = .string("codex_cli_rs/0.165.0")
    case "legacy": options["historyMode"] = .string("legacy")
    default: options["methodErrors"] = .object(["thread/fork": .object(["code": .number(kind == "unsupportedMethod" ? -32601 : -32602), "message": .string("Unsupported exact boundary")])])
    }
    try await withHistoryPeer(options: options) { peer in
        let capabilities = try await peer.session.historyCapabilities(threadID: "native-source")
        if kind == "unknownProfile" || kind == "legacy" {
            #expect(!capabilities.canRead && !capabilities.canForkHead && !capabilities.canForkFromTurn && !capabilities.canRevertBeforeTurn)
        }
        try await historyError(.unsupported) { _ = try await peer.session.forkConversation(source: peer.source, boundary: .beforeTurn("native-2"), configuration: peer.configuration) }
        let attempts = try peer.requests("thread/fork")
        #expect(attempts.count == (kind == "unknownProfile" || kind == "legacy" ? 0 : 1))
        for attempt in attempts { #expect(attempt["params"]["beforeTurnId"] == .string("native-2")) }
        try peer.assertNoImplicitWork()
    }
}

@Test(.timeLimit(.minutes(1)), arguments: ["null", "paused", "complete"])
func codexHistoryRevertRequiresReviewedHeadAndSafeGoalWithoutTouchingFiles(goal: String) async throws {
    try await withHistoryPeer(options: goal == "null" ? [:] : ["goalStatus": .string(goal)]) { peer in
        let file = peer.workspace.appendingPathComponent("user-working-file.txt")
        let contents = Data("User edits remain intact.\n".utf8); try contents.write(to: file)
        let capabilities = try await peer.session.historyCapabilities(threadID: "native-source")
        #expect(capabilities.canRevertBeforeTurn)
        let result = try await peer.session.revertConversation(thread: peer.source, beforeTurnID: "native-2", expectedHeadTurnID: "native-3")
        let source = try peer.source
        #expect(result.reference == source && result.headTurnID == "native-1")
        #expect(try Data(contentsOf: file) == contents)
        let request = try #require(peer.requests("thread/revert").first)
        #expect(request["params"] == .object(["threadId": .string("native-source"), "beforeTurnId": .string("native-2")]))
        #expect(try peer.requests("thread/goal/get").count >= 2)
        try peer.assertNoImplicitWork()
    }
}

@Test(.timeLimit(.minutes(1)))
func codexHistoryMismatchedReadIdentityCannotAuthorizeMutation() async throws {
    try await withHistoryPeer(options: ["readOverrides": .object(["id": .string("unrelated-native-thread")])]) { peer in
        try await historyError(.invalidResponse) {
            _ = try await peer.session.forkConversation(source: peer.source, boundary: .throughTurn("native-2"), configuration: peer.configuration)
        }
        #expect(try peer.requests("thread/fork").isEmpty)
        #expect(try peer.requests("thread/revert").isEmpty)
        try peer.assertNoImplicitWork()
    }
}

@Test(.timeLimit(.minutes(1)), arguments: ["active", "blocked", "usageLimited", "budgetLimited", "unknown", "wrongThread", "malformed", "unsupported"])
func codexHistoryUnsafeOrUnprovenGoalCannotRevert(goal: String) async throws {
    var options: [String: JSONValue] = ["goalStatus": .string(goal)]
    if goal == "wrongThread" { options = ["goalStatus": .string("paused"), "goalThreadID": .string("another-native-thread")] }
    if goal == "malformed" { options = ["goalReply": .object(["goal": .object(["threadId": .string("native-source"), "status": .string("paused")])])] }
    if goal == "unsupported" { options = ["methodErrors": .object(["thread/goal/get": .object(["code": .number(-32601), "message": .string("No goal evidence")])])] }
    try await withHistoryPeer(options: options) { peer in
        let capabilities = try await peer.session.historyCapabilities(threadID: "native-source")
        #expect(capabilities.canRead && !capabilities.canRevertBeforeTurn)
        try await historyError(goal == "unsupported" ? .unsupported : .unsafeGoal) {
            _ = try await peer.session.revertConversation(thread: peer.source, beforeTurnID: "native-2", expectedHeadTurnID: "native-3")
        }
        #expect(try peer.requests("thread/revert").isEmpty)
        try peer.assertNoImplicitWork()
    }
}

@Test(.timeLimit(.minutes(1)), arguments: ["notLoaded", "active", "systemError"])
func codexHistoryRevertNeverResumesOrMutatesANonIdleConversation(status: String) async throws {
    try await withHistoryPeer(options: ["threadStatus": .string(status)]) { peer in
        let capabilities = try await peer.session.historyCapabilities(threadID: "native-source")
        #expect(!capabilities.canRevertBeforeTurn)
        try await historyError(.notIdle) { _ = try await peer.session.revertConversation(thread: peer.source, beforeTurnID: "native-2", expectedHeadTurnID: "native-3") }
        #expect(try peer.requests("thread/revert").isEmpty)
        #expect(try peer.requests("thread/goal/get").isEmpty)
        try peer.assertNoImplicitWork()
    }
}

@Test(.timeLimit(.minutes(1)))
func codexHistoryStaleReviewedHeadAndChangedFinalEvidenceRejectBeforeMutation() async throws {
    try await withHistoryPeer { peer in
        try await historyError(.historyChanged) { _ = try await peer.session.revertConversation(thread: peer.source, beforeTurnID: "native-2", expectedHeadTurnID: "old-reviewed-head") }
        #expect(try peer.requests("thread/revert").isEmpty)
        let gate = peer.gate("goal")
        try peer.writeOptions(["gates": .object(["thread/goal/get": gate.value])])
        let request = Task {
            try await peer.session.revertConversation(thread: peer.source, beforeTurnID: "native-2", expectedHeadTurnID: "native-3")
        }
        try await historyEventually { FileManager.default.fileExists(atPath: gate.entered.path) }
        try peer.writeOptions(["turns": .array([historyTurn("new-unreviewed-head"), historyTurn("native-3"), historyTurn("native-2"), historyTurn("native-1")])])
        try Data().write(to: gate.release)
        try await historyError(.historyChanged) { _ = try await request.value }
        #expect(try peer.requests("thread/revert").isEmpty)
        try peer.assertNoImplicitWork()
    }
}

@Test(.timeLimit(.minutes(1)), arguments: ["wrongSource", "wrongWorkspace", "wrongHead", "disconnect"])
func codexHistoryUnconfirmedForkIsNeverRepeatedOrAdopted(kind: String) async throws {
    var options: [String: JSONValue] = [:]
    switch kind {
    case "wrongSource": options["mutationOverrides"] = .object(["forkedFromId": .string("another-native-source")])
    case "wrongWorkspace": options["mutationOverrides"] = .object(["cwd": .string("/tmp/another-workspace")])
    case "wrongHead": options["turns"] = .array([historyTurn("native-3"), historyTurn("native-2"), historyTurn("native-1")]); options["forkTurns"] = .array([historyTurn("unexpected-head")])
    default: options["disconnectMethods"] = .array([.string("thread/fork")])
    }
    try await withHistoryPeer(options: options) { peer in
        try await historyError(.outcomeUncertain) { _ = try await peer.session.forkConversation(source: peer.source, boundary: .throughTurn("native-2"), configuration: peer.configuration) }
        #expect(try peer.requests("thread/fork").count == 1)
        try await historyError(.outcomeUncertain) { try await peer.session.send(text: "Explicit submit after unconfirmed fork", thread: peer.thread) }
        try await historyError(.outcomeUncertain) { _ = try await peer.session.forkConversation(source: peer.source, boundary: .head, configuration: peer.configuration) }
        try await historyError(.outcomeUncertain) { _ = try await peer.session.revertConversation(thread: peer.source, beforeTurnID: "native-2", expectedHeadTurnID: "native-3") }
        #expect(try peer.requests("thread/fork").count == 1)
        #expect(try peer.requests("thread/revert").isEmpty)
        if kind != "disconnect" {
            let page = try await peer.session.historyPage(threadID: "native-source")
            #expect(page.turns.first?.id == "native-3")
        }
        try peer.assertNoImplicitWork()
    }
}

@Test(.timeLimit(.minutes(1)))
func codexHistorySourceRuntimeCannotForkOrBecomeRetargeted() async throws {
    try await withHistoryPeer(options: ["historyMode": .string("legacy")]) { peer in
        var iterator = peer.session.events.makeAsyncIterator()
        try await peer.session.send(text: "Explicit source turn one", thread: peer.thread)
        try await historyCompleted(&iterator)
        try await historyError(.notIdle) { _ = try await peer.session.forkConversation(source: peer.source, boundary: .head, configuration: peer.configuration) }
        try await peer.session.send(text: "Explicit source turn two", thread: peer.thread)
        try await historyCompleted(&iterator)
        #expect(try peer.requests("thread/fork").isEmpty)
        let starts = try peer.requests("turn/start")
        #expect(starts.count == 2)
        #expect(starts.allSatisfy { $0["params"]["threadId"] == .string("native-source") })
        let resumes = try peer.requests("thread/resume")
        #expect(resumes.count == 1)
        #expect(resumes.allSatisfy { $0["params"].object?["historyMode"] == nil })
        #expect(try peer.requests("thread/start").isEmpty)
        let capabilities = try await peer.session.historyCapabilities(threadID: "native-source")
        #expect(capabilities.historyMode == .legacy && !capabilities.canRead)
    }
}

@Test(.timeLimit(.minutes(1)), arguments: [true, false])
func codexHistoryOnlyReviewedProfileCreatesNewThreadsWithPaginatedHistory(reviewed: Bool) async throws {
    var options: [String: JSONValue] = ["historyMode": .string("legacy")]
    if !reviewed { options["userAgent"] = .string("codex_cli_rs/0.165.0") }
    try await withHistoryPeer(options: options) { peer in
        var thread = peer.thread; thread.providerThreadID = nil
        var iterator = peer.session.events.makeAsyncIterator()
        try await peer.session.send(text: "Explicit first native turn", thread: thread)
        try await historyCompleted(&iterator)
        let requests = try peer.requests("thread/start")
        #expect(requests.count == 1)
        let request = try #require(requests.first)
        if reviewed {
            #expect(request["params"]["historyMode"] == .string("paginated"))
            let capabilities = try await peer.session.historyCapabilities(threadID: "native-source")
            #expect(capabilities.historyMode == .paginated && capabilities.canRead)
        } else {
            #expect(request["params"].object?["historyMode"] == nil)
        }
        #expect(try peer.requests("thread/resume").isEmpty)
        #expect(try peer.requests("turn/start").count == 1)
    }
}

@Test(.timeLimit(.minutes(1)))
func codexHistoryFreshTargetAdoptsOnlyVerifiedForkForLaterExplicitSubmit() async throws {
    try await withHistoryPeer { peer in
        let snapshot = try await peer.session.forkConversation(source: peer.source, boundary: .beforeTurn("native-2"), configuration: peer.configuration)
        #expect(try peer.requests("turn/start").isEmpty)
        var iterator = peer.session.events.makeAsyncIterator()
        var target = peer.thread; target.providerThreadID = snapshot.reference.nativeThreadID
        try await peer.session.send(text: "Explicit new fork turn", thread: target)
        try await historyCompleted(&iterator)
        #expect(try peer.requests("thread/resume").isEmpty)
        #expect(try peer.requests("thread/start").isEmpty)
        #expect(try peer.requests("turn/start").first?["params"]["threadId"] == .string("native-fork"))
    }
}

@Test(.timeLimit(.minutes(1)))
func codexHistoryRewindFencesAnOlderDelayedStartAcknowledgementBeforeTheNextCompletion() async throws {
    try await withHistoryPeer { peer in
        let gate = peer.gate("old-start-ack")
        try peer.writeOptions([
            "delayedFirstStartAcknowledgement": gate.value,
            "completionBeforeStartAcknowledgement": .bool(true),
            "turns": .array([historyTurn("explicit-turn-1"), historyTurn("native-2"), historyTurn("native-1")])])
        let observed = HistoryObservedEvents()
        let observer = Task { for await event in peer.session.events { await observed.append(event) } }
        defer { observer.cancel() }
        let firstRunID = UUID()
        let first: CodingThread = {
            var thread = peer.thread
            thread.activeRun = .init(id: firstRunID, configuration: peer.configuration, startedAt: Date())
            return thread
        }()
        let oldSend = Task { try await peer.session.send(text: "Old explicit turn", thread: first) }
        try await historyEventually {
            guard FileManager.default.fileExists(atPath: gate.entered.path) else { return false }
            return await observed.values.contains { event in
                if case .context(let runID, .completed(.idle)) = event { return runID == firstRunID }
                return false
            }
        }
        #expect(FileManager.default.fileExists(atPath: gate.entered.path))
        #expect(!FileManager.default.fileExists(atPath: gate.release.path))
        let rewound = try await peer.session.revertConversation(thread: peer.source, beforeTurnID: "native-2", expectedHeadTurnID: "explicit-turn-1")
        #expect(rewound.headTurnID == "native-1")
        #expect(try peer.requests("thread/revert").count == 1)
        try Data().write(to: gate.release)
        // The read-only request flushes the released response in the peer; awaiting
        // oldSend then proves its suspended send frame has processed that old ACK.
        _ = try await peer.session.models()
        try await oldSend.value
        var next = peer.thread
        let nextRunID = UUID()
        next.activeRun = .init(id: nextRunID, configuration: peer.configuration, startedAt: Date())
        try await peer.session.send(text: "Next explicit turn", thread: next)
        try await historyEventually {
            await observed.values.contains { event in
                if case .context(let runID, .completed(.idle)) = event { return runID == nextRunID }
                return false
            }
        }
        let events = await observed.values
        let completions = events.compactMap { event -> UUID? in
            if case .context(let runID, .completed(.idle)) = event { return runID }; return nil
        }
        let turns = events.compactMap { event -> String? in
            if case .turn(let id) = historyUnscoped(event) { return id }; return nil
        }
        #expect(completions == [firstRunID, nextRunID])
        #expect(turns == ["explicit-turn-1", "explicit-turn-2"])
        #expect(try peer.requests("turn/start").count == 2)
        #expect(try peer.requests("thread/resume").count == 1)
        #expect(try peer.requests("thread/start").isEmpty)
    }
}


@Test(.timeLimit(.minutes(1)), arguments: ["snapshot", "fork", "revert"])
func codexHistoryNormalizesNativePrivateVarAliasAtMetadataIngress(operation: String) async throws {
    try await withHistoryPeer { peer in
        // Resolve the existing task-owned directory just as Models does. Darwin
        // Foundation need not normalize a nonexistent leaf's /private/var alias.
        let canonical = WorkspaceProject(path: peer.workspace.path).path
        let alias = canonical.hasPrefix("/var/") ? "/private" + canonical : canonical
        try peer.writeOptions(["readOverrides": .object(["cwd": .string(alias)]),
                               "mutationOverrides": .object(["cwd": .string(alias)])])
        let source = try peer.source
        let result: ProviderConversationSnapshot
        switch operation {
        case "fork":
            var configuration = peer.configuration; configuration.workspacePath = canonical
            result = try await peer.session.forkConversation(source: source, boundary: .throughTurn("native-2"), configuration: configuration)
            #expect(result.reference.nativeThreadID == "native-fork" && result.headTurnID == "native-2")
            #expect(try peer.requests("thread/fork").first?["params"]["cwd"] == .string(canonical))
        case "revert":
            result = try await peer.session.revertConversation(thread: source, beforeTurnID: "native-2", expectedHeadTurnID: "native-3")
            #expect(result.reference == source && result.headTurnID == "native-1")
        default:
            result = try await peer.session.conversationSnapshot(threadID: "native-source")
            #expect(result.reference == source && result.headTurnID == "native-3")
        }
        #expect(result.workspacePath == canonical)
        try peer.assertNoImplicitWork()
    }
}

@Test func codexReviewedProfileGateIncludesOnlyTheReviewedStable164Version() {
    for prefix in ["coincide", "codex_cli_rs", "codex"] {
        #expect(CodexHistoryClient.reviewedProfileIdentifier(for: prefix + "/0.164.0 (macos; arm64)") == "codex-0.164.0")
        #expect(CodexHistoryClient.reviewedProfileIdentifier(for: prefix + "/0.163.0") == "codex-0.163")
    }
    for userAgent in ["coincide/0.164.1", "coincide/0.164.0-alpha.1", "coincide/0.164.01", "coincide/0.165.0", "unreviewed/0.164.0", "prefix coincide/0.164.0", "coincide/0.164.0" + String(repeating: "x", count: 4_096)] {
        #expect(CodexHistoryClient.reviewedProfileIdentifier(for: userAgent) == nil)
    }
    #expect(CodexHistoryClient.reviewedProfileIdentifier(for: nil) == nil)
}

@Test(.timeLimit(.minutes(1)))
func codex164HistoryFixturePreservesExactForkAndRevertContractsWithoutImplicitTurns() async throws {
    try await withHistoryPeer(options: ["userAgent": .string("coincide/0.164.0 (macos; arm64)"), "cliVersion": .string("0.164.0")]) { peer in
        let capabilities = try await peer.session.historyCapabilities(threadID: "native-source")
        #expect(capabilities.canRead && capabilities.canForkFromTurn && capabilities.canRevertBeforeTurn)
        let source = try peer.source
        let fork = try await peer.session.forkConversation(source: source, boundary: .throughTurn("native-2"), configuration: peer.configuration)
        #expect(fork.reference != source && fork.headTurnID == "native-2")
        let forkRequest = try #require(peer.requests("thread/fork").first)
        #expect(forkRequest["params"]["lastTurnId"] == .string("native-2"))
        #expect(forkRequest["params"]["deferGoalContinuation"] == .bool(true))
        #expect(forkRequest["params"].object?["experimentalPredictionMode"] == nil)
        #expect(forkRequest["params"].object?["experimentalDisablePredictionMcp"] == nil)
        // A successful fork binds this actor to its new target. It must never
        // retarget back to the source, even while both conversations are idle.
        try await historyError(.notIdle) {
            _ = try await peer.session.revertConversation(thread: source, beforeTurnID: "native-3", expectedHeadTurnID: "native-3")
        }
        #expect(try peer.requests("thread/revert").isEmpty)
        let reverted = try await peer.session.revertConversation(thread: fork.reference, beforeTurnID: "native-2", expectedHeadTurnID: "native-2")
        #expect(reverted.reference == fork.reference && reverted.headTurnID == "native-1")
        let revertRequest = try #require(peer.requests("thread/revert").first)
        #expect(revertRequest["params"] == .object(["threadId": .string(fork.reference.nativeThreadID), "beforeTurnId": .string("native-2")]))
        try peer.assertNoImplicitWork()
    }
}
