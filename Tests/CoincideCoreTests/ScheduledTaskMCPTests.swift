import Foundation
import Testing
@testable import CoincideCore

private struct ScheduledToolFixture {
    let project: WorkspaceProject
    let thread: CodingThread
    let context: AppMCPContext
    init() {
        let project = WorkspaceProject(path: "/private-offline-schedule-parser")
        var thread = CodingThread(project: project); thread.permission = .fullAccess
        self.project = project; self.thread = thread
        context = .init(scope: .init(threadID: thread.id, projectID: project.id, provider: thread.provider, runtimeID: UUID(), incarnation: UUID(),
            providerInstanceID: CodexRuntimeConfiguration.defaultInstanceID, workspacePath: thread.workspacePath, permission: thread.permission, capabilities: [.orchestration]),
            runID: UUID(), configuration: .init(thread: thread))
    }
    var view: AppMCPView { var snapshot = WorkspaceSnapshot(); snapshot.projects = [project]; snapshot.threads = [thread]; return .init(snapshot: snapshot, sequence: 1) }
    func tools(_ probe: ScheduledToolProbe) -> AppMCPTools {
        .init(client: .init(read: { _ in await probe.read() }, perform: { action, _ in await probe.perform(action) }))
    }
}
private actor ScheduledToolProbe {
    private let view: AppMCPView
    private(set) var actions: [AppMCPAction] = []
    init(view: AppMCPView) { self.view = view }
    func read() -> AppMCPView { view }
    func perform(_ action: AppMCPAction) -> JSONValue { actions.append(action); return .object(["accepted": .bool(true)]) }
}

@Test func scheduledTaskMCPToolsRequireStructuredTriggersOriginalIDsAndDoNotExposeWebhookCredentialsOrContextOnlyWrites() async throws {
    let fixture = ScheduledToolFixture(), probe = ScheduledToolProbe(view: fixture.view)
    let tools = fixture.tools(probe)
    let names: Set<String> = ["schedule_task", "list_scheduled_tasks", "update_scheduled_task", "delete_scheduled_task", "run_scheduled_task_now", "acknowledge_scheduled_task_run"]
    #expect(names.isSubset(of: Set(tools.descriptors.map(\.name))))
    for descriptor in tools.descriptors where names.contains(descriptor.name) {
        try descriptor.validate()
        #expect(descriptor.readOnly == (descriptor.name == "list_scheduled_tasks"))
        let bytes = try JSONEncoder().encode(descriptor.inputSchema)
        #expect(bytes.range(of: Data("signingSecret".utf8)) == nil && bytes.range(of: Data("bearer".utf8)) == nil)
    }
    let scoped = AppMCPTools(client: .init(read: { _ in fixture.view }, perform: { _, _ in .null }), allowedToolNames: ["t3_context_read"])
    #expect(scoped.descriptors.map(\.name) == ["t3_context_read"])
    let denied = await scoped.call(name: "schedule_task", arguments: .object([:]), context: fixture.context)
    #expect(denied.isError)
    let before = await probe.actions
    for schedule in [JSONValue.string("{type:'interval'}"), .object(["type": .string("interval"), "everyMs": .number(1000)]), .object(["type": .string("webhook")])] {
        let result = await tools.call(name: "schedule_task", arguments: .object(["title": .string("Test"), "prompt": .string("No real execution"), "schedule": schedule, "commandId": .string(UUID().uuidString)]), context: fixture.context)
        #expect(result.isError)
    }
    let after = await probe.actions
    #expect(before == after)
}

@Test func scheduledTaskMCPParserPreservesOriginalCommandIDBoundDestinationAndLiteralPrompt() async throws {
    let fixture = ScheduledToolFixture(), probe = ScheduledToolProbe(view: fixture.view), id = UUID()
    let tools = fixture.tools(probe), prompt = "  Literal $skill /command 工作 e\u{301}\n"
    let result = await tools.call(name: "schedule_task", arguments: .object(["title": .string("Task"), "prompt": .string(prompt), "bindToCurrentThread": .bool(false),
        "schedule": .object(["type": .string("interval"), "everyMs": .number(60_000)]), "commandId": .string(id.uuidString)]), context: fixture.context)
    #expect(!result.isError)
    let actions = await probe.actions
    guard case .scheduledTask(.save(nil, nil, let title, let text, _, let schedule, let bound, let commandID)) = actions.last else { Issue.record("A typed scheduled action was not produced."); return }
    #expect(title == "Task" && text?.utf8.elementsEqual(prompt.utf8) == true && commandID == id && bound == false)
    #expect(schedule == .interval(everyMilliseconds: 60_000))
    let missingID = await tools.call(name: "run_scheduled_task_now", arguments: .object(["taskId": .string(UUID().uuidString)]), context: fixture.context)
    #expect(missingID.isError)
}
