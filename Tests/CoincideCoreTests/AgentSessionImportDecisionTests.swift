import Foundation
import Testing
@testable import CoincideCore

private struct AgentSessionImportDecisionFixture {
    let files: AgentSessionImportFixture
    let project: WorkspaceProject
    let admission: AgentSessionImportAdmission
    static func make(_ source: AgentSessionSource = .codex) async throws -> Self {
        let files = try AgentSessionImportFixture.make()
        do {
            _ = try files.install(source)
            let project = WorkspaceProject(path: files.workspace.path), scanner = try files.scanner()
            let page: AgentSessionImportPage
            do {
                let scan = try await scanner.scan()
                page = try await scanner.prepareImport(scanID: scan.id, projectID: project.id, expectedWorkspaceRoot: project.path)
            } catch { await scanner.close(); throw error }
            await scanner.close()
            let review = try #require(page.reviews.first)
            var configuration = review.profile.configuration
            configuration.workspacePath = project.path; configuration.nativeThreadID = review.transcript.providerSessionID
            configuration.model = review.transcript.model ?? ""
            if let runtime = configuration.claudeRuntimeConfiguration { configuration.claudeRuntimeConfiguration = try runtime.replacingWorkspace(project.path, physicalPath: project.path) }
            return .init(files: files, project: project, admission: .init(review: review, configuration: configuration, projectIncarnation: UUID()))
        } catch { files.cleanup(); throw error }
    }
    func initial() -> WorkspaceSnapshot { var snapshot = WorkspaceSnapshot(); snapshot.projects = [project]; return snapshot }
    func imported() throws -> WorkspaceSnapshot {
        var decision = WorkspaceDecision(snapshot: initial())
        try decision.acceptAgentSessionImport(admission, id: UUID(), now: files.now)
        return decision.snapshot
    }
}

@Test(arguments: AgentSessionSource.allCases) func agentSessionImportCopiesPublicHistoryAndPreservesSourceProvenanceWithoutBindingOrStartingTheOriginalSession(source: AgentSessionSource) async throws {
    let f = try await AgentSessionImportDecisionFixture.make(source); defer { f.files.cleanup() }
    let command = UUID(); var decision = WorkspaceDecision(snapshot: f.initial())
    try decision.acceptAgentSessionImport(f.admission, id: command, now: f.files.now)
    let thread = try #require(decision.snapshot.threads.first), record = try #require(decision.snapshot.agentSessionImports?.first)
    #expect(decision.effects.isEmpty && decision.closeRuntimes.isEmpty && thread.runtimeID == nil && thread.activeRun == nil)
    #expect(thread.providerThreadID == nil && thread.provider == source.provider)
    #expect(record.nativeSessionID == f.admission.review.transcript.providerSessionID)
    #expect(thread.messages.map(\.text) == f.admission.review.transcript.messages.map(\.text))
    #expect(thread.messages.allSatisfy { $0.runReference == nil && $0.providerEntity == nil && $0.attachments == nil })
    #expect(thread.runHistory == nil && thread.forkedFromHistoryOperationID == nil && thread.claudeInheritedHead == nil)
    #expect(thread.isSettled && thread.queuePaused && thread.settlement?.script == nil)
    #expect(record.lastCommandID == command && record.reviewDigest == f.admission.review.digest && !record.modified && !record.tombstoned)
    let pending = decision.snapshot.pendingContextTransfers(threadID: thread.id)
    #expect(pending.count == 1)
    let transfer = try #require(pending.first)
    #expect(transfer.status == .pending && transfer.delivery == nil && transfer.targetRunID == nil)
    #expect(transfer.review.strategy == .portableContext && transfer.review.targetThreadID == thread.id)
    #expect(transfer.review.sourceConfiguration.nativeThreadID == record.nativeSessionID)
    #expect(transfer.review.targetConfiguration.nativeThreadID == nil)
    #expect(transfer.review.messages.map(\.text) == thread.messages.map(\.text))
    let previous = decision.snapshot
    try decision.acceptAgentSessionImport(f.admission, id: UUID(), now: f.files.now)
    try decision.snapshot.reconcileAgentSessionImports(previous: previous)
    #expect(decision.snapshot.threads.count == 1 && decision.snapshot.threads.first == thread)
    #expect(decision.snapshot.pendingContextTransfers(threadID: thread.id).count == 1)
    #expect(decision.effects.isEmpty && decision.closeRuntimes.isEmpty)
    try WorkspaceJournal.validate(decision.snapshot)
    try decision.snapshot.validateAgentSessionImports()
}

@Test func agentSessionAdoptionStickyModificationAndDeletionPreventOverwriteEvenAfterUserReverts() async throws {
    let f = try await AgentSessionImportDecisionFixture.make(); defer { f.files.cleanup() }
    let imported = try f.imported(); var edited = imported
    edited.threads[0].title = "A user-owned rename"
    try edited.reconcileAgentSessionImports(previous: imported)
    #expect(edited.agentSessionImports?.first?.modified == true)
    let changed = edited; edited.threads[0].title = imported.threads[0].title
    try edited.reconcileAgentSessionImports(previous: changed)
    var refused = WorkspaceDecision(snapshot: edited)
    #expect(throws: WorkspaceCommandError.self) { try refused.acceptAgentSessionImport(f.admission, id: UUID(), now: f.files.now) }
    #expect(refused.snapshot.threads == edited.threads)
    var deleted = imported; deleted.threads = []; deleted.projects = []
    try deleted.reconcileAgentSessionImports(previous: imported)
    #expect(deleted.agentSessionImports?.first?.tombstoned == true)
    try deleted.validateAgentSessionImports()
    deleted.projects = [f.project]; var readded = WorkspaceDecision(snapshot: deleted)
    #expect(throws: WorkspaceCommandError.self) { try readded.acceptAgentSessionImport(f.admission, id: UUID(), now: f.files.now) }
    var archived = imported; archived.threads[0].isArchived = true
    try archived.reconcileAgentSessionImports(previous: imported)
    #expect(archived.agentSessionImports?.first?.tombstoned == true)
}

@Test(arguments: ["current", "archived", "historical", "physical-profile-alias"]) func agentSessionAdoptionRefusesNativeSessionOwnedByAnotherConversationIncludingSavedBindings(kind: String) async throws {
    let f = try await AgentSessionImportDecisionFixture.make(); defer { f.files.cleanup() }
    var snapshot = f.initial(), owner = CodingThread(project: f.project)
    owner.applyContextConfiguration(f.admission.configuration)
    if kind == "archived" { owner.isArchived = true }
    if kind == "historical" {
        var record = ThreadRunRecord(run: .init(id: UUID(), configuration: f.admission.configuration, startedAt: f.files.now), origin: .legacy)
        record.status = .completed; record.endedAt = f.files.now; owner.runHistory = [record]; owner.providerThreadID = "different-live-native-ID"
    }
    if kind == "physical-profile-alias" {
        let captured = try #require(owner.codexRuntimeConfiguration)
        owner.codexRuntimeConfiguration = .init(instanceID: UUID(), selection: captured.selection, executable: captured.executable, homeDirectory: captured.homeDirectory)
    }
    snapshot.threads = [owner]; var decision = WorkspaceDecision(snapshot: snapshot)
    #expect(throws: WorkspaceCommandError.self) { try decision.acceptAgentSessionImport(f.admission, id: UUID(), now: f.files.now) }
    #expect(decision.snapshot == snapshot && decision.effects.isEmpty)
}

@Test func agentSessionAdoptionRejectsRetargetedProjectOrProviderBeforeChangingSnapshot() async throws {
    let f = try await AgentSessionImportDecisionFixture.make(); defer { f.files.cleanup() }
    var moved = f.initial(); moved.projects[0].path = f.files.root.path
    var first = WorkspaceDecision(snapshot: moved)
    #expect(throws: WorkspaceCommandError.self) { try first.acceptAgentSessionImport(f.admission, id: UUID(), now: f.files.now) }
    var foreign = f.admission.configuration; foreign.nativeThreadID = "another-native-session"
    let bad = AgentSessionImportAdmission(review: f.admission.review, configuration: foreign, projectIncarnation: f.admission.projectIncarnation)
    var second = WorkspaceDecision(snapshot: f.initial())
    #expect(throws: WorkspaceCommandError.self) { try second.acceptAgentSessionImport(bad, id: UUID(), now: f.files.now) }
    #expect(first.snapshot == moved && second.snapshot == f.initial())
}

@Test(arguments: ["current", "active", "queued", "historical", "saved-provider-binding", "captured-nil-home", "explicit-other-home"])
func agentSessionAdoptionUncapturedCodexHomeCannotBeReinterpretedAsAnIsolatedNativeSession(binding: String) async throws {
    let f = try await AgentSessionImportDecisionFixture.make(); defer { f.files.cleanup() }
    var snapshot = f.initial(), owner = CodingThread(project: f.project)
    var unknown = f.admission.configuration
    unknown.codexRuntimeConfiguration = nil
    owner.providerThreadID = "different-current-native-session"
    switch binding {
    case "current": owner.applyContextConfiguration(unknown)
    case "active":
        owner.activeRun = .init(id: UUID(), configuration: unknown, startedAt: f.files.now); owner.state = .running
    case "queued": owner.queuedTurns = [.init(id: UUID(), text: "Preserved authored input", configuration: unknown, createdAt: f.files.now)]
    case "historical":
        var run = ThreadRunRecord(run: .init(id: UUID(), configuration: unknown, startedAt: f.files.now), origin: .legacy)
        run.status = .completed; run.endedAt = f.files.now; owner.runHistory = [run]
    case "saved-provider-binding": owner.contextProviderBindings = [.init(configuration: unknown, knownItemIDs: [], updatedAt: f.files.now)]
    case "captured-nil-home":
        unknown.codexRuntimeConfiguration = .init(instanceID: UUID()); owner.applyContextConfiguration(unknown)
    case "explicit-other-home":
        unknown.codexRuntimeConfiguration = .init(instanceID: UUID(), homeDirectory: f.files.root.appendingPathComponent("ExplicitOtherHome").path)
        owner.applyContextConfiguration(unknown)
    default: Issue.record("Unknown controlled native ownership capture")
    }
    snapshot.threads = [owner]; var decision = WorkspaceDecision(snapshot: snapshot)
    if binding == "explicit-other-home" {
        try decision.acceptAgentSessionImport(f.admission, id: UUID(), now: f.files.now)
        #expect(decision.snapshot.threads.count == 2 && decision.effects.isEmpty)
    } else {
        #expect(throws: WorkspaceCommandError.self) { try decision.acceptAgentSessionImport(f.admission, id: UUID(), now: f.files.now) }
        #expect(decision.snapshot == snapshot && decision.effects.isEmpty)
    }
}
