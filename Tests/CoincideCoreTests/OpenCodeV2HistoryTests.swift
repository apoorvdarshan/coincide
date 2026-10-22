import Foundation
import Testing
@testable import CoincideCore

private let historyRootID = "ses_history_root"
private let historyDirectory = URL(fileURLWithPath: "/fixture/opencode-history")

private func historyMessage(_ id: String, _ type: String = "user", text: String = "Synthetic private history 日本語",
                            fields: [String: JSONValue] = [:]) -> JSONValue {
    var value: [String: JSONValue] = ["id": .string(id), "type": .string(type), "time": .object(["created": .number(1)]), "text": .string(text)]
    for (key, item) in fields { value[key] = item }
    return .object(value)
}
private func historyAssistant(_ id: String, text: String = "Exact completed answer") -> JSONValue {
    historyMessage(id, "assistant", fields: ["agent": .string("build"), "model": .object(["providerID": .string("synthetic"), "id": .string("model")]),
        "time": .object(["created": .number(2), "completed": .number(3)]), "content": .array([.object(["type": .string("text"), "text": .string(text)])])])
}
private func historyIdle(_ id: String) -> JSONValue {
    historyMessage(id, "idle", fields: ["outcome": .string("succeeded")])
}
private func historyRows() -> [JSONValue] {
    [historyMessage("msg_first"), historyAssistant("msg_answer_first"),
     historyMessage("msg_steer_first", text: "Same original run additional input"), historyAssistant("msg_answer_steered"), historyIdle("msg_idle_first"),
     historyMessage("msg_second"), historyAssistant("msg_answer_second"), historyIdle("msg_idle_second")]
}
private func historyHTTP(_ value: JSONValue, status: Int = 200, contentType: String = "application/json") throws -> OpenCodeHTTPResponse {
    .init(status: status, headers: ["content-type": contentType], body: try JSONEncoder().encode(value))
}
private struct HistoryRequest: Sendable {
    let method: String
    let path: [String]
    let query: [URLQueryItem]
    let body: JSONValue?
}
private actor HistoryTransport: OpenCodeV2SessionTransport {
    struct NativeSession: Sendable {
        var messages: [JSONValue]
        var stage: JSONValue = .null
        var fork: JSONValue = .null
        var parent: String?
    }
    private let stream = AsyncThrowingStream<OpenCodeSSEEvent, any Error>.makeStream()
    var sessions: [String: NativeSession] = [historyRootID: .init(messages: historyRows())]
    var requests: [HistoryRequest] = []
    var pageSize = 2
    var active: Set<String> = []
    var pending: Set<String> = []
    var failStage = false
    var failCommit = false
    var commitThenLoseACK = false
    var holdClearTerminal = false
    var loseClearACK = false
    var wrongClearTerminal = false
    var clearWork: (String, String, String)?
    var heldStage: CheckedContinuation<OpenCodeHTTPResponse, any Error>?
    var holdStage = false
    var stageCancelled = false
    private var closed = false
    func connect() async throws -> AsyncThrowingStream<OpenCodeSSEEvent, any Error> { stream.stream }
    func inventory(directory: URL) async throws -> OpenCodeMetadataSnapshot { throw ProviderHistoryError(.unsupported) }
    func request(method: String, path: [String], body: JSONValue?) async throws -> OpenCodeHTTPResponse {
        try await request(method: method, path: path, query: [], body: body)
    }
    func request(method: String, path: [String], query: [URLQueryItem], body: JSONValue?) async throws -> OpenCodeHTTPResponse {
        guard !closed else { throw CancellationError() }
        requests.append(.init(method: method, path: path, query: query, body: body))
        if path == ["api", "session", "active"] {
            return try historyHTTP(.object(["data": .object(active.reduce(into: [:]) { $0[$1] = .object(["type": .string("running")]) })]))
        }
        if path == ["api", "session"] {
            let parent = query.first { $0.name == "parentID" }?.value
            let children = sessions.filter { $0.value.parent == parent && parent != nil }.map { id, _ in
                JSONValue.object(["id": .string(id), "parentID": .string(parent!)])
            }
            return try historyHTTP(.object(["data": .array(children), "cursor": .object([:])]))
        }
        guard path.count >= 3, let source = sessions[path[2]] else { return try historyHTTP(.object([:]), status: 404) }
        let id = path[2], tail = Array(path.dropFirst(3))
        if tail.isEmpty { return try info(id) }
        if ["inbox", "permission", "form"].contains(tail.first ?? "") {
            return try historyHTTP(.object(["data": .array(pending.contains(id + ":" + tail[0]) ? [.object(["synthetic": .bool(true)])] : [])]))
        }
        if tail == ["message"] {
            let cursor = query.first { $0.name == "cursor" }?.value
            let offset = cursor.flatMap { Int($0.replacingOccurrences(of: "opaque cursor +/", with: "")) } ?? 0
            let values = Array(source.messages.dropFirst(offset).prefix(pageSize))
            return try historyHTTP(.object(["data": .array(values), "cursor": .object(values.isEmpty ? [:] :
                ["next": .string("opaque cursor +/\(offset + values.count)")])]))
        }
        if tail == ["fork"], method == "POST" {
            let cut = body?["before"].string
            let count = cut.flatMap { selected in source.messages.firstIndex { $0["id"].string == selected } } ?? source.messages.count
            let copied = Array(source.messages.prefix(count)), target = "ses_history_fork"
            let mapping = Dictionary(uniqueKeysWithValues: copied.enumerated().map { ($0.element["id"].string!, "msg_clone_\($0.offset)") })
            let clones = copied.map { original -> JSONValue in
                var object = original.object!; object["id"] = .string(mapping[original["id"].string!]!)
                if original["type"] == .string("compaction"), let keep = original["metadata"]["keepID"].string {
                    var metadata = original["metadata"].object!; metadata["keepID"] = .string(mapping[keep]!)
                    object["metadata"] = .object(metadata)
                }
                return .object(object)
            }
            let boundary: JSONValue = .object(["type": .string(cut == nil ? "through" : "before"),
                "messageID": .string(cut ?? source.messages.last!["id"].string!)])
            sessions[target] = .init(messages: clones, fork: .object(["sessionID": .string(id), "boundary": boundary]))
            return try info(target)
        }
        if tail == ["revert", "stage"], method == "POST" {
            let stage = JSONValue.object(["messageID": body?["messageID"] ?? .null, "snapshot": .string("synthetic_snapshot"), "files": .array([])])
            sessions[id]?.stage = stage
            if failStage { throw CoincideError("Synthetic private stage reply was lost.") }
            if holdStage {
                return try await withTaskCancellationHandler {
                    try Task.checkCancellation()
                    return try await withCheckedThrowingContinuation { heldStage = $0 }
                } onCancel: { Task { await self.cancelStage() } }
            }
            return try historyHTTP(.object(["data": stage]))
        }
        if tail == ["revert", "commit"], method == "POST" {
            if failCommit { return try historyHTTP(.object(["private": .string("synthetic-private-token")]), status: 500) }
            let cut = source.stage["messageID"].string!
            sessions[id]?.messages = Array(source.messages.prefix { $0["id"].string != cut }); sessions[id]?.stage = .null
            if commitThenLoseACK { throw CoincideError("Synthetic private commit reply was lost.") }
            return .init(status: 204, headers: [:], body: Data())
        }
        if tail == ["revert"], method == "DELETE" {
            sessions[id]?.stage = .null
            let start = "evt_maintenance_start", end = "evt_maintenance_terminal"
            clearWork = (id, start, end); active.insert(id)
            emit("session.execution.started", id: start, sessionID: id)
            if !holdClearTerminal { settleClear() }
            if loseClearACK { throw CoincideError("Synthetic private clear reply was lost.") }
            return .init(status: 204, headers: [:], body: Data())
        }
        if tail == ["interrupt"] { return try historyHTTP(.object(["interrupted": .bool(false)])) }
        throw ProviderHistoryError(.invalidRequest)
    }
    func settleClear() {
        guard let (id, _, end) = clearWork else { return }; clearWork = nil; active.remove(id)
        sessions[id]?.messages.append(historyIdle("msg_" + end.dropFirst(4)))
        emit("session.execution.succeeded", id: end, sessionID: wrongClearTerminal ? "ses_foreign" : id)
    }
    private func emit(_ type: String, id: String, sessionID: String) {
        let value = JSONValue.object(["id": .string(id), "type": .string(type), "data": .object(["sessionID": .string(sessionID)])])
        guard let bytes = try? JSONEncoder().encode(value) else { return }
        stream.continuation.yield(.init(event: "message", data: String(decoding: bytes, as: UTF8.self), id: id, retryMilliseconds: nil))
    }
    private func info(_ id: String) throws -> OpenCodeHTTPResponse {
        let value = sessions[id]!
        return try historyHTTP(.object(["data": .object(["id": .string(id), "location": .object(["directory": .string(historyDirectory.path)]),
            "parentID": value.parent.map(JSONValue.string) ?? .null, "revert": value.stage, "fork": value.fork])]))
    }
    func update(_ change: @Sendable (inout SelfState) -> Void) {
        var value = SelfState(failStage: failStage, failCommit: failCommit, commitThenLoseACK: commitThenLoseACK,
            holdClearTerminal: holdClearTerminal, loseClearACK: loseClearACK, wrongClearTerminal: wrongClearTerminal, holdStage: holdStage)
        change(&value)
        failStage = value.failStage; failCommit = value.failCommit; commitThenLoseACK = value.commitThenLoseACK
        holdClearTerminal = value.holdClearTerminal; loseClearACK = value.loseClearACK; wrongClearTerminal = value.wrongClearTerminal; holdStage = value.holdStage
    }
    struct SelfState: Sendable {
        var failStage: Bool; var failCommit: Bool; var commitThenLoseACK: Bool
        var holdClearTerminal: Bool; var loseClearACK: Bool; var wrongClearTerminal: Bool; var holdStage: Bool
    }
    func makeBusy(_ kind: String) {
        if kind == "child" {
            sessions["ses_child"] = .init(messages: [], parent: historyRootID); active.insert("ses_child")
        } else if kind == "root" { active.insert(historyRootID) }
        else { pending.insert(historyRootID + ":" + kind) }
    }
    func setStage(_ stage: JSONValue) { sessions[historyRootID]?.stage = stage }
    func cancelStage() { stageCancelled = true; heldStage?.resume(throwing: CancellationError()); heldStage = nil }
    func close() async { closed = true; cancelStage(); stream.continuation.finish() }
}

private func withHistoryPeer(_ body: (OpenCodeV2Session, HistoryTransport, OpenCodeConfiguration) async throws -> Void) async throws {
    let transport = HistoryTransport(), config = OpenCodeConfiguration(executable: "synthetic-opencode")
    let session = OpenCodeV2Session(cwd: historyDirectory, configuration: config, transport: transport)
    do { try await body(session, transport, config); await session.close() }
    catch { await session.close(); throw error }
}
private func historyCapture(_ config: OpenCodeConfiguration) -> ProviderConfiguration {
    var thread = CodingThread(project: .init(path: historyDirectory.path)); thread.provider = .opencode; thread.openCodeConfiguration = config
    thread.providerThreadID = historyRootID; return .init(thread: thread)
}
private func historyReview(_ source: OpenCodeV2HistorySnapshot, selected: String = "msg_second") throws -> OpenCodeV2HistoryReviewEvidence {
    try .init(source: source, boundary: .beforeMessage("msg_second"), retainedMessageCount: 5, selectedOpeningMessageID: selected,
        inputs: [.init(runID: UUID(), openingMessageID: "msg_first", steeringMessageIDs: ["msg_steer_first"]), .init(runID: UUID(), openingMessageID: "msg_second")])
}
private func historyEventually(_ condition: () async throws -> Bool) async throws {
    let deadline = ContinuousClock.now + .seconds(8)
    while !(try await condition()) {
        guard ContinuousClock.now < deadline else { throw CoincideError("The synthetic native history boundary was not observed.") }
        try await Task.sleep(for: .milliseconds(10))
    }
}

@Test func openCodeV2HistoryWireCloneDigestRemovesOnlyNativeChangedIDsAndNormalizesCompactionKeepReference() throws {
    let first = historyMessage("msg_original"), compact = historyMessage("msg_compact", "compaction", fields: [
        "reason": .string("auto"), "status": .string("completed"), "summary": .string("Synthetic private summary"),
        "metadata": .object(["keepID": .string("msg_original"), "private": .string("synthetic-private-token")])])
    var clone = first.object!, clonedCompact = compact.object!, metadata = compact["metadata"].object!
    clone["id"] = .string("msg_clone"); clonedCompact["id"] = .string("msg_clone_compact"); metadata["keepID"] = .string("msg_clone"); clonedCompact["metadata"] = .object(metadata)
    let a = try OpenCodeV2HistoryWire.records([first, compact]), b = try OpenCodeV2HistoryWire.records([.object(clone), .object(clonedCompact)])
    #expect(a.map(\.id) != b.map(\.id) && a.map(\.contentDigest) == b.map(\.contentDigest))
    metadata["private"] = .string("Changed native value"); clonedCompact["metadata"] = .object(metadata)
    let changed = try OpenCodeV2HistoryWire.records([.object(clone), .object(clonedCompact)])
    #expect(changed.last?.contentDigest != a.last?.contentDigest)
    let encoded = try JSONEncoder().encode(a)
    #expect(!String(decoding: encoded, as: UTF8.self).contains("synthetic-private-token"))
    metadata["keepID"] = .string("msg_foreign"); clonedCompact["metadata"] = .object(metadata)
    #expect(throws: (any Error).self) { try OpenCodeV2HistoryWire.records([.object(clone), .object(clonedCompact)]) }
}

@Test func openCodeV2HistoryWireCursorAndSettledRecordsRejectUnknownMalformedOrUnboundedEvidence() throws {
    for cursor in [JSONValue.object([:]), .object(["next": .null, "previous": .null])] {
        let response = try historyHTTP(.object(["data": .array([]), "cursor": cursor]))
        #expect(try OpenCodeV2HistoryWire.page(response).next == nil)
    }
    for response in [try historyHTTP(.object(["data": .array([]), "cursor": .object(["next": .number(42)])])),
        try historyHTTP(.object(["data": .array([]), "cursor": .object([:])]), status: 503),
        try historyHTTP(.object(["data": .array([]), "cursor": .object([:])]), contentType: "text/html")] {
        #expect(throws: (any Error).self) { try OpenCodeV2HistoryWire.page(response) }
    }
    let assistant = historyAssistant("msg_completed")
    var running = assistant.object!; running["time"] = .object(["created": .number(1)])
    let records = try OpenCodeV2HistoryWire.records([assistant, .object(running.merging(["id": .string("msg_running")]) { _, new in new })])
    #expect(records.map(\.isSettled) == [true, false])
    for rows in [[historyMessage("msg_unknown", "unknown")], [historyMessage("msg_same"), historyMessage("msg_same")],
                 [historyMessage("msg_no_time", fields: ["time": .null])]] {
        #expect(throws: (any Error).self) { try OpenCodeV2HistoryWire.records(rows) }
    }
    let large = OpenCodeHTTPResponse(status: 200, headers: ["content-type": "application/json"],
        body: Data(repeating: 32, count: OpenCodeV2HistoryWire.maximumPageBytes + 1))
    #expect(throws: (any Error).self) { try OpenCodeV2HistoryWire.page(large) }
    #expect(throws: ProviderHistoryError(.limitExceeded)) {
        try OpenCodeV2HistoryWire.records(Array(repeating: historyMessage("msg_overflow"), count: OpenCodeV2HistoryWire.maximumMessages + 1))
    }
}

@Test func openCodeV2HistoryNativeDirectoryAliasesRequireTheSameExistingPhysicalIdentity() throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("coincide-history-alias-" + UUID().uuidString, isDirectory: true)
    defer { try? FileManager.default.removeItem(at: root) }
    let directory = root.appendingPathComponent("directory", isDirectory: true), other = root.appendingPathComponent("other", isDirectory: true)
    let alias = root.appendingPathComponent("alias", isDirectory: true)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
    try FileManager.default.createDirectory(at: other, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
    try FileManager.default.createSymbolicLink(at: alias, withDestinationURL: directory)
    let response = try historyHTTP(.object(["data": .object(["id": .string(historyRootID),
        "location": .object(["directory": .string(alias.path)])])]))
    _ = try OpenCodeV2HistoryWire.session(response, id: historyRootID, directory: directory.path)
    #expect(throws: (any Error).self) { try OpenCodeV2HistoryWire.session(response, id: historyRootID, directory: other.path) }
    let traversal = try historyHTTP(.object(["data": .object(["id": .string(historyRootID),
        "location": .object(["directory": .string(directory.path + "/../directory")])])]))
    #expect(throws: (any Error).self) { try OpenCodeV2HistoryWire.session(traversal, id: historyRootID, directory: directory.path) }
}

@Test func openCodeV2HistoryReadIsStablePaginatedAndNeverCreatesConfiguresOrPublishesPrivatePayloads() async throws {
    try await withHistoryPeer { session, peer, _ in
        let snapshot = try await session.openCodeV2HistorySnapshot(threadID: historyRootID)
        #expect(snapshot.messages.map(\.id) == historyRows().compactMap { $0["id"].string })
        #expect(snapshot.stage == nil && snapshot.reference.nativeThreadID == historyRootID)
        let requests = await peer.requests, pages = requests.filter { $0.path.last == "message" }
        #expect(pages.count == 10, "Each complete four-page inventory ends with an extra empty native page; snapshot reads twice.")
        for page in pages {
            let names = Set(page.query.map(\.name))
            #expect(names.contains("limit") && (names.contains("cursor") != names.contains("order")))
        }
        #expect(requests.allSatisfy { $0.method == "GET" })
        let bytes = try JSONEncoder().encode(snapshot)
        #expect(!String(decoding: bytes, as: UTF8.self).contains("Synthetic private history"))
    }
}

@Test func openCodeV2HistoryForkPreservesEntireSteeredRunWithRegeneratedNativeIDsAndSourceUnchanged() async throws {
    try await withHistoryPeer { session, peer, config in
        let source = try await session.openCodeV2HistorySnapshot(threadID: historyRootID), review = try historyReview(source, selected: "msg_first")
        let result = try await session.applyOpenCodeV2History(review: review, kind: .forkAfterRun, configuration: historyCapture(config))
        let fork = try #require(result.openCodeV2)
        #expect(result.headTurnID == nil && result.historyMode == .messageOrdered && fork.messages.count == 5)
        #expect(fork.contentDigest == review.retainedContentDigest && fork.messages.allSatisfy { $0.id.hasPrefix("msg_clone_") })
        let unchanged = try await session.openCodeV2HistorySnapshot(threadID: historyRootID)
        #expect(unchanged == source)
        let mutations = await peer.requests.filter { $0.method != "GET" }
        #expect(mutations.count == 1 && mutations.first?.path.last == "fork" && mutations.first?.body == .object(["before": .string("msg_second")]))
    }
}

@Test func openCodeV2HistoryRewindUsesLiteralFilesFalseAndConfirmsExactPrefixWithoutHiddenClear() async throws {
    try await withHistoryPeer { session, peer, config in
        let source = try await session.openCodeV2HistorySnapshot(threadID: historyRootID), review = try historyReview(source)
        let result = try await session.applyOpenCodeV2History(review: review, kind: .rewindBeforeRun, configuration: historyCapture(config))
        let observed = try #require(result.openCodeV2)
        #expect(observed.reference == source.reference && observed.messages == Array(source.messages.prefix(5)) && observed.stage == nil)
        let mutations = await peer.requests.filter { $0.method != "GET" }
        #expect(mutations.map { $0.path.last } == ["stage", "commit"])
        #expect(mutations.first?.body == .object(["messageID": .string("msg_second"), "files": .bool(false)]))
    }
}

@Test(arguments: ["root", "child", "inbox", "permission", "form"])
func openCodeV2HistoryRefusesNativeWorkIncludingFreshActorLinkedBackgroundBeforeAnyMutation(kind: String) async throws {
    try await withHistoryPeer { session, peer, _ in
        await peer.makeBusy(kind)
        await #expect(throws: ProviderHistoryError(.notIdle)) { try await session.openCodeV2HistorySnapshot(threadID: historyRootID) }
        #expect(await peer.requests.allSatisfy { $0.method == "GET" })
    }
}

@Test(arguments: [false, true])
func openCodeV2HistoryLostStageOrCommitReplyStaysUncertainWithoutReplayOrHiddenMaintenance(commit: Bool) async throws {
    try await withHistoryPeer { session, peer, config in
        let source = try await session.openCodeV2HistorySnapshot(threadID: historyRootID), review = try historyReview(source)
        await peer.update { $0.failStage = !commit; $0.commitThenLoseACK = commit }
        await #expect(throws: ProviderHistoryError(.outcomeUncertain)) {
            try await session.applyOpenCodeV2History(review: review, kind: .rewindBeforeRun, configuration: historyCapture(config))
        }
        let observed = try await session.openCodeV2HistorySnapshot(threadID: historyRootID)
        #expect(commit ? observed.stage == nil && observed.messages.count == 5 : observed.stage?.messageID == "msg_second" && observed.messages == source.messages)
        let mutations = await peer.requests.filter { $0.method != "GET" }
        #expect(mutations.filter { $0.path.last == "stage" }.count == 1)
        #expect(mutations.filter { $0.path.last == "commit" }.count == (commit ? 1 : 0))
        #expect(!mutations.contains { $0.method == "DELETE" })
    }
}

@Test func openCodeV2HistoryExplicitClearWaitsForOwnedEmptyTerminalThenPersistsOnlyItsExactIdleAppend() async throws {
    try await withHistoryPeer { session, peer, config in
        let source = try await session.openCodeV2HistorySnapshot(threadID: historyRootID), review = try historyReview(source)
        await peer.update { $0.failCommit = true; $0.holdClearTerminal = true }
        await #expect(throws: ProviderHistoryError(.outcomeUncertain)) {
            try await session.applyOpenCodeV2History(review: review, kind: .rewindBeforeRun, configuration: historyCapture(config))
        }
        let staged = try await session.openCodeV2HistorySnapshot(threadID: historyRootID)
        let probe = HistoryCompletion()
        let clear = Task { let result = try await session.clearOpenCodeV2HistoryStage(expected: staged); await probe.finish(); return result }
        do {
            try await historyEventually { await peer.requests.contains { $0.method == "DELETE" } }
            #expect(await probe.finished == false)
            await peer.settleClear()
            let result = try await clear.value, receipt = try #require(result.maintenance)
            #expect(receipt.priorInventoryDigest == staged.inventoryDigest && receipt.idleMessageID == "msg_maintenance_terminal")
            #expect(result.stage == nil && Array(result.messages.dropLast()) == source.messages)
            let fresh = try await session.openCodeV2HistorySnapshot(threadID: historyRootID)
            #expect(fresh.messages == result.messages && fresh.maintenance == nil, "Fresh inspection never invents a maintenance receipt.")
        } catch { clear.cancel(); await session.close(); _ = await clear.result; throw error }
    }
}

@Test func openCodeV2HistoryLostClearACKCanBeConfirmedOnlyFromExactOwnedTerminalAndReadBack() async throws {
    try await withHistoryPeer { session, peer, _ in
        await peer.setStage(.object(["messageID": .string("msg_second"), "files": .array([])]))
        let expected = try await session.openCodeV2HistorySnapshot(threadID: historyRootID)
        await peer.update { $0.loseClearACK = true }
        let result = try await session.clearOpenCodeV2HistoryStage(expected: expected)
        #expect(result.maintenance?.startEventID == "evt_maintenance_start" && result.messages.count == expected.messages.count + 1)
        #expect(await peer.requests.filter { $0.method == "DELETE" }.count == 1)
    }
}

@Test(arguments: [false, true])
func openCodeV2HistoryForeignClearTerminalNeverConfirmsAndCancellationOrCloseJoinsTheExactOperation(close: Bool) async throws {
    try await withHistoryPeer { session, peer, _ in
        await peer.setStage(.object(["messageID": .string("msg_second"), "files": .array([])]))
        let expected = try await session.openCodeV2HistorySnapshot(threadID: historyRootID)
        await peer.update { $0.wrongClearTerminal = true }
        let probe = HistoryCompletion()
        let clear = Task { let result = try await session.clearOpenCodeV2HistoryStage(expected: expected); await probe.finish(); return result }
        do {
            try await historyEventually { await peer.requests.contains { $0.method == "DELETE" } }
            #expect(await probe.finished == false)
            if close { await session.close() } else { clear.cancel() }
            var failure: ProviderHistoryError?
            do { _ = try await clear.value } catch let error as ProviderHistoryError { failure = error }
            #expect(failure == .init(.outcomeUncertain))
            #expect(await peer.requests.filter { $0.method == "DELETE" }.count == 1)
        } catch { clear.cancel(); await session.close(); _ = await clear.result; throw error }
    }
}

@Test func openCodeV2HistoryForeignOrFileAffectingStageIsNeverClearedAndCancellationDrainsOwnedStageRequest() async throws {
    try await withHistoryPeer { session, peer, config in
        let source = try await session.openCodeV2HistorySnapshot(threadID: historyRootID), review = try historyReview(source)
        await peer.setStage(.object(["messageID": .string("msg_second"), "files": .array([.object(["file": .string("foreign.txt")])])]))
        let foreign = try await session.openCodeV2HistorySnapshot(threadID: historyRootID)
        await #expect(throws: ProviderHistoryError(.invalidRequest)) { try await session.clearOpenCodeV2HistoryStage(expected: foreign) }
        #expect(await peer.requests.allSatisfy { $0.method == "GET" })
        await peer.setStage(.null); await peer.update { $0.holdStage = true }
        let mutation = Task { try await session.applyOpenCodeV2History(review: review, kind: .rewindBeforeRun, configuration: historyCapture(config)) }
        do {
            try await historyEventually { await peer.heldStage != nil }
            mutation.cancel()
            var failure: ProviderHistoryError?
            do { _ = try await mutation.value } catch let error as ProviderHistoryError { failure = error }
            let cancelled = await peer.stageCancelled
            #expect(failure == .init(.outcomeUncertain) && cancelled)
            #expect(await peer.requests.filter { $0.path.last == "stage" }.count == 1)
        } catch { mutation.cancel(); await session.close(); _ = await mutation.result; throw error }
    }
}

private actor HistoryCompletion {
    var finished = false
    func finish() { finished = true }
}
