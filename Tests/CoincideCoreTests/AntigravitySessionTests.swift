import Darwin
import Foundation
import Testing
@testable import CoincideCore

@Test func contextHandoffAntigravityCarriesSeparateHistoricalAndLiteralTextBlocks() async throws {
    try await withAntigravity { fixture, session, _ in
        let input = try contextHandoffTestInput()
        try await session.send(input: input, thread: fixture.thread())
        try await antigravityEventually { try !fixture.rows("prompt").isEmpty }
        let prompt = try #require(fixture.rows("prompt").first)
        #expect(prompt["prompt"].array?.compactMap { $0["text"].string } == (try input.providerTextBlocks()))
    }
}

actor AntigravityObserved {
    var completions: [(UUID?, ThreadState)] = []
    var failures = 0, returnedStops = 0
    var requests: [ApprovalRequest] = []
    var dismissed: [JSONValue] = []
    var entities: [ProviderEntityKey: ProviderEntity] = [:]
    var owners: [ProviderEntityKey: UUID] = [:]
    func append(_ event: ProviderEvent, owner: UUID? = nil) {
        switch event {
        case .context(let id, let event): append(event, owner: id)
        case .completed(let state): completions.append((owner, state))
        case .failure, .connectionClosed: failures += 1
        case .sessionApproval(let request): requests.append(request)
        case .sessionApprovalDismissed(let id): dismissed.append(id)
        case .entity(let update): apply(update, owner: owner)
        case .runEntity(let id, let update): apply(update, owner: id)
        default: break
        }
    }
    private func apply(_ update: ProviderEntityUpdate, owner: UUID?) {
        entities[update.key] = try? update.apply(to: entities[update.key]); if let owner { owners[update.key] = owner }
    }
    func stopped() { returnedStops += 1 }
}
struct AntigravityFixture: Sendable {
    let root: URL, executable: URL, state: URL, configuration: AntigravityConfiguration
    init(options: [String: JSONValue] = [:]) throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("coincide-antigravity-\(UUID())", isDirectory: true).standardizedFileURL.resolvingSymlinksInPath()
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        executable = root.appendingPathComponent("agy_acp_server.par"); state = root.appendingPathComponent("state")
        let source = try #require(Bundle.module.url(forResource: "antigravity_acp_server", withExtension: "py", subdirectory: "Fixtures"))
        try FileManager.default.copyItem(at: source, to: executable)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: executable.path)
        let harness = root.appendingPathComponent("localharness_external")
        try Data("#!/bin/sh\nexit 0\n".utf8).write(to: harness)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: harness.path)
        configuration = .init(instanceID: UUID(), executable: executable.path, authGeneration: UUID())
        try JSONEncoder().encode(JSONValue.object(options)).write(to: root.appendingPathComponent("options.json"), options: .atomic)
        try AntigravityAccountRegistry.save(.init(configuration: configuration, accessState: .verified), rootURL: root.appendingPathComponent("AntigravitySettings"))
    }
    func set(_ key: String, _ value: JSONValue) throws {
        let file = root.appendingPathComponent("options.json")
        var options = try JSONDecoder().decode(JSONValue.self, from: Data(contentsOf: file)).object ?? [:]
        options[key] = value; try JSONEncoder().encode(JSONValue.object(options)).write(to: file, options: .atomic)
    }
    func rows(_ kind: String? = nil) throws -> [JSONValue] {
        let file = root.appendingPathComponent("wire.jsonl")
        guard FileManager.default.fileExists(atPath: file.path) else { return [] }
        let data = try Data(contentsOf: file)
        guard let last = data.lastIndex(of: 10) else { return [] }
        let rows = try data[...last].split(separator: 10).map { try JSONDecoder().decode(JSONValue.self, from: Data($0)) }
        return kind.map { kind in rows.filter { $0["kind"] == .string(kind) } } ?? rows
    }
    func signal(_ name: String) throws {
        let process = try #require(try rows("process").last)
        try set("signal", .object(["name": .string(name), "id": .string(UUID().uuidString), "pid": process["pid"]]))
    }
    var stopped: Bool {
        guard let processes = try? rows("process") else { return false }
        return processes.allSatisfy { value in
            guard case .number(let raw) = value["pid"], let pid = Int32(exactly: raw), pid > 0 else { return false }
            return kill(pid, 0) < 0 && errno == ESRCH
        }
    }
    func remove() throws { guard stopped else { throw CoincideError("The owned native fixture is still alive; its files were preserved.") }; try FileManager.default.removeItem(at: root) }
    func thread(model: String? = nil, permission: PermissionMode = .supervised, resume: String? = nil) -> CodingThread {
        var thread = CodingThread(project: .init(path: root.path)); thread.provider = .antigravity
        thread.antigravityConfiguration = configuration.selecting(model: model); thread.model = model ?? ""; thread.permission = permission; thread.providerThreadID = resume
        thread.activeRun = .init(id: UUID(), configuration: .init(thread: thread), startedAt: .now); return thread
    }
    func session(permission: PermissionMode = .supervised, allowedFiles: Bool = true) -> AntigravitySession {
        .init(executable: executable, cwd: root, configuration: configuration, permission: permission,
              fileAccessGuard: { _, _ in if !allowedFiles { throw CoincideError("Fixture lock holds this path.") } }, stateRoot: state)
    }
}
func antigravityEventually(_ predicate: () async throws -> Bool) async throws {
    let deadline = ContinuousClock.now + .seconds(8)
    while !(try await predicate()) {
        guard ContinuousClock.now < deadline else { throw CoincideError("The synthetic native Antigravity boundary was not observed.") }
        try await Task.sleep(for: .milliseconds(10))
    }
}
private func withAntigravity(_ options: [String: JSONValue] = [:], _ body: (AntigravityFixture, AntigravitySession, AntigravityObserved) async throws -> Void) async throws {
    let fixture = try AntigravityFixture(options: options), session = fixture.session(), observed = AntigravityObserved()
    let reader = Task { for await event in session.events { await observed.append(event) } }
    do {
        try await body(fixture, session, observed); await session.close(); reader.cancel(); await reader.value
        try await antigravityEventually { fixture.stopped }; try fixture.remove()
    } catch { await session.close(); reader.cancel(); await reader.value; try? fixture.remove(); throw error }
}

@Test func antigravityMetadataAuthenticatesSelectedMethodAndVerifiesNativeSessionWithoutPrompt() async throws {
    try await withAntigravity { fixture, session, _ in
        let rows = try await session.models()
        #expect(rows.map(\.id) == ["native-default", "selected"] && rows[0].isDefault)
        let requests = try fixture.rows("request")
        #expect(requests.contains { $0["method"] == .string("authenticate") && $0["params"]["methodId"] == .string("oauth-personal") })
        #expect(requests.contains { $0["method"] == .string("session/new") })
        #expect(!requests.contains { $0["method"] == .string("session/prompt") })
        let entries = FileManager.default.enumerator(at: fixture.state, includingPropertiesForKeys: nil)?.allObjects.compactMap { $0 as? URL } ?? []
        #expect(!entries.contains { $0.pathExtension == "db" || $0.pathExtension == "meta" })
    }
}

@Test func antigravityHealthAndLogoutDoNotPretendToAuthenticateOrSendPrompts() async throws {
    try await withAntigravity { fixture, session, _ in
        let health = try await session.healthCheck(); #expect(health["protocolVersion"] == .number(2))
        try await session.logout()
        let requests = try fixture.rows("request")
        #expect(requests.filter { $0["method"] == .string("initialize") }.count == 2)
        #expect(requests.contains { $0["method"] == .string("logout") })
        #expect(!requests.contains { ["authenticate", "session/new", "session/prompt"].contains($0["method"].string ?? "") })
    }
}

@Test func antigravityCloseJoinsAnAlreadyClosingMetadataProbe() async throws {
    let fixture = try AntigravityFixture(), session = fixture.session(), observed = AntigravityObserved()
    let held = fixture.root.appendingPathComponent("probe-close-held"), release = fixture.root.appendingPathComponent("release-probe-close")
    let peer = #"""
    #!/usr/bin/python3
    import json, os, signal, sys, time
    root = os.path.dirname(os.path.realpath(__file__))
    def hold_close(_signal, _frame):
        with open(os.path.join(root, "probe-close-held"), "w") as file:
            file.write("owned process is draining")
        while not os.path.exists(os.path.join(root, "release-probe-close")):
            time.sleep(.005)
        sys.exit(0)
    signal.signal(signal.SIGTERM, hold_close)
    with open(os.path.join(root, "wire.jsonl"), "a") as file:
        file.write(json.dumps({"kind": "process", "pid": os.getpid()}) + "\n")
    for line in sys.stdin.buffer:
        frame = json.loads(line)
        value = {"protocolVersion": 2, "agentCapabilities": {}, "agentInfo": {"name": "synthetic"}, "authMethods": [{"id": "oauth-personal"}]}
        print(json.dumps({"jsonrpc": "2.0", "id": frame["id"], "result": value}), flush=True)
    # Runtime closes stdin before signalling. Keep the exact owned process
    # alive through EOF so SIGTERM, rather than interpreter exit, owns the gate.
    while True:
        time.sleep(.005)
    """#
    try Data(peer.utf8).write(to: fixture.executable)
    let reading = Task { try await session.healthCheck() }
    var closing: Task<Void, Never>?
    do {
        // The signal gate proves closeProbe has already begun its real native
        // drain, rather than merely holding an outstanding metadata RPC.
        try await antigravityEventually { FileManager.default.fileExists(atPath: held.path) }
        closing = Task { await session.close(); await observed.stopped() }
        try await Task.sleep(for: .milliseconds(50))
        let returned = await observed.returnedStops
        #expect(returned == 0 && !fixture.stopped)
        try Data().write(to: release)
        _ = try await reading.value; await closing?.value
        #expect(fixture.stopped)
        let remainingProbes = try FileManager.default.contentsOfDirectory(atPath: fixture.state.appendingPathComponent("probes").path)
        #expect(remainingProbes.isEmpty)
        try fixture.remove()
    } catch {
        try? Data().write(to: release)
        await session.close(); _ = await reading.result; await closing?.value
        try? fixture.remove(); throw error
    }
}

@Test func antigravityCapturedControlsPromptResponseAndLateOriginalToolOwnership() async throws {
    try await withAntigravity { fixture, session, observed in
        var first = fixture.thread(model: "selected")
        first.permission = .fullAccess; first.antigravityConfiguration = fixture.configuration.selecting(model: "future-not-captured")
        try await session.send(text: "First", thread: first)
        try await antigravityEventually { await observed.entities.values.contains { $0.text == "Native 日本語 reply" } }
        let held = await observed.completions; #expect(held.isEmpty)
        try fixture.signal("finish"); try await antigravityEventually { await observed.completions.count == 1 }
        let successor = fixture.thread()
        try await session.send(text: "Second", thread: successor)
        try await antigravityEventually { try fixture.rows("prompt").count == 2 }
        try fixture.signal("late-tool")
        try await antigravityEventually { await observed.entities.values.contains { $0.text.contains("Original-run late tool result") } }
        let entities = await observed.entities, owners = await observed.owners
        let tool = try #require(entities.values.first { $0.text.contains("Original-run late tool result") })
        #expect(owners[tool.key] == first.activeRun?.id)
        let prompts = try fixture.rows("prompt")
        #expect(prompts.map { $0["model"].string } == ["selected", "native-default"])
        #expect(prompts.allSatisfy { $0["mode"] == .string("default") })
    }
}

@Test func antigravityColdResumeReappliesSavedModelAndDoesNotReplayOldTools() async throws {
    let fixture = try AntigravityFixture(), first = fixture.session()
    do {
        try await first.send(text: "Seed", thread: fixture.thread(model: "selected"))
        try await antigravityEventually { try fixture.rows("prompt").count == 1 }
        let original = try #require(try fixture.rows("prompt").first?["sessionID"].string)
        try fixture.signal("finish"); await first.close()
        let resumed = fixture.session(), observed = AntigravityObserved()
        let reader = Task { for await event in resumed.events { await observed.append(event) } }
        do {
            try await resumed.send(text: "Resume exact session", thread: fixture.thread(model: "selected", resume: original))
            try await antigravityEventually { try fixture.rows("prompt").count == 2 }
            let requests = try fixture.rows("request"), prompts = try fixture.rows("prompt"), entities = await observed.entities
            #expect(requests.contains { $0["method"] == .string("session/resume") && $0["params"]["sessionId"] == .string(original) })
            #expect(!requests.contains { $0["method"] == .string("session/load") })
            #expect(prompts[1]["model"] == .string("selected") && prompts[1]["sessionID"] == .string(original))
            #expect(!entities.values.contains { $0.text.contains("Old replay") })
            await resumed.close(); reader.cancel(); await reader.value; try fixture.remove()
        } catch { await resumed.close(); reader.cancel(); await reader.value; throw error }
    } catch { await first.close(); try? fixture.remove(); throw error }
}

@Test(arguments: [false, true])
func antigravityQuestionsUseExactNativeOptionIDsAndPersistentGrantsRetainWarning(_ question: Bool) async throws {
    try await withAntigravity(["interaction": .string(question ? "question" : "permission")]) { fixture, session, observed in
        try await session.send(text: "Native interaction", thread: fixture.thread())
        try await antigravityEventually { await observed.requests.count == 1 }
        let request = try #require(await observed.requests.first), parsed = try AntigravityPermissionRequest.presentation(request)
        #expect(parsed.isQuestion == question && parsed.options[1].securityWarning == "This grants future native tool access.")
        do { try await session.choose(request, optionID: "Second label"); Issue.record("A display label was accepted instead of exact native ID.") } catch {}
        if question {
            do { try await session.respond(request, allow: true); Issue.record("A generic Allow answered a native question.") } catch {}
            try await session.selectAnswers(request, selections: [parsed.toolCallID: ["id-two"]])
        } else { try await session.choose(request, optionID: "id-two") }
        try await antigravityEventually { try fixture.rows("clientResponse").count == 1 }
        let responses = try fixture.rows("clientResponse")
        #expect(responses[0]["wireID"] == .number(700) && responses[0]["value"]["outcome"]["optionId"] == .string("id-two"))
    }
}

@Test func antigravityNewAuthenticationGenerationRetainsNativeConversationAndCapturedModel() async throws {
    let fixture = try AntigravityFixture(), original = fixture.session()
    do {
        try await original.send(text: "Original generation", thread: fixture.thread(model: "selected"))
        try await antigravityEventually { try fixture.rows("prompt").count == 1 }
        let native = try #require(try fixture.rows("prompt").first?["sessionID"].string)
        await original.close()
        let nextConfiguration = AntigravityConfiguration(instanceID: fixture.configuration.instanceID, executable: fixture.executable.path, authGeneration: UUID(), model: "selected")
        let next = AntigravitySession(executable: fixture.executable, cwd: fixture.root, configuration: nextConfiguration,
                                      fileAccessGuard: { _, _ in }, stateRoot: fixture.state)
        do {
            var thread = fixture.thread(model: "selected", resume: native)
            thread.antigravityConfiguration = nextConfiguration
            thread.activeRun = .init(id: UUID(), configuration: .init(thread: thread), startedAt: .now)
            try await next.send(text: "Same conversation after explicit account generation change", thread: thread)
            try await antigravityEventually { try fixture.rows("prompt").count == 2 }
            let prompts = try fixture.rows("prompt")
            #expect(prompts[1]["sessionID"] == .string(native) && prompts[1]["model"] == .string("selected"))
            await next.close(); try fixture.remove()
        } catch { await next.close(); throw error }
    } catch { await original.close(); try? fixture.remove(); throw error }
}

@Test func antigravityStopWaitsForPromptTerminalAndHeldConfigurationCannotReachSuccessor() async throws {
    try await withAntigravity(["holdCancel": .bool(true)]) { fixture, session, observed in
        let first = fixture.thread(); try await session.send(text: "Stop exact native prompt", thread: first)
        try await antigravityEventually { try fixture.rows("prompt").count == 1 }
        let id = try #require(first.activeRun?.id)
        let stopping = Task { try await session.interrupt(expectedRunID: id); await observed.stopped() }
        defer { stopping.cancel() }
        try await antigravityEventually { try fixture.rows("cancel").count == 1 }
        let before = await observed.completions, returned = await observed.returnedStops
        #expect(before.isEmpty && returned == 0)
        try fixture.signal("cancelled"); try await stopping.value
        try await antigravityEventually { await observed.completions.count == 1 }
        try fixture.set("holdModel", .bool(true))
        let sending = Task { try await session.send(text: "Must not be sent", thread: fixture.thread(model: "selected")) }
        try await antigravityEventually {
            try fixture.rows("request").filter { $0["method"] == .string("session/set_config_option") && $0["params"]["configId"] == .string("model") }.count == 2
        }
        do { try await session.interrupt() } catch {}
        do { try await sending.value; Issue.record("A stopped uncertain configuration sent its prompt.") } catch {}
        do { try await session.send(text: "No unsafe successor", thread: fixture.thread()); Issue.record("An uncertain host was reused.") } catch {}
        let prompts = try fixture.rows("prompt"); #expect(prompts.count == 1)
    }
}

@Test func antigravityDelegatedFilesAreRealAndEOFNeverManufacturesPromptCompletion() async throws {
    try await withAntigravity(["delegateFiles": .bool(true)]) { fixture, session, _ in
        try await session.send(text: "Delegated contained file", thread: fixture.thread())
        try await antigravityEventually { try fixture.rows("clientResponse").count == 1 }
        #expect(try String(contentsOf: fixture.root.appendingPathComponent("delegated.txt"), encoding: .utf8) == "first\nsecond\nthird")
    }
    try await withAntigravity(["eof": .bool(true)]) { fixture, session, observed in
        try await session.send(text: "Lost native transport", thread: fixture.thread())
        try await antigravityEventually { await observed.failures == 1 }
        let completions = await observed.completions; #expect(completions.isEmpty)
        let prompts = try fixture.rows("prompt"); #expect(prompts.count == 1)
    }
}

@Test func antigravityClientFilesHonorAnchoredContainmentLineRangesGitMetadataAndLocks() async throws {
    let fixture = try AntigravityFixture()
    let files = try AntigravityClientFiles(root: fixture.root, accessGuard: { _, _ in })
    do {
        let path = fixture.root.appendingPathComponent("nested/text.txt")
        _ = try await files.write(params: .object(["path": .string(path.path), "content": .string("one\ntwo\nthree")]))
        let read = try await files.read(params: .object(["path": .string(path.path), "line": .number(2), "limit": .number(1)]))
        #expect(read["content"] == .string("two"))
        let git = fixture.root.appendingPathComponent(".git/contained.txt")
        _ = try await files.write(params: .object(["path": .string(git.path), "content": .string("native permission already granted")]))
        #expect(FileManager.default.fileExists(atPath: git.path))
        let largerThanEditorLimit = String(repeating: "x", count: 3_000_000)
        _ = try await files.write(params: .object(["path": .string(path.path), "content": .string(largerThanEditorLimit)]))
        let largeRead = try await files.read(params: .object(["path": .string(path.path)]))
        #expect(largeRead["content"].string?.utf8.count == 3_000_000)
        do {
            _ = try await files.write(params: .object(["path": .string(path.path), "content": .string(String(repeating: "x", count: AntigravityClientFiles.maximumBytes + 1))]))
            Issue.record("The native 8 MiB write bound was ignored.")
        } catch {}
        try FileManager.default.createSymbolicLink(at: fixture.root.appendingPathComponent("outside"), withDestinationURL: fixture.root.deletingLastPathComponent())
        do { _ = try await files.write(params: .object(["path": .string(fixture.root.appendingPathComponent("outside/unowned.txt").path), "content": .string("No") ])); Issue.record("An outside symlink escaped containment.") } catch {}
        let denied = try AntigravityClientFiles(root: fixture.root, accessGuard: { _, _ in throw CoincideError("Locked") })
        do { _ = try await denied.write(params: .object(["path": .string(path.path), "content": .string("No") ])); Issue.record("The workspace lock was ignored.") } catch {}
        await denied.close(); await files.close(); try fixture.remove()
    } catch { await files.close(); try? fixture.remove(); throw error }
}
