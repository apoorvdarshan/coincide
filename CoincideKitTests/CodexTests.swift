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

        let looking = presentation.commandInfo(
            id: "c", command: "/bin/zsh -lc 'ls src && cat README.md'",
            actions: [
                try json(#"{"type":"listFiles","command":"ls src","path":"/work/src"}"#),
                try json(#"{"type":"read","command":"cat README.md","name":"README.md","path":"/work/README.md"}"#),
            ])
        #expect(looking.category == .read)
        #expect(looking.title == "Run `ls src && cat README.md`")

        // A stage Codex left out of its actions (here `cd`) makes it a command again.
        let moved = presentation.commandInfo(
            id: "c", command: "/bin/zsh -lc 'cd src && rg -n foo'",
            actions: [try json(#"{"type":"search","command":"rg -n foo","query":"foo","path":"src"}"#)])
        #expect(moved == ToolCallInfo(id: "c", category: .command, title: "Run `cd src && rg -n foo`", detail: "cd src && rg -n foo"))
        #expect(CodexPresentation.unwrapShell(argv: ["/bin/bash", "-c", "make"]) == "make")
        #expect(CodexPresentation.unwrapShell(argv: ["python3", "-c", "print(1)"]) == "python3 -c print(1)")
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

    @Test func subagentToolCallsAreListedUnderTheirSubagentItem() throws {
        var mapper = mapper()
        let events = try mapper.feed([
            #"{"method":"item/started","params":{"item":{"type":"collabAgentToolCall","id":"spawn","tool":"spawnAgent","status":"inProgress","senderThreadId":"T","receiverThreadIds":[],"prompt":"Run the tests","model":null,"reasoningEffort":null,"agentsStates":{}},"threadId":"T","turnId":"R1","startedAtMs":1}}"#,
            #"{"method":"item/completed","params":{"item":{"type":"collabAgentToolCall","id":"spawn","tool":"spawnAgent","status":"completed","senderThreadId":"T","receiverThreadIds":["T2"],"prompt":"Run the tests","model":null,"reasoningEffort":null,"agentsStates":{"T2":{"status":"pendingInit","message":null}}},"threadId":"T","turnId":"R1","completedAtMs":2}}"#,
            #"{"method":"item/started","params":{"item":{"type":"commandExecution","id":"c-exec","command":"/bin/zsh -lc 'npm test'","cwd":"/work","status":"inProgress","commandActions":[{"type":"unknown","command":"npm test"}]},"threadId":"T2","turnId":"C1","startedAtMs":3}}"#,
            #"{"method":"item/started","params":{"item":{"type":"collabAgentToolCall","id":"wait","tool":"wait","status":"inProgress","senderThreadId":"T","receiverThreadIds":["T2"],"prompt":null,"model":null,"reasoningEffort":null,"agentsStates":{}},"threadId":"T","turnId":"R1","startedAtMs":4}}"#,
            #"{"method":"item/started","params":{"item":{"type":"fileChange","id":"c-edit","changes":[{"path":"/work/a.swift","kind":{"type":"update","move_path":null},"diff":"@@ -1 +1 @@\n-a\n+b\n"}],"status":"inProgress"},"threadId":"T2","turnId":"C1","startedAtMs":5}}"#,
            #"{"method":"item/agentMessage/delta","params":{"threadId":"T2","turnId":"C1","itemId":"m","delta":"done"}}"#,
            #"{"method":"item/completed","params":{"item":{"type":"collabAgentToolCall","id":"wait","tool":"wait","status":"completed","senderThreadId":"T","receiverThreadIds":["T2"],"prompt":null,"model":null,"reasoningEffort":null,"agentsStates":{"T2":{"status":"completed","message":"All tests pass"}}},"threadId":"T","turnId":"R1","completedAtMs":6}}"#,
        ])
        #expect(
            events == [
                .toolStarted(ToolCallInfo(id: "spawn", category: .task, title: "Start a subagent", detail: "Run the tests")),
                .toolCompleted(id: "spawn", status: .completed, output: nil),
                .toolOutput(id: "spawn", delta: "• Run `npm test`\n"),
                .toolStarted(ToolCallInfo(id: "wait", category: .task, title: "Wait for subagents")),
                .toolOutput(id: "wait", delta: "• Edit a.swift\n"),
                .toolOutput(id: "wait", delta: "\nAll tests pass"),
                .toolCompleted(id: "wait", status: .completed, output: nil),
            ])
    }

    @Test func sleepDurationsPastIntsRangeDoNotTrap() throws {
        var mapper = mapper()
        let events = try mapper.feed([
            #"{"method":"item/started","params":{"item":{"type":"sleep","id":"s-1","durationMs":1500},"threadId":"T","turnId":"R1","startedAtMs":1}}"#,
            #"{"method":"item/started","params":{"item":{"type":"sleep","id":"s-2","durationMs":1e25},"threadId":"T","turnId":"R1","startedAtMs":2}}"#,
        ])
        #expect(
            events == [
                .toolStarted(ToolCallInfo(id: "s-1", category: .other, title: "Wait 2 s")),
                .toolStarted(ToolCallInfo(id: "s-2", category: .other, title: "Wait 0 s")),
            ])
    }

    @Test func failedAndBlockingHooksAreReported() throws {
        var mapper = mapper()
        let events = try mapper.feed([
            #"{"method":"hook/completed","params":{"threadId":"T","turnId":"R1","run":{"id":"h1","eventName":"sessionStart","status":"completed","statusMessage":null,"entries":[{"kind":"context","text":"ok"}]}}}"#,
            #"{"method":"hook/completed","params":{"threadId":"T","turnId":"R1","run":{"id":"h2","eventName":"userPromptSubmit","status":"blocked","statusMessage":null,"entries":[{"kind":"context","text":"hidden"},{"kind":"stop","text":"Secrets are not allowed in prompts."}]}}}"#,
            #"{"method":"hook/completed","params":{"threadId":"T","turnId":"R1","run":{"id":"h3","eventName":"preToolUse","status":"failed","statusMessage":"exit status 2","entries":[]}}}"#,
        ])
        #expect(
            events == [
                .notice("A userPromptSubmit hook stopped Codex.\nSecrets are not allowed in prompts."),
                .notice("A preToolUse hook failed.\nexit status 2"),
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

    @Test func compactionIsShownWhileItRuns() throws {
        var mapper = mapper()
        let events = try mapper.feed([
            #"{"method":"item/started","params":{"item":{"type":"contextCompaction","id":"cc"},"threadId":"T","turnId":"R1","startedAtMs":1}}"#,
            #"{"method":"item/completed","params":{"item":{"type":"contextCompaction","id":"cc"},"threadId":"T","turnId":"R1","completedAtMs":2}}"#,
        ])
        #expect(
            events == [
                .toolStarted(ToolCallInfo(id: "cc", category: .other, title: "Compact the conversation")),
                .toolCompleted(id: "cc", status: .completed, output: nil),
            ])
    }

    @Test func reroutesAndWarningsBecomeNoticesOnce() throws {
        var mapper = mapper()
        let events = try mapper.feed([
            #"{"method":"model/rerouted","params":{"threadId":"T","turnId":"R1","fromModel":"gpt-6-astra","toModel":"gpt-6-luna","reason":"highRiskCyberActivity"}}"#,
            #"{"method":"warning","params":{"threadId":"T","message":"Skills budget exceeded"}}"#,
            #"{"method":"warning","params":{"threadId":"T","message":"Skills budget exceeded"}}"#,
            #"{"method":"warning","params":{"threadId":null,"message":"Under-development features enabled"}}"#,
            #"{"method":"guardianWarning","params":{"threadId":"OTHER","message":"not ours"}}"#,
            #"{"method":"configWarning","params":{"summary":"Invalid config","details":"unknown key `foo`","path":"/Users/me/.codex/config.toml"}}"#,
            #"{"method":"mcpServer/startupStatus/updated","params":{"threadId":"T","name":"Neon","status":"starting","error":null,"failureReason":null}}"#,
            #"{"method":"mcpServer/startupStatus/updated","params":{"threadId":"T","name":"Neon","status":"failed","error":"connection refused","failureReason":null}}"#,
            #"{"method":"mcpServer/startupStatus/updated","params":{"threadId":"T","name":"github","status":"failed","error":null,"failureReason":"reauthenticationRequired"}}"#,
        ])
        #expect(
            events == [
                .modelResolved("gpt-6-luna"),
                .notice("Codex switched from gpt-6-astra to gpt-6-luna."),
                .notice("Skills budget exceeded"),
                .notice("Under-development features enabled"),
                .notice("Invalid config\nunknown key `foo`\n/Users/me/.codex/config.toml"),
                .notice("The MCP server “Neon” could not start: connection refused"),
                .notice("The MCP server “github” needs you to sign in again: run `codex mcp login github`."),
            ])
    }

    @Test func asyncQuestionsListTheirSuggestedAnswers() throws {
        var mapper = mapper()
        let events = try mapper.feed([
            #"{"method":"item/completed","params":{"item":{"type":"agentMessage","id":"m","text":"Which branch?","phase":"final_answer","memoryCitation":null,"delivery":"async","questions":[{"title":"Which branch?","options":["main","dev"]},{"title":"Squash?","options":null}]},"threadId":"T","turnId":"R1","completedAtMs":1}}"#
        ])
        #expect(events == [.assistantText(itemID: "m", text: "Which branch?\n\n- main\n- dev\n\n**Squash?**")])
    }

    @Test func outputOfOlderTurnsIsNeverTakenForANewTurn() throws {
        var mapper = mapper()
        mapper.beginTurn()
        mapper.adoptTurn("R2")
        // R3 was sent but Codex has not answered yet; R1's background server keeps printing.
        mapper.beginTurn()
        let events = try mapper.feed([
            #"{"method":"item/commandExecution/outputDelta","params":{"threadId":"T","turnId":"R1","itemId":"server","delta":"GET /\n"}}"#,
            #"{"method":"item/agentMessage/delta","params":{"threadId":"T","turnId":"R3","itemId":"m","delta":"hi"}}"#,
        ])
        #expect(events == [.toolOutput(id: "server", delta: "GET /\n"), .assistantTextDelta(itemID: "m", delta: "hi")])
        #expect(mapper.turnID == "R3")
        #expect(mapper.isFinished("R1") && mapper.isFinished("R2"))
    }

    @Test func lateNotificationsOfAFinishedTurnLeaveThePlanAlone() throws {
        var mapper = mapper()
        mapper.beginTurn()
        mapper.adoptTurn("R2")
        let events = try mapper.feed([
            #"{"method":"item/plan/delta","params":{"threadId":"T","turnId":"R1","itemId":"R1-plan","delta":"Old plan"}}"#,
            #"{"method":"turn/plan/updated","params":{"threadId":"T","turnId":"R2","explanation":null,"plan":[{"step":"New","status":"pending"}]}}"#,
        ])
        #expect(events == [.plan(text: "- [ ] New")])
    }

    @Test func codexAnswerToTurnStartWinsOverAGuessedTurn() throws {
        var mapper = mapper(turn: nil)
        _ = try mapper.feed([
            #"{"method":"item/agentMessage/delta","params":{"threadId":"T","turnId":"STALE","itemId":"m","delta":"x"}}"#
        ])
        mapper.adoptTurn("R2")
        let events = try mapper.feed([
            #"{"method":"item/agentMessage/delta","params":{"threadId":"T","turnId":"R2","itemId":"m2","delta":"ok"}}"#,
            #"{"method":"item/agentMessage/delta","params":{"threadId":"T","turnId":"STALE","itemId":"m","delta":"y"}}"#,
        ])
        #expect(events == [.assistantTextDelta(itemID: "m2", delta: "ok")])
    }

    @Test func hugeOutputsKeepTheirEnd() throws {
        var mapper = mapper()
        let output = (1...40_000).map { "line \($0)" }.joined(separator: "\n")
        let item: JSONValue = [
            "type": "commandExecution", "id": "big", "command": "seq 40000", "cwd": "/work", "status": "completed",
            "commandActions": [], "aggregatedOutput": .string(output), "exitCode": 0,
        ]
        let events = mapper.handle(method: "item/completed", params: ["threadId": "T", "turnId": "R1", "item": item])
        guard case .toolCompleted(_, _, let shown?) = events.last else {
            Issue.record("expected a completion, got \(events)")
            return
        }
        #expect(shown.count <= CodexPresentation.outputLimit + 40)
        #expect(shown.hasPrefix("[Earlier output not shown]\nline "))
        #expect(shown.hasSuffix("line 40000"))
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
                method: "item/commandExecution/requestApproval", params: params, requestID: "a1", presentation: presentation,
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

    @Test func commandApprovalShowsTheWholeCommandNotCodexsSummary() throws {
        // Codex parses `cat a | tee b` as one read of `a`: it drops `tee` as formatting.
        let params = try json(
            #"{"kind":"command","threadId":"T","turnId":"R1","itemId":"exec-1","command":"/bin/zsh -lc 'cat a | tee b'","cwd":"/work","commandActions":[{"type":"read","command":"cat a","name":"a","path":"/work/a"}],"availableDecisions":["accept","cancel"]}"#)
        let approval = try approval(
            CodexServerRequests.action(
                method: "item/commandExecution/requestApproval", params: params, requestID: "a1", presentation: presentation,
                fileChanges: nil))
        #expect(approval.request.title == "Run `cat a | tee b`")
        #expect(approval.request.detail == "cat a | tee b")
        let actions = params["commandActions"]?.array ?? []
        let info = presentation.commandInfo(id: "exec-1", command: "/bin/zsh -lc 'cat a | tee b'", actions: actions)
        #expect(info == ToolCallInfo(id: "exec-1", category: .command, title: "Run `cat a | tee b`", detail: "cat a | tee b"))
        // Without a command, the parsed one stands in.
        #expect(CodexPresentation.displayCommand("", actions: actions) == "cat a")
    }

    @Test func chainedCommandsAreCountedOutsideQuotes() {
        #expect(CodexPresentation.chainedCommandCount("cat a") == 1)
        #expect(CodexPresentation.chainedCommandCount("cat a | tee b && ls || pwd; echo x & wait") == 6)
        #expect(CodexPresentation.chainedCommandCount("pwd\ncat a") == 2)
        #expect(CodexPresentation.chainedCommandCount(#"rg -n 'a|b' "c && d" e\|f"#) == 1)
        #expect(CodexPresentation.chainedCommandCount("a|'b'|c") == 3)
        #expect(CodexPresentation.chainedCommandCount("echo 'open") == nil)
    }

    @Test func commandApprovalWithoutDecisionsUsesTheStandardSet() throws {
        let params = try json(
            #"{"kind":"command","threadId":"T","turnId":"R1","itemId":"exec-1","command":"npm install","reason":"Needs network access","networkApprovalContext":{"host":"registry.npmjs.org","protocol":"https"}}"#)
        let approval = try approval(
            CodexServerRequests.action(
                method: "item/commandExecution/requestApproval", params: params, requestID: "a2", presentation: presentation,
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
                method: "item/fileChange/requestApproval", params: params, requestID: "a3", presentation: presentation,
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
                method: "item/permissions/requestApproval", params: params, requestID: "a4", presentation: presentation,
                fileChanges: nil))
        #expect(approval.request.title == "Allow writing to build")
        #expect(approval.request.category == .fileChange)
        #expect(approval.responses["session"] == ["permissions": ["fileSystem": ["read": nil, "write": ["/work/build"]]], "scope": "session"])
        #expect(approval.responses["deny"] == ["permissions": [:], "scope": "turn"])
    }

    @Test func permissionEntriesAndExtraCommandPermissionsAreDescribed() throws {
        let params = try json(
            #"{"threadId":"T","turnId":"R1","itemId":"p-2","environmentId":null,"startedAtMs":1,"cwd":"/work","reason":null,"permissions":{"network":{"enabled":true},"fileSystem":{"read":null,"write":null,"entries":[{"path":{"type":"path","path":"/work/dist"},"access":"write"},{"path":{"type":"glob_pattern","pattern":"/etc/*.conf"},"access":"read"}]}}}"#)
        let permission = try approval(
            CodexServerRequests.action(
                method: "item/permissions/requestApproval", params: params, requestID: "a12", presentation: presentation,
                fileChanges: nil))
        #expect(permission.request.title == "Allow writing to dist")
        #expect(permission.request.detail == "Write access: dist\nRead access: /etc/*.conf\nNetwork access")

        let command = try json(
            #"{"kind":"command","threadId":"T","turnId":"R1","itemId":"exec-9","command":"/bin/zsh -lc 'curl -O https://example.com/a.zip'","additionalPermissions":{"network":{"enabled":true},"fileSystem":null},"availableDecisions":["accept",{"acceptWithExecpolicyAmendment":{"execpolicy_amendment":["/bin/zsh","-lc","curl -O https://example.com/a.zip"]}},"decline"]}"#)
        let commandApproval = try approval(
            CodexServerRequests.action(
                method: "item/commandExecution/requestApproval", params: command, requestID: "a13",
                presentation: presentation, fileChanges: nil))
        #expect(commandApproval.request.detail == "curl -O https://example.com/a.zip\n\nNetwork access")
        #expect(commandApproval.request.options[1].label == "Always allow `curl -O https://example.com/a.zip`")
        #expect(commandApproval.cancelResponse == ["decision": "decline"])
    }

    @Test func legacyApprovalsAnswerWithReviewDecisions() throws {
        let params = try json(
            #"{"conversationId":"T","callId":"call-1","approvalId":null,"command":["/bin/zsh","-lc","make test"],"cwd":"/work","reason":null,"parsedCmd":[]}"#)
        let approval = try approval(
            CodexServerRequests.action(
                method: "execCommandApproval", params: params, requestID: "a5", presentation: presentation, fileChanges: nil))
        #expect(approval.request.title == "Run `make test`")
        #expect(approval.responses["approved_for_session"] == ["decision": "approved_for_session"])
        #expect(approval.responses["denied"] == ["decision": ["denied": ["rejection": "The user declined the request."]]])
        #expect(approval.cancelResponse == ["decision": "abort"])
    }

    private func userInput(_ action: CodexServerRequestAction) throws -> CodexUserInput {
        guard case .userInput(let input) = action else {
            Issue.record("expected questions, got \(action)")
            throw CancellationError()
        }
        return input
    }

    @Test func requestUserInputQuestionsKeepChoicesFreeTextAndSecrets() throws {
        let params = try json(
            #"{"threadId":"T","turnId":"R1","itemId":"q","isBlocking":true,"autoResolutionMs":null,"questions":[{"id":"stack","header":"Stack","question":"Which framework?","isOther":true,"isSecret":false,"options":[{"label":"SwiftUI","description":"Declarative"},{"label":"AppKit","description":""}]},{"id":"name","header":"","question":"What should it be called?","isOther":false,"isSecret":false,"options":null},{"id":"token","header":"Token","question":"Paste the API token.","isOther":false,"isSecret":true,"options":[]}]}"#)
        let input = try userInput(
            CodexServerRequests.action(
                method: "item/tool/requestUserInput", params: params, requestID: "a6", presentation: presentation,
                fileChanges: nil))
        #expect(input.request.id == "a6")
        #expect(
            input.request.questions == [
                UserQuestion(
                    id: "stack", header: "Stack", prompt: "Which framework?",
                    options: [.init(label: "SwiftUI", detail: "Declarative"), .init(label: "AppKit")], allowsFreeText: true),
                UserQuestion(id: "name", prompt: "What should it be called?", allowsFreeText: true),
                UserQuestion(id: "token", header: "Token", prompt: "Paste the API token.", allowsFreeText: true, isSecret: true),
            ])
        #expect(
            input.response(to: ["stack": ["AppKit"], "name": ["  Coincide "], "token": ["s3cret"], "unknown": ["x"]])
                == [
                    "answers": [
                        "stack": ["answers": ["AppKit"]], "name": ["answers": ["Coincide"]],
                        "token": ["answers": ["s3cret"]],
                    ]
                ])
        #expect(input.response(to: ["stack": ["SwiftUI"], "name": [" "]]) == ["answers": ["stack": ["answers": ["SwiftUI"]]]])
        #expect(input.dismissResponse == ["answers": [:]])
    }

    @Test func requestsWithoutQuestionsAreAnsweredRightAway() throws {
        let params = try json(#"{"threadId":"T","turnId":"R1","itemId":"q","isBlocking":true,"questions":[]}"#)
        guard case .respond(let result) = CodexServerRequests.action(
            method: "item/tool/requestUserInput", params: params, requestID: "a7", presentation: presentation,
            fileChanges: nil)
        else {
            Issue.record("expected an immediate answer")
            return
        }
        #expect(result == ["answers": [:]])
    }

    @Test func approveStyleElicitationsCanBeAnswered() throws {
        let params = try json(
            #"{"threadId":"T","turnId":"R1","serverName":"codex_apps","mode":"form","_meta":{"persist":["session","always"]},"message":"Allow ChatGPT to use Gmail?","requestedSchema":{"type":"object","properties":{},"required":[]}}"#)
        let approval = try approval(
            CodexServerRequests.action(
                method: "mcpServer/elicitation/request", params: params, requestID: "a8", presentation: presentation,
                fileChanges: nil))
        #expect(approval.request.title == "Allow ChatGPT to use Gmail?")
        #expect(approval.request.options.map(\.id) == ["accept", "session", "always", "decline", "cancel"])
        #expect(approval.responses["accept"] == ["action": "accept", "content": [:], "_meta": nil])
        #expect(approval.responses["session"] == ["action": "accept", "content": [:], "_meta": ["persist": "session"]])
    }

    @Test func approveStyleFormsFillApproveChoices() throws {
        let form = try json(
            #"{"threadId":"T","turnId":"R1","serverName":"s","mode":"form","_meta":null,"message":"Run tool?","requestedSchema":{"type":"object","properties":{"decision":{"type":"string","enum":["approve_once","approve_session","deny"]}},"required":["decision"]}}"#)
        #expect(CodexServerRequests.elicitationResponse(form, persist: nil)?.at("content.decision") == "approve_once")
        #expect(CodexServerRequests.elicitationResponse(form, persist: "session")?.at("content.decision") == "approve_session")
        #expect(CodexServerRequests.elicitationPersistence(form) == ["session"])
        let approval = try approval(
            CodexServerRequests.action(
                method: "mcpServer/elicitation/request", params: form, requestID: "a9", presentation: presentation,
                fileChanges: nil))
        #expect(approval.request.options.map(\.id) == ["accept", "session", "decline", "cancel"])
        #expect(approval.cancelResponse == ["action": "cancel", "content": nil, "_meta": nil])
    }

    @Test func formsThatNeedAnswersBecomeQuestions() throws {
        let form = try json(
            #"{"threadId":"T","turnId":"R1","serverName":"github","mode":"form","_meta":null,"message":"Where should the issue go?","requestedSchema":{"type":"object","properties":{"repo":{"type":"string","title":"Repository","description":"owner/name"},"labels":{"type":"array","items":{"anyOf":[{"const":"bug","title":"Bug"},{"const":"docs","title":"Docs"}]}},"priority":{"type":"integer","title":"Priority","default":2},"public":{"type":"boolean","title":"Public"},"kind":{"type":"string","oneOf":[{"const":"task","title":"Task"},{"const":"epic","title":"Epic"}]}},"required":["repo","public","kind"]}}"#)
        let input = try userInput(
            CodexServerRequests.action(
                method: "mcpServer/elicitation/request", params: form, requestID: "a10", presentation: presentation,
                fileChanges: nil))
        #expect(input.request.title == "Where should the issue go?")
        #expect(input.request.questions.map(\.id) == ["kind", "public", "repo", "labels", "priority"])
        let byID = Dictionary(uniqueKeysWithValues: input.request.questions.map { ($0.id, $0) })
        #expect(byID["repo"] == UserQuestion(id: "repo", header: "Repository", prompt: "owner/name", allowsFreeText: true))
        #expect(byID["kind"]?.options.map(\.label) == ["Task", "Epic"])
        #expect(byID["kind"]?.allowsFreeText == false)
        #expect(byID["public"]?.options.map(\.label) == ["Yes", "No"])
        #expect(byID["labels"]?.allowsMultipleSelection == true)
        #expect(byID["labels"]?.prompt == "labels (optional)")
        #expect(byID["priority"]?.prompt == "Priority (default: 2)")

        let accepted = input.response(to: [
            "repo": ["apoorvdarshan/coincide"], "kind": ["Epic"], "public": ["No"], "labels": ["Bug", "docs"],
        ])
        #expect(accepted["action"] == "accept")
        #expect(
            accepted["content"] == [
                "repo": "apoorvdarshan/coincide", "kind": "epic", "public": false, "labels": ["bug", "docs"], "priority": 2,
            ])
        #expect(input.response(to: ["repo": ["x/y"], "kind": ["Task"], "public": ["Yes"], "priority": ["3"]])["content"]?["priority"] == 3)
        // A required answer that does not fit, or no answers at all, cancels the form.
        #expect(input.response(to: ["repo": ["x/y"], "kind": ["Story"], "public": ["Yes"]])["action"] == "cancel")
        #expect(input.dismissResponse == ["action": "cancel", "content": nil, "_meta": nil])
    }

    @Test func urlAndVerificationElicitationsAreDeclined() throws {
        for mode in [
            #""mode":"url","message":"Sign in","url":"https://example.com","elicitationId":"e""#,
            #""mode":"openai/userVerification","title":"Verify","description":"Confirm","challenge":"123""#,
        ] {
            let params = try json(#"{"threadId":"T","turnId":null,"serverName":"s","_meta":null,"# + mode + "}")
            guard case .respond(let result) = CodexServerRequests.action(
                method: "mcpServer/elicitation/request", params: params, requestID: "a11", presentation: presentation,
                fileChanges: nil)
            else {
                Issue.record("expected a decline for \(mode)")
                continue
            }
            #expect(result["action"] == "decline")
        }
    }

    @Test func toolCallsTimeAndUnknownRequestsAreAnsweredDirectly() throws {
        let tool = CodexServerRequests.action(
            method: "item/tool/call", params: [:], requestID: "x", presentation: presentation, fileChanges: nil)
        guard case .respond(let toolResult) = tool else {
            Issue.record("expected a tool result")
            return
        }
        #expect(toolResult["success"] == false)

        let time = CodexServerRequests.action(
            method: "currentTime/read", params: ["threadId": "T"], requestID: "x", presentation: presentation, fileChanges: nil)
        guard case .respond(let timeResult) = time else {
            Issue.record("expected the time")
            return
        }
        #expect((timeResult["currentTimeAt"]?.number ?? 0) > 1_700_000_000)

        guard case .reject = CodexServerRequests.action(
            method: "account/chatgptAuthTokens/refresh", params: [:], requestID: "x", presentation: presentation,
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
        handlers["model/list"] = { _ in .result(["data": [], "nextCursor": nil]) }
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

    /// Answers a request that was left unanswered (`.silent`).
    func answer(_ method: String, with result: JSONValue) {
        guard let id = requests(method).last?["id"] else { return }
        deliver(["id": id, "result": result])
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

    var questions: [UserInputRequest] {
        events.compactMap { event -> UserInputRequest? in
            guard case .userInputRequested(let request) = event else { return nil }
            return request
        }
    }

    var notices: [String] {
        events.compactMap { event -> String? in
            guard case .notice(let text) = event else { return nil }
            return text
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
        // The model list and the plan's usage windows are read in the background.
        #expect(
            transport.sent.compactMap { $0["method"]?.string }.filter { $0 != "model/list" && $0 != "account/rateLimits/read" }
                == ["initialize", "initialized", "thread/start"])
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
        #expect(Array(log.events.prefix(3)) == [
            .sessionStarted(id: "T"), .modelResolved("gpt-6-luna"),
            .notice("The previous Codex session could not be resumed, so a new one was started. (no rollout found for thread id OLD)"),
        ])
    }

    @Test func aFreshThreadThatAlsoFailsReportsTheError() async throws {
        let transport = FakeCodexTransport()
        transport.queued["thread/resume"] = [.error("no rollout found for thread id OLD")]
        transport.queued["thread/start"] = [.error("model gpt-0 is not supported")]
        let (session, log) = makeSession(resume: "OLD", transports: [transport])
        await #expect(throws: CodexRPCError.server(code: -32600, message: "model gpt-0 is not supported")) {
            try await session.start()
        }
        #expect(log.notices.isEmpty)
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

    @Test func questionsAreAnsweredThroughUserInput() async throws {
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
                    ["id": "b", "header": "B", "question": "Name?", "isOther": false, "isSecret": false, "options": nil],
                ],
            ])
        let request = try #require(log.questions.first)
        #expect(request.questions.map(\.id) == ["a", "b"])
        #expect(request.questions[1].allowsFreeText)
        session.answer(userInput: request.id, answers: ["a": ["No"], "b": ["Coincide"]])
        #expect(
            transport.responses(to: 7) == [
                ["id": 7, "result": ["answers": ["a": ["answers": ["No"]], "b": ["answers": ["Coincide"]]]]]
            ])
        session.answer(userInput: request.id, answers: [:])
        #expect(transport.responses(to: 7).count == 1)
    }

    @Test func dismissedAndWithdrawnQuestions() async throws {
        let transport = FakeCodexTransport()
        let (session, log) = makeSession(transports: [transport])
        try await session.start()
        try await session.send(input(mode: .plan))
        let question: JSONValue = [
            "threadId": "T", "turnId": "R1", "itemId": "q", "isBlocking": true,
            "questions": [["id": "n", "header": "", "question": "Name?", "isOther": true, "isSecret": false, "options": nil]],
        ]
        transport.request(id: 8, "item/tool/requestUserInput", question)
        transport.request(id: 9, "item/tool/requestUserInput", question)
        #expect(log.questions.count == 2)
        session.answer(userInput: log.questions[0].id, answers: [:])
        #expect(transport.responses(to: 8) == [["id": 8, "result": ["answers": [:]]]])
        transport.notify("serverRequest/resolved", ["threadId": "T", "requestId": 9])
        #expect(log.events.last == .userInputResolved(id: log.questions[1].id))
        session.answer(userInput: log.questions[1].id, answers: ["n": ["late"]])
        #expect(transport.responses(to: 9).isEmpty)
    }

    @Test func mcpFormsAreAskedAndAnsweredWithTypedContent() async throws {
        let transport = FakeCodexTransport()
        let (session, log) = makeSession(transports: [transport])
        try await session.start()
        try await session.send(input())
        transport.request(
            id: 4, "mcpServer/elicitation/request",
            [
                "threadId": "T", "turnId": "R1", "serverName": "tracker", "mode": "form", "_meta": nil,
                "message": "How many tickets?",
                "requestedSchema": [
                    "type": "object", "properties": ["count": ["type": "integer", "title": "Count"]], "required": ["count"],
                ],
            ])
        let request = try #require(log.questions.first)
        #expect(request.title == "How many tickets?")
        session.answer(userInput: request.id, answers: ["count": ["3"]])
        #expect(
            transport.responses(to: 4) == [
                ["id": 4, "result": ["action": "accept", "content": ["count": 3], "_meta": nil]]
            ])
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
        transport.request(
            id: 2, "item/tool/requestUserInput",
            [
                "threadId": "T", "turnId": "R1", "itemId": "q", "isBlocking": true,
                "questions": [["id": "n", "header": "", "question": "Name?", "isOther": true, "isSecret": false, "options": nil]],
            ])
        session.interrupt()
        #expect(transport.responses(to: 1) == [["id": 1, "result": ["decision": "cancel"]]])
        #expect(transport.responses(to: 2) == [["id": 2, "result": ["answers": [:]]]])
        transport.request(
            id: 3, "item/commandExecution/requestApproval",
            ["kind": "command", "threadId": "T", "turnId": "R1", "itemId": "e2", "command": "ls"])
        #expect(transport.responses(to: 3) == [["id": 3, "result": ["decision": "cancel"]]])
        #expect(log.approvals.count == 1)
        transport.notify("turn/completed", ["threadId": "T", "turn": ["id": "R1", "status": "completed"]])
        #expect(log.completions == [.interrupted])
    }

    @Test func promptsLeftOpenByATurnAreDeclinedWhenItEnds() async throws {
        let transport = FakeCodexTransport()
        let (session, log) = makeSession(transports: [transport])
        try await session.start()
        // A subagent asks between turns: it stays open across the next turn.
        transport.request(
            id: 5, "item/permissions/requestApproval",
            ["threadId": "SUB", "turnId": "S1", "itemId": "p", "cwd": "/work", "reason": nil, "permissions": ["network": ["enabled": true], "fileSystem": nil]])
        try await session.send(input(access: .approval))
        transport.request(
            id: 6, "item/fileChange/requestApproval", ["threadId": "T", "turnId": "R1", "itemId": "fc", "reason": nil])
        #expect(log.approvals.count == 2)
        #expect(log.approvals[0].title == "Subagent: Allow network access")
        #expect(log.approvals[1].title == "Edit files")
        transport.notify("turn/completed", ["threadId": "T", "turn": ["id": "R1", "status": "completed"]])
        #expect(transport.responses(to: 6) == [["id": 6, "result": ["decision": "cancel"]]])
        #expect(transport.responses(to: 5).isEmpty)
        session.respond(to: log.approvals[0].id, optionID: "turn")
        #expect(transport.responses(to: 5).first?.at("result.scope") == "turn")
    }

    @Test func aStopWhileCodexStartsUpNeverStartsTheTurn() async throws {
        let transport = FakeCodexTransport()
        transport.handlers["thread/start"] = { _ in .silent }
        let (session, log) = makeSession(transports: [transport])
        let sending = Task { try await session.send(input()) }
        try await waitUntil { !transport.requests("thread/start").isEmpty }
        session.interrupt()
        transport.answer("thread/start", with: ["thread": ["id": "T"], "model": "gpt-6-luna"])
        try await sending.value
        #expect(log.completions == [.interrupted])
        #expect(transport.requests("turn/start").isEmpty)
        try await session.send(input())
        #expect(transport.requests("turn/start").count == 1)
    }

    @Test func aStuckInterruptEndsTheTurnAndTheProcess() async throws {
        let first = FakeCodexTransport()
        let (session, log) = makeSession(grace: .milliseconds(30), transports: [first])
        try await session.start()
        try await session.send(input())
        first.notify("turn/started", ["threadId": "T", "turn": ["id": "R1", "status": "inProgress"]])
        session.interrupt()
        try await waitUntil { !log.completions.isEmpty }
        #expect(Array(log.events.suffix(2)) == [.turnCompleted(.interrupted), .sessionExited(error: nil)])
        #expect(first.isClosed)
        first.notify("turn/completed", ["threadId": "T", "turn": ["id": "R1", "status": "interrupted"]])
        #expect(log.completions == [.interrupted])
        await #expect(throws: AgentError.self) { try await session.send(input("again")) }

        // The runner then resumes the thread in a new session.
        let second = FakeCodexTransport()
        let (resumed, _) = makeSession(resume: session.sessionID, transports: [second])
        try await resumed.start()
        #expect(second.requests("thread/resume").first?.at("params.threadId") == "T")
    }

    @Test func aCrashFailsTheTurnAndEndsTheSession() async throws {
        let transport = FakeCodexTransport()
        let (session, log) = makeSession(transports: [transport])
        try await session.start()
        try await session.send(input())
        transport.crash(status: 101, stderr: "thread 'main' panicked\n")
        let message = "Codex exited unexpectedly (status 101).\nthread 'main' panicked"
        #expect(Array(log.events.suffix(2)) == [.turnCompleted(.failed(message)), .sessionExited(error: message)])
        await #expect(throws: AgentError.self) { try await session.send(input()) }
    }

    @Test func aCrashBeforeCodexAcceptsTheTurnFailsTheSend() async throws {
        let transport = FakeCodexTransport()
        transport.handlers["turn/start"] = { _ in .silent }
        let (session, log) = makeSession(transports: [transport])
        try await session.start()
        let sending = Task { try await session.send(input()) }
        try await waitUntil { !transport.requests("turn/start").isEmpty }
        transport.crash(status: 1, stderr: "")
        await #expect(throws: CodexRPCError.closed("Codex exited unexpectedly (status 1).")) { try await sending.value }
        #expect(log.completions.isEmpty)
        #expect(log.events.last == .sessionExited(error: "Codex exited unexpectedly (status 1)."))
    }

    @Test func retryNoticesAreShownOncePerStreak() async throws {
        let transport = FakeCodexTransport()
        let (session, log) = makeSession(transports: [transport])
        try await session.start()
        try await session.send(input())
        for attempt in 1...3 {
            transport.notify(
                "error",
                [
                    "threadId": "T", "turnId": "R1", "willRetry": true,
                    "error": ["message": .string("Reconnecting... \(attempt)/5"), "additionalDetails": nil],
                ])
        }
        transport.notify(
            "error",
            ["threadId": "T", "turnId": "R1", "willRetry": true, "error": ["message": "Stream disconnected; retrying"]])
        #expect(log.notices == ["Reconnecting... 1/5", "Stream disconnected; retrying"])
    }

    @Test func theSessionCatalogRefreshesTheModelPickerOnce() async throws {
        let transport = FakeCodexTransport()
        transport.handlers["model/list"] = { _ in
            .result([
                "data": [
                    [
                        "id": "gpt-6-luna", "model": "gpt-6-luna", "displayName": "GPT-6-Luna", "hidden": false,
                        "supportedReasoningEfforts": [["reasoningEffort": "low", "description": ""]],
                        "defaultReasoningEffort": "low", "inputModalities": ["text", "image"], "isDefault": true,
                    ]
                ],
                "nextCursor": nil,
            ])
        }
        let (session, log) = makeSession(transports: [transport])
        try await session.start()
        try await waitUntil { log.events.contains { if case .modelsDiscovered = $0 { true } else { false } } }
        transport.notify("thread/closed", ["threadId": "T"])
        try await session.send(input())
        try await Task.sleep(for: .milliseconds(30))
        #expect(transport.requests("model/list").count == 1)
        #expect(
            log.events.contains(
                .modelsDiscovered([
                    ModelOption(
                        provider: .codex, modelID: "gpt-6-luna", displayName: "GPT-6-Luna", efforts: ["low"],
                        defaultEffort: "low")
                ])))
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
        let methods = transport.sent.compactMap { $0["method"]?.string }.filter {
            $0 != "model/list" && $0 != "account/rateLimits/read"
        }
        #expect(methods.suffix(2) == ["thread/resume", "turn/start"])
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

// MARK: - Steering and usage limits

struct CodexUsageLimitsTests {
    @Test func windowsFollowT3sReadingOfCodexSnapshots() throws {
        let read = try #require(
            JSONValue.parse(
                #"""
                {"rateLimits":{"limitId":"codex","primary":{"usedPercent":99,"windowDurationMins":300,"resetsAt":1800000000}},
                 "rateLimitsByLimitId":{"codex":{"limitId":"codex","planType":"pro",
                   "primary":{"usedPercent":42,"windowDurationMins":300,"resetsAt":1800003600},
                   "secondary":{"usedPercent":17,"windowDurationMins":10080,"resetsAt":1800500000}},
                   "gpt-6-astra":{"limitId":"gpt-6-astra","primary":{"usedPercent":80}}}}
                """#))
        // The `codex` bucket wins over the single-bucket view.
        let windows = CodexUsageLimits.windows(fromRead: read)
        #expect(windows.map(\.id) == ["primary", "secondary"])
        #expect(windows.map(\.kind) == [.session, .weekly])
        #expect(windows.map(\.label) == ["Session", "Weekly"])
        #expect(windows.map(\.usedPercent) == [42, 17])
        #expect(windows[0].resetsAt == Date(timeIntervalSince1970: 1_800_003_600))
        #expect(windows[1].durationMinutes == 10_080)
    }

    @Test func positionsWithoutLengthsUseThePlansWindows() throws {
        let paid = try #require(JSONValue.parse(#"{"primary":{"usedPercent":5},"secondary":{"usedPercent":6,"resetsAt":null}}"#))
        #expect(CodexUsageLimits.windows(from: paid).map(\.kind) == [.session, .weekly])
        #expect(CodexUsageLimits.windows(from: paid).map(\.durationMinutes) == [300, 10_080])
        let free = try #require(JSONValue.parse(#"{"planType":"free","primary":{"usedPercent":5}}"#))
        #expect(CodexUsageLimits.windows(from: free).map(\.kind) == [.monthly])
        #expect(CodexUsageLimits.windows(from: free).first?.label == "Monthly")
    }

    @Test func modelLimitsAreLeftOutAndCreditLimitsAdded() throws {
        let model = try #require(JSONValue.parse(#"{"limitId":"gpt-6-astra","primary":{"usedPercent":80}}"#))
        #expect(CodexUsageLimits.windows(from: model).isEmpty)
        let credits = try #require(
            JSONValue.parse(#"{"individualLimit":{"limit":"100","used":"30","remainingPercent":70,"resetsAt":1800000000}}"#))
        let window = try #require(CodexUsageLimits.windows(from: credits).first)
        #expect(window.id == "individual" && window.kind == .monthly && window.usedPercent == 30)
        #expect(window.label == "Monthly credit limit")
        #expect(CodexUsageLimits.windows(from: nil).isEmpty)
        #expect(CodexUsageLimits.windows(from: .null).isEmpty)
    }
}

extension CodexSessionTests {
    @Test func steeringSendsTheMessageIntoTheActiveTurn() async throws {
        let transport = FakeCodexTransport()
        transport.handlers["turn/steer"] = { _ in .result(["turnId": "R1"]) }
        let (session, log) = makeSession(transports: [transport])
        #expect(session.supportsSteering)
        try await session.start()
        try await session.send(input("Count to ten"))
        transport.notify("turn/started", ["threadId": "T", "turn": ["id": "R1", "status": "inProgress"]])
        try await session.steer(input("Stop at five", model: "gpt-6-astra"))
        let steer = try #require(transport.requests("turn/steer").first)
        #expect(steer.at("params.threadId") == "T")
        #expect(steer.at("params.expectedTurnId") == "R1")
        #expect(steer.at("params.input")?[0]?["text"] == "Stop at five")
        // Steering adds to the turn: no new turn, and it still completes once.
        #expect(transport.requests("turn/start").count == 1)
        transport.notify("turn/completed", ["threadId": "T", "turn": ["id": "R1", "status": "completed"]])
        #expect(log.completions == [.completed])
    }

    @Test func steeringNeedsTheTurnsIDAndATurnThatIsNotStopping() async throws {
        let transport = FakeCodexTransport()
        transport.handlers["turn/start"] = { _ in .silent }
        transport.handlers["turn/steer"] = { _ in .result(["turnId": "R1"]) }
        let (session, _) = makeSession(transports: [transport])
        try await session.start()
        await #expect(throws: AgentError.self) { try await session.steer(input()) }
        let sending = Task { try await session.send(input()) }
        try await waitUntil { !transport.requests("turn/start").isEmpty }
        // Codex has not named the turn yet.
        await #expect(throws: AgentError.self) { try await session.steer(input()) }
        transport.answer("turn/start", with: ["turn": ["id": "R1", "status": "inProgress", "startedAt": 1]])
        try await sending.value
        try await session.steer(input())
        session.interrupt()
        await #expect(throws: AgentError.self) { try await session.steer(input()) }
        #expect(transport.requests("turn/steer").count == 1)
    }

    @Test func aSteerCodexRefusesFailsTheCall() async throws {
        let transport = FakeCodexTransport()
        transport.handlers["turn/steer"] = { _ in .error("expected turn R1 is not active") }
        let (session, log) = makeSession(transports: [transport])
        try await session.start()
        try await session.send(input())
        await #expect(throws: CodexRPCError.self) { try await session.steer(input()) }
        #expect(log.completions.isEmpty)
    }

    @Test func usageLimitsAreReadOnStartAndFollowCodexsUpdates() async throws {
        let transport = FakeCodexTransport()
        transport.handlers["account/rateLimits/read"] = { params in
            guard params["excludeResetCreditDetails"] == true else { return .error("expected a background read") }
            return .result(["rateLimits": ["primary": ["usedPercent": 12, "windowDurationMins": 300]]])
        }
        let (session, log) = makeSession(transports: [transport])
        try await session.start()
        let limits = { log.events.compactMap { event -> [UsageLimitWindow]? in if case .rateLimits(let w) = event { w } else { nil } } }
        try await waitUntil { !limits().isEmpty }
        #expect(limits().first?.map(\.usedPercent) == [12])

        transport.notify(
            "account/rateLimits/updated",
            ["rateLimits": ["limitId": "codex", "secondary": ["usedPercent": 91, "windowDurationMins": 10080, "resetsAt": 1_800_000_000]]])
        #expect(
            limits().last == [
                UsageLimitWindow(
                    id: "secondary", kind: .weekly, label: "Weekly", usedPercent: 91,
                    resetsAt: Date(timeIntervalSince1970: 1_800_000_000), durationMinutes: 10_080)
            ])
        // A model's own limit is not the plan's.
        transport.notify("account/rateLimits/updated", ["rateLimits": ["limitId": "gpt-6-astra", "primary": ["usedPercent": 99]]])
        #expect(limits().count == 2)
        // Read once per session.
        try await session.send(input())
        #expect(transport.requests("account/rateLimits/read").count == 1)
    }
}
