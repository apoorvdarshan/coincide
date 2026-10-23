import Foundation
import Testing
@testable import CoincideCore

@Test func appMCPToolCatalogAdvertisesTheRealNativeSurfaceWithoutInventingMissingServicesOrReadingOnConstruction() async throws {
    let fixture = AppMCPToolFixture()
    let probe = AppMCPToolProbe(view: fixture.view)
    let tools = fixture.tools(probe)
    let names = Set(tools.descriptors.map(\.name))
    #expect(names.count == 30)
    #expect(names.isSuperset(of: ["orchestrator_capabilities", "t3_thread_launch", "create_threads", "t3_thread_read", "t3_thread_fork",
        "t3_queue_edit", "t3_queue_reorder", "t3_queue_promote_to_steer", "t3_pending_request_respond", "t3_project_create", "t3_worktree_status"]))
    #expect(names.isDisjoint(with: ["delegate_task", "schedule_task", "request_secret", "preview_open", "device_open", "watch_pull_request", "t3_worktree_handoff", "t3_thread_merge_back"]))
    #expect(AppMCPTools.unsupportedCapabilities.contains("queued_steering_input_text_revision"))
    for definition in tools.descriptors {
        try definition.validate()
        #expect(definition.inputSchema["type"] == .string("object"))
        #expect(definition.inputSchema["additionalProperties"] == .bool(false))
    }
    #expect(tools.descriptors.first { $0.name == "t3_thread_read" }?.readOnly == true)
    #expect(tools.descriptors.first { $0.name == "t3_thread_send" }?.readOnly == false)
    let reads = await probe.readCount, actions = await probe.actions
    #expect(reads == 0 && actions.isEmpty)
}

@Test func appMCPReadsPageRetainedHistoryAndUnicodeWithoutPublishingDraftLaunchOrProviderPrivateFields() async throws {
    var fixture = AppMCPToolFixture()
    let removedOperation = UUID()
    var removed = ChatMessage(id: "removed", role: .assistant, text: "removed-private-canary")
    removed.removedByHistoryOperationID = removedOperation
    fixture.thread.messages = [ChatMessage(id: "first", role: .user, text: "😀Z"), removed,
        ChatMessage(id: "second", role: .assistant, text: "Retained 工作"), ChatMessage(id: "activity", role: .system, text: "Native notice")]
    fixture.thread.draft = "draft-private-canary"
    fixture.thread.providerMetadata = .object(["private": .string("provider-private-canary")])
    var configuration = ProviderConfiguration(thread: fixture.thread)
    configuration.nativeThreadID = "native-private-canary"
    fixture.thread.queuedTurns = [.init(id: UUID(), text: String(repeating: "q", count: 16_001), configuration: configuration, createdAt: .now)]
    let probe = AppMCPToolProbe(view: fixture.view), tools = fixture.tools(probe)
    let first = await tools.call(name: "t3_thread_read", arguments: .object(["threadId": fixture.threadID,
        "limit": .number(1), "maxCharsPerItem": .number(1)]), context: fixture.context)
    let firstBody = try #require(first.structuredContent)
    #expect(!first.isError && firstBody["items"].array?.count == 1 && firstBody["items"][0]["text"] == .string("😀"))
    #expect(firstBody["items"][0]["nextTextOffset"] == .number(2) && firstBody["nextPosition"] == .number(0) && firstBody["hasMore"] == .bool(true))
    let continuation = await tools.call(name: "t3_thread_read", arguments: .object(["threadId": fixture.threadID,
        "itemId": .string("first"), "textOffset": .number(2), "maxCharsPerItem": .number(1)]), context: fixture.context)
    #expect(continuation.structuredContent?["items"][0]["text"] == .string("Z"))
    let next = await tools.call(name: "t3_thread_read", arguments: .object(["threadId": fixture.threadID, "afterPosition": .number(0), "limit": .number(1)]), context: fixture.context)
    #expect(next.structuredContent?["items"][0]["itemId"] == .string("second") && next.structuredContent?["nextPosition"] == .number(1))
    let activity = await tools.call(name: "t3_thread_read", arguments: .object(["threadId": fixture.threadID, "view": .string("activity")]), context: fixture.context)
    #expect(activity.structuredContent?["items"].array?.count == 3)
    let queueList = await tools.call(name: "t3_queue_list", arguments: .object([:]), context: fixture.context)
    #expect(queueList.structuredContent?["items"][0]["text"].string?.utf16.count == 1_000)
    let queued = try #require(fixture.thread.queuedTurns.first)
    let queueRead = await tools.call(name: "t3_queue_read", arguments: .object(["queuedRunId": .string(queued.id.uuidString)]), context: fixture.context)
    #expect(queueRead.structuredContent?["text"].string?.utf16.count == 16_000 && queueRead.structuredContent?["truncated"] == .bool(true))
    let environment = await tools.call(name: "t3_environment_read", arguments: .object([:]), context: fixture.context)
    for result in [first, continuation, next, activity, queueList, queueRead, environment] {
        let rendered = result.content.joined()
        for canary in ["removed-private-canary", "draft-private-canary", "provider-private-canary", "native-private-canary"] { #expect(!rendered.contains(canary)) }
        #expect(!result.isError)
    }
    let actions = await probe.actions
    #expect(actions.isEmpty, "Reading history or the queue cannot start, resume or send work.")
}

@Test func appMCPMutationsCarryLiteralInputsExactQueueIDsAndAbsentVersusEmptyModelOptionsToAtomicAdmission() async throws {
    let fixture = AppMCPToolFixture(), probe = AppMCPToolProbe(view: AppMCPToolFixture().view)
    // Use the exact same captured caller/frame in every request.
    await probe.replace(fixture.view)
    let tools = fixture.tools(probe), queuedID = UUID(), targetRunID = UUID(), instanceID = UUID()
    let literal = "  Literal 😀 工作\n$HOME /unknown  "
    let requests: [(String, JSONValue)] = [
        ("t3_thread_send", .object(["threadId": fixture.threadID, "message": .string(literal), "mode": .string("queue"), "clientRequestId": .string("same-request")])),
        ("t3_queue_edit", .object(["queuedRunId": .string(queuedID.uuidString), "text": .string(literal)])),
        ("t3_queue_reorder", .object(["queuedRunId": .string(queuedID.uuidString), "beforeRunId": .null])),
        ("t3_queue_promote_to_steer", .object(["queuedRunId": .string(queuedID.uuidString), "targetRunId": .string(targetRunID.uuidString)])),
        ("t3_thread_configure", .object(["modelSelection": .object(["instanceId": .string(instanceID.uuidString), "model": .string("wire-model")])])),
        ("t3_thread_configure", .object(["modelSelection": .object(["instanceId": .string(instanceID.uuidString), "model": .string("wire-model"), "options": .array([])])])),
        ("t3_thread_configure", .object(["modelSelection": .object(["instanceId": .string(instanceID.uuidString), "model": .string("wire-model"),
            "options": .array([.object(["id": .string("reasoningEffort"), "value": .string("high")])])])]))
    ]
    for (name, arguments) in requests {
        let result = await tools.call(name: name, arguments: arguments, context: fixture.context)
        #expect(!result.isError)
    }
    let actions = await probe.actions
    #expect(actions == [
        .send(threadID: fixture.thread.id, message: literal, mode: .queue, clientRequestID: "same-request"),
        .editQueued(threadID: fixture.thread.id, queuedRunID: queuedID, text: literal),
        .reorderQueued(threadID: fixture.thread.id, queuedRunID: queuedID, beforeRunID: nil),
        .promoteQueued(threadID: fixture.thread.id, queuedRunID: queuedID, targetRunID: targetRunID),
        .configureThread(threadID: fixture.thread.id, selection: .init(instanceID: instanceID, model: "wire-model")),
        .configureThread(threadID: fixture.thread.id, selection: .init(instanceID: instanceID, model: "wire-model", options: [:])),
        .configureThread(threadID: fixture.thread.id, selection: .init(instanceID: instanceID, model: "wire-model", options: ["reasoningEffort": .string("high")]))
    ])
    let invalidRequests: [(String, JSONValue)] = [
        ("t3_thread_send", .object(["threadId": fixture.threadID, "message": .string("x"), "permission": .string("fullAccess")])),
        ("t3_queue_reorder", .object(["queuedRunId": .string(queuedID.uuidString)])),
        ("t3_thread_configure", .object(["modelSelection": .object(["model": .string("x"), "homeDirectory": .string("/not-allowed")])])),
        ("t3_thread_configure", .object(["modelSelection": .object(["model": .string("x"), "options": .array([
            .object(["id": .string("reasoningEffort"), "value": .string("high")]), .object(["id": .string("reasoningEffort"), "value": .string("low")])])])])),
        ("t3_thread_wait", .object(["threadId": fixture.threadID, "timeoutMs": .number(600_001)])),
        ("create_threads", .object(["threads": .array(Array(repeating: .object([:]), count: 21))]))
    ]
    for (name, arguments) in invalidRequests {
        let result = await tools.call(name: name, arguments: arguments, context: fixture.context)
        #expect(result.isError && result.structuredContent?["code"] == .string("invalid_request"))
    }
    let unchanged = await probe.actions
    #expect(unchanged == actions)
}

@Test func appMCPQuestionToolsExcludeApprovalsAndRespectExactPendingQuestionIdentity() async throws {
    var fixture = AppMCPToolFixture()
    let question = ApprovalRequest(id: .number(7), method: "item/tool/requestUserInput", params: .object(["questions": .array([
        .object(["id": .string("choice"), "header": .string("Choose"), "question": .string("Which 工作?"), "multiSelect": .bool(true),
            "allowCustomAnswer": .bool(true), "required": .bool(true), "private": .string("raw-question-canary"),
            "options": .array([.object(["label": .string("One"), "value": .string("native-one"), "description": .string("First choice")])])
        ])
    ])]))
    let approval = ApprovalRequest(id: .string("permission"), method: "item/commandExecution/requestApproval", params: .object(["private": .string("raw-approval-canary")]))
    fixture.thread.runtimeRequests = [.init(request: question), .init(request: approval)]
    let probe = AppMCPToolProbe(view: fixture.view), tools = fixture.tools(probe)
    let listed = await tools.call(name: "t3_pending_request_list", arguments: .object([:]), context: fixture.context)
    #expect(listed.structuredContent?["requestIds"] == .array([.number(7)]))
    let read = await tools.call(name: "t3_pending_request_read", arguments: .object(["requestId": .number(7)]), context: fixture.context)
    #expect(read.structuredContent?["questions"][0]["multiSelect"] == .bool(true))
    #expect(read.structuredContent?["questions"][0]["options"][0]["value"] == .string("native-one"))
    #expect(!read.content.joined().contains("raw-question-canary"))
    for name in ["t3_pending_request_read", "t3_pending_request_respond"] {
        var fields: [String: JSONValue] = ["requestId": .string("permission")]
        if name.hasSuffix("respond") { fields["answers"] = .object(["allow": .string("yes")]) }
        let denied = await tools.call(name: name, arguments: .object(fields), context: fixture.context)
        #expect(denied.isError && !denied.content.joined().contains("raw-approval-canary"))
    }
    let answer = await tools.call(name: "t3_pending_request_respond", arguments: .object(["requestId": .number(7), "answers": .object(["choice": .string("One\nCustom 工作")])]), context: fixture.context)
    #expect(!answer.isError)
    let actions = await probe.actions
    #expect(actions == [.answerQuestion(threadID: fixture.thread.id, requestID: .number(7), answers: ["choice": "One\nCustom 工作"])])
    fixture.thread.runtimeRequests[0].responding = true
    await probe.replace(fixture.view)
    let duplicate = await tools.call(name: "t3_pending_request_respond", arguments: .object(["requestId": .number(7), "answers": .object(["choice": .string("One")])]), context: fixture.context)
    #expect(duplicate.isError)
    let after = await probe.actions
    #expect(after == actions)
}

@Test(.timeLimit(.minutes(1))) func appMCPIdleReadsRemainAvailableWhileWritesAndAuthorityChangedDuringReadAreRefusedAtAdmission() async throws {
    let fixture = AppMCPToolFixture(), probe = AppMCPToolProbe(view: AppMCPToolFixture().view)
    await probe.replace(fixture.view)
    let tools = fixture.tools(probe), idle = AppMCPContext(scope: fixture.context.scope, runID: nil, configuration: fixture.context.configuration)
    let read = await tools.call(name: "t3_thread_configuration", arguments: .object([:]), context: idle)
    #expect(!read.isError)
    let denied = await tools.call(name: "t3_thread_send", arguments: .object(["threadId": fixture.threadID, "message": .string("No implicit send")]), context: idle)
    #expect(denied.isError && denied.structuredContent?["code"] == .string("parent_not_active"))
    await probe.holdNextRead()
    let call = Task { await tools.call(name: "t3_queue_cancel", arguments: .object(["queuedRunId": .string(UUID().uuidString)]), context: fixture.context) }
    try await appMCPEventually { await probe.isReadHeld }
    await probe.revokeAndReleaseRead()
    let stale = await call.value
    #expect(stale.isError && stale.structuredContent?["code"] == .string("parent_not_active"))
    let actions = await probe.actions
    #expect(actions.isEmpty, "The earlier successful read is not write authorization after an await.")
    let limitedScope = MCPInvocationScope(threadID: fixture.thread.id, projectID: fixture.project.id, provider: fixture.thread.provider,
        runtimeID: fixture.context.scope.runtimeID, incarnation: fixture.context.scope.incarnation,
        providerInstanceID: fixture.context.scope.providerInstanceID, workspacePath: fixture.thread.workspacePath, permission: .supervised, capabilities: [.worktree])
    let limited = AppMCPContext(scope: limitedScope, runID: fixture.context.runID, configuration: fixture.context.configuration)
    let missing = await tools.call(name: "t3_thread_read", arguments: .object(["threadId": fixture.threadID]), context: limited)
    #expect(missing.isError && missing.structuredContent?["code"] == .string("capability_denied"))
}

private struct AppMCPToolFixture {
    let project: WorkspaceProject
    var thread: CodingThread
    let runtimeID = UUID(), incarnation = UUID(), instanceID = UUID(), sessionID = UUID(), runID = UUID()
    init() {
        project = WorkspaceProject(path: "/synthetic-app-mcp-workspace")
        thread = CodingThread(project: project)
        thread.title = "Native app tools 工作"; thread.permission = .supervised
    }
    var threadID: JSONValue { .string(thread.id.uuidString) }
    var context: AppMCPContext {
        .init(scope: .init(sessionID: sessionID, threadID: thread.id, projectID: project.id, provider: thread.provider, runtimeID: runtimeID,
            incarnation: incarnation, providerInstanceID: instanceID, workspacePath: thread.workspacePath, permission: thread.permission, capabilities: [.orchestration, .worktree]),
            runID: runID, configuration: ProviderConfiguration(thread: thread))
    }
    var view: AppMCPView { var snapshot = WorkspaceSnapshot(); snapshot.projects = [project]; snapshot.threads = [thread]; return .init(snapshot: snapshot, sequence: 42) }
    func tools(_ probe: AppMCPToolProbe) -> AppMCPTools {
        .init(client: .init(read: { _ in await probe.read() }, perform: { action, context in try await probe.perform(action, context: context) }))
    }
}
private actor AppMCPToolProbe {
    private var view: AppMCPView
    private var hold = false
    private var readContinuation: CheckedContinuation<Void, Never>?
    private var revoked = false
    private(set) var readCount = 0
    private(set) var actions: [AppMCPAction] = []
    init(view: AppMCPView) { self.view = view }
    var isReadHeld: Bool { readContinuation != nil }
    func replace(_ view: AppMCPView) { self.view = view }
    func holdNextRead() { hold = true }
    func read() async -> AppMCPView {
        readCount += 1
        if hold { hold = false; await withCheckedContinuation { readContinuation = $0 } }
        return view
    }
    func revokeAndReleaseRead() { revoked = true; readContinuation?.resume(); readContinuation = nil }
    func perform(_ action: AppMCPAction, context: AppMCPContext) throws -> JSONValue {
        guard !revoked else { throw AppMCPError(.staleCaller) }
        actions.append(action)
        return .object(["sequence": .number(43), "accepted": .bool(true)])
    }
}
private func appMCPEventually(_ condition: @escaping @Sendable () async -> Bool) async throws {
    let deadline = ContinuousClock.now + .seconds(3)
    while !(await condition()) {
        guard ContinuousClock.now < deadline else { throw AppMCPError(.unavailable) }
        try await Task.sleep(for: .milliseconds(5))
    }
}
private extension JSONValue {
    subscript(_ index: Int) -> JSONValue {
        guard let values = array, values.indices.contains(index) else { return .null }
        return values[index]
    }
}
