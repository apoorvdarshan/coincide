import Foundation
import Testing
@testable import CoincideCore

private func organizationDate(_ value: Double) -> Date { Date(timeIntervalSince1970: value) }
private func organizationProject(_ name: String, id: UUID = UUID(), created: Double? = nil, updated: Double? = nil) -> WorkspaceProject {
    var project = WorkspaceProject(path: "/tmp/coincide-project-organization/" + id.uuidString)
    project.id = id; project.name = name
    project.createdAt = created.map(organizationDate); project.updatedAt = updated.map(organizationDate)
    return project
}
private func organizationMessage(_ role: MessageRole, at timestamp: Double) -> ChatMessage {
    var message = ChatMessage(role: role, text: role.rawValue); message.createdAt = organizationDate(timestamp); return message
}
private func organizationThread(_ project: WorkspaceProject, created: Double, updated: Double, messages: [ChatMessage] = [], archived: Bool = false) -> CodingThread {
    var thread = CodingThread(project: project)
    thread.createdAt = organizationDate(created); thread.updatedAt = organizationDate(updated); thread.messages = messages; thread.isArchived = archived
    return thread
}
private func organizationOrder(_ snapshot: WorkspaceSnapshot, mode: ProjectSortMode = .updatedAt) -> [UUID] {
    var copy = snapshot
    var preferences = copy.effectiveSidebarPreferences; preferences.sortMode = mode; copy.sidebarPreferences = preferences
    return copy.orderedProjects.map(\.id)
}

@Test func projectActivityUsesLatestUserMessageWithoutMovingForAssistantStreamingOrMetadata() {
    let first = organizationProject("First"), second = organizationProject("Second")
    var snapshot = WorkspaceSnapshot(); snapshot.projects = [first, second]
    snapshot.threads = [
        organizationThread(first, created: 10, updated: 1_000, messages: [organizationMessage(.user, at: 100), organizationMessage(.assistant, at: 1_000)]),
        organizationThread(second, created: 20, updated: 200, messages: [organizationMessage(.user, at: 200)])
    ]
    #expect(organizationOrder(snapshot) == [second.id, first.id])
    for role in [MessageRole.assistant, .tool, .reasoning, .system] {
        snapshot.threads[0].messages.append(organizationMessage(role, at: 20_000))
        snapshot.threads[0].updatedAt = organizationDate(30_000)
        #expect(organizationOrder(snapshot) == [second.id, first.id])
    }
    // User history may arrive out of chronological order; the last array element is not the score.
    snapshot.threads[0].messages += [organizationMessage(.user, at: 300), organizationMessage(.user, at: 50)]
    #expect(organizationOrder(snapshot) == [first.id, second.id])
    #expect(snapshot.projects.map(\.id) == [first.id, second.id])
}

@Test func projectActivityNewEmptyThreadsUseUpdatedThenCreatedWhileUserDatesStayAuthoritative() {
    let first = organizationProject("User History"), second = organizationProject("New Conversation")
    var snapshot = WorkspaceSnapshot(); snapshot.projects = [first, second]
    snapshot.threads = [
        organizationThread(first, created: 100, updated: 900, messages: [organizationMessage(.user, at: 200)]),
        organizationThread(second, created: 100, updated: 150)
    ]
    #expect(organizationOrder(snapshot) == [first.id, second.id])
    snapshot.threads.append(organizationThread(second, created: 300, updated: 300))
    #expect(organizationOrder(snapshot) == [second.id, first.id])
    snapshot.threads[2].updatedAt = organizationDate(.nan)
    #expect(organizationOrder(snapshot) == [second.id, first.id]) // Finite creation fallback.
    snapshot.threads[2].messages = [organizationMessage(.user, at: 100), organizationMessage(.assistant, at: 9_000)]
    snapshot.threads[2].updatedAt = organizationDate(10_000)
    #expect(organizationOrder(snapshot) == [first.id, second.id]) // User history suppresses newer metadata.
}

@Test func projectActivityIncludesAcceptedQueuedTurnsAndRemovalRestoresExistingUserHistoryOrder() {
    let first = organizationProject("Queued"), second = organizationProject("Existing history")
    var snapshot = WorkspaceSnapshot(); snapshot.projects = [first, second]
    snapshot.threads = [
        organizationThread(first, created: 10, updated: 50_000, messages: [organizationMessage(.user, at: 100), organizationMessage(.assistant, at: 40_000)]),
        organizationThread(second, created: 20, updated: 200, messages: [organizationMessage(.user, at: 200)])
    ]
    #expect(organizationOrder(snapshot) == [second.id, first.id])
    let configuration = ProviderConfiguration(thread: snapshot.threads[0])
    snapshot.threads[0].queuedTurns = [
        .init(id: UUID(), text: "Accepted newer input", configuration: configuration, createdAt: organizationDate(300)),
        .init(id: UUID(), text: "Older accepted input", configuration: configuration, createdAt: organizationDate(150))
    ]
    #expect(organizationOrder(snapshot) == [first.id, second.id])
    // Newest sorts by project creation; undated projects keep their saved order.
    #expect(organizationOrder(snapshot, mode: .createdAt) == [first.id, second.id])
    snapshot.threads[0].updatedAt = organizationDate(90_000)
    snapshot.threads[0].messages.append(organizationMessage(.assistant, at: 80_000))
    #expect(organizationOrder(snapshot) == [first.id, second.id])
    snapshot.threads[0].queuedTurns.removeAll()
    #expect(organizationOrder(snapshot) == [second.id, first.id])
    snapshot.threads[0].queuedTurns = [
        .init(id: UUID(), text: "Invalid timestamp", configuration: configuration, createdAt: organizationDate(.nan)),
        .init(id: UUID(), text: "Earlier than executed history", configuration: configuration, createdAt: organizationDate(50))
    ]
    #expect(organizationOrder(snapshot) == [second.id, first.id])
    #expect(snapshot.threads[0].messages.filter { $0.role == .user }.count == 1)
    #expect(snapshot.projects.map(\.id) == [first.id, second.id])
}

@Test func projectNewestSortUsesProjectCreationAndIgnoresThreadActivity() {
    let first = organizationProject("First", created: 1_000, updated: 2_000), second = organizationProject("Second", created: 2_000, updated: 3_000)
    var snapshot = WorkspaceSnapshot(); snapshot.projects = [first, second]
    snapshot.threads = [
        organizationThread(first, created: 10, updated: 99_999, messages: [organizationMessage(.user, at: 90_000)]),
        organizationThread(second, created: 20, updated: 20, messages: [organizationMessage(.user, at: 20)])
    ]
    #expect(organizationOrder(snapshot, mode: .createdAt) == [second.id, first.id])
    snapshot.threads.append(organizationThread(first, created: 30, updated: 30))
    #expect(organizationOrder(snapshot, mode: .createdAt) == [second.id, first.id])
    snapshot.threads[2].isArchived = true
    #expect(organizationOrder(snapshot, mode: .createdAt) == [second.id, first.id])
}

@Test func projectActivityOrderingExcludesArchivedThreadsAndNewestIgnoresThem() {
    let first = organizationProject("Archived Activity"), second = organizationProject("Active")
    var snapshot = WorkspaceSnapshot(); snapshot.projects = [first, second]
    snapshot.threads = [
        organizationThread(first, created: 100, updated: 100, messages: [organizationMessage(.user, at: 100)]),
        organizationThread(first, created: 99_999, updated: 99_999, messages: [organizationMessage(.user, at: 99_999)], archived: true),
        organizationThread(second, created: 200, updated: 200, messages: [organizationMessage(.user, at: 200)])
    ]
    #expect(organizationOrder(snapshot) == [second.id, first.id])
    #expect(organizationOrder(snapshot, mode: .createdAt) == [first.id, second.id])
    snapshot.threads[1].isArchived = false
    for mode in [ProjectSortMode.updatedAt, .createdAt] { #expect(organizationOrder(snapshot, mode: mode) == [first.id, second.id]) }
}

@Test func projectOrderingUsesProjectDateFallbackOnlyWithoutEligibleThreadsAndKeepsUnknownManualOrder() {
    let legacyZulu = organizationProject("Zulu"), legacyAlpha = organizationProject("Alpha")
    let createdNewer = organizationProject("Creation Newer", created: 100, updated: 10)
    let updatedNewer = organizationProject("Activity Newer", created: 20, updated: 30)
    let distant = organizationProject("Old dated project", created: -100)
    var snapshot = WorkspaceSnapshot(); snapshot.projects = [legacyZulu, createdNewer, legacyAlpha, updatedNewer, distant]
    #expect(organizationOrder(snapshot) == [updatedNewer.id, createdNewer.id, distant.id, legacyZulu.id, legacyAlpha.id])
    #expect(organizationOrder(snapshot, mode: .createdAt) == [createdNewer.id, updatedNewer.id, distant.id, legacyZulu.id, legacyAlpha.id])
    snapshot.threads = [organizationThread(legacyZulu, created: 9_000, updated: 9_000, archived: true)]
    #expect(organizationOrder(snapshot) == [updatedNewer.id, createdNewer.id, distant.id, legacyZulu.id, legacyAlpha.id])
    #expect(snapshot.projects.map(\.id) == [legacyZulu.id, createdNewer.id, legacyAlpha.id, updatedNewer.id, distant.id])
}

@Test func projectOrderingIgnoresAllNonfiniteDatesAndUsesFiniteFallbacks() {
    let unknown = organizationProject("Unknown", created: .nan, updated: .infinity)
    let projectFallback = organizationProject("Project Fallback", created: 250, updated: -.infinity)
    let threadFallback = organizationProject("Thread Fallback")
    let ordinary = organizationProject("Ordinary")
    var snapshot = WorkspaceSnapshot(); snapshot.projects = [unknown, ordinary, projectFallback, threadFallback]
    snapshot.threads = [
        organizationThread(threadFallback, created: 100, updated: 300, messages: [organizationMessage(.user, at: .nan), organizationMessage(.assistant, at: .infinity)]),
        organizationThread(ordinary, created: 200, updated: 200, messages: [organizationMessage(.user, at: 200)])
    ]
    #expect(organizationOrder(snapshot) == [threadFallback.id, projectFallback.id, ordinary.id, unknown.id])
    #expect(organizationOrder(snapshot, mode: .createdAt) == [projectFallback.id, unknown.id, ordinary.id, threadFallback.id])
    snapshot.threads[0].createdAt = organizationDate(.nan); snapshot.threads[0].updatedAt = organizationDate(.infinity)
    snapshot.projects[3].createdAt = organizationDate(50_000)
    // A present thread with no finite score does not invent activity from the project's fallback.
    #expect(organizationOrder(snapshot) == [projectFallback.id, ordinary.id, unknown.id, threadFallback.id])
    #expect(organizationOrder(snapshot, mode: .createdAt) == [threadFallback.id, projectFallback.id, unknown.id, ordinary.id])
}

@Test func projectDatedTiesUseLocalizedTitleThenStableUUIDWhileUnknownTiesKeepManualOrder() {
    let lowID = UUID(uuidString: "00000000-0000-0000-0000-000000000001")!, highID = UUID(uuidString: "00000000-0000-0000-0000-000000000002")!
    let sameHigh = organizationProject("Same title", id: highID, created: 100), sameLow = organizationProject("Same title", id: lowID, created: 100)
    let alpha = organizationProject("Alpha", created: 100), zulu = organizationProject("Zulu", created: 100)
    let unknownZulu = organizationProject("Zulu unknown"), unknownAlpha = organizationProject("Alpha unknown")
    var snapshot = WorkspaceSnapshot(); snapshot.projects = [unknownZulu, zulu, sameHigh, unknownAlpha, sameLow, alpha]
    let expected = [alpha.id, lowID, highID, zulu.id, unknownZulu.id, unknownAlpha.id]
    #expect(organizationOrder(snapshot) == expected)
    #expect(organizationOrder(snapshot, mode: .createdAt) == expected)
    snapshot.projects = [sameHigh, sameLow, zulu, alpha, unknownZulu, unknownAlpha]
    #expect(organizationOrder(snapshot) == expected)
}

@Test func projectManualModeReturnsExactCanonicalOrderWithoutMutatingAutomaticOrder() {
    let first = organizationProject("Zulu", created: 100), second = organizationProject("Alpha", created: 900)
    var snapshot = WorkspaceSnapshot(); snapshot.projects = [first, second]
    #expect(organizationOrder(snapshot) == [second.id, first.id])
    #expect(organizationOrder(snapshot, mode: .manual) == [first.id, second.id])
    #expect(snapshot.projects == [first, second])
    snapshot.projects.reverse()
    #expect(organizationOrder(snapshot, mode: .manual) == [second.id, first.id])
    #expect(organizationOrder(snapshot) == [second.id, first.id])
}

@Test func projectOrganizationLegacyCodableLeavesMissingDatesAndPreferencesAbsent() throws {
    let id = UUID()
    let legacy: [String: Any] = [
        "schemaVersion": 1,
        "projects": [["id": id.uuidString, "name": "Legacy", "path": "/tmp/legacy-project"]],
        "threads": []
    ]
    let snapshot = try JSONDecoder().decode(WorkspaceSnapshot.self, from: JSONSerialization.data(withJSONObject: legacy))
    #expect(snapshot.projects.count == 1 && snapshot.projects[0].createdAt == nil && snapshot.projects[0].updatedAt == nil)
    #expect(snapshot.sidebarPreferences == nil && snapshot.acpAgents.isEmpty)
    #expect(snapshot.effectiveSidebarPreferences == SidebarPreferences())
    #expect(snapshot.isProjectExpanded(id) && snapshot.orderedProjects.map(\.id) == [id])
    let encoded = try #require(JSONSerialization.jsonObject(with: JSONEncoder().encode(snapshot)) as? [String: Any])
    #expect(encoded["sidebarPreferences"] == nil)
    let projects = try #require(encoded["projects"] as? [[String: Any]])
    #expect(projects[0]["createdAt"] == nil && projects[0]["updatedAt"] == nil)
}

@Test func projectOrganizationPreferencesPersistSortAndCollapseAndDefaultToExpanded() throws {
    let first = organizationProject("First", created: 10, updated: 20), second = organizationProject("Second", created: 30, updated: 40)
    var snapshot = WorkspaceSnapshot(); snapshot.projects = [first, second]
    #expect(snapshot.effectiveSidebarPreferences.sortMode == .updatedAt)
    #expect(snapshot.isProjectExpanded(first.id) && snapshot.isProjectExpanded(second.id))
    snapshot.sidebarPreferences = .init(sortMode: .manual, collapsedProjectIDs: [first.id])
    try snapshot.effectiveSidebarPreferences.validate(projectIDs: [first.id, second.id])
    #expect(!snapshot.isProjectExpanded(first.id) && snapshot.isProjectExpanded(second.id))
    let recovered = try JSONDecoder().decode(WorkspaceSnapshot.self, from: JSONEncoder().encode(snapshot))
    #expect(recovered == snapshot && recovered.effectiveSidebarPreferences.sortMode == .manual)
    #expect(!recovered.isProjectExpanded(first.id))
    #expect(ProjectSortMode.allCases.map(\.rawValue) == ["updated_at", "created_at", "manual", "name", "priority"])
    #expect(ProjectSortMode.allCases.map(\.title) == ["Recently active", "Newest", "Custom", "Name", "Priority (pinned first)"])
    #expect(ProjectSortMode.allCases.map(\.id) == ProjectSortMode.allCases.map(\.rawValue))
}

@Test func projectOrganizationRejectsDuplicateOrUnknownCollapsedIDsAndUnknownSortValues() throws {
    let first = UUID(), second = UUID()
    try SidebarPreferences().validate(projectIDs: [])
    try SidebarPreferences(sortMode: .createdAt, collapsedProjectIDs: [first]).validate(projectIDs: [first, second])
    #expect(throws: (any Error).self) { try SidebarPreferences(collapsedProjectIDs: [first, first]).validate(projectIDs: [first]) }
    #expect(throws: (any Error).self) { try SidebarPreferences(collapsedProjectIDs: [second]).validate(projectIDs: [first]) }
    #expect(throws: (any Error).self) {
        _ = try JSONDecoder().decode(SidebarPreferences.self, from: Data(#"{"sortMode":"unknown","collapsedProjectIDs":[]}"#.utf8))
    }
}

@Test func newlyCreatedProjectTimestampsShareOneCreationInstantWithoutChangingLegacyDecoding() throws {
    let before = Date(), project = WorkspaceProject(path: "/tmp/coincide-new-timestamped-project"), after = Date()
    let created = try #require(project.createdAt), updated = try #require(project.updatedAt)
    #expect(created == updated && created >= before && created <= after)
    let decoded = try JSONDecoder().decode(WorkspaceProject.self, from: JSONEncoder().encode(project))
    #expect(decoded.createdAt == created && decoded.updatedAt == updated)
}
