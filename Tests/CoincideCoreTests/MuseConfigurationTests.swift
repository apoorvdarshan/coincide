import CSQLite
import Foundation
import Testing
@testable import CoincideCore

private func museConfigRow(_ id: String = "muse-native", efforts: [String] = ["low", "high", "max"]) -> ProviderModel {
    let selection = MuseModelSelection(modelID: id)
    let options = efforts.map { ProviderReasoningEffortOption(id: $0, description: $0) }
    return .init(id: selection.catalogID, name: id, reasoningEfforts: options, defaultReasoningEffort: efforts.first,
                 museSelection: selection, museReasoningEfforts: options, museDefaultReasoningEffort: efforts.first)
}
private struct MuseConfigurationFixture {
    var snapshot = WorkspaceSnapshot()
    let runtime = UUID()
    var thread: CodingThread { snapshot.threads[0] }
    init(path: String = "/tmp/coincide-muse-captures") throws {
        let project = WorkspaceProject(path: path)
        var thread = CodingThread(project: project); thread.checkpointPolicy = .disabled
        snapshot.projects = [project]; snapshot.threads = [thread]
        try edit(.provider(.muse))
    }
    @discardableResult mutating func apply(_ command: EngineCommand) throws -> WorkspaceDecision {
        let result = try WorkspaceDecision.make(command, id: UUID(), snapshot: snapshot, now: Date())
        snapshot = result.snapshot; return result
    }
    @discardableResult mutating func edit(_ edit: ThreadEdit) throws -> WorkspaceDecision { try apply(.client(.editThread(thread.id, edit))) }
}

@Test func nativeMuseCapturesFIFOModelEffortAndAuthorityIndependentlyOfLaterHeaderEdits() throws {
    var f = try MuseConfigurationFixture(); let a = museConfigRow(), b = museConfigRow("muse-other")
    try f.edit(.museModel(a)); try f.edit(.museReasoning(model: a, effort: "high"))
    try f.apply(.client(.submit(threadID: f.thread.id, text: "First native Muse input")))
    let first = try #require(f.thread.activeRun)
    try f.apply(.runtimeOpened(threadID: f.thread.id, runID: first.id, runtimeID: f.runtime))
    try f.apply(.provider(threadID: f.thread.id, runtimeID: f.runtime, event: .thread("018f0000-0000-7000-8000-000000000001")))
    try f.edit(.museModel(b)); try f.edit(.museReasoning(model: b, effort: "max")); try f.edit(.permission(.fullAccess))
    try f.apply(.client(.submit(threadID: f.thread.id, text: "Queued native Muse input")))
    let queued = try #require(f.thread.queuedTurns.first)
    try f.edit(.museModel(a)); try f.edit(.museReasoning(model: a, effort: nil)); try f.edit(.permission(.supervised))
    #expect(f.thread.activeRun?.configuration.museConfiguration?.reasoningEffort == "high")
    #expect(queued.configuration.museConfiguration?.model == b.museSelection && queued.configuration.museConfiguration?.reasoningEffort == "max")
    #expect(queued.configuration.permissionSummary == "Always approve")
    try f.apply(.provider(threadID: f.thread.id, runtimeID: f.runtime, event: .completed(.idle)))
    #expect(f.thread.activeRun?.id == queued.id && f.thread.activeRun?.configuration == queued.configuration)
    #expect(f.thread.museConfiguration?.model == a.museSelection && f.thread.museConfiguration?.reasoningEffort == nil)
    try WorkspaceJournal.validate(f.snapshot)
}

@Test func nativeMuseRejectsInvalidSelectionAndUnsupportedAuthorityAsNormalCommands() async throws {
    let root = try temporaryWorkspace(); defer { try? FileManager.default.removeItem(at: root) }
    let url = root.appendingPathComponent("muse.sqlite"), f = try MuseConfigurationFixture(path: root.path)
    try await WorkspaceDatabase(url: url).save(f.snapshot, event: "muse.configuration.fixture")
    let engine = try WorkspaceEngine(url: url, providerFactory: { _ in throw CoincideError("A configuration edit must not start Muse.") }, identityResolver: { _ in nil })
    _ = try await engine.load()
    do {
        let row = museConfigRow()
        try await engine.dispatch(.editThread(f.thread.id, .museModel(row)))
        let before = await engine.current().snapshot
        for edit in [ThreadEdit.museReasoning(model: row, effort: "not-offered"), .museModel(.init(id: row.id, name: "Untyped")), .permission(.auto), .permission(.autoAcceptEdits)] {
            await #expect(throws: WorkspaceCommandError.self) { try await engine.dispatch(.editThread(f.thread.id, edit)) }
            let current = await engine.current()
            #expect(current.snapshot == before && current.error == nil)
        }
        try await engine.dispatch(.editThread(f.thread.id, .museReasoning(model: row, effort: "high")))
        try await engine.dispatch(.editThread(f.thread.id, .museReasoning(model: row, effort: nil)))
        #expect(await engine.current().snapshot.threads[0].museConfiguration?.reasoningEffort == nil)
        #expect(try await WorkspaceDatabase(url: url).effects().isEmpty)
        await engine.shutdown()
    } catch { await engine.shutdown(); throw error }
}

@Test func nativeMuseStorage32MigratesPiWorkspaceAndPreservesCapturedQueueAndLegacyProviders() async throws {
    let root = try temporaryWorkspace(); defer { try? FileManager.default.removeItem(at: root) }
    let url = root.appendingPathComponent("muse.sqlite")
    var f = try MuseConfigurationFixture(path: root.path)
    var pi = CodingThread(project: f.snapshot.projects[0]); pi.provider = .pi; pi.piConfiguration = .init()
    pi.messages = [.init(role: .user, text: "Keep native Pi history 日本語")]; pi.draft = "Keep unsent Pi draft"
    let legacy = CodingThread(project: f.snapshot.projects[0])
    var prior = WorkspaceSnapshot(); prior.projects = f.snapshot.projects; prior.threads = [pi, legacy]
    let db = try WorkspaceDatabase(url: url); try await db.save(prior, event: "muse.prior.workspace")
    var raw: OpaquePointer?; #expect(sqlite3_open(url.path, &raw) == SQLITE_OK)
    #expect(sqlite3_exec(raw, "PRAGMA user_version=28", nil, nil, nil) == SQLITE_OK); sqlite3_close(raw)
    let migrated = try WorkspaceDatabase(url: url); #expect(try await migrated.load() == prior)
    let row = museConfigRow(); try f.edit(.museModel(row)); try f.edit(.museReasoning(model: row, effort: "max"))
    try f.apply(.client(.submit(threadID: f.thread.id, text: "First captured Muse")))
    try f.apply(.client(.submit(threadID: f.thread.id, text: "Second captured Muse")))
    f.snapshot.threads += prior.threads
    try await migrated.save(f.snapshot, event: "muse.capture.workspace")
    #expect(try await WorkspaceDatabase(url: url).load() == f.snapshot)
    #expect(try await migrated.rebuildProjection().snapshot == f.snapshot)
    #expect(sqlite3_open(url.path, &raw) == SQLITE_OK)
    var statement: OpaquePointer?; #expect(sqlite3_prepare_v2(raw, "PRAGMA user_version", -1, &statement, nil) == SQLITE_OK)
    #expect(sqlite3_step(statement) == SQLITE_ROW && sqlite3_column_int(statement, 0) == 40)
    sqlite3_finalize(statement); sqlite3_close(raw)
}

@Test func nativeMuseRuntimeIdentityRetainsModelEditsAndSeparatesLaunchAuthority() throws {
    var f = try MuseConfigurationFixture(); let config = try #require(f.thread.museConfiguration)
    let a = MuseModelSelection(modelID: "a/b"), b = MuseModelSelection(modelID: "a b")
    #expect(a.catalogID != b.catalogID)
    #expect(config.runtimeIdentity == config.selecting(model: a, reasoningEffort: "high").runtimeIdentity)
    let before = ProviderConfiguration(thread: f.thread)
    try f.edit(.permission(.fullAccess))
    #expect(before.museRuntimeBinding != ProviderConfiguration(thread: f.thread).museRuntimeBinding)
    var mixed = f.snapshot; mixed.threads[0].provider = .claude
    #expect(throws: (any Error).self) { try WorkspaceJournal.validate(mixed) }
    try f.edit(.provider(.claude)); #expect(f.thread.museConfiguration == nil)
}

@Test(arguments: [false, true])
func nativeMuseResponseAcknowledgmentKeepsExactRequestDisabledUntilNativeSettlement(question: Bool) throws {
    var f = try MuseConfigurationFixture()
    try f.apply(.client(.submit(threadID: f.thread.id, text: "Native interaction ownership")))
    let run = try #require(f.thread.activeRun)
    try f.apply(.runtimeOpened(threadID: f.thread.id, runID: run.id, runtimeID: f.runtime))
    let sessionID = "018f0000-0000-7000-8000-000000000001"
    let request: ApprovalRequest
    let response: ProviderApprovalResponse
    if question {
        let input = try MuseUserInputRequest(params: .object([
            "sessionId": .string(sessionID), "turnId": .string("018f0000-0000-7000-8000-000000000002"),
            "userInputId": .string("native-question"), "questions": .array([
                .object(["id": .string("choice"), "header": .string("Choice"), "question": .string("Which change?"),
                    "selection": .object(["mode": .string("single")]),
                    "options": .array([.object(["label": .string("Small")])])])
            ])
        ]))
        request = input.approval(localID: .string("local-question"))
        response = .selectionsWithNotes(selections: ["choice": ["Small"]], notes: ["choice": "Keep my draft"])
    } else {
        let input = try MuseApprovalRequest(params: .object([
            "sessionId": .string(sessionID), "approvalId": .string("native-approval"),
            "currentRequirementId": .object(["approvalId": .string("native-approval"), "sourceIndex": .number(0)]),
            "subject": .object(["kind": .string("shell"), "command": .string("echo reviewed")]),
            "availableChoices": .array([
                .object(["choiceId": .string("once"), "label": .string("Allow once"), "decision": .string("approved"), "scope": .string("once")])
            ])
        ]))
        request = input.approval(localID: .string("local-approval")); response = .option("once")
    }
    try f.apply(.provider(threadID: f.thread.id, runtimeID: f.runtime, event: .sessionApproval(request)))
    let decision = try f.apply(.client(.respond(threadID: f.thread.id, requestID: request.id, response: response)))
    let effect = try #require(decision.effects.first)
    try f.apply(.effectResult(effect.request, .succeeded))
    #expect(f.thread.runtimeRequests.count == 1 && f.thread.runtimeRequests.first?.id == request.id)
    #expect(f.thread.runtimeRequests.first?.responding == true)
    #expect(throws: WorkspaceCommandError.self) {
        try f.apply(.client(.respond(threadID: f.thread.id, requestID: request.id, response: response)))
    }
    try f.apply(.provider(threadID: f.thread.id, runtimeID: f.runtime, event: .sessionApprovalDismissed(request.id)))
    #expect(f.thread.runtimeRequests.isEmpty)
    // A late effect completion must not resurrect a natively settled request.
    try f.apply(.effectResult(effect.request, .succeeded))
    #expect(f.thread.runtimeRequests.isEmpty && f.thread.activeRun?.id == run.id)
}
