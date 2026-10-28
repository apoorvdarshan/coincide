import Foundation
import Testing

@testable import CoincideKit

/// fx (`fx acp`), ported from T3 Code's provider-fx tests (`status.test.ts`, `acpSupport.test.ts`, `skills.test.ts`)
/// and checked against the shapes in its recorded fx 0.0.13 sessions.
@MainActor
struct FxTests {
    // MARK: Fixtures

    /// `fx status --json` from fx 0.0.13, trimmed to the fields Coincide reads plus a few it ignores.
    static let signedIn =
        #"{"kind":"status","model":"anthropic/claude-opus-5.5","auth":"fx login","auth_refreshable":true,"permission_mode":"ask"}"#
    static let signedOut =
        #"{"kind":"status","model":"spacexai/grok-4.7","auth":"missing","auth_refreshable":false,"auth_help":"fx needs access to Vercel AI Gateway. Run fx login to sign in, fx setup to use an API key, or set AI_GATEWAY_API_KEY."}"#
    /// `fx models --json` from fx 0.0.13, ids trimmed.
    static let models =
        #"{"kind":"models","count":2,"shown_count":2,"more_count":0,"private_models_hidden":false,"ids":["anthropic/claude-sonnet-5.5","anthropic/claude-opus-5.5"]}"#

    /// `session/new` as fx 0.0.13 answers it, with fewer models. Its backend (`provider`) shares the `model` category
    /// with the model, and it reports `ask` whatever mode it runs.
    static let session = """
        {"sessionId":"sess-1","configOptions":[
        {"id":"provider","name":"Provider","category":"model","type":"select","currentValue":"gateway","options":[{"value":"gateway","name":"Vercel AI Gateway"},{"value":"codex","name":"Codex subscription"}]},
        {"id":"model","name":"Model","category":"model","type":"select","currentValue":"anthropic/claude-opus-5.5","options":[{"value":"anthropic/claude-sonnet-5.5","name":"anthropic/claude-sonnet-5.5"},{"value":"anthropic/claude-opus-5.5","name":"anthropic/claude-opus-5.5"}]},
        {"id":"mode","name":"Mode","category":"mode","type":"select","currentValue":"ask","options":[{"value":"code","name":"Code"},{"value":"ask","name":"Ask"}]},
        {"id":"effort","name":"Effort","category":"thought_level","type":"select","currentValue":"xhigh","options":[{"value":"auto","name":"Auto"},{"value":"low","name":"Low"},{"value":"medium","name":"Medium"},{"value":"high","name":"High"},{"value":"xhigh","name":"Extra High"},{"value":"max","name":"Max"}]}],
        "modes":{"currentModeId":"ask","availableModes":[{"id":"code","name":"Code"},{"id":"ask","name":"Ask"}]}}
        """
    /// fx 0.0.13's `initialize` answer.
    static let initialize =
        #"{"protocolVersion":1,"agentCapabilities":{"loadSession":true,"promptCapabilities":{"image":true,"audio":false,"embeddedContext":true},"mcpCapabilities":{"http":true,"sse":true,"acp":true},"sessionCapabilities":{"list":{},"resume":{},"close":{},"systemPrompt":{}},"_meta":{"fx":{"steering":true}}},"agentInfo":{"name":"fx","title":"fx","version":"0.0.13"},"authMethods":[]}"#

    /// A stand-in `fx` that answers the way fx 0.0.13 does and writes each call's arguments to `calls`, one per line.
    /// `models: nil` makes `fx models` fail.
    private func fakeFx(in directory: URL, status: String = signedIn, models: String? = Self.models, versionStatus: Int = 0) throws
        -> (executable: URL, calls: URL)
    {
        let script = directory.appendingPathComponent("fx")
        let calls = directory.appendingPathComponent("calls.txt")
        try """
            #!/bin/sh
            printf '%s\\n' "$*" >> '\(calls.path)'
            case "$*" in
              --version) printf '%s\\n' 'fx 0.0.13'; exit \(versionStatus) ;;
              'status --json') cat <<'EOF'
            \(status)
            EOF
              exit 0 ;;
              'models --json') \(models == nil ? "exit 1" : "cat <<'EOF'\n\(models!)\nEOF\nexit 0") ;;
            esac
            exit 2
            """.write(to: script, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: script.path)
        return (script, calls)
    }

    private func json(_ text: String) -> JSONValue {
        JSONValue.parse(text) ?? .null
    }

    private func makeSession(
        _ agent: ACPFakeAgent, launch: AgentLaunch = acpLaunch(.fx), defaultModel: @escaping @MainActor () -> String? = { nil }
    ) -> (ACPSession, ACPEventLog) {
        agent.initializeResult = json(Self.initialize)
        agent.sessionResult = json(Self.session)
        let session = ACPSession(launch: launch, flavor: FxFlavor(), transport: agent.factory, defaultModel: defaultModel)
        let log = ACPEventLog()
        log.attach(session)
        return (session, log)
    }

    private func configWrites(_ agent: ACPFakeAgent) -> [String] {
        agent.requests("session/set_config_option").map { "\($0["configId"]?.string ?? "")=\($0["value"]?.string ?? "")" }
    }

    private static let editPermission: JSONValue = [
        "sessionId": "sess-1",
        "toolCall": [
            "toolCallId": "toolu_01", "name": "write_file", "title": "file_mutation", "kind": "edit", "status": "pending",
            "rawInput": ["path": "notes.md", "content": "approval fixture"],
        ],
        "options": [
            ["optionId": "allow_once", "name": "Allow once", "kind": "allow_once"],
            ["optionId": "allow_always", "name": "Allow for this session", "kind": "allow_always"],
            ["optionId": "reject_once", "name": "Reject", "kind": "reject_once"],
        ],
    ]

    // MARK: Status

    @Test func readsTheSignInFromFxStatusWithoutOpeningASession() async throws {
        let directory = try acpTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let fx = try fakeFx(in: directory)
        let environment = ["PATH": "/usr/bin:/bin", "HOME": directory.path]

        let probe = await FxFlavor().probe(executable: fx.executable, environment: environment)
        #expect(try String(contentsOf: fx.calls, encoding: .utf8) == "--version\nstatus --json\nmodels --json\n")
        #expect(probe.status.state == .ready)
        #expect(probe.status.version == "0.0.13")
        #expect(probe.status.account == "fx login")
        #expect(probe.status.message == nil)
        #expect(probe.models.map(\.modelID) == ["default", "anthropic/claude-sonnet-5.5", "anthropic/claude-opus-5.5"])
        // "Default" stands for the model `fx status` reports, which a turn on it selects.
        #expect(probe.models[0].displayName == "Default (anthropic/claude-opus-5.5)")
        #expect(probe.defaultModel == "anthropic/claude-opus-5.5")
        // Every model has fx's Effort control, starting at Medium.
        for model in probe.models {
            #expect(model.efforts == ["auto", "low", "medium", "high", "xhigh", "max"])
            #expect(model.defaultEffort == "medium")
        }

        let provider = ACPProvider(profile: .fx)
        let status = await provider.detect(executable: fx.executable, environment: environment)
        #expect(status.state == .ready)
        #expect(await provider.models(status: status, environment: environment) == probe.models)
    }

    @Test func aSignedOutFxAsksForFxLogin() async throws {
        let directory = try acpTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let fx = try fakeFx(in: directory, status: Self.signedOut)
        let status = await ACPProvider(profile: .fx).detect(executable: fx.executable, environment: ["PATH": "/usr/bin:/bin"])
        #expect(status.state == .notAuthenticated)
        #expect(status.message?.contains("fx login") == true)
    }

    /// An fx whose status output Coincide cannot read is not reported as signed out.
    @Test func unreadableStatusIsNotASignOut() async throws {
        let directory = try acpTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let fx = try fakeFx(in: directory, status: "not json")
        let probe = await FxFlavor().probe(executable: fx.executable, environment: ["PATH": "/usr/bin:/bin"])
        #expect(probe.status.state == .ready)
        #expect(probe.status.account == nil)
        #expect(probe.status.message != nil)
        #expect(probe.defaultModel == nil)
        #expect(probe.models.first?.displayName == "Default")
    }

    @Test func aFailedModelListingStillOffersDefault() async throws {
        let directory = try acpTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let fx = try fakeFx(in: directory, models: nil)
        let probe = await FxFlavor().probe(executable: fx.executable, environment: ["PATH": "/usr/bin:/bin"])
        #expect(probe.status.state == .ready)
        #expect(probe.status.message?.isEmpty == false)
        #expect(probe.models.map(\.modelID) == ["default"])
    }

    @Test func anFxThatFailsToRunIsAnError() async throws {
        let directory = try acpTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let fx = try fakeFx(in: directory, versionStatus: 1)
        let status = await ACPProvider(profile: .fx).detect(executable: fx.executable, environment: ["PATH": "/usr/bin:/bin"])
        #expect(status.state == .error)
        #expect(status.version == "0.0.13")
        // Only `--version` ran.
        #expect(try String(contentsOf: fx.calls, encoding: .utf8) == "--version\n")
    }

    @Test func parsesStatusAndModelListings() {
        #expect(FxCLI.parseStatus(Self.signedIn) == FxCLI.Status(auth: "fx login", model: "anthropic/claude-opus-5.5"))
        #expect(FxCLI.parseStatus("[]") == nil)
        #expect(FxCLI.parseModels(#"{"ids":[" a/b ","",7,"c/d"]}"#) == ["a/b", "c/d"])
        #expect(FxCLI.parseModels("nope") == nil)
        // "default" is Coincide's id for Default, never one of fx's.
        #expect(FxCLI.modelOptions(defaultModel: nil, listed: ["default", "a", "a"]).map(\.modelID) == ["default", "a"])
    }

    // MARK: Session

    @Test func fxLaunchesItsACPServer() async throws {
        let agent = ACPFakeAgent()
        let (session, _) = makeSession(agent)
        try await session.start()
        #expect(agent.transport.arguments == ["acp"])
        // A session's model list names no default, so the picker keeps the probe's.
        #expect(FxFlavor().models(initialize: nil, setup: ACPSessionSetup(json: json(Self.session))).isEmpty)
    }

    /// As in T3 Code's recorded sessions, the first turn sets Medium and then `ask`, though fx already reports it.
    @Test func theFirstTurnStartsAtMediumAndSetsSupervised() async throws {
        let agent = ACPFakeAgent()
        let (session, log) = makeSession(agent, defaultModel: { "anthropic/claude-opus-5.5" })
        try await session.start()
        try await session.send(acpTurn("hi", .fx))
        #expect(configWrites(agent) == ["effort=medium", "mode=ask"])
        #expect(agent.requests("session/set_mode").isEmpty)
        #expect(!log.events.contains { if case .modelsDiscovered = $0 { true } else { false } })

        agent.finishPrompt()
        await acpWaitUntil { log.completions.count == 1 }
        try await session.send(acpTurn("again", .fx))
        #expect(configWrites(agent) == ["effort=medium", "mode=ask"])

        // A chosen effort replaces Medium.
        agent.finishPrompt()
        await acpWaitUntil { log.completions.count == 2 }
        try await session.send(acpTurn("think", .fx, effort: "max"))
        #expect(configWrites(agent).last == "effort=max")
    }

    /// fx runs a loaded session in its saved default until told otherwise, so every reopened session is told again.
    @Test func aLoadedSessionIsToldItsModeAgain() async throws {
        let agent = ACPFakeAgent()
        let (session, _) = makeSession(agent, launch: acpLaunch(.fx, resume: "sess-1"))
        agent.loadResult = json(Self.session)
        try await session.start()
        #expect(agent.requests("session/load").count == 1)
        try await session.send(acpTurn("hi", .fx, effort: "medium"))
        #expect(configWrites(agent) == ["effort=medium", "mode=ask"])
    }

    /// A failed write does not count, so the next turn sends the mode again.
    @Test func aModeFxRefusedIsSentAgain() async throws {
        let agent = ACPFakeAgent()
        let (session, log) = makeSession(agent)
        var refuse = true
        agent.handlers["session/set_config_option"] = { id, params in
            if params["configId"] == "mode", refuse {
                agent.fail(id, code: -32603, message: "busy")
            } else {
                agent.reply(id, [:])
            }
        }
        try await session.start()
        await #expect(throws: (any Error).self) { try await session.send(acpTurn("hi", .fx, effort: "medium")) }
        refuse = false
        try await session.send(acpTurn("hi", .fx, effort: "medium"))
        #expect(configWrites(agent).filter { $0.hasPrefix("mode=") } == ["mode=ask", "mode=ask"])
        agent.finishPrompt()
        await acpWaitUntil { log.completions.count == 1 }
    }

    /// A session that cannot run Supervised fails the turn instead of running in another mode (T3 Code's fx).
    @Test func aSessionWithoutAskFailsTheTurn() async throws {
        let agent = ACPFakeAgent()
        let (session, _) = makeSession(agent)
        agent.sessionResult = json(
            #"{"sessionId":"sess-1","configOptions":[{"id":"mode","name":"Mode","category":"mode","type":"select","currentValue":"code","options":[{"value":"code","name":"Code"}]}]}"#
        )
        try await session.start()
        do {
            try await session.send(acpTurn("hi", .fx))
            Issue.record("Expected the turn to fail")
        } catch {
            #expect(error.localizedDescription.contains("ask"))
        }
        #expect(agent.requests("session/prompt").isEmpty)
        #expect(!configWrites(agent).contains("mode=code"))
    }

    /// "Default" runs the model `fx status` reports when the session lists it (writing `model`, not fx's `provider`);
    /// one from another backend leaves the session's model. A model the thread picked goes to fx even unlisted.
    @Test func defaultRunsTheModelFxStatusReports() async throws {
        let agent = ACPFakeAgent()
        var statusModel: String? = "anthropic/claude-sonnet-5.5"
        let (session, log) = makeSession(agent, defaultModel: { statusModel })
        try await session.start()
        try await session.send(acpTurn("one", .fx, effort: "medium"))
        #expect(configWrites(agent).first == "model=anthropic/claude-sonnet-5.5")
        #expect(log.events.contains(.modelResolved("anthropic/claude-sonnet-5.5")))
        agent.finishPrompt()
        await acpWaitUntil { log.completions.count == 1 }

        try await session.send(acpTurn("two", .fx, model: "anthropic/claude-opus-5.5", effort: "medium"))
        #expect(configWrites(agent).last == "model=anthropic/claude-opus-5.5")
        agent.finishPrompt()
        await acpWaitUntil { log.completions.count == 2 }

        let writes = configWrites(agent).count
        statusModel = "spacexai/grok-4.7"
        try await session.send(acpTurn("three", .fx, effort: "medium"))
        #expect(configWrites(agent).count == writes)
        agent.finishPrompt()
        await acpWaitUntil { log.completions.count == 3 }

        try await session.send(acpTurn("four", .fx, model: "openai/gpt-5.5", effort: "medium"))
        #expect(configWrites(agent).last == "model=openai/gpt-5.5")
    }

    // MARK: Permission modes

    @Test func fxOffersOnlyAskForApprovalAndNoPlanMode() {
        #expect(ProviderKind.fx.accessModes == [.approval])
        #expect(ProviderKind.fx.accessMode(for: .fullAccess) == .approval)
        #expect(ProviderKind.fx.accessMode(for: .approval) == .approval)
        #expect(!ProviderKind.fx.supportsPlanMode)
        #expect(ProviderKind.fx.interactionMode(for: .plan) == .build)
        #expect(!ProviderKind.fx.supportsTextGeneration)
        for kind in ProviderKind.allCases where kind != .fx {
            #expect(kind.accessModes == AccessMode.allCases)
            #expect(kind.accessMode(for: .fullAccess) == .fullAccess)
            // Muse Code has no plan mode either (see MuseSessionTests).
            #expect(kind.interactionMode(for: .plan) == (kind == .muse ? .build : .plan))
            #expect(kind.supportsTextGeneration)
        }
    }

    /// fx has no full access: a thread set to it runs Supervised, so an edit still asks while a read does not
    /// (T3 Code's `fxPermissionDisposition` answers by the Supervised policy).
    @Test func aFullAccessThreadRunsSupervised() async throws {
        let agent = ACPFakeAgent()
        let (session, log) = makeSession(agent, launch: acpLaunch(.fx, accessMode: .fullAccess))
        try await session.start()
        try await session.send(acpTurn("write", .fx, effort: "medium", accessMode: .fullAccess))
        #expect(configWrites(agent).contains("mode=ask"))
        #expect(!configWrites(agent).contains("mode=code"))

        agent.ask(7, "session/request_permission", Self.editPermission)
        await acpWaitUntil { !log.approvals.isEmpty }
        #expect(agent.answers[7] == nil)
        #expect(log.approvals[0].options.map(\.id) == ["allow_once", "allow_always", "reject_once", ACPApprovals.cancelOptionID])
        session.respond(to: log.approvals[0].id, optionID: "reject_once")
        #expect(agent.answers[7]?.at("result.outcome") == ["outcome": "selected", "optionId": "reject_once"])

        var read = Self.editPermission.object ?? [:]
        read["toolCall"] = ["toolCallId": "r1", "name": "read_file", "kind": "read", "rawInput": ["path": "a"]]
        agent.ask(8, "session/request_permission", .object(read))
        await acpWaitUntil { agent.answers[8] != nil }
        #expect(agent.answers[8]?.at("result.outcome.optionId") == "allow_once")
        #expect(log.approvals.count == 1)
    }

    /// fx has no plan mode, so a thread in plan mode builds: the prompt carries build instructions and no mode changes.
    @Test func aPlanModeThreadBuilds() async throws {
        let agent = ACPFakeAgent()
        let (session, _) = makeSession(agent)
        try await session.start()
        try await session.send(acpTurn("hi", .fx, effort: "medium", interactionMode: .plan))
        #expect(agent.requests("session/prompt").last?["prompt"]?[0]?["text"]?.string == acpInstructed("hi", .build))
        #expect(configWrites(agent) == ["effort=medium", "mode=ask"])
    }

    @Test func theRunnerRunsFxInTheModesItHas() async throws {
        let store = AppStore(directory: FileManager.default.temporaryDirectory.appendingPathComponent("coincide-fx-\(UUID().uuidString)"))
        store.updateSettings { $0.checkpointsEnabled = false }
        let fx = ScriptedProvider(kind: .fx)
        fx.configure = { session in session.onSend = { session, _ in session.emit(.turnCompleted(.completed)) } }
        let runner = ThreadRunner(store: store, registry: ProviderRegistry(store: store, providers: [fx]))
        let project = store.addProject(at: URL(fileURLWithPath: "/tmp"))
        let threadID = store.createThread(in: project.id, selection: ModelSelection(provider: .fx, modelID: "default")).id
        store.updateThread(threadID) { thread in
            thread.accessMode = .fullAccess
            thread.interactionMode = .plan
        }

        await runner.send(threadID: threadID, text: "hello")
        let launch = try #require(fx.launches.last)
        #expect(launch.accessMode == .approval)
        #expect(launch.interactionMode == .build)
        let input = try #require(fx.last?.sent.last)
        #expect(input.accessMode == .approval)
        #expect(input.interactionMode == .build)
        // The thread keeps its own modes for the other agents.
        #expect(store.thread(threadID)?.accessMode == .fullAccess)
        #expect(store.thread(threadID)?.interactionMode == .plan)
    }

    /// fx keeps every session it opens, so another ready agent writes commit messages and pull request text.
    @Test func anotherAgentWritesTheTextOfAnFxThread() async {
        let store = AppStore(directory: FileManager.default.temporaryDirectory.appendingPathComponent("coincide-fx-\(UUID().uuidString)"))
        let selection = ModelSelection(provider: .fx, modelID: "default")
        let both = ProviderRegistry(store: store, providers: [ProbedProvider(kind: .fx), ProbedProvider(kind: .codex)])
        await both.refresh()
        #expect(both.usableSelection(preferring: selection) == selection)
        #expect(both.usableSelection(preferring: selection, writingText: true) == ModelSelection(provider: .codex, modelID: "m1"))

        // With no other agent ready, nothing writes it and the plain summary stands.
        let alone = ProviderRegistry(store: store, providers: [ProbedProvider(kind: .fx)])
        await alone.refresh()
        #expect(!alone.usableSelection(preferring: selection, writingText: true).provider.supportsTextGeneration)
    }

    // MARK: Sub-agents

    /// From T3 Code's recorded fx_subagent session: fx clips the reply to 199 bytes.
    @Test func subagentCallsShowTheTaskAndTheReadableReply() {
        var mapper = ACPEventMapper(workingDirectory: URL(fileURLWithPath: "/work"))
        mapper.beginTurn()
        let flavor = FxFlavor()
        let task = "Locate and read package.json in the repo root (or nearest). Summarize: name, version, packageManager, scripts."
        let started = mapper.map(
            ACPSessionUpdate(
                json: [
                    "sessionUpdate": "tool_call", "toolCallId": "call_1", "name": "subagent",
                    "title": "Subagent · Locate and read package.json in the repo root (or nearest). Summarize: name, version...",
                    "kind": "other", "status": "pending", "rawInput": ["request": ["action": "run", "task": .string(task)]],
                ]), flavor: flavor, terminals: nil)
        guard case .toolStarted(let info) = started.first else {
            Issue.record("Expected the call to start")
            return
        }
        #expect(info.category == .task)
        #expect(info.title == ACPToolCallState.truncate(task, 100))

        let clipped = #"{"ok":true,"result":"No `package.json` exists in this workspace checkout.\n\nEvidence:\n- `glob(\"package.json\")` → no matches\n- `glob(\"**/package.js"#
        let completed = mapper.map(
            ACPSessionUpdate(
                json: [
                    "sessionUpdate": "tool_call_update", "toolCallId": "call_1", "status": "completed",
                    "content": [["type": "content", "content": ["type": "text", "text": .string(clipped)]]],
                ]), flavor: flavor, terminals: nil)
        #expect(
            completed.contains(
                .toolCompleted(
                    id: "call_1", status: .completed,
                    output: "No `package.json` exists in this workspace checkout.\n\nEvidence:\n- `glob(\"package.json\")` → no matches\n- `glob(\"**/package.js…"
                )))
    }

    @Test func subagentOutcomes() {
        #expect(FxSubagent.outcome(#"{"ok":false,"result":"blocked"}"#) == FxSubagent.Outcome(ok: false, result: "blocked"))
        #expect(FxSubagent.outcome(#"{"ok":true,"result":null}"#) == FxSubagent.Outcome(ok: true, result: nil))
        // A clip inside an escape drops the partial escape.
        #expect(FxSubagent.outcome(#"{"ok":true,"result":"caf\u00"#) == FxSubagent.Outcome(ok: true, result: "caf…"))
        #expect(FxSubagent.outcome(#"{"ok":true,"result":"party \ud83c"#) == FxSubagent.Outcome(ok: true, result: "party …"))
        #expect(FxSubagent.outcome(#"{"ok":true,"result":"whole""#) == FxSubagent.Outcome(ok: true, result: "whole"))
        #expect(FxSubagent.outcome("plain text") == nil)

        // fx 0.0.14 wraps the request; later fx sends it flat.
        #expect(FxSubagent.request(["request": ["action": "run", "task": "t"]]) == FxSubagent.Request(prompt: "t", agent: nil))
        #expect(FxSubagent.request(["action": "message", "agent": "a1", "message": "m"]) == FxSubagent.Request(prompt: "m", agent: "a1"))
        #expect(FxSubagent.request(["action": "stop"]) == nil)

        var failed = ACPToolCallState(
            ACPToolCallUpdate(
                id: "s", name: "subagent", status: "completed", content: [.content(.text(#"{"ok":false,"result":"no access"}"#))],
                rawInput: ["action": "message", "agent": "reviewer", "message": "Check it"]))
        FxFlavor().normalize(&failed)
        #expect(failed.status == .failed)
        #expect(failed.title == "reviewer: Check it")
        #expect(failed.outputText() == "no access")
    }

    // MARK: Schema

    @Test func theModelOptionIsFxsModelNotItsBackend() {
        let setup = ACPSessionSetup(json: json(Self.session))
        #expect(setup.modelOption?.id == "model")
        #expect(setup.reasoningOption?.id == "effort")
        #expect(setup.modeOption?.id == "mode")
        #expect(ACPToolCallUpdate(json: ["toolCallId": "t", "name": "write_file"])?.name == "write_file")
    }

    // MARK: Skills

    private func writeSkill(_ root: URL, _ folder: String, _ contents: String) throws {
        let directory = root.appendingPathComponent(folder, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try Data(contents.utf8).write(to: directory.appendingPathComponent("SKILL.md"))
    }

    private func writeSkill(_ root: URL, _ name: String) throws {
        try writeSkill(root, name, "---\nname: \(name)\ndescription: \(name) skill\n---\n\nBody.\n")
    }

    /// fx 0.0.13 scans the workspace folders from the workspace up to HOME, then ~/.fx/skills, then the home
    /// compatibility folders, and lists ~/.fx/skills first, then the workspace's own folders, then the compatibility
    /// ones in scan order.
    @Test func listsSkillsInFxsOwnOrder() throws {
        let home = try acpTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: home) }
        // The workspace sits under the fake HOME, so the walk up stops there.
        let parent = home.appendingPathComponent("projects")
        let workspace = parent.appendingPathComponent("app")
        try writeSkill(workspace.appendingPathComponent(".claude/skills"), "workspace-claude")
        try writeSkill(workspace.appendingPathComponent(".fx/skills"), "workspace-fx")
        try writeSkill(parent.appendingPathComponent(".agents/skills"), "parent-agents")
        try writeSkill(parent.appendingPathComponent("skills"), "parent-shared")
        try writeSkill(home.appendingPathComponent(".claude/skills"), "home-claude")
        try writeSkill(home.appendingPathComponent(".fx/skills"), "home-fx")
        // HOME is no workspace ancestor, and ~/skills is no fx folder.
        try writeSkill(home.appendingPathComponent("skills"), "home-shared")

        let skills = FxSkills.discover(workingDirectory: workspace, environment: ["HOME": home.path])
        #expect(
            skills.map(\.name) == ["home-fx", "workspace-fx", "parent-shared", "workspace-claude", "parent-agents", "home-claude"])
        #expect(skills.first?.description == "home-fx skill")
        #expect(skills.first?.scope == .user)
        #expect(skills[1].scope == .project)
        #expect(skills[1].path == workspace.appendingPathComponent(".fx/skills/workspace-fx/SKILL.md").path)
        #expect(FxSkills.discover(workingDirectory: workspace, environment: [:]).isEmpty)
    }

    /// For `$review` with two skills of exactly that name, fx's model loads the first in scan order, so only that one
    /// is offered; `Review` is another skill `$Review` loads. fx skips a SKILL.md whose frontmatter has no name or
    /// never closes, and a linked folder in its managed ~/.fx/skills.
    @Test func offersTheSkillFxLoadsForEachName() throws {
        let home = try acpTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: home) }
        let workspace = home.appendingPathComponent("app")
        let managed = home.appendingPathComponent(".fx/skills")
        try writeSkill(workspace.appendingPathComponent(".fx/skills"), "review", "---\nname: review\n---\nBody.\n")
        try writeSkill(home.appendingPathComponent(".claude/skills"), "review", "---\nname: Review\n---\n")
        try writeSkill(managed, "plain", "No frontmatter.\n")
        try writeSkill(managed, "unnamed", "---\ndescription: Missing name\n---\n")
        try writeSkill(managed, "unclosed", "---\nname: unclosed\n")
        // A continued plain value is fx's `unsupported_multiline`, and fx trims only spaces and tabs, so a trailing
        // vertical tab is a control byte: both these `review`s are invalid and the valid ones stay the only two.
        try writeSkill(home.appendingPathComponent(".codex/skills"), "review", "---\nname: review\u{0B}\n---\n")
        try writeSkill(
            home.appendingPathComponent(".agents/skills"), "review", "---\nname: review\ndescription: first line\n  second line\n---\n")
        // fx sees no frontmatter after a byte order mark, so this one is `bom-folder`, not `bom-name`, and its body may
        // run past 1 MB.
        let bom = managed.appendingPathComponent("bom-folder")
        try FileManager.default.createDirectory(at: bom, withIntermediateDirectories: true)
        try (Data([0xEF, 0xBB, 0xBF]) + Data("---\nname: bom-name\n---\n\(String(repeating: "x", count: 1_100_000))".utf8))
            .write(to: bom.appendingPathComponent("SKILL.md"))
        // A literal U+FFFD is valid text to fx; an invalid UTF-8 byte is not.
        try writeSkill(managed, "replacement", "---\nname: replacement\ndescription: Replace \u{FFFD} in imported text.\n---\n")
        let badBytes = managed.appendingPathComponent("bad-bytes")
        try FileManager.default.createDirectory(at: badBytes, withIntermediateDirectories: true)
        try (Data("---\nname: bad".utf8) + Data([0xFF, 0x0A, 0x2D, 0x2D, 0x2D, 0x0A])).write(to: badBytes.appendingPathComponent("SKILL.md"))
        // fx folds only ASCII case, so these two are distinct.
        try writeSkill(managed, "accent-upper", "---\nname: \u{00C9}t\u{00E9}\n---\n")
        try writeSkill(managed, "accent-lower", "---\nname: \u{00E9}t\u{00E9}\n---\n")
        try writeSkill(home.appendingPathComponent("library"), "linked", "---\nname: linked\n---\n")
        try FileManager.default.createSymbolicLink(
            at: managed.appendingPathComponent("linked"), withDestinationURL: home.appendingPathComponent("library/linked"))
        try FileManager.default.createDirectory(at: managed.appendingPathComponent("linked-file"), withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(
            at: managed.appendingPathComponent("linked-file/SKILL.md"),
            withDestinationURL: home.appendingPathComponent("library/linked/SKILL.md"))

        let skills = FxSkills.discover(workingDirectory: workspace, environment: ["HOME": home.path])
        #expect(skills.map(\.name) == ["\u{00E9}t\u{00E9}", "\u{00C9}t\u{00E9}", "bom-folder", "plain", "replacement", "review", "Review"])
        #expect(
            skills.map(\.path) == [
                managed.appendingPathComponent("accent-lower/SKILL.md").path,
                managed.appendingPathComponent("accent-upper/SKILL.md").path,
                managed.appendingPathComponent("bom-folder/SKILL.md").path, managed.appendingPathComponent("plain/SKILL.md").path,
                managed.appendingPathComponent("replacement/SKILL.md").path,
                workspace.appendingPathComponent(".fx/skills/review/SKILL.md").path,
                home.appendingPathComponent(".claude/skills/review/SKILL.md").path,
            ])

        // The `$` menu offers one skill per name regardless of case; typing `$Review` still runs that one.
        #expect(ProviderSkill.matching("", in: skills).map(\.name) == ["\u{00E9}t\u{00E9}", "bom-folder", "plain", "replacement", "review"])
    }

    /// Nix home-manager and dotfile setups link ~/.fx/skills; fx then loads nothing from it, while the compatibility
    /// folders still count.
    @Test func listsNothingFromALinkedManagedFolder() throws {
        let home = try acpTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: home) }
        try writeSkill(home.appendingPathComponent("dotfiles/fx-skills"), "managed", "---\nname: managed\n---\n")
        try writeSkill(home.appendingPathComponent(".claude/skills"), "compat", "---\nname: compat\n---\n")
        try FileManager.default.createDirectory(at: home.appendingPathComponent(".fx"), withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(
            at: home.appendingPathComponent(".fx/skills"), withDestinationURL: home.appendingPathComponent("dotfiles/fx-skills"))

        let skills = FxSkills.discover(workingDirectory: home.appendingPathComponent("app"), environment: ["HOME": home.path])
        #expect(skills.map(\.name) == ["compat"])
    }

    @Test func readsSkillFrontmatterTheWayFxDoes() {
        func parse(_ text: String, folder: String = "folder") -> String? {
            FxSkills.metadata(text, folderName: folder).map { [$0.name, $0.description].compactMap(\.self).joined(separator: "|") }
        }
        #expect(parse("---\r\nname: crlf\r\ndescription: 'quoted'\r\n---\r\n") == "crlf|quoted")
        #expect(parse("---\nname: \"x\"\n# comment\nother: ignored\n---") == "x")
        // Neighbouring lines join; a blank line breaks, and its own line break stays (T3 Code's port of fx).
        #expect(parse("---\nname: folded\ndescription: >\n  first\n  second\n\n  third\n---\n") == "folded|first second\n\nthird")
        #expect(parse("---\nname: literal\ndescription: |\n  first\n  second\n---\n") == "literal|first\nsecond")
        // A tab or a shrinking indent in a block, a repeated key, a mismatched quote or a block name is unreadable.
        #expect(parse("---\nname: a\ndescription: >\n\tx\n---\n") == nil)
        #expect(parse("---\nname: a\ndescription: >\n    x\n  y\n---\n") == nil)
        #expect(parse("---\nname: a\nname: b\n---\n") == nil)
        #expect(parse("---\nname: 'a\"\n---\n") == nil)
        #expect(parse("---\nname: |\n---\n") == nil)
        #expect(parse("---\nname: a/b\n---\n") == nil)
        // Without frontmatter the folder names the skill, if it is a valid name.
        #expect(parse("----\nname: dashes\n---\n") == "folder")
        #expect(parse("Body", folder: "..") == nil)
        // Frontmatter that closes past fx's 64 KiB is not read.
        #expect(parse("---\nname: big\ndescription: \(String(repeating: "x", count: 70_000))\n---\n") == nil)
    }

    @Test func theSkillMenuRanksNamesFirst() {
        let skills = [
            ProviderSkill(name: "code-review", description: "Reviews a diff", path: "/a", scope: .user),
            ProviderSkill(name: "review", path: "/b", scope: .project),
            ProviderSkill(name: "deploy", description: "Ships after review", path: "/c", scope: .project),
            ProviderSkill(name: "previewer", path: "/d", scope: .user),
            ProviderSkill(name: "Review", path: "/e", scope: .user),
        ]
        #expect(ProviderSkill.matching("REVIEW", in: skills).map(\.path) == ["/b", "/a", "/d", "/c"])
        #expect(ProviderSkill.matching("dep", in: skills).map(\.name) == ["deploy"])
        #expect(ProviderSkill.matching("zzz", in: skills).isEmpty)
        #expect(skills[1].mention == "$review")
    }
}
