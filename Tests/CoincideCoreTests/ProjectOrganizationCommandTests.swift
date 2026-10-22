import CSQLite
import Foundation
import Testing
@testable import CoincideCore

private actor OrganizationProvider: ProviderSession {
    nonisolated let events: AsyncStream<ProviderEvent>
    private let sink: AsyncStream<ProviderEvent>.Continuation
    private var runID: UUID?
    private(set) var prompts: [String] = []
    private(set) var closed = false
    private(set) var interrupts = 0
    init() { let pair = AsyncStream<ProviderEvent>.makeStream(); events = pair.stream; sink = pair.continuation }
    func models() -> [ProviderModel] { [] }
    func send(text: String, thread: CodingThread) {
        prompts.append(text); runID = thread.activeRun?.id
        emit(.thread("organization-fixture-\(thread.id)")); emit(.turn(UUID().uuidString))
    }
    func finish() { emit(.completed(.idle)) }
    func publish(_ event: ProviderEvent) { emit(event) }
    func interrupt() { interrupts += 1; emit(.completed(.interrupted)) }
    func respond(_ request: ApprovalRequest, allow: Bool) { }
    func answer(_ request: ApprovalRequest, answers: [String: String]) { }
    func close() { closed = true; sink.finish() }
    private func emit(_ event: ProviderEvent) {
        if let runID { sink.yield(.context(runID: runID, event: event)) }
        else { sink.yield(event) }
    }
}

private final class OrganizationHarness: @unchecked Sendable {
    private let lock = NSLock()
    private var values: [UUID: [OrganizationProvider]] = [:]
    func make(_ thread: CodingThread) -> any ProviderSession {
        lock.lock(); defer { lock.unlock() }
        let provider = OrganizationProvider(); values[thread.id, default: []].append(provider); return provider
    }
    func providers(_ id: UUID) -> [OrganizationProvider] { lock.lock(); defer { lock.unlock() }; return values[id] ?? [] }
    var count: Int { lock.lock(); defer { lock.unlock() }; return values.values.reduce(0) { $0 + $1.count } }
}

private struct OrganizationFixture {
    let root: URL
    let engine: WorkspaceEngine
    let harness: OrganizationHarness
    var databaseURL: URL { root.appendingPathComponent("workspace.sqlite") }
    func project(_ name: String, date: TimeInterval = 100) throws -> WorkspaceProject {
        let folder = root.appendingPathComponent(name, isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        var project = WorkspaceProject(path: folder.path)
        project.name = name; project.createdAt = Date(timeIntervalSince1970: date); project.updatedAt = project.createdAt
        return project
    }
}
private func withOrganization(_ body: (OrganizationFixture) async throws -> Void) async throws {
    let root = try temporaryWorkspace(); defer { try? FileManager.default.removeItem(at: root) }
    let harness = OrganizationHarness()
    let engine = try WorkspaceEngine(url: root.appendingPathComponent("workspace.sqlite"), providerFactory: { harness.make($0) })
    do {
        _ = try await engine.load(); try await body(.init(root: root, engine: engine, harness: harness))
        await engine.shutdown()
    } catch { await engine.shutdown(); throw error }
}
private func waitOrganization(_ condition: () async throws -> Bool) async throws {
    let deadline = ContinuousClock.now + .seconds(8)
    while try await !condition() {
        guard ContinuousClock.now < deadline else { throw CoincideError("Project organization test timed out") }
        try await Task.sleep(for: .milliseconds(10))
    }
}
private func expectOrganizationRejection(_ command: WorkspaceCommand, fixture f: OrganizationFixture) async throws {
    let before = await f.engine.current(), database = try WorkspaceDatabase(url: f.databaseURL), id = UUID()
    let count = try await database.journalEventCount(), effects = try await database.effects()
    await #expect(throws: WorkspaceCommandError.self) { try await f.engine.dispatch(command, id: id) }
    let rejected = await f.engine.current()
    #expect(rejected.snapshot == before.snapshot && rejected.sequence == before.sequence && rejected.error == nil)
    #expect(try await database.journalEventCount() == count)
    #expect(try await database.receipt(id)?.rejection != nil)
    #expect(try await database.effects() == effects)
}

@Test func projectRenameChangesOnlyTitleAndProjectUpdateDateEvenForInterruptedClone() throws {
    let root = try temporaryWorkspace(); defer { try? FileManager.default.removeItem(at: root) }
    let plan = try GitClonePlan.prepare(source: "https://example.invalid/native.git", destination: root.appendingPathComponent("checkout"))
    var project = WorkspaceProject(path: plan.destinationPath)
    let oldDate = Date(timeIntervalSince1970: 100), now = Date(timeIntervalSince1970: 200)
    project.createdAt = oldDate; project.updatedAt = oldDate
    var clone = ProjectCloneState(plan: plan, now: oldDate); clone.phase = .interrupted
    clone.error = "Interrupted fixture checkout"; project.clone = clone
    var thread = CodingThread(project: project); thread.draft = "Keep my unsent draft"
    thread.queuePaused = true
    thread.queuedTurns = [.init(id: UUID(), text: "Wait for checkout", configuration: .init(thread: thread), createdAt: oldDate)]
    let other = WorkspaceProject(path: root.appendingPathComponent("other").path)
    var snapshot = WorkspaceSnapshot(); snapshot.projects = [other, project]; snapshot.threads = [thread]
    snapshot.sidebarPreferences = .init(sortMode: .manual, collapsedProjectIDs: [project.id])
    let decision = try WorkspaceDecision.make(.client(.renameProject(projectID: project.id, title: "  Café 日本 🌍  ")),
                                              id: UUID(), snapshot: snapshot, now: now)
    var expected = snapshot; expected.projects[1].name = "Café 日本 🌍"; expected.projects[1].updatedAt = now
    #expect(decision.snapshot == expected)
    #expect(decision.effects.isEmpty && decision.closeRuntime == nil && decision.cancelCloneAttempt == nil)
    #expect(try WorkspaceJournal.changes(from: snapshot, to: expected) == [.projectUpserted(expected.projects[1])])
    let unchanged = try WorkspaceDecision.make(.client(.renameProject(projectID: project.id, title: " Café 日本 🌍 ")),
                                               id: UUID(), snapshot: expected, now: now.addingTimeInterval(999))
    #expect(unchanged.snapshot == expected && unchanged.effects.isEmpty)
}

@Test(.timeLimit(.minutes(1))) func projectRenameReceiptsDoNotReapplyOldNamesAndInvalidNamesNeverMutateWorkspace() async throws {
    try await withOrganization { f in
        let project = try f.project("Original"), thread = CodingThread(project: project)
        try await f.engine.dispatch(.addProjectWithThread(project: project, thread: thread))
        let id = UUID(), command = WorkspaceCommand.renameProject(projectID: project.id, title: " First name ")
        let first = try await f.engine.dispatch(command, id: id)
        try await f.engine.dispatch(.renameProject(projectID: project.id, title: "Newest name"))
        let before = await f.engine.current()
        #expect(try await f.engine.dispatch(command, id: id) == first)
        #expect(await f.engine.current().snapshot == before.snapshot)
        #expect(await f.engine.current().sequence == before.sequence)
        do {
            try await f.engine.dispatch(.renameProject(projectID: project.id, title: "Conflicting payload"), id: id)
            Issue.record("A reused rename command identity accepted a different title.")
        } catch WorkspaceCommitError.commandIDCollision { }
        #expect(await f.engine.current().snapshot == before.snapshot)
        for title in ["", " \n\t ", "embedded\nnewline", "embedded\u{2028}separator", "control\u{7}character", String(repeating: "🌍", count: 101)] {
            try await expectOrganizationRejection(.renameProject(projectID: project.id, title: title), fixture: f)
        }
        try await expectOrganizationRejection(.renameProject(projectID: UUID(), title: "Missing project"), fixture: f)
        let boundary = String(repeating: "🌍", count: 100)
        try await f.engine.dispatch(.renameProject(projectID: project.id, title: " \(boundary) "))
        #expect(await f.engine.current().snapshot.projects[0].name == boundary)
        #expect(await f.engine.current().snapshot.projects[0].path == project.path)
        #expect(await f.engine.current().snapshot.threads == [thread] && f.harness.count == 0)
        let database = try WorkspaceDatabase(url: f.databaseURL)
        #expect(try await database.effects().isEmpty)
        let current = await f.engine.current().snapshot
        #expect(try await database.rebuildProjection().snapshot == current)
    }
}

@Test(.timeLimit(.minutes(1))) func collapsingAndRenamingRunningProjectPreservesProviderQueueAndDraftUntilExplicitCompletion() async throws {
    try await withOrganization { f in
        let project = try f.project("Live"), thread = CodingThread(project: project)
        try await f.engine.dispatch(.addProjectWithThread(project: project, thread: thread))
        try await f.engine.dispatch(.submit(threadID: thread.id, text: "First running turn"))
        try await waitOrganization { await f.engine.current().snapshot.threads[0].activeRun?.nativeTurnID != nil }
        let provider = try #require(f.harness.providers(thread.id).first)
        try await f.engine.dispatch(.submit(threadID: thread.id, text: "Second queued turn"))
        try await f.engine.dispatch(.editThread(thread.id, .draft("Draft for a future third turn")))
        let before = await f.engine.current().snapshot
        let database = try WorkspaceDatabase(url: f.databaseURL), effectsBefore = try await database.effects()
        try await f.engine.dispatch(.setProjectExpanded(projectID: project.id, expanded: false))
        try await f.engine.dispatch(.renameProject(projectID: project.id, title: "Still live"))
        let collapsed = await f.engine.current().snapshot
        #expect(!collapsed.isProjectExpanded(project.id) && collapsed.threads == before.threads)
        #expect(await provider.closed == false)
        #expect(await provider.interrupts == 0)
        #expect(await provider.prompts == ["First running turn"])
        #expect(f.harness.providers(thread.id).count == 1)
        #expect(try await database.effects().map(\.id) == effectsBefore.map(\.id))
        // Collapsing a project must not pause its queued work or stop runtime events.
        await provider.finish()
        try await waitOrganization { await provider.prompts == ["First running turn", "Second queued turn"] }
        try await waitOrganization { await f.engine.current().snapshot.threads[0].activeRun?.nativeTurnID != nil }
        let second = await f.engine.current().snapshot.threads[0]
        #expect(second.queuedTurns.isEmpty && second.draft == "Draft for a future third turn" && !second.queuePaused)
        #expect(!((await f.engine.current().snapshot).isProjectExpanded(project.id)))
        try await f.engine.dispatch(.setProjectExpanded(projectID: project.id, expanded: true))
        #expect(await f.engine.current().snapshot.threads[0] == second)
        #expect(await provider.closed == false)
        #expect(await provider.interrupts == 0)
        #expect(f.harness.providers(thread.id).count == 1)
        await provider.finish()
        try await waitOrganization { await f.engine.current().snapshot.threads[0].state == .idle }
        let final = await f.engine.current().snapshot
        #expect(final.threads[0].messages.filter { $0.role == .user }.map(\.text) == ["First running turn", "Second queued turn"])
        #expect(final.threads[0].draft == "Draft for a future third turn" && final.isProjectExpanded(project.id))
        #expect(try await database.rebuildProjection().snapshot == final)
    }
}

@Test(.timeLimit(.minutes(1))) func sidebarManualOrderAndCollapsedPreferencesSurviveModeSwitchNewProjectRestartAndJournalRebuild() async throws {
    try await withOrganization { f in
        let a = try f.project("A", date: 100), b = try f.project("B", date: 300), c = try f.project("C", date: 200)
        for project in [a, b, c] { try await f.engine.dispatch(.addProject(project)) }
        let defaults = await f.engine.current().snapshot
        #expect(defaults.sidebarPreferences == nil && defaults.effectiveSidebarPreferences.sortMode == .updatedAt)
        #expect(defaults.projects.allSatisfy { defaults.isProjectExpanded($0.id) })
        let defaultNoOp = try await f.engine.dispatch(.setProjectSortMode(.updatedAt))
        #expect(defaultNoOp.eventCount == 0)
        #expect(await f.engine.current().snapshot.sidebarPreferences == nil)
        try await f.engine.dispatch(.setProjectSortMode(.manual))
        let move = WorkspaceCommand.moveProject(projectID: c.id, before: a.id, expectedOrder: [a.id, b.id, c.id])
        let moveID = UUID(), receipt = try await f.engine.dispatch(move, id: moveID)
        try await f.engine.dispatch(.setProjectExpanded(projectID: b.id, expanded: false))
        try await f.engine.dispatch(.setProjectSortMode(.createdAt))
        #expect(await f.engine.current().snapshot.orderedProjects.map(\.id) == [b.id, c.id, a.id])
        let d = try f.project("D", date: 400)
        try await f.engine.dispatch(.addProject(d))
        try await f.engine.dispatch(.setProjectSortMode(.updatedAt))
        #expect(await f.engine.current().snapshot.orderedProjects.map(\.id) == [d.id, b.id, c.id, a.id])
        #expect(await f.engine.current().snapshot.projects.map(\.id) == [c.id, a.id, b.id, d.id])
        try await f.engine.dispatch(.setProjectSortMode(.manual))
        let expected = await f.engine.current().snapshot
        #expect(expected.orderedProjects.map(\.id) == [c.id, a.id, b.id, d.id] && !expected.isProjectExpanded(b.id))
        #expect(expected.projects == [c, a, b, d] && f.harness.count == 0)
        let database = try WorkspaceDatabase(url: f.databaseURL)
        #expect(try await database.effects().isEmpty)
        let events = try await database.journal()
        #expect(events.contains { if case .sidebarPreferencesChanged = $0.event { true } else { false } })
        #expect(events.filter { $0.commandID == moveID }.map(\.event) == [.projectsOrdered([c.id, a.id, b.id])])
        #expect(try await database.rebuildProjection().snapshot == expected)
        await f.engine.shutdown()
        let reopened = try WorkspaceEngine(url: f.databaseURL, providerFactory: { f.harness.make($0) })
        do {
            #expect(try await reopened.load() == expected)
            #expect(try await reopened.dispatch(move, id: moveID) == receipt)
            #expect(await reopened.current().snapshot == expected && f.harness.count == 0)
            await reopened.shutdown()
        } catch { await reopened.shutdown(); throw error }
        // Remove both replaceable projection tables to require recovery solely from the journal.
        try organizationSQL(f.databaseURL, "DELETE FROM workspace; DELETE FROM workspace_projection")
        let rebuilt = try WorkspaceDatabase(url: f.databaseURL)
        #expect(try await rebuilt.load() == expected)
        #expect(try await rebuilt.rebuildProjection().snapshot == expected)
    }
}

@Test(.timeLimit(.minutes(1))) func acceptingQueuedUserTurnAdvancesProjectActivityBeforeStartingOrAddingItsTranscriptMessage() async throws {
    try await withOrganization { f in
        let a = try f.project("A"), b = try f.project("B")
        let aStarter = CodingThread(project: a), bStarter = CodingThread(project: b)
        try await f.engine.dispatch(.addProjectWithThread(project: a, thread: aStarter))
        try await f.engine.dispatch(.addProjectWithThread(project: b, thread: bStarter))
        try await f.engine.dispatch(.submit(threadID: aStarter.id, text: "A first gated turn"))
        try await f.engine.dispatch(.submit(threadID: bStarter.id, text: "B first gated turn"))
        try await waitOrganization { await f.engine.current().snapshot.threads.allSatisfy { $0.activeRun?.nativeTurnID != nil } }
        let aProvider = try #require(f.harness.providers(aStarter.id).first)
        let bProvider = try #require(f.harness.providers(bStarter.id).first)
        let running = await f.engine.current().snapshot
        var aMessage = try #require(running.threads.first { $0.id == aStarter.id }?.messages.first { $0.role == .user })
        var bMessage = try #require(running.threads.first { $0.id == bStarter.id }?.messages.first { $0.role == .user })
        // Canonical provider echoes give the accepted messages fixed historical dates;
        // the ordering assertion does not depend on two commands observing different clock ticks.
        let aDate = Date(timeIntervalSince1970: 100), bDate = Date(timeIntervalSince1970: 200)
        aMessage.createdAt = aDate; bMessage.createdAt = bDate
        await aProvider.publish(.message(aMessage)); await bProvider.publish(.message(bMessage))
        try await waitOrganization {
            let snapshot = await f.engine.current().snapshot
            return snapshot.threads.first { $0.id == aStarter.id }?.messages.first?.createdAt == aDate
                && snapshot.threads.first { $0.id == bStarter.id }?.messages.first?.createdAt == bDate
        }
        let before = await f.engine.current().snapshot
        let aBefore = try #require(before.threads.first { $0.id == aStarter.id })
        #expect(before.effectiveSidebarPreferences.sortMode == .updatedAt && before.orderedProjects.map(\.id) == [b.id, a.id])
        let queuedID = UUID()
        try await f.engine.dispatch(.submit(threadID: aStarter.id, text: "A accepted queued turn"), id: queuedID)
        let queued = await f.engine.current().snapshot
        let aQueued = try #require(queued.threads.first { $0.id == aStarter.id })
        #expect(queued.orderedProjects.map(\.id) == [a.id, b.id])
        #expect(aQueued.activeRun == aBefore.activeRun && aQueued.messages == aBefore.messages)
        #expect(aQueued.queuedTurns.map(\.id) == [queuedID] && aQueued.queuedTurns[0].text == "A accepted queued turn")
        #expect(await aProvider.prompts == ["A first gated turn"])
        #expect(f.harness.providers(aStarter.id).count == 1)
        let database = try WorkspaceDatabase(url: f.databaseURL)
        #expect(try await database.effects(commandID: queuedID).isEmpty)
        await bProvider.publish(.delta(id: "b-stream-after-a-queued", role: .assistant, text: "B is still streaming"))
        try await waitOrganization {
            await f.engine.current().snapshot.threads.first { $0.id == bStarter.id }?.messages.last?.text == "B is still streaming"
        }
        let afterAssistant = await f.engine.current().snapshot
        #expect(afterAssistant.orderedProjects.map(\.id) == [a.id, b.id])
        #expect(afterAssistant.threads.first { $0.id == aStarter.id } == aQueued)
        #expect(afterAssistant.projects.map(\.id) == [a.id, b.id])
        #expect(await aProvider.prompts == ["A first gated turn"])
        #expect(try await database.rebuildProjection().snapshot == afterAssistant)
        await aProvider.finish()
        try await waitOrganization { await aProvider.prompts == ["A first gated turn", "A accepted queued turn"] }
        try await waitOrganization { await f.engine.current().snapshot.threads.first { $0.id == aStarter.id }?.activeRun?.nativeTurnID != nil }
        await aProvider.finish(); await bProvider.finish()
        try await waitOrganization { await f.engine.current().snapshot.threads.allSatisfy { $0.state == .idle } }
    }
}

@Test(.timeLimit(.minutes(1))) func invalidOrStaleProjectMovesNeverLoseNewProjectsOrWriteJournalEvents() async throws {
    try await withOrganization { f in
        let a = try f.project("A"), b = try f.project("B"), c = try f.project("C")
        for project in [a, b, c] { try await f.engine.dispatch(.addProject(project)) }
        let original = [a.id, b.id, c.id]
        try await expectOrganizationRejection(.moveProject(projectID: c.id, before: a.id, expectedOrder: original), fixture: f)
        try await expectOrganizationRejection(.reorderProjects(projectIDs: Array(original.reversed()), expectedOrder: original), fixture: f)
        try await f.engine.dispatch(.setProjectSortMode(.manual))
        let missing = UUID()
        let invalidCommands: [WorkspaceCommand] = [
            .moveProject(projectID: missing, before: a.id, expectedOrder: original),
            .moveProject(projectID: a.id, before: missing, expectedOrder: original),
            .moveProject(projectID: a.id, before: b.id, expectedOrder: [a.id, a.id, c.id]),
            .moveProject(projectID: a.id, before: b.id, expectedOrder: [a.id, b.id]),
            .moveProject(projectID: a.id, before: b.id, expectedOrder: Array(original.reversed())),
            .reorderProjects(projectIDs: [a.id, a.id, c.id], expectedOrder: original),
            .reorderProjects(projectIDs: [a.id, b.id], expectedOrder: original),
            .reorderProjects(projectIDs: [a.id, b.id, missing], expectedOrder: original),
            .reorderProjects(projectIDs: original, expectedOrder: [a.id, b.id]),
        ]
        for command in invalidCommands { try await expectOrganizationRejection(command, fixture: f) }
        let d = try f.project("New while dragging")
        try await f.engine.dispatch(.addProject(d))
        try await expectOrganizationRejection(.moveProject(projectID: c.id, before: a.id, expectedOrder: original), fixture: f)
        try await expectOrganizationRejection(.reorderProjects(projectIDs: Array(original.reversed()), expectedOrder: original), fixture: f)
        try await expectOrganizationRejection(.setProjectExpanded(projectID: missing, expanded: false), fixture: f)
        #expect(await f.engine.current().snapshot.projects == [a, b, c, d] && f.harness.count == 0)
        let beforeNoOp = await f.engine.current()
        let receipt = try await f.engine.dispatch(.moveProject(projectID: a.id, before: a.id, expectedOrder: [a.id, b.id, c.id, d.id]))
        #expect(receipt.eventCount == 0 && receipt.sequence == beforeNoOp.sequence)
        #expect(await f.engine.current().snapshot == beforeNoOp.snapshot)
    }
}

@Test(.timeLimit(.minutes(1))) func atomicProjectBatchOrderDeduplicatesAndConcurrentStaleMovesHaveOneWinner() async throws {
    try await withOrganization { f in
        let a = try f.project("A"), b = try f.project("B"), c = try f.project("C")
        for project in [a, b, c] { try await f.engine.dispatch(.addProject(project)) }
        try await f.engine.dispatch(.setProjectSortMode(.manual))
        let initial = [a.id, b.id, c.id], batch = [c.id, b.id, a.id], id = UUID()
        let command = WorkspaceCommand.reorderProjects(projectIDs: batch, expectedOrder: initial)
        let receipt = try await f.engine.dispatch(command, id: id)
        #expect(receipt.eventCount == 1)
        #expect(await f.engine.current().snapshot.projects == [c, b, a])
        #expect(try await f.engine.dispatch(command, id: id) == receipt)
        let database = try WorkspaceDatabase(url: f.databaseURL)
        #expect(try await database.journal().filter { $0.commandID == id }.map(\.event) == [.projectsOrdered(batch)])
        async let first: WorkspaceCommandReceipt? = try? f.engine.dispatch(.moveProject(projectID: a.id, before: c.id, expectedOrder: batch))
        async let second: WorkspaceCommandReceipt? = try? f.engine.dispatch(.moveProject(projectID: b.id, before: c.id, expectedOrder: batch))
        let outcomes = await (first, second)
        #expect([outcomes.0, outcomes.1].compactMap { $0 }.count == 1)
        let winner = await f.engine.current().snapshot
        #expect([[a.id, c.id, b.id], [b.id, c.id, a.id]].contains(winner.projects.map(\.id)))
        #expect(Set(winner.projects.map(\.id)) == Set(initial) && winner.projects.count == 3 && f.harness.count == 0)
        #expect(try await database.effects().isEmpty)
        #expect(try await database.rebuildProjection().snapshot == winner)
        // The old accepted batch cannot overwrite the newer order when its receipt is retried.
        #expect(try await f.engine.dispatch(command, id: id) == receipt)
        #expect(await f.engine.current().snapshot == winner)
    }
}

@Test func sidebarPreferencesRejectUnknownOrDuplicateCollapsedProjectsBeforePersistence() async throws {
    let root = try temporaryWorkspace(); defer { try? FileManager.default.removeItem(at: root) }
    let project = WorkspaceProject(path: root.path), thread = CodingThread(project: project)
    var initial = WorkspaceSnapshot(); initial.projects = [project]; initial.threads = [thread]
    let database = try WorkspaceDatabase(url: root.appendingPathComponent("workspace.sqlite"))
    try await database.save(initial, event: "fixture")
    let before = try await database.revision(), count = try await database.journalEventCount()
    for ids in [[UUID()], [project.id, project.id]] {
        var invalid = initial; invalid.sidebarPreferences = .init(sortMode: .manual, collapsedProjectIDs: ids)
        let candidate = invalid, id = UUID()
        #expect(throws: (any Error).self) { try WorkspaceJournal.changes(from: initial, to: candidate) }
        await #expect(throws: (any Error).self) { try await database.commit(candidate, event: "invalid.preferences", commandID: id) }
        #expect(try await database.revision() == before)
        #expect(try await database.journalEventCount() == count)
        #expect(try await database.receipt(id) == nil)
        #expect(try await database.effects().isEmpty)
    }
    var valid = initial; valid.sidebarPreferences = .init(sortMode: .manual, collapsedProjectIDs: [project.id])
    try await database.save(valid, event: "valid.preferences")
    #expect(try await database.rebuildProjection().snapshot == valid)
    try await database.save(initial, event: "reset.preferences")
    #expect(try await database.rebuildProjection().snapshot == initial)
    #expect(try await database.journal().last?.event == .sidebarPreferencesChanged(nil))
}

@Test func projectPreferencesOrderAndRenameRollBackTogetherWhenCommitFails() async throws {
    let root = try temporaryWorkspace(); defer { try? FileManager.default.removeItem(at: root) }
    let first = WorkspaceProject(path: root.appendingPathComponent("first").path)
    let second = WorkspaceProject(path: root.appendingPathComponent("second").path)
    var thread = CodingThread(project: first); thread.draft = "Preserve alongside sidebar state"
    var initial = WorkspaceSnapshot(); initial.projects = [first, second]; initial.threads = [thread]
    let url = root.appendingPathComponent("workspace.sqlite"), database = try WorkspaceDatabase(url: url)
    try await database.save(initial, event: "fixture")
    let before = try await database.revision(), count = try await database.journalEventCount(), id = UUID()
    var changed = initial; changed.projects.reverse(); changed.projects[0].name = "Renamed second"
    changed.sidebarPreferences = .init(sortMode: .manual, collapsedProjectIDs: [first.id])
    let expected = changed
    try organizationSQL(url, "CREATE TRIGGER fail_organization BEFORE INSERT ON events BEGIN SELECT RAISE(ABORT,'organization rollback fixture'); END")
    await #expect(throws: (any Error).self) { try await database.commit(expected, event: "organization", commandID: id) }
    #expect(try await database.revision() == before)
    #expect(try await database.journalEventCount() == count)
    #expect(try await database.receipt(id) == nil)
    #expect(try await database.effects().isEmpty)
    #expect(try await WorkspaceDatabase(url: url).load() == initial)
    try organizationSQL(url, "DROP TRIGGER fail_organization")
    _ = try await database.commit(expected, event: "organization", commandID: id)
    #expect(try await database.rebuildProjection().snapshot == expected)
    let mutations = try await database.journal(after: before.sequence).map(\.event)
    #expect(mutations.contains(.sidebarPreferencesChanged(expected.sidebarPreferences)))
    #expect(mutations.contains(.projectsOrdered([second.id, first.id])))
    #expect(mutations.contains(.projectUpserted(expected.projects[0])))
}

@Test(.timeLimit(.minutes(1))) func storageSevenSidebarMigrationPreservesAbsentLegacyDatesPreferencesAndStableEmptyProjectOrder() async throws {
    let root = try temporaryWorkspace(); defer { try? FileManager.default.removeItem(at: root) }
    let url = root.appendingPathComponent("workspace.sqlite")
    var z = WorkspaceProject(path: root.appendingPathComponent("z").path), a = WorkspaceProject(path: root.appendingPathComponent("a").path)
    var archivedProject = WorkspaceProject(path: root.appendingPathComponent("archive").path)
    z.name = "Zulu"; a.name = "Alpha"; archivedProject.name = "Archived only"
    z.createdAt = nil; z.updatedAt = nil; a.createdAt = nil; a.updatedAt = nil
    archivedProject.createdAt = nil; archivedProject.updatedAt = nil
    var archived = CodingThread(project: archivedProject)
    archived.isArchived = true; archived.draft = "Legacy unsent draft 🌍"
    archived.messages = [.init(role: .user, text: "Legacy conversation preserved")]
    var snapshot = WorkspaceSnapshot(); snapshot.projects = [z, a, archivedProject]; snapshot.threads = [archived]
    let oldPayload = try JSONEncoder().encode(snapshot)
    let object = try #require(JSONSerialization.jsonObject(with: oldPayload) as? [String: Any])
    let oldProjects = try #require(object["projects"] as? [[String: Any]])
    #expect(object["sidebarPreferences"] == nil && oldProjects.allSatisfy { $0["createdAt"] == nil && $0["updatedAt"] == nil })
    // This fixture writes only pre-organization journal mutations, then marks the existing storage as v7.
    let oldDatabase = try WorkspaceDatabase(url: url); try await oldDatabase.save(snapshot, event: "legacy")
    try organizationSQL(url, "PRAGMA user_version=7")
    let database = try WorkspaceDatabase(url: url)
    #expect(try organizationStorageVersion(url) == 15)
    #expect(try await database.load() == snapshot)
    #expect(try await database.rebuildProjection().snapshot == snapshot)
    let harness = OrganizationHarness(), engine = try WorkspaceEngine(url: url, providerFactory: { harness.make($0) })
    do {
        let recovered = try await engine.load()
        #expect(recovered == snapshot && recovered.sidebarPreferences == nil)
        #expect(recovered.effectiveSidebarPreferences.sortMode == .updatedAt)
        #expect(recovered.projects.allSatisfy { $0.createdAt == nil && $0.updatedAt == nil && recovered.isProjectExpanded($0.id) })
        #expect(recovered.orderedProjects.map(\.id) == [z.id, a.id, archivedProject.id])
        try await engine.dispatch(.setProjectSortMode(.createdAt))
        #expect(await engine.current().snapshot.orderedProjects.map(\.id) == [z.id, a.id, archivedProject.id])
        try await engine.dispatch(.setProjectExpanded(projectID: a.id, expanded: false))
        let organized = await engine.current().snapshot
        #expect(organized.threads == [archived] && organized.projects == snapshot.projects && harness.count == 0)
        #expect(try await database.rebuildProjection().snapshot == organized)
        #expect(try await database.effects().isEmpty)
        await engine.shutdown()
    } catch { await engine.shutdown(); throw error }
}

private func organizationSQL(_ url: URL, _ statement: String) throws {
    var connection: OpaquePointer?
    guard sqlite3_open(url.path, &connection) == SQLITE_OK else { throw CoincideError("Organization fixture database could not open") }
    defer { sqlite3_close(connection) }
    sqlite3_busy_timeout(connection, 1_000)
    guard sqlite3_exec(connection, statement, nil, nil, nil) == SQLITE_OK else { throw CoincideError("Organization fixture SQL failed") }
}
private func organizationStorageVersion(_ url: URL) throws -> Int32 {
    var connection: OpaquePointer?, statement: OpaquePointer?
    guard sqlite3_open(url.path, &connection) == SQLITE_OK else { throw CoincideError("Organization fixture database could not open") }
    defer { sqlite3_close(connection) }
    guard sqlite3_prepare_v2(connection, "PRAGMA user_version", -1, &statement, nil) == SQLITE_OK else { throw CoincideError("Organization fixture version could not prepare") }
    defer { sqlite3_finalize(statement) }
    guard sqlite3_step(statement) == SQLITE_ROW else { throw CoincideError("Organization fixture version could not read") }
    return sqlite3_column_int(statement, 0)
}
