import AppKit
import CoincideCore
import Observation

struct FileNavigation: Equatable {
    let id = UUID()
    let workspacePath: String
    let path: String
    let line: Int?
}

@MainActor @Observable
final class WorkspaceStore {
    var snapshot = WorkspaceSnapshot()
    var selectedThreadID: UUID?
    var selectedProjectID: UUID?
    var search = ""
    var showArchived = false
    var errorMessage: String?
    var providerModels: [ProviderKind: [ProviderModel]] = [:]
    var isLoading = true
    var isRefreshingModels = false
    var inspectorVisible = false
    var fileNavigation: FileNavigation?
    private var engine: WorkspaceEngine?
    private var loadingTask: Task<Void, Never>?
    private var updatesTask: Task<Void, Never>?
    private var commandTail: Task<Void, Never>?
    private var draftSaveTask: Task<Void, Never>?
    private var draftOverrides: [UUID: String] = [:]
    private var pendingDrafts: [UUID: String] = [:]
    private var preparingWorkspaces: Set<UUID> = []
    private var lastSequence: Int64 = -1
    private var terminating = false

    init() {
        do {
            let root = try FileManager.default.url(for: .applicationSupportDirectory, in: .userDomainMask, appropriateFor: nil, create: true)
                .appendingPathComponent("Coincide", isDirectory: true)
            engine = try WorkspaceEngine(url: root.appendingPathComponent("workspace.sqlite"))
        } catch { errorMessage = error.localizedDescription }
    }
    func thread(_ id: UUID) -> CodingThread? {
        guard var value = snapshot.threads.first(where: { $0.id == id }) else { return nil }
        if let draft = draftOverrides[id] { value.draft = draft }
        return value
    }
    var selectedThread: CodingThread? { selectedThreadID.flatMap { thread($0) } }
    var selectedProject: WorkspaceProject? {
        let id = selectedThread?.projectID ?? selectedProjectID
        return snapshot.projects.first { $0.id == id }
    }
    var approvals: [UUID: [ApprovalRequest]] {
        Dictionary(uniqueKeysWithValues: snapshot.threads.map { ($0.id, $0.runtimeRequests.map(\.request)) })
    }
    func isResponding(_ request: ApprovalRequest, threadID: UUID) -> Bool {
        thread(threadID)?.runtimeRequests.first(where: { $0.id == request.id })?.responding == true
    }
    var visibleThreads: [CodingThread] {
        snapshot.threads.filter {
            $0.isArchived == showArchived && (search.isEmpty || $0.title.localizedCaseInsensitiveContains(search) || $0.messages.contains { $0.text.localizedCaseInsensitiveContains(search) })
        }.sorted { $0.isPinned != $1.isPinned ? $0.isPinned : $0.updatedAt > $1.updatedAt }
    }
    func load() async {
        if let loadingTask { await loadingTask.value; return }
        let task = Task<Void, Never> { await self.loadRuntime() }
        loadingTask = task; await task.value
    }
    private func loadRuntime() async {
        defer { isLoading = false }
        guard let engine else { return }
        do {
            let stream = await engine.updates()
            updatesTask = Task { [weak self] in for await value in stream { self?.apply(value) } }
            _ = try await engine.load()
            apply(await engine.current())
            selectedProjectID = snapshot.projects.first?.id
            selectedThreadID = snapshot.threads.first(where: { !$0.isArchived })?.id
        } catch { errorMessage = error.localizedDescription }
    }
    private func apply(_ update: WorkspaceUpdate) {
        guard update.sequence >= lastSequence else { return }
        lastSequence = update.sequence; snapshot = update.snapshot
        if let error = update.error, !terminating { errorMessage = error }
    }
    private func enqueue(_ command: WorkspaceCommand) -> Task<WorkspaceCommandReceipt, any Error> {
        let previous = commandTail, engine = engine
        let task = Task<WorkspaceCommandReceipt, any Error> {
            await previous?.value
            guard let engine else { throw CoincideError("The workspace runtime is unavailable.") }
            let receipt = try await engine.dispatch(command)
            apply(await engine.current())
            return receipt
        }
        commandTail = Task { _ = try? await task.value }
        return task
    }
    private func sendCommand(_ command: WorkspaceCommand) {
        let task = enqueue(command)
        Task { do { _ = try await task.value } catch { if !terminating { errorMessage = error.localizedDescription } } }
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
        let task = enqueue(.addProject(project))
        Task {
            do { _ = try await task.value; selectedProjectID = snapshot.projects.first { $0.path == project.path }?.id }
            catch { errorMessage = error.localizedDescription }
        }
    }
    func newThread(projectID: UUID? = nil) {
        guard let project = snapshot.projects.first(where: { $0.id == (projectID ?? selectedProjectID ?? selectedProject?.id) }) ?? snapshot.projects.first else {
            addProject(); return
        }
        let thread = CodingThread(project: project)
        let task = enqueue(.createThread(thread))
        Task {
            do {
                _ = try await task.value
                selectedThreadID = thread.id
                selectedProjectID = project.id; showArchived = false
            } catch { errorMessage = error.localizedDescription }
        }
    }
    func setModel(_ model: String, id: UUID) { sendCommand(.editThread(id, .model(model))) }
    func setProvider(_ provider: ProviderKind, id: UUID) { sendCommand(.editThread(id, .provider(provider))) }
    func models(for provider: ProviderKind) -> [ProviderModel] { providerModels[provider] ?? [] }
    func setDraft(_ text: String, id: UUID) {
        draftOverrides[id] = text; pendingDrafts[id] = text
        draftSaveTask?.cancel()
        draftSaveTask = Task { [weak self] in
            do { try await Task.sleep(for: .milliseconds(350)) } catch { return }
            self?.flushDrafts()
        }
    }
    private func flushDrafts() {
        let values = pendingDrafts; pendingDrafts = [:]
        for (id, text) in values {
            let task = enqueue(.editThread(id, .draft(text)))
            Task {
                do { _ = try await task.value; if draftOverrides[id] == text { draftOverrides.removeValue(forKey: id) } }
                catch { if !terminating { errorMessage = error.localizedDescription } }
            }
        }
    }
    func setPermission(_ mode: PermissionMode, id: UUID) { sendCommand(.editThread(id, .permission(mode))) }
    func togglePin(_ id: UUID) { if let value = thread(id) { sendCommand(.editThread(id, .pinned(!value.isPinned))) } }
    func toggleArchive(_ id: UUID) { if let value = thread(id) { sendCommand(.editThread(id, .archived(!value.isArchived))) } }
    func rename(_ id: UUID, title: String) { sendCommand(.editThread(id, .title(title))) }
    func isBusy(_ id: UUID) -> Bool { thread(id)?.isBusy == true }
    func isPreparingWorkspace(_ id: UUID) -> Bool { preparingWorkspaces.contains(id) }

    func submit(_ text: String, threadID id: UUID) -> Task<Bool, Never> {
        let prompt = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !prompt.isEmpty, let thread = thread(id), !preparingWorkspaces.contains(id) else { return Task { false } }
        guard ProcessChannel.findExecutable(thread.provider.executable) != nil else {
            errorMessage = "Install and sign in to \(thread.provider.name) CLI before sending a message."
            return Task { false }
        }
        pendingDrafts.removeValue(forKey: id)
        draftOverrides[id] = ""
        let task = enqueue(.submit(threadID: id, text: prompt))
        return Task {
            do { _ = try await task.value; if draftOverrides[id] == "" { draftOverrides.removeValue(forKey: id) }; return true }
            catch {
                if (draftOverrides[id] ?? "").isEmpty { setDraft(text, id: id) }
                errorMessage = error.localizedDescription; return false
            }
        }
    }
    func interrupt(_ id: UUID) async {
        let task = enqueue(.interrupt(threadID: id))
        do { _ = try await task.value } catch { errorMessage = error.localizedDescription }
    }
    func respond(_ request: ApprovalRequest, threadID id: UUID, allow: Bool) async {
        let task = enqueue(.respond(threadID: id, requestID: request.id, response: .decision(allow)))
        do { _ = try await task.value } catch { errorMessage = error.localizedDescription }
    }
    func answer(_ request: ApprovalRequest, threadID id: UUID, answers: [String: String]) async {
        let task = enqueue(.respond(threadID: id, requestID: request.id, response: .answers(answers)))
        do { _ = try await task.value } catch { errorMessage = error.localizedDescription }
    }
    func removeQueued(_ queuedID: UUID, threadID: UUID) { sendCommand(.removeQueued(threadID: threadID, queuedID: queuedID)) }
    func editQueued(_ queuedID: UUID, threadID: UUID) {
        flushDrafts(); sendCommand(.editQueued(threadID: threadID, queuedID: queuedID))
    }
    func resumeQueue(_ threadID: UUID) { sendCommand(.resumeQueue(threadID: threadID)) }
    func openFile(_ url: URL, line: Int?, workspacePath: String) {
        let root = URL(fileURLWithPath: workspacePath).standardizedFileURL.resolvingSymlinksInPath()
        guard url.path.hasPrefix(root.path + "/") else { errorMessage = "This file is outside the workspace."; return }
        let relative = String(url.path.dropFirst(root.path.count + 1))
        do { _ = try WorkspaceFiles(root: root).resolve(relative) }
        catch { errorMessage = error.localizedDescription; return }
        fileNavigation = .init(workspacePath: workspacePath, path: relative, line: line); inspectorVisible = true
    }
    func refreshModels(provider: ProviderKind? = nil) async {
        guard !isRefreshingModels, let engine else { return }; isRefreshingModels = true
        defer { isRefreshingModels = false }
        do {
            let kind = provider ?? selectedThread?.provider ?? .codex
            providerModels[kind] = try await engine.models(provider: kind)
        } catch { if !terminating { errorMessage = error.localizedDescription } }
    }
    func createWorktree(for id: UUID, branch: String) async {
        guard let thread = thread(id), thread.messages.isEmpty, !thread.isBusy, !preparingWorkspaces.contains(id) else {
            errorMessage = "Create the worktree before sending the first message."; return
        }
        preparingWorkspaces.insert(id); defer { preparingWorkspaces.remove(id) }
        do {
            let parent = try FileManager.default.url(for: .applicationSupportDirectory, in: .userDomainMask, appropriateFor: nil, create: true)
                .appendingPathComponent("Coincide/Worktrees", isDirectory: true)
            try FileManager.default.createDirectory(at: parent, withIntermediateDirectories: true)
            let path = parent.appendingPathComponent(id.uuidString)
            try await GitService(root: URL(fileURLWithPath: thread.workspacePath)).createWorktree(at: path, branch: branch)
            _ = try await enqueue(.editThread(id, .workspacePath(path.path))).value
        } catch { errorMessage = error.localizedDescription }
    }
    func shutdown() async {
        terminating = true; draftSaveTask?.cancel(); flushDrafts()
        await commandTail?.value
        await engine?.shutdown()
        updatesTask?.cancel(); updatesTask = nil
    }
}
