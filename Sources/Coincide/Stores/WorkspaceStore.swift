import AppKit
import CoincideCore
import Observation

@MainActor @Observable
final class WorkspaceStore {
    var snapshot = WorkspaceSnapshot()
    var selectedThreadID: UUID?
    var selectedProjectID: UUID?
    var search = ""
    var showArchived = false
    var errorMessage: String?
    var providerModels: [ProviderKind: [ProviderModel]] = [:]
    var approvals: [UUID: [ApprovalRequest]] = [:]
    var isLoading = true
    var isRefreshingModels = false
    var inspectorVisible = false
    private var database: WorkspaceDatabase?
    private var sessions: [UUID: any ProviderSession] = [:]
    private var eventTasks: [UUID: Task<Void, Never>] = [:]
    private var writeTask: Task<Void, any Error>?
    private var draftSaveTask: Task<Void, Never>?

    init() {
        do {
            let root = try FileManager.default.url(for: .applicationSupportDirectory, in: .userDomainMask, appropriateFor: nil, create: true)
                .appendingPathComponent("Coincide", isDirectory: true)
            database = try WorkspaceDatabase(url: root.appendingPathComponent("workspace.sqlite"))
        } catch { errorMessage = error.localizedDescription }
    }
    var selectedThread: CodingThread? { snapshot.threads.first { $0.id == selectedThreadID } }
    var selectedProject: WorkspaceProject? {
        let id = selectedThread?.projectID ?? selectedProjectID
        return snapshot.projects.first { $0.id == id }
    }
    var visibleThreads: [CodingThread] {
        snapshot.threads.filter {
            $0.isArchived == showArchived && (search.isEmpty || $0.title.localizedCaseInsensitiveContains(search) || $0.messages.contains { $0.text.localizedCaseInsensitiveContains(search) })
        }.sorted { $0.isPinned != $1.isPinned ? $0.isPinned : $0.updatedAt > $1.updatedAt }
    }
    func load() async {
        guard isLoading else { return }
        defer { isLoading = false }
        do {
            guard let database else { return }
            snapshot = try await database.load(); snapshot.recoverInterruptedWork()
            selectedProjectID = snapshot.projects.first?.id
            selectedThreadID = snapshot.threads.first(where: { !$0.isArchived })?.id
            try await persist("workspace.opened")
        } catch { errorMessage = error.localizedDescription }
    }
    func addProject() {
        let panel = NSOpenPanel(); panel.canChooseDirectories = true; panel.canChooseFiles = false
        panel.allowsMultipleSelection = false; panel.prompt = "Add Project"
        panel.begin { [weak self] response in
            guard response == .OK, let url = panel.url else { return }
            self?.addProject(at: url)
        }
    }
    func addProject(at url: URL) {
        var directory: ObjCBool = false
        guard url.isFileURL, FileManager.default.fileExists(atPath: url.path, isDirectory: &directory), directory.boolValue else {
            errorMessage = "Choose an existing project folder."; return
        }
        let project = WorkspaceProject(path: url.path)
        if let existing = snapshot.projects.first(where: { $0.path == project.path }) { selectedProjectID = existing.id; return }
        snapshot.projects.append(project); selectedProjectID = project.id
        Task { await save("project.added") }
    }
    func newThread(projectID: UUID? = nil) {
        guard let project = snapshot.projects.first(where: { $0.id == (projectID ?? selectedProjectID ?? selectedProject?.id) }) ?? snapshot.projects.first else {
            addProject(); return
        }
        let thread = CodingThread(project: project)
        snapshot.threads.insert(thread, at: 0); selectedThreadID = thread.id; selectedProjectID = project.id; showArchived = false
        Task { await save("thread.created") }
    }
    func updateThread(_ id: UUID, _ mutate: (inout CodingThread) -> Void) {
        guard let i = snapshot.threads.firstIndex(where: { $0.id == id }) else { return }
        mutate(&snapshot.threads[i]); snapshot.threads[i].updatedAt = Date()
    }
    func setModel(_ model: String, id: UUID) {
        updateThread(id) { $0.model = model }; Task { await save("thread.model") }
    }
    func setProvider(_ provider: ProviderKind, id: UUID) {
        guard let thread = snapshot.threads.first(where: { $0.id == id }), thread.messages.isEmpty else {
            errorMessage = "Start a new thread to use a different provider."; return
        }
        updateThread(id) { $0.provider = provider; $0.model = ""; $0.providerThreadID = nil }
        Task { await save("thread.provider") }
    }
    func models(for provider: ProviderKind) -> [ProviderModel] { providerModels[provider] ?? [] }
    func setDraft(_ text: String, id: UUID) {
        guard let i = snapshot.threads.firstIndex(where: { $0.id == id }) else { return }
        snapshot.threads[i].draft = text
        draftSaveTask?.cancel()
        draftSaveTask = Task { [weak self] in
            do { try await Task.sleep(for: .milliseconds(350)) } catch { return }
            await self?.save("thread.draft")
        }
    }
    func setPermission(_ mode: PermissionMode, id: UUID) {
        updateThread(id) { $0.permission = mode }; Task { await save("thread.permissions") }
    }
    func togglePin(_ id: UUID) { updateThread(id) { $0.isPinned.toggle() }; Task { await save("thread.pin") } }
    func toggleArchive(_ id: UUID) {
        guard !isBusy(id) else { errorMessage = "Stop the running turn before archiving this thread."; return }
        updateThread(id) { $0.isArchived.toggle() }; Task { await save("thread.archive") }
    }
    func rename(_ id: UUID, title: String) {
        let value = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.isEmpty else { return }; updateThread(id) { $0.title = value }; Task { await save("thread.renamed") }
    }
    func isBusy(_ id: UUID) -> Bool {
        guard let thread = snapshot.threads.first(where: { $0.id == id }) else { return false }
        return thread.state == .running || thread.state == .awaitingApproval
    }
    func send(_ text: String, threadID id: UUID) async -> Bool {
        let prompt = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !prompt.isEmpty, !isBusy(id), let thread = snapshot.threads.first(where: { $0.id == id }) else { return false }
        guard ProcessChannel.findExecutable(thread.provider.executable) != nil else {
            errorMessage = "Install and sign in to \(thread.provider.name) CLI before sending a message."; return false
        }
        updateThread(id) {
            if $0.messages.isEmpty { $0.title = String(prompt.prefix(80)) }
            $0.messages.append(.init(role: .user, text: prompt)); $0.state = .running
            if $0.draft == text { $0.draft = "" }
        }
        do {
            // Durable intent comes before a provider process is allowed to act.
            try await persist("turn.requested")
            let session: any ProviderSession
            if let existing = sessions[id] { session = existing }
            else {
                session = try ProviderSessions.make(for: thread)
                sessions[id] = session
                let events = session.events
                eventTasks[id] = Task { [weak self] in
                    for await event in events { await self?.receive(event, id: id) }
                }
            }
            try await session.send(text: prompt, thread: thread)
            return true
        } catch {
            updateThread(id) { $0.state = .failed; $0.messages.append(.init(role: .system, text: error.localizedDescription)) }
            if let session = sessions.removeValue(forKey: id) { await session.close() }
            eventTasks.removeValue(forKey: id)?.cancel()
            await save("turn.failed"); errorMessage = error.localizedDescription
            return true // The prompt is preserved in the conversation even when dispatch fails.
        }
    }
    func interrupt(_ id: UUID) async {
        do { try await sessions[id]?.interrupt() } catch { errorMessage = error.localizedDescription }
    }
    func respond(_ request: ApprovalRequest, threadID id: UUID, allow: Bool) async {
        do {
            guard let session = sessions[id] else { throw CoincideError("The provider disconnected.") }
            try await session.respond(request, allow: allow)
            approvals[id]?.removeAll { $0.id == request.id }
            updateThread(id) { $0.state = approvals[id, default: []].isEmpty ? .running : .awaitingApproval }
            try await persist("approval.answered")
        } catch { errorMessage = error.localizedDescription }
    }
    func answer(_ request: ApprovalRequest, threadID id: UUID, answers: [String: String]) async {
        do {
            guard let session = sessions[id] else { throw CoincideError("The provider disconnected.") }
            try await session.answer(request, answers: answers)
            approvals[id]?.removeAll { $0.id == request.id }
            updateThread(id) { $0.state = approvals[id, default: []].isEmpty ? .running : .awaitingApproval }
            try await persist("question.answered")
        } catch { errorMessage = error.localizedDescription }
    }
    func refreshModels(provider: ProviderKind? = nil) async {
        guard !isRefreshingModels else { return }; isRefreshingModels = true
        defer { isRefreshingModels = false }
        do {
            let kind = provider ?? selectedThread?.provider ?? .codex
            var thread = CodingThread(project: WorkspaceProject(path: FileManager.default.homeDirectoryForCurrentUser.path))
            thread.provider = kind
            let session = try ProviderSessions.make(for: thread)
            do { providerModels[kind] = try await session.models(); await session.close() }
            catch { await session.close(); throw error }
        } catch { errorMessage = error.localizedDescription }
    }
    func createWorktree(for id: UUID, branch: String) async {
        guard let thread = snapshot.threads.first(where: { $0.id == id }), thread.messages.isEmpty else {
            errorMessage = "Create the worktree before sending the first message."; return
        }
        do {
            let parent = try FileManager.default.url(for: .applicationSupportDirectory, in: .userDomainMask, appropriateFor: nil, create: true)
                .appendingPathComponent("Coincide/Worktrees", isDirectory: true)
            try FileManager.default.createDirectory(at: parent, withIntermediateDirectories: true)
            let path = parent.appendingPathComponent(id.uuidString)
            try await GitService(root: URL(fileURLWithPath: thread.workspacePath)).createWorktree(at: path, branch: branch)
            updateThread(id) { $0.workspacePath = path.path }
            try await persist("worktree.created")
        } catch { errorMessage = error.localizedDescription }
    }
    func shutdown() async {
        draftSaveTask?.cancel()
        for session in sessions.values { await session.close() }
        sessions.removeAll()
        for task in eventTasks.values { task.cancel() }; eventTasks.removeAll()
        snapshot.recoverInterruptedWork(); await save("workspace.closed")
    }
    private func receive(_ event: ProviderEvent, id: UUID) async {
        updateThread(id) { thread in
            switch event {
            case .thread(let providerID): thread.providerThreadID = providerID
            case .turn: thread.state = .running
            case .delta(let itemID, let role, let text):
                if let i = thread.messages.firstIndex(where: { $0.id == itemID }) { thread.messages[i].text += text }
                else { thread.messages.append(.init(id: itemID, role: role, text: text)) }
            case .message(let message):
                if let i = thread.messages.firstIndex(where: { $0.id == message.id }) { thread.messages[i] = message }
                else { thread.messages.append(message) }
            case .approval(let request):
                approvals[id, default: []].append(request); thread.state = .awaitingApproval
            case .approvalDismissed(let requestID):
                approvals[id]?.removeAll { $0.id == requestID }
                if thread.state == .awaitingApproval && approvals[id, default: []].isEmpty { thread.state = .running }
            case .completed(let state): thread.state = state; approvals[id] = []
            case .failure(let message): thread.state = .failed; thread.messages.append(.init(role: .system, text: message)); approvals[id] = []
            }
        }
        if case .failure = event {
            if let session = sessions.removeValue(forKey: id) { await session.close() }
            eventTasks.removeValue(forKey: id)?.cancel()
        }
        await save("provider.event")
    }
    private func persist(_ event: String) async throws {
        guard let database else { throw CoincideError("The workspace database is unavailable.") }
        let previous = writeTask, value = snapshot
        let task = Task { _ = try? await previous?.value; try await database.save(value, event: event) }
        writeTask = task; try await task.value
    }
    private func save(_ event: String) async {
        do { try await persist(event) } catch { errorMessage = "Workspace could not be saved: \(error.localizedDescription)" }
    }
}
