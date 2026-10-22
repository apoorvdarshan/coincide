import Foundation
import Testing
@testable import CoincideCore

private actor ACP2IntegrationRecording {
    private(set) var requests: [ApprovalRequest] = []
    private(set) var dismissed: [JSONValue] = []
    private(set) var entities: [ProviderEntityKey: ProviderEntity] = [:]
    private(set) var owners: [ProviderEntityKey: UUID] = [:]
    private(set) var finished = 0
    private(set) var failures: [String] = []
    private(set) var metadata: JSONValue = .null
    private(set) var activities: [ProviderActivity] = []
    private(set) var ownersMissingPriorActivity: [ProviderEntityKey] = []

    func record(_ event: ProviderEvent) {
        switch event {
        case .context(_, let inner): record(inner)
        case .approval(let request), .sessionApproval(let request): requests.append(request)
        case .approvalDismissed(let id), .sessionApprovalDismissed(let id): dismissed.append(id)
        case .entity(let update): apply(update, owner: nil)
        case .runEntity(let runID, let update): apply(update, owner: runID)
        case .activity(let activity): activities.append(activity); if activity.finishesRun { finished += 1 }
        case .configuration(let value): metadata = value
        case .completed: finished += 1
        case .failure(let reason), .connectionClosed(let reason): failures.append(reason)
        default: break
        }
    }
    private func apply(_ update: ProviderEntityUpdate, owner: UUID?) {
        do {
            entities[update.key] = try update.apply(to: entities[update.key])
            if let owner {
                if !activities.contains(where: { $0.id == owner && $0.state != .idle }) { ownersMissingPriorActivity.append(update.key) }
                owners[update.key] = owner
            }
        }
        catch { failures.append("The synthetic integration entity was invalid.") }
    }
}

private struct ACP2IntegrationFixture {
    let root: URL
    let log: URL
    let session: ACP2Session
    let recording: ACP2IntegrationRecording
    func frames() throws -> [JSONValue] {
        guard FileManager.default.fileExists(atPath: log.path) else { return [] }
        let data = try Data(contentsOf: log)
        guard let end = data.lastIndex(of: 10) else { return [] }
        return try data[...end].split(separator: 10).map { try JSONDecoder().decode(JSONValue.self, from: Data($0)) }
    }
    func thread(runID: UUID = UUID()) -> CodingThread {
        var thread = CodingThread(project: WorkspaceProject(path: root.path)); thread.provider = .acp
        thread.activeRun = .init(id: runID, configuration: .init(thread: thread), startedAt: .now)
        return thread
    }
}

private func withACP2Integration(_ mode: String, integration: ACPIntegration?, body: (ACP2IntegrationFixture) async throws -> Void) async throws {
    let root = try temporaryWorkspace(); defer { try? FileManager.default.removeItem(at: root) }
    let script = root.appendingPathComponent("peer.py"), log = root.appendingPathComponent("wire.jsonl")
    try Data(acp2IntegrationPeer.utf8).write(to: script)
    let session = try ACP2Session(executable: URL(fileURLWithPath: "/usr/bin/python3"), arguments: ["-u", script.path, mode, log.path],
                                  cwd: root, cancellationTimeout: .seconds(1), acceptanceTimeout: .seconds(10), integration: integration)
    let recording = ACP2IntegrationRecording()
    let reader = Task { for await event in session.events { await recording.record(event) } }
    do {
        try await body(.init(root: root, log: log, session: session, recording: recording))
        await session.close(); await reader.value
    } catch { await session.close(); await reader.value; throw error }
}

private func waitACP2Integration(_ predicate: () async throws -> Bool) async throws {
    let deadline = ContinuousClock.now + .seconds(8)
    while try await !predicate() {
        guard ContinuousClock.now < deadline else { throw CoincideError("The ACP integration fixture did not reach its expected boundary.") }
        try await Task.sleep(for: .milliseconds(10))
    }
}

private func rejectsACP2Integration(_ body: () async throws -> Void) async throws {
    do { try await body(); Issue.record("A stale or invalid synthetic Cursor response was accepted.") }
    catch is CancellationError { throw CancellationError() }
    catch { /* The request must remain pending; the peer verifies the later valid reply. */ }
}

@Test(.timeLimit(.minutes(1)), arguments: [ACPIntegration.cursor, .copilot])
func acpV2IntegrationConnectionProbeIsInitializeOnlyAndAdvertisesBothNegotiationShapes(_ integration: ACPIntegration) async throws {
    try await withACP2Integration("probe", integration: integration) { f in
        async let first = f.session.acpConnectionInfo()
        async let second = f.session.acpConnectionInfo()
        let info = try await (first, second)
        #expect(info.0.protocolVersion == 2 && info.1.protocolVersion == 2)
        #expect(info.0.supportsImages && info.0.supportsResume)
        let frames = try f.frames()
        #expect(frames.filter { $0["method"].string == "initialize" }.count == 1)
        #expect(!frames.contains { $0["method"].string == "session/new" })
        let params = try #require(frames.first?["params"])
        #expect(params["capabilities"] == integration.clientCapabilities)
        #expect(params["clientCapabilities"] == integration.clientCapabilities)
    }
}

@Test(.timeLimit(.minutes(1)), arguments: ["questions", "questions-alias", "v1"])
func acpV2IntegrationCursorQuestionsUseTypedIDsAndSameTransportV1Delegation(_ mode: String) async throws {
    try await withACP2Integration(mode, integration: .cursor) { f in
        try await f.session.send(text: "Synthetic question", thread: f.thread())
        try await waitACP2Integration { await f.recording.requests.count == 1 }
        let request = try #require(await f.recording.requests.first)
        #expect(request.id != .number(37))
        #expect(request.method == CursorACPMethod.question && request.params["untrusted"] == .null)
        #expect(request.params["sessionId"] == .string("integration-session"))
        try await rejectsACP2Integration { try await f.session.selectAnswers(request, selections: ["q": ["missing"]]) }
        try await f.session.selectAnswers(request, selections: ["q": ["second", "first"]])
        try await waitACP2Integration { await f.recording.finished == 1 }
        let frames = try f.frames(), responses = frames.filter { $0["id"] == .number(37) && $0["method"] == .null }
        #expect(responses.count == 1)
        #expect(responses[0]["result"]["outcome"]["answers"].array?.first?["selectedOptionIds"] == .array([.string("first"), .string("second")]))
        #expect(frames.filter { $0["method"].string == "initialize" }.count == 1)
        #expect(await f.recording.dismissed.contains(request.id))
        #expect(await f.recording.failures.isEmpty)
    }
}

@Test(.timeLimit(.minutes(1)), arguments: ["skip", "plan-accept", "plan-decline"])
func acpV2IntegrationCursorExplicitSkipAcceptAndDeclineHaveDistinctWireOutcomes(_ mode: String) async throws {
    try await withACP2Integration(mode, integration: .cursor) { f in
        try await f.session.send(text: "Synthetic review", thread: f.thread())
        try await waitACP2Integration { await f.recording.requests.count == 1 }
        let request = try #require(await f.recording.requests.first)
        if mode == "skip" { #expect(request.cursorQuestion != nil) }
        else { #expect(request.cursorPlan?.plan == "# Synthetic plan\n\nReview only.") }
        try await f.session.respond(request, allow: mode == "plan-accept")
        try await waitACP2Integration { await f.recording.finished == 1 }
        let response = try #require(try f.frames().last(where: { $0["id"] == .number(37) && $0["method"] == .null }))
        let expected = mode == "skip" ? "skipped" : mode == "plan-accept" ? "accepted" : "rejected"
        #expect(response["result"]["outcome"]["outcome"] == .string(expected))
        #expect(await f.recording.failures.isEmpty)
    }
}

@Test(.timeLimit(.minutes(1)))
func acpV2IntegrationCursorSessionApprovalIsAnswerableWhileForegroundIsIdle() async throws {
    try await withACP2Integration("idle", integration: .cursor) { f in
        _ = try await f.session.models()
        try await waitACP2Integration { await f.recording.requests.count == 1 }
        let request = try #require(await f.recording.requests.first)
        #expect(await f.recording.finished == 0)
        try await f.session.selectAnswers(request, selections: ["q": ["first"]])
        try await waitACP2Integration { try f.frames().contains { $0["id"] == .number(37) && $0["result"]["outcome"]["outcome"] == .string("answered") } }
        #expect(await f.recording.dismissed == [request.id])
        #expect(await f.recording.finished == 0)
        let frames = try f.frames()
        #expect(!frames.contains { $0["method"].string == "session/prompt" })
    }
}

@Test(.timeLimit(.minutes(1)))
func acpV2IntegrationRemoteCancelMapsWireIdentityAndReusedWireIDCannotAcceptOldLocalAnswer() async throws {
    try await withACP2Integration("remote-cancel", integration: .cursor) { f in
        try await f.session.send(text: "Synthetic cancellation", thread: f.thread())
        try await waitACP2Integration { await f.recording.requests.count == 2 }
        let requests = await f.recording.requests
        #expect(requests[0].id != requests[1].id)
        #expect(await f.recording.dismissed.contains(requests[0].id))
        try await rejectsACP2Integration { try await f.session.selectAnswers(requests[0], selections: ["q": ["first"]]) }
        try await f.session.selectAnswers(requests[1], selections: ["q": ["second"]])
        try await waitACP2Integration { await f.recording.finished == 1 }
        let responses = try f.frames().filter { $0["id"] == .number(37) && $0["method"] == .null }
        #expect(responses.count == 2)
        #expect(responses[0]["result"]["outcome"]["outcome"] == .string("cancelled"))
        #expect(responses[1]["result"]["outcome"]["outcome"] == .string("answered"))
    }
}

@Test(.timeLimit(.minutes(1)))
func acpV2IntegrationStopCancelsEveryCursorWireRequestWithoutUsingLocalIDs() async throws {
    try await withACP2Integration("stop", integration: .cursor) { f in
        try await f.session.send(text: "Synthetic stop", thread: f.thread())
        try await waitACP2Integration { await f.recording.requests.count == 2 }
        let requests = await f.recording.requests
        try await f.session.interrupt()
        try await waitACP2Integration { await f.recording.dismissed.count == 2 }
        try await waitACP2Integration { try f.frames().filter { $0["result"]["outcome"]["outcome"] == .string("cancelled") }.count == 2 }
        let responses = try f.frames().filter { $0["result"]["outcome"]["outcome"] == .string("cancelled") }
        #expect(Set(responses.map { $0["id"] }) == Set([.number(37), .number(38)]))
        for request in requests { try await rejectsACP2Integration { try await f.session.respond(request, allow: false) } }
    }
}

@Test(.timeLimit(.minutes(1)), arguments: ["unnegotiated", "invalid"])
func acpV2IntegrationCursorRequestsRequireExplicitProfileAndValidBoundSessionPayload(_ mode: String) async throws {
    try await withACP2Integration(mode, integration: mode == "unnegotiated" ? nil : .cursor) { f in
        try await f.session.send(text: "Synthetic rejection", thread: f.thread())
        try await waitACP2Integration { await f.recording.finished == 1 }
        #expect(await f.recording.requests.isEmpty)
        let frames = try f.frames()
        #expect(frames.contains { $0["id"] == .number(37) && $0["error"].object != nil })
        if mode == "invalid" {
            #expect(frames.contains { $0["id"] == .number(38) && $0["result"]["outcome"]["outcome"] == .string("cancelled") })
        }
    }
}

@Test(.timeLimit(.minutes(1)))
func acpV2IntegrationCursorActivityUsesCurrentRunAndIgnoresUnownedIdleNotifications() async throws {
    try await withACP2Integration("cursor-notices", integration: .cursor) { f in
        try await f.session.send(text: "Synthetic activity", thread: f.thread())
        try await waitACP2Integration { await f.recording.metadata["sessionInfo"]["fixtureBoundary"] == .string("after-idle") }
        #expect(await f.recording.finished == 1)
        let entities = await f.recording.entities
        let plan = try #require(entities.values.first { $0.key.type == "plan" })
        #expect(plan.fields["entries"].array?.map { $0["id"].string } == ["first", "second"])
        let task = try #require(entities.values.first { $0.key.id == "cursor-task" })
        #expect(task.fields["rawInput"]["prompt"] == .string("Synthetic nested prompt"))
        #expect(task.fields["rawInput"]["untrusted"] == .null)
        let image = try #require(entities.values.first { $0.key.id == "cursor-image" })
        #expect(image.fields["rawInput"]["filePath"] == .string("/not-opened/synthetic.png"))
        #expect(!entities.values.contains { $0.key.id == "unowned-idle" })
        #expect(await f.recording.failures.isEmpty)
    }
}

@Test(.timeLimit(.minutes(1)))
func acpV2IntegrationDuplicatePendingCursorWireIdentityFailsWithoutReplacingReview() async throws {
    try await withACP2Integration("duplicate", integration: .cursor) { f in
        try await f.session.send(text: "Synthetic duplicate", thread: f.thread())
        try await waitACP2Integration { await !f.recording.failures.isEmpty }
        #expect(await f.recording.requests.count == 1)
        #expect(await f.recording.failures.contains { $0.contains("reused a pending request identity") })
    }
}

@Test(.timeLimit(.minutes(1)))
func acpV2IntegrationCopilotChildContinuesOriginalRunAcrossIdleAndTheNextForegroundTurn() async throws {
    try await withACP2Integration("copilot", integration: .copilot) { f in
        let first = UUID(), second = UUID()
        try await f.session.send(text: "First synthetic turn", thread: f.thread(runID: first))
        try await waitACP2Integration { await f.recording.entities.values.contains { $0.key.id == "child-message" && $0.text == "idle child\n" } }
        #expect(await f.recording.finished == 1)
        try await f.session.send(text: "Second synthetic turn", thread: f.thread(runID: second))
        try await waitACP2Integration { await f.recording.finished == 2 }
        let entities = await f.recording.entities, owners = await f.recording.owners
        let lifecycle = try #require(entities.values.first { $0.key.id == "copilot-child-lifecycle" })
        let child = try #require(entities.values.first { $0.key.id == "child-message" })
        #expect(child.text == "idle child\nnext child 🌍")
        #expect(child.key.sessionID == lifecycle.key.sessionID && child.key.sessionID != "integration-session")
        #expect(owners[child.key] == first && owners[lifecycle.key] == first)
        #expect(lifecycle.fields["status"] == .string("completed"))
        #expect(child.fields["_meta"]["github.com/copilot"]["parentRunID"] == .string(first.uuidString))
        let firstRoot = try #require(entities.values.first { $0.key.id == "root-first" })
        let secondRoot = try #require(entities.values.first { $0.key.id == "root-second" })
        #expect(firstRoot.text == "root first" && owners[firstRoot.key] == first)
        #expect(secondRoot.text == "root second" && owners[secondRoot.key] == second)
        #expect(!entities.values.contains { $0.text.contains("discard late root") || $0.text.contains("discard unknown child") || $0.text.contains("discard ended child") })
        #expect(await f.recording.failures.isEmpty)
    }
}

@Test(.timeLimit(.minutes(1)))
func acpV2IntegrationCopilotResumedForegroundIdleDuringConfigurationDoesNotConsumeNewPromptOwner() async throws {
    try await withACP2Integration("copilot-config-idle", integration: .copilot) { f in
        let runID = UUID()
        var thread = f.thread(runID: runID); thread.providerThreadID = "integration-session"; thread.model = "changed"
        try await f.session.send(text: "Synthetic configured turn", thread: thread)
        try await waitACP2Integration { await f.recording.finished == 1 }
        let entities = await f.recording.entities, owners = await f.recording.owners
        let root = try #require(entities.values.first { $0.key.id == "configured-root" })
        #expect(root.text == "after configuration" && owners[root.key] == runID)
        #expect(!entities.values.contains { $0.text.contains("discard before dispatch") })
        let frames = try f.frames()
        #expect(frames.contains { $0["method"].string == "session/resume" })
        #expect(frames.filter { $0["method"].string == "session/set_config_option" }.count == 1)
        #expect(frames.filter { $0["method"].string == "session/prompt" }.count == 1)
        #expect(await f.recording.failures.isEmpty)
    }
}

@Test(.timeLimit(.minutes(1)), arguments: ["copilot-autonomous", "copilot-autonomous-config"])
func acpV2IntegrationCopilotAutonomousWakeOwnsItsActivityAndCannotConsumeTheNextUserOwner(_ mode: String) async throws {
    try await withACP2Integration(mode, integration: .copilot) { f in
        let first = UUID(), second = UUID()
        try await f.session.send(text: "First synthetic turn", thread: f.thread(runID: first))
        let boundary = mode == "copilot-autonomous" ? "autonomous-idle" : "autonomous-running"
        try await waitACP2Integration { await f.recording.metadata["sessionInfo"]["fixtureBoundary"] == .string(boundary) }
        #expect(await f.recording.finished == (mode == "copilot-autonomous" ? 2 : 1))
        var next = f.thread(runID: second)
        if mode == "copilot-autonomous-config" { next.model = "changed" }
        try await f.session.send(text: "Second synthetic turn", thread: next)
        try await waitACP2Integration { await f.recording.finished == 3 }
        let entities = await f.recording.entities, owners = await f.recording.owners, activities = await f.recording.activities
        let autonomous = try #require(activities.first { $0.state == .running && $0.id != first && $0.id != second }?.id)
        #expect(Set(activities.filter { $0.state == .running }.map(\.id)) == Set([first, autonomous, second]))
        #expect(activities.filter { $0.finishesRun }.map(\.id) == [first, autonomous, second])
        for (id, owner, text) in [("root-first", first, "first user"), ("autonomous-root", autonomous, "autonomous root"), ("root-second", second, "second user")] {
            let entity = try #require(entities.values.first { $0.key.id == id })
            #expect(entity.text == text && owners[entity.key] == owner)
        }
        let child = try #require(entities.values.first { $0.key.id == "autonomous-child" })
        let lifecycle = try #require(entities.values.first { $0.key.id == "copilot-child-lifecycle" })
        #expect(child.text == "autonomous child" && owners[child.key] == autonomous)
        #expect(owners[lifecycle.key] == autonomous && lifecycle.fields["status"] == .string("completed"))
        #expect(!entities.values.contains { $0.text.contains("discard after autonomous idle") || $0.text.contains("discard before dispatch") })
        #expect(await f.recording.ownersMissingPriorActivity.isEmpty)
        #expect(await f.recording.failures.isEmpty)
        let frames = try f.frames()
        #expect(frames.filter { $0["method"].string == "session/prompt" }.count == 2)
        #expect(frames.filter { $0["method"].string == "session/set_config_option" }.count == (mode == "copilot-autonomous-config" ? 1 : 0))
    }
}

@Test(.timeLimit(.minutes(1)))
func acpV2IntegrationCopilotMalformedChildMessageIdentityFailsSafely() async throws {
    try await withACP2Integration("copilot-bad-id", integration: .copilot) { f in
        try await f.session.send(text: "Synthetic malformed identity", thread: f.thread())
        try await waitACP2Integration { await !f.recording.failures.isEmpty }
        #expect(await f.recording.failures.contains(CopilotACPBridge.failureMessage))
    }
}

// A task-owned local peer only: no network, provider credentials or real CLI.
private let acp2IntegrationPeer = #"""
import json, sys
mode, log = sys.argv[1:]
sid = 'integration-session'
pending = set()
turn = 0
def out(value):
    print(json.dumps(dict(jsonrpc='2.0', **value)), flush=True)
def result(i, value): out(dict(id=i, result=value))
def notice(method, params): out(dict(method=method, params=params))
def state(value): notice('session/update', dict(sessionId=sid, update=dict(sessionUpdate='state_update', state=value, stopReason='end_turn')))
def question(i=37, method='_cursor/ask_question', session=sid, invalid=False):
    params = dict(sessionId=session, toolCallId='question-tool', untrusted='must not reach UI', questions=[dict(id='q', prompt='Choose synthetic values', allowMultiple=True, options=[dict(id='first', label='Same label'), dict(id='second', label='Same label')])])
    if invalid: params['questions'] = []
    out(dict(id=i, method=method, params=params)); pending.add(i)
def plan(i=37):
    out(dict(id=i, method='_cursor/create_plan', params=dict(sessionId=sid, toolCallId='plan-tool', plan='# Synthetic plan\n\nReview only.', todos=[], phases=[]))); pending.add(i)
def raw(kind, **data): notice('_github.com/copilot/sessionEvent', dict(sessionId=sid, type=kind, data=data))
def chunk(text, mid='child-message'):
    notice('session/update', dict(sessionId=sid, update=dict(sessionUpdate='agent_message_chunk', messageId=mid, content=dict(type='text', text=text))))
def finish():
    if mode == 'v1': result(prompt_id, dict(stopReason='end_turn'))
    else: state('idle')
def configuration(value='default'):
    return [dict(configId='model', category='model', type='select', currentValue=value, options=[dict(value='default', name='Default'), dict(value='changed', name='Changed')])]
for line in sys.stdin:
    frame = json.loads(line)
    with open(log, 'a') as f: f.write(json.dumps(frame)+'\n')
    method, i = frame.get('method'), frame.get('id')
    if method == 'initialize':
        if mode == 'v1': result(i, dict(protocolVersion=1, agentInfo=dict(name='Synthetic peer', version='1'), agentCapabilities=dict(loadSession=True), authMethods=[]))
        else: result(i, dict(protocolVersion=2, info=dict(name='Synthetic peer', version='2'), capabilities=dict(session=dict(resume={}, prompt=dict(image={}))), authMethods=[]))
    elif method in ('session/new', 'session/resume', 'session/load'):
        if mode == 'copilot-config-idle': state('running')
        result(i, dict(sessionId=sid, configOptions=configuration() if mode in ('copilot-config-idle', 'copilot-autonomous-config') else []))
        if mode == 'idle': question()
    elif method == 'session/set_config_option':
        state('idle')
        raw('assistant.message_delta', deltaContent='discard before dispatch'); chunk('discard before dispatch', 'predispatch-root')
        if mode == 'copilot-autonomous-config':
            raw('assistant.message_delta', deltaContent='autonomous child', parentToolCallId='autonomous-task'); chunk('autonomous child', 'autonomous-child')
            raw('subagent.completed', toolCallId='autonomous-task')
        result(i, dict(configOptions=configuration('changed')))
    elif method == 'session/prompt':
        turn += 1; prompt_id = i
        if mode != 'v1': state('running'); result(i, dict(messageId='user-'+str(turn)))
        if mode in ('questions', 'questions-alias', 'v1', 'skip', 'unnegotiated'):
            question(method='cursor/ask_question' if mode == 'questions-alias' else '_cursor/ask_question')
        elif mode in ('plan-accept', 'plan-decline'): plan()
        elif mode == 'remote-cancel':
            question(); notice('$/cancel_request', dict(requestId=37))
        elif mode == 'stop': question(); plan(38)
        elif mode == 'duplicate': question(); question()
        elif mode == 'invalid': question(invalid=True); question(38, session='foreign-session')
        elif mode == 'cursor-notices':
            notice('_cursor/update_todos', dict(sessionId=sid, toolCallId='todos', merge=False, todos=[dict(id='first', content='Synthetic first', status='pending')]))
            notice('cursor/update_todos', dict(sessionId=sid, toolCallId='todos', merge=True, todos=[dict(id='second', content='Synthetic second', status='completed')]))
            notice('_cursor/task', dict(sessionId=sid, toolCallId='cursor-task', description='Synthetic task', prompt='Synthetic nested prompt', subagentType='explore', untrusted='discard'))
            notice('_cursor/generate_image', dict(sessionId=sid, toolCallId='cursor-image', description='Synthetic image', filePath='/not-opened/synthetic.png'))
            state('idle')
            notice('_cursor/task', dict(sessionId=sid, toolCallId='unowned-idle', description='Do not attribute', prompt='Late idle activity', subagentType='explore'))
            notice('session/update', dict(sessionId=sid, update=dict(sessionUpdate='session_info_update', fixtureBoundary='after-idle')))
        elif mode == 'copilot-config-idle':
            raw('assistant.message_delta', deltaContent='after configuration'); chunk('after configuration', 'configured-root')
            state('idle')
        elif mode in ('copilot-autonomous', 'copilot-autonomous-config'):
            if turn == 1:
                raw('assistant.message_delta', deltaContent='first user'); chunk('first user', 'root-first')
                state('idle'); state('running')
                raw('assistant.message_delta', deltaContent='autonomous root'); chunk('autonomous root', 'autonomous-root')
                notice('session/update', dict(sessionId=sid, update=dict(sessionUpdate='tool_call', toolCallId='autonomous-task', status='completed', rawInput=dict(agent_type='explore', prompt='Synthetic autonomous child', mode='background'))))
                if mode == 'copilot-autonomous':
                    state('idle')
                    raw('assistant.message_delta', deltaContent='discard after autonomous idle'); chunk('discard after autonomous idle', 'late-autonomous-root')
                    raw('assistant.message_delta', deltaContent='autonomous child', parentToolCallId='autonomous-task'); chunk('autonomous child', 'autonomous-child')
                    raw('subagent.completed', toolCallId='autonomous-task')
                notice('session/update', dict(sessionId=sid, update=dict(sessionUpdate='session_info_update', fixtureBoundary='autonomous-idle' if mode == 'copilot-autonomous' else 'autonomous-running')))
            else:
                raw('assistant.message_delta', deltaContent='second user'); chunk('second user', 'root-second')
                state('idle')
        elif mode.startswith('copilot'):
            if turn == 1:
                notice('session/update', dict(sessionId=sid, update=dict(sessionUpdate='tool_call', toolCallId='task', status='completed', rawInput=dict(agent_type='explore', prompt='Synthetic child', mode='background'))))
                raw('assistant.message_delta', deltaContent='root first'); chunk('root first', 'root-first')
                if mode == 'copilot-bad-id': raw('assistant.message_delta', deltaContent='invalid', parentToolCallId='task'); chunk('invalid', 42)
                else:
                    state('idle')
                    raw('assistant.message_delta', deltaContent='discard late root'); chunk('discard late root', 'late-root')
                    raw('assistant.message_delta', deltaContent='idle child\n', parentToolCallId='task'); chunk('idle child\n')
            else:
                raw('assistant.message_delta', deltaContent='next child 🌍', parentToolCallId='task'); chunk('next child 🌍')
                raw('assistant.message_delta', deltaContent='discard unknown child', parentToolCallId='unknown'); chunk('discard unknown child', 'unknown-child')
                raw('assistant.message_delta', deltaContent='root second'); chunk('root second', 'root-second')
                raw('subagent.completed', toolCallId='task')
                raw('assistant.message_delta', deltaContent='discard ended child', parentToolCallId='task'); chunk('discard ended child', 'ended-child')
                state('idle')
    elif method == 'session/cancel': state('idle')
    elif method == 'session/close': result(i, {}); break
    elif method == '$/cancel_request': pass
    elif method is None and i in pending:
        pending.remove(i)
        if mode == 'remote-cancel' and frame.get('result', {}).get('outcome', {}).get('outcome') == 'cancelled': question()
        elif not pending and mode != 'idle': finish()
"""#
