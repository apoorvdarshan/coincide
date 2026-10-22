import Foundation
import Testing
@testable import CoincideCore

private let cursorSelections = ["multi": ["opaque-A", "opaque-B"], "single": ["日本語"]]
private func cursorQuestion() -> CursorACPQuestionRequest {
    .init(toolCallID: "tool", questions: [
        .init(id: "multi", prompt: "Choose", options: [.init(id: "opaque-B", label: "Same"), .init(id: "opaque-A", label: "Same")], allowMultiple: true),
        .init(id: "single", prompt: "One", options: [.init(id: "日本語", label: "Yes")])])
}

@Test func cursorQuestionsRetainOpaqueSelectionsAndSanitizeUnknownFields() throws {
    var fields = cursorQuestion().parameters.object!; fields["unknownCredential"] = .string("synthetic-private-token")
    let parsed = try CursorACPQuestionRequest(params: .object(fields))
    #expect(parsed == cursorQuestion())
    #expect(parsed.parameters["unknownCredential"] == .null)
    let answers = try #require(parsed.response(for: cursorSelections)["outcome"]["answers"].array)
    #expect(answers[0]["selectedOptionIds"] == .array([.string("opaque-B"), .string("opaque-A")]))
    #expect(answers[1]["selectedOptionIds"] == .array([.string("日本語")]))
}

@Test(arguments: ["missing", "extra", "unknown", "duplicate", "empty", "single-multiple"])
func cursorQuestionRejectsIncompleteAmbiguousAndInventedAnswers(_ mode: String) {
    var selections = cursorSelections
    switch mode {
    case "missing": selections.removeValue(forKey: "single")
    case "extra": selections["invented"] = ["x"]
    case "unknown": selections["multi"] = ["Same"]
    case "duplicate": selections["multi"] = ["opaque-B", "opaque-B"]
    case "empty": selections["multi"] = []
    default: selections["single"] = ["日本語", "日本語"]
    }
    #expect(throws: (any Error).self) { _ = try cursorQuestion().response(for: selections) }
}

@Test func cursorPlansAndNotificationsValidateMergeReplaceAndDiscardUnknownData() throws {
    let plan = CursorACPPlanRequest(toolCallID: "plan", plan: "# Plan\nText", todos: [.init(id: "a", content: "A", status: .pending)],
        phases: [.init(name: "Same", todos: []), .init(name: "Same", todos: [])])
    #expect(try CursorACPPlanRequest(params: plan.parameters) == plan)
    var projector = CursorACPNotifications(); let run = UUID()
    func payload(_ id: String, merge: Bool, status: String = "pending") -> JSONValue {
        .object(["toolCallId": .string("todo-tool"), "merge": .bool(merge), "todos": .array([
            .object(["id": .string(id), "content": .string(id), "status": .string(status)])])])
    }
    let first = try projector.consume(method: "_cursor/update_todos", params: payload("one", merge: false), sessionID: "session", runID: run)
    var entity = try #require(first).apply(to: nil)
    let second = try projector.consume(method: "cursor/update_todos", params: payload("two", merge: true), sessionID: "session", runID: run)
    entity = try #require(second).apply(to: entity)
    #expect(entity.fields["entries"].array?.count == 2)
    let completed = try projector.consume(method: "cursor/update_todos", params: payload("one", merge: true, status: "completed"), sessionID: "session", runID: run)
    entity = try #require(completed).apply(to: entity)
    #expect(entity.fields["entries"].array?.first?["status"] == .string("completed"))
    let replacement = try projector.consume(method: "cursor/update_todos", params: payload("replacement", merge: false), sessionID: "session", runID: run)
    entity = try #require(replacement).apply(to: entity)
    #expect(entity.fields["entries"].array?.count == 1)
    #expect(entity.text == "- [ ] replacement")
    #expect(throws: (any Error).self) { _ = try projector.consume(method: "cursor/update_todos", params: payload("bad", merge: true, status: "invented"), sessionID: "session", runID: run) }
    let image: JSONValue = .object(["toolCallId": .string("image"), "description": .string("Only display"),
        "filePath": .string("/private/nonexistent/image.png"), "referenceImagePaths": .array([.string("/private/unknown")]), "unknownSecret": .string("synthetic-private-token")])
    let imageUpdate = try projector.consume(method: "_cursor/generate_image", params: image, sessionID: "session", runID: run)
    let displayed = try #require(imageUpdate).apply(to: nil)
    #expect(displayed.fields["rawInput"]["filePath"] == image["filePath"])
    #expect(!displayed.fields.pretty.contains("synthetic-private-token"))
}

@Test func integrationProfilesAreExplicitCapturedAndLegacyCompatible() throws {
    for profile in ACPIntegration.allCases {
        var config = profile.configuration(); try config.validate()
        #expect(try JSONDecoder().decode(ACPAgentConfiguration.self, from: JSONEncoder().encode(config)) == config)
        config.executable = "/path with spaces/\(profile.executable)"; try config.validate()
        config.arguments.append("different")
        #expect(throws: (any Error).self) { try config.validate() }
        config.integration = nil; try config.validate()
    }
    let legacy = Data(#"{"id":"934C65F1-4C32-4F7B-949A-851881252ABE","name":"Cursor","executable":"agent","arguments":["acp"]}"#.utf8)
    #expect(try JSONDecoder().decode(ACPAgentConfiguration.self, from: legacy).integration == nil)
    #expect(ACPIntegration.copilot.clientCapabilities["fs"] == .null)
    #expect(ACPIntegration.cursor.clientCapabilities == .object([:]))
}

@Test(.timeLimit(.minutes(1)), arguments: ["answer", "alias", "skip", "accept", "decline", "cancel", "reuse", "remote_cancel", "malformed", "unprofiled"])
func cursorACPActorUsesExactWireResponsesAndFencesReusedAndCancelledIDs(_ mode: String) async throws {
    let fixture = try #require(Bundle.module.url(forResource: "cursor_acp_server", withExtension: "py", subdirectory: "Fixtures"))
    let session = try ACPSession(executable: URL(fileURLWithPath: "/usr/bin/python3"), arguments: [fixture.path, mode],
        cwd: FileManager.default.temporaryDirectory, integration: mode == "unprofiled" ? nil : .cursor)
    do {
        let observer = Task {
            var requests: [ApprovalRequest] = [], dismissed: Set<JSONValue> = []
            for await scoped in session.events {
                let event: ProviderEvent = if case .context(_, let inner) = scoped { inner } else { scoped }
                switch event {
                case .approval(let request):
                    requests.append(request)
                    #expect(request.id != .string("reused-wire"))
                    #expect(!request.params.pretty.contains("synthetic-private-token"))
                    if mode == "remote_cancel", requests.count == 1 { continue }
                    if requests.count == 2 {
                        #expect(requests[0].id != request.id)
                        await #expect(throws: (any Error).self) { try await session.selectAnswers(requests[0], selections: cursorSelections) }
                    }
                    if mode == "cancel" { try await session.interrupt() }
                    else if request.cursorPlan != nil { try await session.respond(request, allow: mode != "decline") }
                    else if mode == "skip" { try await session.respond(request, allow: false) }
                    else {
                        await #expect(throws: (any Error).self) { try await session.selectAnswers(request, selections: ["multi": ["Same"]]) }
                        try await session.selectAnswers(request, selections: cursorSelections)
                    }
                case .approvalDismissed(let id): dismissed.insert(id)
                case .completed(let state):
                    #expect(state == (mode == "cancel" ? .interrupted : .idle))
                    #expect(requests.count == (["malformed", "unprofiled"].contains(mode) ? 0 : ["reuse", "remote_cancel"].contains(mode) ? 2 : 1))
                    #expect(Set(requests.map(\.id)).isSubset(of: dismissed))
                    return
                case .failure(let reason), .connectionClosed(let reason): throw CoincideError(reason)
                default: break
                }
            }
            throw CoincideError("Cursor protocol fixture ended early.")
        }
        let thread = CodingThread(project: WorkspaceProject(path: FileManager.default.temporaryDirectory.path))
        try await session.send(text: "fixture", thread: thread)
        try await observer.value
        await session.close()
    } catch { await session.close(); throw error }
}

@Test(.timeLimit(.minutes(1))) func acpConnectionObservationDoesNotCreateSessionAuthenticateOrPrompt() async throws {
    let fixture = try #require(Bundle.module.url(forResource: "cursor_acp_server", withExtension: "py", subdirectory: "Fixtures"))
    let root = try temporaryWorkspace(); defer { try? FileManager.default.removeItem(at: root) }
    let audit = root.appendingPathComponent("methods")
    let session = try ACPSession(executable: URL(fileURLWithPath: "/usr/bin/python3"), arguments: [fixture.path, "initialize", audit.path], cwd: root, integration: .cursor)
    do {
        let info = try await session.acpConnectionInfo()
        #expect(info.agentName == "fixture-cursor" && info.supportsImages && info.supportsResume)
        #expect(info.authenticationMethods == ["Cursor login"])
        await session.close()
        #expect(try String(contentsOf: audit, encoding: .utf8) == "initialize\n")
    } catch { await session.close(); throw error }
}

@Test(.enabled(if: ProcessInfo.processInfo.environment["COINCIDE_LIVE_CURSOR"] == "1"), .timeLimit(.minutes(2)))
func installedCursorACPModelsAndNativeMarkerTurn() async throws {
    let executable = try #require(ProcessChannel.findExecutable("agent"))
    let root = try temporaryWorkspace(); defer { try? FileManager.default.removeItem(at: root) }
    let session = try ACPSession(executable: executable, arguments: ["acp"], cwd: root, integration: .cursor)
    let deadline = Task { do { try await Task.sleep(for: .seconds(90)); await session.close() } catch { } }
    do {
        let info = try await session.acpConnectionInfo()
        #expect(info.protocolVersion == 1)
        let models = try await session.models(); #expect(!models.isEmpty)
        let configuration = try await session.configuration()
        var thread = CodingThread(project: WorkspaceProject(path: root.path))
        if (configuration["modes"]["availableModes"].array ?? []).contains(where: { $0["id"].string == "ask" }) { thread.agentModeID = "ask" }
        let observer = Task {
            var text = ""
            for await scoped in session.events {
                let event: ProviderEvent = if case .context(_, let inner) = scoped { inner } else { scoped }
                switch event {
                case .delta(_, .assistant, let chunk): text += chunk
                case .approval(let request):
                    try await session.respond(request, allow: false)
                    Issue.record("The installed Cursor marker turn unexpectedly requested a tool or user interaction.")
                case .entity(let update): if update.key.type == "tool_call" { Issue.record("The installed Cursor marker turn unexpectedly used a tool.") }
                case .completed(let state):
                    let matches = text.trimmingCharacters(in: .whitespacesAndNewlines) == "COINCIDE_CURSOR_NATIVE_OK"
                    #expect(state == .idle)
                    #expect(matches, "The installed Cursor did not return the marker. Its existing sign-in or plan may require attention.")
                    return
                case .failure(let reason), .connectionClosed(let reason): throw CoincideError(reason)
                default: break
                }
            }
            throw CoincideError("Installed Cursor ended before the marker turn completed.")
        }
        try await session.send(text: "Respond with exactly COINCIDE_CURSOR_NATIVE_OK. Do not use tools, read files, or change files.", thread: thread)
        try await observer.value
        #expect(try FileManager.default.contentsOfDirectory(atPath: root.path).isEmpty)
        deadline.cancel(); await deadline.value
        await session.close()
    } catch { deadline.cancel(); await deadline.value; await session.close(); throw error }
}

@Test(.enabled(if: ProcessInfo.processInfo.environment["COINCIDE_LIVE_CURSOR_METADATA"] == "1"), .timeLimit(.minutes(2)))
func installedCursorACPConnectionAndModelsWithoutModelTurn() async throws {
    let executable = try #require(ProcessChannel.findExecutable("agent"))
    let root = try temporaryWorkspace(); defer { try? FileManager.default.removeItem(at: root) }
    let session = try ACPSession(executable: executable, arguments: ["acp"], cwd: root, integration: .cursor)
    let deadline = Task { do { try await Task.sleep(for: .seconds(90)); await session.close() } catch { } }
    do {
        let info = try await session.acpConnectionInfo()
        #expect(info.protocolVersion == 1)
        #expect(info.supportsResume)
        #expect(try await !session.models().isEmpty)
        #expect(try FileManager.default.contentsOfDirectory(atPath: root.path).isEmpty)
        deadline.cancel(); await deadline.value; await session.close()
    } catch { deadline.cancel(); await deadline.value; await session.close(); throw error }
}
