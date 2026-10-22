import Foundation
import Testing
@testable import CoincideCore

private let v1HistoryRoot = "ses_v1_history_source"
private let v1HistoryDirectory = URL(fileURLWithPath: "/fixture/opencode-v1-history")

private func v1HistoryRow(_ id: String, parent: String? = nil, parts: [JSONValue]? = nil) -> JSONValue {
    var info: [String: JSONValue] = ["id": .string(id), "sessionID": .string(v1HistoryRoot),
        "role": .string(parent == nil ? "user" : "assistant"), "agent": .string("build"),
        "time": .object(["created": .number(1)])]
    if let parent {
        info["parentID"] = .string(parent); info["providerID"] = .string("synthetic"); info["modelID"] = .string("model/with-slash")
        info["time"] = .object(["created": .number(1), "completed": .number(2)])
    } else { info["model"] = .object(["providerID": .string("synthetic"), "modelID": .string("model/with-slash")]) }
    let raw = parts ?? [.object(["type": .string("text"), "text": .string("Private synthetic 日本語 canary")])]
    let owned = raw.enumerated().map { index, item -> JSONValue in
        var fields = item.object!; fields["id"] = .string("prt_" + id + "_\(index)")
        fields["messageID"] = .string(id); fields["sessionID"] = .string(v1HistoryRoot); return .object(fields)
    }
    return .object(["info": .object(info), "parts": .array(owned)])
}
private func v1HistoryRows() -> [JSONValue] {
    [v1HistoryRow("msg_01"), v1HistoryRow("msg_02", parent: "msg_01"),
     v1HistoryRow("msg_03", parts: [.object(["type": .string("compaction"), "auto": .bool(false), "overflow": .bool(false), "tail_start_id": .string("msg_01")])]),
     v1HistoryRow("msg_04", parent: "msg_03"), v1HistoryRow("msg_05"), v1HistoryRow("msg_06", parent: "msg_05")]
}
private func v1HistoryClone(_ rows: [JSONValue], id: String) -> [JSONValue] {
    let mapping = Dictionary(uniqueKeysWithValues: rows.enumerated().map { ($0.element["info"]["id"].string!, "msg_copy_\($0.offset)") })
    return rows.enumerated().map { index, row in
        var info = row["info"].object!
        info["id"] = .string(mapping[row["info"]["id"].string!]!); info["sessionID"] = .string(id)
        if let parent = info["parentID"]?.string { info["parentID"] = .string(mapping[parent]!) }
        let parts = row["parts"].array!.enumerated().map { partIndex, part -> JSONValue in
            var fields = part.object!; fields["id"] = .string("prt_copy_\(index)_\(partIndex)")
            fields["messageID"] = info["id"]; fields["sessionID"] = .string(id); return .object(fields)
        }
        return .object(["info": .object(info), "parts": .array(parts)])
    }
}
private func v1HistoryHTTP(_ value: JSONValue, headers: [String: String] = [:], status: Int = 200) throws -> OpenCodeHTTPResponse {
    .init(status: status, headers: ["content-type": "application/json"].merging(headers) { _, new in new }, body: try JSONEncoder().encode(value))
}
private struct V1HistoryCall: Sendable {
    let method: String; let path: [String]; let query: [URLQueryItem]; let body: JSONValue?
}
private actor V1HistoryAudit {
    var values: [String] = []
    var candidates: [OpenCodeV1HistoryCandidate] = []
    func mark(_ value: String) { values.append(value) }
    func record(_ candidate: OpenCodeV1HistoryCandidate) { candidates.append(candidate); values.append("candidate") }
}
private actor V1HistoryPeer: OpenCodeV1SessionTransport {
    struct Native: Sendable { var rows: [JSONValue]; var rules: JSONValue = .null; var parent: String?; var reverted = false }
    enum Mode: String, Sendable { case normal, lostACK, lostProof, holdProof, changedContent, reusedMessage, reusedPart, foreignPart, foreignParent, wrongDirectory, wrongPolicy }
    let audit: V1HistoryAudit
    let channel = AsyncThrowingStream<OpenCodeSSEEvent, any Error>.makeStream()
    var sessions: [String: Native] = [v1HistoryRoot: .init(rows: v1HistoryRows())]
    var calls: [V1HistoryCall] = []
    var mode = Mode.normal
    var busy = Set<String>(), requestsPending = Set<String>()
    var inventoryCalls = 0, policyReads = 0, closed = false, proofCancelled = false
    var heldProof: CheckedContinuation<OpenCodeHTTPResponse, any Error>?
    init(audit: V1HistoryAudit) { self.audit = audit }
    func connect() async throws -> AsyncThrowingStream<OpenCodeSSEEvent, any Error> { channel.stream }
    func inventory(directory: URL) async throws -> OpenCodeMetadataSnapshot {
        inventoryCalls += 1; throw ProviderHistoryError(.unsupported)
    }
    func agentPermissionRules(directory: URL, agentID: String) async throws -> [OpenCodeV1PermissionRule] {
        policyReads += 1; return [.init(permission: "edit", pattern: "*", action: "deny")]
    }
    func request(method: String, path: [String], body: JSONValue?) async throws -> OpenCodeHTTPResponse {
        try await request(method: method, path: path, query: [], body: body)
    }
    func request(method: String, path: [String], query: [URLQueryItem], body: JSONValue?) async throws -> OpenCodeHTTPResponse {
        try Task.checkCancellation(); guard !closed else { throw CancellationError() }
        calls.append(.init(method: method, path: path, query: query, body: body))
        await audit.mark(method + " " + path.joined(separator: "/"))
        if path == ["session", "status"] {
            return try v1HistoryHTTP(.object(busy.reduce(into: [:]) { $0[$1] = .object(["type": .string("busy")]) }))
        }
        if path == ["permission"] || path == ["question"] {
            return try v1HistoryHTTP(.array(requestsPending.contains(path[0]) ? [.object(["sessionID": .string(v1HistoryRoot), "id": .string("synthetic_pending")])] : []))
        }
        guard path.count >= 2, let source = sessions[path[1]] else { return try v1HistoryHTTP(.object([:]), status: 404) }
        let id = path[1], tail = Array(path.dropFirst(2))
        if id != v1HistoryRoot, mode == .lostProof { throw CoincideError("Private synthetic proof unavailable") }
        if id != v1HistoryRoot, mode == .holdProof {
            return try await withTaskCancellationHandler {
                try Task.checkCancellation()
                return try await withCheckedThrowingContinuation { heldProof = $0 }
            } onCancel: { Task { await self.cancelProof() } }
        }
        if tail.isEmpty {
            if method == "PATCH" {
                sessions[id]?.rules = mode == .wrongPolicy ? .array([]) : body?["permission"] ?? .null
                // Own settings events must not poison the clone's proof; the
                // subsequent exact settings and full snapshot reads still fence it.
                try emitUpdate(id)
            }
            return try info(id)
        }
        if tail == ["children"] {
            return try v1HistoryHTTP(.array(sessions.filter { $0.value.parent == id }.map { child, _ in
                .object(["id": .string(child), "parentID": .string(id), "directory": .string(v1HistoryDirectory.path)])
            }))
        }
        if tail == ["message"] {
            let before = query.first { $0.name == "before" }?.value
            let end = before.flatMap { Int($0.replacingOccurrences(of: "older opaque +/", with: "")) } ?? source.rows.count
            let start = max(0, end - 2), rows = Array(source.rows[start..<end])
            let headers = start > 0 ? ["x-next-cursor": "older opaque +/\(start)", "link": "<https://foreign.invalid/must-not-follow>; rel=next"] : [:]
            return try v1HistoryHTTP(.array(rows), headers: headers)
        }
        if tail == ["fork"], method == "POST" {
            let count = body?["messageID"].string.flatMap { cut in source.rows.firstIndex { $0["info"]["id"].string! >= cut } } ?? source.rows.count
            let target = "ses_v1_clone"
            var copy = v1HistoryClone(Array(source.rows.prefix(count)), id: target)
            if mode == .reusedMessage {
                copy = copy.enumerated().map { index, row in
                    var info = row["info"].object!
                    info["id"] = source.rows[index]["info"]["id"]
                    if info["role"] == .string("assistant") { info["parentID"] = source.rows[index]["info"]["parentID"] }
                    let parts = row["parts"].array!.map { part -> JSONValue in
                        var fields = part.object!; fields["messageID"] = info["id"]; return .object(fields)
                    }
                    return .object(["info": .object(info), "parts": .array(parts)])
                }
            }
            if !copy.isEmpty {
                var row = copy[0].object!, info = copy[0]["info"].object!, parts = copy[0]["parts"].array!
                if mode == .foreignParent { info["role"] = .string("assistant"); info["parentID"] = .string("msg_foreign") }
                if mode == .changedContent { var part = parts[0].object!; part["text"] = .string("Same count, wrong private content"); parts[0] = .object(part) }
                if mode == .reusedPart { var part = parts[0].object!; part["id"] = source.rows[0]["parts"].array![0]["id"]; parts[0] = .object(part) }
                if mode == .foreignPart { var part = parts[0].object!; part["sessionID"] = .string("ses_foreign"); parts[0] = .object(part) }
                row["info"] = .object(info); row["parts"] = .array(parts); copy[0] = .object(row)
            }
            sessions[target] = .init(rows: copy)
            if mode == .lostACK { throw CoincideError("Private synthetic lost fork ACK") }
            return try info(target)
        }
        if tail == ["abort"] { return try v1HistoryHTTP(.bool(true)) }
        throw ProviderHistoryError(.invalidRequest)
    }
    private func info(_ id: String) throws -> OpenCodeHTTPResponse {
        let native = sessions[id]!
        return try v1HistoryHTTP(.object(["id": .string(id), "projectID": .string("project_synthetic"),
            "directory": .string(id != v1HistoryRoot && mode == .wrongDirectory ? "/different/workspace" : v1HistoryDirectory.path),
            "parentID": native.parent.map(JSONValue.string) ?? .null, "permission": native.rules,
            "time": .object(["created": .number(1), "updated": .number(native.rules == .null ? 1 : 2)]),
            "revert": native.reverted ? .object(["messageID": .string("msg_05")]) : .null]))
    }
    private func emitUpdate(_ id: String) throws {
        let response = try info(id), info = try JSONDecoder().decode(JSONValue.self, from: response.body)
        let value = JSONValue.object(["type": .string("session.updated"), "properties": .object(["sessionID": .string(id), "info": info])])
        channel.continuation.yield(.init(event: "message", data: String(decoding: try JSONEncoder().encode(value), as: UTF8.self), id: nil, retryMilliseconds: nil))
    }
    func setMode(_ mode: Mode) { self.mode = mode }
    func importSessions(_ sessions: [String: Native]) { self.sessions = sessions }
    func makeBusy(_ value: String) {
        if value == "child" { sessions["ses_child"] = .init(rows: [], parent: v1HistoryRoot); busy.insert("ses_child") }
        else if value == "root" { busy.insert(v1HistoryRoot) }
        else { requestsPending.insert(value) }
    }
    func setRevert() { sessions[v1HistoryRoot]?.reverted = true }
    func cancelProof() { proofCancelled = true; heldProof?.resume(throwing: CancellationError()); heldProof = nil }
    func close() async { closed = true; cancelProof(); channel.continuation.finish() }
}
private actor V1HistoryEvents {
    var threadIDs: [String] = []
    func accept(_ event: ProviderEvent) { if case .thread(let id) = event { threadIDs.append(id) } }
}
private struct V1HistoryFixture: Sendable {
    let peer: V1HistoryPeer
    let session: OpenCodeV1Session
    let configuration: OpenCodeConfiguration
    let audit: V1HistoryAudit
    let events: V1HistoryEvents
    let reader: Task<Void, Never>
    init() {
        audit = V1HistoryAudit(); peer = V1HistoryPeer(audit: audit)
        configuration = .init(generation: .v1, executable: "synthetic-opencode")
        session = .init(cwd: v1HistoryDirectory, configuration: configuration, transport: peer)
        events = V1HistoryEvents(); let stream = session.events, collector = events
        reader = Task { for await event in stream { await collector.accept(event) } }
    }
    func captured() -> ProviderConfiguration {
        var thread = CodingThread(project: .init(path: v1HistoryDirectory.path)); thread.provider = .opencode
        thread.openCodeConfiguration = configuration; thread.providerThreadID = v1HistoryRoot; return .init(thread: thread)
    }
    func review(_ source: OpenCodeV1HistorySnapshot, kind: ConversationHistoryKind = .rewindBeforeRun, first: Bool = false) throws -> OpenCodeV1HistoryReviewEvidence {
        let firstRef = try ProviderConversationReference(provider: .opencode, nativeThreadID: v1HistoryRoot)
        let opening = first ? "msg_01" : "msg_05"
        let cut: ProviderHistoryBoundary = kind == .forkAfterRun ? (first ? .beforeMessage("msg_05") : .head) : .beforeMessage(opening)
        let count = cut == .head ? source.messages.count : (cut == .beforeMessage("msg_01") ? 0 : 4)
        return try .init(source: source, boundary: cut, retainedMessageCount: count, selectedOpeningMessageID: opening,
            inputs: [.init(runID: UUID(), originalReference: firstRef, originalMessageID: "msg_01", openingMessageID: "msg_01"),
                     .init(runID: UUID(), originalReference: firstRef, originalMessageID: "msg_05", openingMessageID: "msg_05")])
    }
    func close() async { await session.close(); await reader.value }
}
private func withV1History(_ body: (V1HistoryFixture) async throws -> Void) async throws {
    let fixture = V1HistoryFixture()
    do { try await body(fixture); await fixture.close() }
    catch { await fixture.close(); throw error }
}
private func v1HistoryEventually(_ condition: () async -> Bool) async throws {
    let deadline = ContinuousClock.now + .seconds(8)
    while !(await condition()) {
        guard ContinuousClock.now < deadline else { throw CoincideError("The private v1 history peer did not reach its owned boundary.") }
        try await Task.sleep(for: .milliseconds(5))
    }
}

@Test func openCodeV1HistoryCanonicalCopyNormalizesOnlyNativeOwnershipChanges() throws {
    let rows = v1HistoryRows(), clones = v1HistoryClone(rows, id: "ses_clone")
    let source = try OpenCodeV1HistoryWire.records(rows, sessionID: v1HistoryRoot)
    let copy = try OpenCodeV1HistoryWire.records(clones, sessionID: "ses_clone")
    #expect(OpenCodeV1HistorySnapshot.contentDigest(source) == OpenCodeV1HistorySnapshot.contentDigest(copy))
    #expect(source.map(\.id) != copy.map(\.id) && source.flatMap(\.partIDs) != copy.flatMap(\.partIDs))
    #expect(copy[1].parentID == copy[0].id && copy[3].parentID == copy[2].id)
    let encoded = try JSONEncoder().encode(copy)
    #expect(!String(decoding: encoded, as: UTF8.self).contains("canary"))
    var changed = clones, row = clones[2].object!, parts = clones[2]["parts"].array!, part = parts[0].object!
    part["tail_start_id"] = .string(copy[0].id); parts[0] = .object(part); row["parts"] = .array(parts); changed[2] = .object(row)
    let rewritten = try OpenCodeV1HistoryWire.records(changed, sessionID: "ses_clone")
    #expect(rewritten[2].contentDigest != copy[2].contentDigest)
}

@Test func openCodeV1HistoryRecognizesOnlyExplicitNativeInternalCompactionShapes() throws {
    let internalContinue = v1HistoryRow("msg_07", parts: [.object(["type": .string("text"), "text": .string("Any native continuation"),
        "synthetic": .bool(true), "metadata": .object(["compaction_continue": .bool(true)])])])
    let genericSynthetic = v1HistoryRow("msg_08", parts: [.object(["type": .string("text"), "text": .string("Unowned synthetic request"), "synthetic": .bool(true)])])
    let rows = try OpenCodeV1HistoryWire.records(v1HistoryRows() + [internalContinue, genericSynthetic], sessionID: v1HistoryRoot)
    #expect(rows.map(\.isInternalUserInput) == [false, false, true, false, false, false, true, false])
}

@Test func openCodeV1HistoryPagesUseActualCursorHeaderAndRejectInvalidOwnershipOrBodies() throws {
    let response = try v1HistoryHTTP(.array([v1HistoryRows()[0]]), headers: ["x-next-cursor": "opaque +/", "link": "<https://foreign.invalid/>; rel=next"])
    #expect(try OpenCodeV1HistoryWire.page(response).before == "opaque +/")
    let final = try v1HistoryHTTP(.array([]))
    #expect(try OpenCodeV1HistoryWire.page(final).before == nil)
    for bad in [try v1HistoryHTTP(.array([]), headers: ["x-next-cursor": "opaque"]),
                try v1HistoryHTTP(.array([]), headers: ["content-type": "text/html"]),
                try v1HistoryHTTP(.array([]), status: 503)] {
        #expect(throws: (any Error).self) { try OpenCodeV1HistoryWire.page(bad) }
    }
    let duplicate = [v1HistoryRows()[0], v1HistoryRows()[0]]
    #expect(throws: (any Error).self) { try OpenCodeV1HistoryWire.records(duplicate, sessionID: v1HistoryRoot) }
    #expect(throws: (any Error).self) { try OpenCodeV1HistoryWire.records(v1HistoryRows(), sessionID: "ses_foreign") }
    let large = OpenCodeHTTPResponse(status: 200, headers: ["content-type": "application/json"], body: Data(repeating: 32, count: OpenCodeV1HistoryWire.maximumPageBytes + 1))
    #expect(throws: (any Error).self) { try OpenCodeV1HistoryWire.page(large) }
}

@Test func openCodeV1HistoryReadReassemblesOlderChunksAndMakesNoSettingsOrSessionWrites() async throws {
    try await withV1History { f in
        let source = try await f.session.openCodeV1HistorySnapshot(threadID: v1HistoryRoot)
        #expect(source.messages.map(\.id) == (1...6).map { "msg_0\($0)" })
        let calls = await f.peer.calls, catalogs = await f.peer.inventoryCalls, policies = await f.peer.policyReads
        #expect(calls.allSatisfy { $0.method == "GET" } && catalogs == 0 && policies == 0)
        let pages = calls.filter { $0.path.last == "message" }
        #expect(pages.count == 6 && pages.filter { $0.query.contains { $0.name == "before" } }.count == 4)
        #expect(pages.allSatisfy { $0.query.first { $0.name == "limit" }?.value == "200" && !$0.query.contains { $0.name == "order" } })
    }
}

@Test(arguments: [ConversationHistoryKind.forkAfterRun, .rewindBeforeRun])
func openCodeV1HistoryForkAndRewindBothCloneFullPrefixThenVerifyCloneOnlyPolicy(kind: ConversationHistoryKind) async throws {
    try await withV1History { f in
        let source = try await f.session.openCodeV1HistorySnapshot(threadID: v1HistoryRoot)
        let review = try f.review(source, kind: kind, first: kind == .forkAfterRun)
        let result = try await f.session.applyOpenCodeV1History(review: review, kind: kind, configuration: f.captured(), candidate: { await f.audit.record($0) })
        let proof = try #require(result.openCodeV1)
        #expect(result.reference.nativeThreadID == "ses_v1_clone" && result.headTurnID == nil && proof.messages.count == 4)
        try review.validateResult(proof, kind: kind)
        let unchanged = try await f.session.openCodeV1HistorySnapshot(threadID: v1HistoryRoot)
        #expect(unchanged == source)
        let calls = await f.peer.calls, published = await f.events.threadIDs, audit = await f.audit.values
        let writes = calls.filter { $0.method != "GET" }
        #expect(writes.map(\.method) == ["POST", "PATCH"] && writes[0].path == ["session", v1HistoryRoot, "fork"])
        #expect(writes[0].body == .object(["messageID": .string("msg_05")]) && writes[1].path == ["session", "ses_v1_clone"])
        #expect(writes[1].body?["permission"].array?.last == .object(["permission": .string("edit"), "pattern": .string("*"), "action": .string("deny")]))
        #expect(published.isEmpty)
        let marker = try #require(audit.firstIndex(of: "candidate")), read = try #require(audit.firstIndex(of: "GET session/ses_v1_clone"))
        #expect(marker < read)
    }
}

@Test func openCodeV1HistoryRewindBeforeFirstInputPermitsVerifiedEmptyClone() async throws {
    try await withV1History { f in
        let source = try await f.session.openCodeV1HistorySnapshot(threadID: v1HistoryRoot), review = try f.review(source, first: true)
        let result = try await f.session.applyOpenCodeV1History(review: review, kind: .rewindBeforeRun, configuration: f.captured(), candidate: { await f.audit.record($0) })
        #expect(result.openCodeV1?.messages.isEmpty == true && result.reference.nativeThreadID != source.reference.nativeThreadID)
    }
}

@Test func openCodeV1HistoryRequiredCandidateFailureStopsBeforeAnyCloneReadOrSettingsWrite() async throws {
    try await withV1History { f in
        let source = try await f.session.openCodeV1HistorySnapshot(threadID: v1HistoryRoot), review = try f.review(source)
        await #expect(throws: ProviderHistoryError(.outcomeUncertain)) {
            try await f.session.applyOpenCodeV1History(review: review, kind: .rewindBeforeRun, configuration: f.captured(), candidate: { value in
                await f.audit.record(value); throw CoincideError("Synthetic durable publication refused")
            })
        }
        let candidates = await f.audit.candidates, calls = await f.peer.calls
        #expect(candidates.count == 1 && !calls.contains { $0.path.contains("ses_v1_clone") })
        #expect(calls.filter { $0.method != "GET" }.count == 1)
    }
}

@Test(arguments: [V1HistoryPeer.Mode.changedContent, .reusedMessage, .reusedPart, .foreignPart, .foreignParent, .wrongDirectory, .wrongPolicy])
private func openCodeV1HistoryRejectsWrongCopyEvenWithCorrectCount(mode: V1HistoryPeer.Mode) async throws {
    try await withV1History { f in
        let source = try await f.session.openCodeV1HistorySnapshot(threadID: v1HistoryRoot), review = try f.review(source)
        await f.peer.setMode(mode)
        await #expect(throws: ProviderHistoryError(.outcomeUncertain)) {
            try await f.session.applyOpenCodeV1History(review: review, kind: .rewindBeforeRun, configuration: f.captured(), candidate: { await f.audit.record($0) })
        }
        let calls = await f.peer.calls
        #expect(calls.filter { $0.path.last == "fork" }.count == 1)
        #expect(!calls.contains { ["revert", "unrevert", "prompt_async"].contains($0.path.last ?? "") || $0.method == "DELETE" })
    }
}

@Test(arguments: ["root", "child", "permission", "question"])
func openCodeV1HistoryQuietProofRefusesOwnedBusyWorkBeforeFork(_ work: String) async throws {
    try await withV1History { f in
        let source = try await f.session.openCodeV1HistorySnapshot(threadID: v1HistoryRoot), review = try f.review(source)
        await f.peer.makeBusy(work)
        await #expect(throws: ProviderHistoryError(.notIdle)) {
            try await f.session.applyOpenCodeV1History(review: review, kind: .rewindBeforeRun, configuration: f.captured(), candidate: { await f.audit.record($0) })
        }
        let calls = await f.peer.calls
        #expect(calls.allSatisfy { $0.method == "GET" })
    }
}

@Test(arguments: [V1HistoryPeer.Mode.lostACK, .lostProof])
private func openCodeV1HistoryLostRepliesNeverRepeatForkOrAdoptUnknownIdentity(mode: V1HistoryPeer.Mode) async throws {
    try await withV1History { f in
        let source = try await f.session.openCodeV1HistorySnapshot(threadID: v1HistoryRoot), review = try f.review(source)
        await f.peer.setMode(mode)
        await #expect(throws: ProviderHistoryError(.outcomeUncertain)) {
            try await f.session.applyOpenCodeV1History(review: review, kind: .rewindBeforeRun, configuration: f.captured(), candidate: { await f.audit.record($0) })
        }
        let calls = await f.peer.calls, candidates = await f.audit.candidates, adopted = await f.events.threadIDs
        #expect(calls.filter { $0.path.last == "fork" }.count == 1 && adopted.isEmpty)
        #expect(candidates.count == (mode == .lostACK ? 0 : 1))
        #expect(!calls.contains { $0.method == "PATCH" })
    }
}

@Test func openCodeV1HistoryCloseCancelsAndJoinsExactHeldCandidateProof() async throws {
    try await withV1History { f in
        let source = try await f.session.openCodeV1HistorySnapshot(threadID: v1HistoryRoot), review = try f.review(source)
        await f.peer.setMode(.holdProof)
        let mutation = Task {
            try await f.session.applyOpenCodeV1History(review: review, kind: .rewindBeforeRun, configuration: f.captured(), candidate: { await f.audit.record($0) })
        }
        try await v1HistoryEventually { await f.peer.heldProof != nil }
        await f.session.close()
        do { _ = try await mutation.value; Issue.record("The cancelled native copy was confirmed") }
        catch { #expect(error as? ProviderHistoryError == .init(.outcomeUncertain)) }
        let cancelled = await f.peer.proofCancelled, closed = await f.peer.closed, calls = await f.peer.calls
        #expect(cancelled && closed && calls.filter { $0.path.last == "fork" }.count == 1)
        #expect(!calls.contains { $0.method == "PATCH" || $0.method == "DELETE" })
    }
}

@Test func openCodeV1HistoryPreexistingNativeRevertNeverInvokesAutomaticUnrevert() async throws {
    try await withV1History { f in
        let source = try await f.session.openCodeV1HistorySnapshot(threadID: v1HistoryRoot), review = try f.review(source)
        await f.peer.setRevert()
        await #expect(throws: ProviderHistoryError(.historyChanged)) {
            try await f.session.applyOpenCodeV1History(review: review, kind: .rewindBeforeRun, configuration: f.captured(), candidate: { await f.audit.record($0) })
        }
        let calls = await f.peer.calls
        #expect(calls.allSatisfy { $0.method == "GET" })
    }
}


@Test func openCodeV1HistorySettledProofRetainsPendingNativeToolState() throws {
    let tool = JSONValue.object(["type": .string("tool"), "callID": .string("call_native"), "tool": .string("bash"),
        "state": .object(["status": .string("running"), "input": .object([:]), "time": .object(["start": .number(1)])])])
    let rows = [v1HistoryRow("msg_01"), v1HistoryRow("msg_02", parent: "msg_01", parts: [tool])]
    let evidence = try OpenCodeV1HistoryWire.records(rows, sessionID: v1HistoryRoot)
    #expect(evidence.map(\.isSettled) == [true, false])
}

@Test func openCodeV1HistoryLexicallyInvalidNativeCutIsRejectedBeforeAnyFork() async throws {
    try await withV1History { f in
        let rows = [v1HistoryRow("msg_90"), v1HistoryRow("msg_91", parent: "msg_90"), v1HistoryRow("msg_10")]
        await f.peer.importSessions([v1HistoryRoot: .init(rows: rows)])
        let source = try await f.session.openCodeV1HistorySnapshot(threadID: v1HistoryRoot)
        let reference = source.reference
        #expect(throws: (any Error).self) {
            try OpenCodeV1HistoryReviewEvidence(source: source, boundary: .beforeMessage("msg_10"), retainedMessageCount: 2,
                selectedOpeningMessageID: "msg_10", inputs: [
                    .init(runID: UUID(), originalReference: reference, originalMessageID: "msg_90", openingMessageID: "msg_90"),
                    .init(runID: UUID(), originalReference: reference, originalMessageID: "msg_10", openingMessageID: "msg_10")])
        }
        let calls = await f.peer.calls
        #expect(calls.allSatisfy { $0.method == "GET" })
    }
}

@Test(arguments: [false, true], [ConversationHistoryKind.forkAfterRun, .rewindBeforeRun])
func openCodeV1HistoryCandidateRecoveryIsReadOnlyAndRequiresAlreadyVerifiedPolicy(missingPolicy: Bool, kind: ConversationHistoryKind) async throws {
    try await withV1History { f in
        let source = try await f.session.openCodeV1HistorySnapshot(threadID: v1HistoryRoot)
        let review = try f.review(source, kind: kind, first: kind == .forkAfterRun)
        if missingPolicy { await f.peer.setMode(.lostProof) }
        if missingPolicy {
            await #expect(throws: ProviderHistoryError(.outcomeUncertain)) {
                try await f.session.applyOpenCodeV1History(review: review, kind: kind, configuration: f.captured(), candidate: { await f.audit.record($0) })
            }
        } else {
            _ = try await f.session.applyOpenCodeV1History(review: review, kind: kind, configuration: f.captured(), candidate: { await f.audit.record($0) })
        }
        let candidates = await f.audit.candidates
        let candidate = try #require(candidates.first)
        let restored = V1HistoryPeer(audit: V1HistoryAudit()), native = await f.peer.sessions
        await restored.importSessions(native)
        let session = OpenCodeV1Session(cwd: v1HistoryDirectory, configuration: f.configuration, transport: restored)
        do {
            if missingPolicy {
                await #expect(throws: ProviderHistoryError(.historyChanged)) {
                    try await session.inspectOpenCodeV1HistoryCandidate(review: review, candidate: candidate, configuration: f.captured())
                }
            } else {
                let observed = try await session.inspectOpenCodeV1HistoryCandidate(review: review, candidate: candidate, configuration: f.captured())
                let proof = try #require(observed.openCodeV1)
                try review.validateResult(proof, kind: kind)
                #expect(observed.reference == candidate.reference)
            }
            let calls = await restored.calls
            #expect(calls.allSatisfy { $0.method == "GET" })
            await session.close()
        } catch { await session.close(); throw error }
    }
}
