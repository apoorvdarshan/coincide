import Foundation
import Testing
@testable import CoincideCore

@Test func contextHandoffOpenCodeV1KeepsHistorySeparateFromLiteralInput() async throws {
    try await withV1Session { fixture in
        let input = try contextHandoffTestInput()
        #expect(try await fixture.session.contextInputDisposition(input: .init(text: "/tmp/foo"), thread: fixture.thread()) == .ordinary)
        #expect(try await fixture.session.contextInputDisposition(input: .init(text: "/review"), thread: fixture.thread()) == .nativeCommand)
        try await fixture.session.send(input: input, thread: fixture.thread())
        let calls = await fixture.peer.calls
        let prompt = try #require(calls.first { $0.path.last == "prompt_async" }?.body)
        let text = prompt["parts"].array?.compactMap { $0["text"].string }
        #expect(text == (try input.providerTextBlocks()))
        #expect(text?.last?.utf8.elementsEqual(input.text.utf8) == true)
        try await fixture.peer.begin(); try await fixture.peer.idle()
        try await v1Eventually { await fixture.record.completions == [.idle] }
    }
}

@Test func openCodeV1CatalogSharesOneConnectionWithoutCreatingAConversation() async throws {
    try await withV1Session { f in
        async let models = f.session.models()
        async let inventory = f.session.openCodeInventory()
        let (rows, observed) = try await (models, inventory)
        #expect(rows.first?.openCodeSelection == f.model)
        #expect(rows.first?.openCodeVariants == ["balanced", "fast"])
        #expect(observed.server.generation == .v1)
        let connects = await f.peer.connects, calls = await f.peer.calls
        #expect(connects == 1)
        #expect(calls.isEmpty)
    }
}

@Test func openCodeV1HTTPAdmissionAndAssistantCompletionDoNotCompleteBeforeIdle() async throws {
    try await withV1Session { f in
        try await f.session.send(text: "Exact input", thread: f.thread())
        try await f.peer.begin()
        try await f.peer.text("first 🌍")
        try await f.peer.delta(" + next", part: "part_text")
        try await f.peer.assistant(completed: true)
        try await v1Eventually { await f.record.text.contains("first 🌍 + next") }
        let before = await f.record.completions
        #expect(before.isEmpty)
        try await f.peer.idle()
        try await v1Eventually { await f.record.completions == [.idle] }
        try await f.peer.idle()
        let final = await f.record.completions
        #expect(final == [.idle])
        let calls = await f.peer.calls
        let prompt = try #require(calls.first { $0.path.last == "prompt_async" }?.body)
        #expect(prompt["messageID"].string?.hasPrefix("msg_") == true)
        #expect(prompt["parts"].array?.first?["text"] == .string("Exact input"))
        #expect(prompt["model"]["modelID"] == .string(f.model.id))
        #expect(prompt["id"] == .null)
    }
}

@Test func openCodeV1EarlyIdleAndUnrelatedUserCannotReleaseTheNewRun() async throws {
    try await withV1Session { f in
        try await f.session.send(text: "Owned input", thread: f.thread())
        try await f.peer.idle()
        try await f.peer.user(id: "msg_stale_other_user")
        try await f.peer.assistant(id: "msg_unowned", parent: "msg_stale_other_user", completed: true)
        try await f.peer.text("must not appear", assistant: "msg_unowned")
        try await f.peer.begin()
        try await v1Eventually { await f.record.turns.count == 1 }
        let before = await f.record.completions, text = await f.record.text
        #expect(before.isEmpty)
        #expect(!text.contains("must not appear"))
        try await f.peer.text("owned")
        try await f.peer.idle()
        try await v1Eventually { await f.record.completions == [.idle] }
    }
}

@Test func openCodeV1CapturedDefaultOmitsModelAndVariantInsteadOfGuessingAProviderDefault() async throws {
    try await withV1Session { f in
        var thread = f.thread()
        thread.openCodeConfiguration = f.configuration.selecting(model: nil); thread.model = ""
        thread.activeRun = .init(id: UUID(), configuration: .init(thread: thread), startedAt: Date())
        // A future explicit header choice must not replace the captured native default.
        thread.openCodeConfiguration = f.configuration; thread.model = f.model.catalogID
        try await f.session.send(text: "Native default", thread: thread)
        let calls = await f.peer.calls
        let prompt = try #require(calls.first { $0.path.last == "prompt_async" }?.body)
        #expect(prompt["model"] == .null && prompt["variant"] == .null)
        #expect(prompt["agent"] == .string("build"))
        try await f.peer.begin(); try await f.peer.idle()
        try await v1Eventually { await f.record.completions == [.idle] }
    }
}

@Test(arguments: [false, true])
func openCodeV1ObservedCompletionBeforeHeldHTTPAckPreservesSuccessor(_ lost: Bool) async throws {
    try await withV1Session(mode: lost ? .heldLostAck : .heldAck) { f in
        let first = f.thread()
        let send = Task { try await f.session.send(text: "First", thread: first) }
        do {
            try await v1Eventually { await f.peer.promptCount == 1 }
            try await f.peer.begin()
            try await f.peer.assistant(completed: true)
            try await f.peer.idle()
            try await v1Eventually { await f.record.completions == [.idle] }
            await f.peer.setMode(.manual)
            try await f.session.send(text: "Second", thread: f.thread(nativeID: "ses_root"))
            try await f.peer.begin(assistant: "msg_second")
            await f.peer.release()
            try await send.value
            try await f.peer.text("successor", assistant: "msg_second")
            try await f.peer.idle()
            try await v1Eventually { await f.record.completions == [.idle, .idle] }
            let failures = await f.record.failures, starts = await f.peer.promptCount
            #expect(failures == 0)
            #expect(starts == 2)
        } catch { await f.peer.release(); _ = await send.result; throw error }
    }
}

@Test func openCodeV1CapturedControlsAndExactResumeDoNotCreateANewSession() async throws {
    try await withV1Session { f in
        var thread = f.thread()
        thread.openCodeConfiguration = f.configuration.selecting(model: .init(providerID: f.model.providerID, id: f.model.id, variant: "fast"))
        thread.permission = .fullAccess
        try await f.session.send(text: "Captured", thread: thread)
        try await f.peer.begin(); try await f.peer.idle()
        try await v1Eventually { await f.record.completions.count == 1 }
        var next = f.thread(nativeID: "ses_root")
        next.openCodeConfiguration = thread.openCodeConfiguration; next.permission = .fullAccess
        next.activeRun = .init(id: UUID(), configuration: .init(thread: next), startedAt: Date())
        try await f.session.send(text: "Future captured", thread: next)
        let calls = await f.peer.calls
        let prompts = calls.filter { $0.path.last == "prompt_async" }
        #expect(prompts[0].body?["variant"] == .string("balanced"))
        #expect(prompts[1].body?["variant"] == .string("fast"))
        let create = calls.filter { $0.method == "POST" && $0.path == ["session"] }
        #expect(create.count == 1)
        #expect(create.first?.body?["title"] == .null)
        #expect(create.first?.body?["id"] == .null)
        let patches = calls.filter { $0.method == "PATCH" }
        #expect(patches[0].body?["permission"].array?.contains(.object(["permission": .string("bash"), "pattern": .string("*"), "action": .string("ask")])) == true)
        #expect(patches.last?.body?["permission"].array?.first?["action"] == .string("allow"))
    }
}

@Test(arguments: ["missing", "wrong-cwd", "child", "reverted"])
func openCodeV1ResumeNeverCreatesOrMovesAnUnverifiedConversation(_ fault: String) async throws {
    try await withV1Session { f in
        await f.peer.seed(fault: fault)
        do {
            try await f.session.send(text: "Not a fallback", thread: f.thread(nativeID: "ses_existing"))
            Issue.record("An unverified native conversation was resumed.")
        } catch { }
        let calls = await f.peer.calls
        #expect(calls.allSatisfy { $0.method != "POST" || $0.path != ["session"] })
        #expect(calls.allSatisfy { $0.path.last != "prompt_async" })
    }
}

@Test(arguments: [PermissionMode.supervised, .fullAccess])
func openCodeV1PlanRulesKeepLastMatchingDenyAndNarrowAllowAcrossFutureHeader(_ permission: PermissionMode) async throws {
    try await withV1Session { f in
        await f.peer.setAgentRules([
            .init(permission: "edit", pattern: "/plans/*", action: "allow"),
            .init(permission: "external_directory", pattern: "/plans/*", action: "allow"),
            .init(permission: "bash", pattern: "git *", action: "allow"),
            .init(permission: "task", pattern: "*", action: "deny")
        ])
        var captured = f.thread()
        captured.permission = permission
        captured.openCodeConfiguration = f.configuration.selecting(agentID: "plan")
        captured.activeRun = .init(id: UUID(), configuration: .init(thread: captured), startedAt: Date())
        // A future header edit must not remove this accepted plan's restrictions.
        captured.openCodeConfiguration = f.configuration
        captured.permission = permission == .supervised ? .fullAccess : .supervised
        try await f.session.send(text: "Captured planning controls", thread: captured)
        let firstCalls = await f.peer.calls
        let firstPatch = try #require(firstCalls.first { $0.method == "PATCH" }?.body?["permission"].array)
        func action(_ rules: [JSONValue], permission: String, path: String) -> String? {
            rules.last {
                ($0["permission"] == .string(permission) || $0["permission"] == .string("*")) &&
                ($0["pattern"] == .string("*") || ($0["pattern"] == .string("/plans/*") && path.hasPrefix("/plans/")))
            }?["action"].string
        }
        #expect(action(firstPatch, permission: "edit", path: "/repository/source.swift") == "deny")
        #expect(action(firstPatch, permission: "edit", path: "/plans/approved.md") == "allow")
        #expect(action(firstPatch, permission: "external_directory", path: "/plans/approved.md") == "allow")
        #expect(!firstPatch.contains(.object(["permission": .string("bash"), "pattern": .string("git *"), "action": .string("allow")])))
        try await f.peer.begin(); try await f.peer.idle()
        try await v1Eventually { await f.record.completions == [.idle] }
        var next = f.thread(nativeID: "ses_root")
        next.permission = permission; next.openCodeConfiguration = f.configuration.selecting(agentID: "plan")
        next.activeRun = .init(id: UUID(), configuration: .init(thread: next), startedAt: Date())
        try await f.session.send(text: "A newly captured plan", thread: next)
        let laterCalls = await f.peer.calls
        let lastPatch = try #require(laterCalls.last { $0.method == "PATCH" }?.body?["permission"].array)
        #expect(action(lastPatch, permission: "edit", path: "/repository/source.swift") == "deny")
        #expect(action(lastPatch, permission: "edit", path: "/plans/approved.md") == "allow")
    }
}

@Test(arguments: [V1Fault.lostCreate, .lostPrompt, .rejectedPrompt])
func openCodeV1LostMutationIsNotRetriedOrMistakenForKnownRejection(_ mode: V1Fault) async throws {
    try await withV1Session(mode: mode) { f in
        var observed: OpenCodeV1SessionError?
        do { try await f.session.send(text: "Once", thread: f.thread()) }
        catch { observed = error as? OpenCodeV1SessionError }
        #expect(observed == (mode == .rejectedPrompt ? .rejected : .uncertainDelivery))
        let calls = await f.peer.calls
        #expect(calls.filter { $0.method == "POST" && $0.path == ["session"] }.count == 1)
        #expect(calls.filter { $0.path.last == "prompt_async" }.count == (mode == .lostCreate ? 0 : 1))
        #expect(calls.allSatisfy { $0.path != ["session", "ses_guessed"] })
    }
}

@Test func openCodeV1StopDuringHeldConfigurationPreventsEveryLatePrompt() async throws {
    try await withV1Session(mode: .heldConfiguration) { f in
        let send = Task { try await f.session.send(text: "Must stay unsent", thread: f.thread()) }
        do {
            try await v1Eventually { await f.peer.configurationHeld }
            try await f.session.interrupt()
            await f.peer.release()
            let result = await send.result
            if case .success = result { Issue.record("A stopped preparation submitted native input.") }
            let count = await f.peer.promptCount
            #expect(count == 0)
        } catch { await f.peer.release(); _ = await send.result; throw error }
    }
}

@Test(arguments: [false, true])
func openCodeV1StopOfUnobservedPOSTIsUncertainAndDrainsItsOwner(_ acknowledged: Bool) async throws {
    try await withV1Session(mode: acknowledged ? .manual : .heldAck) { f in
        let send = Task { try await f.session.send(text: "Unknown delivery", thread: f.thread()) }
        do {
            try await v1Eventually { await f.peer.promptCount == 1 }
            if acknowledged { try await send.value }
            var failure: OpenCodeV1SessionError?
            do { try await f.session.interrupt() } catch { failure = error as? OpenCodeV1SessionError }
            let result = await send.result
            #expect(failure == .uncertainDelivery)
            if !acknowledged, case .success = result { Issue.record("An unknown POST was reported as successful Stop.") }
            let closed = await f.peer.closeCount
            #expect(closed == 1)
            let completions = await f.record.completions
            #expect(completions.isEmpty)
        } catch { await f.peer.release(); _ = await send.result; throw error }
    }
}

@Test func openCodeV1PermissionRepliesUseExactIDsAndWaitForNativeSettlement() async throws {
    try await withV1Session { f in
        try await f.session.send(text: "Permission owner", thread: f.thread()); try await f.peer.begin()
        try await f.peer.permission(id: "perm_one")
        try await v1Eventually { await f.record.approvals.count == 1 }
        let saved = await f.record.approvals
        let approval = try #require(saved.first)
        try await f.session.choose(approval, optionID: "conversation")
        do { try await f.session.respond(approval, allow: true); Issue.record("The answered request was submitted twice.") } catch { }
        let before = await f.record.dismissals
        #expect(before == 0)
        try await f.peer.emit("permission.replied", fields: ["requestID": .string("perm_one"), "reply": .string("once")])
        try await v1Eventually { await f.record.dismissals == 1 }
        let calls = await f.peer.calls
        let reply = calls.filter { $0.path == ["permission", "perm_one", "reply"] }
        #expect(reply.count == 1)
        #expect(reply.first?.body?["reply"] == .string("once"))
        let grantPatch = calls.last { $0.method == "PATCH" }
        #expect(grantPatch?.body?["permission"].array?.contains(.object(["permission": .string("bash"), "pattern": .string("echo safe"), "action": .string("allow")])) == true)
        try await f.peer.permission(id: "perm_workspace")
        try await v1Eventually { await f.record.approvals.count == 2 }
        let later = await f.record.approvals
        let workspace = try #require(later.last)
        try await f.session.choose(workspace, optionID: "always")
        let laterCalls = await f.peer.calls
        #expect(laterCalls.last?.path == ["permission", "perm_workspace", "reply"])
        #expect(laterCalls.last?.body?["reply"] == .string("always"))
    }
}

@Test func openCodeV1QuestionsPreserveOrderedSelectionsCustomAnswersAndNativeCancel() async throws {
    try await withV1Session { f in
        try await f.session.send(text: "Question owner", thread: f.thread()); try await f.peer.begin()
        try await f.peer.question(id: "question_one")
        try await v1Eventually { await f.record.approvals.count == 1 }
        let requests = await f.record.approvals
        let request = try #require(requests.first)
        try await f.session.selectAnswers(request, selections: ["question-0": ["Tea", "Water"], "question-1": ["My exact value"]])
        let calls = await f.peer.calls
        #expect(calls.last?.path == ["question", "question_one", "reply"])
        #expect(calls.last?.body?["answers"] == .array([.array([.string("Tea"), .string("Water")]), .array([.string("My exact value")])]))
        try await f.peer.emit("question.replied", fields: ["requestID": .string("question_one")])
        try await f.peer.question(id: "question_cancel")
        try await v1Eventually { await f.record.approvals.count == 2 }
        let later = await f.record.approvals
        let cancel = try #require(later.last)
        try await f.session.respond(cancel, allow: false)
        let finalCalls = await f.peer.calls
        #expect(finalCalls.last?.path == ["question", "question_cancel", "reject"])
        #expect(finalCalls.filter { $0.path.last == "abort" }.isEmpty)
    }
}

@Test func openCodeV1EarlyChildKeepsOriginalRunAndSurvivesRootIdleAndFailure() async throws {
    try await withV1Session { f in
        let first = f.thread()
        let actualOwner = try #require(first.activeRun?.id)
        try await f.session.send(text: "Parent", thread: first); try await f.peer.begin()
        try await f.peer.childCreated(extraRules: [
            .init(permission: "bash", pattern: "git *", action: "allow"),
            .init(permission: "edit", pattern: "/plans/*", action: "allow")
        ])
        try await f.peer.user(id: "msg_child_user", session: "ses_child")
        try await f.peer.assistant(id: "msg_child_assistant", parent: "msg_child_user", session: "ses_child")
        try await f.peer.text("early child 🌍", assistant: "msg_child_assistant", session: "ses_child")
        try await f.peer.taskChild()
        try await v1Eventually { await f.record.childText.contains("early child") }
        try await f.peer.emit("session.error", fields: ["error": .object(["name": .string("UnknownError")])])
        try await v1Eventually { await f.record.completions == [.failed] }
        try await f.peer.delta(" after parent", part: "part_text", assistant: "msg_child_assistant", session: "ses_child")
        try await v1Eventually { await f.record.childText.contains("after parent") }
        let owners = await f.record.backgroundOwners
        #expect(owners == [actualOwner])
        let failures = await f.record.failures
        #expect(failures == 0)
        try await f.peer.idle(session: "ses_child")
        let calls = await f.peer.calls
        let childPatch = calls.first { $0.method == "PATCH" && $0.path == ["session", "ses_child"] }
        #expect(childPatch?.body?["permission"].array?.contains(.object(["permission": .string("task"), "pattern": .string("*"), "action": .string("deny")])) == true)
        let childRules = try #require(childPatch?.body?["permission"].array)
        let bash = childRules.last {
            ($0["permission"] == .string("bash") || $0["permission"] == .string("*")) &&
            ($0["pattern"] == .string("*") || $0["pattern"] == .string("git *"))
        }?["action"].string
        let planEdit = childRules.last {
            ($0["permission"] == .string("edit") || $0["permission"] == .string("*")) &&
            ($0["pattern"] == .string("*") || $0["pattern"] == .string("/plans/*"))
        }?["action"].string
        #expect(bash == "ask")
        #expect(planEdit == "allow")
    }
}

@Test func openCodeV1ObservedStopAbortsRootAndOnlyVerifiedDescendants() async throws {
    try await withV1Session { f in
        try await f.session.send(text: "Stop owned work", thread: f.thread()); try await f.peer.begin()
        try await f.peer.childCreated(); try await f.peer.taskChild()
        try await v1Eventually { await f.peer.childPatched }
        try await f.session.interrupt()
        let calls = await f.peer.calls
        #expect(calls.filter { $0.path.last == "abort" }.map(\.path) == [["session", "ses_root", "abort"], ["session", "ses_child", "abort"]])
        try await f.peer.emit("session.error", fields: ["error": .object(["name": .string("MessageAbortedError")])])
        try await v1Eventually { await f.record.completions == [.interrupted] }
    }
}

@Test func openCodeV1ExactAssistantParentProvesInputWithoutAUserEcho() async throws {
    try await withV1Session { f in
        try await f.session.send(text: "Native parent proof", thread: f.thread())
        // No user echo was emitted. The exact assistant.parentID is the authored
        // native message ID, which is enough to prove this request was admitted.
        try await f.peer.assistant()
        try await v1Eventually { await f.record.turns.count == 1 }
        try await f.session.interrupt()
        try await f.peer.emit("session.error", fields: ["error": .object(["name": .string("MessageAbortedError")])])
        try await v1Eventually { await f.record.completions == [.interrupted] }
        let failures = await f.record.failures
        #expect(failures == 0)
    }
}

@Test(arguments: [false, true])
func openCodeV1MalformedTerminalAndUnexpectedEOFPauseInsteadOfCompleting(_ eof: Bool) async throws {
    try await withV1Session { f in
        try await f.session.send(text: "Keep truthful failure", thread: f.thread()); try await f.peer.begin()
        if eof { await f.peer.disconnect() }
        else { await f.peer.raw("{\"type\":\"session.idle\",\"properties\":{}}") }
        try await v1Eventually { await f.record.failures == 1 }
        let completions = await f.record.completions
        #expect(completions.isEmpty)
    }
}

enum V1Fault: Sendable, Equatable { case manual, lostCreate, lostPrompt, rejectedPrompt, heldAck, heldLostAck, heldConfiguration }
private struct V1Call: Sendable { let method: String; let path: [String]; let body: JSONValue? }
private actor V1Gate {
    private var open = false
    private var waiters: [CheckedContinuation<Void, Never>] = []
    func wait() async { if open { return }; await withCheckedContinuation { waiters.append($0) } }
    func release() { open = true; let saved = waiters; waiters = []; for waiter in saved { waiter.resume() } }
}
private actor V1Record {
    private var events: [ProviderEvent] = []
    private var entities: [ProviderEntityKey: ProviderEntity] = [:]
    func append(_ event: ProviderEvent) {
        events.append(event)
        let inner = Self.inner(event)
        if case .entity(let update) = inner { entities[update.key] = try? update.apply(to: entities[update.key]) }
        if case .runEntity(_, let update) = inner { entities[update.key] = try? update.apply(to: entities[update.key]) }
    }
    var associations: [String: ProviderEntityKey] {
        events.reduce(into: [:]) { result, event in
            if case .associateEntity(let key, let clientID) = Self.inner(event) { result[clientID] = key }
        }
    }
    var contextOwners: Set<UUID> { Set(events.compactMap { if case .context(let id, _) = $0 { id } else { nil } }) }
    var turns: [String] { events.compactMap { if case .turn(let value) = Self.inner($0) { value } else { nil } } }
    var completions: [ThreadState] { events.compactMap { if case .completed(let value) = Self.inner($0) { value } else { nil } } }
    var failures: Int { events.filter { if case .connectionClosed = Self.inner($0) { true } else { false } }.count }
    var approvals: [ApprovalRequest] { events.compactMap { if case .sessionApproval(let value) = Self.inner($0) { value } else { nil } } }
    var dismissals: Int { events.filter { if case .sessionApprovalDismissed = Self.inner($0) { true } else { false } }.count }
    var text: String { entities.values.filter { $0.role == .assistant && !$0.key.sessionID.contains("ses_child") }.map(\.text).sorted().joined() }
    var childText: String { entities.values.filter { $0.role == .assistant && $0.key.sessionID.contains("ses_child") }.map(\.text).sorted().joined() }
    var backgroundOwners: Set<UUID> { Set(events.compactMap { if case .runEntity(let id, _) = $0 { id } else { nil } }) }
    private static func inner(_ event: ProviderEvent) -> ProviderEvent { if case .context(_, let value) = event { value } else { event } }
}
@Test func openCodeV1AdvertisedCommandUsesNativeEndpointLiteralArgumentsAndCapturedControls() async throws {
    try await withV1Session { f in
        var thread = f.thread()
        thread.openCodeConfiguration = f.configuration.selecting(model: nil)
        try await f.session.send(text: "/review literal \"quotes\"\nsecond line", thread: thread)
        let calls = await f.peer.calls
        let body = try #require(calls.first { $0.path.last == "command" }?.body)
        #expect(body["command"] == .string("review"))
        #expect(body["arguments"] == .string("literal \"quotes\"\nsecond line"))
        #expect(body["model"] == .string(f.model.providerID + "/" + f.model.id))
        #expect(body["variant"] == .string("balanced"))
        #expect(body["agent"] == .string("build"))
        #expect(!calls.contains { $0.path.last == "prompt_async" })
        let before = await f.record.completions
        #expect(before.isEmpty)
        try await f.peer.begin(); try await f.peer.text("native command snapshot"); try await f.peer.idle()
        try await v1Eventually { await f.record.completions == [.idle] }
        let turns = await f.record.turns
        let inputID = try #require(body["messageID"].string)
        #expect(turns == [inputID])
    }
}

@Test func openCodeV1LeadingNativeSkillIsCommandButInlineSkillsRefuseBeforeSessionCreation() async throws {
    try await withV1Session { f in
        try await f.session.send(text: "$review\tinspect the change", thread: f.thread())
        let calls = await f.peer.calls
        let body = try #require(calls.first { $0.path.last == "command" }?.body)
        #expect(body["command"] == .string("review"))
        #expect(body["arguments"] == .string("inspect the change"))
    }
    for text in ["inspect $review", "$review $review inspect", "$review $audit inspect"] {
        try await withV1Session { f in
            await #expect(throws: (any Error).self) { try await f.session.send(text: text, thread: f.thread()) }
            let calls = await f.peer.calls
            #expect(!calls.contains { $0.method == "POST" || $0.method == "PATCH" })
            #expect(!calls.contains { $0.path.last == "prompt_async" || $0.path.last == "command" })
        }
    }
}

@Test func openCodeV1UnknownDollarVariableRemainsExactOrdinaryPrompt() async throws {
    try await withV1Session { f in
        try await f.session.send(text: "Show $HOME and $100 without expansion", thread: f.thread())
        let calls = await f.peer.calls
        let body = try #require(calls.first { $0.path.last == "prompt_async" }?.body)
        #expect(body["parts"].array?.first?["text"] == .string("Show $HOME and $100 without expansion"))
        #expect(!calls.contains { $0.path.last == "command" })
    }
}

@Test func openCodeV1CompactUsesSummarizeAuthorityWithoutInventingUserTurn() async throws {
    try await withV1Session { f in
        try await f.session.send(text: "/compact", thread: f.thread())
        try await v1Eventually { await f.record.completions == [.idle] }
        let calls = await f.peer.calls, turns = await f.record.turns
        let body = try #require(calls.first { $0.path.last == "summarize" }?.body)
        #expect(body == .object(["providerID": .string(f.model.providerID), "modelID": .string(f.model.id), "auto": .bool(false)]))
        #expect(turns.isEmpty)
        #expect(!calls.contains { $0.path.last == "command" || $0.path.last == "prompt_async" })
    }
}

private struct V1Fixture: Sendable {
    let root: URL
    let model: OpenCodeModelSelection
    let configuration: OpenCodeConfiguration
    let peer: V1Peer
    let session: OpenCodeV1Session
    let record: V1Record
    func thread(nativeID: String? = nil) -> CodingThread {
        var thread = CodingThread(project: .init(path: root.path))
        thread.provider = .opencode; thread.openCodeConfiguration = configuration
        thread.model = configuration.model?.catalogID ?? ""; thread.providerThreadID = nativeID
        thread.checkpointPolicy = .disabled
        thread.activeRun = .init(id: UUID(), configuration: .init(thread: thread), startedAt: Date())
        return thread
    }
}
private func withV1Session(mode: V1Fault = .manual, body: (V1Fixture) async throws -> Void) async throws {
    let root = try temporaryWorkspace()
    let model = OpenCodeModelSelection(providerID: "fixture-provider", id: "model/with/slashes")
    let config = OpenCodeConfiguration(generation: .v1, model: .init(providerID: model.providerID, id: model.id, variant: "balanced"))
    let peer = V1Peer(directory: root.path, model: model, mode: mode)
    let session = OpenCodeV1Session(cwd: root, configuration: config, transport: peer)
    let record = V1Record(), consumer = Task { for await event in session.events { await record.append(event) } }
    do { try await body(.init(root: root, model: model, configuration: config, peer: peer, session: session, record: record)) }
    catch { await session.close(); await consumer.value; try? FileManager.default.removeItem(at: root); throw error }
    await session.close(); await consumer.value; try FileManager.default.removeItem(at: root)
}
private func v1Eventually(_ predicate: @escaping @Sendable () async throws -> Bool) async throws {
    let deadline = ContinuousClock.now + .seconds(5)
    while !(try await predicate()) {
        guard ContinuousClock.now < deadline else { throw CoincideError("The private OpenCode 1 fixture did not reach its expected boundary.") }
        try await Task.sleep(for: .milliseconds(5))
    }
}

private actor V1Peer: OpenCodeV1SessionTransport {
    private let directory: String
    private let model: OpenCodeModelSelection
    private var mode: V1Fault
    private let stream: AsyncThrowingStream<OpenCodeSSEEvent, any Error>
    private let continuation: AsyncThrowingStream<OpenCodeSSEEvent, any Error>.Continuation
    private let gate = V1Gate()
    private let commandGate = V1Gate(), statusGate = V1Gate()
    private var holdingCommands = false, holdingStatus = false
    var commandReadHeld = false, statusReadHeld = false
    var heldStatusReturns = 0
    private var closed = false
    private var sessions: [String: JSONValue] = [:]
    private var busy = false
    private var inputID: String?
    private var agentRules: [OpenCodeV1PermissionRule] = []
    var calls: [V1Call] = []
    var connects = 0
    var closeCount = 0
    var configurationHeld = false
    var childPatched = false
    var promptCount: Int { calls.filter { $0.path.last == "prompt_async" }.count }
    var statusCount: Int { calls.filter { $0.path == ["session", "status"] }.count }
    init(directory: String, model: OpenCodeModelSelection, mode: V1Fault) {
        self.directory = directory; self.model = model; self.mode = mode
        let pair = AsyncThrowingStream<OpenCodeSSEEvent, any Error>.makeStream()
        stream = pair.stream; continuation = pair.continuation
    }
    func connect() async throws -> AsyncThrowingStream<OpenCodeSSEEvent, any Error> { connects += 1; return stream }
    func inventory(directory: URL) async throws -> OpenCodeMetadataSnapshot {
        .init(server: .init(generation: .v1, version: .init(major: 1, minor: 14, patch: 19), processIdentifier: nil), directory: directory.path,
            models: [.init(selection: model, name: "Private Fixture", variants: ["balanced", "fast"], enabled: true, input: ["text", "image"], output: ["text"], tools: true)],
            agents: [.init(id: "build", name: "Build", description: nil, mode: .primary, hidden: false),
                     .init(id: "plan", name: "Plan", description: nil, mode: .primary, hidden: false)], defaults: [model])
    }
    func commands(directory: URL) async throws -> ProviderCommandInventory {
        if holdingCommands { commandReadHeld = true; await commandGate.wait() }
        return try ProviderCommandCatalog.openCode(commands: .array([
            .object(["name": .string("review"), "source": .string("skill")]),
            .object(["name": .string("audit"), "source": .string("skill")])]),
            skills: .array([.object(["name": .string("review"), "location": .string(directory.path + "/review/SKILL.md")]),
                .object(["name": .string("audit"), "location": .string(directory.path + "/audit/SKILL.md")])]),
            generation: .v1, cwd: directory.path)
    }
    func agentPermissionRules(directory: URL, agentID: String) async throws -> [OpenCodeV1PermissionRule] { agentRules }
    func setAgentRules(_ rules: [OpenCodeV1PermissionRule]) { agentRules = rules }
    func setMode(_ value: V1Fault) { mode = value }
    func release() async { await gate.release() }
    func close() async { guard !closed else { return }; closed = true; closeCount += 1; continuation.finish(); await gate.release(); await commandGate.release(); await statusGate.release() }
    func disconnect() { continuation.finish() }
    func holdCommandReads() { holdingCommands = true }
    func releaseCommands() async { holdingCommands = false; await commandGate.release() }
    func holdStatusRead() { holdingStatus = true }
    func releaseStatus() async { holdingStatus = false; await statusGate.release() }
    func raw(_ text: String) { continuation.yield(.init(event: "message", data: text, id: nil, retryMilliseconds: nil)) }
    func seed(fault: String) {
        if fault == "missing" { return }
        var fields = info(id: "ses_existing").object ?? [:]
        if fault == "wrong-cwd" { fields["directory"] = .string(directory + "/other") }
        if fault == "child" { fields["parentID"] = .string("ses_other") }
        if fault == "reverted" { fields["revert"] = .object(["messageID": .string("msg_hidden")]) }
        sessions["ses_existing"] = .object(fields)
    }
    func request(method: String, path: [String], body: JSONValue?) async throws -> OpenCodeHTTPResponse {
        guard !closed else { throw CancellationError() }
        calls.append(.init(method: method, path: path, body: body))
        if path == ["session", "status"] {
            if holdingStatus {
                statusReadHeld = true; await statusGate.wait(); heldStatusReturns += 1
                return try response(.object([:]))
            }
            return try response(.object(busy ? ["ses_root": .object(["type": .string("busy")])] : [:]))
        }
        if method == "POST", path == ["session"] {
            sessions["ses_root"] = info(id: "ses_root", rules: body?["permission"] ?? .array([]))
            if mode == .lostCreate { throw OpenCodeHTTPError.transportFailure }
            return try response(sessions["ses_root"]!)
        }
        if method == "GET", path.count == 2 { return try response(sessions[path[1]] ?? .object([:]), status: sessions[path[1]] == nil ? 404 : 200) }
        if method == "GET", path.last == "message" { return try response(.array([])) }
        if method == "PATCH", path.count == 2 {
            if mode == .heldConfiguration { configurationHeld = true; await gate.wait() }
            guard !closed else { throw CancellationError() }
            var fields = sessions[path[1]]?.object ?? [:]; fields["permission"] = body?["permission"] ?? .array([])
            sessions[path[1]] = .object(fields)
            if path[1] == "ses_child" { childPatched = true }
            return try response(.object(fields))
        }
        if path.last == "summarize" { return try response(.bool(true)) }
        if path.last == "command" {
            inputID = body?["messageID"].string
            return try response(.object(["info": message(id: "msg_assistant", role: "assistant", session: path[1], parent: inputID), "parts": .array([])]))
        }
        if path.last == "prompt_async" {
            inputID = body?["messageID"].string
            let fault = mode
            if fault == .heldAck || fault == .heldLostAck { await gate.wait() }
            guard !closed else { throw CancellationError() }
            if fault == .lostPrompt || fault == .heldLostAck { throw OpenCodeHTTPError.transportFailure }
            if fault == .rejectedPrompt { return try response(.object([:]), status: 400) }
            return .init(status: 204, headers: [:], body: Data())
        }
        if path.last == "children" {
            let children = sessions.values.filter { $0["parentID"] == .string(path[1]) }
            return try response(.array(children))
        }
        if path.last == "abort" || path.last == "reply" || path.last == "reject" { return try response(.bool(true)) }
        throw CoincideError("The private OpenCode 1 peer received an unexpected route.")
    }
    func begin(assistant: String = "msg_assistant") throws {
        guard let inputID else { throw CoincideError("The private peer has no input.") }
        busy = true
        try user(id: inputID); try self.assistant(id: assistant, parent: inputID)
        try emit("session.status", fields: ["status": .object(["type": .string("busy")])])
    }
    func user(id: String, session: String = "ses_root") throws {
        try emit("message.updated", session: session, fields: ["info": message(id: id, role: "user", session: session)])
    }
    func assistant(id: String = "msg_assistant", parent: String? = nil, completed: Bool = false, session: String = "ses_root") throws {
        try emit("message.updated", session: session, fields: ["info": message(id: id, role: "assistant", session: session,
            parent: parent ?? inputID ?? "msg_missing", completed: completed)])
    }
    func text(_ text: String, assistant: String = "msg_assistant", session: String = "ses_root", part: String = "part_text") throws {
        try emit("message.part.updated", session: session, fields: ["part": .object(["id": .string(part), "sessionID": .string(session),
            "messageID": .string(assistant), "type": .string("text"), "text": .string(text)])])
    }
    func delta(_ text: String, part: String, assistant: String = "msg_assistant", session: String = "ses_root") throws {
        try emit("message.part.delta", session: session, fields: ["messageID": .string(assistant), "partID": .string(part), "field": .string("text"), "delta": .string(text)])
    }
    func idle(session: String = "ses_root") throws {
        if session == "ses_root" { busy = false }
        try emit("session.idle", session: session)
    }
    func childCreated(extraRules: [OpenCodeV1PermissionRule] = []) throws {
        let restricted = OpenCodeV1PermissionRule(permission: "task", pattern: "*", action: "deny")
        sessions["ses_child"] = info(id: "ses_child", parent: "ses_root", rules: .array(([restricted] + extraRules).map(\.json)))
        try emit("session.created", session: "ses_child", fields: ["info": sessions["ses_child"]!])
    }
    func taskChild() throws {
        try emit("message.part.updated", fields: ["part": .object(["id": .string("part_task"), "sessionID": .string("ses_root"),
            "messageID": .string("msg_assistant"), "type": .string("tool"), "callID": .string("call_task"), "tool": .string("task"),
            "state": .object(["status": .string("running"), "input": .object(["description": .string("Private child"), "prompt": .string("Harmless fixture")]),
                "metadata": .object(["sessionId": .string("ses_child")])])])])
    }
    func permission(id: String) throws {
        try emit("permission.asked", fields: ["id": .string(id), "permission": .string("bash"), "patterns": .array([.string("echo safe")]),
            "always": .array([.string("echo safe")]), "metadata": .object([:]), "tool": .object(["messageID": .string("msg_assistant"), "callID": .string("call_shell")])])
    }
    func question(id: String) throws {
        try emit("question.asked", fields: ["id": .string(id), "questions": .array([
            .object(["header": .string("Drinks"), "question": .string("Choose drinks"), "multiple": .bool(true), "custom": .bool(false),
                "options": .array([.object(["label": .string("Tea"), "description": .string("Tea")]), .object(["label": .string("Water"), "description": .string("Water")])])]),
            .object(["header": .string("Custom"), "question": .string("Exact value"), "custom": .bool(true), "options": .array([])])])])
    }
    func emit(_ type: String, session: String = "ses_root", fields: [String: JSONValue] = [:]) throws {
        var props = fields; props["sessionID"] = .string(session)
        let value = JSONValue.object(["type": .string(type), "properties": .object(props)])
        raw(String(decoding: try JSONEncoder().encode(value), as: UTF8.self))
    }
    private func info(id: String, parent: String? = nil, rules: JSONValue = .array([])) -> JSONValue {
        var fields: [String: JSONValue] = ["id": .string(id), "directory": .string(directory), "permission": rules]
        if let parent { fields["parentID"] = .string(parent) }; return .object(fields)
    }
    private func message(id: String, role: String, session: String, parent: String? = nil, completed: Bool = false) -> JSONValue {
        var time: [String: JSONValue] = ["created": .number(1)]
        if completed { time["completed"] = .number(2) }
        var fields: [String: JSONValue] = ["id": .string(id), "sessionID": .string(session), "role": .string(role), "time": .object(time)]
        if let parent { fields["parentID"] = .string(parent) }; return .object(fields)
    }
    private func response(_ value: JSONValue, status: Int = 200) throws -> OpenCodeHTTPResponse {
        .init(status: status, headers: ["content-type": "application/json"], body: try JSONEncoder().encode(value))
    }
}

private func v1ReadyToSteer(_ f: V1Fixture, nativeDefault: Bool = false) async throws -> CodingThread {
    var thread = f.thread()
    if nativeDefault {
        thread.openCodeConfiguration = f.configuration.selecting(model: nil); thread.model = ""
        thread.activeRun = .init(id: UUID(), configuration: .init(thread: thread), startedAt: Date())
    }
    try await f.session.send(text: "Original input", thread: thread)
    try await f.peer.begin()
    try await v1Eventually { await f.record.turns.count == 1 }
    thread.providerThreadID = "ses_root"
    thread.activeRun?.nativeTurnID = await f.record.turns.first
    try await v1Eventually { await f.session.steeringCapabilities().supportsActiveSteering }
    return thread
}

@Test(arguments: [false, true])
func openCodeV1SteeringKeepsCapturedControlsOriginalRunAndIdempotentInput(nativeDefault: Bool) async throws {
    try await withV1Session { f in
        var thread = try await v1ReadyToSteer(f, nativeDefault: nativeDefault)
        let opening = try #require(thread.activeRun?.nativeTurnID)
        thread.openCodeConfiguration = f.configuration.selecting(agentID: "plan")
        thread.permission = .fullAccess
        let before = await f.peer.calls
        let receipt = try await f.session.steer(input: .init(text: "Follow exact $HOME 🌍"), thread: thread,
            expectedTurnID: opening, clientMessageID: "local-steering-one")
        #expect(receipt.turnID == opening && receipt.delivery == .acknowledged)
        let calls = await f.peer.calls
        let prompts = calls.filter { $0.path.last == "prompt_async" }
        #expect(prompts.count == 2 && calls.count == before.count + 1)
        let body = try #require(prompts.last?.body), nativeID = try #require(body["messageID"].string)
        #expect(nativeID != opening && nativeID > opening)
        #expect(body["agent"] == .string("build"))
        #expect(body["variant"] == (nativeDefault ? .null : .string("balanced")))
        #expect(body["model"] == (nativeDefault ? .null : .object(["providerID": .string(f.model.providerID), "modelID": .string(f.model.id)])))
        #expect(body["parts"].array?.first?["text"] == .string("Follow exact $HOME 🌍"))
        #expect(body["expectedTurnID"] == .null && body["delivery"] == .null)
        let again = try await f.session.steer(input: .init(text: "Follow exact $HOME 🌍"), thread: thread,
            expectedTurnID: opening, clientMessageID: "local-steering-one")
        #expect(again == receipt)
        await #expect(throws: ProviderSteeringError(.invalidRequest)) {
            try await f.session.steer(input: .init(text: "Changed content"), thread: thread,
                expectedTurnID: opening, clientMessageID: "local-steering-one")
        }
        try await f.peer.begin(assistant: "msg_steered_reply")
        try await v1Eventually { await f.record.associations["local-steering-one"]?.id == nativeID }
        try await f.peer.text("steered output", assistant: "msg_steered_reply", part: "part_steered")
        try await f.peer.idle()
        try await v1Eventually { await f.record.completions == [.idle] }
        #expect(await f.record.turns == [opening])
        #expect(await f.peer.promptCount == 2)
        #expect(await f.record.text.contains("steered output"))
        #expect(await f.record.contextOwners == [thread.activeRun!.id])
    }
}

@Test(arguments: [false, true])
func openCodeV1SteeringHoldsOldIdleUntilExactInputAndFreshStatus(lostAck: Bool) async throws {
    try await withV1Session { f in
        let thread = try await v1ReadyToSteer(f), opening = try #require(thread.activeRun?.nativeTurnID)
        let statusCount = await f.peer.statusCount
        await f.peer.setMode(lostAck ? .heldLostAck : .heldAck)
        let task = Task { try await f.session.steer(input: .init(text: "Delayed steering"), thread: thread,
            expectedTurnID: opening, clientMessageID: "held-steering") }
        do {
            try await v1Eventually { await f.peer.promptCount == 2 }
            try await f.peer.idle()
            try await f.peer.user(id: "msg_unrelated_steer")
            try await f.peer.assistant(id: "msg_unrelated_reply", parent: "msg_unrelated_steer", completed: true)
            #expect(await f.record.completions.isEmpty)
            try await f.peer.begin(assistant: "msg_held_reply")
            if lostAck { try await f.peer.assistant(id: "msg_held_reply", completed: true) }
            try await v1Eventually { await f.record.associations["held-steering"] != nil }
            await f.peer.release()
            #expect(try await task.value.turnID == opening)
            try await v1Eventually { await f.peer.statusCount > statusCount }
            #expect(await f.record.completions.isEmpty)
            #expect(await f.record.failures == 0)
            try await f.peer.idle()
            try await v1Eventually { await f.record.completions == [.idle] }
            #expect(await f.record.turns == [opening])
        } catch { await f.peer.release(); _ = await task.result; throw error }
    }
}

@Test(arguments: [false, true])
func openCodeV1SteeringSeparatesKnownRejectionFromUnknownAdmission(rejected: Bool) async throws {
    try await withV1Session { f in
        let thread = try await v1ReadyToSteer(f), opening = try #require(thread.activeRun?.nativeTurnID)
        await f.peer.setMode(rejected ? .rejectedPrompt : .lostPrompt)
        await #expect(throws: ProviderSteeringError(rejected ? .rejected : .outcomeUncertain)) {
            try await f.session.steer(input: .init(text: "Never resend"), thread: thread,
                expectedTurnID: opening, clientMessageID: "failed-steering")
        }
        await #expect(throws: (any Error).self) {
            try await f.session.steer(input: .init(text: "Never resend"), thread: thread,
                expectedTurnID: opening, clientMessageID: "failed-steering")
        }
        #expect(await f.peer.promptCount == 2)
        #expect(await f.record.completions.isEmpty)
        if rejected {
            #expect(await f.session.steeringCapabilities().supportsActiveSteering)
            try await f.peer.idle()
            try await v1Eventually { await f.record.completions == [.idle] }
        } else {
            try await v1Eventually { await f.record.failures == 1 }
            #expect(await f.session.steeringCapabilities().supportsActiveSteering == false)
        }
    }
}

@Test func openCodeV1SteeringStopJoinsUnknownAdmissionAndDoesNotCompleteIt() async throws {
    try await withV1Session { f in
        let thread = try await v1ReadyToSteer(f), opening = try #require(thread.activeRun?.nativeTurnID)
        await f.peer.setMode(.heldAck)
        let task = Task { try await f.session.steer(input: .init(text: "Unknown at Stop"), thread: thread,
            expectedTurnID: opening, clientMessageID: "stopped-steering") }
        try await v1Eventually { await f.peer.promptCount == 2 }
        await #expect(throws: OpenCodeV1SessionError.uncertainDelivery) { try await f.session.interrupt() }
        await #expect(throws: ProviderSteeringError(.outcomeUncertain)) { try await task.value }
        #expect(await f.peer.closeCount == 1)
        #expect(await f.record.completions.isEmpty)
        #expect(await f.record.failures == 1)
    }
}

@Test func openCodeV1SteeringRefusesChangedCapturedTargetPendingQuestionAndNativeCommand() async throws {
    try await withV1Session { f in
        let thread = try await v1ReadyToSteer(f), opening = try #require(thread.activeRun?.nativeTurnID)
        var changed = thread
        changed.activeRun?.configuration.permission = .fullAccess
        await #expect(throws: ProviderSteeringError(.staleTarget)) {
            try await f.session.steer(input: .init(text: "Wrong capture"), thread: changed,
                expectedTurnID: opening, clientMessageID: "changed-capture")
        }
        await #expect(throws: ProviderSteeringError(.staleTarget)) {
            try await f.session.steer(input: .init(text: "Wrong turn"), thread: thread,
                expectedTurnID: "msg_foreign", clientMessageID: "changed-target")
        }
        await #expect(throws: ProviderSteeringError(.unsupported)) {
            try await f.session.steer(input: .init(text: "/review inspect"), thread: thread,
                expectedTurnID: opening, clientMessageID: "native-command")
        }
        try await f.peer.question(id: "question-steer")
        try await v1Eventually { await f.record.approvals.count == 1 }
        #expect(await f.session.steeringCapabilities().supportsActiveSteering == false)
        await #expect(throws: ProviderSteeringError(.staleTarget)) {
            try await f.session.steer(input: .init(text: "Question pending"), thread: thread,
                expectedTurnID: opening, clientMessageID: "pending-question")
        }
        #expect(await f.peer.promptCount == 1)
    }
}

@Test(arguments: [false, true])
func openCodeV1SteeringEnginePersistsNativeAssociationFIFOAndUnknownRestart(unknown: Bool) async throws {
    let root = try temporaryWorkspace(), url = root.appendingPathComponent("workspace.sqlite")
    let project = WorkspaceProject(path: root.path)
    let model = OpenCodeModelSelection(providerID: "fixture-provider", id: "model/with/slashes")
    let configuration = OpenCodeConfiguration(generation: .v1, model: .init(providerID: model.providerID, id: model.id, variant: "balanced"))
    var thread = CodingThread(project: project)
    thread.provider = .opencode; thread.openCodeConfiguration = configuration; thread.model = model.catalogID
    thread.checkpointPolicy = .disabled
    var seed = WorkspaceSnapshot(); seed.projects = [project]; seed.threads = [thread]
    try await WorkspaceDatabase(url: url).save(seed, event: "v1 steering fixture")
    let peer = V1Peer(directory: root.path, model: model, mode: .manual)
    let session = OpenCodeV1Session(cwd: root, configuration: configuration, transport: peer)
    let engine = try WorkspaceEngine(url: url, providerFactory: { _ in session }, identityResolver: { _ in nil })
    let threadID = thread.id
    do {
        _ = try await engine.load()
        _ = try await engine.dispatch(.submit(threadID: thread.id, text: "Original input"))
        try await v1Eventually { await peer.promptCount == 1 }
        try await peer.begin()
        try await v1Eventually { await engine.promptSteeringAvailability(threadID: threadID).canSteer }
        let original = try #require(await engine.current().snapshot.threads[0].activeRun)
        _ = try await engine.dispatch(.editThread(thread.id, .permission(.fullAccess)))
        await peer.setMode(unknown ? .lostPrompt : .heldAck)
        _ = try await engine.steerPrompt(threadID: thread.id, text: "Additional original-run input", expectedRunID: original.id)
        try await v1Eventually { await peer.promptCount == 2 }
        if !unknown {
            let persisted = try await WorkspaceDatabase(url: url).load()
            #expect(persisted.promptSteerings?.last?.phase == .dispatching)
        }
        _ = try await engine.dispatch(.submit(threadID: thread.id, text: "Captured FIFO follow-up"))
        if unknown {
            try await v1Eventually { await engine.current().snapshot.promptSteerings?.last?.phase == .unconfirmed }
            try await v1Eventually { await engine.current().snapshot.threads[0].activeRun == nil }
            #expect(await engine.current().snapshot.threads[0].queuePaused)
            #expect(await peer.promptCount == 2)
        } else {
            let nativeID = try #require(await peer.calls.last { $0.path.last == "prompt_async" }?.body?["messageID"].string)
            try await peer.begin(assistant: "msg_engine_steered")
            await peer.release()
            try await v1Eventually {
                let snapshot = await engine.current().snapshot
                guard let operation = snapshot.promptSteerings?.last else { return false }
                return operation.phase == .delivered && snapshot.threads[0].messages.first { $0.id == operation.messageID }?.providerEntity?.key.id == nativeID
            }
            #expect(await engine.current().snapshot.threads[0].activeRun?.id == original.id)
            await peer.setMode(.manual)
            try await peer.idle()
            try await v1Eventually { await peer.promptCount == 3 }
            try await peer.begin(assistant: "msg_engine_followup")
            try await peer.idle()
            try await v1Eventually { await engine.current().snapshot.threads[0].activeRun == nil }
            let snapshot = await engine.current().snapshot
            let operation = try #require(snapshot.promptSteerings?.last)
            #expect(snapshot.threads[0].runHistory?.count == 2)
            #expect(snapshot.threads[0].runHistory?.first?.turnIDs == [original.nativeTurnID!])
            #expect(snapshot.threads[0].messages.filter { $0.promptSteeringID == operation.id }.count == 1)
            #expect(snapshot.threads[0].messages.first { $0.id == operation.messageID }?.runReference?.runID == original.id)
            let prompts = await peer.calls.filter { $0.path.last == "prompt_async" }
            #expect(prompts[1].body?["agent"] == .string("build") && prompts[1].body?["variant"] == .string("balanced"))
            #expect(operation.configuration.permission == .supervised)
        }
        await engine.drainCommands()
        let retained = await engine.current().snapshot
        let operation = try #require(retained.promptSteerings?.last)
        #expect(try await WorkspaceDatabase(url: url).rebuildProjection().snapshot == retained)
        await engine.shutdown()
        let reopened = try WorkspaceEngine(url: url, providerFactory: { _ in throw CoincideError("A retained input must not start a provider") }, identityResolver: { _ in nil })
        do {
            _ = try await reopened.load()
            #expect(await reopened.current().snapshot.promptSteering(operation.id)?.phase == (unknown ? .unconfirmed : .delivered))
            #expect(await peer.promptCount == (unknown ? 2 : 3))
            await reopened.shutdown()
        } catch { await reopened.shutdown(); throw error }
    } catch { await engine.shutdown(); try? FileManager.default.removeItem(at: root); throw error }
    try FileManager.default.removeItem(at: root)
}

@Test func openCodeV1SteeringRechecksQuestionAfterHeldCommandDiscovery() async throws {
    try await withV1Session { f in
        let thread = try await v1ReadyToSteer(f), opening = try #require(thread.activeRun?.nativeTurnID)
        await f.peer.holdCommandReads()
        let task = Task { try await f.session.steer(input: .init(text: "Show $MISSING_NATIVE_SKILL literally"), thread: thread,
            expectedTurnID: opening, clientMessageID: "preflight-steering") }
        try await v1Eventually { await f.peer.commandReadHeld }
        try await f.peer.question(id: "question-during-discovery")
        try await v1Eventually { await f.record.approvals.count == 1 }
        await f.peer.releaseCommands()
        await #expect(throws: ProviderSteeringError(.staleTarget)) { try await task.value }
        #expect(await f.peer.promptCount == 1)
        #expect(await f.record.approvals.count == 1)
    }
}

@Test func openCodeV1SteeringInvalidatesStatusReadStartedBeforeItsNativeAdmission() async throws {
    try await withV1Session(mode: .heldAck) { f in
        var thread = f.thread()
        let initialThread = thread
        let send = Task { try await f.session.send(text: "Original delayed acknowledgement", thread: initialThread) }
        try await v1Eventually { await f.peer.promptCount == 1 }
        await f.peer.holdStatusRead()
        try await f.peer.idle()
        try await f.peer.begin()
        await f.peer.release()
        try await send.value
        try await v1Eventually { await f.peer.statusReadHeld }
        thread.providerThreadID = "ses_root"
        thread.activeRun?.nativeTurnID = await f.record.turns.first
        let opening = try #require(thread.activeRun?.nativeTurnID)
        _ = try await f.session.steer(input: .init(text: "Admitted after status started"), thread: thread,
            expectedTurnID: opening, clientMessageID: "new-generation-steering")
        try await f.peer.begin(assistant: "msg_new_generation")
        try await v1Eventually { await f.record.associations["new-generation-steering"] != nil }
        await f.peer.releaseStatus()
        try await v1Eventually { await f.peer.heldStatusReturns == 1 }
        // Drain actor scheduling after the controlled stale reply; no timeout
        // extension or native retry is used to make the obsolete read succeed.
        for _ in 0..<8 { await Task.yield() }
        #expect(await f.record.completions.isEmpty)
        #expect(await f.session.steeringCapabilities().supportsActiveSteering)
        try await f.peer.idle()
        try await v1Eventually { await f.record.completions == [.idle] }
        #expect(await f.record.turns == [opening])
    }
}
