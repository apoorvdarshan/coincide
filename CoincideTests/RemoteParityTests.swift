import CoincideRemoteKit
import Foundation
import Testing

@testable import Coincide
@testable import CoincideKit

/// The Mac tools Coincide Remote gained for parity: forking, "Edit from Here", the sidebar's sorting, project defaults
/// and removal, scheduled tasks, git and pull requests, and the usage-limit banner. Each runs on a scratch store (and
/// a scratch git repository where git is involved), through the adapter and the wire protocol.
@MainActor
struct RemoteParityTests {
    struct Fixture {
        let folders: [TemporaryDirectory]
        let store: AppStore
        let adapter: RemoteStoreAdapter
        let project: Project
    }

    private func fixture(_ name: String, services: ((inout RemoteStoreAdapter.Services) -> Void)? = nil, repository: URL? = nil) -> Fixture {
        let data = TemporaryDirectory(name)
        let store = AppStore(directory: data.url)
        let registry = ProviderRegistry(store: store, providers: [])
        let runner = ThreadRunner(store: store, registry: registry)
        var live = RemoteSessionTests.services(store: store)
        services?(&live)
        let adapter = RemoteStoreAdapter(store: store, runner: runner, registry: registry, services: live)
        let project = store.addProject(at: repository ?? data.url)
        return Fixture(folders: [data], store: store, adapter: adapter, project: project)
    }

    private func roundTrip(_ request: RemoteRequest) throws -> RemoteRequest {
        let data = try RemoteProtocol.makeEncoder().encode(RemoteClientMessage(id: "1", request: request))
        return try RemoteProtocol.makeDecoder().decode(RemoteClientMessage.self, from: data).request
    }

    private func roundTrip(_ result: RemoteResult) throws -> RemoteResult? {
        let data = try RemoteProtocol.makeEncoder().encode(RemoteServerMessage.response(id: "1", result: result))
        guard case .response(_, let decoded) = try RemoteProtocol.makeDecoder().decode(RemoteServerMessage.self, from: data) else {
            return nil
        }
        return decoded
    }

    // MARK: Protocol

    @Test func everyNewRequestAndResultCrossesTheWireUnchanged() throws {
        let thread = UUID()
        let project = UUID()
        // Dates cross in whole milliseconds.
        let day = Date(timeIntervalSince1970: 1_800_000_000)
        let requests: [RemoteRequest] = [
            .forkThread(RemoteForkRequest(threadID: thread, itemID: UUID())), .forkThread(RemoteForkRequest(threadID: thread)),
            .rewindOptions(RemoteItemReference(threadID: thread, itemID: UUID())),
            .rewind(RemoteRewindRequest(threadID: thread, itemID: UUID(), revertsFiles: true)), .composerNotice(threadID: thread),
            .usageWarningAction(RemoteUsageWarningCommand(threadID: thread, key: "k", action: .resumeAtReset)),
            .setSidebarOptions(RemoteSidebarOptions(projectSort: "name", threadsPerProject: 20)), .projectDefaults(projectID: project),
            .saveProjectDefaults(RemoteProjectDefaults(projectID: project, usesGlobalDefaults: false, provider: "claude", modelID: "opus")),
            .removeProject(projectID: project), .scheduledTasks,
            .saveScheduledTask(RemoteScheduledTaskDraft(name: "N", projectID: project, prompt: "P", recurrence: RemoteTaskRecurrence(date: day))),
            .scheduledTaskAction(RemoteScheduledTaskCommand(taskID: UUID(), action: .runNow)), .gitState(threadID: thread),
            .gitAction(RemoteGitActionRequest(threadID: thread, action: .commitPush, message: "Fix", featureBranch: true)),
            .pullRequests(RemotePullRequestQuery(projectID: project, filter: "mine")),
            .pullRequest(RemotePullRequestReference(projectID: project, number: 7)),
            .pullRequestAction(RemotePullRequestCommand(projectID: project, number: 7, action: .merge, method: "squash")),
        ]
        for request in requests { #expect(try roundTrip(request) == request, "\(request.name)") }

        let pullRequest = RemotePullRequest(number: 7, title: "T", url: "https://x", checks: .failing, review: .approved)
        let results: [RemoteResult] = [
            .rewindOptions(RemoteRewindOptions(canRevertFiles: true)), .rewind(RemoteRewind(text: "Hi", attachments: ["a.png"])),
            .composerNotice(RemoteComposerNotice(usageWarning: RemoteUsageWarning(key: "k", text: "t", fraction: 0.9))),
            .projectDefaults(RemoteProjectDefaults(projectID: project, usesGlobalDefaults: true, provider: "codex", modelID: "gpt")),
            .scheduledTasks(RemoteScheduledTasks(tasks: [
                RemoteScheduledTask(id: UUID(), name: "N", projectID: project, prompt: "P", recurrence: RemoteTaskRecurrence(kind: .weekly, date: day))
            ])),
            .gitState(RemoteGitState(isRepository: true, branch: "main", pullRequest: pullRequest, confirmsOnDefaultBranch: ["push"])),
            .gitAction(RemoteGitActionResult(title: "Pushed", url: "https://x")), .pullRequests(RemotePullRequestList(items: [pullRequest])),
            .pullRequest(RemotePullRequestDetail(pullRequest: pullRequest, checks: [.init(name: "CI", status: "success")])),
        ]
        for result in results { #expect(try roundTrip(result) == result, "\(result)") }
    }

    @Test func modelsFromAnotherVersionStillDecode() throws {
        let decoder = RemoteProtocol.makeDecoder()
        // An older Mac's workspace has no sidebar options; the phone keeps its own limit then.
        let workspace = try decoder.decode(RemoteWorkspace.self, from: Data(#"{"projects":[],"threads":[],"providers":[],"sections":[],"pinnedOrder":[]}"#.utf8))
        #expect(workspace.sidebar == nil)
        #expect(RemoteLayout.threadLimit(threadsPerProject: workspace.sidebar?.threadsPerProject, fitting: 6) == 6)
        #expect(RemoteLayout.threadLimit(threadsPerProject: 20, fitting: 6) == 20)
        #expect(RemoteLayout.threadLimit(threadsPerProject: 0, fitting: 6) == nil)

        // A newer Mac's schedule kind, state and extra fields read as unknown; a task that can't decode is left out.
        let project = UUID()
        let tasks = """
            {"tasks":[
              {"id":"\(UUID())","name":"Hourly","projectID":"\(project)","prompt":"P","recurrence":{"kind":"hourly","every":2},
               "isPaused":false,"state":"snoozed","stateText":"Snoozed","scheduleText":"Every 2 hours","canRunNow":true,
               "targetThreadID":"\(UUID())","agent":{"provider":"claude"}},
              {"name":"Broken"}
            ]}
            """
        let decoded = try decoder.decode(RemoteScheduledTasks.self, from: Data(tasks.utf8))
        #expect(decoded.tasks.count == 1)
        #expect(decoded.tasks[0].recurrence.kind == .unknown)
        #expect(decoded.tasks[0].state == .unknown)
        #expect(decoded.tasks[0].scheduleText == "Every 2 hours")
        // Actions and git states a newer peer adds read as unknown instead of failing.
        let command = try decoder.decode(RemoteScheduledTaskCommand.self, from: Data(#"{"taskID":"\#(UUID())","action":"skipNext"}"#.utf8))
        #expect(command.action == .unknown)
        let state = try decoder.decode(RemotePullRequest.self, from: Data(#"{"number":1,"title":"T","url":"u","headBranch":"h","baseBranch":"b","state":"queued","isDraft":false}"#.utf8))
        #expect(state.state == .unknown)
    }

    // MARK: Fork and Edit from Here

    @Test func thePhoneForksAThreadWithoutOpeningItOnTheMac() throws {
        let fixture = fixture("remote-fork")
        let store = fixture.store
        let thread = store.createThread(in: fixture.project.id)
        store.updateThread(thread.id) { $0.title = "Plan the trip" }
        store.append(TranscriptItem(kind: .user, text: "Where to?"), to: thread.id)
        let reply = store.append(TranscriptItem(kind: .assistant, text: "Lisbon."), to: thread.id)
        store.append(TranscriptItem(kind: .user, text: "And then?"), to: thread.id)
        store.append(TranscriptItem(kind: .assistant, text: "Porto."), to: thread.id)

        let whole = try fixture.adapter.forkThread(RemoteForkRequest(threadID: thread.id))
        #expect(store.summary(whole)?.projectID == fixture.project.id)
        #expect(store.thread(whole)?.items.map(\.text) == ["Where to?", "Lisbon.", "And then?", "Porto."])
        // Through a reply: the conversation up to that turn.
        let partial = try fixture.adapter.forkThread(RemoteForkRequest(threadID: thread.id, itemID: reply))
        #expect(store.thread(partial)?.items.map(\.text) == ["Where to?", "Lisbon."])

        let empty = store.createThread(in: fixture.project.id)
        #expect(throws: RemoteError.self) { try fixture.adapter.forkThread(RemoteForkRequest(threadID: empty.id)) }
    }

    @Test func editFromHereRewindsAndReturnsTheMessage() async throws {
        let restored = RestoreLog()
        let fixture = fixture("remote-rewind") { services in
            services.canRestore = { _, _ in true }
            services.restore = { thread, item in restored.calls.append((thread, item)) }
        }
        let store = fixture.store
        let thread = store.createThread(in: fixture.project.id)
        store.append(TranscriptItem(kind: .user, text: "Make it blue"), to: thread.id)
        store.append(TranscriptItem(kind: .assistant, text: "Done."), to: thread.id)
        let second = store.append(TranscriptItem(kind: .user, text: "Now green", attachments: ["/tmp/shot.png"]), to: thread.id)
        let reply = store.append(TranscriptItem(kind: .assistant, text: "Green."), to: thread.id)

        let options = try fixture.adapter.rewindOptions(RemoteItemReference(threadID: thread.id, itemID: second))
        #expect(options.canRevertFiles)
        #expect(!options.isRunning)
        // Only the user's messages rewind.
        #expect(throws: RemoteError.self) { try fixture.adapter.rewindOptions(RemoteItemReference(threadID: thread.id, itemID: reply)) }

        let rewind = try await fixture.adapter.rewind(RemoteRewindRequest(threadID: thread.id, itemID: second, revertsFiles: true))
        #expect(rewind == RemoteRewind(text: "Now green", attachments: ["shot.png"]))
        #expect(restored.calls.count == 1)
        #expect(restored.calls.first?.0 == thread.id && restored.calls.first?.1 == second)
        #expect(store.thread(thread.id)?.items.map(\.text) == ["Make it blue", "Done."])
    }

    @Test func revertingFilesThatCantBeRestoredLeavesTheConversation() async throws {
        let fixture = fixture("remote-rewind-refused")
        let store = fixture.store
        let thread = store.createThread(in: fixture.project.id)
        let message = store.append(TranscriptItem(kind: .user, text: "Hi"), to: thread.id)
        #expect(try fixture.adapter.rewindOptions(RemoteItemReference(threadID: thread.id, itemID: message)).canRevertFiles == false)
        await #expect(throws: RemoteError.self) {
            try await fixture.adapter.rewind(RemoteRewindRequest(threadID: thread.id, itemID: message, revertsFiles: true))
        }
        #expect(store.thread(thread.id)?.items.count == 1)
    }

    // MARK: Sidebar and projects

    @Test func theSidebarsSortingAndLimitFollowThePhone() throws {
        let saved = LayoutLog()
        let fixture = fixture("remote-sidebar") { services in
            services.layout = { saved.layout }
            services.updateLayout = { saved.layout = $0 }
        }
        #expect(fixture.adapter.workspace().sidebar == RemoteSidebarOptions(botSort: "manual"))
        try fixture.adapter.setSidebarOptions(
            RemoteSidebarOptions(projectSort: "name", threadSort: "created", chatSort: "name", botSort: "recentActivity", threadsPerProject: 20))
        #expect(saved.layout.projectSort == .name && saved.layout.threadSort == .created && saved.layout.chatSort == .name)
        #expect(saved.layout.botSort == .recentActivity && saved.layout.threadsPerProject == 20)
        #expect(fixture.adapter.workspace().sidebar?.threadsPerProject == 20)
        // A sort this Mac doesn't know changes nothing.
        #expect(throws: RemoteError.self) { try fixture.adapter.setSidebarOptions(RemoteSidebarOptions(projectSort: "stars")) }
        #expect(saved.layout.projectSort == .name)
    }

    @Test func projectDefaultsAndRemovalWorkAsOnTheMac() throws {
        let fixture = fixture("remote-project")
        let store = fixture.store
        let project = fixture.project
        let defaults = try fixture.adapter.projectDefaults(project.id)
        #expect(defaults.usesGlobalDefaults)

        let saved = try fixture.adapter.saveProjectDefaults(
            RemoteProjectDefaults(
                projectID: project.id, usesGlobalDefaults: false, provider: "codex", modelID: "gpt-5", accessMode: "fullAccess",
                interactionMode: "plan"))
        #expect(!saved.usesGlobalDefaults)
        #expect(store.project(project.id)?.threadDefaults?.selection.provider == .codex)
        #expect(store.project(project.id)?.threadDefaults?.selection.modelID == "gpt-5")
        #expect(store.project(project.id)?.threadDefaults?.accessMode == .fullAccess)
        #expect(store.project(project.id)?.threadDefaults?.interactionMode == .plan)
        #expect(throws: RemoteError.self) {
            try fixture.adapter.saveProjectDefaults(
                RemoteProjectDefaults(projectID: project.id, usesGlobalDefaults: false, provider: "nobody", modelID: "x"))
        }
        _ = try fixture.adapter.saveProjectDefaults(
            RemoteProjectDefaults(projectID: project.id, usesGlobalDefaults: true, provider: "codex", modelID: "gpt-5"))
        #expect(store.project(project.id)?.threadDefaults == nil)
        // Chats has no defaults of its own and can't be removed.
        let chats = store.ensureChatsProject()
        #expect(throws: RemoteError.self) { try fixture.adapter.projectDefaults(chats.id) }
        #expect(throws: RemoteError.self) { try fixture.adapter.removeProject(chats.id) }

        let thread = store.createThread(in: project.id)
        try fixture.adapter.removeProject(project.id)
        #expect(store.project(project.id) == nil)
        #expect(store.summary(thread.id) == nil)
    }

    // MARK: Scheduled tasks

    @Test func thePhoneCreatesPausesAndDeletesScheduledTasks() throws {
        let fixture = fixture("remote-schedules")
        let adapter = fixture.adapter
        #expect(adapter.scheduledTasks().tasks.isEmpty)
        let tomorrow = Date().addingTimeInterval(86_400)
        var list = try adapter.saveScheduledTask(
            RemoteScheduledTaskDraft(
                name: "  Morning check  ", projectID: fixture.project.id, prompt: "Check the build.",
                recurrence: RemoteTaskRecurrence(kind: .daily, date: tomorrow, hour: 9, minute: 30)))
        let task = try #require(list.tasks.first)
        #expect(task.name == "Morning check")
        #expect(task.recurrence.kind == .daily && task.recurrence.hour == 9 && task.recurrence.minute == 30)
        #expect(task.state == .scheduled)
        #expect(task.nextRunAt != nil)
        #expect(task.canRunNow)

        list = try adapter.perform(RemoteScheduledTaskCommand(taskID: task.id, action: .pause))
        #expect(list.tasks.first?.isPaused == true)
        #expect(list.tasks.first?.state == .paused)
        list = try adapter.perform(RemoteScheduledTaskCommand(taskID: task.id, action: .resume))
        #expect(list.tasks.first?.isPaused == false)

        // Editing without a schedule keeps the task's own (one whose kind the phone doesn't know).
        list = try adapter.saveScheduledTask(
            RemoteScheduledTaskDraft(id: task.id, name: "Evening check", projectID: fixture.project.id, prompt: "Check.", recurrence: nil))
        #expect(list.tasks.first?.name == "Evening check")
        #expect(list.tasks.first?.recurrence.hour == 9)
        // A new task needs a schedule, a project and a name; a one-time task can't be in the past.
        #expect(throws: RemoteError.self) {
            try adapter.saveScheduledTask(RemoteScheduledTaskDraft(name: "N", projectID: fixture.project.id, prompt: "P", recurrence: nil))
        }
        #expect(throws: RemoteError.self) {
            try adapter.saveScheduledTask(RemoteScheduledTaskDraft(name: "N", projectID: UUID(), prompt: "P", recurrence: RemoteTaskRecurrence()))
        }
        #expect(throws: RemoteError.self) {
            try adapter.saveScheduledTask(
                RemoteScheduledTaskDraft(
                    name: "N", projectID: fixture.project.id, prompt: "P",
                    recurrence: RemoteTaskRecurrence(kind: .once, date: Date().addingTimeInterval(-86_400 * 2), hour: 0)))
        }

        list = try adapter.perform(RemoteScheduledTaskCommand(taskID: task.id, action: .delete))
        #expect(list.tasks.isEmpty)
        #expect(throws: RemoteError.self) { try adapter.perform(RemoteScheduledTaskCommand(taskID: task.id, action: .pause)) }
    }

    // MARK: Git

    private func git(_ arguments: [String], in directory: URL) throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/git")
        process.arguments = ["-c", "user.name=Test", "-c", "user.email=test@example.com", "-c", "commit.gpgsign=false"] + arguments
        process.currentDirectoryURL = directory
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        try process.run()
        process.waitUntilExit()
        #expect(process.terminationStatus == 0, "git \(arguments.joined(separator: " ")) failed")
    }

    @Test func thePhoneSeesAFoldersGitStateAndCommits() async throws {
        let repository = TemporaryDirectory("remote-git-repo")
        try git(["init", "-q", "-b", "main"], in: repository.url)
        try git(["config", "user.name", "Test"], in: repository.url)
        try git(["config", "user.email", "test@example.com"], in: repository.url)
        try git(["config", "commit.gpgsign", "false"], in: repository.url)
        try git(["commit", "-q", "--allow-empty", "-m", "First"], in: repository.url)
        try "hello\n".write(to: repository.url.appendingPathComponent("README.md"), atomically: true, encoding: .utf8)
        let fixture = fixture("remote-git", repository: repository.url)
        defer { _ = repository }
        let thread = fixture.store.createThread(in: fixture.project.id)

        let state = try await fixture.adapter.gitState(thread.id)
        #expect(state.isRepository)
        #expect(state.branch == "main")
        #expect(state.changedFiles == 1)
        #expect(state.canCommit)
        // No remote: nothing to push, pull or open a pull request for.
        #expect(!state.hasRemote && !state.canPush && !state.canPull && !state.canCreatePullRequest)

        let result = try await fixture.adapter.gitAction(RemoteGitActionRequest(threadID: thread.id, action: .commit, message: "Add a readme"))
        #expect(!result.title.isEmpty)
        let after = try await fixture.adapter.gitState(thread.id)
        #expect(after.changedFiles == 0)
        #expect(!after.canCommit)

        let pullRequests = try await fixture.adapter.pullRequests(RemotePullRequestQuery(projectID: fixture.project.id))
        #expect(pullRequests.items.isEmpty)
        #expect(pullRequests.unavailable != nil)
    }

    @Test func aFolderOutsideGitHasNoActions() async throws {
        let fixture = fixture("remote-git-none")
        let thread = fixture.store.createThread(in: fixture.project.id)
        #expect(try await fixture.adapter.gitState(thread.id) == RemoteGitState(isRepository: false))
    }

    // MARK: Usage banner

    @Test func noLimitsMeanNoBanner() throws {
        let fixture = fixture("remote-usage-banner")
        let thread = fixture.store.createThread(in: fixture.project.id)
        #expect(try fixture.adapter.composerNotice(thread.id) == RemoteComposerNotice())
        #expect(throws: RemoteError.self) {
            try fixture.adapter.perform(RemoteUsageWarningCommand(threadID: thread.id, key: "k", action: .resumeAtReset))
        }
        #expect(throws: RemoteError.self) { try fixture.adapter.composerNotice(UUID()) }
    }

    // MARK: Session

    @Test func aPairedPhoneReachesTheToolsThroughTheSession() throws {
        let fixture = fixture("remote-parity-session")
        let transport = FakeTransport()
        let pairing = RemotePairing(storage: MemoryRemoteDeviceStorage())
        let session = RemoteSession(transport: transport, adapter: fixture.adapter, pairing: pairing) {
            RemoteServerInfo(serverID: "server", name: "Mac", appVersion: "1")
        }
        session.start()
        func send(_ request: RemoteRequest, id: String) throws {
            session.receive(try RemoteProtocol.makeEncoder().encode(RemoteClientMessage(id: id, request: request)))
        }
        // Before pairing, the tools are out of reach.
        try send(.scheduledTasks, id: "early")
        #expect(transport.error("early")?.code == .unauthorized)

        let paired = FakeTransport()
        let second = RemoteSession(transport: paired, adapter: fixture.adapter, pairing: pairing) {
            RemoteServerInfo(serverID: "server", name: "Mac", appVersion: "1")
        }
        second.start()
        second.receive(try RemoteProtocol.makeEncoder().encode(
            RemoteClientMessage(id: "auth", request: .pair(RemotePairRequest(secret: pairing.makeSecret().value, deviceName: "P")))))
        let thread = fixture.store.createThread(in: fixture.project.id)
        fixture.store.append(TranscriptItem(kind: .user, text: "Hi"), to: thread.id)
        fixture.store.append(TranscriptItem(kind: .assistant, text: "Hello"), to: thread.id)
        second.receive(try RemoteProtocol.makeEncoder().encode(
            RemoteClientMessage(id: "fork", request: .forkThread(RemoteForkRequest(threadID: thread.id)))))
        guard case .thread(let fork)? = paired.result("fork") else {
            Issue.record("No fork")
            return
        }
        #expect(fixture.store.summary(fork) != nil)
        second.receive(try RemoteProtocol.makeEncoder().encode(RemoteClientMessage(id: "tasks", request: .scheduledTasks)))
        #expect(paired.result("tasks") == .scheduledTasks(RemoteScheduledTasks()))
    }
}

@MainActor
private final class RestoreLog {
    var calls: [(UUID, UUID)] = []
}

@MainActor
private final class LayoutLog {
    var layout = RemoteStoreAdapter.Services.Layout()
}
