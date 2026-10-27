import Foundation
import Testing

@testable import CoincideKit

@MainActor
final class PiSessionTests {
    private let fake = FakePi()
    private let log = PiEventLog()
    private let scratch = piScratchDirectory()

    deinit {
        try? FileManager.default.removeItem(at: scratch)
    }

    private static let timing = PiSession.Timing(
        request: .seconds(2), lifecycle: .seconds(2), quick: .milliseconds(500), abort: .milliseconds(200),
        exitGrace: .milliseconds(200), probeRetry: .milliseconds(10), busyRecheck: .milliseconds(40))

    private func makeSession(
        resume: String? = nil, accessMode: AccessMode = .fullAccess, interactionMode: InteractionMode = .build,
        workingDirectory: URL? = nil
    ) -> PiSession {
        let launch = AgentLaunch(
            provider: .pi, executable: URL(fileURLWithPath: "/usr/local/bin/pi"), environment: ["PATH": "/usr/bin"],
            workingDirectory: workingDirectory ?? scratch, resumeSessionID: resume,
            selection: ModelSelection(provider: .pi, modelID: "default"), accessMode: accessMode,
            interactionMode: interactionMode)
        let fake = fake
        let session = PiSession(
            launch: launch, extensionDirectory: scratch.appendingPathComponent("extension"), timing: Self.timing
        ) { arguments, environment in
            fake.makeTransport(arguments: arguments, environment: environment)
        }
        let log = log
        session.onEvent = { log.record($0) }
        return session
    }

    private func input(
        _ text: String = "Respond with the following text: fixture simple ok", model: String = "default", effort: String? = nil,
        accessMode: AccessMode = .fullAccess, interactionMode: InteractionMode = .build, images: [String] = []
    ) -> AgentTurnInput {
        AgentTurnInput(
            text: text, imagePaths: images, selection: ModelSelection(provider: .pi, modelID: model, effort: effort),
            accessMode: accessMode, interactionMode: interactionMode)
    }

    private func models(_ records: [JSONValue]) -> [String] {
        records.map { "\($0["provider"]?.string ?? "")/\($0["modelId"]?.string ?? "")" }
    }

    private func finished(count: Int = 1) async -> Bool {
        await eventually { log.completions.count >= count }
    }

    // MARK: Starting and resuming

    @Test func startsAFreshSessionWithCoincidesExtension() async throws {
        let session = makeSession()
        try await session.start()
        let transport = fake.current
        let extensionPath = scratch.appendingPathComponent("extension/coincide-pi-extension.ts").path
        #expect(transport.arguments == ["--mode", "rpc", "--extension", extensionPath])
        #expect(FileManager.default.fileExists(atPath: extensionPath))
        #expect(transport.environment["COINCIDE_PI_ACCESS"] == "full")
        #expect(transport.environment["COINCIDE_PI_PLAN"] == "0")
        #expect(transport.environment["PATH"] == "/usr/bin")
        #expect(fake.sent("switch_session").isEmpty)
        #expect(session.sessionID == fake.sessionFile)
        #expect(log.events == [.sessionStarted(id: fake.sessionFile), .modelResolved("openrouter/deepseek/deepseek-v4-flash")])
    }

    @Test func resumesTheSavedSessionFile() async throws {
        let saved = piSessionFile(in: scratch, workingDirectory: scratch)
        let session = makeSession(resume: saved)
        try await session.start()
        #expect(fake.sent("switch_session").map { $0["sessionPath"]?.string } == [saved])
        #expect(session.sessionID == saved)
        // The resumed session already holds the conversation, so the thread needs no recap for it.
        #expect(log.events.first == .sessionContinued(id: saved))
        #expect(log.notices.isEmpty)
    }

    @Test func missingSessionFileStartsFreshWithoutComplaint() async throws {
        let session = makeSession(resume: scratch.appendingPathComponent("never-written.jsonl").path)
        try await session.start()
        #expect(fake.sent("switch_session").isEmpty)
        #expect(log.events.first == .sessionStarted(id: fake.sessionFile))
        #expect(log.notices.isEmpty)
    }

    @Test func refusedResumeStartsANewSessionAndSaysSo() async throws {
        let saved = piSessionFile(in: scratch, workingDirectory: scratch)
        fake.rejections["switch_session"] = "Session file is not a valid pi session"
        let session = makeSession(resume: saved)
        try await session.start()
        #expect(session.sessionID == fake.sessionFile)
        #expect(log.events.first == .sessionStarted(id: fake.sessionFile))
        #expect(log.notices.count == 1)
    }

    @Test func movedThreadForksTheSessionIntoTheNewFolder() async throws {
        let project = scratch.appendingPathComponent("project")
        let worktree = scratch.appendingPathComponent("worktree")
        try FileManager.default.createDirectory(at: project, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: worktree, withIntermediateDirectories: true)
        let saved = piSessionFile(in: scratch, workingDirectory: project)
        let forked = try #require(fake.forkedSessionFile)
        let session = makeSession(resume: saved, workingDirectory: worktree)
        try await session.start()
        #expect(fake.current.arguments.contains("--fork"))
        #expect(fake.current.arguments.contains(saved))
        #expect(fake.sent("switch_session").isEmpty)
        // The fork holds the whole conversation under a new id: no recap, and nothing to tell the user.
        #expect(session.sessionID == forked)
        #expect(log.events.first == .sessionContinued(id: forked))
        #expect(log.notices.isEmpty)
    }

    @Test func failedForkStartsFreshAndSaysSo() async throws {
        let project = scratch.appendingPathComponent("project")
        let worktree = scratch.appendingPathComponent("worktree")
        try FileManager.default.createDirectory(at: project, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: worktree, withIntermediateDirectories: true)
        let saved = piSessionFile(in: scratch, workingDirectory: project)
        fake.forkedSessionFile = nil
        let session = makeSession(resume: saved, workingDirectory: worktree)
        try await session.start()
        #expect(fake.transports.count == 2)
        #expect(!fake.current.arguments.contains("--fork"))
        #expect(log.events.first == .sessionStarted(id: fake.sessionFile))
        #expect(log.notices.count == 1)
    }

    @Test func approvalAndPlanModeNeedCoincidesExtension() async throws {
        fake.extensionLoaded = false
        let approval = makeSession(accessMode: .approval)
        await #expect(throws: AgentError.self) { try await approval.start() }
        #expect(fake.current.terminated)
        let plan = makeSession(interactionMode: .plan)
        await #expect(throws: AgentError.self) { try await plan.start() }

        // Full access in build mode does not depend on it.
        let full = makeSession()
        try await full.start()
        try await full.send(input())
        #expect(fake.sent("prompt").count == 1)
        // Switching to approval mode later refuses to run without it.
        fake.emit([#"{"type":"agent_start"}"#, #"{"type":"agent_settled"}"#])
        #expect(await finished())
        await #expect(throws: AgentError.self) { try await full.send(input(accessMode: .approval)) }
        #expect(fake.sent("prompt").count == 1)
    }

    @Test func startFailsWithPisErrorWhenItExits() async throws {
        fake.held = ["get_state"]
        let session = makeSession()
        Task { fake.current.exit(status: 1, stderr: "Error: No models available\n") }
        do {
            try await session.start()
            Issue.record("Expected start to fail")
        } catch {
            #expect(error.localizedDescription == "Pi exited with code 1.\nError: No models available")
        }
        #expect(!log.events.contains(.sessionExited(error: "Pi exited with code 1.\nError: No models available")))
    }

    // MARK: Turns

    @Test func recordedTurnStreamsAndCompletesOnce() async throws {
        let session = makeSession()
        try await session.start()
        try await session.send(input())
        let prompt = try #require(fake.sent("prompt").first)
        #expect(prompt["message"]?.string == "Respond with the following text: fixture simple ok")
        #expect(prompt["streamingBehavior"]?.string == "steer")
        #expect(prompt["images"] == nil)

        fake.emit(PiFixtures.simpleTurn)
        #expect(await finished())
        #expect(log.events.contains(.assistantText(itemID: "t1.m1.c1", text: "fixture simple ok")))
        #expect(log.events.contains(.reasoningDelta(itemID: "t1.m1.c0", delta: "The")))
        #expect(log.completions == [.completed])
        // The turn ends as soon as Pi is idle; the session's usage follows.
        let usage = AgentEvent.usage(TokenUsage(inputTokens: 1814, contextWindow: 1_048_576, costUSD: 0.00007710612))
        #expect(await eventually { log.events.last == usage })
        #expect(log.events.dropLast().last == .turnCompleted(.completed))
        // Pi's default before any session, the session's state, then the idle check.
        #expect(fake.sent("get_state").count == 3)
        #expect(fake.sent("get_session_stats").count == 1)

        // A second turn reuses the same process and session.
        try await session.send(input("And again"))
        fake.emit([#"{"type":"agent_start"}"#, #"{"type":"agent_settled"}"#])
        #expect(await finished(count: 2))
        #expect(fake.transports.count == 1)
        #expect(log.completions == [.completed, .completed])
    }

    @Test func modelAndThinkingLevelAreAppliedOnlyWhenTheyChange() async throws {
        fake.model = PiFixtures.sonnet
        fake.thinkingLevel = "medium"
        let session = makeSession()
        try await session.start()

        try await session.send(input(model: "openrouter/deepseek/deepseek-v4-flash", effort: "high"))
        #expect(models(fake.sent("set_model")) == ["openrouter/deepseek/deepseek-v4-flash"])
        #expect(fake.sent("set_thinking_level").map { $0["level"]?.string } == ["high"])
        #expect(log.events.contains(.modelResolved("openrouter/deepseek/deepseek-v4-flash")))
        fake.emit([#"{"type":"agent_start"}"#, #"{"type":"agent_settled"}"#])
        #expect(await finished())

        try await session.send(input(model: "openrouter/deepseek/deepseek-v4-flash", effort: "high"))
        #expect(fake.sent("set_model").count == 1)
        #expect(fake.sent("set_thinking_level").count == 1)
        fake.emit([#"{"type":"agent_start"}"#, #"{"type":"agent_settled"}"#])
        #expect(await finished(count: 2))

        // "Default" goes back to the model and level Pi started with.
        try await session.send(input(model: "default"))
        #expect(models(fake.sent("set_model")).last == "anthropic/claude-sonnet-4-5")
        #expect(fake.sent("set_thinking_level").last?["level"]?.string == "medium")
    }

    @Test func defaultMeansPisDefaultEvenAfterARestart() async throws {
        fake.model = PiFixtures.sonnet
        fake.sessionFile = piSessionFile(in: scratch, workingDirectory: scratch)
        let session = makeSession()
        try await session.start()
        try await session.send(input(model: "openrouter/deepseek/deepseek-v4-flash"))
        fake.emit([#"{"type":"agent_start"}"#, #"{"type":"agent_settled"}"#])
        #expect(await finished())

        // The restarted process resumes the session, which comes back on the model it last used.
        try await session.send(input(model: "default", accessMode: .approval))
        #expect(fake.transports.count == 2)
        #expect(models(fake.sent("set_model")) == ["openrouter/deepseek/deepseek-v4-flash", "anthropic/claude-sonnet-4-5"])
    }

    @Test func resumedSessionsKeepPisDefaultForDefault() async throws {
        fake.model = PiFixtures.sonnet
        fake.resumedModel = PiFixtures.deepseek
        let saved = piSessionFile(in: scratch, workingDirectory: scratch)
        let session = makeSession(resume: saved)
        try await session.start()
        #expect(log.events.contains(.modelResolved("openrouter/deepseek/deepseek-v4-flash")))
        try await session.send(input(model: "default"))
        #expect(models(fake.sent("set_model")) == ["anthropic/claude-sonnet-4-5"])
        fake.emit([#"{"type":"agent_start"}"#, #"{"type":"agent_settled"}"#])
        #expect(await finished())

        // Pi reports a level it changed by itself, so asking for that level sends nothing; another one is applied.
        fake.emit([#"{"type":"thinking_level_changed","level":"low"}"#])
        try await session.send(input(model: "default", effort: "low"))
        fake.emit([#"{"type":"agent_start"}"#, #"{"type":"agent_settled"}"#])
        #expect(await finished(count: 2))
        try await session.send(input(model: "default", effort: "high"))
        #expect(fake.sent("set_thinking_level").compactMap { $0["level"]?.string } == ["high", "high"])
        #expect(fake.transports.count == 1)
    }

    @Test func unusableModelsFailTheTurnBeforeAnythingIsSent() async throws {
        let session = makeSession()
        try await session.start()
        await #expect(throws: AgentError.self) { try await session.send(input(model: "claude-sonnet")) }
        await #expect(throws: AgentError.self) { try await session.send(input(model: "anthropic/claude-opus-9")) }
        #expect(fake.sent("prompt").isEmpty)
        // The session is still usable afterwards.
        try await session.send(input())
        #expect(fake.sent("prompt").count == 1)
    }

    @Test func rejectedPromptFailsTheTurn() async throws {
        fake.rejections["prompt"] = "No API key found for anthropic."
        let session = makeSession()
        try await session.start()
        try await session.send(input())
        #expect(await finished())
        #expect(log.completions == [.failed("No API key found for anthropic.")])
    }

    @Test func modelErrorFailsTheTurn() async throws {
        let session = makeSession()
        try await session.start()
        try await session.send(input())
        fake.emit([
            #"{"type":"agent_start"}"#,
            #"{"type":"message_start","message":{"role":"assistant","content":[]}}"#,
            #"{"type":"message_end","message":{"role":"assistant","content":[],"stopReason":"error","errorMessage":"400 prompt is too long"}}"#,
            #"{"type":"agent_settled"}"#,
        ])
        #expect(await finished())
        #expect(log.completions == [.failed("400 prompt is too long")])
    }

    @Test func handledCommandEndsWithoutARun() async throws {
        fake.promptDisposition = "handled"
        let session = makeSession()
        try await session.start()
        try await session.send(input("/my-extension-command"))
        #expect(await finished())
        #expect(log.completions == [.completed])
    }

    @Test func turnWaitsWhilePiIsStillBusyAfterSettling() async throws {
        let session = makeSession()
        try await session.start()
        try await session.send(input())
        fake.busy = true
        let handshake = fake.sent("get_state").count
        fake.emit([#"{"type":"agent_start"}"#, #"{"type":"agent_settled"}"#])
        #expect(fake.sent("get_state").count == handshake + 1)
        try await Task.sleep(for: .milliseconds(50))
        #expect(log.completions.isEmpty)
        fake.busy = false
        fake.emit([#"{"type":"agent_start"}"#, #"{"type":"agent_settled"}"#])
        #expect(await finished())
        #expect(log.completions == [.completed])
    }

    @Test func compactCommandUsesPisCompaction() async throws {
        fake.stats = PiFixtures.statsAfterCompaction
        let session = makeSession()
        try await session.start()
        try await session.send(input("/compact keep the opaque marker compaction-marker-4Z7Q"))
        let compact = try #require(fake.sent("compact").first)
        #expect(compact["customInstructions"]?.string == "keep the opaque marker compaction-marker-4Z7Q")
        #expect(fake.sent("prompt").isEmpty)
        fake.emit(PiFixtures.compaction)
        #expect(await finished())
        #expect(log.completions == [.completed])
        // Pi has no token count right after compacting, so its estimate stands in.
        let usage = AgentEvent.usage(TokenUsage(inputTokens: 1890, contextWindow: 1_048_576, costUSD: 0.000207767924))
        #expect(await eventually { log.events.contains(usage) })
    }

    @Test func stillBusyAfterSettlingIsCheckedAgain() async throws {
        let session = makeSession()
        try await session.start()
        try await session.send(input())
        fake.busy = true
        fake.emit([#"{"type":"agent_start"}"#, #"{"type":"agent_settled"}"#])
        try await Task.sleep(for: .milliseconds(100))
        #expect(log.completions.isEmpty)
        // Pi went idle without another event.
        fake.busy = false
        #expect(await finished())
        #expect(log.completions == [.completed])
    }

    @Test func unresponsivePiFailsTheTurnAndRestarts() async throws {
        let session = makeSession()
        try await session.start()
        try await session.send(input())
        fake.held = ["get_state"]
        fake.emit([#"{"type":"agent_start"}"#, #"{"type":"agent_settled"}"#])
        #expect(await finished())
        #expect(log.completions == [.failed("Pi stopped responding.")])
        #expect(fake.transports[0].terminated)
        fake.held = []
        try await session.send(input())
        #expect(fake.transports.count == 2)
    }

    @Test func imagesTravelWithThePrompt() async throws {
        let image = scratch.appendingPathComponent("screen.png")
        try Data([1, 2, 3]).write(to: image)
        let session = makeSession()
        try await session.start()
        try await session.send(input("What is this?", images: [image.path]))
        let prompt = try #require(fake.sent("prompt").first)
        #expect(prompt["images"] == [["type": "image", "data": "AQID", "mimeType": "image/png"]])
    }

    @Test func notificationsDuringATurnAreShown() async throws {
        let session = makeSession()
        try await session.start()
        fake.emit([#"{"type":"extension_ui_request","id":"n0","method":"notify","message":"Loaded before the turn"}"#])
        try await session.send(input())
        fake.emit([#"{"type":"extension_ui_request","id":"n1","method":"notify","message":"Indexed 12 files","notifyType":"info"}"#])
        #expect(log.notices == ["Indexed 12 files"])
    }

    // MARK: Approvals and plan mode

    private func requestApproval(callID: String = "call_1", uiID: String = "ui-1", command: String = "echo coincide-ok") {
        fake.emit([
            #"{"type":"tool_execution_start","toolCallId":"\#(callID)","toolName":"bash","args":{"command":"\#(command)"}}"#,
            #"{"type":"extension_ui_request","id":"\#(uiID)","method":"confirm","title":"Allow bash?","message":"{\"coincide\":\"coincide.toolApproval\",\"toolCallId\":\"\#(callID)\",\"toolName\":\"bash\"}"}"#,
        ])
    }

    @Test func approvalRoundTrip() async throws {
        let session = makeSession(accessMode: .approval)
        try await session.start()
        #expect(fake.current.environment["COINCIDE_PI_ACCESS"] == "approval")
        try await session.send(input("Run: echo coincide-ok", accessMode: .approval))
        #expect(fake.transports.count == 1)
        requestApproval()
        let request = try #require(log.approvals.first)
        #expect(request.id == "ui-1")
        #expect(request.title == "Run `echo coincide-ok`")
        #expect(request.detail == "echo coincide-ok")
        #expect(request.category == .command)
        #expect(request.toolCallID == "call_1")
        #expect(request.options == ApprovalRequest.standardOptions)

        session.respond(to: "ui-1", optionID: "allow")
        #expect(fake.sent("extension_ui_response") == [["type": "extension_ui_response", "id": "ui-1", "confirmed": true]])
        fake.emit([
            #"{"type":"tool_execution_end","toolCallId":"call_1","toolName":"bash","result":{"content":[{"type":"text","text":"coincide-ok\n"}],"structuredContent":{"output":"coincide-ok\n","truncated":false,"exit_code":0,"wall_time_seconds":0}},"isError":false}"#
        ])
        #expect(log.events.contains(.toolCompleted(id: "call_1", status: .completed, output: "coincide-ok\n")))
        // Answering twice does nothing.
        session.respond(to: "ui-1", optionID: "deny")
        #expect(fake.sent("extension_ui_response").count == 1)
    }

    @Test func alwaysAllowAnswersTheSameCommandAutomatically() async throws {
        let session = makeSession(accessMode: .approval)
        try await session.start()
        try await session.send(input(accessMode: .approval))
        requestApproval()
        session.respond(to: "ui-1", optionID: "allow_always")
        requestApproval(callID: "call_2", uiID: "ui-2")
        #expect(log.approvals.count == 1)
        #expect(fake.sent("extension_ui_response").last == ["type": "extension_ui_response", "id": "ui-2", "confirmed": true])
        requestApproval(callID: "call_3", uiID: "ui-3", command: "rm -rf build")
        #expect(log.approvals.count == 2)
    }

    @Test func alwaysAllowOutlivesTheProcess() async throws {
        fake.sessionFile = piSessionFile(in: scratch, workingDirectory: scratch)
        let first = makeSession(accessMode: .approval)
        try await first.start()
        try await first.send(input(accessMode: .approval))
        requestApproval()
        first.respond(to: "ui-1", optionID: "allow_always")
        // The idle timer ends the session; the next turn gets a new one that resumes the same Pi session.
        first.shutdown()
        let second = makeSession(resume: fake.sessionFile, accessMode: .approval)
        try await second.start()
        try await second.send(input(accessMode: .approval))
        requestApproval(callID: "call_2", uiID: "ui-2")
        #expect(log.approvals.count == 1)
        #expect(fake.sent("extension_ui_response").last == ["type": "extension_ui_response", "id": "ui-2", "confirmed": true])
    }

    @Test func deniedToolReadsAsDeclined() async throws {
        let session = makeSession(accessMode: .approval)
        try await session.start()
        try await session.send(input(accessMode: .approval))
        requestApproval()
        session.respond(to: "ui-1", optionID: "deny")
        #expect(fake.sent("extension_ui_response").last == ["type": "extension_ui_response", "id": "ui-1", "confirmed": false])
        fake.emit([
            #"{"type":"tool_execution_end","toolCallId":"call_1","toolName":"bash","result":{"content":[{"type":"text","text":"The user declined this bash call."}]},"isError":true}"#
        ])
        #expect(log.events.contains(.toolCompleted(id: "call_1", status: .declined, output: "The user declined this bash call.")))
    }

    @Test func dialogsPiAnswersItselfAreWithdrawn() async throws {
        let session = makeSession()
        try await session.start()
        try await session.send(input())
        fake.emit([#"{"type":"extension_ui_request","id":"ui-timed","method":"select","title":"Pick one","options":["a","b"],"timeout":40}"#])
        #expect(log.questions.map(\.id) == ["ui-timed"])
        #expect(await eventually { log.events.contains(.userInputResolved(id: "ui-timed")) })
        session.answer(userInput: "ui-timed", answers: ["ui-timed": ["a"]])
        fake.emit([#"{"type":"extension_ui_request","id":"ui-confirm","method":"confirm","title":"Continue?","timeout":40}"#])
        #expect(await eventually { log.events.contains(.approvalResolved(id: "ui-confirm")) })
        session.respond(to: "ui-confirm", optionID: "allow")
        #expect(fake.sent("extension_ui_response").isEmpty)
    }

    @Test func selectDialogsBecomeQuestions() async throws {
        let session = makeSession()
        try await session.start()
        try await session.send(input("/release"))
        fake.emit([#"{"type":"extension_ui_request","id":"ui-tag","method":"select","title":"Pick a tag","options":["stable","","beta"]}"#])
        let question = try #require(log.questions.first?.questions.first)
        #expect(question.prompt == "Pick a tag")
        #expect(question.options.map(\.label) == ["stable", PiDialog.emptyChoiceLabel, "beta"])
        #expect(!question.allowsFreeText)
        #expect(!question.allowsMultipleSelection)
        // An approval answer does not apply to a question.
        session.respond(to: "ui-tag", optionID: "allow")
        #expect(fake.sent("extension_ui_response").isEmpty)
        session.answer(userInput: "ui-tag", answers: [question.id: [PiDialog.emptyChoiceLabel]])
        #expect(fake.sent("extension_ui_response") == [["type": "extension_ui_response", "id": "ui-tag", "value": ""]])

        fake.emit([#"{"type":"extension_ui_request","id":"ui-again","method":"select","title":"Pick again","options":["a"]}"#])
        session.answer(userInput: "ui-again", answers: [:])
        #expect(fake.sent("extension_ui_response").last == ["type": "extension_ui_response", "id": "ui-again", "cancelled": true])
    }

    @Test func inputAndEditorDialogsTakeTypedText() async throws {
        let session = makeSession()
        try await session.start()
        try await session.send(input("/setup"))
        fake.emit([#"{"type":"extension_ui_request","id":"ui-db","method":"input","title":"Which database?","placeholder":"postgres"}"#])
        let ask = try #require(log.approvals.last)
        #expect(ask.title == "Which database?")
        #expect(ask.textInput == TextInputSpec(placeholder: "postgres"))
        #expect(ask.options.map(\.kind) == [.allowOnce, .cancel])
        session.respond(to: "ui-db", optionID: try #require(ask.options.first?.id), text: "SQLite")
        #expect(fake.sent("extension_ui_response").last == ["type": "extension_ui_response", "id": "ui-db", "value": "SQLite"])

        let prefill = "fix(server): keep the editor text\n\ndetails\n"
        fake.current.emit(
            ["type": "extension_ui_request", "id": "ui-msg", "method": "editor", "title": "Commit message", "prefill": .string(prefill)])
        let edit = try #require(log.approvals.last)
        #expect(edit.textInput == TextInputSpec(initialText: prefill, isMultiline: true))
        // Without text (an app that shows no field) the prefilled text goes back unchanged.
        session.respond(to: "ui-msg", optionID: try #require(edit.options.first?.id))
        #expect(fake.sent("extension_ui_response").last == ["type": "extension_ui_response", "id": "ui-msg", "value": .string(prefill)])

        fake.emit([#"{"type":"extension_ui_request","id":"ui-no","method":"input","title":"Name?"}"#])
        session.respond(to: "ui-no", optionID: "cancel", text: "ignored")
        #expect(fake.sent("extension_ui_response").last == ["type": "extension_ui_response", "id": "ui-no", "cancelled": true])
    }

    @Test func startupDialogsCanBeAnsweredAndAreWithdrawnWhenPiExits() async throws {
        let session = makeSession()
        fake.held = ["get_commands"]
        let starting = Task { try await session.start() }
        #expect(await eventually { !fake.transports.isEmpty && !fake.current.records("get_commands").isEmpty })
        fake.emit([#"{"type":"extension_ui_request","id":"ui-trust","method":"confirm","title":"Run project extensions?","message":"This project has .pi/extensions."}"#])
        let trust = try #require(log.approvals.first)
        #expect(trust.title == "Run project extensions?")
        #expect(trust.detail == "This project has .pi/extensions.")
        session.respond(to: "ui-trust", optionID: "allow")
        #expect(fake.sent("extension_ui_response") == [["type": "extension_ui_response", "id": "ui-trust", "confirmed": true]])
        fake.answer("get_commands", data: ["commands": [["name": .string(PiExtension.handoffCommand)]]])
        try await starting.value

        fake.emit([#"{"type":"extension_ui_request","id":"ui-later","method":"confirm","title":"Reload?"}"#])
        fake.current.exit(status: 0)
        #expect(log.events.contains(.approvalResolved(id: "ui-later")))
        #expect(log.events.last == .sessionExited(error: "Pi exited."))
    }

    @Test func pendingApprovalsAreCancelledWhenTheTurnEnds() async throws {
        let session = makeSession(accessMode: .approval)
        try await session.start()
        try await session.send(input(accessMode: .approval))
        requestApproval()
        fake.emit([#"{"type":"agent_settled","aborted":true}"#])
        #expect(await finished())
        #expect(log.completions == [.interrupted])
        #expect(fake.sent("extension_ui_response") == [["type": "extension_ui_response", "id": "ui-1", "cancelled": true]])
        #expect(log.events.contains(.toolCompleted(id: "call_1", status: .failed, output: nil)))
    }

    @Test func changingAccessModeRestartsPiOnTheSameSession() async throws {
        fake.sessionFile = piSessionFile(in: scratch, workingDirectory: scratch)
        let session = makeSession()
        try await session.start()
        try await session.send(input())
        fake.emit([#"{"type":"agent_start"}"#, #"{"type":"agent_settled"}"#])
        #expect(await finished())

        let first = fake.current
        try await session.send(input(accessMode: .approval))
        #expect(first.inputClosed)
        #expect(fake.transports.count == 2)
        #expect(fake.current.environment["COINCIDE_PI_ACCESS"] == "approval")
        #expect(fake.current.records("switch_session").map { $0["sessionPath"]?.string } == [fake.sessionFile])
        #expect(fake.current.records("prompt").count == 1)
        #expect(log.events.filter { $0 == .sessionStarted(id: fake.sessionFile) }.count == 1)
        #expect(log.events.filter { $0 == .sessionContinued(id: fake.sessionFile) }.count == 1)
        #expect(!log.events.contains { if case .sessionExited = $0 { true } else { false } })
    }

    @Test func stopWhileStartingPiEndsTheTurnWithoutSendingThePrompt() async throws {
        fake.sessionFile = piSessionFile(in: scratch, workingDirectory: scratch)
        let session = makeSession()
        try await session.start()
        fake.held = ["switch_session"]
        // A new access mode restarts Pi, which takes a while to load the session.
        let sending = Task { try await session.send(input(accessMode: .approval)) }
        #expect(await eventually { fake.transports.count == 2 && !fake.current.records("switch_session").isEmpty })
        session.interrupt()
        #expect(await finished())
        #expect(log.completions == [.interrupted])
        fake.answer("switch_session", data: ["cancelled": false])
        try await sending.value
        #expect(fake.sent("prompt").isEmpty)

        // The restarted process takes the next turn.
        fake.held = []
        try await session.send(input(accessMode: .approval))
        #expect(fake.transports.count == 2)
        #expect(fake.sent("prompt").count == 1)
    }

    @Test func slashCommandAfterAHandoffGetsItsRecapSeparately() async throws {
        let session = makeSession()
        try await session.start()
        let handoff = Self.handoffText(for: "/compact keep the API notes")
        try await session.send(input(handoff))
        let recap = try #require(fake.sent("prompt").first?["message"]?.string)
        #expect(recap.hasPrefix("/\(PiExtension.handoffCommand) <conversation_handoff>"))
        #expect(recap.contains("Claude Code:\nThe parser is done."))
        #expect(!recap.contains("/compact"))
        #expect(fake.sent("compact").first?["customInstructions"]?.string == "keep the API notes")
        fake.emit(PiFixtures.compaction)
        #expect(await finished())

        // An ordinary message keeps its recap in the prompt.
        let plain = Self.handoffText(for: "Now add tests")
        try await session.send(input(plain))
        #expect(fake.sent("prompt").last?["message"]?.string == plain)
        #expect(fake.sent("prompt").count == 2)
    }

    /// What the thread runner sends Pi after another agent worked on the thread.
    private static func handoffText(for message: String) -> String {
        let thread = ChatThread(
            projectID: UUID(), selection: ModelSelection(provider: .pi, modelID: "default"),
            items: [
                TranscriptItem(kind: .user, text: "Write the parser"),
                TranscriptItem(kind: .assistant, text: "The parser is done.", provider: .claude),
            ],
            sessions: [.pi: ProviderSessionRef(sessionID: "/s.jsonl", seenItemCount: 0)])
        return Handoff.prompt(for: message, thread: thread, provider: .pi)
    }

    @Test func planModeKeepsPiReadOnlyAndReturnsThePlan() async throws {
        let session = makeSession(interactionMode: .plan)
        try await session.start()
        #expect(fake.current.environment["COINCIDE_PI_PLAN"] == "1")
        try await session.send(input("Plan the parser", interactionMode: .plan))
        fake.emit([
            #"{"type":"agent_start"}"#,
            #"{"type":"tool_execution_start","toolCallId":"w1","toolName":"write","args":{"path":"parser.swift","content":"x"}}"#,
            #"{"type":"tool_execution_end","toolCallId":"w1","toolName":"write","result":{"content":[{"type":"text","text":"Plan mode is on, so write is not available. Use read-only tools, then call propose_plan with your plan."}]},"isError":true}"#,
            #"{"type":"tool_execution_start","toolCallId":"p1","toolName":"propose_plan","args":{"plan":"1. Add Parser.swift\n2. Test it"}}"#,
            #"{"type":"tool_execution_end","toolCallId":"p1","toolName":"propose_plan","result":{"content":[{"type":"text","text":"The plan is in front of the user. Stop here and wait for their reply."}]},"isError":false}"#,
            #"{"type":"agent_settled"}"#,
        ])
        #expect(await finished())
        #expect(log.events.contains(.plan(text: "1. Add Parser.swift\n2. Test it")))
        #expect(log.events.contains { if case .toolCompleted("w1", .declined, _) = $0 { true } else { false } })
        #expect(!log.events.contains { if case .toolStarted(let info) = $0 { info.id == "p1" } else { false } })

        // Leaving plan mode restarts Pi without the plan policy.
        try await session.send(input("Go ahead", interactionMode: .build))
        #expect(fake.current.environment["COINCIDE_PI_PLAN"] == "0")
    }

    // MARK: Interrupts and failures

    @Test func interruptAbortsAndCompletesOnce() async throws {
        fake.held = ["abort"]
        let session = makeSession()
        try await session.start()
        try await session.send(input("Run the slow command"))
        fake.emit(PiFixtures.toolTurnBeforeAbort)
        session.interrupt()
        session.interrupt()
        #expect(fake.sent("abort").count == 1)
        fake.emit(PiFixtures.toolTurnAfterAbort)
        #expect(await finished())
        fake.answer("abort")
        try await Task.sleep(for: .milliseconds(30))
        #expect(log.completions == [.interrupted])
        #expect(log.events.contains(.toolCompleted(id: PiFixtures.interruptedCallID, status: .failed, output: "Command aborted")))
    }

    @Test func interruptThatPiIgnoresStopsTheProcess() async throws {
        fake.held = ["abort"]
        fake.sessionFile = piSessionFile(in: scratch, workingDirectory: scratch)
        let session = makeSession()
        try await session.start()
        try await session.send(input())
        fake.emit([#"{"type":"agent_start"}"#])
        session.interrupt()
        #expect(await finished())
        #expect(log.completions == [.interrupted])
        #expect(fake.transports[0].terminated)
        #expect(!log.events.contains { if case .sessionExited = $0 { true } else { false } })

        // The next turn starts Pi again on the same session.
        fake.held = []
        try await session.send(input())
        #expect(fake.transports.count == 2)
        #expect(fake.current.records("switch_session").map { $0["sessionPath"]?.string } == [fake.sessionFile])
    }

    @Test func crashFailsTheTurnThenReportsTheExit() async throws {
        let session = makeSession()
        try await session.start()
        try await session.send(input())
        fake.emit([#"{"type":"agent_start"}"#])
        fake.current.exit(status: 1, stderr: "FATAL ERROR: JavaScript heap out of memory\n")
        let reason = "Pi exited with code 1.\nFATAL ERROR: JavaScript heap out of memory"
        #expect(await eventually { log.events.last == .sessionExited(error: reason) })
        #expect(log.completions == [.failed(reason)])
        let tail = Array(log.events.suffix(2))
        #expect(tail == [.turnCompleted(.failed(reason)), .sessionExited(error: reason)])
    }

    @Test func exitWhilePreparingATurnFailsTheSend() async throws {
        let session = makeSession()
        try await session.start()
        fake.held = ["set_model"]
        let sending = Task { try await session.send(input(model: "anthropic/claude-sonnet-4-5")) }
        #expect(await eventually { !fake.sent("set_model").isEmpty })
        fake.current.exit(status: 1, stderr: "Error: out of memory\n")
        do {
            try await sending.value
            Issue.record("Expected the send to fail")
        } catch {
            #expect(error.localizedDescription == "Pi exited with code 1.\nError: out of memory")
        }
        // `send` reported it; there is no turn to complete and the process is not reported separately.
        #expect(log.completions.isEmpty)
        #expect(!log.events.contains { if case .sessionExited = $0 { true } else { false } })
        fake.held = []
        try await session.send(input())
        #expect(fake.transports.count == 2)
        #expect(fake.sent("prompt").count == 1)
    }

    @Test func workAnExtensionStartsBetweenTurnsIsShownWithoutATurn() async throws {
        let session = makeSession()
        try await session.start()
        fake.emit([
            #"{"type":"agent_start"}"#,
            #"{"type":"message_start","message":{"role":"assistant","content":[]}}"#,
            #"{"type":"message_update","assistantMessageEvent":{"type":"text_delta","contentIndex":0,"delta":"Build finished"}}"#,
            #"{"type":"message_end","message":{"role":"assistant","content":[{"type":"text","text":"Build finished"}]}}"#,
            #"{"type":"agent_settled"}"#,
        ])
        #expect(log.events.contains(.assistantText(itemID: "w1.m1.c0", text: "Build finished")))
        #expect(log.completions.isEmpty)
        // The next turn is unaffected.
        try await session.send(input())
        fake.emit([#"{"type":"agent_start"}"#, #"{"type":"agent_settled"}"#])
        #expect(await finished())
        #expect(log.completions == [.completed])
    }

    @Test func exitBetweenTurnsIsReported() async throws {
        let session = makeSession()
        try await session.start()
        fake.current.exit(status: 0)
        #expect(log.events.last == .sessionExited(error: "Pi exited."))
    }

    @Test func abandonedTurnRestartsPiBeforeTheNextOne() async throws {
        let session = makeSession()
        try await session.start()
        try await session.send(input())
        fake.emit([#"{"type":"agent_start"}"#])
        // The thread runner gave up on that turn and sends a new one.
        try await session.send(input("Next"))
        #expect(fake.transports.count == 2)
        #expect(fake.transports[0].inputClosed)
        #expect(log.completions.isEmpty)
    }

    @Test func shutdownClosesPiAndGoesQuiet() async throws {
        let session = makeSession()
        try await session.start()
        let transport = fake.current
        let count = log.events.count
        session.shutdown()
        #expect(transport.inputClosed)
        transport.emit(#"{"type":"extension_ui_request","id":"late","method":"confirm","title":"Late?"}"#)
        #expect(log.events.count == count)
        await #expect(throws: AgentError.self) { try await session.send(input()) }
    }
}

@MainActor
struct PiProviderTests {
    private let fake = FakePi()

    private func provider(version: String = "1.4.0", status: Int32 = 0, timeout: Duration = .milliseconds(300)) -> PiProvider {
        let fake = fake
        return PiProvider(
            probeVersion: { _, _ in ProcessRunner.Result(status: status, stdout: version + "\n", stderr: "") },
            discoveryTransport: { _, environment in
                fake.makeTransport(arguments: ["--mode", "rpc", "--no-session"], environment: environment)
            },
            discoveryTimeout: timeout)
    }

    private let executable = URL(fileURLWithPath: "/opt/homebrew/bin/pi")

    @Test func missingExecutableIsNotInstalled() async {
        let status = await provider().detect(executable: nil, environment: [:])
        #expect(status.state == .notInstalled)
        #expect(status.message?.contains("@earendil-works/pi-coding-agent") == true)
    }

    @Test func oldOrBrokenPiIsAnError() async {
        let old = await provider(version: "0.80.3").detect(executable: executable, environment: [:])
        #expect(old.state == .error)
        #expect(old.version == "0.80.3")
        #expect(old.message?.contains("0.80.5") == true)
        let broken = await provider(status: 1).detect(executable: executable, environment: [:])
        #expect(broken.state == .error)
        let silent = await provider(version: "").detect(executable: executable, environment: [:])
        #expect(silent.state == .error)
        #expect(fake.transports.isEmpty)
    }

    @Test func discoveredModelsMeanSignedIn() async {
        let pi = provider()
        let status = await pi.detect(executable: executable, environment: [:])
        #expect(status.state == .ready)
        #expect(status.version == "1.4.0")
        #expect(status.account == "openrouter, anthropic")
        let models = await pi.models(status: status, environment: [:])
        #expect(models.map(\.modelID) == ["default", "openrouter/deepseek/deepseek-v4-flash", "anthropic/claude-sonnet-4-5"])
        // `models` reuses what `detect` just discovered.
        #expect(fake.transports.count == 1)
        #expect(fake.transports[0].arguments == ["--mode", "rpc", "--no-session"])
        #expect(fake.transports[0].inputClosed)
    }

    @Test func noModelsMeansSignedOut() async {
        fake.models = []
        let pi = provider()
        let status = await pi.detect(executable: executable, environment: [:])
        #expect(status.state == .notAuthenticated)
        #expect(await pi.models(status: status, environment: [:]).map(\.modelID) == ["default"])
    }

    @Test func unreadableInventoryKeepsPiUsable() async {
        fake.models = [["provider": "anthropic"]]
        let pi = provider()
        let malformed = await pi.detect(executable: executable, environment: [:])
        #expect(malformed.state == .ready)
        #expect(malformed.message != nil)
        #expect(await pi.models(status: malformed, environment: [:]) == PiModels.fallback)

        fake.held = ["get_state"]
        let silent = await provider().detect(executable: executable, environment: [:])
        #expect(silent.state == .ready)
        #expect(silent.message != nil)
    }

    @Test func discoveryDismissesDialogsNobodyCanAnswer() async {
        fake.held = ["get_state"]
        let pi = provider(timeout: .seconds(5))
        let detecting = Task { await pi.detect(executable: executable, environment: [:]) }
        #expect(await eventually { !fake.transports.isEmpty && !fake.current.records("get_state").isEmpty })
        fake.emit([#"{"type":"extension_ui_request","id":"ui-start","method":"confirm","title":"Trust this folder?"}"#])
        #expect(fake.sent("extension_ui_response") == [["type": "extension_ui_response", "id": "ui-start", "cancelled": true]])
        fake.held = []
        fake.answer("get_state", data: PiFixtures.state(sessionFile: "/s.jsonl"))
        let status = await detecting.value
        #expect(status.state == .ready)
        #expect(status.message == nil)
    }

    @Test func sessionsArePiSessions() {
        let launch = AgentLaunch(
            provider: .pi, executable: executable, environment: [:], workingDirectory: URL(fileURLWithPath: "/tmp"),
            resumeSessionID: nil, selection: ModelSelection(provider: .pi, modelID: "default"), accessMode: .fullAccess,
            interactionMode: .build)
        let session = provider().makeSession(launch)
        #expect(session is PiSession)
        #expect(session.provider == .pi)
    }
}
