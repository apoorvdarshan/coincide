import Foundation
import Testing

@testable import CoincideKit

private func json(_ text: String) -> JSONValue {
    JSONValue.parse(text) ?? .null
}

private let localAgent = ACPAgentConfig(
    id: "dsh", name: "DeepSeek Harness", source: .local, command: "dsh", arguments: ["--profile", "acp", "two words", "$HOME"])

private func registryAgent(id: String = "devin", data: URL) -> (ACPAgentConfig, ACPRegistryPaths) {
    let install = ACPRegistryInstall(
        agentID: "devin", version: "3000.11.228", distribution: .npx, executable: "npm/bin/devin", arguments: ["acp"],
        environment: ["DEVIN_MODE": "acp", "PATH_HINT": "registry"], binDirectory: "npm/bin")
    return (ACPAgentConfig(id: id, name: "Devin", source: .registry, registry: install), ACPRegistryPaths(dataDirectory: data))
}

/// The instance ID a custom agent gets, and how `ProviderKind` writes it.
struct ACPAgentKindTests {
    @Test func builtInKindsKeepTheirRawValuesAndCustomAgentsArePrefixed() throws {
        #expect(
            ProviderKind.allCases.map(\.rawValue) == ["claude", "codex", "cursor", "grok", "opencode", "pi", "antigravity", "fx", "muse"])
        #expect(ProviderKind.acp("devin").rawValue == "acp:devin")
        #expect(ProviderKind(rawValue: "acp:devin") == .acp("devin"))
        #expect(ProviderKind(rawValue: "codex") == .codex)
        for invalid in ["acp:", "acp:Has Space", "acp:../x", "acp", "gemini"] {
            #expect(ProviderKind(rawValue: invalid) == nil, "\(invalid)")
        }
        let encoded = try JSONEncoder().encode([ProviderKind.acp("devin"), .claude])
        #expect(String(decoding: encoded, as: UTF8.self) == #"["acp:devin","claude"]"#)
        #expect(try JSONDecoder().decode([ProviderKind].self, from: encoded) == [.acp("devin"), .claude])
        #expect(ProviderKind.acp("devin").commandName == "devin")
        #expect(ProviderKind.codex.commandName == "codex")
    }

    @Test func instanceIDsAreSlugsThatNeverTakeABuiltInName() {
        #expect(ACPAgentConfig.makeID(from: "DeepSeek Harness", existing: []) == "deepseek-harness")
        #expect(ACPAgentConfig.makeID(from: "devin", existing: ["devin"]) == "devin-2")
        #expect(ACPAgentConfig.makeID(from: "devin", existing: ["devin", "devin-2"]) == "devin-3")
        #expect(ACPAgentConfig.makeID(from: "Claude", existing: []) == "claude-2")
        #expect(ACPAgentConfig.makeID(from: "model", existing: []) == "model-2")
        #expect(ACPAgentConfig.makeID(from: "fx", existing: []) == "fx-2")
        #expect(ACPAgentConfig.makeID(from: "!!!", existing: []) == "agent")
        #expect(ACPAgentConfig.makeID(from: "mistral-vibe", existing: []) == "mistral-vibe")
        let long = ACPAgentConfig.makeID(from: String(repeating: "a", count: 200), existing: [])
        #expect(ACPAgentConfig.isValidID(long))
        #expect(ACPAgentConfig.isValidID(ACPAgentConfig.makeID(from: "Ünïcode Agent ✨", existing: [])))
    }

    /// The per-agent mode hooks fx and Muse Code introduced: an added agent runs in either access mode and in plan
    /// mode, starts on, and never writes commit messages or pull request text (T3 Code keeps registry instances out of
    /// its text generation).
    @Test func addedAgentsTakeEveryModeButWriteNoText() {
        let kind = ProviderKind.acp("devin")
        #expect(kind.accessModes == AccessMode.allCases)
        #expect(kind.accessMode(for: .fullAccess) == .fullAccess)
        #expect(kind.supportsPlanMode)
        #expect(kind.interactionMode(for: .plan) == .plan)
        #expect(kind.isEnabledByDefault)
        #expect(!kind.supportsTextGeneration)
        #expect(ProviderKind.codex.supportsTextGeneration)
        #expect(AppSettings().settings(for: kind).isEnabled)
    }

    @Test func aCustomAgentIsNamedAfterItsSettings() {
        ACPAgentNames.shared.register([ACPAgentConfig(id: "named-agent-test", name: "  My Agent  ", source: .local)])
        #expect(ProviderKind.acp("named-agent-test").displayName == "My Agent")
        // An agent Coincide never heard of reads as its id.
        #expect(ProviderKind.acp("unknown-agent-test").displayName == "unknown-agent-test")
    }
}

/// Settings and threads with custom agents round-trip, and files written before them read as before.
struct ACPAgentSettingsTests {
    @Test func agentsRoundTrip() throws {
        let data = try acpTemporaryDirectory()
        var settings = AppSettings()
        settings.acpAgents = [localAgent, registryAgent(data: data).0]
        settings.providers[.acp("dsh")] = ProviderSettings(customModels: ["deepseek-v4"], environment: ["DSH_HOME": "/tmp/dsh"])
        settings.defaultSelection = ModelSelection(provider: .acp("dsh"), modelID: "default")
        let encoded = try JSONEncoder().encode(settings)
        let decoded = try JSONDecoder().decode(AppSettings.self, from: encoded)
        #expect(decoded == settings)
        #expect(decoded.acpAgent("devin")?.registry?.binDirectory == "npm/bin")
        #expect(decoded.settings(for: .acp("dsh")).customModels == ["deepseek-v4"])
    }

    @Test func settingsWrittenBeforeCustomAgentsReadTheSame() throws {
        // Swift writes the provider map as alternating keys and values; nothing about it changes.
        let old = #"{"providers":["codex",{"isEnabled":false},"claude",{"executablePath":"/opt/claude"}],"defaultSelection":{"provider":"codex","modelID":"gpt-5"},"fontSize":14}"#
        let settings = try JSONDecoder().decode(AppSettings.self, from: Data(old.utf8))
        #expect(settings.acpAgents.isEmpty)
        #expect(settings.settings(for: .codex).isEnabled == false)
        #expect(settings.settings(for: .claude).executablePath == "/opt/claude")
        #expect(settings.defaultSelection == ModelSelection(provider: .codex, modelID: "gpt-5"))
        let reencoded = try #require(try JSONSerialization.jsonObject(with: try JSONEncoder().encode(settings)) as? [String: Any])
        #expect((reencoded["providers"] as? [Any])?.count == 4)
        #expect((reencoded["acpAgents"] as? [Any])?.isEmpty == true)
    }

    @Test func unreadableAgentsAreSkippedNotTheSettings() throws {
        let text = #"""
            {"acpAgents":[
              {"id":"good","name":"Good","source":"local","command":"good","arguments":["a"]},
              {"id":"Bad ID","name":"Bad","source":"local"},
              {"name":"No id"},
              {"id":"good","name":"Duplicate","source":"local"},
              {"id":"broken-install","name":"Broken","source":"registry","registry":{"agentID":"x","version":"..","distribution":"binary","executable":"x"}},
              {"id":"future","name":"Future","source":"satellite","command":"f"}
            ],
            "providers":["acp:good",{"isEnabled":false},"acp:Bad ID",{"isEnabled":false}],
            "fontSize":16}
            """#
        let settings = try JSONDecoder().decode(AppSettings.self, from: Data(text.utf8))
        #expect(settings.acpAgents.map(\.id) == ["good", "broken-install", "future"])
        #expect(settings.acpAgent("good")?.arguments == ["a"])
        // A registry agent whose install record can't be trusted keeps no record; Settings offers to add it again.
        #expect(settings.acpAgent("broken-install")?.registry == nil)
        #expect(settings.acpAgent("future")?.source == .local)
        #expect(settings.settings(for: .acp("good")).isEnabled == false)
        #expect(settings.providers.count == 1)
        #expect(settings.fontSize == 16)
    }

    @Test func threadsKeepCustomAgentSelectionsAndSessions() throws {
        var thread = ChatThread(projectID: UUID(), selection: ModelSelection(provider: .acp("devin"), modelID: "swe-1.5", effort: "high"))
        thread.sessions = [.acp("devin"): ProviderSessionRef(sessionID: "native-1", seenItemCount: 3), .codex: ProviderSessionRef(sessionID: "c", seenItemCount: 1)]
        thread.items = [TranscriptItem(kind: .assistant, text: "hi", provider: .acp("devin"), modelID: "swe-1.5")]
        let decoded = try JSONDecoder().decode(ChatThread.self, from: try JSONEncoder().encode(thread))
        #expect(decoded.selection == thread.selection)
        #expect(decoded.sessions == thread.sessions)
        #expect(decoded.items.first?.provider == .acp("devin"))

        // A thread of a version without custom agents reads unchanged.
        let id = UUID()
        let old = #"{"id":"\#(id)","projectID":"\#(UUID())","selection":{"provider":"grok","modelID":"grok-build"},"sessions":["grok",{"sessionID":"g","seenItemCount":2}],"items":[]}"#
        let oldThread = try JSONDecoder().decode(ChatThread.self, from: Data(old.utf8))
        #expect(oldThread.selection.provider == .grok)
        #expect(oldThread.sessions[.grok]?.sessionID == "g")
    }
}

/// A custom agent runs through the shared ACP session with its own executable, literal arguments and environment.
@MainActor
struct ACPCustomFlavorTests {
    @Test func aLocalCommandStartsWithItsLiteralArgumentsAndTheProvidersEnvironment() async throws {
        let agent = ACPFakeAgent()
        let launch = acpLaunch(.acp("dsh"), environment: ["DSH_HOME": "/tmp/dsh", "PATH": "/usr/bin"])
        let session = ACPSession(launch: launch, flavor: ACPCustomFlavor(config: localAgent), transport: agent.factory)
        try await session.start()
        // Passed as written: no shell splits "two words" or expands "$HOME".
        #expect(agent.transport.arguments == ["--profile", "acp", "two words", "$HOME"])
        #expect(agent.transport.environment["DSH_HOME"] == "/tmp/dsh")
        #expect(agent.transport.environment["PATH"] == "/usr/bin")
        #expect(session.provider == .acp("dsh"))
        #expect(ACPCustomFlavor.executableNames(localAgent, paths: .standard) == ["dsh"])
        session.shutdown()
    }

    @Test func localCommandsAreANameOrAnAbsolutePath() {
        #expect(ACPAgentConfig.isValidCommand("dsh"))
        #expect(ACPAgentConfig.isValidCommand("/opt/agents/dsh"))
        #expect(ACPAgentConfig.isValidCommand("~/bin/dsh"))
        #expect(!ACPAgentConfig.isValidCommand("bin/dsh"))
        #expect(!ACPAgentConfig.isValidCommand(""))
        var relative = localAgent
        relative.command = "./dsh"
        #expect(ACPCustomFlavor.executableNames(relative, paths: .standard).isEmpty)
    }

    @Test func aRegistryAgentGetsTheRegistrysEnvironmentAndItsPackageFirstOnPath() throws {
        let data = try acpTemporaryDirectory()
        let (config, paths) = registryAgent(data: data)
        let flavor = ACPCustomFlavor(config: config, paths: paths)
        let environment = flavor.environment(["PATH": "/usr/bin", "DEVIN_MODE": "user"], executable: URL(fileURLWithPath: "/x"))
        // As T3 Code merges it, the registry's environment goes over the provider's.
        #expect(environment["DEVIN_MODE"] == "acp")
        #expect(environment["PATH"] == paths.versionDirectory("devin", "3000.11.228").path + "/npm/bin:/usr/bin")
        #expect(flavor.arguments(for: .fullAccess) == ["acp"])
        // Devin runs its commands in Coincide's terminals.
        #expect(flavor.clientCapabilities.terminal)
        #expect(!ACPCustomFlavor(config: localAgent).clientCapabilities.terminal)
        // Nothing installed yet: no executable to find.
        #expect(ACPCustomFlavor.executableNames(config, paths: paths).isEmpty)

        let bin = paths.versionDirectory("devin", "3000.11.228").appendingPathComponent("npm/bin", isDirectory: true)
        try FileManager.default.createDirectory(at: bin, withIntermediateDirectories: true)
        FileManager.default.createFile(atPath: bin.appendingPathComponent("devin").path, contents: Data(), attributes: [.posixPermissions: 0o755])
        #expect(ACPCustomFlavor.executableNames(config, paths: paths) == [bin.appendingPathComponent("devin").path])
    }

    @Test func devinsGenericToolTitlesUseTheToolName() {
        var call = ACPToolCallState(ACPToolCallUpdate(id: "t1", title: "Tool", meta: ["cognition.ai/inferenceToolName": "grep_search"]))
        ACPCustomFlavor(config: localAgent).normalize(&call)
        #expect(call.title == "grep_search")
        call.title = "Search for TODO"
        ACPCustomFlavor(config: localAgent).normalize(&call)
        #expect(call.title == "Search for TODO")
    }

    // MARK: Sign-in method selection

    private func signedOutAgent(_ methods: String) -> ACPFakeAgent {
        let agent = ACPFakeAgent()
        agent.initializeResult = json(#"{"protocolVersion":1,"authMethods":\#(methods)}"#)
        var attempts = 0
        agent.handlers["session/new"] = { id, _ in
            attempts += 1
            if attempts == 1 { agent.fail(id, code: ACPError.authRequired, message: "Authentication required") } else {
                agent.reply(id, ["sessionId": "sess-1"])
            }
        }
        return agent
    }

    @Test func aSessionSignsInWithTheFirstMethodTheAgentCompletesByItself() async throws {
        let agent = signedOutAgent(#"[{"id":"key","name":"API key","type":"env_var","vars":[{"name":"DEVIN_API_KEY"}]},{"id":"login","name":"Login","type":"terminal","args":["login"]},{"id":"browser","name":"Browser"}]"#)
        let session = ACPSession(launch: acpLaunch(.acp("dsh")), flavor: ACPCustomFlavor(config: localAgent), transport: agent.factory)
        try await session.start()
        #expect(agent.requests("authenticate").map { $0["methodId"] } == ["browser"])
        session.shutdown()
    }

    @Test func aSessionUsesTheChosenMethodOnlyWhenTheAgentListsIt() async throws {
        var config = localAgent
        config.authMethodID = "sso"
        let listed = signedOutAgent(#"[{"id":"browser","name":"Browser"},{"id":"sso","name":"SSO","type":"agent"}]"#)
        let first = ACPSession(launch: acpLaunch(.acp("dsh")), flavor: ACPCustomFlavor(config: config), transport: listed.factory)
        try await first.start()
        #expect(listed.requests("authenticate").map { $0["methodId"] } == ["sso"])
        first.shutdown()

        let unlisted = signedOutAgent(#"[{"id":"browser","name":"Browser"}]"#)
        let second = ACPSession(launch: acpLaunch(.acp("dsh")), flavor: ACPCustomFlavor(config: config), transport: unlisted.factory)
        await #expect(throws: ACPError.self) { try await second.start() }
        #expect(unlisted.requests("authenticate").isEmpty)
        second.shutdown()
    }

    @Test func terminalAndKeyMethodsNeverRunInsideASession() async throws {
        let agent = signedOutAgent(#"[{"id":"login","name":"Login","type":"terminal"},{"id":"key","name":"Key","type":"env_var"}]"#)
        let session = ACPSession(launch: acpLaunch(.acp("dsh")), flavor: ACPCustomFlavor(config: localAgent), transport: agent.factory)
        await #expect(throws: ACPError.self) { try await session.start() }
        #expect(agent.requests("authenticate").isEmpty)
        session.shutdown()
    }

    // MARK: Probe

    @Test func aProbeListsTheAgentsModelsFromATestSession() async throws {
        let agent = ACPFakeAgent()
        agent.initializeResult = json(#"{"protocolVersion":1,"agentInfo":{"name":"dsh","version":"0.4.2"},"agentCapabilities":{"sessionCapabilities":{"close":{}}}}"#)
        agent.sessionResult = json(
            #"{"sessionId":"probe-1","models":{"currentModelId":"deepseek-v4","availableModels":[{"modelId":"deepseek-v4","name":"DeepSeek V4"},{"modelId":"deepseek-r2","name":"DeepSeek R2"}]}}"#)
        // Devin's sessions get terminals; its probe, like T3 Code's, offers none.
        let devin = registryAgent(data: try acpTemporaryDirectory())
        let flavor = ACPCustomFlavor(config: localAgent, transport: agent.factory)
        let probe = await flavor.probe(executable: URL(fileURLWithPath: "/usr/bin/true"), environment: ["PATH": "/usr/bin"])
        #expect(agent.requests("initialize").first?.at("clientCapabilities.terminal") == false)
        let devinAgent = ACPFakeAgent()
        _ = await ACPCustomFlavor(config: devin.0, paths: devin.1, transport: devinAgent.factory)
            .probe(executable: URL(fileURLWithPath: "/usr/bin/true"), environment: [:])
        #expect(devinAgent.requests("initialize").first?.at("clientCapabilities.terminal") == false)
        #expect(probe.status.state == .ready)
        #expect(probe.status.version == "0.4.2")
        #expect(probe.models.map(\.modelID) == ["default", "deepseek-v4", "deepseek-r2"])
        #expect(probe.models.first?.displayName == "Default (DeepSeek V4)")
        #expect(agent.transport.arguments == localAgent.arguments)
        // The probe never signs in, and closes its test session.
        #expect(agent.requests("authenticate").isEmpty)
        await acpWaitUntil("the test session closes") { !agent.requests("session/close").isEmpty }
        await acpWaitUntil("the probe stops the agent") { agent.transport.isTerminated }
    }

    @Test(arguments: [
        (#"[{"id":"key","name":"API key","type":"env_var","vars":[{"name":"DSH_API_KEY"}]}]"#, "Set DSH_API_KEY in DeepSeek Harness’s environment variables in Settings, then check again."),
        (#"[{"id":"login","name":"Device login","type":"terminal","args":["login"]}]"#, "Sign in to DeepSeek Harness in Settings with “Device login”. It runs in Terminal."),
        (#"[{"id":"browser","name":"Browser"}]"#, "Sign in to DeepSeek Harness in Settings with “Browser”."),
        ("[]", "DeepSeek Harness needs you to sign in."),
    ])
    func aProbeTheAgentRefusesSaysHowToSignIn(methods: String, message: String) async throws {
        let agent = ACPFakeAgent()
        agent.initializeResult = json(#"{"protocolVersion":1,"authMethods":\#(methods)}"#)
        agent.handlers["session/new"] = { id, _ in agent.fail(id, code: ACPError.authRequired, message: "Authentication required") }
        let probe = await ACPCustomFlavor(config: localAgent, transport: agent.factory)
            .probe(executable: URL(fileURLWithPath: "/usr/bin/true"), environment: [:])
        #expect(probe.status.state == .notAuthenticated)
        #expect(probe.status.message == message)
        #expect(agent.requests("authenticate").isEmpty)
    }

    @Test func aProbeThatFailsReportsTheError() async throws {
        let agent = ACPFakeAgent()
        agent.handlers["initialize"] = { id, _ in agent.fail(id, code: -32603, message: "missing config file") }
        let probe = await ACPCustomFlavor(config: localAgent, transport: agent.factory)
            .probe(executable: URL(fileURLWithPath: "/usr/bin/true"), environment: [:])
        #expect(probe.status.state == .error)
        #expect(probe.status.message?.contains("missing config file") == true)
        #expect(probe.models.map(\.modelID) == ["default"])
    }
}

/// Signing in from Settings with the methods the agent advertises (T3 Code's `auth.test.ts`).
@MainActor
struct ACPAgentSignInTests {
    private let launch = ACPAgentLaunch(
        name: "Devin", executable: URL(fileURLWithPath: "/Applications/Devin Tools/devin"), arguments: ["acp"],
        environment: ["PATH": "/usr/bin", "DEVIN_API_KEY": "secret-key"], registryEnvironment: ["DEVIN_MODE": "acp"])

    private func agent(_ methods: String, canLogout: Bool = false) -> ACPFakeAgent {
        let agent = ACPFakeAgent()
        let logout = canLogout ? #","agentCapabilities":{"auth":{"logout":{}}}"# : ""
        agent.initializeResult = json(#"{"protocolVersion":1,"authMethods":\#(methods)\#(logout)}"#)
        return agent
    }

    @Test func discoveryListsTheAdvertisedMethods() async throws {
        let agent = agent(#"[{"id":"browser","name":"Browser","description":"Sign in with your account"},{"id":"login","name":"Login","type":"terminal","args":["auth","login"],"env":{"LOGIN":"yes"}},{"id":"key","name":"Key","type":"env_var","vars":[{"name":"DEVIN_API_KEY"}],"link":"https://example.com/keys"}]"#, canLogout: true)
        let signIn = ACPAgentSignIn(transport: agent.factory)
        signIn.discover(launch)
        await acpWaitUntil("discovery ends") { signIn.hasDiscovered && !signIn.isActive }
        #expect(signIn.methods.map(\.id) == ["browser", "login", "key"])
        #expect(signIn.methods[1].arguments == ["auth", "login"])
        #expect(signIn.methods[1].environment == ["LOGIN": "yes"])
        #expect(signIn.methods[2].variables == ["DEVIN_API_KEY"])
        #expect(signIn.methods[2].link?.absoluteString == "https://example.com/keys")
        #expect(signIn.canLogout)
        #expect(agent.requests("authenticate").isEmpty)
        #expect(agent.transport.arguments == ["acp"])
        // Only a sign-in offers to open pages.
        #expect(agent.requests("initialize").first?.at("clientCapabilities.elicitation.url") == nil)
    }

    @Test func anAgentMethodSignsInAndIsConfirmedByATestSession() async throws {
        let agent = agent(#"[{"id":"browser","name":"Browser"}]"#)
        let signIn = ACPAgentSignIn(transport: agent.factory)
        signIn.signIn(methodID: "browser", launch)
        await acpWaitUntil("sign-in ends") { signIn.phase == .succeeded || signIn.phase == .failed }
        #expect(signIn.phase == .succeeded)
        #expect(agent.requests.map(\.method) == ["initialize", "authenticate", "session/new"])
        #expect(agent.requests("initialize").first?.at("clientCapabilities.elicitation.url") != nil)
        #expect(agent.requests("initialize").first?.at("clientCapabilities.terminal") == false)
        #expect(agent.requests("authenticate").first?["methodId"] == "browser")
        await acpWaitUntil("the agent stops") { agent.transport.isTerminated }
    }

    @Test func aBrowserPageOpensOnlyOnceTheUserAgrees() async throws {
        let agent = agent(#"[{"id":"browser","name":"Browser"}]"#)
        var authenticateID: JSONValue?
        agent.handlers["authenticate"] = { id, _ in
            authenticateID = id
            agent.ask(7, "elicitation/create", ["mode": "url", "elicitationId": "e1", "url": "https://login.example.com/device?code=1", "message": "Open the page"])
        }
        let signIn = ACPAgentSignIn(transport: agent.factory)
        signIn.signIn(methodID: "browser", launch)
        await acpWaitUntil("the page is offered") { signIn.pendingURL != nil }
        #expect(signIn.pendingURL?.host == "login.example.com")
        #expect(signIn.message == "Open the page")
        // The agent waits for consent.
        try await Task.sleep(for: .milliseconds(30))
        #expect(agent.answers[7] == nil)
        signIn.acceptPendingURL()
        await acpWaitUntil("the agent hears consent") { agent.answers[7] != nil }
        #expect(agent.answers[7]?["result"]?["action"] == "accept")
        agent.reply(try #require(authenticateID), [:])
        await acpWaitUntil("sign-in ends") { signIn.phase == .succeeded }
    }

    @Test func pagesThatAreNotWebAddressesAreDeclined() async throws {
        let agent = agent(#"[{"id":"browser","name":"Browser"}]"#)
        agent.handlers["authenticate"] = { _, _ in
            agent.ask(8, "elicitation/create", ["mode": "url", "elicitationId": "e2", "url": "file:///etc/passwd", "message": "x"])
        }
        let signIn = ACPAgentSignIn(transport: agent.factory)
        signIn.signIn(methodID: "browser", launch)
        await acpWaitUntil("the agent is answered") { agent.answers[8] != nil }
        #expect(agent.answers[8]?["result"]?["action"] == "decline")
        #expect(signIn.pendingURL == nil)
        signIn.cancel()
        #expect(signIn.phase == .cancelled)
    }

    @Test func aMethodTheAgentNoLongerOffersFails() async throws {
        let agent = agent(#"[{"id":"browser","name":"Browser"}]"#)
        let signIn = ACPAgentSignIn(transport: agent.factory)
        signIn.signIn(methodID: "gone", launch)
        await acpWaitUntil("sign-in ends") { signIn.phase == .failed }
        #expect(agent.requests("authenticate").isEmpty)
    }

    @Test func signOutUsesTheAgentsLogout() async throws {
        let agent = agent(#"[{"id":"browser","name":"Browser"}]"#, canLogout: true)
        let signIn = ACPAgentSignIn(transport: agent.factory)
        signIn.signOut(launch)
        await acpWaitUntil("sign-out ends") { signIn.phase == .succeeded || signIn.phase == .failed }
        #expect(signIn.phase == .succeeded)
        #expect(agent.requests.map(\.method) == ["initialize", "logout"])

        let unsupported = self.agent(#"[{"id":"browser","name":"Browser"}]"#)
        let other = ACPAgentSignIn(transport: unsupported.factory)
        other.signOut(launch)
        await acpWaitUntil("sign-out ends") { other.phase == .failed }
        #expect(unsupported.requests("logout").isEmpty)
    }

    @Test func aTerminalMethodsCommandLeavesOutTheUsersOwnVariables() throws {
        let method = try #require(ACPAuthMethod(json: json(#"{"id":"login","name":"Login","type":"terminal","args":["auth","login","--note=it's"],"env":{"LOGIN":"yes please","bad name":"x"}}"#)))
        let command = ACPAgentSignIn.terminalCommand(method, launch)
        #expect(command == #"DEVIN_MODE=acp LOGIN='yes please' '/Applications/Devin Tools/devin' acp auth login '--note=it'\''s'"#)
        #expect(!command.contains("secret-key"))
    }
}

/// The registry lists the user's agents after the built-in ones, for as long as they are in settings.
@MainActor
struct ACPAgentRegistryTests {
    @Test func customAgentsFollowTheBuiltInProvidersInTheOrderTheyWereAdded() throws {
        let store = AppStore(directory: try acpTemporaryDirectory())
        let registry = ProviderRegistry(store: store, providers: [ProbedProvider(kind: .codex)], custom: { ProbedProvider(kind: .acp($0)) })
        #expect(registry.orderedKinds == [.codex])
        #expect(registry.provider(.acp("dsh")) == nil)

        store.updateSettings {
            $0.acpAgents = [localAgent, ACPAgentConfig(id: "goose", name: "goose", source: .local, command: "goose")]
        }
        #expect(registry.orderedKinds == [.codex, .acp("dsh"), .acp("goose")])
        #expect(registry.provider(.acp("dsh"))?.kind == .acp("dsh"))
        #expect(ProviderKind.acp("dsh").displayName == "DeepSeek Harness")

        store.updateSettings { $0.acpAgents.removeAll { $0.id == "dsh" } }
        registry.forget(.acp("dsh"))
        #expect(registry.orderedKinds == [.codex, .acp("goose")])
        #expect(registry.provider(.acp("dsh")) == nil)
    }

    @Test func textIsWrittenByAnotherReadyAgentThanAnAddedOne() async throws {
        let store = AppStore(directory: try acpTemporaryDirectory())
        store.updateSettings { $0.acpAgents = [localAgent] }
        let registry = ProviderRegistry(
            store: store, providers: [ProbedProvider(kind: .codex)], custom: { ProbedProvider(kind: .acp($0)) })
        await registry.refresh()
        let selection = ModelSelection(provider: .acp("dsh"), modelID: "default")
        #expect(registry.usableSelection(preferring: selection) == selection)
        #expect(registry.usableSelection(preferring: selection, writingText: true).provider == .codex)
    }

    @Test func theProviderOfALocalCommandLooksItUpOnPath() throws {
        let store = AppStore(directory: try acpTemporaryDirectory())
        store.updateSettings { $0.acpAgents = [localAgent] }
        let provider = ACPProvider(agent: "dsh", store: store)
        #expect(provider.kind == .acp("dsh"))
        #expect(provider.executableNames == ["dsh"])
        store.updateSettings { $0.acpAgents[0].command = "/opt/dsh/bin/dsh" }
        #expect(provider.executableNames == ["/opt/dsh/bin/dsh"])
        #expect(!provider.setupHint.isEmpty)
    }
}
