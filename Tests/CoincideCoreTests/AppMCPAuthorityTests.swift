import Foundation
import Testing
@testable import CoincideCore

private struct MCPAuthorityFixture {
    var snapshot = WorkspaceSnapshot()
    let now = Date(timeIntervalSince1970: 1_790_000_000)
    let incarnation = UUID(), runtimeID = UUID(), instanceID = UUID(), sessionID = UUID()
    var caller: CodingThread { snapshot.threads[0] }
    var target: CodingThread { snapshot.threads[1] }
    var context: AppMCPContext {
        let run = caller.activeRun!
        return .init(scope: .init(sessionID: sessionID, threadID: caller.id, projectID: caller.projectID, provider: .codex,
            runtimeID: runtimeID, incarnation: incarnation, providerInstanceID: instanceID, workspacePath: caller.workspacePath,
            permission: run.configuration.permission, capabilities: [.orchestration, .worktree]), runID: run.id, configuration: run.configuration)
    }
    init(permission: PermissionMode = .supervised) throws {
        let project = WorkspaceProject(path: "/tmp/coincide-mcp-authority-fixture")
        var owner = CodingThread(project: project)
        owner.provider = .codex; owner.codexRuntimeConfiguration = .init(instanceID: instanceID); owner.permission = permission; owner.checkpointPolicy = .disabled
        var other = CodingThread(project: project); other.checkpointPolicy = .disabled
        snapshot.projects = [project]; snapshot.threads = [owner, other]
        snapshot = try WorkspaceDecision.make(.client(.submit(threadID: owner.id, text: "Owned native call")), id: UUID(), snapshot: snapshot, now: now).snapshot
        snapshot = try WorkspaceDecision.make(.runtimeOpened(threadID: owner.id, runID: caller.activeRun!.id, runtimeID: runtimeID), id: UUID(), snapshot: snapshot, now: now).snapshot
    }
    func newThread(title: String = "MCP child", permission: PermissionMode = .supervised) -> CodingThread {
        var thread = CodingThread(project: snapshot.projects[0]); thread.title = title; thread.checkpointPolicy = .disabled; thread.permission = permission
        thread.createdAt = now; thread.updatedAt = now
        thread.createdByAppMCP = .init(sessionID: sessionID, threadID: caller.id, runID: caller.activeRun!.id)
        return thread
    }
}

@Test func appMCPAuthorityRoundTripsOnlyNonsecretOwnerFieldsAndRejectsAbsentOrWrongCapturedRunContext() throws {
    let fixture = try MCPAuthorityFixture(), authority = try AppMCPCommandAuthority(context: fixture.context)
    let data = try JSONEncoder().encode(authority)
    #expect(try JSONDecoder().decode(AppMCPCommandAuthority.self, from: data) == authority)
    let json = try JSONDecoder().decode(JSONValue.self, from: data)
    #expect(Set(json.object!.keys) == Set(["sessionID", "threadID", "projectID", "runtimeID", "incarnation", "providerInstanceID", "workspacePath", "provider", "permission", "runID"]))
    let origin = AppMCPThreadOrigin(sessionID: authority.sessionID, threadID: authority.threadID, runID: authority.runID)
    #expect(try JSONDecoder().decode(AppMCPThreadOrigin.self, from: JSONEncoder().encode(origin)) == origin)
    #expect(throws: AppMCPError.self) { _ = try AppMCPCommandAuthority(context: .init(scope: fixture.context.scope, runID: nil, configuration: fixture.context.configuration)) }
    var changed = fixture.context.configuration; changed.permission = .fullAccess
    #expect(throws: AppMCPError.self) { _ = try AppMCPCommandAuthority(context: .init(scope: fixture.context.scope, runID: fixture.context.runID, configuration: changed)) }
    changed = fixture.context.configuration; changed.codexRuntimeConfiguration = .init(instanceID: UUID())
    #expect(throws: AppMCPError.self) { _ = try AppMCPCommandAuthority(context: .init(scope: fixture.context.scope, runID: fixture.context.runID, configuration: changed)) }
}

@Test(arguments: ["archived", "runtime", "provider", "path", "project", "run", "stopped", "instance", "capturedPermission"])
func appMCPAuthorityRejectsStaleCallerAtSnapshotCommitBoundary(fault: String) throws {
    var fixture = try MCPAuthorityFixture()
    let authority = try AppMCPCommandAuthority(context: fixture.context)
    switch fault {
    case "archived": fixture.snapshot.threads[0].isArchived = true
    case "runtime": fixture.snapshot.threads[0].runtimeID = UUID()
    case "provider": fixture.snapshot.threads[0].provider = .claude
    case "path": fixture.snapshot.threads[0].workspacePath += "/changed"
    case "project": fixture.snapshot.threads[0].projectID = UUID()
    case "run": fixture.snapshot.threads[0].activeRun!.id = UUID()
    case "stopped": fixture.snapshot.threads[0].activeRun!.stopRequested = true
    case "instance": fixture.snapshot.threads[0].activeRun!.configuration.codexRuntimeConfiguration = .init(instanceID: UUID())
    case "capturedPermission": fixture.snapshot.threads[0].activeRun!.configuration.permission = .fullAccess
    default: break
    }
    #expect(throws: WorkspaceCommandError.self) {
        try AppMCPAdmission.validate(authority: authority, snapshot: fixture.snapshot, commands: [.client(.editThread(fixture.target.id, .title("Changed")))])
    }
}

@Test func appMCPAuthorityKeepsIncomparableMiddleModesAndBothCapturedAndLiveCeilings() throws {
    for ceiling in PermissionMode.allCases {
        for target in PermissionMode.allCases {
            let allowed = target == .supervised || target == ceiling || ceiling == .fullAccess
            #expect(AppMCPAdmission.permits(target, ceiling: ceiling) == allowed)
        }
    }
    var raised = try MCPAuthorityFixture()
    let restricted = try AppMCPCommandAuthority(context: raised.context)
    raised.snapshot.threads[0].permission = .fullAccess
    raised.snapshot.threads[1].permission = .fullAccess
    #expect(throws: WorkspaceCommandError.self) {
        try AppMCPAdmission.validate(authority: restricted, snapshot: raised.snapshot, commands: [.client(.editThread(raised.target.id, .title("Cannot borrow a later raise")))])
    }
    raised.snapshot.threads[1].permission = .supervised
    raised.snapshot.threads[0].reasoningEffort = "high"
    raised.snapshot.threads[0].agentModeID = "future-model-choice"
    try AppMCPAdmission.validate(authority: restricted, snapshot: raised.snapshot, commands: [.client(.editThread(raised.target.id, .title("Allowed with original ceiling")))])
    var lowered = try MCPAuthorityFixture(permission: .fullAccess)
    let previouslyBroad = try AppMCPCommandAuthority(context: lowered.context)
    lowered.snapshot.threads[0].permission = .supervised; lowered.snapshot.threads[1].permission = .autoAcceptEdits
    #expect(throws: WorkspaceCommandError.self) {
        try AppMCPAdmission.validate(authority: previouslyBroad, snapshot: lowered.snapshot, commands: [.client(.interrupt(threadID: lowered.target.id))])
    }
}

@Test func appMCPAuthorityRefusesQueuedCapturedEscalationNewThreadEscalationAndForgedParentOrigin() throws {
    var fixture = try MCPAuthorityFixture(), queuedConfiguration = ProviderConfiguration(thread: try MCPAuthorityFixture().target)
    let authority = try AppMCPCommandAuthority(context: fixture.context)
    queuedConfiguration.permission = .fullAccess
    fixture.snapshot.threads[1].queuedTurns = [.init(id: UUID(), text: "future captured input", configuration: queuedConfiguration, createdAt: fixture.now)]
    #expect(throws: WorkspaceCommandError.self) {
        try AppMCPAdmission.validate(authority: authority, snapshot: fixture.snapshot, commands: [.client(.resumeQueue(threadID: fixture.target.id))])
    }
    #expect(throws: WorkspaceCommandError.self) {
        try AppMCPAdmission.validate(authority: authority, snapshot: fixture.snapshot, commands: [.client(.createThread(fixture.newThread(permission: .fullAccess)))])
    }
    var independent = fixture.newThread(); independent.createdByAppMCP = nil
    try AppMCPAdmission.validate(authority: authority, snapshot: fixture.snapshot, commands: [.client(.createThread(independent))])
    var forged = fixture.newThread(); forged.createdByAppMCP = .init(sessionID: UUID(), threadID: fixture.caller.id, runID: fixture.caller.activeRun!.id)
    #expect(throws: WorkspaceCommandError.self) { try AppMCPAdmission.validate(authority: authority, snapshot: fixture.snapshot, commands: [.client(.createThread(forged))]) }
    #expect(throws: WorkspaceCommandError.self) {
        try AppMCPAdmission.validate(authority: authority, snapshot: fixture.snapshot, commands: [.client(.editThread(fixture.target.id, .permission(.fullAccess)))])
    }
}

@Test func appMCPAuthorityBatchDerivesDistinctStableRunIDsAndPreservesDraftsAndOriginalRun() throws {
    var fixture = try MCPAuthorityFixture()
    fixture.snapshot.threads[0].draft = "human caller draft"
    let authority = try AppMCPCommandAuthority(context: fixture.context), first = fixture.newThread(title: "First"), second = fixture.newThread(title: "Second")
    let outer = UUID(), commands: [EngineCommand] = [.client(.createThread(first)), .client(.submitFromAppMCP(threadID: first.id, text: "  literal first\n", queueEvenWhenIdle: false)),
        .client(.createThread(second)), .client(.submitFromAppMCP(threadID: second.id, text: "第二 input", queueEvenWhenIdle: false))]
    let result = try AppMCPAdmission.reduce(authority: authority, commands: commands, id: outer, snapshot: fixture.snapshot, now: fixture.now)
    let replayed = try AppMCPAdmission.reduce(authority: authority, commands: commands, id: outer, snapshot: fixture.snapshot, now: fixture.now)
    let firstResult = try #require(result.snapshot.threads.first { $0.id == first.id }), secondResult = try #require(result.snapshot.threads.first { $0.id == second.id })
    #expect(firstResult.activeRun?.id == AppMCPAdmission.memberCommandID(parentID: outer, index: 1))
    #expect(secondResult.activeRun?.id == AppMCPAdmission.memberCommandID(parentID: outer, index: 3))
    #expect(firstResult.activeRun?.id != secondResult.activeRun?.id && firstResult.activeRun?.id != outer)
    #expect(firstResult.messages.first?.text == "  literal first\n" && secondResult.messages.first?.text == "第二 input")
    #expect(result.snapshot == replayed.snapshot && result.effects == replayed.effects)
    #expect(result.effects.count == 2 && Set(result.effects.map(\.id)).count == 2)
    let retainedCaller = try #require(result.snapshot.threads.first { $0.id == fixture.caller.id })
    #expect(retainedCaller == fixture.snapshot.threads[0] && retainedCaller.draft == "human caller draft")
    let singleton = try AppMCPAdmission.reduce(authority: authority,
        commands: [.client(.submitFromAppMCP(threadID: fixture.target.id, text: "singleton input", queueEvenWhenIdle: false))],
        id: outer, snapshot: fixture.snapshot, now: fixture.now)
    #expect(singleton.snapshot.threads.first { $0.id == fixture.target.id }?.activeRun?.id == outer)
    try WorkspaceJournal.validate(result.snapshot)
}

@Test func appMCPAuthorityBatchPublishesNothingWhenLateReducerFailsAndRejectsNestedOrProviderCommands() throws {
    let fixture = try MCPAuthorityFixture(), before = fixture.snapshot
    let authority = try AppMCPCommandAuthority(context: fixture.context), child = fixture.newThread()
    let commands: [EngineCommand] = [.client(.createThread(child)), .client(.submitFromAppMCP(threadID: child.id, text: "", queueEvenWhenIdle: false))]
    #expect(throws: WorkspaceCommandError.self) { _ = try AppMCPAdmission.reduce(authority: authority, commands: commands, id: UUID(), snapshot: fixture.snapshot, now: fixture.now) }
    #expect(fixture.snapshot == before)
    #expect(throws: WorkspaceCommandError.self) {
        try AppMCPAdmission.validate(authority: authority, snapshot: fixture.snapshot, commands: [.appMCP(authority: authority, commands: [.client(.interrupt(threadID: fixture.target.id))])])
    }
    #expect(throws: WorkspaceCommandError.self) {
        try AppMCPAdmission.validate(authority: authority, snapshot: fixture.snapshot, commands: [.provider(threadID: fixture.caller.id, runtimeID: fixture.runtimeID, event: .completed(.idle))])
    }
}

@Test func appMCPAuthorityCannotAnswerItsOwnPermissionGrantAsQuestion() throws {
    var fixture = try MCPAuthorityFixture()
    let authority = try AppMCPCommandAuthority(context: fixture.context), requestID = JSONValue.string("owned-permission")
    fixture.snapshot.threads[1].runtimeRequests = [.init(request: .init(id: requestID, method: "item/commandExecution/requestApproval", params: .object([:]))) ]
    #expect(throws: WorkspaceCommandError.self) {
        try AppMCPAdmission.validate(authority: authority, snapshot: fixture.snapshot, commands: [.client(.respond(threadID: fixture.target.id, requestID: requestID, response: .decision(true)))])
    }
}

@Test func appMCPAuthorityCommandIdentityIsDomainSeparatedAndTaskLocalValueNeverContainsCredential() async throws {
    let fixture = try MCPAuthorityFixture(), authority = try AppMCPCommandAuthority(context: fixture.context)
    let first = try AppMCPAdmission.commandID(sessionID: authority.sessionID, clientRequestID: "ab", action: "c")
    #expect(try AppMCPAdmission.commandID(sessionID: authority.sessionID, clientRequestID: "ab", action: "c") == first)
    #expect(try AppMCPAdmission.commandID(sessionID: authority.sessionID, clientRequestID: "a", action: "bc") != first)
    #expect(try AppMCPAdmission.commandID(sessionID: UUID(), clientRequestID: "ab", action: "c") != first)
    #expect(throws: AppMCPError.self) { _ = try AppMCPAdmission.commandID(sessionID: authority.sessionID, clientRequestID: "", action: "send") }
    #expect(AppMCPTaskContext.authority == nil)
    let inherited = await AppMCPTaskContext.$authority.withValue(authority) { await Task { AppMCPTaskContext.authority }.value }
    #expect(inherited == authority && AppMCPTaskContext.authority == nil)
}
