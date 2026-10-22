import CSQLite
import Foundation
import Testing
@testable import CoincideCore

private func groupedProject(_ path: String, remote: String? = "https://github.com/Team/Repo.git", relative: String = "", title: String? = nil) throws -> WorkspaceProject {
    var project = WorkspaceProject(path: path)
    if let title { project.name = title }
    if let remote {
        let value = try #require(RepositoryIdentity.normalizedRemote(remote))
        let root = relative.isEmpty ? project.path : String(project.path.dropLast(relative.count + 1))
        project.repositoryIdentity = try .init(remote: value, remoteName: "origin", rootPath: root, projectRelativePath: relative)
    }
    return project
}
private func groupingDecision(_ command: WorkspaceCommand, _ snapshot: WorkspaceSnapshot) throws -> WorkspaceSnapshot {
    try WorkspaceDecision.make(.client(command), id: UUID(), snapshot: snapshot, now: Date()).snapshot
}

@Test func projectGroupsPreservePhysicalAliasesForksMonorepoModesAndCollisionSafeKeys() throws {
    let a = try groupedProject("/tmp/grouping/first", title: "First"), b = try groupedProject("/tmp/grouping/second", title: "Second")
    var stale = a; stale.id = UUID(); stale.path += "/"; stale.updatedAt = Date(timeIntervalSince1970: 1); stale.repositoryIdentity = nil
    let sub = try groupedProject("/tmp/grouping/third/packages/web", relative: "packages/web", title: "Web")
    let fork = try groupedProject("/tmp/grouping/fork", remote: "https://github.com/Someone/Fork.git", title: "Fork")
    let local = try groupedProject("/tmp/grouping/local", remote: nil)
    var snapshot = WorkspaceSnapshot(); snapshot.projects = [a, stale, fork, b, sub, local]
    var groups = snapshot.projectGroups
    #expect(groups.count == 3 && groups[0].members.map(\.id) == [a.id, b.id, sub.id])
    #expect(groups[0].memberProjectIDs == [a.id, stale.id, b.id, sub.id])
    #expect(groups[0].displayName == "Team/Repo" && groups[0].representative.id == a.id)
    snapshot = try groupingDecision(.setProjectGroupingMode(.repositoryPath), snapshot)
    groups = snapshot.projectGroups
    #expect(groups.count == 4 && groups[0].memberProjectIDs == [a.id, stale.id, b.id])
    snapshot = try groupingDecision(.setProjectGroupingOverride(projectID: b.id, mode: .separate), snapshot)
    #expect(snapshot.projectGroups.count == 5)
    #expect(Set(snapshot.projectGroups.flatMap(\.memberProjectIDs)) == Set(snapshot.projects.map(\.id)))
    snapshot = try groupingDecision(.setProjectGroupingMode(.separate), snapshot)
    #expect(snapshot.projectGroups.count == 5 && snapshot.projectGroups[0].memberProjectIDs == [a.id, stale.id])
    #expect(snapshot.projects.map(\.id) == [a.id, stale.id, fork.id, b.id, sub.id, local.id])
    var collision = WorkspaceSnapshot()
    collision.projects = [try groupedProject("/tmp/grouping/collision-a", remote: "https://host.invalid/org/repo::pkg"),
                          try groupedProject("/tmp/grouping/collision-b/pkg", remote: "https://host.invalid/org/repo", relative: "pkg")]
    collision = try groupingDecision(.setProjectGroupingMode(.repositoryPath), collision)
    #expect(Set(collision.projectGroups.map(\.key)).count == 2)
    try WorkspaceJournal.validate(snapshot)
}

@Test func groupedActivityIncludesAliasUserAndQueueDatesExcludesArchivedAndPreservesManualOrder() throws {
    let a = try groupedProject("/tmp/group-activity/a", title: "Shared custom title")
    let b = try groupedProject("/tmp/group-activity/b", title: "Shared custom title")
    let other = try groupedProject("/tmp/group-activity/other", remote: "https://github.com/Team/Other.git")
    var alias = a; alias.id = UUID(); alias.updatedAt = Date(timeIntervalSince1970: 1)
    var first = CodingThread(project: a), second = CodingThread(project: alias), unrelated = CodingThread(project: other)
    var user = ChatMessage(role: .user, text: "Older input"); user.createdAt = Date(timeIntervalSince1970: 100)
    first.messages = [user]; first.updatedAt = Date(timeIntervalSince1970: 90_000)
    user.createdAt = Date(timeIntervalSince1970: 200); unrelated.messages = [user]
    second.queuedTurns = [.init(id: UUID(), text: "Accepted alias input", configuration: .init(thread: second), createdAt: Date(timeIntervalSince1970: 300))]
    var snapshot = WorkspaceSnapshot(); snapshot.projects = [other, a, alias, b]; snapshot.threads = [first, second, unrelated]
    let group = try #require(snapshot.projectGroups.first { $0.memberProjectIDs.contains(a.id) })
    #expect(group.displayName == "Shared custom title")
    #expect(snapshot.orderedProjectGroups.first?.key == group.key)
    snapshot.threads[1].isArchived = true
    #expect(snapshot.orderedProjectGroups.first?.memberProjectIDs == [other.id])
    var assistant = ChatMessage(role: .assistant, text: "Streaming"); assistant.createdAt = Date(timeIntervalSince1970: 100_000)
    snapshot.threads[0].messages.append(assistant)
    #expect(snapshot.orderedProjectGroups.first?.memberProjectIDs == [other.id])
    snapshot = try groupingDecision(.setProjectSortMode(.manual), snapshot)
    #expect(snapshot.orderedProjectGroups == snapshot.projectGroups)
    snapshot = try groupingDecision(.reorderProjects(projectIDs: [a.id, alias.id, b.id, other.id], expectedOrder: snapshot.projects.map(\.id)), snapshot)
    #expect(snapshot.orderedProjectGroups.first?.key == group.key)
    snapshot = try groupingDecision(.setProjectSortMode(.updatedAt), snapshot)
    #expect(snapshot.orderedProjectGroups.first?.memberProjectIDs == [other.id])
    #expect(snapshot.projects.map(\.id) == [a.id, alias.id, b.id, other.id])
}

@Test func groupPreferencesValidateExactMembershipPersistCheckoutAndNeverRetargetConversationState() throws {
    let a = try groupedProject("/tmp/group-prefs/a"), b = try groupedProject("/tmp/group-prefs/b")
    var thread = CodingThread(project: a); thread.draft = "Keep this draft"; thread.workspacePath = "/tmp/group-prefs/user-worktree"
    var snapshot = WorkspaceSnapshot(); snapshot.projects = [a, b]; snapshot.threads = [thread]
    let group = try #require(snapshot.projectGroups.first)
    for expected in [[a.id], [a.id, b.id, b.id], [a.id, UUID()], []] {
        #expect(throws: WorkspaceCommandError.self) { try groupingDecision(.setProjectGroupExpanded(groupKey: group.key, expectedProjectIDs: expected, expanded: false), snapshot) }
        #expect(throws: WorkspaceCommandError.self) { try groupingDecision(.setProjectGroupCheckout(groupKey: group.key, expectedProjectIDs: expected, projectID: b.id), snapshot) }
    }
    snapshot = try groupingDecision(.setProjectGroupExpanded(groupKey: group.key, expectedProjectIDs: [b.id, a.id], expanded: false), snapshot)
    snapshot = try groupingDecision(.setProjectGroupCheckout(groupKey: group.key, expectedProjectIDs: group.memberProjectIDs, projectID: b.id), snapshot)
    #expect(!snapshot.isProjectGroupExpanded(group.key) && !snapshot.isProjectExpanded(a.id) && !snapshot.isProjectExpanded(b.id))
    #expect(snapshot.effectiveSidebarPreferences.activeProjectByGroup[group.key] == b.id)
    #expect(snapshot.threads == [thread])
    let stored = try JSONDecoder().decode(WorkspaceSnapshot.self, from: JSONEncoder().encode(snapshot))
    #expect(stored == snapshot && stored.effectiveSidebarPreferences.activeProjectByGroup[group.key] == b.id)
    snapshot = try groupingDecision(.renameProject(projectID: b.id, title: "Only B"), snapshot)
    #expect(snapshot.projects[0].name == a.name && snapshot.projects[1].name == "Only B")
    snapshot = try groupingDecision(.removeProject(projectID: b.id, expectedThreadIDs: []), snapshot)
    #expect(snapshot.projects == [a] && snapshot.threads == [thread] && snapshot.effectiveSidebarPreferences.activeProjectByGroup.isEmpty)
    #expect(snapshot.effectiveSidebarPreferences.groupExpandedByKey[group.key] == false)
    snapshot = try groupingDecision(.setProjectGroupingMode(.separate), snapshot)
    #expect(snapshot.effectiveSidebarPreferences.groupExpandedByKey.isEmpty)
    var invalid = snapshot; invalid.sidebarPreferences?.groupingOverrides["unknown"] = .separate
    #expect(throws: (any Error).self) { try WorkspaceJournal.validate(invalid) }
    invalid = snapshot; invalid.sidebarPreferences?.activeProjectByGroup["unknown"] = a.id
    #expect(throws: (any Error).self) { try WorkspaceJournal.validate(invalid) }
}

@Test func groupedReorderingRejectsMetadataRegroupingDespiteUnchangedPhysicalProjectOrder() throws {
    let a = try groupedProject("/tmp/group-reorder/a"), b = try groupedProject("/tmp/group-reorder/b")
    let other = try groupedProject("/tmp/group-reorder/other", remote: "https://github.com/Team/Other.git")
    var snapshot = WorkspaceSnapshot(); snapshot.projects = [a, other, b]; snapshot.sidebarPreferences = .init(sortMode: .manual)
    let expected = Dictionary(uniqueKeysWithValues: snapshot.projectGroups.map { ($0.key, $0.memberProjectIDs) })
    let command = WorkspaceCommand.reorderProjectGroups(projectIDs: [other.id, a.id, b.id], expectedOrder: snapshot.projects.map(\.id), expectedGroups: expected)
    #expect(try groupingDecision(command, snapshot).projects.map(\.id) == [other.id, a.id, b.id])
    snapshot = try groupingDecision(.setProjectGroupingOverride(projectID: b.id, mode: .separate), snapshot)
    #expect(snapshot.projects.map(\.id) == [a.id, other.id, b.id])
    #expect(throws: WorkspaceCommandError.self) { try groupingDecision(command, snapshot) }
    var duplicated = expected; let key = try #require(snapshot.projectGroups.first?.key)
    duplicated[key] = [a.id, a.id]
    #expect(throws: WorkspaceCommandError.self) { try groupingDecision(.reorderProjectGroups(projectIDs: snapshot.projects.map(\.id), expectedOrder: snapshot.projects.map(\.id), expectedGroups: duplicated), snapshot) }
}

@Test func groupingLegacyDecodeAndStorageNineMigrationPreserveOldMetadataAndRejectFutureStores() async throws {
    let root = try temporaryWorkspace(); defer { try? FileManager.default.removeItem(at: root) }
    let project = WorkspaceProject(path: root.path), thread = CodingThread(project: project)
    var legacy = WorkspaceSnapshot(); legacy.projects = [project]; legacy.threads = [thread]
    legacy.sidebarPreferences = .init(sortMode: .manual, collapsedProjectIDs: [project.id])
    var object = try #require(JSONSerialization.jsonObject(with: JSONEncoder().encode(legacy)) as? [String: Any])
    var preferences = try #require(object["sidebarPreferences"] as? [String: Any])
    for key in ["groupingMode", "groupingOverrides", "groupExpandedByKey", "activeProjectByGroup"] { preferences.removeValue(forKey: key) }
    object["sidebarPreferences"] = preferences
    let payload = try JSONSerialization.data(withJSONObject: object), url = root.appendingPathComponent("legacy.sqlite")
    let decoded = try JSONDecoder().decode(WorkspaceSnapshot.self, from: payload)
    #expect(decoded == legacy && decoded.projects[0].repositoryIdentity == nil && decoded.effectiveSidebarPreferences.groupingMode == .repository)
    var connection: OpaquePointer?
    #expect(sqlite3_open(url.path, &connection) == SQLITE_OK)
    defer { sqlite3_close(connection) }
    #expect(sqlite3_exec(connection, "CREATE TABLE workspace(id INTEGER PRIMARY KEY,payload BLOB NOT NULL); PRAGMA user_version=8;", nil, nil, nil) == SQLITE_OK)
    var statement: OpaquePointer?
    #expect(sqlite3_prepare_v2(connection, "INSERT INTO workspace(id,payload) VALUES(1,?)", -1, &statement, nil) == SQLITE_OK)
    _ = payload.withUnsafeBytes { sqlite3_bind_blob(statement, 1, $0.baseAddress, Int32($0.count), unsafeBitCast(-1, to: sqlite3_destructor_type.self)) }
    #expect(sqlite3_step(statement) == SQLITE_DONE); sqlite3_finalize(statement)
    let database = try WorkspaceDatabase(url: url)
    #expect(try await database.load() == legacy)
    #expect(sqlite3_prepare_v2(connection, "PRAGMA user_version", -1, &statement, nil) == SQLITE_OK)
    #expect(sqlite3_step(statement) == SQLITE_ROW && sqlite3_column_int(statement, 0) == 35); sqlite3_finalize(statement)
    var changed = legacy
    changed.projects[0] = try groupedProject(root.path)
    changed.projects[0].id = project.id; changed.projects[0].createdAt = project.createdAt; changed.projects[0].updatedAt = project.updatedAt
    changed = try groupingDecision(.setProjectGroupingMode(.repositoryPath), changed)
    let group = try #require(changed.projectGroups.first)
    changed = try groupingDecision(.setProjectGroupCheckout(groupKey: group.key, expectedProjectIDs: group.memberProjectIDs, projectID: project.id), changed)
    _ = try await database.commit(changed, event: "grouping.fixture", commandID: UUID())
    #expect(try await database.rebuildProjection().snapshot == changed)
    #expect(try await WorkspaceDatabase(url: url).load() == changed)
    let future = root.appendingPathComponent("future.sqlite")
    var futureConnection: OpaquePointer?; #expect(sqlite3_open(future.path, &futureConnection) == SQLITE_OK)
    #expect(sqlite3_exec(futureConnection, "PRAGMA user_version=36", nil, nil, nil) == SQLITE_OK); sqlite3_close(futureConnection)
    #expect(throws: (any Error).self) { try WorkspaceDatabase(url: future) }
}

@Test func conversationSelectionPersistsArchivedTargetsAndPrunesOnlyRemovedOwnersWithoutRuntimeOrOutboxChanges() async throws {
    let root = try temporaryWorkspace(); defer { try? FileManager.default.removeItem(at: root) }
    let a = WorkspaceProject(path: root.appendingPathComponent("a").path), b = WorkspaceProject(path: root.appendingPathComponent("b").path)
    var active = CodingThread(project: a), archived = CodingThread(project: b)
    active.draft = "Keep drafting"; active.runtimeID = UUID(); active.activeRun = .init(id: UUID(), configuration: .init(thread: active), startedAt: Date()); active.state = .running
    archived.isArchived = true
    var snapshot = WorkspaceSnapshot(); snapshot.projects = [a, b]; snapshot.threads = [active, archived]
    let decision = try WorkspaceDecision.make(.client(.selectConversation(threadID: archived.id)), id: UUID(), snapshot: snapshot, now: Date())
    #expect(decision.snapshot.effectiveSidebarPreferences.selectedThreadID == archived.id)
    #expect(decision.snapshot.threads == snapshot.threads && decision.effects.isEmpty && decision.closeRuntimes.isEmpty)
    #expect(throws: WorkspaceCommandError.self) { try groupingDecision(.selectConversation(threadID: UUID()), snapshot) }
    let database = try WorkspaceDatabase(url: root.appendingPathComponent("selection.sqlite"))
    _ = try await database.commit(decision.snapshot, event: "selection.fixture", commandID: UUID())
    #expect(try await database.rebuildProjection().snapshot == decision.snapshot)
    #expect(try await WorkspaceDatabase(url: root.appendingPathComponent("selection.sqlite")).load().effectiveSidebarPreferences.selectedThreadID == archived.id)
    #expect(try await database.effects().isEmpty)
    var invalid = decision.snapshot; invalid.sidebarPreferences?.selectedThreadID = UUID()
    #expect(throws: (any Error).self) { try WorkspaceJournal.validate(invalid) }
    let removedOther = try groupingDecision(.removeProject(projectID: a.id, expectedThreadIDs: [active.id]), decision.snapshot)
    #expect(removedOther.effectiveSidebarPreferences.selectedThreadID == archived.id)
    let removedOwner = try groupingDecision(.removeProject(projectID: b.id, expectedThreadIDs: [archived.id]), decision.snapshot)
    #expect(removedOwner.effectiveSidebarPreferences.selectedThreadID == nil)
    let cleared = try groupingDecision(.selectConversation(threadID: nil), decision.snapshot)
    #expect(cleared.effectiveSidebarPreferences.selectedThreadID == nil && cleared.threads == snapshot.threads)
}
