import Foundation
import Testing

@testable import CoincideKit

// Ported from T3 Code's provider-muse tests (sdk, modelCatalog, protocol, itemPresentation, usageLimits, status,
// maintenance) and replayed against its recorded Muse 1.4.3 transcripts (`MuseFixtures`).

private func json(_ text: String) throws -> JSONValue {
    try #require(JSONValue.parse(text), "invalid JSON fixture: \(text)")
}

private func item(_ fields: [String: JSONValue]) -> MuseItem? {
    var value: [String: JSONValue] = ["itemId": "native-item", "kind": "toolCall", "status": "completed", "revision": 1]
    for (key, field) in fields { value[key] = field }
    return MuseItem(.object(value))
}

private func args(_ object: JSONValue) -> JSONValue { .string(object.compactJSON) }

// MARK: - Protocol

struct MuseProtocolTests {
    @Test(arguments: ["META_API_KEY", "meta_api_key", "Meta_Api_Key"])
    func inheritedAPIKeysAreDroppedAndAutoUpdateIsOff(key: String) {
        let environment = MuseProtocol.environment(inherited: ["PATH": "/bin", "MUSE_TEST": "yes", key: "secret"])
        #expect(environment == ["PATH": "/bin", "MUSE_TEST": "yes", "MUSE_NO_AUTO_UPDATE": "1"])
    }

    @Test func eachAccessAndPlanModeGetsItsFlagsApprovalModeAndProfile() {
        let full = MuseProtocol.HostMode(accessMode: .fullAccess, interactionMode: .build)
        let ask = MuseProtocol.HostMode(accessMode: .approval, interactionMode: .build)
        let plan = MuseProtocol.HostMode(accessMode: .fullAccess, interactionMode: .plan)
        #expect(MuseProtocol.serveArguments(full) == ["serve", "--trust-workspace", "--disable-sandbox"])
        #expect(MuseProtocol.serveArguments(ask) == ["serve", "--trust-workspace"])
        #expect(MuseProtocol.serveArguments(plan) == ["serve", "--trust-workspace", "--disable-shell", "--disable-write"])
        #expect(MuseProtocol.probeArguments == ["serve", "--disable-shell", "--disable-write", "--no-session-log"])
        #expect(MuseProtocol.approvalMode(.fullAccess) == "allowAll")
        #expect(MuseProtocol.approvalMode(.approval) == "promptUnmatched")
        #expect(MuseProtocol.permissionProfile(.fullAccess) == ":unrestricted")
        #expect(MuseProtocol.permissionProfile(.approval) == ":ask-me")
    }

    @Test func initializeAsksForNothingAndAcceptsOnlyEnvelopeVersionOne() throws {
        let params = MuseProtocol.initializeParams(version: "1.2")
        #expect(params.at("clientInfo.name") == "coincide")
        #expect(params.at("clientInfo.version") == "1.2")
        #expect(params.at("capabilities.requestedCapabilities") == [])
        try MuseProtocol.checkInitializeResult(MuseFixtures.initializeResult)
        for schema: JSONValue in [["fingerprint": "test"], ["fingerprint": "test", "version": 2], ["version": 1]] {
            #expect(throws: AgentError.self) { try MuseProtocol.checkInitializeResult(["schema": schema]) }
        }
    }

    @Test func versionsKeepMusesReleaseRevision() {
        #expect(MuseProtocol.version(in: "Muse Code 1.1.1 (1.1.1-R2514.1)") == "1.1.1-R2514.1")
        #expect(MuseProtocol.version(in: "muse 1.0.3-R2198.1\n") == "1.0.3-R2198.1")
        #expect(MuseProtocol.version(in: "muse v1.4.3") == "1.4.3")
        #expect(MuseProtocol.version(in: "unknown") == nil)
    }

    @Test func metasCatalogBecomesPickerModelsWithTheDefaultFirst() throws {
        let list = try json(
            #"{"providerId":"meta","source":"live","models":[{"modelId":"muse-newer","displayLabel":"Muse Newer","providerId":"meta","isDefault":false,"variants":["low","ultra","turbo"],"defaultReasoningEffort":"ultra"},{"modelId":"muse-wonder-1.0","displayLabel":"muse-wonder-1.0","providerId":"meta","isDefault":true},{"modelId":"foreign-model","displayLabel":"Another provider","providerId":"another","isDefault":false},{"modelId":"muse-wonder-1.0","displayLabel":"Again","providerId":"meta","isDefault":false},{"modelId":"muse-none","displayLabel":"","providerId":"meta","isDefault":false,"variants":[]},{"modelId":"muse-unknown","displayLabel":"Unknown","providerId":"meta","isDefault":false,"variants":"unknown"}]}"#)
        let models = try #require(MuseProtocol.models(fromList: list))
        #expect(models.map(\.modelID) == ["muse-wonder-1.0", "muse-newer", "muse-none", "muse-unknown"])
        #expect(models.map(\.displayName) == ["Muse Wonder 1.0", "Muse Newer", "Muse None", "Unknown"])
        #expect(models.allSatisfy { $0.provider == .muse })
        // Unreported efforts fall back to T3's list; reported ones keep only tiers Muse knows.
        #expect(models[0].efforts == ["low", "medium", "high", "xhigh", "max"])
        #expect(models[0].defaultEffort == "high")
        #expect(models[1].efforts == ["low", "ultra"])
        #expect(models[1].defaultEffort == "ultra")
        #expect(models[2].efforts.isEmpty)
        #expect(models[2].defaultEffort == nil)
        #expect(models[3].efforts == ["low", "medium", "high", "xhigh", "max"])
        #expect(MuseProtocol.models(fromList: ["providerId": "another", "models": []]) == nil)
        #expect(MuseProtocol.models(fromList: ["providerId": "meta", "models": []]) == [])
    }

    @Test func turnsSendOnlyModelsAndEffortsMuseKnows() {
        #expect(MuseProtocol.modelID(ModelSelection(provider: .muse, modelID: " muse-wonder-1.0 ")) == "muse-wonder-1.0")
        #expect(MuseProtocol.modelID(ModelSelection(provider: .muse, modelID: "default")) == nil)
        #expect(MuseProtocol.reasoningEffort(ModelSelection(provider: .muse, modelID: "m", effort: "max")) == "max")
        #expect(MuseProtocol.reasoningEffort(ModelSelection(provider: .muse, modelID: "m", effort: "turbo")) == nil)
        #expect(MuseProtocol.reasoningEffort(ModelSelection(provider: .muse, modelID: "m")) == nil)
        #expect(MuseProtocol.isCompactCommand(" /compact\n"))
        #expect(!MuseProtocol.isCompactCommand("/compact now"))
    }

    @Test func modelsTheAccountCannotUseGetAHint() {
        let refusal = "Model muse-wonder-1.0 does not exist or you lack access to it."
        #expect(MuseProtocol.explained(refusal).hasPrefix(refusal + "\n\n"))
        #expect(MuseProtocol.explained("Something else") == "Something else")
        let error = MuseProtocol.explained(MuseRPCError.server(code: -32602, kind: "invalidParams", message: refusal))
        #expect(error.localizedDescription == MuseProtocol.explained(refusal))
        let other = MuseRPCError.server(code: -32602, kind: "invalidParams", message: "bad")
        #expect(MuseProtocol.explained(other) as? MuseRPCError == other)
    }

    @MainActor
    @Test func idsAreOrderedVersionSevenUUIDs() {
        let id = MuseIDs.uuidV7(milliseconds: 0x01a1_1a6a_bbb5, sequence: 0x123, random: [UInt8](repeating: 0xff, count: 16))
        #expect(id == "01a11a6a-bbb5-7123-bfff-ffffffffffff")
        let ids = MuseIDs.uuidV7()
        let minted = (0..<50).map { _ in ids.next() }
        #expect(Set(minted).count == 50)
        #expect(minted == minted.sorted())
        #expect(minted.allSatisfy { $0.count == 36 && $0[$0.index($0.startIndex, offsetBy: 14)] == "7" })
    }

    @Test func overloadedAndBackpressuredCommandsCanBeSentAgain() {
        #expect(MuseRPCError.server(code: -32001, kind: "overloaded", message: "").nothingAdmitted)
        #expect(MuseRPCError.server(code: -32031, kind: "backpressured", message: "").nothingAdmitted)
        #expect(!MuseRPCError.server(code: -32001, kind: "internal", message: "").nothingAdmitted)
        #expect(!MuseRPCError.timedOut(method: "turn/start").nothingAdmitted)
    }
}

// MARK: - Usage limits

struct MuseUsageLimitsTests {
    private let usage = MuseSubscriptionUsage(
        window: .init(usedPercent: 0, resetsAt: Date(timeIntervalSince1970: 1_791_465_557), durationMinutes: 300),
        weekly: .init(usedPercent: 5, resetsAt: Date(timeIntervalSince1970: 1_791_763_200), durationMinutes: nil))
    private let now = Date(timeIntervalSince1970: 1_791_447_762.610)
    private let relayed =
        "API error 429: All credentials for model muse-wonder-1.0-contributor are cooling down (last error: rate_limit_exceeded: Subscription quota exhausted. Your usage window resets at 2026-10-13T10:45:52Z.) (after 10 provider attempts)"

    @Test func reportsBecomeTheComposersWindows() throws {
        let report = try json(
            #"{"observedAtMs":1791447762610,"tier":"tier-1","window":{"usedPercent":103,"windowDurationMins":300,"resetsAtMs":1791465557000},"weekly":{"usedPercent":5,"resetsAtMs":1791763200000}}"#)
        let windows = try #require(MuseSubscriptionUsage(report)).windows
        #expect(windows.map(\.id) == ["window", "weekly"])
        #expect(windows.map(\.kind) == [.session, .weekly])
        #expect(windows.map(\.usedPercent) == [100, 5])
        #expect(windows[0].durationMinutes == 300)
        #expect(windows[0].resetsAt == Date(timeIntervalSince1970: 1_791_465_557))
        // Unreadable reports are skipped, as T3's schema rejects them.
        #expect(MuseSubscriptionUsage(["window": "not usage"]) == nil)
        let tooLate = try json(report.compactJSON.replacingOccurrences(of: "1791465557000", with: "1e16"))
        #expect(MuseSubscriptionUsage(tooLate) == nil)
    }

    @Test func recognizesMetasQuotaRefusalAndNoOtherFailure() {
        #expect(MuseUsageLimits.isUsageLimitFailure(
            "API error 429: Subscription quota exhausted. Your usage window resets soon. (rate_limit_error)"))
        #expect(MuseUsageLimits.isUsageLimitFailure(relayed))
        #expect(!MuseUsageLimits.isUsageLimitFailure("API error 429: Rate limit exceeded. (rate_limit_error)"))
        #expect(!MuseUsageLimits.isUsageLimitFailure("Subscription quota exhausted."))
        #expect(!MuseUsageLimits.isUsageLimitFailure(nil))
    }

    @Test func workResumesOnceEveryExhaustedWindowHasReset() {
        var sessionOut = usage
        sessionOut.window.usedPercent = 103
        #expect(MuseUsageLimits.resetDate(usage: sessionOut, now: now, quotaReset: nil, message: nil) == usage.window.resetsAt)
        var bothOut = sessionOut
        bothOut.weekly.usedPercent = 100
        #expect(MuseUsageLimits.resetDate(usage: bothOut, now: now, quotaReset: nil, message: nil) == usage.weekly.resetsAt)
    }

    @Test func aRefusalsNamedOrTypedResetCounts() {
        let named = MuseUsageLimits.resetDate(usage: nil, now: now, quotaReset: nil, message: relayed)
        #expect(named == ISO8601DateFormatter().date(from: "2026-10-13T10:45:52Z"))
        #expect(MuseUsageLimits.resetDate(usage: usage, now: now, quotaReset: usage.window.resetsAt, message: nil) == usage.window.resetsAt)
        var weeklyOut = usage
        weeklyOut.weekly.usedPercent = 100
        #expect(
            MuseUsageLimits.resetDate(usage: weeklyOut, now: now, quotaReset: usage.window.resetsAt, message: nil)
                == usage.weekly.resetsAt)
    }

    @Test func noResetUnlessAUsedUpWindowResetsLater() {
        #expect(MuseUsageLimits.resetDate(usage: nil, now: now, quotaReset: nil, message: nil) == nil)
        #expect(MuseUsageLimits.resetDate(usage: usage, now: now, quotaReset: nil, message: nil) == nil)
        var sessionOut = usage
        sessionOut.window.usedPercent = 100
        #expect(MuseUsageLimits.resetDate(usage: sessionOut, now: usage.window.resetsAt, quotaReset: nil, message: nil) == nil)
        let later = ISO8601DateFormatter().date(from: "2026-10-14T00:00:00Z")!
        #expect(MuseUsageLimits.resetDate(usage: nil, now: later, quotaReset: nil, message: relayed) == nil)
    }

    @Test func quotaStopsSayWhenTheyLift() {
        let reset = Date(timeIntervalSince1970: 1_791_465_557)
        let message = MuseUsageLimits.failureMessage(detail: "API error 429: quota", resetsAt: reset)
        #expect(message.contains(reset.formatted(date: .abbreviated, time: .shortened)))
        #expect(message.hasSuffix("\n\nAPI error 429: quota"))
        #expect(MuseUsageLimits.failureMessage(detail: nil, resetsAt: nil) == "Muse Code usage limit reached. Try again later.")
    }
}

// MARK: - Presentation

struct MusePresentationTests {
    private let presentation = MusePresentation(workingDirectory: "/work")

    @Test func editsShowTheirFileAndExactChange() throws {
        let edit = try #require(item([
            "tool": "edit_file",
            "args": args(["file_path": "/work/src/index.ts", "old_string": "old\n", "new_string": "new\n"]),
        ]))
        let tool = presentation.tool(edit)
        #expect(tool.info.category == .fileChange)
        #expect(tool.info.title == "Edit src/index.ts")
        #expect(tool.info.detail == "--- a/src/index.ts\n+++ b/src/index.ts\n@@ -1,1 +1,1 @@\n-old\n+new")
        #expect(tool.status == .completed)
    }

    @Test func writesAndProviderPatchesAreDiffsToo() throws {
        let write = try #require(item(["tool": "write_file", "args": args(["path": "README.md", "content": "Hello\n"])]))
        #expect(presentation.tool(write).info.title == "Write README.md")
        #expect(presentation.tool(write).info.detail == "--- /dev/null\n+++ b/README.md\n@@ -0,0 +1,1 @@\n+Hello")
        let patch = try #require(item([
            "tool": "apply_patch", "args": args(["path": "README.md", "patch": "@@ -1 +1 @@\n-old\n+new"]),
        ]))
        #expect(presentation.tool(patch).info.detail == "--- a/README.md\n+++ b/README.md\n@@ -1 +1 @@\n-old\n+new\n")
    }

    @Test(arguments: ["rejected", "timedOut", "handedOff"])
    func nativeEndsOtherThanCompletingAreFailures(status: String) throws {
        let native = try #require(item(["tool": "search_files", "status": .string(status), "fallbackText": "Native explanation"]))
        #expect(MusePresentation.status(native) == .failed)
        #expect(presentation.tool(native).status == .failed)
        #expect(presentation.tool(native).output == "Muse reported \(status).\nNative explanation")
    }

    @Test func webSearchesListTheirHitsAndFetchesTheirPage() throws {
        let output: JSONValue = [
            "query": "node lts",
            "results": [
                ["url": "https://nodejs.org/", "title": "Node.js", "snippet": "Node 24 is LTS", "extra": 1],
                ["url": "", "title": "", "snippet": "No link"],
            ],
        ]
        let search = try #require(item([
            "tool": "web_search", "args": args(["query": "node lts"]), "visibleOutput": .string(output.compactJSON),
        ]))
        let tool = presentation.tool(search)
        #expect(tool.info.category == .web)
        #expect(tool.info.title == "Search the web for “node lts”")
        #expect(tool.output == "Node.js — https://nodejs.org/\nNo link")
        let fetch = try #require(item([
            "tool": "web_fetch", "args": args(["url": "https://nodejs.org/en/about"]), "visibleOutput": "About Node.js",
        ]))
        #expect(presentation.tool(fetch).info.title == "Fetch https://nodejs.org/en/about")
        #expect(presentation.tool(fetch).output == "About Node.js")
    }

    @Test func shellCommandsShowWhatRanAndHowItEnded() throws {
        // Muse's bash tool reports a JSON envelope (from the recorded permission scenario).
        let envelope: JSONValue = ["command": "make", "exit_code": 2, "output": "make: *** No rule\n", "truncated": false]
        let failed = try #require(item([
            "tool": "bash", "args": args(["command": "make", "description": "Build"]),
            "visibleOutput": .string(envelope.compactJSON),
        ]))
        let tool = presentation.tool(failed)
        #expect(tool.info.category == .command)
        #expect(tool.info.title == "Run `make`")
        #expect(tool.status == .failed)
        #expect(tool.output == "make: *** No rule\nExit code 2")
        let shell = try #require(item(["kind": "userShell", "commandText": "ls", "exitCode": 0, "visibleOutput": "a\nb"]))
        #expect(presentation.tool(shell).status == .completed)
        #expect(presentation.tool(shell).output == "a\nb")
    }

    @Test func otherToolsGetCoincidesTitles() throws {
        let read = try #require(item(["tool": "read_file", "args": args(["path": "/work/Package.swift"])]))
        #expect(presentation.tool(read).info.category == .read)
        #expect(presentation.tool(read).info.title == "Read Package.swift")
        let grep = try #require(item(["tool": "grep", "args": args(["pattern": "TODO", "path": "/work/Sources"])]))
        #expect(presentation.tool(grep).info.title == "Search for “TODO” in Sources")
        let spawn = try #require(item(["tool": "subagent_spawn", "args": args(["objective": "Check"])]))
        #expect(presentation.tool(spawn).info.category == .task)
        #expect(presentation.tool(spawn).info.title == "Start a subagent")
        let mcp = try #require(item(["tool": "github__create_issue", "args": "{\"title\":"]))
        #expect(presentation.tool(mcp).info.category == .mcp)
        #expect(presentation.tool(mcp).info.detail == "{\"title\":")
        let unknown = try #require(MuseItem(["itemId": "h", "kind": "hookRun", "revision": 1, "status": "completed", "fallbackText": "Ran the format hook"]))
        #expect(presentation.tool(unknown).info.title == "Ran the format hook")
    }

    @Test func subagentsShowTheirObjectiveAndResultOnceReady() throws {
        let running = try #require(item([
            "kind": "subagent", "status": "inProgress", "objective": "Check the thing", "role": "general-purpose",
            "controlStatus": "running",
        ]))
        #expect(MusePresentation.status(running) == .running)
        #expect(presentation.tool(running).info.title == "Subagent: Check the thing")
        // T3 counts a subagent whose result is ready as done, though Muse keeps the item open.
        let ready = try #require(item([
            "kind": "subagent", "status": "inProgress", "objective": "Check the thing", "controlStatus": "resultReady",
            "result": ["summary": "All done"],
        ]))
        #expect(MusePresentation.status(ready) == .completed)
        #expect(presentation.tool(ready).output == "All done")
    }

    @Test func workflowAgentsListWithTheirFirstLabelAndFailureKind() throws {
        var mapper = MuseEventMapper(workingDirectory: "/work")
        func workflow(_ revision: Int, _ children: JSONValue, status: String = "inProgress") -> MuseItem? {
            MuseItem(["itemId": "wf-1", "kind": "workflow", "revision": .number(Double(revision)), "status": .string(status), "turnId": "t", "entryId": "Probe workflow", "children": children])
        }
        let started = mapper.apply(try #require(workflow(1, [["childId": "c1", "attempt": 1, "status": "scheduled", "label": "ping"]])))
        #expect(started == [.toolStarted(ToolCallInfo(id: "wf-1", category: .task, title: "Workflow: Probe workflow", detail: "• ping"))])
        // A later revision drops the label; the first one stays.
        let running = mapper.apply(try #require(workflow(2, [
            ["childId": "c1", "attempt": 1, "status": "started"],
            ["childId": "c2", "attempt": 1, "status": "finished", "terminal": "completed", "failureKind": "budget_exhausted"],
        ])))
        #expect(running == [.toolUpdated(ToolCallInfo(id: "wf-1", category: .task, title: "Workflow: Probe workflow", detail: "• ping\n✗ Agent 2: budget_exhausted"))])
        let done = mapper.apply(try #require(workflow(3, [["childId": "c1", "attempt": 1, "status": "terminal", "terminal": "completed"]], status: "completed")))
        #expect(done.last == .toolCompleted(id: "wf-1", status: .completed, output: nil))
    }

    @Test func todosBecomeAChecklistWithoutCancelledOrEmptySteps() {
        let markdown = MusePresentation.todoMarkdown([
            "items": [
                ["text": " Investigate ", "status": "completed"], ["text": "Fix", "status": "inProgress"],
                ["text": "Discarded", "status": "cancelled"], ["text": "  ", "status": "pending"], ["text": "Ship", "status": "pending"],
            ],
        ])
        #expect(markdown == "- [x] Investigate\n- [ ] Fix _(in progress)_\n- [ ] Ship")
        #expect(MusePresentation.todoMarkdown(["items": [["text": "x", "status": "cancelled"]]]) == nil)
    }
}

// MARK: - Approvals and questions

struct MuseApprovalTests {
    private let presentation = MusePresentation(workingDirectory: "/work")

    private func approval(choices: JSONValue, subject: JSONValue = ["kind": "shell", "command": "touch result.txt"]) throws
        -> MuseApproval
    {
        try #require(MuseApproval([
            "approvalId": "approval-1", "sessionId": "s", "turnId": "t",
            "currentRequirementId": ["approvalId": "approval-1", "sourceIndex": 0], "availableChoices": choices,
            "subject": subject,
        ]))
    }

    @Test func deniedAndAbortStaySeparateWhenMuseOffersBoth() throws {
        let choices = try approval(choices: [
            ["choiceId": "deny", "label": "Deny", "decision": "denied", "scope": "once"],
            ["choiceId": "abort", "label": "Stop", "decision": "abort", "scope": "once"],
        ]).choicesByDecision
        #expect(choices[.decline]?.id == "deny")
        #expect(choices[.cancel]?.id == "abort")
    }

    @Test func recordedShellApprovalOffersOnceAlwaysAndReject() throws {
        let line = try #require(MuseFixtures.permission.first { $0.contains(#""method":"approval/requested""#) })
        let params = try #require(try json(line)["params"])
        let approval = try #require(MuseApproval(params))
        // Shell approvals offer abort instead of denied, so it also stands in for declining, shown once.
        #expect(approval.options == [
            ApprovalOption(id: "allow_once", label: "Allow once", kind: .allowOnce),
            ApprovalOption(id: "allow_local_prefix", label: "Always allow in this workspace: touch ...", kind: .allowAlways),
            ApprovalOption(id: "abort", label: "Reject", kind: .deny),
        ])
        let request = approval.request(id: approval.id, presentation: presentation)
        #expect(request.category == .command)
        #expect(request.title == "Run `touch muse-approved.txt`")
        #expect(request.detail == "touch muse-approved.txt")
    }

    @Test func policyAmendmentsMapByScopeAndTheNarrowestChoiceWins() throws {
        let approval = try approval(choices: [
            ["choiceId": "session", "label": "", "decision": "approvedPolicyAmendment", "scope": "session"],
            ["choiceId": "for-session", "label": "For this session", "decision": "approvedForSession", "scope": "session"],
            ["choiceId": "elsewhere", "label": "Somewhere", "decision": "approvedPolicyAmendment", "scope": "remote"],
            ["choiceId": "deny-rule", "label": "Never", "decision": "deniedPolicyAmendment", "scope": "localPersistent"],
            ["choiceId": "deny", "label": "Deny once", "decision": "denied", "scope": "once"],
        ])
        #expect(approval.options.map(\.id) == ["for-session", "deny"])
        #expect(approval.options.map(\.kind) == [.allowAlways, .deny])
    }

    @Test func fileAndChildApprovalsSayWhatTheyAreAbout() throws {
        var read = try approval(choices: [], subject: ["kind": "fileAccess", "access": "read", "path": "/work/.env"])
        #expect(read.request(id: "x", presentation: presentation).title == "Read .env")
        #expect(read.request(id: "x", presentation: presentation).category == .read)
        read.subagentID = "child"
        #expect(read.request(id: "x", presentation: presentation).title == "Subagent: Read .env")
        let write = try approval(choices: [], subject: ["kind": "fileAccess", "access": "write", "path": "/work/a.txt"])
        #expect(write.request(id: "x", presentation: presentation).title == "Edit a.txt")
        let other = try approval(choices: [], subject: ["kind": "network"])
        #expect(other.request(id: "x", presentation: presentation).title == "Muse Code asks for permission")
    }

    private func question(_ mode: String = "single", max: Int? = nil) throws -> MuseUserInput {
        var selection: [String: JSONValue] = ["mode": .string(mode)]
        if let max { selection["maxSelections"] = .number(Double(max)) }
        return try #require(MuseUserInput([
            "userInputId": "question-1", "sessionId": "s", "turnId": "t",
            "questions": [
                [
                    "id": "approach", "header": "Approach", "question": "Which approach?",
                    "options": [["label": "Small", "description": "Less code"], ["label": "Large"]], "selection": .object(selection),
                ],
            ],
        ]))
    }

    @Test func questionsKeepTheirOptionsAndAllowTypedAnswers() throws {
        let request = try question().request
        #expect(request.id == "question-1")
        #expect(request.questions == [
            UserQuestion(
                id: "approach", header: "Approach", prompt: "Which approach?",
                options: [.init(label: "Small", detail: "Less code"), .init(label: "Large")], allowsMultipleSelection: false,
                allowsFreeText: true),
        ])
    }

    @Test func answersCarryChosenLabelsWithTypedTextAsANote() throws {
        #expect(try question().answers(["approach": ["Small", "Keep tests focused"]])
            == [["questionId": "approach", "selectedLabel": "Small", "note": "Keep tests focused"]])
        #expect(try question().answers(["approach": ["Something else"]]) == [["questionId": "approach", "freeText": "Something else"]])
        #expect(try question("multiple", max: 1).answers(["approach": ["Small", "Large"]])
            == [["questionId": "approach", "selectedLabels": ["Small"]]])
        let long = String(repeating: "a", count: 600)
        #expect(try question().answers(["approach": [long]])?[0]?["freeText"]?.string?.count == MuseUserInput.freeTextLimit)
        #expect(try question().answers([:]) == nil)
    }
}

// MARK: - Mapper

struct MuseEventMapperTests {
    /// Feeds recorded notifications and collects what they produce.
    private func replay(_ lines: [String], into mapper: inout MuseEventMapper) throws -> [AgentEvent] {
        var events: [AgentEvent] = []
        for line in lines {
            let frame = try json(line)
            switch frame["method"]?.string {
            case "item/started", "item/updated", "item/completed":
                events += mapper.apply(try #require(MuseItem(frame.at("params.item"))))
            case "item/delta":
                let params = try #require(frame["params"])
                events += mapper.delta(
                    itemID: params["itemId"]?.string ?? "", field: params["field"]?.string ?? "text",
                    delta: params["delta"]?.string ?? "")
            default:
                break
            }
        }
        return events
    }

    @Test func recordedAnswerStreamsThenSettlesWithoutRemindersOrTheUsersMessage() throws {
        var mapper = MuseEventMapper(workingDirectory: "/work")
        let events = try replay(MuseFixtures.simple, into: &mapper)
        #expect(events == [
            .assistantTextDelta(itemID: "0a68e576-f554-4700-8853-a68ad2b7179b", delta: "fixture simple ok"),
            .assistantText(itemID: "0a68e576-f554-4700-8853-a68ad2b7179b", text: "fixture simple ok"),
        ])
    }

    @Test func recordedWorkflowReasoningJoinsItsSummaryParts() throws {
        var mapper = MuseEventMapper(workingDirectory: "/work")
        let events = try replay(Array(MuseFixtures.workflow.prefix(8)), into: &mapper)
        let first = "Launching a two-agent ping-pong workflow via the workflow tool while skipping skill reading for a trivial task."
        let second = "Resolving the conflict between explicit workflow request and skill-skip rule to call the workflow tool first."
        #expect(events == [
            .reasoningDelta(itemID: "3ce724bc-dacf-400e-af9a-995104717cb1", delta: first),
            .reasoningDelta(itemID: "3ce724bc-dacf-400e-af9a-995104717cb1", delta: "\n" + second),
            .reasoningText(itemID: "3ce724bc-dacf-400e-af9a-995104717cb1", text: first + "\n" + second),
        ])
    }

    @Test func olderRevisionsAndDeltasOfSettledItemsChangeNothing() throws {
        var mapper = MuseEventMapper(workingDirectory: "/work")
        let newer = try #require(MuseItem(["itemId": "m", "kind": "agentMessage", "revision": 2, "status": "completed", "text": "final"]))
        let older = try #require(MuseItem(["itemId": "m", "kind": "agentMessage", "revision": 1, "status": "inProgress", "text": "fi"]))
        #expect(mapper.apply(newer) == [.assistantText(itemID: "m", text: "final")])
        #expect(mapper.apply(older).isEmpty)
        #expect(mapper.delta(itemID: "m", field: "text", delta: "!").isEmpty)
        #expect(mapper.delta(itemID: "unknown", field: "text", delta: "!").isEmpty)
    }

    @Test func toolsStartStreamAndCompleteOnce() throws {
        var mapper = MuseEventMapper(workingDirectory: "/work")
        let running = try #require(MuseItem(["itemId": "t", "kind": "toolCall", "revision": 1, "status": "inProgress", "tool": "read_file", "args": args(["path": "/work/a"])]))
        let done = try #require(MuseItem(["itemId": "t", "kind": "toolCall", "revision": 2, "status": "completed", "tool": "read_file", "args": args(["path": "/work/a"]), "visibleOutput": "contents"]))
        let info = ToolCallInfo(id: "t", category: .read, title: "Read a", detail: args(["path": "/work/a"]).string.flatMap { JSONValue.parse($0)?.prettyJSON })
        #expect(mapper.apply(running) == [.toolStarted(info)])
        #expect(mapper.delta(itemID: "t", field: "output", delta: "con") == [.toolOutput(id: "t", delta: "con")])
        #expect(mapper.apply(done) == [.toolCompleted(id: "t", status: .completed, output: "contents")])
        var repeated = done
        repeated.revision = 3
        #expect(mapper.apply(repeated).isEmpty)
    }

    @Test func todoAndQuestionToolsShowOnlyWhenTheyFail() throws {
        var mapper = MuseEventMapper(workingDirectory: "/work")
        let todo = try #require(MuseItem(["itemId": "todo", "kind": "toolCall", "revision": 1, "status": "completed", "tool": "write_todos"]))
        #expect(mapper.apply(todo).isEmpty)
        let failed = try #require(MuseItem(["itemId": "ask", "kind": "toolCall", "revision": 1, "status": "failed", "tool": "request_user_input", "failureReason": "No answer"]))
        #expect(mapper.apply(failed).last == .toolCompleted(id: "ask", status: .failed, output: "No answer"))
    }

    @Test func runningSubagentsAndWorkflowsOutliveTheirTurn() throws {
        var mapper = MuseEventMapper(workingDirectory: "/work")
        let tool = try #require(MuseItem(["itemId": "t", "kind": "toolCall", "revision": 1, "status": "inProgress", "tool": "bash"]))
        let agent = try #require(MuseItem(["itemId": "a", "kind": "subagent", "revision": 1, "status": "inProgress", "objective": "Look"]))
        _ = mapper.apply(tool)
        _ = mapper.apply(agent)
        mapper.endTurn()
        #expect(mapper.isBackground("a"))
        #expect(!mapper.isBackground("t"))
        var done = agent
        done.revision = 2
        done.status = "completed"
        done.result = "Found it"
        #expect(mapper.apply(done) == [.toolCompleted(id: "a", status: .completed, output: "Found it")])
        #expect(!mapper.isBackground("a"))
    }
}

// MARK: - Provider

@MainActor
struct MuseProviderTests {
    private let executable = URL(fileURLWithPath: "/opt/muse/bin/muse")

    private func provider(
        version: ProcessRunner.Result = .init(status: 0, stdout: "muse 1.0.3-R2198.1\n", stderr: ""),
        catalog: JSONValue = ["providerId": "meta", "models": [["modelId": "muse-wonder-1.0", "displayLabel": "muse-wonder-1.0", "providerId": "meta", "isDefault": true], ["modelId": "foreign-model", "displayLabel": "Other", "providerId": "another", "isDefault": false]]],
        usage: JSONValue = [:]
    ) -> (MuseProvider, () -> [FakeMuseTransport]) {
        var transports: [FakeMuseTransport] = []
        let provider = MuseProvider(
            probeVersion: { _, _ in version },
            probeTransport: { _, _ in
                let transport = FakeMuseTransport()
                transport.handlers["model/list"] = { _ in .result(catalog) }
                transport.handlers["usage/read"] = { _ in .result(usage) }
                transports.append(transport)
                return transport
            })
        return (provider, { transports })
    }

    @Test func museIsOffUntilTurnedOnAndAddedToTheRegistry() {
        #expect(!AppSettings().settings(for: .muse).isEnabled)
        #expect(AppSettings().settings(for: .codex).isEnabled)
        #expect(ProviderKind.muse.displayName == "Muse Code")
        #expect(ProviderRegistry.builtInProviders().contains { $0.kind == .muse })
    }

    @Test func aFoundCatalogIsReadyWithoutClaimingASignIn() async throws {
        let usage: JSONValue = ["usage": ["observedAtMs": 1, "tier": "tier-1", "window": ["usedPercent": 20, "windowDurationMins": 300, "resetsAtMs": 1_791_465_557_000], "weekly": ["usedPercent": 5, "resetsAtMs": 1_791_763_200_000]]]
        let (provider, transports) = provider(usage: usage)
        let status = await provider.detect(executable: executable, environment: ["PATH": "/bin"])
        #expect(status.state == .ready)
        #expect(status.version == "1.0.3-R2198.1")
        #expect(status.message == nil)
        #expect(status.account == nil)
        #expect(status.usageLimits?.windows.map(\.usedPercent) == [20, 5])
        let models = await provider.models(status: status, environment: [:])
        #expect(models.map(\.modelID) == ["muse-wonder-1.0"])
        #expect(models.first?.displayName == "Muse Wonder 1.0")
        // One read-only host served both, and it only answered queries (no commands) before it was closed.
        let host = try #require(transports().first)
        #expect(transports().count == 1)
        #expect(host.isClosed)
        #expect(host.sent.compactMap { $0["method"]?.string } == ["initialize", "initialized", "model/list", "usage/read"])
        #expect(host.sent.allSatisfy { $0.at("params.commandId") == nil })
    }

    @Test func aFailedVersionCheckShowsNoCLIOutputAndStartsNoHost() async {
        let (provider, transports) = provider(version: .init(status: 2, stdout: "", stderr: "secret-test-value"))
        let status = await provider.detect(executable: executable, environment: [:])
        #expect(status.state == .error)
        #expect(status.message?.contains("secret-test-value") == false)
        #expect(transports().isEmpty)
    }

    @Test func anEmptyCatalogStaysEmptyAndAsksForASignIn() async {
        let (provider, _) = provider(catalog: ["providerId": "meta", "models": []])
        let status = await provider.detect(executable: executable, environment: [:])
        #expect(status.state == .notAuthenticated)
        #expect(status.message?.contains("muse login") == true)
        #expect(await provider.models(status: status, environment: [:]).isEmpty)
    }

    @Test func anUnreadableCatalogIsAnError() async {
        let (provider, _) = provider(catalog: ["providerId": "another", "models": []])
        #expect(await provider.detect(executable: executable, environment: [:]).state == .error)
        #expect(await provider.detect(executable: nil, environment: [:]).state == .notInstalled)
    }

    @Test func theLoginShellsAPIKeyIsDroppedButOneSetForMuseApplies() async {
        let shell = ShellEnvironment(resolve: { ["PATH": "/bin", "META_API_KEY": "from-shell"] })
        let store = AppStore(directory: FileManager.default.temporaryDirectory.appendingPathComponent("coincide-muse-\(UUID().uuidString)"))
        let registry = ProviderRegistry(store: store, providers: [MuseProvider(), CodexProvider()], shell: shell)
        let inherited = await registry.environment(for: .muse)
        #expect(inherited["META_API_KEY"] == nil)
        #expect(inherited["MUSE_NO_AUTO_UPDATE"] == "1")
        #expect(await registry.environment(for: .codex)["META_API_KEY"] == "from-shell")
        store.updateSettings { $0.providers[.muse] = ProviderSettings(isEnabled: true, environment: ["META_API_KEY": "for-muse"]) }
        #expect(await registry.environment(for: .muse)["META_API_KEY"] == "for-muse")
    }
}
