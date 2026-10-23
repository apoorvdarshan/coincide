import Foundation
import Testing
@testable import CoincideCore

private let claudeSingleQuestion = " Choose one / 工作? "
private let claudeMultipleQuestion = "Which features, exactly?"

private func claudeQuestionRequest(_ mutate: (inout [String: JSONValue]) -> Void = { _ in }) -> ApprovalRequest {
    var input: [String: JSONValue] = ["questions": .array([
        .object(["question": .string(claudeSingleQuestion), "header": .string("Single"), "multiSelect": .bool(false),
            "options": .array([.object(["label": .string("a/b"), "description": .string("Slash")]),
                .object(["label": .string("a b"), "description": .string("Space")])])]),
        .object(["question": .string(claudeMultipleQuestion), "header": .string("Multiple"), "multiSelect": .bool(true),
            "options": .array([.object(["label": .string("First, literal"), "description": .string("Comma")]),
                .object(["label": .string("Second 🌍"), "description": .string("Unicode")])])])
    ]), "future": .object(["preserved": .bool(true)])]
    mutate(&input)
    return .init(id: .string("question-1"), method: "can_use_tool", params: .object([
        "tool_name": .string("AskUserQuestion"), "input": .object(input)]))
}

@Test func claudeQuestionAnswersKeepExactQuestionKeysLabelsCustomTextAndUnknownInput() throws {
    let request = claudeQuestionRequest(), questions = try ClaudeQuestionRequest(request: request)
    #expect(request.isQuestion && request.isClaudeQuestion && request.claudeQuestion == questions)
    #expect(request.title == "Answer Claude questions")
    #expect(questions.questions.map(\.question) == [claudeSingleQuestion, claudeMultipleQuestion])
    let selections = [claudeSingleQuestion: ["a/b"], claudeMultipleQuestion: ["First, literal", "Second 🌍", " custom, 工作 "]]
    let response = try questions.response(selections: selections, notes: [claudeMultipleQuestion: " exact notes "])
    #expect(response["behavior"] == .string("allow"))
    #expect(response["updatedInput"]["questions"] == request.params["input"]["questions"])
    #expect(response["updatedInput"]["future"] == .object(["preserved": .bool(true)]))
    #expect(response["updatedInput"]["answers"][claudeSingleQuestion] == .string("a/b"))
    #expect(response["updatedInput"]["answers"][claudeMultipleQuestion] == .string("First, literal, Second 🌍,  custom, 工作 "))
    #expect(response["updatedInput"]["annotations"][claudeMultipleQuestion]["notes"] == .string(" exact notes "))
    let generic = try questions.response(answers: [claudeSingleQuestion: " A, B / custom ", claudeMultipleQuestion: "other"])
    #expect(generic["updatedInput"]["answers"][claudeSingleQuestion] == .string(" A, B / custom "))
}

@Test func claudeQuestionsRejectMalformedDuplicateAndUnboundedNativeShapes() throws {
    let base = claudeQuestionRequest(), values = try #require(base.params["input"]["questions"].array)
    var invalidInputs: [JSONValue] = [
        .null, .object(["questions": .array([])]), .object(["questions": .array(Array(repeating: values[0], count: 5))]),
        .object(["questions": .array([values[0], values[0]])])
    ]
    for (key, value) in [("question", JSONValue.string(" \n")), ("question", .string(String(repeating: "x", count: 16_385))),
        ("question", .string("nul\0text")), ("multiSelect", .string("true")), ("header", .number(3)),
        ("options", .array([])), ("options", .array([.object(["label": .string("same")]), .object(["label": .string("same")])])),
        ("options", .array([.object(["label": .string("x"), "preview": .bool(false)])]))] {
        var changed = try #require(values[0].object); changed[key] = value
        invalidInputs.append(.object(["questions": .array([.object(changed)])]))
    }
    for input in invalidInputs {
        var request = base; request.params = .object(["tool_name": .string("AskUserQuestion"), "input": input])
        #expect(request.claudeQuestion == nil)
        #expect(throws: CoincideError.self) { try ClaudeQuestionRequest(request: request) }
    }
    var nonQuestion = base; nonQuestion.params = .object(["tool_name": .string("Bash"), "input": base.params["input"]])
    #expect(nonQuestion.claudeQuestion == nil)
}

@Test func claudeQuestionSelectionValidationRejectsMissingExtraDuplicateAndInvalidSingleAnswers() throws {
    let question = try ClaudeQuestionRequest(request: claudeQuestionRequest())
    let valid = [claudeSingleQuestion: ["a/b"], claudeMultipleQuestion: ["Second 🌍"]]
    var cases: [[String: [String]]] = [[:], [claudeSingleQuestion: ["a/b"]]]
    var extra = valid; extra["foreign"] = ["answer"]; cases.append(extra)
    for invalid in [[], ["a/b", "a b"], ["a/b", "a/b"], [" \n"], ["nul\0text"], [String(repeating: "x", count: 16_385)]] {
        var changed = valid; changed[claudeSingleQuestion] = invalid; cases.append(changed)
    }
    for selections in cases { #expect(throws: CoincideError.self) { try question.response(selections: selections) } }
    #expect(throws: CoincideError.self) { try question.response(selections: valid, notes: ["foreign": "note"]) }
    #expect(throws: CoincideError.self) { try question.response(answers: [claudeSingleQuestion: "answer"]) }
    #expect(throws: CoincideError.self) { try question.response(answers: [claudeSingleQuestion: "answer", claudeMultipleQuestion: " "]) }
}

@Test func claudeQuestionKeysRequireExactNativeUnicodeSpelling() throws {
    let request = claudeQuestionRequest { input in
        var questions = input["questions"]!.array!, field = questions[0].object!
        field["question"] = .string("Caf\u{00e9}?"); questions[0] = .object(field); input["questions"] = .array(questions)
    }
    let question = try ClaudeQuestionRequest(request: request)
    #expect(throws: CoincideError.self) {
        try question.response(answers: ["Cafe\u{0301}?": "a/b", claudeMultipleQuestion: "Second 🌍"])
    }
    #expect(throws: CoincideError.self) {
        try question.response(selections: ["Cafe\u{0301}?": ["a/b"], claudeMultipleQuestion: ["Second 🌍"]])
    }
    let response = try question.response(answers: ["Caf\u{00e9}?": "a/b", claudeMultipleQuestion: "Second 🌍"])
    let key = try #require(response["updatedInput"]["answers"].object?.keys.first { $0 == "Caf\u{00e9}?" })
    #expect(Array(key.utf8) == Array("Caf\u{00e9}?".utf8))
}

@Test(arguments: ["text", "selections", "notes", "cancel"])
func claudeQuestionCommandsValidateAndCaptureNativeResponsesAtAdmission(kind: String) throws {
    var fixture = RunHistoryFixture(); fixture.snapshot.threads[0].provider = .claude
    try fixture.submit("Explicit question input"); try fixture.connect()
    let request = claudeQuestionRequest(); try fixture.event(.approval(request))
    let before = fixture.snapshot
    let invalidResponses: [ProviderApprovalResponse] = [.decision(true), .answers(["foreign": "answer"]), .selections([:]),
        .selectionsWithNotes(selections: [claudeSingleQuestion: ["a/b"], claudeMultipleQuestion: ["Second 🌍"]], notes: ["foreign": "note"])]
    for invalid in invalidResponses {
        #expect(throws: (any Error).self) {
            try fixture.command(.client(.respond(threadID: fixture.threadID, requestID: request.id, response: invalid)))
        }
        #expect(fixture.snapshot == before)
    }
    let selections = [claudeSingleQuestion: ["a/b"], claudeMultipleQuestion: ["First, literal", "Second 🌍"]]
    let response: ProviderApprovalResponse
    switch kind {
    case "text": response = .answers([claudeSingleQuestion: " custom ", claudeMultipleQuestion: "First, literal, Second 🌍"])
    case "selections": response = .selections(selections)
    case "notes": response = .selectionsWithNotes(selections: selections, notes: [claudeSingleQuestion: " exact notes "])
    default: response = .decision(false)
    }
    let decision = try fixture.command(.client(.respond(threadID: fixture.threadID, requestID: request.id, response: response)))
    let effect = try #require(decision.effects.first)
    #expect(try JSONDecoder().decode(PendingWorkspaceEffect.self, from: JSONEncoder().encode(effect)) == effect)
    guard case .providerRespond(_, _, let captured, let capturedResponse) = effect.request else {
        Issue.record("The Claude question response did not reach its provider effect."); return
    }
    #expect(captured == request && capturedResponse == response)
    #expect(fixture.thread.runtimeRequests.first?.responding == true)
}

@Test(.timeLimit(.minutes(1))) func claudeQuestionEngineRoutesSelectedAnswersNotesAndCancellationToNativeControl() async throws {
    for scenario in ["selections", "decline"] {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("coincide-claude-question-engine-\(UUID())")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        let peer = try #require(Bundle.module.url(forResource: "claude_questions", withExtension: "py", subdirectory: "Fixtures"))
        let project = WorkspaceProject(path: root.path)
        var thread = CodingThread(project: project); thread.provider = .claude; thread.model = "fixture-model"; thread.checkpointPolicy = .disabled
        let engine = try WorkspaceEngine(url: root.appendingPathComponent("workspace.sqlite"), providerFactory: { _ in
            try ClaudeSession(executable: URL(fileURLWithPath: "/usr/bin/python3"), cwd: root, arguments: [peer.path, scenario, root.path])
        }, identityResolver: { _ in nil })
        do {
            _ = try await engine.load()
            _ = try await engine.dispatch(.addProjectWithThread(project: project, thread: thread))
            _ = try await engine.dispatch(.submit(threadID: thread.id, text: "Explicit native question input"))
            let deadline = ContinuousClock.now + .seconds(10)
            var pending: ApprovalRequest?
            while pending == nil {
                pending = await engine.current().snapshot.threads.first { $0.id == thread.id }?.runtimeRequests.first?.request
                if ContinuousClock.now >= deadline { throw CoincideError("The Claude question engine did not present its request.") }
                if pending == nil { try await Task.sleep(for: .milliseconds(5)) }
            }
            let request = try #require(pending)
            let response: ProviderApprovalResponse = scenario == "decline" ? .decision(false)
                : .selectionsWithNotes(selections: [claudeSingleQuestion: ["a/b"], claudeMultipleQuestion: ["First, literal", "Second 🌍", "custom answer"]],
                    notes: [claudeSingleQuestion: " exact notes 🌍 "])
            let receipt = try await engine.dispatch(.respond(threadID: thread.id, requestID: request.id, response: response))
            #expect(receipt.rejection == nil)
            var completed = false
            while !completed {
                let current = await engine.current().snapshot.threads.first { $0.id == thread.id }
                completed = current?.activeRun == nil && current?.messages.contains { $0.role == .assistant && $0.text == "QUESTION_DONE" } == true
                if ContinuousClock.now >= deadline { throw CoincideError("The Claude question engine did not complete its answered turn.") }
                if !completed { try await Task.sleep(for: .milliseconds(5)) }
            }
            #expect(await engine.current().snapshot.threads.first { $0.id == thread.id }?.runtimeRequests.isEmpty == true)
            await engine.shutdown()
            try FileManager.default.removeItem(at: root)
        } catch { await engine.shutdown(); try? FileManager.default.removeItem(at: root); throw error }
    }
}

@Test(.timeLimit(.minutes(1))) func claudeQuestionSelectionsRoundTripAndRejectForgedInvalidAndRepeatedResponses() async throws {
    let fixture = try ClaudeQuestionFixture("selections")
    do {
        try await fixture.session.send(text: "Explicit question input", thread: fixture.thread)
        let request = try await fixture.request()
        var forged = request; forged.params = .object(["tool_name": .string("AskUserQuestion"), "input": .object(["questions": .array([])])])
        await #expect(throws: CoincideError.self) { try await fixture.session.respond(forged, allow: false) }
        await #expect(throws: CoincideError.self) { try await fixture.session.answer(forged, answers: [:]) }
        var forgedParams = try #require(request.params.object), forgedInput = try #require(request.params["input"].object)
        forgedInput["metadata"] = .object(["source": .string("synthetic"), "unicode": .string("Cafe\u{0301}")])
        forgedParams["input"] = .object(forgedInput); forged.params = .object(forgedParams)
        await #expect(throws: CoincideError.self) { try await fixture.session.answer(forged,
            answers: [claudeSingleQuestion: "answer", claudeMultipleQuestion: "answer"]) }
        await #expect(throws: CoincideError.self) { try await fixture.session.selectAnswers(request, selections: [claudeSingleQuestion: ["a/b", "a b"], claudeMultipleQuestion: ["Second 🌍"]]) }
        await #expect(throws: CoincideError.self) { try await fixture.session.answer(request, answers: ["missing": "answer"]) }
        try await fixture.session.selectAnswers(request, selections: [claudeSingleQuestion: ["a/b"],
            claudeMultipleQuestion: ["First, literal", "Second 🌍", "custom answer"]], notes: [claudeSingleQuestion: " exact notes 🌍 "])
        await #expect(throws: CoincideError.self) { try await fixture.session.respond(request, allow: false) }
        await #expect(throws: CoincideError.self) { try await fixture.session.selectAnswers(request, selections: [:]) }
        try await fixture.completed()
        let responses = try fixture.responses()
        #expect(responses.count == 1 && responses.first?["subtype"] == .string("success"))
        await fixture.close()
    } catch { await fixture.close(); throw error }
}

@Test(.timeLimit(.minutes(1)), arguments: ["generic", "reused"])
func claudeQuestionGenericTextAndReusedNativeIDsRemainUnambiguous(scenario: String) async throws {
    let fixture = try ClaudeQuestionFixture(scenario)
    do {
        try await fixture.session.send(text: "Explicit input", thread: fixture.thread)
        let request = try await fixture.request()
        try await fixture.session.answer(request, answers: [claudeSingleQuestion: " custom, 工作 🌍 ", claudeMultipleQuestion: "First, literal, Second 🌍"])
        try await fixture.completed()
        if scenario == "reused" {
            try await fixture.session.send(text: "Next explicit input", thread: fixture.thread)
            try await fixture.completed(count: 2)
            #expect(await fixture.observation.requests.count == 1)
            await #expect(throws: CoincideError.self) { try await fixture.session.answer(request, answers: [claudeSingleQuestion: "stale", claudeMultipleQuestion: "stale"]) }
        }
        #expect(try fixture.responses().count == (scenario == "reused" ? 2 : 1))
        await fixture.close()
    } catch { await fixture.close(); throw error }
}

@Test(.timeLimit(.minutes(1))) func claudeQuestionCancellationCannotApproveAnUnansweredForm() async throws {
    let fixture = try ClaudeQuestionFixture("decline")
    do {
        try await fixture.session.send(text: "Explicit input", thread: fixture.thread)
        let request = try await fixture.request()
        await #expect(throws: CoincideError.self) { try await fixture.session.respond(request, allow: true) }
        try await fixture.session.respond(request, allow: false)
        try await fixture.completed()
        #expect(try fixture.responses().first?["response"]["behavior"] == .string("deny"))
        await #expect(throws: CoincideError.self) { try await fixture.session.respond(request, allow: false) }
        await fixture.close()
    } catch { await fixture.close(); throw error }
}

@Test(.timeLimit(.minutes(1)), arguments: ["cancel", "changed"])
func claudeQuestionNativeCancellationAndChangedRetransmissionsDismissOriginalRequest(scenario: String) async throws {
    let fixture = try ClaudeQuestionFixture(scenario)
    do {
        try await fixture.session.send(text: "Explicit input", thread: fixture.thread)
        let request = try await fixture.request()
        try await fixture.wait { FileManager.default.fileExists(atPath: fixture.root.appendingPathComponent("ready").path) }
        try Data().write(to: fixture.root.appendingPathComponent("release"))
        try await fixture.completed()
        #expect(await fixture.observation.requests.count == 1)
        #expect(await fixture.observation.dismissed == [.string("question-1")])
        await #expect(throws: CoincideError.self) { try await fixture.session.answer(request, answers: [claudeSingleQuestion: "stale", claudeMultipleQuestion: "stale"]) }
        #expect(try fixture.responses().count == (scenario == "changed" ? 1 : 0))
        await fixture.close()
    } catch { await fixture.close(); throw error }
}

@Test(.timeLimit(.minutes(1)), arguments: ["malformed", "inactive"])
func claudeQuestionsRejectMalformedAndInactiveRequestsWithoutPresentingThem(scenario: String) async throws {
    let fixture = try ClaudeQuestionFixture(scenario)
    do {
        if scenario == "inactive" { _ = try await fixture.session.models() }
        else { try await fixture.session.send(text: "Explicit input", thread: fixture.thread) }
        try await fixture.wait { try fixture.responses().count == 1 }
        #expect(try fixture.responses().first?["subtype"] == .string("error"))
        #expect(await fixture.observation.requests.isEmpty)
        if scenario != "inactive" { try await fixture.completed() }
        await fixture.close()
    } catch { await fixture.close(); throw error }
}

private actor ClaudeQuestionObservation {
    var requests: [ApprovalRequest] = []
    var dismissed: [JSONValue] = []
    var completed = 0
    var failure: String?
    func accept(_ event: ProviderEvent) {
        switch event {
        case .context(_, let inner): accept(inner)
        case .approval(let request): requests.append(request)
        case .approvalDismissed(let id): dismissed.append(id)
        case .completed: completed += 1
        case .failure(let message): failure = message
        default: break
        }
    }
}

private struct ClaudeQuestionFixture {
    let root: URL
    let session: ClaudeSession
    let observation = ClaudeQuestionObservation()
    let reader: Task<Void, Never>
    var thread: CodingThread {
        var thread = CodingThread(project: .init(path: root.path)); thread.provider = .claude; thread.model = "fixture-model"; return thread
    }
    init(_ scenario: String) throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("coincide-claude-question-\(UUID())")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        let peer = try #require(Bundle.module.url(forResource: "claude_questions", withExtension: "py", subdirectory: "Fixtures"))
        session = try ClaudeSession(executable: URL(fileURLWithPath: "/usr/bin/python3"), cwd: root, arguments: [peer.path, scenario, root.path])
        let stream = session.events, observation = observation
        reader = Task { for await event in stream { await observation.accept(event) } }
    }
    func request() async throws -> ApprovalRequest {
        try await wait { await !observation.requests.isEmpty }
        return try #require(await observation.requests.first)
    }
    func completed(count: Int = 1) async throws { try await wait { await observation.completed >= count } }
    func wait(_ condition: () async throws -> Bool) async throws {
        let deadline = ContinuousClock.now + .seconds(10)
        while try await !condition() {
            if let failure = await observation.failure { throw CoincideError(failure) }
            if ContinuousClock.now >= deadline { throw CoincideError("The Claude question peer did not reach its expected state.") }
            try await Task.sleep(for: .milliseconds(5))
        }
    }
    func responses() throws -> [JSONValue] {
        let log = root.appendingPathComponent("wire.jsonl")
        guard FileManager.default.fileExists(atPath: log.path) else { return [] }
        return try Data(contentsOf: log).split(separator: 10).map { try JSONDecoder().decode(JSONValue.self, from: Data($0)) }
            .filter { $0["type"] == .string("control_response") }.map { $0["response"] }
    }
    func close() async {
        await session.close(); reader.cancel(); await reader.value
        try? FileManager.default.removeItem(at: root)
    }
}
