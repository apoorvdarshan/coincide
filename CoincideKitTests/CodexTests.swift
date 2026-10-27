import Foundation
import Testing

@testable import CoincideKit

// Fixtures are trimmed from `codex app-server` traffic recorded with codex-cli 0.164.0.

private func json(_ text: String) throws -> JSONValue {
    try #require(JSONValue.parse(text), "invalid JSON fixture: \(text)")
}

extension CodexEventMapper {
    /// Feeds JSON-RPC notifications (one per line) and collects the events they produce.
    fileprivate mutating func feed(_ lines: [String]) throws -> [AgentEvent] {
        var events: [AgentEvent] = []
        for line in lines {
            let message = try json(line)
            let method = try #require(message["method"]?.string)
            events += handle(method: method, params: message["params"] ?? .null)
        }
        return events
    }
}

private func mapper(turn: String? = "R1") -> CodexEventMapper {
    var mapper = CodexEventMapper(workingDirectory: "/work")
    mapper.threadID = "T"
    mapper.beginTurn()
    if let turn { mapper.adoptTurn(turn) }
    return mapper
}

private func selection(_ model: String = "gpt-6-luna", effort: String? = "low") -> ModelSelection {
    ModelSelection(provider: .codex, modelID: model, effort: effort)
}

// MARK: - Protocol

struct CodexProtocolTests {
    @Test func initializeDeclaresClientAndOptsOutOfAggregateDiffs() {
        let params = CodexProtocol.initializeParams(version: "1.2.3")
        #expect(params.at("clientInfo.name")?.string == "coincide")
        #expect(params.at("clientInfo.version")?.string == "1.2.3")
        #expect(params.at("capabilities.experimentalApi")?.bool == true)
        #expect(params.at("capabilities.optOutNotificationMethods")?.array == ["turn/diff/updated"])
    }

    @Test func threadStartAndResumeCarryWorkingDirectoryModelAndConfig() {
        let start = CodexProtocol.threadStartParams(cwd: "/work", model: "gpt-6-luna")
        #expect(start["cwd"] == "/work")
        #expect(start["model"] == "gpt-6-luna")
        #expect(start.at("config")?["tools.update_plan.enabled"] == true)
        #expect(start.at("config")?["mcp_optional_startup_grace_ms"]?.int == 10_000)

        let resume = CodexProtocol.threadResumeParams(threadID: "T", cwd: "/work", model: nil)
        #expect(resume["threadId"] == "T")
        #expect(resume["excludeTurns"] == true)
        #expect(resume["model"] == nil)
    }

    @Test func fullAccessBuildTurnNeverAsks() {
        let input = AgentTurnInput(text: "hi", selection: selection(), accessMode: .fullAccess, interactionMode: .build)
        let params = CodexProtocol.turnStartParams(threadID: "T", cwd: "/work", input: input, fallbackModel: nil)
        #expect(params["threadId"] == "T")
        #expect(params["cwd"] == "/work")
        #expect(params["model"] == "gpt-6-luna")
        #expect(params["effort"] == "low")
        #expect(params["summary"] == "detailed")
        #expect(params["approvalPolicy"] == "never")
        #expect(params["approvalsReviewer"] == "user")
        #expect(params["sandboxPolicy"] == ["type": "dangerFullAccess"])
        #expect(params.at("collaborationMode.mode") == "default")
        #expect(params.at("collaborationMode.settings.model") == "gpt-6-luna")
        #expect(params.at("collaborationMode.settings.reasoning_effort") == "low")
        #expect(params.at("collaborationMode.settings.developer_instructions")?.isNull == true)
        #expect(params["input"] == [["type": "text", "text": "hi", "text_elements": []]])
    }

    @Test func approvalPlanTurnUsesUntrustedReadOnlyAndPlanMode() {
        let input = AgentTurnInput(
            text: "plan it", imagePaths: ["/tmp/shot.png"], selection: selection(), accessMode: .approval,
            interactionMode: .plan)
        let params = CodexProtocol.turnStartParams(threadID: "T", cwd: "/work", input: input, fallbackModel: nil)
        #expect(params["approvalPolicy"] == "untrusted")
        #expect(params["sandboxPolicy"] == ["type": "readOnly"])
        #expect(params.at("collaborationMode.mode") == "plan")
        #expect(params["input"]?[1] == ["type": "localImage", "path": "/tmp/shot.png"])
    }

    @Test func missingEffortUsesT3OverrideOrCodexDefault() {
        let astra = AgentTurnInput(
            text: "x", selection: selection("gpt-6-astra", effort: nil), accessMode: .fullAccess, interactionMode: .build)
        #expect(CodexProtocol.turnStartParams(threadID: "T", cwd: "/w", input: astra, fallbackModel: nil)["effort"] == "medium")

        let luna = AgentTurnInput(
            text: "x", selection: selection("gpt-6-luna", effort: nil), accessMode: .fullAccess, interactionMode: .build)
        let params = CodexProtocol.turnStartParams(threadID: "T", cwd: "/w", input: luna, fallbackModel: nil)
        #expect(params["effort"] == nil)
        #expect(params.at("collaborationMode.settings.reasoning_effort")?.isNull == true)
    }

    @Test func defaultModelFallsBackToTheThreadModel() {
        let input = AgentTurnInput(
            text: "x", selection: selection("default", effort: nil), accessMode: .fullAccess, interactionMode: .plan)
        let params = CodexProtocol.turnStartParams(threadID: "T", cwd: "/w", input: input, fallbackModel: "gpt-6.1-sol")
        #expect(params["model"] == "gpt-6.1-sol")
        #expect(params.at("collaborationMode.settings.model") == "gpt-6.1-sol")
    }

    private func catalogEntry(
        _ model: String, _ name: String, efforts: [String], defaultEffort: String, isDefault: Bool = false,
        hidden: Bool = false, modalities: [String] = ["text", "image"]
    ) -> JSONValue {
        [
            "id": .string(model), "model": .string(model), "displayName": .string(name), "hidden": .bool(hidden),
            "supportedReasoningEfforts": .array(efforts.map { ["reasoningEffort": .string($0), "description": ""] }),
            "defaultReasoningEffort": .string(defaultEffort), "inputModalities": .array(modalities.map { .string($0) }),
            "isDefault": .bool(isDefault),
        ]
    }

    @Test func catalogPutsT3PreferredDefaultFirstAndDropsHiddenModels() {
        let all = ["low", "medium", "high", "xhigh", "max", "ultra"]
        let models = CodexProtocol.models(fromEntries: [
            catalogEntry("gpt-6.1-sol", "GPT-6.1-Sol", efforts: all, defaultEffort: "low", isDefault: true),
            catalogEntry("gpt-6-astra", "GPT-6-Astra", efforts: all, defaultEffort: "low"),
            catalogEntry("gpt-6-chat-thinking", "GPT-6 Chat Thinking", efforts: all, defaultEffort: "medium", hidden: true),
            catalogEntry("gpt-6-luna", "gpt-6-luna", efforts: ["low", "medium"], defaultEffort: "medium", modalities: ["text"]),
        ])
        #expect(models.map(\.modelID) == ["gpt-6-astra", "gpt-6.1-sol", "gpt-6-luna"])
        #expect(models[0].defaultEffort == "medium")
        #expect(models[0].efforts == all)
        #expect(models[1].defaultEffort == "low")
        #expect(models[2].displayName == "GPT-6-Luna")
        #expect(models[2].supportsImages == false)
        #expect(models.allSatisfy { $0.provider == .codex })
    }

    @Test func catalogWithoutPreferredModelsKeepsCodexDefaultFirst() {
        let models = CodexProtocol.models(fromEntries: [
            catalogEntry("gpt-6-luna", "GPT-6-Luna", efforts: ["low"], defaultEffort: "low"),
            catalogEntry("gpt-6.1-sol", "GPT-6.1-Sol", efforts: ["low"], defaultEffort: "low", isDefault: true),
        ])
        #expect(models.map(\.modelID) == ["gpt-6.1-sol", "gpt-6-luna"])
    }

    @Test func builtInModelsMirrorT3Defaults() {
        #expect(CodexProtocol.builtInModels.map(\.modelID) == ["gpt-6-astra", "gpt-6.1-sol", "gpt-6-luna"])
        #expect(CodexProtocol.builtInModels.allSatisfy { model in model.defaultEffort.map { model.efforts.contains($0) } == true })
    }

    @Test func displayNamesAreFormattedLikeT3() {
        #expect(CodexProtocol.displayName("gpt-6-luna") == "GPT-6-Luna")
        #expect(CodexProtocol.displayName("GPT-6.1 Terra") == "GPT-6.1 Terra")
        #expect(CodexProtocol.displayName("o3") == "o3")
    }

    @Test func signedInChatGPTAccountIsReady() throws {
        let response = try json(
            #"{"account":{"type":"chatgpt","email":"dev@example.com","planType":"pro"},"requiresOpenaiAuth":true,"workspaceRouting":null}"#)
        let status = CodexProtocol.providerStatus(
            account: response, version: "0.164.0", executable: URL(fileURLWithPath: "/opt/homebrew/bin/codex"))
        #expect(status.state == .ready)
        #expect(status.version == "0.164.0")
        #expect(status.account == "dev@example.com (ChatGPT Pro 200)")
        #expect(status.message == nil)
    }

    @Test func signedOutCodexNeedsLogin() throws {
        let response = try json(#"{"account":null,"requiresOpenaiAuth":true,"workspaceRouting":null}"#)
        let status = CodexProtocol.providerStatus(account: response, version: "0.164.0", executable: URL(fileURLWithPath: "/c"))
        #expect(status.state == .notAuthenticated)
        #expect(status.message?.contains("codex login") == true)
    }

    @Test func providerWithoutOpenAIAuthIsReady() throws {
        let response = try json(#"{"account":null,"requiresOpenaiAuth":false,"workspaceRouting":null}"#)
        #expect(CodexProtocol.providerStatus(account: response, version: nil, executable: URL(fileURLWithPath: "/c")).state == .ready)
        let apiKey = try json(#"{"account":{"type":"apiKey"},"requiresOpenaiAuth":true}"#)
        #expect(CodexProtocol.providerStatus(account: apiKey, version: nil, executable: URL(fileURLWithPath: "/c")).account == "OpenAI API key")
    }

    @Test func oldVersionsAreFlaggedUsingT3Ranges() throws {
        let response = try json(#"{"account":{"type":"apiKey"},"requiresOpenaiAuth":true}"#)
        let url = URL(fileURLWithPath: "/c")
        #expect(CodexProtocol.providerStatus(account: response, version: "0.140.2", executable: url).state == .error)
        let outdated = CodexProtocol.providerStatus(account: response, version: "0.150.0", executable: url)
        #expect(outdated.state == .ready)
        #expect(outdated.message?.contains("0.156") == true)
        #expect(CodexProtocol.versionCompatibility("0.164.0") == .supported)
    }

    @Test func versionsAreReadFromUserAgentAndVersionOutput() {
        #expect(
            CodexProtocol.version(fromUserAgent: "coincide/0.164.0 (Mac OS 27.0.1; arm64) herdr/0.9.5 (coincide; 0.1.0)")
                == "0.164.0")
        #expect(CodexProtocol.version(fromVersionOutput: "codex-cli 0.164.0\n") == "0.164.0")
    }

    @Test func archivedResumeErrorsAreRecognized() {
        #expect(CodexProtocol.isArchivedError("session 01a1 is archived; run `codex unarchive 01a1`"))
        #expect(!CodexProtocol.isArchivedError("no rollout found for thread id 01a1"))
    }
}

// MARK: - Presentation

struct CodexPresentationTests {
    let presentation = CodexPresentation(workingDirectory: "/work")

    @Test func shellWrappersAreRemovedForDisplay() {
        #expect(CodexPresentation.unwrapShell("/bin/zsh -lc 'echo coincide-ok'") == "echo coincide-ok")
        #expect(CodexPresentation.unwrapShell(#"/bin/zsh -lc "printf 'hi\\n' > hello.txt""#) == #"printf 'hi\n' > hello.txt"#)
        #expect(
            CodexPresentation.unwrapShell(
                #"/bin/zsh -lc "pwd && rg --files -g 'README.md' -g '"'!**/.git/**'"' . && git status""#)
                == "pwd && rg --files -g 'README.md' -g '!**/.git/**' . && git status")
        #expect(CodexPresentation.unwrapShell("bash -c 'a' 'b'") == "bash -c 'a' 'b'")
        #expect(CodexPresentation.unwrapShell("npm test") == "npm test")
    }

    @Test func commandsAreClassifiedByParsedActions() throws {
        let read = presentation.commandInfo(
            id: "c", command: "/bin/zsh -lc 'cat Package.swift'",
            actions: [try json(#"{"type":"read","command":"cat Package.swift","name":"Package.swift","path":"/work/Package.swift"}"#)])
        #expect(read == ToolCallInfo(id: "c", category: .read, title: "Read Package.swift", detail: "cat Package.swift"))

        let search = presentation.commandInfo(
            id: "c", command: "/bin/zsh -lc 'rg -n foo Sources'",
            actions: [try json(#"{"type":"search","command":"rg -n foo Sources","query":"foo","path":"/work/Sources"}"#)])
        #expect(search.category == .search)
        #expect(search.title == "Search for “foo” in Sources")

        let list = presentation.commandInfo(
            id: "c", command: "/bin/zsh -lc 'ls -la'", actions: [try json(#"{"type":"listFiles","command":"ls -la","path":null}"#)])
        #expect(list.category == .search)
        #expect(list.title == "List files")

        let mixed = presentation.commandInfo(
            id: "c", command: "/bin/zsh -lc 'cat a | tee b'",
            actions: [
                try json(#"{"type":"read","command":"cat a","name":"a","path":"a"}"#),
                try json(#"{"type":"unknown","command":"tee b"}"#),
            ])
        #expect(mixed == ToolCallInfo(id: "c", category: .command, title: "Run `cat a | tee b`", detail: "cat a | tee b"))
    }

    @Test func longCommandsAreShortenedInTitles() {
        #expect(CodexPresentation.shortened("line one\nline two") == "line one…")
        let long = String(repeating: "a", count: 100)
        #expect(CodexPresentation.shortened(long).count == 80)
        #expect(CodexPresentation.shortened(long).hasSuffix("…"))
    }

    @Test func pathsAreShownRelativeToTheWorkingDirectoryAndItsResolvedPath() {
        let tmp = CodexPresentation(workingDirectory: "/tmp/project/")
        #expect(tmp.relativePath("/tmp/project/a.swift") == "a.swift")
        #expect(tmp.relativePath("/private/tmp/project/b/c.swift") == "b/c.swift")
        #expect(tmp.relativePath("/etc/hosts") == "/etc/hosts")
    }

    @Test func fileChangesBecomeUnifiedDiffs() throws {
        let changes = [
            try json(#"{"path":"/work/hello.txt","kind":{"type":"add"},"diff":"hi\n"}"#),
            try json(#"{"path":"/work/notes.txt","kind":{"type":"update","move_path":null},"diff":"@@ -1,3 +1,3 @@\n one\n-two\n+2\n three\n"}"#),
            try json(#"{"path":"/work/old.txt","kind":{"type":"delete"},"diff":"gone"}"#),
        ]
        #expect(
            presentation.unifiedDiff(changes) == """
                --- /dev/null
                +++ b/hello.txt
                @@ -0,0 +1,1 @@
                +hi
                --- a/notes.txt
                +++ b/notes.txt
                @@ -1,3 +1,3 @@
                 one
                -two
                +2
                 three
                --- a/old.txt
                +++ /dev/null
                @@ -1,1 +0,0 @@
                -gone
                \\ No newline at end of file

                """)
        #expect(presentation.fileChangeTitle(changes) == "Edit 3 files")
        #expect(presentation.fileChangeTitle([changes[0]]) == "Create hello.txt")
        #expect(presentation.fileChangeTitle([changes[2]]) == "Delete old.txt")
        let move = try json(#"{"path":"/work/a.swift","kind":{"type":"update","move_path":"/work/b.swift"},"diff":"@@ -1 +1 @@\n-a\n+b\n"}"#)
        #expect(presentation.fileChangeTitle([move]) == "Move a.swift to b.swift")
        #expect(presentation.unifiedDiff([move])?.hasPrefix("--- a/a.swift\n+++ b/b.swift\n") == true)
    }

    @Test func todoListsBecomeChecklists() throws {
        let steps = try json(
            #"[{"step":"Read the code","status":"completed"},{"step":"Fix the bug","status":"inProgress"},{"step":"","status":"pending"}]"#)
        #expect(
            CodexPresentation.todoMarkdown(explanation: " Fixing the crash ", steps: steps.array ?? []) == """
                Fixing the crash

                - [x] Read the code
                - [ ] Fix the bug _(in progress)_
                - [ ] Step 3
                """)
    }

    @Test func exitMessagesKeepTheLastStderrLinesWithoutColors() {
        let message = CodexPresentation.exitMessage(
            status: 1, stderr: "one\ntwo\n\u{1B}[31mERROR\u{1B}[0m three\nfour\n")
        #expect(message == "Codex exited unexpectedly (status 1).\ntwo\nERROR three\nfour")
        #expect(CodexPresentation.exitMessage(status: 9, stderr: "") == "Codex exited unexpectedly (status 9).")
    }

    @Test func errorsPreferDetails() throws {
        #expect(CodexPresentation.errorMessage(try json(#"{"message":"Bad","additionalDetails":"Quota exceeded"}"#)) == "Quota exceeded")
        #expect(CodexPresentation.errorMessage(try json(#"{"message":"Bad","additionalDetails":null}"#)) == "Bad")
    }
}

// MARK: - Event mapping

struct CodexEventMapperTests {
    @Test func assistantTextStreamsThenSettlesWithUsage() throws {
        var mapper = mapper()
        let events = try mapper.feed([
            #"{"method":"item/started","params":{"item":{"type":"userMessage","id":"u1","clientId":null,"content":[{"type":"text","text":"Reply with exactly: pong","text_elements":[]}]},"threadId":"T","turnId":"R1","startedAtMs":1}}"#,
            #"{"method":"item/started","params":{"item":{"type":"agentMessage","id":"msg_1","text":"","phase":"final_answer","memoryCitation":null,"delivery":null,"questions":null},"threadId":"T","turnId":"R1","startedAtMs":2}}"#,
            #"{"method":"item/agentMessage/delta","params":{"threadId":"T","turnId":"R1","itemId":"msg_1","delta":"po"}}"#,
            #"{"method":"item/agentMessage/delta","params":{"threadId":"T","turnId":"R1","itemId":"msg_1","delta":"ng"}}"#,
            #"{"method":"item/completed","params":{"item":{"type":"agentMessage","id":"msg_1","text":"pong","phase":"final_answer","memoryCitation":null,"delivery":null,"questions":null},"threadId":"T","turnId":"R1","completedAtMs":3}}"#,
            #"{"method":"thread/tokenUsage/updated","params":{"threadId":"T","turnId":"R1","tokenUsage":{"total":{"totalTokens":63112,"inputTokens":63038,"cachedInputTokens":31360,"cacheWriteInputTokens":0,"outputTokens":74,"reasoningOutputTokens":0},"last":{"totalTokens":31590,"inputTokens":31550,"cachedInputTokens":31360,"cacheWriteInputTokens":0,"outputTokens":40,"reasoningOutputTokens":0},"modelContextWindow":258400}}}"#,
        ])
        #expect(
            events == [
                .assistantTextDelta(itemID: "msg_1", delta: "po"),
                .assistantTextDelta(itemID: "msg_1", delta: "ng"),
                .assistantText(itemID: "msg_1", text: "pong"),
                .usage(TokenUsage(inputTokens: 31590, outputTokens: 40, cachedInputTokens: 31360, contextWindow: 258400)),
            ])
    }

    @Test func commandsStreamOutputAndReportExitStatus() throws {
        var mapper = mapper()
        let events = try mapper.feed([
            #"{"method":"item/started","params":{"item":{"type":"commandExecution","id":"exec-1","pluginId":null,"scriptPath":null,"command":"/bin/zsh -lc 'echo coincide-ok'","cwd":"/work","processId":null,"source":"agent","status":"inProgress","commandActions":[{"type":"unknown","command":"echo coincide-ok"}],"aggregatedOutput":null,"exitCode":null,"durationMs":null},"threadId":"T","turnId":"R1","startedAtMs":1}}"#,
            #"{"method":"item/commandExecution/outputDelta","params":{"threadId":"T","turnId":"R1","itemId":"exec-1","delta":"coincide-ok\n"}}"#,
            #"{"method":"item/completed","params":{"item":{"type":"commandExecution","id":"exec-1","pluginId":null,"scriptPath":null,"command":"/bin/zsh -lc 'echo coincide-ok'","cwd":"/work","processId":"31057","source":"unifiedExecStartup","status":"completed","commandActions":[{"type":"unknown","command":"echo coincide-ok"}],"aggregatedOutput":"coincide-ok\n","exitCode":0,"durationMs":0},"threadId":"T","turnId":"R1","completedAtMs":2}}"#,
            #"{"method":"item/completed","params":{"item":{"type":"commandExecution","id":"exec-2","pluginId":null,"scriptPath":null,"command":"/bin/zsh -lc \"pwd && rg --files -g 'README.md' . && git status --short --branch\"","cwd":"/work","processId":"4656","source":"unifiedExecStartup","status":"failed","commandActions":[{"type":"unknown","command":"pwd && rg --files -g 'README.md' . && git status --short --branch"}],"aggregatedOutput":"/work\n","exitCode":1,"durationMs":0},"threadId":"T","turnId":"R1","completedAtMs":3}}"#,
        ])
        #expect(
            events == [
                .toolStarted(
                    ToolCallInfo(id: "exec-1", category: .command, title: "Run `echo coincide-ok`", detail: "echo coincide-ok")),
                .toolOutput(id: "exec-1", delta: "coincide-ok\n"),
                .toolCompleted(id: "exec-1", status: .completed, output: "coincide-ok\n"),
                .toolStarted(
                    ToolCallInfo(
                        id: "exec-2", category: .command,
                        title: "Run `pwd && rg --files -g 'README.md' . && git status --short --branch`",
                        detail: "pwd && rg --files -g 'README.md' . && git status --short --branch")),
                .toolCompleted(id: "exec-2", status: .failed, output: "/work\nExit code 1"),
            ])
    }

    @Test func declinedCommandsAreMarkedDeclined() throws {
        var mapper = mapper()
        let events = try mapper.feed([
            #"{"method":"item/completed","params":{"item":{"type":"commandExecution","id":"exec-3","command":"rm -rf build","cwd":"/work","processId":null,"source":"agent","status":"declined","commandActions":[],"aggregatedOutput":null,"exitCode":null,"durationMs":null},"threadId":"T","turnId":"R1","completedAtMs":1}}"#
        ])
        #expect(events.last == .toolCompleted(id: "exec-3", status: .declined, output: nil))
    }

    @Test func fileChangesShowDiffsAndPatchUpdates() throws {
        var mapper = mapper()
        let events = try mapper.feed([
            #"{"method":"item/started","params":{"item":{"type":"fileChange","id":"fc-1","changes":[{"path":"/work/hello.txt","kind":{"type":"add"},"diff":"h"}],"status":"inProgress"},"threadId":"T","turnId":"R1","startedAtMs":1}}"#,
            #"{"method":"item/fileChange/patchUpdated","params":{"threadId":"T","turnId":"R1","itemId":"fc-1","changes":[{"path":"/work/hello.txt","kind":{"type":"add"},"diff":"hi\n"}]}}"#,
            #"{"method":"item/completed","params":{"item":{"type":"fileChange","id":"fc-1","changes":[{"path":"/work/hello.txt","kind":{"type":"add"},"diff":"hi\n"}],"status":"completed"},"threadId":"T","turnId":"R1","completedAtMs":2}}"#,
        ])
        let final = ToolCallInfo(
            id: "fc-1", category: .fileChange, title: "Create hello.txt",
            detail: "--- /dev/null\n+++ b/hello.txt\n@@ -0,0 +1,1 @@\n+hi\n")
        #expect(events.count == 3)
        if case .toolStarted(let info) = events[0] {
            #expect(info.detail?.contains("\\ No newline at end of file") == true)
        } else {
            Issue.record("expected toolStarted, got \(events[0])")
        }
        #expect(events[1] == .toolUpdated(final))
        #expect(events[2] == .toolCompleted(id: "fc-1", status: .completed, output: nil))
        #expect(mapper.fileChanges(for: "fc-1")?.count == 1)
    }

    @Test func reasoningPartsBecomeSeparateEntries() throws {
        var mapper = mapper()
        let events = try mapper.feed([
            #"{"method":"item/started","params":{"item":{"type":"reasoning","id":"rs_1","summary":[],"content":[]},"threadId":"T","turnId":"R1","startedAtMs":1}}"#,
            #"{"method":"item/reasoning/summaryTextDelta","params":{"threadId":"T","turnId":"R1","itemId":"rs_1","delta":"**Plan**","summaryIndex":0}}"#,
            #"{"method":"item/reasoning/summaryPartAdded","params":{"threadId":"T","turnId":"R1","itemId":"rs_1","summaryIndex":1}}"#,
            #"{"method":"item/reasoning/summaryTextDelta","params":{"threadId":"T","turnId":"R1","itemId":"rs_1","delta":"Next","summaryIndex":1}}"#,
            #"{"method":"item/completed","params":{"item":{"type":"reasoning","id":"rs_1","summary":["**Plan** first","Next step"],"content":[]},"threadId":"T","turnId":"R1","completedAtMs":2}}"#,
        ])
        #expect(
            events == [
                .reasoningDelta(itemID: "rs_1#summary0", delta: "**Plan**"),
                .reasoningDelta(itemID: "rs_1#summary1", delta: "Next"),
                .reasoningText(itemID: "rs_1#summary0", text: "**Plan** first"),
                .reasoningText(itemID: "rs_1#summary1", text: "Next step"),
            ])
    }

    @Test func proposedPlanStreamsAndCombinesWithTheTodoList() throws {
        var mapper = mapper()
        let events = try mapper.feed([
            #"{"method":"turn/plan/updated","params":{"threadId":"T","turnId":"R1","explanation":null,"plan":[{"step":"Explore","status":"completed"}]}}"#,
            #"{"method":"item/started","params":{"item":{"type":"plan","id":"R1-plan","text":""},"threadId":"T","turnId":"R1","startedAtMs":1}}"#,
            ###"{"method":"item/plan/delta","params":{"threadId":"T","turnId":"R1","itemId":"R1-plan","delta":"## Add"}}"###,
            ###"{"method":"item/completed","params":{"item":{"type":"plan","id":"R1-plan","text":"## Add a README\n\n1. Create `README.md`.\n"},"threadId":"T","turnId":"R1","completedAtMs":2}}"###,
        ])
        #expect(
            events == [
                .plan(text: "- [x] Explore"),
                .plan(text: "## Add\n\n- [x] Explore"),
                .plan(text: "## Add a README\n\n1. Create `README.md`.\n\n- [x] Explore"),
            ])
    }

    @Test func emptyPlansAreNotShown() throws {
        var mapper = mapper()
        let events = try mapper.feed([
            #"{"method":"turn/plan/updated","params":{"threadId":"T","turnId":"R1","explanation":" ","plan":[]}}"#,
            #"{"method":"item/completed","params":{"item":{"type":"plan","id":"R1-plan","text":""},"threadId":"T","turnId":"R1","completedAtMs":1}}"#,
        ])
        #expect(events.isEmpty)
    }

    @Test func mcpCallsShowArgumentsProgressAndResults() throws {
        var mapper = mapper()
        let events = try mapper.feed([
            #"{"method":"item/started","params":{"item":{"type":"mcpToolCall","id":"mcp-1","server":"browser","tool":"open","status":"inProgress","arguments":{"url":"https://example.com"},"appContext":null,"mcpAppUi":null,"pluginId":null,"readOnlyHint":null,"result":null,"error":null,"durationMs":null},"threadId":"T","turnId":"R1","startedAtMs":1}}"#,
            #"{"method":"item/mcpToolCall/progress","params":{"threadId":"T","turnId":"R1","itemId":"mcp-1","message":"Loading"}}"#,
            #"{"method":"item/completed","params":{"item":{"type":"mcpToolCall","id":"mcp-1","server":"browser","tool":"open","status":"completed","arguments":{"url":"https://example.com"},"appContext":null,"mcpAppUi":null,"pluginId":null,"readOnlyHint":null,"result":{"content":[{"type":"text","text":"Opened"}],"structuredContent":null,"_meta":null},"error":null,"durationMs":5},"threadId":"T","turnId":"R1","completedAtMs":2}}"#,
            #"{"method":"item/completed","params":{"item":{"type":"mcpToolCall","id":"mcp-2","server":"mail","tool":"send","status":"failed","arguments":{},"appContext":null,"mcpAppUi":null,"pluginId":null,"readOnlyHint":null,"result":null,"error":{"message":"Not allowed"},"durationMs":5},"threadId":"T","turnId":"R1","completedAtMs":3}}"#,
        ])
        #expect(
            events == [
                .toolStarted(
                    ToolCallInfo(
                        id: "mcp-1", category: .mcp, title: "browser: open",
                        detail: "{\n  \"url\" : \"https://example.com\"\n}")),
                .toolOutput(id: "mcp-1", delta: "Loading\n"),
                .toolCompleted(id: "mcp-1", status: .completed, output: "Opened"),
                .toolStarted(ToolCallInfo(id: "mcp-2", category: .mcp, title: "mail: send")),
                .toolCompleted(id: "mcp-2", status: .failed, output: "Not allowed"),
            ])
    }

    @Test func webSearchesGetTheirQueryOnCompletion() throws {
        var mapper = mapper()
        let events = try mapper.feed([
            #"{"method":"item/started","params":{"item":{"type":"webSearch","id":"ws-1","query":"","action":null,"results":null},"threadId":"T","turnId":"R1","startedAtMs":1}}"#,
            #"{"method":"item/completed","params":{"item":{"type":"webSearch","id":"ws-1","query":"swift testing","action":{"type":"search","query":"swift testing","queries":["swift testing"]},"results":[{"title":"Swift Testing","url":"https://developer.apple.com/xcode/swift-testing/"}]},"threadId":"T","turnId":"R1","completedAtMs":2}}"#,
        ])
        #expect(
            events == [
                .toolStarted(ToolCallInfo(id: "ws-1", category: .web, title: "Search the web")),
                .toolUpdated(ToolCallInfo(id: "ws-1", category: .web, title: "Search the web for “swift testing”")),
                .toolCompleted(id: "ws-1", status: .completed, output: "Swift Testing — https://developer.apple.com/xcode/swift-testing/"),
            ])
    }

    @Test func subagentCallsAreTasks() throws {
        var mapper = mapper()
        let events = try mapper.feed([
            #"{"method":"item/started","params":{"item":{"type":"collabAgentToolCall","id":"c-1","tool":"spawnAgent","status":"inProgress","senderThreadId":"T","receiverThreadIds":[],"prompt":"Check the tests","model":null,"reasoningEffort":null,"agentsStates":{}},"threadId":"T","turnId":"R1","startedAtMs":1}}"#,
            #"{"method":"item/completed","params":{"item":{"type":"collabAgentToolCall","id":"c-1","tool":"spawnAgent","status":"completed","senderThreadId":"T","receiverThreadIds":["T2"],"prompt":"Check the tests","model":null,"reasoningEffort":null,"agentsStates":{"T2":{"status":"completed","message":"All tests pass"}}},"threadId":"T","turnId":"R1","completedAtMs":2}}"#,
            #"{"method":"item/started","params":{"item":{"type":"agentMessage","id":"child","text":"","phase":null,"memoryCitation":null,"delivery":null,"questions":null},"threadId":"T2","turnId":"C1","startedAtMs":3}}"#,
        ])
        #expect(
            events == [
                .toolStarted(ToolCallInfo(id: "c-1", category: .task, title: "Start a subagent", detail: "Check the tests")),
                .toolCompleted(id: "c-1", status: .completed, output: "All tests pass"),
            ])
    }

    @Test func otherThreadsAndUnknownTurnsAreIgnored() throws {
        var mapper = mapper()
        let events = try mapper.feed([
            #"{"method":"item/agentMessage/delta","params":{"threadId":"OTHER","turnId":"R1","itemId":"m","delta":"x"}}"#,
            #"{"method":"item/agentMessage/delta","params":{"threadId":"T","turnId":"R9","itemId":"m","delta":"x"}}"#,
            #"{"method":"warning","params":{"threadId":"OTHER","message":"not ours"}}"#,
        ])
        #expect(events.isEmpty)
    }

    @Test func aNewTurnIsAdoptedFromItsFirstNotification() throws {
        var mapper = mapper(turn: nil)
        let events = try mapper.feed([
            #"{"method":"item/agentMessage/delta","params":{"threadId":"T","turnId":"R2","itemId":"m","delta":"hi"}}"#
        ])
        #expect(events == [.assistantTextDelta(itemID: "m", delta: "hi")])
        #expect(mapper.turnID == "R2")
    }

    @Test func lateEventsOfThePreviousTurnOnlyFinishItsTools() throws {
        var mapper = mapper()
        mapper.beginTurn()
        mapper.adoptTurn("R2")
        let events = try mapper.feed([
            #"{"method":"item/commandExecution/outputDelta","params":{"threadId":"T","turnId":"R1","itemId":"bg","delta":"tick\n"}}"#,
            #"{"method":"item/completed","params":{"item":{"type":"commandExecution","id":"bg","command":"sleep 5","cwd":"/work","status":"completed","commandActions":[],"aggregatedOutput":"tick\n","exitCode":0},"threadId":"T","turnId":"R1","completedAtMs":2}}"#,
            #"{"method":"item/started","params":{"item":{"type":"agentMessage","id":"m","text":"late"},"threadId":"T","turnId":"R1","startedAtMs":3}}"#,
        ])
        #expect(
            events == [
                .toolOutput(id: "bg", delta: "tick\n"),
                .toolCompleted(id: "bg", status: .completed, output: "tick\n"),
            ])
    }

    @Test func compactionReroutesAndWarningsBecomeNotices() throws {
        var mapper = mapper()
        let events = try mapper.feed([
            #"{"method":"item/completed","params":{"item":{"type":"contextCompaction","id":"cc"},"threadId":"T","turnId":"R1","completedAtMs":1}}"#,
            #"{"method":"model/rerouted","params":{"threadId":"T","turnId":"R1","fromModel":"gpt-6-astra","toModel":"gpt-6-luna","reason":"highRiskCyberActivity"}}"#,
            #"{"method":"warning","params":{"threadId":"T","message":"Skills budget exceeded"}}"#,
        ])
        #expect(
            events == [
                .notice("Context compacted"),
                .modelResolved("gpt-6-luna"),
                .notice("Codex switched from gpt-6-astra to gpt-6-luna."),
                .notice("Skills budget exceeded"),
            ])
    }
}

// MARK: - Server requests

struct CodexServerRequestTests {
    let presentation = CodexPresentation(workingDirectory: "/work")

    private func approval(_ action: CodexServerRequestAction) throws -> CodexApproval {
        guard case .approval(let approval) = action else {
            Issue.record("expected an approval, got \(action)")
            throw CancellationError()
        }
        return approval
    }

    @Test func commandApprovalOffersCodexDecisions() throws {
        let params = try json(
            #"{"kind":"command","threadId":"T","turnId":"R1","itemId":"exec-1","startedAtMs":1,"environmentId":"local","command":"/bin/zsh -lc 'echo coincide-ok'","cwd":"/work","commandActions":[{"type":"unknown","command":"echo coincide-ok"}],"proposedExecpolicyAmendment":["echo","coincide-ok"],"availableDecisions":["accept",{"acceptWithExecpolicyAmendment":{"execpolicy_amendment":["echo","coincide-ok"]}},"cancel"]}"#)
        let approval = try approval(
            CodexServerRequests.action(
                method: "item/commandExecution/requestApproval", params: params, approvalID: "a1", presentation: presentation,
                fileChanges: nil))
        #expect(approval.request.id == "a1")
        #expect(approval.request.category == .command)
        #expect(approval.request.title == "Run `echo coincide-ok`")
        #expect(approval.request.detail == "echo coincide-ok")
        #expect(approval.request.toolCallID == "exec-1")
        #expect(approval.request.options.map(\.kind) == [.allowOnce, .allowAlways, .cancel])
        #expect(approval.request.options[1].label == "Always allow `echo coincide-ok`")
        #expect(approval.responses["accept"] == ["decision": "accept"])
        #expect(
            approval.responses["acceptWithExecpolicyAmendment"]
                == ["decision": ["acceptWithExecpolicyAmendment": ["execpolicy_amendment": ["echo", "coincide-ok"]]]])
        #expect(approval.cancelResponse == ["decision": "cancel"])
    }

    @Test func commandApprovalWithoutDecisionsUsesTheStandardSet() throws {
        let params = try json(
            #"{"kind":"command","threadId":"T","turnId":"R1","itemId":"exec-1","command":"npm install","reason":"Needs network access","networkApprovalContext":{"host":"registry.npmjs.org","protocol":"https"}}"#)
        let approval = try approval(
            CodexServerRequests.action(
                method: "item/commandExecution/requestApproval", params: params, approvalID: "a2", presentation: presentation,
                fileChanges: nil))
        #expect(approval.request.title == "Allow network access to registry.npmjs.org")
        #expect(approval.request.detail == "npm install\n\nNeeds network access")
        #expect(approval.request.options.map(\.id) == ["accept", "acceptForSession", "decline", "cancel"])
        #expect(approval.responses["decline"] == ["decision": "decline"])
    }

    @Test func networkAmendmentsAreOffered() throws {
        let decision = try json(
            #"{"applyNetworkPolicyAmendment":{"network_policy_amendment":{"host":"example.com","action":"deny"}}}"#)
        let option = try #require(CodexServerRequests.commandOption(decision, index: 2))
        #expect(option == ApprovalOption(id: "network-2", label: "Always block example.com", kind: .deny))
    }

    @Test func fileChangeApprovalShowsTheRecordedDiff() throws {
        let params = try json(
            #"{"threadId":"T","turnId":"R1","itemId":"fc-1","startedAtMs":1,"reason":null,"grantRoot":null}"#)
        let changes = [try json(#"{"path":"/work/hello.txt","kind":{"type":"add"},"diff":"hi\n"}"#)]
        let approval = try approval(
            CodexServerRequests.action(
                method: "item/fileChange/requestApproval", params: params, approvalID: "a3", presentation: presentation,
                fileChanges: changes))
        #expect(approval.request.title == "Create hello.txt")
        #expect(approval.request.detail == "--- /dev/null\n+++ b/hello.txt\n@@ -0,0 +1,1 @@\n+hi")
        #expect(approval.request.options.map(\.kind) == [.allowOnce, .allowAlways, .deny, .cancel])
        #expect(approval.responses["acceptForSession"] == ["decision": "acceptForSession"])
    }

    @Test func permissionRequestsGrantForTheTurnOrSession() throws {
        let params = try json(
            #"{"threadId":"T","turnId":"R1","itemId":"p-1","environmentId":null,"startedAtMs":1,"cwd":"/work","reason":"Write build output","permissions":{"network":null,"fileSystem":{"read":null,"write":["/work/build"]}}}"#)
        let approval = try approval(
            CodexServerRequests.action(
                method: "item/permissions/requestApproval", params: params, approvalID: "a4", presentation: presentation,
                fileChanges: nil))
        #expect(approval.request.title == "Allow writing to build")
        #expect(approval.request.category == .fileChange)
        #expect(approval.responses["session"] == ["permissions": ["fileSystem": ["read": nil, "write": ["/work/build"]]], "scope": "session"])
        #expect(approval.responses["deny"] == ["permissions": [:], "scope": "turn"])
    }

    @Test func legacyApprovalsAnswerWithReviewDecisions() throws {
        let params = try json(
            #"{"conversationId":"T","callId":"call-1","approvalId":null,"command":["/bin/zsh","-lc","make test"],"cwd":"/work","reason":null,"parsedCmd":[]}"#)
        let approval = try approval(
            CodexServerRequests.action(
                method: "execCommandApproval", params: params, approvalID: "a5", presentation: presentation, fileChanges: nil))
        #expect(approval.request.title == "Run `make test`")
        #expect(approval.responses["approved_for_session"] == ["decision": "approved_for_session"])
        #expect(approval.responses["denied"] == ["decision": ["denied": ["rejection": "The user declined the request."]]])
        #expect(approval.cancelResponse == ["decision": "abort"])
    }

    @Test func multipleChoiceQuestionsBecomeApprovals() throws {
        let params = try json(
            #"{"threadId":"T","turnId":"R1","itemId":"q","isBlocking":true,"autoResolutionMs":null,"questions":[{"id":"stack","header":"Stack","question":"Which framework?","isOther":true,"isSecret":false,"options":[{"label":"SwiftUI","description":"Declarative"},{"label":"AppKit","description":""}]},{"id":"name","header":"Name","question":"What should it be called?","isOther":false,"isSecret":false,"options":null}]}"#)
        let action = CodexServerRequests.action(
            method: "item/tool/requestUserInput", params: params, approvalID: "a6", presentation: presentation, fileChanges: nil)
        guard case .questions(let questions, let answered, let notices) = action else {
            Issue.record("expected questions, got \(action)")
            return
        }
        #expect(questions.count == 1)
        let question = try #require(questions.first)
        #expect(question.questionID == "stack")
        #expect(question.request.id == "a6/0")
        #expect(question.request.title == "Stack")
        #expect(question.request.detail == "Which framework?\n\nSwiftUI: Declarative")
        #expect(question.request.options.map(\.label) == ["SwiftUI", "AppKit", "Skip"])
        #expect(question.responses["option-1"] == ["answers": ["AppKit"]])
        #expect(question.cancelResponse == ["answers": []])
        #expect(answered == ["name": ["answers": []]])
        #expect(notices == ["Codex asked: What should it be called?"])
    }

    @Test func freeTextQuestionsAreAnsweredEmpty() throws {
        let params = try json(
            #"{"threadId":"T","turnId":"R1","itemId":"q","isBlocking":true,"questions":[{"id":"name","header":"","question":"Name?","isOther":false,"isSecret":false,"options":[]}]}"#)
        let action = CodexServerRequests.action(
            method: "item/tool/requestUserInput", params: params, approvalID: "a7", presentation: presentation, fileChanges: nil)
        guard case .questions(let questions, let answered, let notices) = action else {
            Issue.record("expected questions, got \(action)")
            return
        }
        #expect(questions.isEmpty)
        #expect(answered == ["name": ["answers": []]])
        #expect(notices == ["Codex asked: Name?"])
    }

    @Test func approveStyleElicitationsCanBeAnswered() throws {
        let params = try json(
            #"{"threadId":"T","turnId":"R1","serverName":"codex_apps","mode":"form","_meta":{"persist":["session","always"]},"message":"Allow ChatGPT to use Gmail?","requestedSchema":{"type":"object","properties":{},"required":[]}}"#)
        let approval = try approval(
            CodexServerRequests.action(
                method: "mcpServer/elicitation/request", params: params, approvalID: "a8", presentation: presentation,
                fileChanges: nil))
        #expect(approval.request.title == "Allow ChatGPT to use Gmail?")
        #expect(approval.request.options.map(\.id) == ["accept", "session", "always", "decline", "cancel"])
        #expect(approval.responses["accept"] == ["action": "accept", "content": [:], "_meta": nil])
        #expect(approval.responses["session"] == ["action": "accept", "content": [:], "_meta": ["persist": "session"]])
    }

    @Test func elicitationFormsFillApproveChoicesAndDeclineTheRest() throws {
        let form = try json(
            #"{"threadId":"T","turnId":"R1","serverName":"s","mode":"form","_meta":null,"message":"Run tool?","requestedSchema":{"type":"object","properties":{"decision":{"type":"string","enum":["approve_once","approve_session","deny"]}},"required":["decision"]}}"#)
        #expect(CodexServerRequests.elicitationResponse(form, persist: nil)?.at("content.decision") == "approve_once")
        #expect(CodexServerRequests.elicitationResponse(form, persist: "session")?.at("content.decision") == "approve_session")
        #expect(CodexServerRequests.elicitationPersistence(form) == ["session"])

        let url = try json(
            #"{"threadId":"T","turnId":null,"serverName":"s","mode":"url","_meta":null,"message":"Sign in","url":"https://example.com","elicitationId":"e"}"#)
        guard case .respond(let result) = CodexServerRequests.action(
            method: "mcpServer/elicitation/request", params: url, approvalID: "a9", presentation: presentation, fileChanges: nil)
        else {
            Issue.record("expected a decline")
            return
        }
        #expect(result["action"] == "decline")
    }

    @Test func toolCallsTimeAndUnknownRequestsAreAnsweredDirectly() throws {
        let tool = CodexServerRequests.action(
            method: "item/tool/call", params: [:], approvalID: "x", presentation: presentation, fileChanges: nil)
        guard case .respond(let toolResult) = tool else {
            Issue.record("expected a tool result")
            return
        }
        #expect(toolResult["success"] == false)

        let time = CodexServerRequests.action(
            method: "currentTime/read", params: ["threadId": "T"], approvalID: "x", presentation: presentation, fileChanges: nil)
        guard case .respond(let timeResult) = time else {
            Issue.record("expected the time")
            return
        }
        #expect((timeResult["currentTimeAt"]?.number ?? 0) > 1_700_000_000)

        guard case .reject = CodexServerRequests.action(
            method: "account/chatgptAuthTokens/refresh", params: [:], approvalID: "x", presentation: presentation,
            fileChanges: nil)
        else {
            Issue.record("expected a rejection")
            return
        }
    }
}

// MARK: - Session

/// An in-memory app server: answers requests by method and lets tests push notifications.
@MainActor
final class FakeCodexTransport: CodexTransport {
    enum Reply {
        case result(JSONValue)
        case error(String)
        case silent
    }

    var onLine: ((String) -> Void)?
    var onExit: ((Int32, String) -> Void)?
    private(set) var sent: [JSONValue] = []
    private(set) var isClosed = false
    var handlers: [String: (JSONValue) -> Reply] = [:]
    var queued: [String: [Reply]] = [:]

    init() {
        handlers["initialize"] = { _ in
            .result([
                "userAgent": "coincide/0.164.0 (Mac OS 27.0.1; arm64)", "codexHome": "/Users/me/.codex",
                "platformFamily": "unix", "platformOs": "macos",
            ])
        }
        handlers["thread/start"] = { _ in .result(["thread": ["id": "T"], "model": "gpt-6-luna"]) }
        handlers["thread/resume"] = { params in .result(["thread": ["id": params["threadId"] ?? "T"], "model": "gpt-6-luna"]) }
        handlers["turn/start"] = { _ in .result(["turn": ["id": "R1", "status": "inProgress", "startedAt": nil, "items": []]]) }
        handlers["turn/interrupt"] = { _ in .result([:]) }
    }

    func start() throws {}

    func send(_ line: String) {
        guard let message = JSONValue.parse(line) else { return }
        sent.append(message)
        guard let id = message["id"], let method = message["method"]?.string else { return }
        let reply: Reply
        if var queue = queued[method], !queue.isEmpty {
            reply = queue.removeFirst()
            queued[method] = queue
        } else {
            reply = handlers[method]?(message["params"] ?? .null) ?? .silent
        }
        let response: JSONValue
        switch reply {
        case .result(let result): response = ["id": id, "result": result]
        case .error(let text): response = ["id": id, "error": ["code": -32600, "message": .string(text)]]
        case .silent: return
        }
        Task { @MainActor [weak self] in self?.deliver(response) }
    }

    func close() {
        isClosed = true
    }

    func deliver(_ message: JSONValue) {
        onLine?(message.compactJSON)
    }

    func notify(_ method: String, _ params: JSONValue) {
        deliver(["method": .string(method), "params": params])
    }

    func request(id: Int, _ method: String, _ params: JSONValue) {
        deliver(["id": .number(Double(id)), "method": .string(method), "params": params])
    }

    func crash(status: Int32, stderr: String) {
        onExit?(status, stderr)
    }

    func requests(_ method: String) -> [JSONValue] {
        sent.filter { $0["method"]?.string == method && $0["id"] != nil }
    }

    /// Responses Coincide sent to server requests, by id.
    func responses(to id: Int) -> [JSONValue] {
        sent.filter { $0["id"]?.int == id && $0["method"] == nil }
    }
}

@MainActor
private final class EventLog {
    var events: [AgentEvent] = []

    var completions: [TurnOutcome] {
        events.compactMap { event -> TurnOutcome? in
            guard case .turnCompleted(let outcome) = event else { return nil }
            return outcome
        }
    }

    var approvals: [ApprovalRequest] {
        events.compactMap { event -> ApprovalRequest? in
            guard case .approvalRequested(let request) = event else { return nil }
            return request
        }
    }
}

private struct TimedOut: Error {}

@MainActor
private func waitUntil(_ timeout: Duration = .seconds(2), _ condition: () -> Bool) async throws {
    let deadline = ContinuousClock.now + timeout
    while !condition() {
        guard ContinuousClock.now < deadline else { throw TimedOut() }
        try await Task.sleep(for: .milliseconds(5))
    }
}

@MainActor
struct CodexSessionTests {
    private func launch(resume: String?) -> AgentLaunch {
        AgentLaunch(
            provider: .codex, executable: URL(fileURLWithPath: "/usr/bin/false"), environment: [:],
            workingDirectory: URL(fileURLWithPath: "/work"), resumeSessionID: resume, selection: selection(),
            accessMode: .fullAccess, interactionMode: .build)
    }

    private func makeSession(
        resume: String? = nil, grace: Duration = .seconds(5), transports: [FakeCodexTransport] = [FakeCodexTransport()]
    ) -> (CodexSession, EventLog) {
        var remaining = transports
        let session = CodexSession(launch: launch(resume: resume), interruptGracePeriod: grace) { _ in
            remaining.isEmpty ? FakeCodexTransport() : remaining.removeFirst()
        }
        let log = EventLog()
        session.onEvent = { log.events.append($0) }
        return (session, log)
    }

    private func input(
        _ text: String = "hi", model: String = "gpt-6-luna", effort: String? = "low", access: AccessMode = .fullAccess,
        mode: InteractionMode = .build
    ) -> AgentTurnInput {
        AgentTurnInput(text: text, selection: selection(model, effort: effort), accessMode: access, interactionMode: mode)
    }

    @Test func startInitializesAndStartsAThread() async throws {
        let transport = FakeCodexTransport()
        let (session, log) = makeSession(transports: [transport])
        try await session.start()
        #expect(transport.sent.map { $0["method"]?.string } == ["initialize", "initialized", "thread/start"])
        #expect(transport.requests("thread/start").first?.at("params.cwd") == "/work")
        #expect(transport.requests("thread/start").first?.at("params.model") == "gpt-6-luna")
        #expect(session.sessionID == "T")
        #expect(log.events == [.sessionStarted(id: "T"), .modelResolved("gpt-6-luna")])
    }

    @Test func startResumesTheSavedThread() async throws {
        let transport = FakeCodexTransport()
        let (session, log) = makeSession(resume: "OLD", transports: [transport])
        try await session.start()
        let resume = try #require(transport.requests("thread/resume").first)
        #expect(resume.at("params.threadId") == "OLD")
        #expect(resume.at("params.excludeTurns") == true)
        #expect(transport.requests("thread/start").isEmpty)
        #expect(log.events.first == .sessionStarted(id: "OLD"))
    }

    @Test func failedResumeStartsAFreshThread() async throws {
        let transport = FakeCodexTransport()
        transport.queued["thread/resume"] = [.error("no rollout found for thread id OLD")]
        let (session, log) = makeSession(resume: "OLD", transports: [transport])
        try await session.start()
        #expect(transport.requests("thread/start").count == 1)
        #expect(session.sessionID == "T")
        #expect(log.events.contains(.sessionStarted(id: "T")))
        #expect(log.events.contains { if case .notice = $0 { true } else { false } })
    }

    @Test func archivedThreadsAreUnarchivedThenResumed() async throws {
        let transport = FakeCodexTransport()
        transport.queued["thread/resume"] = [.error("session OLD is archived; run codex unarchive OLD")]
        transport.handlers["thread/unarchive"] = { _ in .result([:]) }
        let (session, _) = makeSession(resume: "OLD", transports: [transport])
        try await session.start()
        #expect(transport.requests("thread/unarchive").first?.at("params.threadId") == "OLD")
        #expect(transport.requests("thread/resume").count == 2)
        #expect(session.sessionID == "OLD")
    }

    @Test func aTurnStreamsEventsAndCompletesOnce() async throws {
        let transport = FakeCodexTransport()
        let (session, log) = makeSession(transports: [transport])
        try await session.start()
        try await session.send(input("Reply with exactly: pong"))
        let turnStart = try #require(transport.requests("turn/start").first)
        #expect(turnStart.at("params.threadId") == "T")
        #expect(turnStart.at("params.input")?[0]?["text"] == "Reply with exactly: pong")

        transport.notify("turn/started", ["threadId": "T", "turn": ["id": "R1", "status": "inProgress"]])
        transport.notify(
            "item/agentMessage/delta", ["threadId": "T", "turnId": "R1", "itemId": "m", "delta": "pong"])
        transport.notify(
            "item/completed",
            ["threadId": "T", "turnId": "R1", "item": ["type": "agentMessage", "id": "m", "text": "pong"]])
        transport.notify("turn/completed", ["threadId": "T", "turn": ["id": "R1", "status": "completed"]])
        transport.notify("turn/completed", ["threadId": "T", "turn": ["id": "R1", "status": "completed"]])
        #expect(
            Array(log.events.suffix(3)) == [
                .assistantTextDelta(itemID: "m", delta: "pong"), .assistantText(itemID: "m", text: "pong"),
                .turnCompleted(.completed),
            ])
        #expect(log.completions == [.completed])
    }

    @Test func eachTurnCarriesTheLatestSelection() async throws {
        let transport = FakeCodexTransport()
        let (session, _) = makeSession(transports: [transport])
        try await session.start()
        try await session.send(input())
        transport.notify("turn/completed", ["threadId": "T", "turn": ["id": "R1", "status": "completed"]])
        transport.handlers["turn/start"] = { _ in .result(["turn": ["id": "R2", "status": "inProgress"]]) }
        try await session.send(input(model: "gpt-6-astra", effort: "high", access: .approval, mode: .plan))
        let second = try #require(transport.requests("turn/start").last)
        #expect(second.at("params.model") == "gpt-6-astra")
        #expect(second.at("params.effort") == "high")
        #expect(second.at("params.approvalPolicy") == "untrusted")
        #expect(second.at("params.collaborationMode.mode") == "plan")
        #expect(transport.requests("initialize").count == 1)
    }

    @Test func failedTurnsReportCodexDetails() async throws {
        let transport = FakeCodexTransport()
        let (session, log) = makeSession(transports: [transport])
        try await session.start()
        try await session.send(input())
        transport.notify(
            "error",
            [
                "threadId": "T", "turnId": "R1", "willRetry": true,
                "error": ["message": "Reconnecting... 1/5", "additionalDetails": nil],
            ])
        transport.notify(
            "error",
            [
                "threadId": "T", "turnId": "R1", "willRetry": false,
                "error": ["message": "Usage limit", "additionalDetails": "You've hit your usage limit."],
            ])
        transport.notify(
            "turn/completed",
            ["threadId": "T", "turn": ["id": "R1", "status": "failed", "error": ["message": "Usage limit"]]])
        #expect(log.events.contains(.notice("Reconnecting... 1/5")))
        #expect(log.completions == [.failed("You've hit your usage limit.")])
    }

    @Test func approvalsRoundTripToCodex() async throws {
        let transport = FakeCodexTransport()
        let (session, log) = makeSession(transports: [transport])
        try await session.start()
        try await session.send(input(access: .approval))
        transport.request(
            id: 0, "item/commandExecution/requestApproval",
            [
                "kind": "command", "threadId": "T", "turnId": "R1", "itemId": "exec-1", "command": "/bin/zsh -lc 'echo ok'",
                "commandActions": [["type": "unknown", "command": "echo ok"]], "availableDecisions": ["accept", "cancel"],
            ])
        let request = try #require(log.approvals.first)
        #expect(request.title == "Run `echo ok`")
        session.respond(to: request.id, optionID: "accept")
        #expect(transport.responses(to: 0) == [["id": 0, "result": ["decision": "accept"]]])
        transport.notify("serverRequest/resolved", ["threadId": "T", "requestId": 0])
        #expect(!log.events.contains(.approvalResolved(id: request.id)))
        session.respond(to: request.id, optionID: "accept")
        #expect(transport.responses(to: 0).count == 1)
    }

    @Test func withdrawnApprovalsAreResolved() async throws {
        let transport = FakeCodexTransport()
        let (session, log) = makeSession(transports: [transport])
        try await session.start()
        try await session.send(input(access: .approval))
        transport.request(
            id: 3, "item/fileChange/requestApproval", ["threadId": "T", "turnId": "R1", "itemId": "fc-1", "reason": nil])
        let request = try #require(log.approvals.first)
        transport.notify("serverRequest/resolved", ["threadId": "T", "requestId": 3])
        #expect(log.events.last == .approvalResolved(id: request.id))
        session.respond(to: request.id, optionID: "accept")
        #expect(transport.responses(to: 3).isEmpty)
    }

    @Test func questionsAreAnsweredTogether() async throws {
        let transport = FakeCodexTransport()
        let (session, log) = makeSession(transports: [transport])
        try await session.start()
        try await session.send(input(mode: .plan))
        transport.request(
            id: 7, "item/tool/requestUserInput",
            [
                "threadId": "T", "turnId": "R1", "itemId": "q", "isBlocking": true,
                "questions": [
                    [
                        "id": "a", "header": "A", "question": "First?", "isOther": false, "isSecret": false,
                        "options": [["label": "Yes", "description": ""], ["label": "No", "description": ""]],
                    ],
                    [
                        "id": "b", "header": "B", "question": "Second?", "isOther": false, "isSecret": false,
                        "options": [["label": "Left", "description": ""], ["label": "Right", "description": ""]],
                    ],
                ],
            ])
        #expect(log.approvals.count == 2)
        session.respond(to: log.approvals[1].id, optionID: "option-1")
        #expect(transport.responses(to: 7).isEmpty)
        session.respond(to: log.approvals[0].id, optionID: "option-0")
        #expect(
            transport.responses(to: 7) == [
                ["id": 7, "result": ["answers": ["a": ["answers": ["Yes"]], "b": ["answers": ["Right"]]]]]
            ])
    }

    @Test func unanswerableQuestionsAreAnsweredRightAway() async throws {
        let transport = FakeCodexTransport()
        let (session, log) = makeSession(transports: [transport])
        try await session.start()
        try await session.send(input(mode: .plan))
        transport.request(
            id: 8, "item/tool/requestUserInput",
            [
                "threadId": "T", "turnId": "R1", "itemId": "q", "isBlocking": true,
                "questions": [["id": "n", "header": "", "question": "Name?", "isOther": true, "isSecret": false, "options": nil]],
            ])
        #expect(transport.responses(to: 8) == [["id": 8, "result": ["answers": ["n": ["answers": []]]]]])
        #expect(log.events.last == .notice("Codex asked: Name?"))
        #expect(log.approvals.isEmpty)
    }

    @Test func interruptWaitsForTurnStartedAndCompletesOnce() async throws {
        let transport = FakeCodexTransport()
        let (session, log) = makeSession(transports: [transport])
        try await session.start()
        try await session.send(input())
        session.interrupt()
        try await Task.sleep(for: .milliseconds(30))
        #expect(transport.requests("turn/interrupt").isEmpty)
        transport.notify("turn/started", ["threadId": "T", "turn": ["id": "R1", "status": "inProgress"]])
        try await waitUntil { !transport.requests("turn/interrupt").isEmpty }
        #expect(transport.requests("turn/interrupt").first?["params"] == ["threadId": "T", "turnId": "R1"])
        session.interrupt()
        try await Task.sleep(for: .milliseconds(30))
        #expect(transport.requests("turn/interrupt").count == 1)
        transport.notify("turn/completed", ["threadId": "T", "turn": ["id": "R1", "status": "interrupted"]])
        #expect(log.completions == [.interrupted])
    }

    @Test func interruptTurnsDownPendingApprovals() async throws {
        let transport = FakeCodexTransport()
        let (session, log) = makeSession(transports: [transport])
        try await session.start()
        try await session.send(input(access: .approval))
        transport.notify("turn/started", ["threadId": "T", "turn": ["id": "R1", "status": "inProgress"]])
        transport.request(
            id: 1, "item/commandExecution/requestApproval",
            ["kind": "command", "threadId": "T", "turnId": "R1", "itemId": "e", "command": "rm -rf /"])
        session.interrupt()
        #expect(transport.responses(to: 1) == [["id": 1, "result": ["decision": "cancel"]]])
        transport.notify("turn/completed", ["threadId": "T", "turn": ["id": "R1", "status": "completed"]])
        #expect(log.completions == [.interrupted])
    }

    @Test func aStuckInterruptEndsTheTurnAndRestartsCodex() async throws {
        let first = FakeCodexTransport()
        let second = FakeCodexTransport()
        let (session, log) = makeSession(grace: .milliseconds(30), transports: [first, second])
        try await session.start()
        try await session.send(input())
        first.notify("turn/started", ["threadId": "T", "turn": ["id": "R1", "status": "inProgress"]])
        session.interrupt()
        try await waitUntil { !log.completions.isEmpty }
        #expect(log.completions == [.interrupted])
        #expect(first.isClosed)

        second.handlers["turn/start"] = { _ in .result(["turn": ["id": "R2", "status": "inProgress"]]) }
        try await session.send(input("again"))
        #expect(second.requests("thread/resume").first?.at("params.threadId") == "T")
        #expect(second.requests("turn/start").count == 1)
        first.notify("turn/completed", ["threadId": "T", "turn": ["id": "R1", "status": "interrupted"]])
        #expect(log.completions == [.interrupted])
    }

    @Test func aCrashFailsTheTurnAndEndsTheSession() async throws {
        let transport = FakeCodexTransport()
        let (session, log) = makeSession(transports: [transport])
        try await session.start()
        try await session.send(input())
        transport.crash(status: 101, stderr: "thread 'main' panicked\n")
        let message = "Codex exited unexpectedly (status 101).\nthread 'main' panicked"
        #expect(Array(log.events.suffix(2)) == [.turnCompleted(.failed(message)), .sessionExited(error: message)])
    }

    @Test func aRejectedTurnStartThrowsWithoutCompleting() async throws {
        let transport = FakeCodexTransport()
        transport.queued["turn/start"] = [.error("model not supported")]
        let (session, log) = makeSession(transports: [transport])
        try await session.start()
        await #expect(throws: CodexRPCError.server(code: -32600, message: "model not supported")) {
            try await session.send(input())
        }
        #expect(log.completions.isEmpty)
        try await session.send(input())
        #expect(transport.requests("turn/start").count == 2)
    }

    @Test func aClosedThreadIsResumedBeforeTheNextTurn() async throws {
        let transport = FakeCodexTransport()
        let (session, _) = makeSession(transports: [transport])
        try await session.start()
        transport.notify("thread/closed", ["threadId": "T"])
        try await session.send(input())
        #expect(transport.requests("thread/resume").first?.at("params.threadId") == "T")
        #expect(transport.sent.last?["method"] == "turn/start")
    }

    @Test func unknownServerRequestsGetAnError() async throws {
        let transport = FakeCodexTransport()
        let (session, _) = makeSession(transports: [transport])
        try await session.start()
        transport.request(id: 9, "attestation/generate", [:])
        #expect(transport.responses(to: 9).first?.at("error.code")?.int == -32601)
    }

    @Test func shutdownClosesCodexAndStopsEvents() async throws {
        let transport = FakeCodexTransport()
        let (session, log) = makeSession(transports: [transport])
        try await session.start()
        try await session.send(input())
        let count = log.events.count
        session.shutdown()
        #expect(transport.isClosed)
        transport.notify("turn/completed", ["threadId": "T", "turn": ["id": "R1", "status": "completed"]])
        #expect(log.events.count == count)
        await #expect(throws: AgentError.self) { try await session.send(input()) }
    }
}
