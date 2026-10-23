import Foundation
import Testing
@testable import CoincideCore

@Test func contextHandoffOpenCodeV2UsesLabeledPortableEnvelopeAndLiteralAppInput() async throws {
    try await withOpenCodeV2Session { fixture in
        let input = try contextHandoffTestInput()
        #expect(try await fixture.session.contextInputDisposition(input: .init(text: "/tmp/foo"), thread: fixture.thread()) == .ordinary)
        #expect(try await fixture.session.contextInputDisposition(input: .init(text: "/review"), thread: fixture.thread()) == .nativeCommand)
        try await fixture.session.send(input: input, thread: fixture.thread())
        let calls = await fixture.transport.calls
        let prompt = try #require(calls.first { $0.path.last == "prompt" }?.body)
        #expect(prompt["text"] == .string(try input.providerText()))
        #expect(prompt["text"].string?.hasSuffix("User message:\n" + input.text) == true)
        try await fixture.transport.beginInput()
        try await fixture.transport.emit(.executionSucceeded)
        try await openCodeSessionEventually { await fixture.record.completions == [.idle] }
    }
}

@Test func openCodeV2ModelsShareInitializationAndNeverCreateOrPrompt() async throws {
    try await withOpenCodeV2Session { fixture in
        async let first = fixture.session.models()
        async let second = fixture.session.openCodeInventory()
        let (models, inventory) = try await (first, second)
        #expect(models.first?.id == fixture.model.catalogID)
        #expect(models.first?.openCodeSelection == fixture.model)
        #expect(models.first?.openCodeVariants == ["balanced", "fast"])
        #expect(inventory.defaults == [fixture.model])
        let connects = await fixture.transport.connects
        let calls = await fixture.transport.calls
        #expect(connects == 1)
        #expect(calls.isEmpty)
    }
}

@Test func openCodeV2AdmissionAndStepEndNeverCompleteUntilOwnedExecutionEnds() async throws {
    try await withOpenCodeV2Session { fixture in
        let thread = fixture.thread()
        try await fixture.session.send(text: "Exact authored input", thread: thread)
        try await openCodeSessionEventually { await fixture.record.turns.count == 1 }
        let beforeStart = await fixture.record.completions
        #expect(beforeStart.isEmpty)
        try await fixture.transport.beginInput()
        try await fixture.transport.emit(.stepEnded, fields: ["assistantMessageID": .string("msg_assistant_one")])
        try await fixture.transport.text(" first 🌍 ", assistant: "msg_assistant_one")
        try await openCodeSessionEventually { await fixture.record.assistantText.contains(" first 🌍 ") }
        let beforeTerminal = await fixture.record.completions
        #expect(beforeTerminal.isEmpty)
        try await fixture.transport.emit(.executionSucceeded)
        try await openCodeSessionEventually { await fixture.record.completions.count == 1 }
        try await fixture.transport.emit(.executionSucceeded)
        try await fixture.transport.emit(.executionInterrupted)
        try await fixture.transport.emit(.textEnded, fields: ["assistantMessageID": .string("msg_assistant_one"), "ordinal": .number(0), "text": .string(" full replacement 🌍 ")])
        try await openCodeSessionEventually { await fixture.record.assistantText.contains(" full replacement 🌍 ") }
        let completions = await fixture.record.completions
        let finalText = await fixture.record.assistantText
        #expect(completions == [.idle])
        #expect(finalText == " full replacement 🌍 ")
    }
}

@Test(arguments: [false, true])
func openCodeV2EventsBeforeHTTPReplyKeepExactRunAndDoNotBlockNextRun(_ lostReply: Bool) async throws {
    try await withOpenCodeV2Session(mode: lostReply ? .holdPromptReplyLost : .holdPromptReply) { fixture in
        let first = fixture.thread()
        let firstRun = try #require(first.activeRun?.id)
        let send = Task { try await fixture.session.send(text: "First", thread: first) }
        do {
            try await openCodeSessionEventually { await fixture.transport.promptCount == 1 }
            try await fixture.transport.beginInput()
            try await fixture.transport.text("early", assistant: "msg_assistant_one")
            try await fixture.transport.emit(.executionSucceeded)
            try await openCodeSessionEventually { await fixture.record.completions.count == 1 }
            await fixture.transport.setMode(.manual)
            var second = fixture.thread(nativeID: await fixture.transport.nativeID)
            second.activeRun = ActiveRun(id: UUID(), configuration: .init(thread: second), startedAt: Date())
            try await fixture.session.send(text: "Second", thread: second)
            try await fixture.transport.beginInput(assistant: "msg_successor")
            await fixture.transport.releasePrompt()
            try await send.value
            let turns = await fixture.record.turns
            let starts = await fixture.transport.promptCount
            #expect(Set(turns).count == 2)
            #expect(starts == 2)
            let firstOwners = await fixture.record.entityOwners
            #expect(firstOwners.contains(firstRun))
            let failures = await fixture.record.connectionFailures
            #expect(failures == 0)
            try await fixture.transport.text("successor survives the old reply", assistant: "msg_successor")
            try await fixture.transport.emit(.executionSucceeded)
            try await openCodeSessionEventually { await fixture.record.completions == [.idle, .idle] }
        } catch {
            await fixture.transport.releasePrompt(); _ = try? await send.value
            throw error
        }
    }
}

@Test func openCodeV2OldTerminalBeforeOwnedDeliveryCannotFinishLaterInput() async throws {
    try await withOpenCodeV2Session { fixture in
        try await fixture.session.send(text: "New input", thread: fixture.thread())
        try await fixture.transport.emit(.executionStarted)
        try await fixture.transport.emit(.executionSucceeded) // A prior, unowned execution.
        try await fixture.transport.beginInput()
        try await fixture.transport.text("owned execution still running", assistant: "msg_assistant_one")
        try await openCodeSessionEventually { await fixture.record.assistantText.contains("still running") }
        let beforeOwnEnd = await fixture.record.completions
        #expect(beforeOwnEnd.isEmpty)
        try await fixture.transport.emit(.executionSucceeded)
        try await openCodeSessionEventually { await fixture.record.completions == [.idle] }
    }
}

@Test func openCodeV2DeliveredInputTerminalWithoutExecutionStartRequiresReconciliation() async throws {
    try await withOpenCodeV2Session { fixture in
        try await fixture.session.send(text: "Do not invent the missing start", thread: fixture.thread())
        try await fixture.transport.beginInput(includeStart: false)
        try await fixture.transport.emit(.executionSucceeded)
        try await openCodeSessionEventually { await fixture.record.connectionFailures == 1 }
        let completions = await fixture.record.completions
        #expect(completions.isEmpty)
    }
}

@Test func openCodeV2StopDuringConfigurationPreventsEveryLatePrompt() async throws {
    try await withOpenCodeV2Session(mode: .holdConfiguration) { fixture in
        let thread = fixture.thread()
        let send = Task { try await fixture.session.send(text: "Must remain unsent", thread: thread) }
        do {
            try await openCodeSessionEventually { await fixture.transport.configurationHeld }
            try await fixture.session.interrupt()
            await fixture.transport.releaseConfiguration()
            let result = await send.result
            if case .success = result { Issue.record("A stopped configuration admitted an input.") }
            let prompts = await fixture.transport.promptCount
            #expect(prompts == 0)
        } catch {
            await fixture.transport.releaseConfiguration(); _ = await send.result
            throw error
        }
    }
}

@Test func openCodeV2StopBeforeAdmissionEvidenceDrainsUnknownPOSTInsteadOfConfirmingCancellation() async throws {
    try await withOpenCodeV2Session(mode: .holdPromptBeforeAdmission) { fixture in
        let thread = fixture.thread()
        let send = Task { try await fixture.session.send(text: "Must not appear after a confirmed Stop", thread: thread) }
        do {
            try await openCodeSessionEventually { await fixture.transport.promptHeldBeforeAdmission }
            var stopError: OpenCodeV2SessionError?
            do { try await fixture.session.interrupt() }
            catch { stopError = error as? OpenCodeV2SessionError }
            await fixture.transport.releasePrompt()
            let result = await send.result
            #expect(stopError == .uncertainDelivery)
            if case .success = result { Issue.record("An unknown, stopped POST completed after owned cleanup.") }
            try await openCodeSessionEventually { await fixture.record.connectionFailures == 1 }
            let admissions = await fixture.transport.nativeAdmissions
            let closed = await fixture.transport.closeCount
            let failures = await fixture.record.connectionFailures
            #expect(admissions == 0)
            #expect(closed == 1)
            #expect(failures == 1)
        } catch {
            await fixture.transport.releasePrompt(); _ = await send.result
            throw error
        }
    }
}

@Test func openCodeV2CapturedControlsSurviveFutureHeaderAndResumeWithoutNewSession() async throws {
    try await withOpenCodeV2Session { fixture in
        var first = fixture.thread()
        let captured = first.activeRun?.configuration.openCodeConfiguration
        first.openCodeConfiguration = fixture.configuration.selecting(model: .init(providerID: "provider-fixture", id: "wire-model", variant: "fast"))
        first.model = first.openCodeConfiguration?.model?.catalogID ?? ""
        first.permission = .fullAccess
        try await fixture.session.send(text: "Captured first", thread: first)
        let initialCalls = await fixture.transport.calls
        let firstModel = initialCalls.first { $0.path.last == "model" }?.body?["model"]
        #expect(firstModel?["variant"] == .string("balanced"))
        #expect(captured?.model?.variant == "balanced")
        let initialRules = initialCalls.first { $0.method == "PATCH" }?.body?["permissions"].array
        #expect(initialRules?.contains(.object(["action": .string("shell"), "resource": .string("*"), "effect": .string("ask")])) == true)
        try await fixture.transport.beginInput()
        try await fixture.transport.emit(.executionSucceeded)
        try await openCodeSessionEventually { await fixture.record.completions.count == 1 }
        var next = first
        next.providerThreadID = await fixture.transport.nativeID
        next.activeRun = .init(id: UUID(), configuration: .init(thread: next), startedAt: Date())
        try await fixture.session.send(text: "Future controls now apply", thread: next)
        let calls = await fixture.transport.calls
        let modelBodies = calls.filter { $0.method == "POST" && $0.path.last == "model" }.compactMap(\.body)
        #expect(modelBodies.last?["model"]["variant"] == .string("fast"))
        #expect(calls.filter { $0.method == "POST" && $0.path == ["api", "session"] }.count == 1)
    }
}

@Test(arguments: [OpenCodeSessionFault.lostPrompt, .rejectedPrompt])
private func openCodeV2LostAdmissionNeverReplaysAndDefiniteRejectionRemainsDistinct(_ fault: OpenCodeSessionFault) async throws {
    try await withOpenCodeV2Session(mode: fault) { fixture in
        var received: OpenCodeV2SessionError?
        do { try await fixture.session.send(text: "Only one admission", thread: fixture.thread()) }
        catch { received = error as? OpenCodeV2SessionError }
        #expect(received == (fault == .lostPrompt ? .uncertainDelivery : .rejected))
        if fault == .lostPrompt {
            try await openCodeSessionEventually { await fixture.record.connectionFailures == 1 }
            do { try await fixture.session.send(text: "Forbidden retry", thread: fixture.thread()) }
            catch { /* A closed/uncertain actor cannot post a second input. */ }
            let count = await fixture.transport.promptCount
            #expect(count == 1)
        }
        let completions = await fixture.record.completions
        #expect(completions.isEmpty)
    }
}

@Test func openCodeV2StreamLossCannotCompleteOrAutomaticallyResubmit() async throws {
    try await withOpenCodeV2Session { fixture in
        try await fixture.session.send(text: "One native input", thread: fixture.thread())
        try await fixture.transport.beginInput()
        await fixture.transport.disconnect()
        try await openCodeSessionEventually { await fixture.record.connectionFailures == 1 }
        do { try await fixture.session.send(text: "Not an implicit recovery", thread: fixture.thread()) }
        catch { }
        let count = await fixture.transport.promptCount
        let completions = await fixture.record.completions
        #expect(count == 1)
        #expect(completions.isEmpty)
    }
}

@Test(arguments: [false, true])
func openCodeV2ResumeRejectsWrongDirectoryAndForeignBusyWorkWithoutPrompt(_ wrongDirectory: Bool) async throws {
    try await withOpenCodeV2Session { fixture in
        let native = "ses_existing_owned"
        await fixture.transport.seedSession(id: native, wrongDirectory: wrongDirectory, busy: !wrongDirectory)
        do { try await fixture.session.send(text: "Never sent", thread: fixture.thread(nativeID: native)) }
        catch { }
        let calls = await fixture.transport.calls
        #expect(calls.allSatisfy { $0.method == "GET" })
        #expect(calls.contains { $0.path == ["api", "session", native] })
    }
}

@Test func openCodeV2PermissionCancelDeclineAndConversationGrantUseDifferentNativeActions() async throws {
    try await withOpenCodeV2Session { fixture in
        try await fixture.session.send(text: "Permission fixture", thread: fixture.thread())
        try await fixture.transport.beginInput()
        try await fixture.transport.permission(id: "per_session")
        try await openCodeSessionEventually { await fixture.record.approvals.count == 1 }
        let firstObserved = await fixture.record.approvals.first
        let first = try #require(firstObserved)
        #expect(first.params["options"].array?.contains(where: { $0["optionId"] == .string("session") }) == true)
        try await fixture.session.choose(first, optionID: "session")
        let sessionCalls = await fixture.transport.calls
        let grant = sessionCalls.last { $0.method == "PATCH" }?.body?["permissions"].array
        #expect(grant?.contains(.object(["action": .string("shell"), "resource": .string("printf safe"), "effect": .string("allow")])) == true)
        #expect(sessionCalls.last { $0.path.last == "reply" }?.body == .object(["decision": .string("once")]))

        try await fixture.transport.permission(id: "per_decline")
        try await openCodeSessionEventually { await fixture.record.approvals.count == 2 }
        let secondObserved = await fixture.record.approvals.last
        let second = try #require(secondObserved)
        try await fixture.session.choose(second, optionID: "reject")
        let declined = await fixture.transport.calls
        let note = declined.last { $0.path.last == "synthetic" }?.body
        #expect(note?["resume"] == .bool(false))
        #expect(declined.last { $0.path.last == "reply" }?.body?["message"] == .string("The user declined this request."))
        #expect(declined.filter { $0.path.last == "interrupt" }.isEmpty)

        try await fixture.transport.permission(id: "per_cancel")
        try await openCodeSessionEventually { await fixture.record.approvals.count == 3 }
        let thirdObserved = await fixture.record.approvals.last
        let third = try #require(thirdObserved)
        try await fixture.session.respond(third, allow: false)
        let cancelled = await fixture.transport.calls
        #expect(cancelled.last { $0.path.last == "reply" }?.body == .object(["decision": .string("reject")]))
        // A native no-message reject already interrupts the asker. A second
        // asynchronous interrupt could instead stop the next FIFO execution.
        #expect(cancelled.filter { $0.path.last == "interrupt" }.isEmpty)
        do { try await fixture.session.respond(third, allow: true); Issue.record("A stale request was answered twice.") }
        catch { #expect(error as? OpenCodeV2SessionError == .staleRequest) }
    }
}

@Test func openCodeV2FormsPreserveWireOptionsAndUnsupportedFormsRemainCancellable() async throws {
    try await withOpenCodeV2Session { fixture in
        try await fixture.session.send(text: "Form fixture", thread: fixture.thread())
        try await fixture.transport.beginInput()
        try await fixture.transport.form(id: "frm_choice", unsupported: false)
        try await openCodeSessionEventually { await fixture.record.approvals.count == 1 }
        let observed = await fixture.record.approvals.first
        let request = try #require(observed)
        try await fixture.session.selectAnswers(request, selections: ["choice": ["wire-b"]])
        let calls = await fixture.transport.calls
        #expect(calls.last?.body == .object(["answer": .object(["choice": .array([.string("wire-b")])])]))
        try await fixture.transport.form(id: "frm_numeric", unsupported: true)
        try await openCodeSessionEventually { await fixture.record.approvals.count == 2 }
        let unsupportedObserved = await fixture.record.approvals.last
        let unsupported = try #require(unsupportedObserved)
        #expect(unsupported.params["unsupportedReason"].string != nil)
        do { try await fixture.session.answer(unsupported, answers: ["choice": "1"]); Issue.record("An unsupported form fabricated a native value.") }
        catch { #expect(error as? OpenCodeV2ProtocolError == .unsupportedForm) }
        try await fixture.session.respond(unsupported, allow: false)
        let final = await fixture.transport.calls
        #expect(final.last?.method == "DELETE")
        #expect(final.last?.path.suffix(2) == ["form", "frm_numeric"])
    }
}

@Test(arguments: [false, true], [false, true])
func openCodeV2BackgroundChildKeepsOriginalRunAndCannotFinishNextRoot(_ childBeforeLink: Bool, _ parentFails: Bool) async throws {
    try await withOpenCodeV2Session { fixture in
        let first = fixture.thread()
        let firstRun = try #require(first.activeRun?.id)
        try await fixture.session.send(text: "Start parent", thread: first)
        try await fixture.transport.beginInput()
        try await fixture.transport.emit(.toolInputStarted, fields: ["assistantMessageID": .string("msg_assistant_one"), "id": .string("call_child"), "name": .string("subagent")])
        if childBeforeLink {
            let observedParentID = await fixture.transport.nativeID
            let parentID = try #require(observedParentID)
            try await fixture.transport.emit(.sessionCreated, session: "ses_child", fields: ["parentID": .string(parentID), "location": .object(["directory": .string(fixture.root.path)])])
            try await fixture.transport.emit(.executionStarted, session: "ses_child")
            try await fixture.transport.step(assistant: "msg_child", session: "ses_child")
            try await fixture.transport.text("early child survives link", assistant: "msg_child", session: "ses_child")
        }
        try await fixture.transport.emit(.toolProgress, fields: ["assistantMessageID": .string("msg_assistant_one"), "id": .string("call_child"), "metadata": .object(["sessionID": .string("ses_child"), "status": .string("running")])])
        if childBeforeLink {
            try await openCodeSessionEventually { await fixture.record.backgroundText.contains("early child survives link") }
        }
        try await fixture.transport.emit(parentFails ? .executionFailed : .executionSucceeded)
        try await openCodeSessionEventually { await fixture.record.completions.count == 1 }
        var second = fixture.thread(nativeID: await fixture.transport.nativeID)
        second.activeRun = .init(id: UUID(), configuration: .init(thread: second), startedAt: Date())
        try await fixture.session.send(text: "Next root", thread: second)
        try await fixture.transport.beginInput(assistant: "msg_assistant_two")
        if !childBeforeLink {
            try await fixture.transport.emit(.executionStarted, session: "ses_child")
            try await fixture.transport.step(assistant: "msg_child", session: "ses_child")
        }
        try await fixture.transport.text("same exact text", assistant: "msg_child", session: "ses_child")
        try await fixture.transport.text("same exact text", assistant: "msg_foreign", session: "ses_foreign")
        try await fixture.transport.emit(.executionSucceeded, session: "ses_child")
        try await openCodeSessionEventually { await fixture.record.backgroundText.contains("same exact text") }
        let beforeRootEnd = await fixture.record.completions
        let backgroundOwners = await fixture.record.backgroundOwners
        let keys = await fixture.record.entityKeys
        #expect(beforeRootEnd == [parentFails ? .failed : .idle])
        #expect(backgroundOwners == Set([firstRun]))
        #expect(keys.allSatisfy { !$0.sessionID.contains("ses_foreign") })
        let disconnected = await fixture.record.connectionFailures
        #expect(disconnected == 0)
        try await fixture.transport.emit(.executionSucceeded)
        try await openCodeSessionEventually { await fixture.record.completions.count == 2 }
    }
}

@Test(arguments: [false, true])
func openCodeV2MalformedJSONOrUnownedCriticalIdentityRequiresReconciliation(_ invalidIdentity: Bool) async throws {
    try await withOpenCodeV2Session { fixture in
        try await fixture.session.send(text: "Retain uncertain native execution", thread: fixture.thread())
        try await fixture.transport.beginInput()
        if invalidIdentity {
            await fixture.transport.raw("{\"type\":\"session.execution.succeeded\",\"data\":{\"sessionID\":7}}")
        } else { await fixture.transport.raw("{\"type\":\"session.execution.succeeded\",\"data\":") }
        try await openCodeSessionEventually { await fixture.record.connectionFailures == 1 }
        let completions = await fixture.record.completions
        #expect(completions.isEmpty)
    }
}

@Test func openCodeV2UnreadableAutonomousStartCannotCreateAnActivityOwner() async throws {
    try await withOpenCodeV2Session(mode: .holdConfiguration) { fixture in
        let thread = fixture.thread()
        let send = Task { try await fixture.session.send(text: "Never dispatched", thread: thread) }
        do {
            try await openCodeSessionEventually { await fixture.transport.configurationHeld }
            try await fixture.session.interrupt()
            await fixture.transport.releaseConfiguration()
            _ = await send.result
            let observedID = await fixture.transport.nativeID
            let nativeID = try #require(observedID)
            let invalid: JSONValue = .object(["id": .string("evt_invalid_autonomous"), "created": .number(1),
                "type": .string("session.execution.started"), "data": .object(["sessionID": .string(nativeID)]),
                "durable": .object(["aggregateID": .string(nativeID), "seq": .string("invalid"), "version": .number(1)])])
            let bytes = try JSONEncoder().encode(invalid)
            await fixture.transport.raw(String(decoding: bytes, as: UTF8.self))
            try await openCodeSessionEventually { await fixture.record.connectionFailures == 1 }
            let activities = await fixture.record.activities
            #expect(activities.isEmpty)
        } catch {
            await fixture.transport.releaseConfiguration(); _ = await send.result
            throw error
        }
    }
}

@Test func openCodeV2AutonomousStopInterruptsExactOwnerWithoutInventingAnInboxID() async throws {
    try await withOpenCodeV2Session { fixture in
        try await fixture.session.send(text: "First user run", thread: fixture.thread())
        try await fixture.transport.beginInput()
        try await fixture.transport.emit(.executionSucceeded)
        try await openCodeSessionEventually { await fixture.record.completions.count == 1 }
        try await fixture.transport.emit(.executionStarted)
        try await openCodeSessionEventually { await fixture.record.activities.contains(where: { $0.state == .running }) }
        try await fixture.session.interrupt()
        let calls = await fixture.transport.calls
        #expect(calls.filter { $0.method == "DELETE" }.isEmpty)
        #expect(calls.last?.path.last == "interrupt")
        #expect(calls.allSatisfy { $0.path.allSatisfy { !$0.isEmpty } })
        try await fixture.transport.emit(.executionInterrupted)
        try await openCodeSessionEventually { await fixture.record.activities.contains(where: { $0.state == .idle }) }
        let activities = await fixture.record.activities
        #expect(activities.count == 2)
        #expect(activities.first?.id == activities.last?.id)
        #expect(activities.last?.stopReason == .string("cancelled"))
    }
}

@Test func openCodeV2LateCancelReplyNeverInterruptsTheSuccessorRun() async throws {
    try await withOpenCodeV2Session { fixture in
        try await fixture.session.send(text: "Original run", thread: fixture.thread())
        try await fixture.transport.beginInput()
        try await fixture.transport.permission(id: "per_held_cancel")
        try await openCodeSessionEventually { await fixture.record.approvals.count == 1 }
        let observed = await fixture.record.approvals.first
        let request = try #require(observed)
        await fixture.transport.setMode(.holdPermissionReply)
        let answer = Task { try await fixture.session.respond(request, allow: false) }
        do {
            try await openCodeSessionEventually { await fixture.transport.permissionReplyHeld }
            try await fixture.transport.emit(.permissionReplied, fields: ["requestID": .string("per_held_cancel")])
            try await fixture.transport.emit(.executionInterrupted)
            try await openCodeSessionEventually { await fixture.record.completions == [.interrupted] }
            await fixture.transport.setMode(.manual)
            let next = fixture.thread(nativeID: await fixture.transport.nativeID)
            try await fixture.session.send(text: "Successor must keep running", thread: next)
            try await fixture.transport.beginInput(assistant: "msg_successor")
            await fixture.transport.releasePermissionReply()
            try await answer.value
            let calls = await fixture.transport.calls
            #expect(calls.filter { $0.path.last == "interrupt" }.isEmpty)
            try await fixture.transport.emit(.executionSucceeded)
            try await openCodeSessionEventually { await fixture.record.completions == [.interrupted, .idle] }
        } catch {
            await fixture.transport.releasePermissionReply(); _ = try? await answer.value
            throw error
        }
    }
}

@Test(.timeLimit(.minutes(1)))
func openCodeV2SequentialRunsDoNotShareTheProjectionByteBudget() async throws {
    try await withOpenCodeV2Session { fixture in
        let chunk = String(repeating: "x", count: 500_000)
        for index in 0..<2 {
            let thread = fixture.thread(nativeID: await fixture.transport.nativeID)
            try await fixture.session.send(text: "Independent projection \(index)", thread: thread)
            let assistant = "msg_budget_\(index)"
            try await fixture.transport.beginInput(assistant: assistant)
            // Each run stays below 16 MiB, while both together exceed it.
            for ordinal in 0..<5 {
                try await fixture.transport.emit(.textStarted, fields: ["assistantMessageID": .string(assistant), "ordinal": .number(Double(ordinal))])
                for _ in 0..<4 {
                    try await fixture.transport.emit(.textDelta, fields: ["assistantMessageID": .string(assistant), "ordinal": .number(Double(ordinal)), "delta": .string(chunk)])
                }
            }
            try await fixture.transport.emit(.executionSucceeded)
            try await openCodeSessionEventually { await fixture.record.completions.count == index + 1 }
        }
        let failures = await fixture.record.connectionFailures
        #expect(failures == 0)
        let starts = await fixture.transport.promptCount
        #expect(starts == 2)
    }
}

@Test func openCodeV2SteeringKeepsOriginalTurnAndCapturedControlsAndDoesNotReplayAnInboxID() async throws {
    try await withOpenCodeV2Session { fixture in
        let thread = try await fixture.readyToSteer()
        let original = try #require(thread.activeRun?.nativeTurnID)
        let before = await fixture.transport.calls
        let receipt = try await fixture.session.steer(input: .init(text: "Steer 工作 🌍"), thread: thread,
            expectedTurnID: original, clientMessageID: "local-steer-one")
        #expect(receipt.turnID == original && receipt.delivery == .acknowledged)
        let calls = await fixture.transport.calls
        #expect(calls.count == before.count + 1)
        let call = try #require(calls.last), body = try #require(call.body)
        #expect(call.path == ["api", "session", thread.providerThreadID!, "prompt"])
        #expect(body["id"].string?.hasPrefix("msg_coincide_steer_") == true)
        #expect(body["delivery"] == .string("steer") && body["text"] == .string("Steer 工作 🌍"))
        #expect(body["model"] == .null && body["agent"] == .null && body["permissions"] == .null && body["resume"] == .null)
        let again = try await fixture.session.steer(input: .init(text: "Steer 工作 🌍"), thread: thread,
            expectedTurnID: original, clientMessageID: "local-steer-one")
        #expect(again == receipt)
        await #expect(throws: ProviderSteeringError(.invalidRequest)) {
            try await fixture.session.steer(input: .init(text: "Different input under the old ID"), thread: thread,
                expectedTurnID: original, clientMessageID: "local-steer-one")
        }
        let afterDuplicate = await fixture.transport.calls
        #expect(afterDuplicate.count == calls.count)
        let turns = await fixture.record.turns
        #expect(turns == [original], "Additional inbox messages never replace the original native run boundary.")
    }
}

@Test(arguments: [false, true])
func openCodeV2SteerSpansExecutionEndAndDeliveredBeforeNextStartWhileLateReplyKeepsItsOriginalRun(_ lostReply: Bool) async throws {
    try await withOpenCodeV2Session { fixture in
        let thread = try await fixture.readyToSteer(), original = try #require(thread.activeRun?.nativeTurnID)
        let originalRun = try #require(thread.activeRun?.id)
        await fixture.transport.setMode(lostReply ? .holdPromptReplyLost : .holdPromptReply)
        let steering = Task { try await fixture.session.steer(input: .init(text: "Delayed steer"), thread: thread,
            expectedTurnID: original, clientMessageID: "held-steer") }
        do {
            try await openCodeSessionEventually { await fixture.transport.promptCount == 2 }
            let steerCalls = await fixture.transport.calls
            let inbox = try #require(steerCalls.last?.body?["id"].string)
            try await fixture.transport.emit(.executionSucceeded)
            try await fixture.transport.snapshotBarrier("held-first-terminal")
            try await openCodeSessionEventually { await fixture.record.assistantText == "held-first-terminal" }
            #expect(await fixture.record.completions.isEmpty)
            try await fixture.transport.emit(.inboxDelivered, fields: ["inboxID": .string(inbox)])
            try await fixture.transport.snapshotBarrier("delivered-awaiting-next-start")
            try await openCodeSessionEventually { await fixture.record.assistantText == "delivered-awaiting-next-start" }
            #expect(await fixture.record.completions.isEmpty)
            try await fixture.transport.emit(.executionStarted)
            try await fixture.transport.step(assistant: "msg_steered_execution")
            try await fixture.transport.text("second execution retained by original run", assistant: "msg_steered_execution")
            try await fixture.transport.emit(.executionSucceeded)
            try await openCodeSessionEventually { await fixture.record.completions == [.idle] }
            #expect(await fixture.record.entityOwners == [originalRun])
            #expect(await fixture.record.activities.isEmpty)
            await fixture.transport.setMode(.manual)
            let successor = fixture.thread(nativeID: await fixture.transport.nativeID)
            try await fixture.session.send(text: "Independent successor", thread: successor)
            try await fixture.transport.beginInput(assistant: "msg_successor_steer_test")
            await fixture.transport.releasePrompt()
            let receipt = try await steering.value
            #expect(receipt.turnID == original)
            #expect(await fixture.record.connectionFailures == 0)
            try await fixture.transport.emit(.executionSucceeded)
            try await openCodeSessionEventually { await fixture.record.completions == [.idle, .idle] }
            #expect(await fixture.transport.promptCount == 3)
        } catch { await fixture.transport.releasePrompt(); _ = await steering.result; throw error }
    }
}

@Test func openCodeV2CancelledSteerReleasesOnlyItsHeldTerminalWithoutInventingAnotherExecution() async throws {
    try await withOpenCodeV2Session { fixture in
        let thread = try await fixture.readyToSteer(), original = try #require(thread.activeRun?.nativeTurnID)
        _ = try await fixture.session.steer(input: .init(text: "Cancel this inbox item"), thread: thread,
            expectedTurnID: original, clientMessageID: "cancelled-steer")
        let calls = await fixture.transport.calls, inbox = try #require(calls.last?.body?["id"].string)
        try await fixture.transport.emit(.executionSucceeded)
        try await fixture.transport.snapshotBarrier("cancel-held-terminal")
        try await openCodeSessionEventually { await fixture.record.assistantText == "cancel-held-terminal" }
        #expect(await fixture.record.completions.isEmpty)
        try await fixture.transport.emit(.inboxCancelled, fields: ["inboxID": .string(inbox)])
        try await openCodeSessionEventually { await fixture.record.completions == [.idle] }
        try await fixture.transport.emit(.inboxCancelled, fields: ["inboxID": .string(inbox)])
        #expect(await fixture.record.activities.isEmpty)
        #expect(await fixture.record.turns == [original])
    }
}

@Test(arguments: [false, true])
func openCodeV2RejectedAndUncertainSteerNeverAutomaticallyResubmit(_ lost: Bool) async throws {
    try await withOpenCodeV2Session { fixture in
        let thread = try await fixture.readyToSteer(), original = try #require(thread.activeRun?.nativeTurnID)
        await fixture.transport.setMode(lost ? .lostPrompt : .rejectedPrompt)
        await #expect(throws: ProviderSteeringError(lost ? .outcomeUncertain : .rejected)) {
            try await fixture.session.steer(input: .init(text: "One attempted steer"), thread: thread,
                expectedTurnID: original, clientMessageID: "one-attempt")
        }
        if lost {
            try await openCodeSessionEventually { await fixture.record.connectionFailures == 1 }
            await #expect(throws: ProviderSteeringError(.noActiveTurn)) {
                try await fixture.session.steer(input: .init(text: "One attempted steer"), thread: thread,
                    expectedTurnID: original, clientMessageID: "one-attempt")
            }
        } else {
            #expect(await fixture.record.connectionFailures == 0)
            try await fixture.transport.emit(.executionSucceeded)
            try await openCodeSessionEventually { await fixture.record.completions == [.idle] }
        }
        #expect(await fixture.transport.promptCount == 2)
    }
}

@Test func openCodeV2StaleSteeringAndPendingNativeQuestionRefuseBeforeAnyWrite() async throws {
    try await withOpenCodeV2Session { fixture in
        let thread = try await fixture.readyToSteer(), original = try #require(thread.activeRun?.nativeTurnID)
        var future = thread
        future.openCodeConfiguration = fixture.configuration.selecting(model: .init(providerID: "provider-fixture", id: "wire-model", variant: "fast"))
        future.permission = .fullAccess
        let futureCapture = future
        await #expect(throws: ProviderSteeringError(.staleTarget)) {
            try await fixture.session.steer(input: .init(text: "Wrong future capture"), thread: futureCapture,
                expectedTurnID: original, clientMessageID: "future-capture")
        }
        await #expect(throws: ProviderSteeringError(.staleTarget)) {
            try await fixture.session.steer(input: .init(text: "Wrong boundary"), thread: thread,
                expectedTurnID: "msg_unrelated", clientMessageID: "wrong-boundary")
        }
        try await fixture.transport.permission(id: "per_blocks_steer")
        try await openCodeSessionEventually { await fixture.record.approvals.count == 1 }
        #expect(await fixture.session.steeringCapabilities().supportsActiveSteering == false)
        await #expect(throws: ProviderSteeringError(.noActiveTurn)) {
            try await fixture.session.steer(input: .init(text: "Question still pending"), thread: thread,
                expectedTurnID: original, clientMessageID: "pending-question")
        }
        #expect(await fixture.transport.promptCount == 1)
    }
}

@Test func openCodeV2StopCancelsExactAdmittedSteersAndTheOriginalInboxBeforeInterrupting() async throws {
    try await withOpenCodeV2Session { fixture in
        let thread = try await fixture.readyToSteer(), original = try #require(thread.activeRun?.nativeTurnID)
        _ = try await fixture.session.steer(input: .init(text: "Pending steer"), thread: thread,
            expectedTurnID: original, clientMessageID: "stop-owned-steer")
        let before = await fixture.transport.calls, inbox = try #require(before.last?.body?["id"].string)
        try await fixture.session.interrupt()
        let calls = await fixture.transport.calls
        #expect(calls.filter { $0.method == "DELETE" }.map { $0.path.last! } == [inbox, original])
        #expect(calls.last?.path.last == "interrupt")
        try await fixture.transport.emit(.inboxCancelled, fields: ["inboxID": .string(inbox)])
        try await fixture.transport.emit(.executionInterrupted)
        try await openCodeSessionEventually { await fixture.record.completions == [.interrupted] }
        #expect(await fixture.transport.promptCount == 2)
    }
}

@Test func openCodeV2StopWithUnknownSteerAdmissionDrainsTheExactOwnedRuntime() async throws {
    try await withOpenCodeV2Session { fixture in
        let thread = try await fixture.readyToSteer(), original = try #require(thread.activeRun?.nativeTurnID)
        await fixture.transport.setMode(.holdPromptBeforeAdmission)
        let steering = Task { try await fixture.session.steer(input: .init(text: "Unknown write at Stop"), thread: thread,
            expectedTurnID: original, clientMessageID: "unknown-at-stop") }
        do {
            try await openCodeSessionEventually { await fixture.transport.promptHeldBeforeAdmission }
            await #expect(throws: OpenCodeV2SessionError.uncertainDelivery) { try await fixture.session.interrupt() }
            let result = await steering.result
            if case .success = result { Issue.record("Unknown steering admission was reported delivered after Stop.") }
            #expect(await fixture.transport.closeCount == 1)
            #expect(await fixture.transport.nativeAdmissions == 1)
            #expect(await fixture.record.connectionFailures == 1)
        } catch { await fixture.transport.releasePrompt(); _ = await steering.result; throw error }
    }
}

@Test func openCodeV2SteeringStateIsBoundedWithoutDroppingPreviouslyAcceptedInboxOwnership() async throws {
    try await withOpenCodeV2Session { fixture in
        let thread = try await fixture.readyToSteer(), original = try #require(thread.activeRun?.nativeTurnID)
        for index in 0..<128 {
            _ = try await fixture.session.steer(input: .init(text: "Bounded steering \(index)"), thread: thread,
                expectedTurnID: original, clientMessageID: "bounded-\(index)")
        }
        #expect(await fixture.session.steeringCapabilities().supportsActiveSteering == false)
        await #expect(throws: ProviderSteeringError(.rejected)) {
            try await fixture.session.steer(input: .init(text: "Over the bounded limit"), thread: thread,
                expectedTurnID: original, clientMessageID: "over-limit")
        }
        #expect(await fixture.transport.promptCount == 129)
        let calls = await fixture.transport.calls
        let inboxIDs = calls.filter { $0.path.last == "prompt" && $0.body?["delivery"] == .string("steer") }.compactMap { $0.body?["id"].string }
        #expect(Set(inboxIDs).count == 128)
        try await fixture.transport.emit(.executionSucceeded)
        for inbox in inboxIDs { try await fixture.transport.emit(.inboxCancelled, fields: ["inboxID": .string(inbox)]) }
        try await openCodeSessionEventually { await fixture.record.completions == [.idle] }
    }
}

@Test func openCodeV2LateExpectedRunStopCannotInterruptTheSuccessorAfterSteeringSettles() async throws {
    try await withOpenCodeV2Session { fixture in
        let thread = try await fixture.readyToSteer(), original = try #require(thread.activeRun?.nativeTurnID)
        let oldRun = try #require(thread.activeRun?.id)
        _ = try await fixture.session.steer(input: .init(text: "Delivered within the first execution"), thread: thread,
            expectedTurnID: original, clientMessageID: "old-run-steer")
        let calls = await fixture.transport.calls, inbox = try #require(calls.last?.body?["id"].string)
        try await fixture.transport.emit(.inboxDelivered, fields: ["inboxID": .string(inbox)])
        try await fixture.transport.emit(.executionSucceeded)
        try await openCodeSessionEventually { await fixture.record.completions == [.idle] }
        let successor = fixture.thread(nativeID: await fixture.transport.nativeID)
        try await fixture.session.send(text: "Owned successor", thread: successor)
        try await fixture.transport.beginInput(assistant: "msg_owned_successor")
        try await openCodeSessionEventually { await fixture.session.steeringCapabilities().supportsActiveSteering }
        await #expect(throws: ProviderSteeringError(.staleTarget)) { try await fixture.session.interrupt(expectedRunID: oldRun) }
        let after = await fixture.transport.calls
        #expect(after.filter { $0.path.last == "interrupt" }.isEmpty)
        try await fixture.transport.emit(.executionSucceeded)
        try await openCodeSessionEventually { await fixture.record.completions == [.idle, .idle] }
    }
}

@Test func openCodeV2FailedExecutionTakesBackOnlyItsStrandedSteerBeforeAnotherNormalPrompt() async throws {
    try await withOpenCodeV2Session { fixture in
        let thread = try await fixture.readyToSteer(), original = try #require(thread.activeRun?.nativeTurnID)
        _ = try await fixture.session.steer(input: .init(text: "Stranded after native failure"), thread: thread,
            expectedTurnID: original, clientMessageID: "stranded-steer")
        let initialCalls = await fixture.transport.calls, inbox = try #require(initialCalls.last?.body?["id"].string)
        try await fixture.transport.emit(.executionFailed)
        try await openCodeSessionEventually { await fixture.record.completions == [.failed] }
        let successor = fixture.thread(nativeID: await fixture.transport.nativeID)
        try await fixture.session.send(text: "New input after exact inbox cleanup", thread: successor)
        let calls = await fixture.transport.calls
        let cancellation = try #require(calls.firstIndex { $0.method == "DELETE" })
        let nextPrompt = try #require(calls.lastIndex { $0.path.last == "prompt" })
        #expect(cancellation < nextPrompt && calls[cancellation].path.last == inbox)
        #expect(calls.filter { $0.method == "DELETE" }.count == 1)
        try await fixture.transport.beginInput(assistant: "msg_after_failure")
        try await fixture.transport.emit(.inboxCancelled, fields: ["inboxID": .string(inbox)])
        try await fixture.transport.text("successor remains alive", assistant: "msg_after_failure")
        try await openCodeSessionEventually { await fixture.record.assistantText.contains("successor remains alive") }
        #expect(await fixture.record.completions == [.failed])
        #expect(await fixture.record.connectionFailures == 0)
        try await fixture.transport.emit(.executionSucceeded)
        try await openCodeSessionEventually { await fixture.record.completions == [.failed, .idle] }
    }
}

@Test func openCodeV2CallerCancellationAfterSteeringWriteKeepsDeliveryUncertainWithoutRetry() async throws {
    try await withOpenCodeV2Session { fixture in
        let thread = try await fixture.readyToSteer(), original = try #require(thread.activeRun?.nativeTurnID)
        await fixture.transport.setMode(.holdPromptReply)
        let steering = Task { try await fixture.session.steer(input: .init(text: "Cancelled local wait after write"), thread: thread,
            expectedTurnID: original, clientMessageID: "cancelled-wait") }
        do {
            try await openCodeSessionEventually { await fixture.transport.promptCount == 2 }
            steering.cancel(); await fixture.transport.releasePrompt()
            var error: ProviderSteeringError?
            do { _ = try await steering.value } catch let failure as ProviderSteeringError { error = failure }
            #expect(error == .init(.outcomeUncertain))
            try await openCodeSessionEventually { await fixture.record.connectionFailures == 1 }
            #expect(await fixture.transport.promptCount == 2)
        } catch { await fixture.transport.releasePrompt(); _ = await steering.result; throw error }
    }
}

private struct OpenCodeSessionCall: Sendable {
    let method: String
    let path: [String]
    let body: JSONValue?
}

private enum OpenCodeSessionFault: Sendable, Equatable {
    case manual, holdPromptReply, holdPromptReplyLost, holdPromptBeforeAdmission, holdConfiguration, holdPermissionReply, lostPrompt, rejectedPrompt
}

private actor OpenCodeSessionGate {
    private var open = false
    private var waiters: [CheckedContinuation<Void, Never>] = []
    func wait() async { if open { return }; await withCheckedContinuation { waiters.append($0) } }
    func release() { open = true; let saved = waiters; waiters = []; for waiter in saved { waiter.resume() } }
}

private actor OpenCodeSessionRecord {
    var values: [ProviderEvent] = []
    private var entities: [ProviderEntityKey: ProviderEntity] = [:]
    private var background: Set<ProviderEntityKey> = []
    func append(_ event: ProviderEvent) {
        values.append(event)
        let inner = Self.inner(event)
        if case .entity(let update) = inner { entities[update.key] = try? update.apply(to: entities[update.key]) }
        if case .runEntity(_, let update) = inner { entities[update.key] = try? update.apply(to: entities[update.key]); background.insert(update.key) }
    }
    var turns: [String] { values.compactMap { if case .turn(let id) = Self.inner($0) { id } else { nil } } }
    var completions: [ThreadState] { values.compactMap { if case .completed(let state) = Self.inner($0) { state } else { nil } } }
    var connectionFailures: Int { values.filter { if case .connectionClosed = Self.inner($0) { true } else { false } }.count }
    var approvals: [ApprovalRequest] { values.compactMap { if case .sessionApproval(let request) = Self.inner($0) { request } else { nil } } }
    var assistantText: String { entities.values.filter { $0.role == .assistant && !$0.key.sessionID.hasSuffix(":ses_child") }.map(\.text).sorted().joined() }
    var backgroundText: String { entities.values.filter { $0.role == .assistant && $0.key.sessionID.hasSuffix(":ses_child") }.map(\.text).sorted().joined() }
    var entityKeys: [ProviderEntityKey] { Array(entities.keys) }
    var entityOwners: Set<UUID> { Set(values.compactMap { if case .context(let id, let event) = $0, case .entity = event { id } else { nil } }) }
    var backgroundOwners: Set<UUID> { Set(values.compactMap { if case .runEntity(let id, _) = $0 { id } else { nil } }) }
    var activities: [ProviderActivity] { values.compactMap { if case .activity(let value) = Self.inner($0) { value } else { nil } } }
    static func inner(_ event: ProviderEvent) -> ProviderEvent { if case .context(_, let inner) = event { inner } else { event } }
}

@Test func openCodeV2NativeSkillsAttachExactIDsInMentionOrderAndPreserveLiteralText() async throws {
    try await withOpenCodeV2Session { f in
        let text = "Inspect $skill-b $skill-a $skill-b with $HOME and $100"
        try await f.session.send(text: text, thread: f.thread())
        let calls = await f.transport.calls
        let body = try #require(calls.first { $0.path.last == "prompt" }?.body)
        #expect(body["text"] == .string(text))
        #expect(body["skills"] == .array([.object(["id": .string("skill-b")]), .object(["id": .string("skill-a")])]))
        #expect(!calls.contains { $0.path.last == "command" })
    }
}

@Test func openCodeV2ActiveSteerAttachesNativeSkillsButRefusesNativeCommandsBeforeWrite() async throws {
    try await withOpenCodeV2Session { f in
        let thread = try await f.readyToSteer()
        let target = try #require(thread.activeRun?.nativeTurnID)
        let receipt = try await f.session.steer(input: .init(text: "also $skill-b"), thread: thread,
            expectedTurnID: target, clientMessageID: "skill-steer")
        #expect(receipt.turnID == target)
        let calls = await f.transport.calls
        let body = try #require(calls.last { $0.path.last == "prompt" }?.body)
        #expect(body["delivery"] == .string("steer"))
        #expect(body["skills"] == .array([.object(["id": .string("skill-b")])]))
        let before = calls.count
        await #expect(throws: ProviderSteeringError(.unsupported)) {
            try await f.session.steer(input: .init(text: "/review now"), thread: thread,
                expectedTurnID: target, clientMessageID: "command-steer")
        }
        let after = await f.transport.calls
        #expect(after.count == before)
    }
}

@Test func openCodeV2CommandAdoptsObservedNativeInboxInsteadOfInventingCallerMessageID() async throws {
    try await withOpenCodeV2Session { f in
        try await f.session.send(text: "/review quoted \"argument\"\nline two", thread: f.thread())
        try await openCodeSessionEventually { await f.record.turns == ["msg_native_command"] }
        let calls = await f.transport.calls
        let body = try #require(calls.first { $0.path.last == "command" }?.body)
        #expect(body["name"] == .string("review"))
        #expect(body["text"] == .string("quoted \"argument\"\nline two"))
        #expect(body["delivery"] == .string("queue"))
        #expect(body["id"] == .null && body["resume"] == .null)
        #expect(!calls.contains { $0.path.last == "prompt" })
        let before = await f.record.completions
        #expect(before.isEmpty)
        try await f.transport.text("native command result", assistant: "msg_assistant_one")
        try await f.transport.emit(.executionSucceeded)
        try await openCodeSessionEventually { await f.record.completions == [.idle] }
    }
}

@Test(arguments: [false, true])
func openCodeV2CommandTerminalBeforeCallbackReplyCannotReleaseSuccessorOrHideLostReply(lost: Bool) async throws {
    try await withOpenCodeV2Session(mode: lost ? .holdPromptReplyLost : .holdPromptReply) { f in
        let send = Task { try await f.session.send(text: "/review held callback", thread: f.thread()) }
        do {
            try await openCodeSessionEventually { await f.record.turns == ["msg_native_command"] }
            try await f.transport.emit(.executionSucceeded)
            try await f.transport.snapshotBarrier("Terminal reached while callback still owns the command")
            try await openCodeSessionEventually { await f.record.assistantText.contains("Terminal reached") }
            let before = await f.record.completions
            #expect(before.isEmpty)
            await #expect(throws: OpenCodeV2SessionError.busy) { try await f.session.send(text: "Must not start early", thread: f.thread()) }
            let calls = await f.transport.calls
            #expect(!calls.contains { $0.path.last == "prompt" })
            await f.transport.releasePrompt()
            if lost {
                await #expect(throws: OpenCodeV2SessionError.uncertainDelivery) { try await send.value }
                try await openCodeSessionEventually { await f.record.connectionFailures == 1 }
                let completions = await f.record.completions
                #expect(completions.isEmpty)
            } else {
                try await send.value
                try await openCodeSessionEventually { await f.record.completions == [.idle] }
            }
        } catch { await f.transport.releasePrompt(); _ = await send.result; throw error }
    }
}

@Test func openCodeV2SecondRootAfterFirstTerminalIsAmbiguousUntilCallbackReturns() async throws {
    try await withOpenCodeV2Session(mode: .holdPromptReply) { f in
        let send = Task { try await f.session.send(text: "/review multiple roots", thread: f.thread()) }
        do {
            try await openCodeSessionEventually { await f.record.turns == ["msg_native_command"] }
            try await f.transport.emit(.executionSucceeded)
            try await f.transport.emit(.inboxEnqueued, fields: ["inboxID": .string("msg_second_command_root"),
                "item": .object(["type": .string("user"), "delivery": .string("queue"), "payload": .object(["text": .string("Second native root")])])])
            try await openCodeSessionEventually { await f.record.connectionFailures == 1 }
            await f.transport.releasePrompt()
            await #expect(throws: OpenCodeV2SessionError.uncertainDelivery) { try await send.value }
            let completions = await f.record.completions, calls = await f.transport.calls
            #expect(completions.isEmpty)
            #expect(!calls.contains { $0.path.last == "prompt" })
        } catch { await f.transport.releasePrompt(); _ = await send.result; throw error }
    }
}

@Test func openCodeV2CompactionAdmissionIsNotExecutionCompletionAndHasNoFakeUserTurn() async throws {
    try await withOpenCodeV2Session { f in
        try await f.session.send(text: "/compact", thread: f.thread())
        let before = await f.record.completions
        #expect(before.isEmpty)
        try await f.transport.beginCompaction()
        try await f.transport.emit(.executionSucceeded)
        try await openCodeSessionEventually { await f.record.completions == [.idle] }
        let calls = await f.transport.calls, turns = await f.record.turns
        let body = try #require(calls.first { $0.path.last == "compact" }?.body)
        #expect(body["delivery"] == .string("queue"))
        #expect(body["id"].string?.hasPrefix("msg_") == true)
        #expect(turns.isEmpty)
        #expect(!calls.contains { $0.path.last == "prompt" || $0.path.last == "command" })
    }
}

@Test func openCodeV2ColdCommandScanRereadsOnlyAfterBothExactWorkspaceSignals() async throws {
    try await withOpenCodeV2Session { f in
        await f.transport.setCatalogCold(true)
        let read = Task { try await f.session.providerCommands() }
        try await openCodeSessionEventually { await f.transport.commandReads == 1 }
        try await f.transport.catalogSignal("command.updated", directory: f.root.path + "/foreign")
        try await f.transport.catalogSignal("skill.updated", directory: f.root.path)
        let before = await f.transport.commandReads
        #expect(before == 1)
        await f.transport.setCatalogCold(false)
        try await f.transport.catalogSignal("command.updated", directory: f.root.path)
        let inventory = try await read.value
        #expect(inventory.commands.contains { $0.name == "review" })
        #expect(!inventory.isPartial)
        let after = await f.transport.commandReads
        #expect(after == 2)
    }
}

@Test func openCodeV2CancelColdCatalogWaitDoesNotCloseSharedEventConnection() async throws {
    try await withOpenCodeV2Session { f in
        await f.transport.setCatalogCold(true)
        let read = Task { try await f.session.providerCommands() }
        try await openCodeSessionEventually { await f.transport.commandReads == 1 }
        read.cancel()
        await #expect(throws: CancellationError.self) { try await read.value }
        let closed = await f.transport.closeCount
        #expect(closed == 0)
        await f.transport.setCatalogCold(false)
        let inventory = try await f.session.providerCommands()
        #expect(inventory.commands.contains { $0.name == "review" })
    }
}

@Test(arguments: [false, true])
func openCodeV2ImplicitVariantSendsNativeDefaultSentinelAndPreservesCapturedChoice(inheritModel: Bool) async throws {
    try await withOpenCodeV2Session { fixture in
        var thread = fixture.thread()
        let selected = fixture.configuration.selecting(model: inheritModel ? nil : fixture.model)
        thread.openCodeConfiguration = selected; thread.model = selected.model?.catalogID ?? ""
        thread.activeRun = .init(id: UUID(), configuration: .init(thread: thread), startedAt: .now)
        try await fixture.session.send(text: "Native default variant", thread: thread)
        let calls = await fixture.transport.calls
        let create = try #require(calls.first { $0.method == "POST" && $0.path == ["api", "session"] }?.body)
        let configure = try #require(calls.last { $0.path.last == "model" }?.body)
        for body in [create, configure] {
            #expect(body["model"]["variant"] == .string("default"))
            #expect(body["model"]["providerID"] == .string(fixture.model.providerID))
            #expect(body["model"]["id"] == .string(fixture.model.id))
        }
        #expect(calls.filter { $0.path.last == "prompt" }.count == 1)
        #expect(thread.openCodeConfiguration == selected)
        #expect(thread.activeRun?.configuration.openCodeConfiguration == selected)
        #expect(selected.model?.variant == nil)
    }
}

@Test func openCodeV2MetadataWaitsOnlyForExplicitTemporaryNativeReadiness() async throws {
    try await withOpenCodeV2Session { fixture in
        await fixture.transport.deferInventoryReadiness(reads: 1)
        let models = try await fixture.session.models()
        #expect(models.count == 1)
        #expect(await fixture.transport.inventoryReads == 2)
        #expect(await fixture.transport.promptCount == 0)
    }
}

@Test(arguments: [OpenCodeProtocolError.unauthorized, .invalidCatalog, .wrongDirectory])
func openCodeV2MetadataDoesNotRetryAuthenticationOrInvalidInventory(error: OpenCodeProtocolError) async throws {
    try await withOpenCodeV2Session { fixture in
        await fixture.transport.failInventory(error)
        await #expect(throws: error) { try await fixture.session.models() }
        #expect(await fixture.transport.inventoryReads == 1)
        #expect(await fixture.transport.promptCount == 0)
    }
}

@Test(arguments: [false, true])
func openCodeV2MetadataReadinessRemainsCancellableAndCloseStopsPolling(close: Bool) async throws {
    try await withOpenCodeV2Session { fixture in
        await fixture.transport.deferInventoryReadiness(reads: Int.max)
        let operation = Task { try await fixture.session.models() }
        try await openCodeSessionEventually { await fixture.transport.inventoryReads > 0 }
        if close { await fixture.session.close() } else { operation.cancel() }
        await #expect(throws: (any Error).self) { try await operation.value }
        let count = await fixture.transport.inventoryReads
        #expect(count <= 2)
        #expect(await fixture.transport.promptCount == 0)
    }
}

@Test(.timeLimit(.minutes(1)))
func openCodeV2MetadataPersistentNativeUnavailabilityStopsAtBoundedDeadline() async throws {
    try await withOpenCodeV2Session { fixture in
        await fixture.transport.deferInventoryReadiness(reads: Int.max)
        let started = ContinuousClock.now
        await #expect(throws: OpenCodeProtocolError.unavailable) { try await fixture.session.models() }
        let elapsed = ContinuousClock.now - started
        #expect(elapsed >= .seconds(10) && elapsed < .seconds(15))
        #expect(await fixture.transport.inventoryReads > 1)
        #expect(await fixture.transport.promptCount == 0)
    }
}

private struct OpenCodeSessionFixture: Sendable {
    let root: URL
    let configuration: OpenCodeConfiguration
    let model: OpenCodeModelSelection
    let transport: OpenCodeSessionFixtureTransport
    let session: OpenCodeV2Session
    let record: OpenCodeSessionRecord
    func thread(nativeID: String? = nil) -> CodingThread {
        var thread = CodingThread(project: .init(path: root.path))
        thread.provider = .opencode; thread.openCodeConfiguration = configuration
        thread.model = configuration.model?.catalogID ?? ""; thread.providerThreadID = nativeID
        thread.checkpointPolicy = .disabled
        thread.activeRun = .init(id: UUID(), configuration: .init(thread: thread), startedAt: Date())
        return thread
    }
    func readyToSteer() async throws -> CodingThread {
        var value = thread()
        try await session.send(text: "Original foreground turn", thread: value)
        try await transport.beginInput()
        try await openCodeSessionEventually {
            let capabilities = await session.steeringCapabilities(), turns = await record.turns
            return capabilities.supportsActiveSteering && turns.count == 1
        }
        let turns = await record.turns
        value.providerThreadID = await transport.nativeID
        value.activeRun?.nativeTurnID = try #require(turns.first)
        return value
    }
}

private func withOpenCodeV2Session(mode: OpenCodeSessionFault = .manual,
                                  body: (OpenCodeSessionFixture) async throws -> Void) async throws {
    let root = try temporaryWorkspace()
    let model = OpenCodeModelSelection(providerID: "provider-fixture", id: "wire-model")
    let configuration = OpenCodeConfiguration(model: .init(providerID: model.providerID, id: model.id, variant: "balanced"))
    let transport = OpenCodeSessionFixtureTransport(directory: root.path, model: model, mode: mode)
    let session = OpenCodeV2Session(cwd: root, configuration: configuration, transport: transport)
    let record = OpenCodeSessionRecord()
    let consumer = Task { for await event in session.events { await record.append(event) } }
    let fixture = OpenCodeSessionFixture(root: root, configuration: configuration, model: model, transport: transport, session: session, record: record)
    do { try await body(fixture) }
    catch { await session.close(); await consumer.value; try? FileManager.default.removeItem(at: root); throw error }
    await session.close(); await consumer.value
    try FileManager.default.removeItem(at: root)
}

private actor OpenCodeSessionFixtureTransport: OpenCodeV2SessionTransport {
    private let directory: String
    private let model: OpenCodeModelSelection
    private var mode: OpenCodeSessionFault
    private let eventStream: AsyncThrowingStream<OpenCodeSSEEvent, any Error>
    private let eventContinuation: AsyncThrowingStream<OpenCodeSSEEvent, any Error>.Continuation
    private let promptGate = OpenCodeSessionGate()
    private let configurationGate = OpenCodeSessionGate()
    private let permissionReplyGate = OpenCodeSessionGate()
    private var closed = false
    private var info: JSONValue?
    private var busy = false
    private var seq: [String: Int] = [:]
    private var inputID: String?
    var calls: [OpenCodeSessionCall] = []
    var connects = 0
    var configurationHeld = false
    var permissionReplyHeld = false
    var promptHeldBeforeAdmission = false
    var nativeAdmissions = 0
    var closeCount = 0
    var commandReads = 0
    private var catalogCold = false
    var promptCount: Int { calls.filter { $0.method == "POST" && $0.path.last == "prompt" }.count }
    var nativeID: String? { info?["id"].string }

    init(directory: String, model: OpenCodeModelSelection, mode: OpenCodeSessionFault) {
        self.directory = directory; self.model = model; self.mode = mode
        let pair = AsyncThrowingStream<OpenCodeSSEEvent, any Error>.makeStream()
        eventStream = pair.stream; eventContinuation = pair.continuation
    }
    func connect() async throws -> AsyncThrowingStream<OpenCodeSSEEvent, any Error> { connects += 1; return eventStream }
    var inventoryReads = 0
    private var unavailableInventoryReads = 0
    private var inventoryFailure: OpenCodeProtocolError?
    func failInventory(_ error: OpenCodeProtocolError) { inventoryFailure = error }
    func deferInventoryReadiness(reads: Int) { unavailableInventoryReads = reads }
    func inventory(directory: URL) async throws -> OpenCodeMetadataSnapshot {
        inventoryReads += 1
        if let inventoryFailure { throw inventoryFailure }
        if unavailableInventoryReads > 0 { unavailableInventoryReads -= 1; throw OpenCodeProtocolError.unavailable }
        return .init(server: .init(generation: .v2, version: .init(major: 2, minor: 1, patch: 2), processIdentifier: 1), directory: directory.path,
              models: [.init(selection: model, name: "Fixture", variants: ["balanced", "fast"], enabled: true, input: ["text", "image"], output: ["text"], tools: true)],
              agents: [.init(id: "build", name: "Build", description: nil, mode: .primary, hidden: false)], defaults: [model])
    }
    func commands(directory: URL) async throws -> ProviderCommandInventory {
        commandReads += 1
        return try ProviderCommandCatalog.openCode(commands: .array(catalogCold ? [] : [.object(["name": .string("review")])]),
            skills: .array(catalogCold ? [] : [
                .object(["id": .string("skill-a"), "name": .string("Friendly A"), "path": .string(directory.path + "/a/SKILL.md")]),
                .object(["id": .string("skill-b"), "name": .string("Friendly B"), "path": .string(directory.path + "/b/SKILL.md")])]),
            generation: .v2, cwd: directory.path)
    }
    func setCatalogCold(_ value: Bool) { catalogCold = value }
    func catalogSignal(_ kind: String, directory: String) throws {
        let value: JSONValue = .object(["type": .string(kind), "location": .object(["directory": .string(directory)]), "data": .object([:])])
        let data = try JSONEncoder().encode(value)
        raw(String(decoding: data, as: UTF8.self))
    }
    func request(method: String, path: [String], query: [URLQueryItem], body: JSONValue?) async throws -> OpenCodeHTTPResponse {
        if method == "GET", path.last == "message" {
            calls.append(.init(method: method, path: path, body: body))
            let rows: [JSONValue] = inputID.map { [.object(["id": .string($0), "type": .string("user"),
                "time": .object(["created": .number(1)]), "text": .string("Native command expansion")])] } ?? []
            return try response(.object(["data": .array(rows), "cursor": .object([:])]))
        }
        return try await request(method: method, path: path, body: body)
    }
    func setMode(_ mode: OpenCodeSessionFault) { self.mode = mode }
    func releasePrompt() async { await promptGate.release() }
    func releaseConfiguration() async { await configurationGate.release() }
    func releasePermissionReply() async { await permissionReplyGate.release() }
    func disconnect() { eventContinuation.finish() }
    func raw(_ data: String) { eventContinuation.yield(.init(event: "message", data: data, id: nil, retryMilliseconds: nil)) }
    func close() async {
        guard !closed else { return }
        closeCount += 1
        closed = true; eventContinuation.finish(); await promptGate.release(); await configurationGate.release(); await permissionReplyGate.release()
    }
    func seedSession(id: String, wrongDirectory: Bool, busy: Bool) {
        self.busy = busy
        info = .object(["id": .string(id), "agent": .string("build"), "model": modelJSON(model), "location": .object(["directory": .string(wrongDirectory ? directory + "/different" : directory)]), "permissions": .array([])])
    }
    func request(method: String, path: [String], body: JSONValue?) async throws -> OpenCodeHTTPResponse {
        guard !closed else { throw CancellationError() }
        guard path.allSatisfy({ !$0.isEmpty }) else { throw OpenCodeHTTPError.invalidPath }
        calls.append(.init(method: method, path: path, body: body))
        if path == ["api", "session", "active"] {
            return try response(.object(["data": .object(busy ? [nativeID!: .object(["type": .string("running")])] : [:])]))
        }
        if method == "GET", path.count == 3 {
            if let info, info["id"].string == path[2] { return try response(.object(["data": info])) }
            return try response(.object([:]), status: 404)
        }
        if method == "POST", path == ["api", "session"], let body {
            var object = body.object ?? [:]; object["time"] = .object(["created": .number(1), "updated": .number(1)])
            info = .object(object); return try response(.object(["data": info!]))
        }
        if method == "GET", path.last == "inbox" { return try response(.object(["data": .array([])])) }
        if method == "POST", path.last == "agent" {
            if mode == .holdConfiguration { configurationHeld = true; await configurationGate.wait() }
            guard !closed else { throw CancellationError() }
            setInfo("agent", body?["agent"] ?? .null); return empty()
        }
        if method == "PATCH" { setInfo("permissions", body?["permissions"] ?? .null); return empty() }
        if method == "POST", path.last == "model" { setInfo("model", body?["model"] ?? .null); return empty() }
        if method == "POST", path.last == "command" {
            inputID = "msg_native_command"
            try beginInput()
            let saved = mode
            if saved == .holdPromptReply || saved == .holdPromptReplyLost { await promptGate.wait() }
            guard !closed else { throw CancellationError() }
            if saved == .holdPromptReplyLost { throw OpenCodeHTTPError.transportFailure }
            return empty()
        }
        if method == "POST", path.last == "compact" {
            inputID = body?["id"].string
            return try response(.object(["data": .object(["id": body?["id"] ?? .null, "sessionID": .string(nativeID!),
                "type": .string("compaction"), "delivery": .string("queue"), "payload": .object([:])])]))
        }
        if method == "POST", path.last == "prompt" {
            inputID = body?["id"].string
            let saved = body ?? .null
            let savedNativeID = nativeID!
            let loseHeldReply = mode == .holdPromptReplyLost
            if mode == .holdPromptBeforeAdmission {
                promptHeldBeforeAdmission = true
                await promptGate.wait()
            }
            if mode == .lostPrompt { throw OpenCodeHTTPError.transportFailure }
            if mode == .rejectedPrompt { return try response(.object([:]), status: 409) }
            if mode == .holdPromptReply || loseHeldReply { await promptGate.wait() }
            guard !closed else { throw CancellationError() }
            if loseHeldReply { throw OpenCodeHTTPError.transportFailure }
            nativeAdmissions += 1
            return try response(.object(["data": .object(["id": saved["id"], "sessionID": .string(savedNativeID), "type": .string("user"), "delivery": saved["delivery"], "payload": .object(["text": saved["text"]])])]))
        }
        if path.last == "interrupt" { return try response(.object(["interrupted": .bool(busy)])) }
        if path.last == "synthetic" { return try response(.object(["data": .object([:])])) }
        if path.last == "reply", path.contains("permission"), mode == .holdPermissionReply {
            permissionReplyHeld = true; await permissionReplyGate.wait()
            guard !closed else { throw CancellationError() }
        }
        if method == "DELETE" || path.last == "reply" { return empty() }
        throw CoincideError("The private OpenCode fixture received an unexpected route.")
    }
    func beginCompaction() throws {
        guard let inputID else { throw CoincideError("The private fixture has no compaction.") }
        try emit(.inboxEnqueued, fields: ["inboxID": .string(inputID), "item": .object(["type": .string("compaction"), "delivery": .string("queue"), "payload": .object([:])])])
        try emit(.executionStarted)
        try emit(.inboxDelivered, fields: ["inboxID": .string(inputID)])
    }
    func beginInput(assistant: String = "msg_assistant_one", includeStart: Bool = true) throws {
        guard let inputID else { throw CoincideError("The private fixture has no admitted input.") }
        try emit(.inboxEnqueued, fields: ["inboxID": .string(inputID), "item": .object(["type": .string("user"), "delivery": .string("queue"), "payload": .object(["text": .string("native plugin projection")])])])
        if includeStart { try emit(.executionStarted) }
        try emit(.inboxDelivered, fields: ["inboxID": .string(inputID)])
        try step(assistant: assistant)
    }
    func step(assistant: String, session: String? = nil) throws {
        try emit(.stepStarted, session: session, fields: ["assistantMessageID": .string(assistant), "agent": .string("build"), "model": modelJSON(model)])
    }
    func text(_ text: String, assistant: String, session: String? = nil) throws {
        try emit(.textStarted, session: session, fields: ["assistantMessageID": .string(assistant), "ordinal": .number(0)])
        try emit(.textDelta, session: session, fields: ["assistantMessageID": .string(assistant), "ordinal": .number(0), "delta": .string(text)])
    }
    func snapshotBarrier(_ text: String) throws {
        try emit(.textEnded, fields: ["assistantMessageID": .string("msg_assistant_one"), "ordinal": .number(0), "text": .string(text)])
    }
    func permission(id: String) throws {
        try emit(.permissionAsked, fields: ["id": .string(id), "action": .string("shell"), "resources": .array([.string("printf safe")]), "save": .array([.string("printf safe")]),
                                           "source": .object(["type": .string("tool"), "messageID": .string("msg_assistant_one"), "id": .string("call_shell")])])
    }
    func form(id: String, unsupported: Bool) throws {
        try emit(.formCreated, fields: ["form": .object(["id": .string(id), "sessionID": .string(nativeID!), "title": .string("Choose"), "fields": .array([
            .object(["key": .string("choice"), "title": .string("Choice"), "type": .string(unsupported ? "number" : "multiselect"), "required": .bool(true),
                     "options": .array([.object(["value": .string("wire-a"), "label": .string("Display A")]), .object(["value": .string("wire-b"), "label": .string("Display B")])])])
        ])])])
    }
    func emit(_ kind: OpenCodeV2Event.Kind, session: String? = nil, fields: [String: JSONValue] = [:]) throws {
        guard let session = session ?? nativeID else { throw CoincideError("The private fixture has no native session.") }
        var data = fields; data["sessionID"] = .string(session)
        let sequence = (seq[session] ?? 0) + 1; seq[session] = sequence
        let value: JSONValue = .object(["id": .string("evt_" + UUID().uuidString), "created": .number(Double(sequence)), "type": .string(kind.rawValue),
            "durable": .object(["aggregateID": .string(session), "seq": .number(Double(sequence)), "version": .number(1)]), "data": .object(data)])
        let bytes = try JSONEncoder().encode(value)
        eventContinuation.yield(.init(event: "message", data: String(decoding: bytes, as: UTF8.self), id: nil, retryMilliseconds: nil))
    }
    private func setInfo(_ key: String, _ value: JSONValue) { var object = info?.object ?? [:]; object[key] = value; info = .object(object) }
    private func modelJSON(_ model: OpenCodeModelSelection) -> JSONValue {
        var object: [String: JSONValue] = ["providerID": .string(model.providerID), "id": .string(model.id)]
        if let variant = model.variant { object["variant"] = .string(variant) }; return .object(object)
    }
    private func response(_ value: JSONValue, status: Int = 200) throws -> OpenCodeHTTPResponse { .init(status: status, headers: ["content-type": "application/json"], body: try JSONEncoder().encode(value)) }
    private func empty() -> OpenCodeHTTPResponse { .init(status: 204, headers: [:], body: Data()) }
}

private func openCodeSessionEventually(_ predicate: @Sendable () async -> Bool) async throws {
    let deadline = ContinuousClock.now + .seconds(5)
    while !(await predicate()) {
        guard ContinuousClock.now < deadline else { throw CoincideError("The native OpenCode fixture did not reach its expected boundary.") }
        try await Task.sleep(for: .milliseconds(5))
    }
}
