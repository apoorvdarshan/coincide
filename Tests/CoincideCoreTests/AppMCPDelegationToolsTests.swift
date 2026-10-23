import Foundation
import Testing
@testable import CoincideCore

private actor DelegationToolProbe {
    let view: AppMCPView
    private(set) var reads = 0
    private(set) var actions: [AppMCPAction] = []
    private(set) var ceilings: [PermissionMode] = []
    var revoked = false
    init(view: AppMCPView) { self.view = view }
    func read() -> AppMCPView { reads += 1; return view }
    func revoke() { revoked = true }
    func perform(_ action: AppMCPAction, context: AppMCPContext) throws -> JSONValue {
        guard !revoked else { throw AppMCPError(.staleCaller) }
        actions.append(action); ceilings.append(context.scope.permission)
        return .object(["accepted": .bool(true), "permissionCeiling": .string(context.scope.permission.rawValue)])
    }
}
private struct DelegationToolFixture {
    let project: WorkspaceProject
    let thread: CodingThread
    let context: AppMCPContext
    init() {
        let project = WorkspaceProject(path: "/owned-offline-delegation-facade"); self.project = project
        var thread = CodingThread(project: project); thread.permission = .supervised; self.thread = thread
        context = .init(scope: .init(threadID: thread.id, projectID: project.id, provider: thread.provider, runtimeID: UUID(), incarnation: UUID(),
            providerInstanceID: CodexRuntimeConfiguration.defaultInstanceID, workspacePath: thread.workspacePath,
            permission: .supervised, capabilities: [.orchestration, .worktree]), runID: UUID(), configuration: .init(thread: thread))
    }
    var view: AppMCPView { var snapshot = WorkspaceSnapshot(); snapshot.projects = [project]; snapshot.threads = [thread]; return .init(snapshot: snapshot, sequence: 7) }
    func tools(_ probe: DelegationToolProbe, allowed: Set<String>? = nil) -> AppMCPTools {
        .init(client: .init(read: { _ in await probe.read() }, perform: { action, context in try await probe.perform(action, context: context) }), allowedToolNames: allowed)
    }
}

@Test func appMCPDelegationCatalogDeclaresAcknowledgingReadsAsWritesAndContextOnlyScopesNeverExposeDelegation() async throws {
    let fixture = DelegationToolFixture(), probe = DelegationToolProbe(view: DelegationToolFixture().view)
    let tools = fixture.tools(probe), names = Set(tools.descriptors.map(\.name))
    #expect(names.count == 36 && names.isSuperset(of: ["delegate_task", "task_status", "task_cancel"]))
    for name in ["delegate_task", "task_status", "task_cancel"] {
        let descriptor = try #require(tools.descriptors.first { $0.name == name }); try descriptor.validate()
        #expect(!descriptor.readOnly && descriptor.capability == .orchestration)
        #expect(descriptor.inputSchema["additionalProperties"] == .bool(false))
    }
    let scoped = fixture.tools(probe, allowed: ["t3_context_read"])
    #expect(scoped.descriptors.map(\.name) == ["t3_context_read"])
    for name in ["delegate_task", "task_status", "task_cancel"] {
        let denied = await scoped.call(name: name, arguments: .object(["task": .string("Read-only archive scope")]), context: fixture.context)
        #expect(denied.isError && denied.structuredContent?["code"] == .string("unsupported"))
    }
    let reads = await probe.reads, actions = await probe.actions
    #expect(reads == 0 && actions.isEmpty)
}

@Test func appMCPDelegationParserPreservesLiteralBriefClosedTargetDefaultsAndTheUnchangedCallerPermissionCeiling() async throws {
    let fixture = DelegationToolFixture()
    let owned = DelegationToolProbe(view: fixture.view), tools = fixture.tools(owned), instance = UUID()
    let literal = "  Literal 工作 e\u{301}\n$HOME /review is authored text  "
    let simple = await tools.call(name: "delegate_task", arguments: .object(["task": .string(literal)]), context: fixture.context)
    #expect(!simple.isError)
    let full = await tools.call(name: "delegate_task", arguments: .object(["task": .string(literal), "title": .string("Review round 工作"),
        "target": .object(["instanceId": .string(instance.uuidString), "driverKind": .string("claude"), "model": .string("exact-advertised-model"),
            "options": .array([.object(["id": .string("reasoningEffort"), "value": .string("high")]), .object(["id": .string("budget"), "value": .number(42)])])]),
        "runtimeMode": .string("full-access"), "interactionMode": .string("inherit"), "role": .string("review"), "isolation": .string("worktree"),
        "mode": .string("wait"), "timeoutMs": .number(3_600_000), "clientRequestId": .string("stable-review-round")]), context: fixture.context)
    #expect(!full.isError)
    let emptyOptions = await tools.call(name: "delegate_task", arguments: .object(["task": .string("Distinct next round"),
        "target": .object(["options": .object([:])]), "timeoutMs": .number(0)]), context: fixture.context)
    #expect(!emptyOptions.isError)
    let actions = await owned.actions, ceilings = await owned.ceilings
    #expect(actions == [.delegateTask(.init(task: literal)), .delegateTask(.init(task: literal, title: "Review round 工作",
        target: .init(instanceID: instance, provider: .claude, model: "exact-advertised-model", options: ["reasoningEffort": .string("high"), "budget": .number(42)]),
        permission: .fullAccess, role: .review, isolation: .worktree, mode: .wait, timeoutMilliseconds: 3_600_000, clientRequestID: "stable-review-round")),
        .delegateTask(.init(task: "Distinct next round", target: .init(options: [:]), timeoutMilliseconds: 0))])
    #expect(ceilings == [.supervised, .supervised, .supervised])
    #expect(full.structuredContent?["permissionCeiling"] == .string("supervised"))
}

@Test func appMCPDelegationParserRejectsUnknownFieldsTypesNonfiniteTimeoutsAndLaunchOrSecretFieldsWithoutPerforming() async throws {
    let fixture = DelegationToolFixture()
    let owned = DelegationToolProbe(view: fixture.view), tools = fixture.tools(owned)
    var invalid: [JSONValue] = [.object([:]), .array([])]
    for raw in [JSONValue.null, .bool(true), .number(1), .string(""), .string(" \n\t "), .string("before\0after"), .string(String(repeating: "x", count: 120_001))] {
        invalid.append(.object(["task": raw]))
    }
    for raw in [JSONValue.number(-1), .number(3_600_001), .number(1.5), .number(.infinity), .number(.nan), .string("1000"), .bool(true), .null] {
        invalid.append(.object(["task": .string("Brief"), "timeoutMs": raw]))
    }
    for (key, raw) in [("role", JSONValue.string("admin")), ("isolation", .string("arbitrary-path")), ("mode", .string("background")),
                       ("title", .bool(true)), ("target", .string("claude")), ("taskId", .string(UUID().uuidString)),
                       ("parentThreadId", .string(UUID().uuidString)), ("workspacePath", .string("/foreign")), ("environment", .object([:]))] {
        invalid.append(.object(["task": .string("Brief"), key: raw]))
    }
    for field in ["executable", "homeDirectory", "cwd", "token", "apiKey", "environment", "nativeThreadId"] {
        invalid.append(.object(["task": .string("Brief"), "target": .object([field: .string("PRIVATE-UNTRUSTED-INPUT-CANARY")])]))
    }
    for options in [JSONValue.null, .object(["effort": .object(["value": .string("high")])]),
                    .array([.object(["id": .string("effort"), "value": .string("high"), "token": .string("PRIVATE-UNTRUSTED-INPUT-CANARY")])]),
                    .array([.object(["id": .string("effort"), "value": .string("high")]), .object(["id": .string("effort"), "value": .string("low")])])] {
        invalid.append(.object(["task": .string("Brief"), "target": .object(["options": options])]))
    }
    for request in invalid {
        let result = await tools.call(name: "delegate_task", arguments: request, context: fixture.context)
        #expect(result.isError && result.structuredContent?["code"] == .string("invalid_request"))
        #expect(!result.content.joined().contains("PRIVATE-UNTRUSTED-INPUT-CANARY"))
    }
    let actions = await owned.actions; #expect(actions.isEmpty)
}

@Test func appMCPDelegationStatusAndCancellationCarryExactTaskAndRequestIDsWithNoImplicitNewDelegation() async throws {
    let fixture = DelegationToolFixture()
    let probe = DelegationToolProbe(view: fixture.view), tools = fixture.tools(probe), task = UUID()
    let status = await tools.call(name: "task_status", arguments: .object(["taskId": .string(task.uuidString)]), context: fixture.context)
    let cancel = await tools.call(name: "task_cancel", arguments: .object(["taskId": .string(task.uuidString), "reason": .string("  User stopped 工作\n"),
        "clientRequestId": .string("exact-cancel-request")]), context: fixture.context)
    #expect(!status.isError && !cancel.isError)
    for name in ["task_status", "task_cancel"] {
        for bad in [JSONValue.object([:]), .object(["taskId": .string("not-a-uuid")]), .object(["taskId": .number(7)]),
                    .object(["taskId": .string(task.uuidString), "threadId": .string(fixture.thread.id.uuidString)])] {
            let result = await tools.call(name: name, arguments: bad, context: fixture.context); #expect(result.isError)
        }
    }
    let actions = await probe.actions
    #expect(actions == [.delegatedTaskStatus(taskID: task), .cancelDelegatedTask(taskID: task, reason: "  User stopped 工作\n", clientRequestID: "exact-cancel-request")])
}

@Test func appMCPDelegationFacadeRequiresActiveScopedCallerAndHonorsRevocationBeforeMutation() async throws {
    let fixture = DelegationToolFixture()
    let owned = DelegationToolProbe(view: fixture.view), tools = fixture.tools(owned)
    let noRun = AppMCPContext(scope: fixture.context.scope, runID: nil, configuration: fixture.context.configuration)
    let limitedScope = MCPInvocationScope(threadID: fixture.thread.id, projectID: fixture.project.id, provider: fixture.thread.provider,
        runtimeID: fixture.context.scope.runtimeID, incarnation: fixture.context.scope.incarnation, providerInstanceID: fixture.context.scope.providerInstanceID,
        workspacePath: fixture.thread.workspacePath, permission: .supervised, capabilities: [.contextRead])
    let limited = AppMCPContext(scope: limitedScope, runID: fixture.context.runID, configuration: fixture.context.configuration)
    for (context, code) in [(noRun, "parent_not_active"), (limited, "capability_denied")] {
        for name in ["delegate_task", "task_status", "task_cancel"] {
            let result = await tools.call(name: name, arguments: .object(["task": .string("Brief")]), context: context)
            #expect(result.isError && result.structuredContent?["code"] == .string(code))
        }
    }
    #expect(await owned.reads == 0)
    await owned.revoke()
    let revoked = await tools.call(name: "delegate_task", arguments: .object(["task": .string("Brief")]), context: fixture.context)
    #expect(revoked.isError && revoked.structuredContent?["code"] == .string("parent_not_active"))
    let actions = await owned.actions; #expect(actions.isEmpty)
}
