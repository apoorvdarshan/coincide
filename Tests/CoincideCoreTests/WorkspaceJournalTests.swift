import CSQLite
import Foundation
import Testing
@testable import CoincideCore

private func journalFixture(_ root: URL) -> WorkspaceSnapshot {
    var value = WorkspaceSnapshot()
    let project = WorkspaceProject(path: root.path)
    var thread = CodingThread(project: project)
    thread.messages = [.init(role: .assistant, text: "e")]
    value.projects = [project]; value.threads = [thread]
    return value
}

private func sql(_ url: URL, _ sql: String, data: Data? = nil) throws {
    var db: OpaquePointer?
    guard sqlite3_open(url.path, &db) == SQLITE_OK else { throw CoincideError("Test database could not open.") }
    defer { sqlite3_close(db) }
    sqlite3_busy_timeout(db, 1_000)
    if let data {
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK else { throw CoincideError("Test SQL could not prepare.") }
        defer { sqlite3_finalize(statement) }
        let bound = data.withUnsafeBytes { sqlite3_bind_blob(statement, 1, $0.baseAddress, Int32($0.count), unsafeBitCast(-1, to: sqlite3_destructor_type.self)) }
        guard bound == SQLITE_OK, sqlite3_step(statement) == SQLITE_DONE else { throw CoincideError("Test SQL could not write.") }
    } else if sqlite3_exec(db, sql, nil, nil, nil) != SQLITE_OK { throw CoincideError("Test SQL failed.") }
}

@Test func journalReplaysUnicodeStreamingReorderingTruncationAndRemoval() throws {
    let root = URL(fileURLWithPath: "/tmp")
    var expected = journalFixture(root), replayed = WorkspaceSnapshot()
    for event in try WorkspaceJournal.changes(from: replayed, to: expected) { try event.apply(to: &replayed) }
    #expect(replayed == expected)
    expected.threads[0].messages[0].text += "\u{301} 🌍"
    expected.threads[0].draft = "Unsent"
    let events = try WorkspaceJournal.changes(from: replayed, to: expected)
    #expect(events.contains { if case .messageTextAppended(_, _, _, let text) = $0 { text == "\u{301} 🌍" } else { false } })
    for event in events { try event.apply(to: &replayed) }
    #expect(replayed == expected)
    var second = CodingThread(project: expected.projects[0]); second.messages = [.init(role: .user, text: "New")]
    expected.threads.insert(second, at: 0)
    expected.threads[1].messages.append(.init(role: .assistant, text: "Later"))
    for event in try WorkspaceJournal.changes(from: replayed, to: expected) { try event.apply(to: &replayed) }
    #expect(replayed == expected)
    expected.threads.reverse(); expected.threads[0].messages.removeLast()
    expected.threads[0].messages[0].text = "Replaced"
    for event in try WorkspaceJournal.changes(from: replayed, to: expected) { try event.apply(to: &replayed) }
    #expect(replayed == expected)
    expected.threads.removeAll(); expected.projects.removeAll()
    for event in try WorkspaceJournal.changes(from: replayed, to: expected) { try event.apply(to: &replayed) }
    #expect(replayed == expected)
}

@Test func journalReceiptsDeduplicateConcurrentConnectionsAndRejectStaleWrites() async throws {
    let root = try temporaryWorkspace(); defer { try? FileManager.default.removeItem(at: root) }
    let url = root.appendingPathComponent("workspace.sqlite")
    let first = try WorkspaceDatabase(url: url), second = try WorkspaceDatabase(url: url)
    let snapshot = journalFixture(root), command = UUID()
    async let a = first.commit(snapshot, event: "thread.created", commandID: command)
    async let b = second.commit(snapshot, event: "thread.created", commandID: command)
    let (one, two) = try await (a, b)
    #expect(one == two)
    #expect(try await first.eventCount() == 1)
    #expect(try await first.journalEventCount() == one.eventCount)
    #expect(try await second.receipt(command) == one)
    var changed = snapshot; changed.threads[0].title = "Changed"
    await #expect(throws: (any Error).self) { try await first.commit(changed, event: "thread.created", commandID: command) }
    await #expect(throws: (any Error).self) { try await second.commit(changed, event: "thread.renamed", commandID: UUID(), expectedSequence: 0) }
    #expect(try await first.load() == snapshot)
}

@Test func journalProjectionRebuildAndLegacyImportPreserveWorkspace() async throws {
    let root = try temporaryWorkspace(); defer { try? FileManager.default.removeItem(at: root) }
    let url = root.appendingPathComponent("workspace.sqlite"), snapshot = journalFixture(root)
    try sql(url, "CREATE TABLE workspace(id INTEGER PRIMARY KEY,payload BLOB NOT NULL)")
    try sql(url, "INSERT INTO workspace VALUES(1,?)", data: JSONEncoder().encode(snapshot))
    let database = try WorkspaceDatabase(url: url)
    #expect(try await database.load() == snapshot)
    let imported = try await database.journal()
    #expect(imported.count == 1)
    #expect(imported.first?.event == .imported(snapshot))
    var changed = snapshot; changed.threads[0].messages[0].text += "\u{301}"
    try await database.save(changed, event: "provider.event")
    try sql(url, "DELETE FROM workspace; DELETE FROM workspace_projection")
    let reopened = try WorkspaceDatabase(url: url)
    #expect(try await reopened.load() == changed)
    #expect(try await reopened.rebuildProjection().snapshot == changed)
    #expect(try await reopened.eventCount() == 1)
    let records = try await reopened.journal(after: 1, limit: 1)
    #expect(records.count == 1 && records[0].sequence == 2)
}

@Test func journalTransactionFailureRollsBackEventsProjectionAndReceipt() async throws {
    let root = try temporaryWorkspace(); defer { try? FileManager.default.removeItem(at: root) }
    let url = root.appendingPathComponent("workspace.sqlite"), before = journalFixture(root)
    let database = try WorkspaceDatabase(url: url)
    try await database.save(before, event: "thread.created")
    let count = try await database.journalEventCount(), command = UUID()
    try sql(url, "CREATE TRIGGER fail_audit BEFORE INSERT ON events BEGIN SELECT RAISE(ABORT,'test interruption'); END")
    var after = before; after.threads[0].messages[0].text += " more"
    await #expect(throws: (any Error).self) { try await database.commit(after, event: "provider.event", commandID: command) }
    #expect(try await database.receipt(command) == nil)
    #expect(try await database.journalEventCount() == count)
    #expect(try await database.load() == before)
    #expect(try await WorkspaceDatabase(url: url).load() == before)
    try sql(url, "DROP TRIGGER fail_audit")
    let receipt = try await database.commit(after, event: "provider.event", commandID: command)
    #expect(receipt.eventCount == 1)
    #expect(try await database.rebuildProjection().snapshot == after)
}

@Test func journalRefusesFutureStorageAndIncompleteHistory() async throws {
    let root = try temporaryWorkspace(); defer { try? FileManager.default.removeItem(at: root) }
    let future = root.appendingPathComponent("future.sqlite")
    try sql(future, "PRAGMA user_version=99")
    #expect(throws: (any Error).self) { try WorkspaceDatabase(url: future) }
    let url = root.appendingPathComponent("workspace.sqlite")
    let database = try WorkspaceDatabase(url: url)
    try await database.save(journalFixture(root), event: "thread.created")
    try sql(url, "DELETE FROM workspace_journal WHERE sequence=(SELECT max(sequence) FROM workspace_journal)")
    await #expect(throws: (any Error).self) { try await WorkspaceDatabase(url: url).load() }
    var invalid = journalFixture(root); invalid.threads.append(invalid.threads[0])
    #expect(throws: (any Error).self) { try WorkspaceJournal.changes(from: invalid, to: invalid) }
}

@Test func emptyJournalDoesNotCreateRepeatedLegacyImports() async throws {
    let root = try temporaryWorkspace(); defer { try? FileManager.default.removeItem(at: root) }
    let url = root.appendingPathComponent("workspace.sqlite")
    let first = try WorkspaceDatabase(url: url)
    try await first.save(WorkspaceSnapshot(), event: "workspace.opened")
    let second = try WorkspaceDatabase(url: url)
    #expect(try await second.load() == WorkspaceSnapshot())
    #expect(try await second.journalEventCount() == 0)
}

@Test func outboxCommitAndLogicalCommandRetryDoNotDuplicateActions() async throws {
    let root = try temporaryWorkspace(); defer { try? FileManager.default.removeItem(at: root) }
    let database = try WorkspaceDatabase(url: root.appendingPathComponent("workspace.sqlite"))
    let snapshot = journalFixture(root), command = UUID(), payload = Data("submit this exact turn".utf8)
    let pending = PendingWorkspaceEffect(request: .providerStart(threadID: snapshot.threads[0].id, runID: command,
        configuration: .init(thread: snapshot.threads[0]), prompt: "Fixture prompt"))
    let receipt = try await database.commit(snapshot, event: "turn.requested", commandID: command, effects: [pending], deduplicationPayload: payload)
    var newer = snapshot; newer.threads[0].title = "A newer title"
    try await database.save(newer, event: "thread.renamed")
    let duplicate = try await database.commit(snapshot, event: "turn.requested", commandID: command, effects: [pending], deduplicationPayload: payload)
    #expect(duplicate == receipt)
    #expect(try await database.receipt(command, matching: payload) == receipt)
    await #expect(throws: (any Error).self) { try await database.receipt(command, matching: Data("different command".utf8)) }
    #expect(try await database.load() == newer)
    let effects = try await database.effects(commandID: command)
    #expect(effects.count == 1 && effects[0].id == pending.id && effects[0].status == .pending)
}

@Test func outboxClaimsAndLeaseFencesRejectDuplicateOwnership() async throws {
    let root = try temporaryWorkspace(); defer { try? FileManager.default.removeItem(at: root) }
    let url = root.appendingPathComponent("workspace.sqlite"), snapshot = journalFixture(root)
    let first = try WorkspaceDatabase(url: url), second = try WorkspaceDatabase(url: url)
    let command = UUID(), workerA = UUID(), workerB = UUID(), now = Date()
    let actions = (0..<2).map { _ in PendingWorkspaceEffect(request: .providerInterrupt(threadID: snapshot.threads[0].id, runID: UUID())) }
    _ = try await first.commit(snapshot, event: "fixture", commandID: command, effects: actions)
    async let a = first.claimNextEffect(workerID: workerA, leaseDuration: 60, now: now)
    async let b = second.claimNextEffect(workerID: workerB, leaseDuration: 60, now: now)
    let results = try await (a, b)
    let one = try #require(results.0), two = try #require(results.1)
    #expect(one.id != two.id && one.attemptCount == 1 && two.attemptCount == 1)
    #expect(try await first.claimNextEffect(workerID: UUID(), now: now) == nil)
    #expect(try await first.renewEffectLease(one.id, workerID: workerB, now: now) == false)
    #expect(try await first.settleEffect(one.id, workerID: workerB, now: now) == false)
    #expect(try await first.renewEffectLease(one.id, workerID: workerA, leaseDuration: 120, now: now.addingTimeInterval(1)))
    #expect(try await first.settleEffect(one.id, workerID: workerA, now: now.addingTimeInterval(2)))
    #expect(try await first.settleEffect(one.id, workerID: workerA, now: now.addingTimeInterval(3)) == false)
    let expired = now.addingTimeInterval(1_000)
    #expect(try await second.renewEffectLease(two.id, workerID: workerB, now: expired) == false)
    #expect(try await second.settleEffect(two.id, workerID: workerB, now: expired) == false)
    #expect(try await second.claimNextEffect(workerID: UUID(), now: expired) == nil)
    #expect(try await second.cancelEffectsAfterProcessLoss(now: expired) == [two.id])
    #expect(try await first.effects().map(\.status).filter { $0 == .succeeded }.count == 1)
}

@Test func outboxRollsBackWithIntentAndCancelsAfterRuntimeLoss() async throws {
    let root = try temporaryWorkspace(); defer { try? FileManager.default.removeItem(at: root) }
    let url = root.appendingPathComponent("workspace.sqlite"), before = journalFixture(root)
    let database = try WorkspaceDatabase(url: url), command = UUID()
    try await database.save(before, event: "thread.created")
    let count = try await database.journalEventCount()
    var after = before; after.threads[0].state = .running
    let pending = PendingWorkspaceEffect(request: .providerInterrupt(threadID: before.threads[0].id, runID: UUID()))
    try sql(url, "CREATE TRIGGER fail_audit BEFORE INSERT ON events BEGIN SELECT RAISE(ABORT,'test interruption'); END")
    await #expect(throws: (any Error).self) { try await database.commit(after, event: "fixture", commandID: command, effects: [pending]) }
    #expect(try await database.effects().isEmpty)
    #expect(try await database.receipt(command) == nil)
    #expect(try await database.journalEventCount() == count)
    #expect(try await database.load() == before)
    try sql(url, "DROP TRIGGER fail_audit")
    _ = try await database.commit(after, event: "fixture", commandID: command, effects: [pending])
    let reopened = try WorkspaceDatabase(url: url)
    #expect(try await reopened.cancelEffectsAfterProcessLoss() == [pending.id])
    #expect(try await reopened.effects().first?.status == .cancelled)
    #expect(try await reopened.claimNextEffect(workerID: UUID()) == nil)
}

@Test func outboxRejectsInvalidLeasesAndDoesNotRetryProviderFailures() async throws {
    let root = try temporaryWorkspace(); defer { try? FileManager.default.removeItem(at: root) }
    let database = try WorkspaceDatabase(url: root.appendingPathComponent("workspace.sqlite")), snapshot = journalFixture(root)
    let pending = PendingWorkspaceEffect(request: .providerInterrupt(threadID: snapshot.threads[0].id, runID: UUID()))
    _ = try await database.commit(snapshot, event: "fixture", commandID: UUID(), effects: [pending])
    await #expect(throws: (any Error).self) { try await database.claimNextEffect(workerID: UUID(), leaseDuration: -.infinity) }
    let worker = UUID(), effect = try #require(try await database.claimNextEffect(workerID: worker))
    #expect(try await database.settleEffect(effect.id, workerID: worker, error: "Fixture provider failed"))
    let failed = try #require(try await database.effects().first)
    #expect(failed.status == .failed && failed.leaseOwner == nil && failed.lastError == "Fixture provider failed")
    #expect(try await database.claimNextEffect(workerID: UUID()) == nil)
}
