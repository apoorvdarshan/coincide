import Foundation
import Testing
@testable import CoincideCore

private actor ACPV1LifecycleRecording {
    private(set) var text = ""
    private(set) var completed = 0
    private(set) var failures: [String] = []
    func receive(_ event: ProviderEvent) {
        switch event {
        case .context(_, let inner): receive(inner)
        case .delta(_, _, let value): text += value
        case .completed: completed += 1
        case .failure(let reason), .connectionClosed(let reason): failures.append(reason)
        default: break
        }
    }
}

private struct ACPV1LifecycleFixture {
    let root: URL
    let gate: URL
    let log: URL
    let session: ACPSession
    let recording: ACPV1LifecycleRecording
    func thread() -> CodingThread {
        var thread = CodingThread(project: WorkspaceProject(path: root.path)); thread.provider = .acp; thread.model = "changed"
        thread.activeRun = .init(id: UUID(), configuration: .init(thread: thread), startedAt: .now)
        return thread
    }
    func frames() throws -> [JSONValue] {
        guard FileManager.default.fileExists(atPath: log.path) else { return [] }
        let data = try Data(contentsOf: log)
        guard let end = data.lastIndex(of: 10) else { return [] }
        return try data[...end].split(separator: 10).map { try JSONDecoder().decode(JSONValue.self, from: Data($0)) }
    }
}

private func withACPV1Lifecycle(_ mode: String, integration: ACPIntegration,
                                body: (ACPV1LifecycleFixture) async throws -> Void) async throws {
    let root = try temporaryWorkspace(); defer { try? FileManager.default.removeItem(at: root) }
    let script = root.appendingPathComponent("peer.py"), gate = root.appendingPathComponent("release"), log = root.appendingPathComponent("wire.jsonl")
    try Data(acpV1LifecyclePeer.utf8).write(to: script)
    let session = try ACPSession(executable: URL(fileURLWithPath: "/usr/bin/python3"), arguments: ["-u", script.path, mode, gate.path, log.path],
                                 cwd: root, cancellationTimeout: .seconds(2), integration: integration)
    let recording = ACPV1LifecycleRecording()
    let reader = Task { for await event in session.events { await recording.receive(event) } }
    do {
        try await body(.init(root: root, gate: gate, log: log, session: session, recording: recording))
        try Data().write(to: gate); await session.close(); await reader.value
    } catch {
        try? Data().write(to: gate); await session.close(); await reader.value; throw error
    }
}

private func waitACPV1Lifecycle(_ predicate: () async throws -> Bool) async throws {
    let deadline = ContinuousClock.now + .seconds(8)
    while try await !predicate() {
        guard ContinuousClock.now < deadline else { throw CoincideError("The synthetic ACP v1 lifecycle boundary was not reached.") }
        try await Task.sleep(for: .milliseconds(10))
    }
}

@Test(.timeLimit(.minutes(1)))
func acpV1IntegrationCopilotConfigurationOutputCannotAcquireUnsentPromptOwnership() async throws {
    try await withACPV1Lifecycle("stale-output", integration: .copilot) { f in
        try await f.session.send(text: "Synthetic actual prompt", thread: f.thread())
        try await waitACPV1Lifecycle { await f.recording.completed == 1 }
        #expect(await f.recording.text == "actual prompt output")
        #expect(await f.recording.failures.isEmpty)
        let frames = try f.frames()
        #expect(frames.filter { $0["method"].string == "session/set_config_option" }.count == 1)
        #expect(frames.filter { $0["method"].string == "session/prompt" }.count == 1)
    }
}

@Test(.timeLimit(.minutes(1)), arguments: [ACPIntegration.cursor, .copilot])
func acpV1IntegrationStopDuringHeldConfigurationNeverWritesPromptAfterLateReply(_ integration: ACPIntegration) async throws {
    try await withACPV1Lifecycle("held-config", integration: integration) { f in
        let send = Task { try await f.session.send(text: "must remain unsent", thread: f.thread()) }
        do {
            try await waitACPV1Lifecycle { FileManager.default.fileExists(atPath: f.gate.path + ".config") }
            try await f.session.interrupt()
            try await waitACPV1Lifecycle { try f.frames().contains { $0["method"].string == "session/cancel" } }
            try Data().write(to: f.gate)
            do { try await send.value; Issue.record("Stop allowed a configured ACP prompt to be sent.") }
            catch is CancellationError { /* The final post-configuration guard must reject it. */ }
            try await waitACPV1Lifecycle { FileManager.default.fileExists(atPath: f.gate.path + ".replied") }
            let frames = try f.frames()
            #expect(frames.filter { $0["method"].string == "session/set_config_option" }.count == 1)
            #expect(!frames.contains { $0["method"].string == "session/prompt" })
            #expect(await f.recording.text.isEmpty)
            #expect(await f.recording.completed == 0)
            #expect(await f.recording.failures.isEmpty)
        } catch {
            try? Data().write(to: f.gate); send.cancel(); await f.session.close(); _ = try? await send.value
            throw error
        }
    }
}

// Only a task-owned peer is run by these tests. It never opens a real provider.
private let acpV1LifecyclePeer = #"""
import json, os, sys, threading, time
mode, gate, log = sys.argv[1:]
lock = threading.Lock()
sid = 'lifecycle-session'
def out(value):
    with lock:
        print(json.dumps(dict(jsonrpc='2.0', **value)), flush=True)
def result(i, value): out(dict(id=i, result=value))
def raw(text):
    out(dict(method='_github.com/copilot/sessionEvent', params=dict(sessionId=sid, type='assistant.message_delta', data=dict(deltaContent=text))))
    out(dict(method='session/update', params=dict(sessionId=sid, update=dict(sessionUpdate='agent_message_chunk', messageId='native-message', content=dict(type='text', text=text)))))
def options(value):
    return [dict(id='model', category='model', type='select', name='Model', currentValue=value, options=[dict(value='default', name='Default'), dict(value='changed', name='Changed')])]
def configured(i):
    deadline = time.monotonic()+5
    while not os.path.exists(gate) and time.monotonic() < deadline: time.sleep(.01)
    result(i, dict(configOptions=options('changed')))
    open(gate+'.replied', 'w').close()
for line in sys.stdin:
    frame = json.loads(line)
    with open(log, 'a') as f: f.write(json.dumps(frame)+'\n')
    method, i = frame.get('method'), frame.get('id')
    if method == 'initialize': result(i, dict(protocolVersion=1, agentInfo=dict(name='Synthetic lifecycle peer', version='1'), agentCapabilities=dict(loadSession=True)))
    elif method == 'session/new': result(i, dict(sessionId=sid, configOptions=options('default')))
    elif method == 'session/set_config_option':
        if mode == 'held-config':
            open(gate+'.config', 'w').close()
            threading.Thread(target=configured, args=(i,), daemon=True).start()
        else:
            raw('stale configuration output')
            result(i, dict(configOptions=options('changed')))
    elif method == 'session/prompt':
        raw('actual prompt output')
        result(i, dict(stopReason='end_turn'))
    elif method == 'session/cancel': pass
"""#
