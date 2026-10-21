import CSQLite
import Foundation
import Testing
@testable import CoincideCore

private struct GroupMutationFixture {
    let snapshot: WorkspaceSnapshot
    let group: ProjectGroup
    let survivor: CodingThread
    var threadIDs: [UUID] { snapshot.threads.filter { group.memberProjectIDs.contains($0.projectID) }.map(\.id) }
}

private func groupMutationFixture(_ root: URL) throws -> GroupMutationFixture {
    func project(_ name: String, repository: String) throws -> WorkspaceProject {
        var project = WorkspaceProject(path: root.appendingPathComponent(name).path)
        let remote = try #require(RepositoryIdentity.normalizedRemote("https://github.com/Team/\(repository).git"))
        project.repositoryIdentity = try .init(remote: remote, remoteName: "origin", rootPath: project.path, projectRelativePath: "")
        project.createdAt = Date(timeIntervalSince1970: 10); project.updatedAt = Date(timeIntervalSince1970: 20)
        return project
    }
    let a = try project("first-checkout", repository: "Shared"), b = try project("second-checkout", repository: "Shared")
    let keep = try project("survivor", repository: "Other"), last = try project("last-survivor", repository: "Last")
    var alias = a; alias.id = UUID(); alias.path += "/"; alias.updatedAt = Date(timeIntervalSince1970: 1)
    var active = CodingThread(project: a), archived = CodingThread(project: a), aliasThread = CodingThread(project: alias)
    let second = CodingThread(project: b), survivor = CodingThread(project: keep)
    active.draft = "Keep my draft"; active.workspacePath = root.appendingPathComponent("worktrees/user-checkout").path
    archived.isArchived = true; aliasThread.isArchived = true
    var snapshot = WorkspaceSnapshot(); snapshot.projects = [keep, a, alias, b, last]
    snapshot.threads = [active, archived, survivor, aliasThread, second]
    let group = try #require(snapshot.projectGroups.first { $0.memberProjectIDs.contains(a.id) })
    let keepGroup = try #require(snapshot.projectGroups.first { $0.memberProjectIDs.contains(keep.id) })
    let firstPath = try #require(snapshot.physicalProjectKey(for: a.id)), keepPath = try #require(snapshot.physicalProjectKey(for: keep.id))
    snapshot.sidebarPreferences = .init(sortMode: .manual, collapsedProjectIDs: [a.id, alias.id, b.id, keep.id],
        groupingOverrides: [firstPath: .repository, keepPath: .repository],
        groupExpandedByKey: [group.key: false, keepGroup.key: false],
        activeProjectByGroup: [group.key: b.id, keepGroup.key: keep.id], selectedThreadID: survivor.id)
    try WorkspaceJournal.validate(snapshot)
    return .init(snapshot: snapshot, group: group, survivor: survivor)
}

private func groupMutationDecision(_ command: WorkspaceCommand, _ snapshot: WorkspaceSnapshot, now: Date = Date()) throws -> WorkspaceDecision {
    try WorkspaceDecision.make(.client(command), id: UUID(), snapshot: snapshot, now: now)
}

@Test func projectGroupRenameChangesEveryRegistrationAtomicallyAndAcceptsReorderedReferencesWithoutTimestampChurn() throws {
    let fixture = try groupMutationFixture(URL(fileURLWithPath: "/tmp/group-mutation-rename"))
    let before = fixture.snapshot, group = fixture.group, now = Date(timeIntervalSince1970: 100)
    #expect(group.members.count == 2 && group.memberProjectReferences.count == 3)
    #expect(group.memberProjectReferences == before.projects.filter { group.memberProjectIDs.contains($0.id) }.map { ProjectGroupMemberReference(project: $0) })
    let command = WorkspaceCommand.renameProjectGroup(groupKey: group.key, expectedProjects: Array(group.memberProjectReferences.reversed()), title: "  Shared workspace  ")
    #expect(try JSONDecoder().decode(WorkspaceCommand.self, from: JSONEncoder().encode(command)) == command)
    let decision = try groupMutationDecision(command, before, now: now)
    var expected = before
    for i in expected.projects.indices where group.memberProjectIDs.contains(expected.projects[i].id) {
        expected.projects[i].name = "Shared workspace"; expected.projects[i].updatedAt = now
    }
    #expect(decision.snapshot == expected)
    #expect(decision.effects.isEmpty && decision.closeRuntimes.isEmpty)
    let renamed = try #require(decision.snapshot.projectGroups.first { $0.key == group.key })
    #expect(renamed.displayName == "Shared workspace" && renamed.memberProjectReferences == group.memberProjectReferences)
    #expect(try groupMutationDecision(command, expected, now: now.addingTimeInterval(900)).snapshot == expected)
    var reordered = before; reordered.projects.reverse()
    let afterReorder = try groupMutationDecision(command, reordered, now: now).snapshot
    #expect(afterReorder.projects.map(\.id) == reordered.projects.map(\.id))
    #expect(afterReorder.threads == before.threads)
    for title in ["", "\n", "line\u{2028}break", String(repeating: "a", count: 201)] {
        #expect(throws: WorkspaceCommandError.self) {
            try groupMutationDecision(.renameProjectGroup(groupKey: group.key, expectedProjects: group.memberProjectReferences, title: title), before)
        }
    }
}

@Test func projectGroupMutationsRejectDuplicateMissingMovedOrRegroupedRegistrationsAndIncompleteArchivedThreadUnions() throws {
    let fixture = try groupMutationFixture(URL(fileURLWithPath: "/tmp/group-mutation-stale"))
    let before = fixture.snapshot, group = fixture.group, refs = group.memberProjectReferences
    var wrongPath = refs; wrongPath[0] = .init(id: refs[0].id, path: refs[0].path + "/")
    let invalidReferences = [Array(refs.dropLast()), refs + [refs[0]], wrongPath, [.init(id: UUID(), path: refs[0].path)] + Array(refs.dropFirst())]
    func reject(_ snapshot: WorkspaceSnapshot, references: [ProjectGroupMemberReference]? = nil, key: String? = nil) {
        let references = references ?? refs
        #expect(throws: WorkspaceCommandError.self) {
            try groupMutationDecision(.renameProjectGroup(groupKey: key ?? group.key, expectedProjects: references, title: "Changed"), snapshot)
        }
        #expect(throws: WorkspaceCommandError.self) {
            try groupMutationDecision(.removeProjectGroup(groupKey: key ?? group.key, expectedProjects: references, expectedThreadIDs: fixture.threadIDs), snapshot)
        }
    }
    for references in invalidReferences { reject(before, references: references) }
    reject(before, key: "missing-group")
    var moved = before
    let movedIndex = try #require(moved.projects.firstIndex { $0.id == refs.last?.id })
    moved.projects[movedIndex].path += "/"
    try WorkspaceJournal.validate(moved)
    #expect(moved.projectGroups.first { $0.key == group.key }?.memberProjectIDs == group.memberProjectIDs)
    reject(moved)
    let regrouped = try groupMutationDecision(.setProjectGroupingOverride(projectID: refs.last!.id, mode: .separate), before).snapshot
    #expect(regrouped.projects.map(\.id) == before.projects.map(\.id))
    reject(regrouped)
    let onlyActive = before.threads.filter { group.memberProjectIDs.contains($0.projectID) && !$0.isArchived }.map(\.id)
    for threadIDs in [onlyActive, Array(fixture.threadIDs.dropLast()), fixture.threadIDs + [fixture.threadIDs[0]], [UUID()] + Array(fixture.threadIDs.dropFirst())] {
        #expect(throws: WorkspaceCommandError.self) {
            try groupMutationDecision(.removeProjectGroup(groupKey: group.key, expectedProjects: refs, expectedThreadIDs: threadIDs), before)
        }
    }
    var newConversation = before
    newConversation.threads.append(CodingThread(project: before.projects[movedIndex]))
    #expect(throws: WorkspaceCommandError.self) {
        try groupMutationDecision(.removeProjectGroup(groupKey: group.key, expectedProjects: refs, expectedThreadIDs: fixture.threadIDs), newConversation)
    }
}

@Test func projectGroupRemovalPrunesOnlyRemovedPreferencesAndPreservesSurvivorOrderSelectionAndConversations() throws {
    let fixture = try groupMutationFixture(URL(fileURLWithPath: "/tmp/group-mutation-preferences")), group = fixture.group
    let decision = try groupMutationDecision(.removeProjectGroup(groupKey: group.key, expectedProjects: Array(group.memberProjectReferences.reversed()), expectedThreadIDs: Array(fixture.threadIDs.reversed())), fixture.snapshot)
    var expected = fixture.snapshot
    expected.projects.removeAll { group.memberProjectIDs.contains($0.id) }
    expected.threads.removeAll { group.memberProjectIDs.contains($0.projectID) }
    expected.reconcileGroupingPreferences()
    #expect(decision.snapshot == expected && decision.effects.isEmpty && decision.closeRuntimes == Set(fixture.threadIDs))
    let preferences = decision.snapshot.effectiveSidebarPreferences
    #expect(preferences.selectedThreadID == fixture.survivor.id)
    #expect(preferences.collapsedProjectIDs == [fixture.survivor.projectID])
    #expect(preferences.groupExpandedByKey.count == 1 && preferences.groupExpandedByKey[group.key] == nil)
    #expect(preferences.activeProjectByGroup.values.sorted { $0.uuidString < $1.uuidString } == [fixture.survivor.projectID])
    #expect(preferences.groupingOverrides.count == 1)
    var selectedRemoved = fixture.snapshot; selectedRemoved.sidebarPreferences?.selectedThreadID = fixture.threadIDs.first
    #expect(try groupMutationDecision(.removeProjectGroup(groupKey: group.key, expectedProjects: group.memberProjectReferences, expectedThreadIDs: fixture.threadIDs), selectedRemoved).snapshot.effectiveSidebarPreferences.selectedThreadID == nil)
}

private func groupMutationSQL(_ url: URL, _ statement: String) throws {
    var connection: OpaquePointer?
    guard sqlite3_open(url.path, &connection) == SQLITE_OK else { throw CoincideError("Group mutation fixture could not open its database") }
    defer { sqlite3_close(connection) }
    sqlite3_busy_timeout(connection, 1_000)
    guard sqlite3_exec(connection, statement, nil, nil, nil) == SQLITE_OK else { throw CoincideError("Group mutation fixture SQL failed") }
}

@Test func projectGroupTransactionsRollbackEveryMemberJournalPreferenceAndEffectBeforeCommittingTogether() async throws {
    let root = try temporaryWorkspace(); defer { try? FileManager.default.removeItem(at: root) }
    let fixture = try groupMutationFixture(root), group = fixture.group, snapshot = fixture.snapshot
    let url = root.appendingPathComponent("group.sqlite"), database = try WorkspaceDatabase(url: url)
    let targets = fixture.threadIDs
    let requests = (targets + [fixture.survivor.id]).map { PendingWorkspaceEffect(request: .providerInterrupt(threadID: $0, runID: UUID())) }
    _ = try await database.commit(snapshot, event: "fixture", commandID: UUID(), effects: requests)
    let worker = UUID(), leased = try #require(try await database.claimNextEffect(workerID: worker))
    #expect(leased.id == requests[0].id)
    let renameID = UUID(), before = try await database.revision(), effectsBefore = try await database.effects()
    let rename = try groupMutationDecision(.renameProjectGroup(groupKey: group.key, expectedProjects: group.memberProjectReferences, title: "Atomic title"), snapshot, now: Date(timeIntervalSince1970: 100)).snapshot
    try groupMutationSQL(url, "CREATE TRIGGER fail_group_mutation BEFORE INSERT ON events BEGIN SELECT RAISE(ABORT,'atomic group mutation fixture'); END")
    await #expect(throws: (any Error).self) {
        try await database.commit(rename, event: "group.rename", commandID: renameID, expectedSequence: before.sequence)
    }
    #expect(try await database.revision() == before)
    #expect(try await database.effects() == effectsBefore)
    #expect(try await database.receipt(renameID) == nil)
    #expect(try await database.rebuildProjection() == before)
    try groupMutationSQL(url, "DROP TRIGGER fail_group_mutation")
    let renameReceipt = try await database.commit(rename, event: "group.rename", commandID: renameID, expectedSequence: before.sequence)
    #expect(try await database.effects() == effectsBefore)
    let renamedRecords = try await database.journal().filter { $0.commandID == renameID }
    #expect(renamedRecords.count == group.memberProjectIDs.count)
    #expect(renamedRecords.allSatisfy { if case .projectUpserted = $0.event { true } else { false } })
    let renamed = try await database.revision(), removeID = UUID()
    let removed = try groupMutationDecision(.removeProjectGroup(groupKey: group.key, expectedProjects: group.memberProjectReferences, expectedThreadIDs: targets), rename).snapshot
    try groupMutationSQL(url, "CREATE TRIGGER fail_group_mutation BEFORE INSERT ON events BEGIN SELECT RAISE(ABORT,'atomic group mutation fixture'); END")
    await #expect(throws: (any Error).self) {
        try await database.commit(removed, event: "group.remove", commandID: removeID, expectedSequence: renamed.sequence)
    }
    #expect(try await database.revision() == renamed)
    #expect(try await database.effects() == effectsBefore)
    #expect(try await database.receipt(removeID) == nil)
    #expect(try await WorkspaceDatabase(url: url).load() == rename)
    try groupMutationSQL(url, "DROP TRIGGER fail_group_mutation")
    _ = try await database.commit(removed, event: "group.remove", commandID: removeID, expectedSequence: renamed.sequence)
    let effects = try await database.effects()
    #expect(effects.first { $0.id == leased.id } == leased)
    for request in requests.dropFirst().dropLast() { #expect(effects.first { $0.id == request.id }?.status == .cancelled) }
    #expect(effects.last == effectsBefore.last)
    #expect(try await database.cancelEffect(leased.id, workerID: worker, reason: "Group removed"))
    #expect(try await database.rebuildProjection().snapshot == removed)
    #expect(try await WorkspaceDatabase(url: url).load() == removed)
    #expect(try await database.commit(rename, event: "group.rename", commandID: renameID) == renameReceipt)
    #expect(try await database.load() == removed)
    let removedRecords = try await database.journal().filter { $0.commandID == removeID }
    #expect(removedRecords.filter { if case .projectRemoved = $0.event { true } else { false } }.count == group.memberProjectIDs.count)
    #expect(removedRecords.filter { if case .threadRemoved = $0.event { true } else { false } }.count == targets.count)
    #expect(try await database.journal().contains { if case .threadMetadataUpserted(let thread) = $0.event { thread.draft == "Keep my draft" } else { false } })
}

private actor GroupMutationProvider: ProviderSession {
    nonisolated let events: AsyncStream<ProviderEvent>
    private let sink: AsyncStream<ProviderEvent>.Continuation
    private var waiter: CheckedContinuation<Void, any Error>?
    private var cancelled = false
    private var runID: UUID?
    private(set) var prompts: [String] = []
    private(set) var closed = false
    init() {
        let pair = AsyncStream<ProviderEvent>.makeStream(); events = pair.stream; sink = pair.continuation
    }
    func models() -> [ProviderModel] { [] }
    func send(text: String, thread: CodingThread) async throws {
        prompts.append(text); runID = thread.activeRun?.id
        emit(.thread("group-fixture-\(thread.id)")); emit(.turn(UUID().uuidString))
        try await withTaskCancellationHandler {
            try Task.checkCancellation()
            try await withCheckedThrowingContinuation { (value: CheckedContinuation<Void, any Error>) in
                if cancelled { value.resume(throwing: CancellationError()) } else { waiter = value }
            }
            try Task.checkCancellation()
        } onCancel: { Task { await self.cancel() } }
    }
    func interrupt() { cancel() }
    func respond(_ request: ApprovalRequest, allow: Bool) { }
    func answer(_ request: ApprovalRequest, answers: [String: String]) { }
    func close() { closed = true; cancel(); sink.finish() }
    func complete() {
        let value = waiter; waiter = nil; value?.resume()
        emit(.completed(.idle))
    }
    private func cancel() {
        cancelled = true
        let value = waiter; waiter = nil; value?.resume(throwing: CancellationError())
    }
    private func emit(_ event: ProviderEvent) {
        if let runID { sink.yield(.context(runID: runID, event: event)) } else { sink.yield(event) }
    }
}

private final class GroupMutationProviders: @unchecked Sendable {
    private let lock = NSLock()
    private var providers: [UUID: [GroupMutationProvider]] = [:]
    func make(_ thread: CodingThread) -> any ProviderSession {
        lock.lock(); defer { lock.unlock() }
        let provider = GroupMutationProvider(); providers[thread.id, default: []].append(provider); return provider
    }
    func values(_ id: UUID) -> [GroupMutationProvider] { lock.lock(); defer { lock.unlock() }; return providers[id] ?? [] }
    func all() -> [GroupMutationProvider] { lock.lock(); defer { lock.unlock() }; return providers.values.flatMap { $0 } }
    func closeAll() async { for provider in all() { await provider.close() } }
}

private func groupMutationEventually(_ condition: () async throws -> Bool) async throws {
    let deadline = ContinuousClock.now + .seconds(8)
    while try await !condition() {
        guard ContinuousClock.now < deadline else { throw CoincideError("Group mutation fixture timed out") }
        try await Task.sleep(for: .milliseconds(10))
    }
}

@Test(.timeLimit(.minutes(1))) func projectGroupRemovalSettlesEveryCheckoutRuntimeReplaysReceiptsAndPreservesAllFilesAndUnrelatedWork() async throws {
    let root = try temporaryWorkspace(); defer { try? FileManager.default.removeItem(at: root) }
    let fixture = try groupMutationFixture(root), group = fixture.group, harness = GroupMutationProviders()
    var savedFiles: [(URL, Data)] = [], identities: [String: RepositoryIdentity] = [:]
    for project in fixture.snapshot.projects {
        let directory = URL(fileURLWithPath: project.path)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let file = directory.appendingPathComponent("user-\(project.id).txt"), bytes = Data("User data for \(project.id) 🌍\n".utf8)
        try bytes.write(to: file); savedFiles.append((file, bytes))
        identities[directory.standardizedFileURL.path] = project.repositoryIdentity
    }
    let first = try #require(fixture.snapshot.threads.first { $0.projectID == group.memberProjectIDs[0] && !$0.isArchived })
    let second = try #require(fixture.snapshot.threads.first { $0.projectID == group.memberProjectIDs.last && !$0.isArchived })
    let worktree = URL(fileURLWithPath: first.workspacePath)
    try FileManager.default.createDirectory(at: worktree, withIntermediateDirectories: true)
    let worktreeFile = worktree.appendingPathComponent("uncommitted.bin"), worktreeBytes = Data([0, 3, 5, 255])
    try worktreeBytes.write(to: worktreeFile); savedFiles.append((worktreeFile, worktreeBytes))
    let url = root.appendingPathComponent("group.sqlite"), database = try WorkspaceDatabase(url: url)
    _ = try await database.commit(fixture.snapshot, event: "fixture", commandID: UUID())
    let identityMap = identities
    let engine = try WorkspaceEngine(url: url, providerFactory: { harness.make($0) }, identityResolver: { identityMap[$0.standardizedFileURL.path] })
    do {
        _ = try await engine.load()
        let attachmentBytes = Data("Group recovery attachment\n".utf8)
        let attachment = try await engine.attachments.importData(attachmentBytes, name: "recovery.txt")
        try await engine.dispatch(.addAttachments(threadID: first.id, attachments: [attachment]))
        for thread in [first, second, fixture.survivor] { try await engine.dispatch(.submit(threadID: thread.id, text: "Running \(thread.id)")) }
        try await groupMutationEventually {
            let snapshot = await engine.current().snapshot
            for thread in [first, second, fixture.survivor] {
                guard snapshot.threads.first(where: { $0.id == thread.id })?.activeRun?.nativeTurnID != nil,
                      let provider = harness.values(thread.id).first, await provider.prompts.count == 1 else { return false }
            }
            return true
        }
        try await engine.dispatch(.submit(threadID: first.id, text: "Queued work must never start"))
        let renameID = UUID(), rename = WorkspaceCommand.renameProjectGroup(groupKey: group.key, expectedProjects: group.memberProjectReferences, title: "Live group")
        let renameReceipt = try await engine.dispatch(rename, id: renameID)
        for provider in harness.all() { #expect(await provider.closed == false) }
        let beforeRejection = await engine.current(), staleID = UUID()
        let eventCount = try await database.journalEventCount(), effectsBefore = try await database.effects()
        await #expect(throws: WorkspaceCommandError.self) {
            try await engine.dispatch(.removeProjectGroup(groupKey: group.key, expectedProjects: group.memberProjectReferences, expectedThreadIDs: [first.id, second.id]), id: staleID)
        }
        #expect(await engine.current().snapshot == beforeRejection.snapshot)
        #expect(await engine.current().sequence == beforeRejection.sequence)
        #expect(try await database.journalEventCount() == eventCount)
        #expect(try await database.effects() == effectsBefore)
        #expect(try await database.receipt(staleID)?.rejection != nil)
        for provider in harness.all() { #expect(await provider.closed == false) }
        let removeID = UUID(), remove = WorkspaceCommand.removeProjectGroup(groupKey: group.key, expectedProjects: group.memberProjectReferences, expectedThreadIDs: fixture.threadIDs)
        let receipt = try await engine.dispatch(remove, id: removeID)
        for projectID in group.memberProjectIDs { await engine.awaitProjectRemovalCleanup(projectID: projectID) }
        #expect(await engine.current().error == nil)
        #expect(harness.all().count == 3)
        for thread in [first, second] {
            let provider = try #require(harness.values(thread.id).first)
            #expect(await provider.closed)
            #expect(await provider.prompts.count == 1)
        }
        let survivorProvider = try #require(harness.values(fixture.survivor.id).first)
        #expect(await survivorProvider.closed == false)
        let effects = try await database.effects()
        #expect(effects.filter { $0.request.threadID == first.id || $0.request.threadID == second.id }.allSatisfy { $0.status == .cancelled })
        #expect(effects.first { $0.request.threadID == fixture.survivor.id }?.status == .running)
        try await engine.dispatch(.editThread(fixture.survivor.id, .draft("Unrelated draft still works")))
        let newer = await engine.current()
        #expect(try await engine.dispatch(remove, id: removeID) == receipt)
        #expect(try await engine.dispatch(rename, id: renameID) == renameReceipt)
        #expect(await engine.current().snapshot == newer.snapshot)
        #expect(await engine.current().sequence == newer.sequence)
        do {
            try await engine.dispatch(.removeProjectGroup(groupKey: group.key, expectedProjects: group.memberProjectReferences, expectedThreadIDs: []), id: removeID)
            Issue.record("A group removal command identity accepted a different confirmation.")
        } catch WorkspaceCommitError.commandIDCollision { }
        for (file, bytes) in savedFiles { #expect(try Data(contentsOf: file) == bytes) }
        #expect(try await engine.attachments.data(for: attachment) == attachmentBytes)
        await survivorProvider.complete()
        try await groupMutationEventually {
            let current = await engine.current().snapshot
            let effects = try await database.effects()
            return current.threads.first { $0.id == fixture.survivor.id }?.activeRun == nil && effects.allSatisfy { $0.status != .running && $0.status != .pending }
        }
        let final = await engine.current().snapshot
        #expect(final.projects == fixture.snapshot.projects.filter { !group.memberProjectIDs.contains($0.id) })
        #expect(final.threads.count == 1 && final.threads[0].draft == "Unrelated draft still works")
        #expect(final.effectiveSidebarPreferences.selectedThreadID == fixture.survivor.id)
        #expect(try await database.rebuildProjection().snapshot == final)
        await engine.shutdown()
        let persisted = await engine.current().snapshot
        var expectedAfterClose = final; expectedAfterClose.recoverInterruptedWork()
        #expect(persisted == expectedAfterClose)
        let reopened = try WorkspaceEngine(url: url, providerFactory: { harness.make($0) }, identityResolver: { identityMap[$0.standardizedFileURL.path] })
        do {
            #expect(try await reopened.load() == persisted)
            #expect(try await reopened.dispatch(remove, id: removeID) == receipt)
            #expect(try await reopened.dispatch(rename, id: renameID) == renameReceipt)
            #expect(try await reopened.attachments.data(for: attachment) == attachmentBytes)
            await reopened.shutdown()
        } catch { await reopened.shutdown(); throw error }
        for (file, bytes) in savedFiles { #expect(try Data(contentsOf: file) == bytes) }
    } catch { await harness.closeAll(); await engine.shutdown(); throw error }
}
