import AppKit
import CoincideCore
import Observation
import UniformTypeIdentifiers

struct FileNavigation: Equatable {
    let id = UUID()
    let workspacePath: String
    let path: String
    let line: Int?
}

@MainActor @Observable
final class WorkspaceStore {
    typealias ProjectCreator = @Sendable (String, URL) async throws -> ManagedProjectCreationResult
    let managedProjectsRoot: URL
    private let projectCreator: ProjectCreator
    var snapshot = WorkspaceSnapshot()
    var selectedThreadID: UUID?
    var selectedProjectID: UUID?
    var search = ""
    var showArchived = false
    var errorMessage: String?
    var providerModels: [ProviderKind: [ProviderModel]] = [:]
    var acpModels: [UUID: [ProviderModel]] = [:]
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
    private var attachmentImportCounts: [UUID: Int] = [:]
    private var attachmentImportTasks: [UUID: Task<Void, Never>] = [:]
    private var gitInspectors: [String: GitInspectorStore] = [:]
    private var retryingProjectClones: Set<UUID> = []
    private var projectCreationTasks: [UUID: Task<ManagedProjectCreationResult, any Error>] = [:]
    private var lastSequence: Int64 = -1
    private var terminating = false

    init(databaseURL: URL? = nil) {
        managedProjectsRoot = (databaseURL?.deletingLastPathComponent() ?? Self.applicationDataRoot).appendingPathComponent("Projects", isDirectory: true)
        projectCreator = { name, root in try await ManagedProjectService(root: root).create(name: name) }
        do {
            if let databaseURL { engine = try WorkspaceEngine(url: databaseURL); return }
            let root = try FileManager.default.url(for: .applicationSupportDirectory, in: .userDomainMask, appropriateFor: nil, create: true)
                .appendingPathComponent("Coincide", isDirectory: true)
            engine = try WorkspaceEngine(url: root.appendingPathComponent("workspace.sqlite"))
        } catch { errorMessage = error.localizedDescription }
    }
    init(engine: WorkspaceEngine, managedProjectsRoot: URL? = nil,
         projectCreator: @escaping ProjectCreator = { name, root in try await ManagedProjectService(root: root).create(name: name) }) {
        self.engine = engine
        self.managedProjectsRoot = managedProjectsRoot ?? Self.applicationDataRoot.appendingPathComponent("Projects", isDirectory: true)
        self.projectCreator = projectCreator
    }
    private static var applicationDataRoot: URL {
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support", isDirectory: true)
        return support.appendingPathComponent("Coincide", isDirectory: true)
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
    func gitInspector(path: String) -> GitInspectorStore {
        let path = URL(fileURLWithPath: path).standardizedFileURL.resolvingSymlinksInPath().path
        if let existing = gitInspectors[path] { return existing }
        let model = GitInspectorStore(path: path)
        if terminating { model.prepareForShutdown() }
        gitInspectors[path] = model; return model
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
        for id in Array(acpModels.keys) {
            let old = snapshot.threads.first { $0.id == id }, next = update.snapshot.threads.first { $0.id == id }
            if old?.providerMetadata != next?.providerMetadata || old?.acpAgent != next?.acpAgent || old?.workspacePath != next?.workspacePath {
                acpModels.removeValue(forKey: id)
            }
        }
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
    func workspaceReady(for thread: CodingThread) -> Bool { snapshot.workspaceReady(for: thread) }
    func createManagedProject(name: String) async throws -> ManagedProjectCreationResult {
        guard !terminating, engine != nil else { throw CancellationError() }
        let name = try ManagedProjectService.validatedName(name)
        let root = managedProjectsRoot, creator = projectCreator, id = UUID()
        let task = Task.detached(priority: .userInitiated) { try await creator(name, root) }
        projectCreationTasks[id] = task
        defer { projectCreationTasks.removeValue(forKey: id) }
        let result = try await withTaskCancellationHandler { try await task.value } onCancel: { task.cancel() }
        try Task.checkCancellation()
        guard !terminating else { throw CancellationError() }
        let thread = CodingThread(project: result.project)
        do { _ = try await enqueue(.addProjectWithThread(project: result.project, thread: thread)).value }
        catch {
            throw CoincideError("The project files are preserved at \(result.project.path), but the project could not be opened. \(GitService.redactURLs(error.localizedDescription))")
        }
        selectedProjectID = result.project.id; selectedThreadID = thread.id; showArchived = false
        return result
    }
    func cloneRepository(source: String, destination: URL) async throws {
        let plan = try GitClonePlan.prepare(source: source, destination: destination)
        var project = WorkspaceProject(path: plan.destinationPath); project.clone = .init(plan: plan)
        let thread = CodingThread(project: project)
        _ = try await enqueue(.startProjectClone(project: project, thread: thread)).value
        selectedProjectID = project.id; selectedThreadID = thread.id; showArchived = false
    }
    func cancelProjectClone(_ projectID: UUID) { sendCommand(.cancelProjectClone(projectID)) }
    func retryProjectClone(_ projectID: UUID) {
        guard !terminating, snapshot.projects.first(where: { $0.id == projectID })?.clone?.canRetry == true,
              retryingProjectClones.insert(projectID).inserted else { return }
        Task {
            defer { retryingProjectClones.remove(projectID) }
            guard let engine else { return }
            do { _ = try await engine.retryProjectClone(projectID); apply(await engine.current()) }
            catch { if !terminating { errorMessage = GitService.redactURLs(error.localizedDescription) } }
        }
    }
    func isRetryingProjectClone(_ projectID: UUID) -> Bool { retryingProjectClones.contains(projectID) }
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
    func setACPAgent(_ agent: ACPAgentConfiguration, id: UUID) { sendCommand(.editThread(id, .acpAgent(agent))) }
    func setAgentMode(_ mode: String?, id: UUID) { sendCommand(.editThread(id, .agentMode(mode))) }
    func setAgentConfig(_ optionID: String, value: String?, id: UUID) { sendCommand(.editThread(id, .agentConfig(id: optionID, value: value))) }
    func setAgentConfiguration(_ optionID: String, value: JSONValue?, id: UUID) { sendCommand(.editThread(id, .agentConfiguration(id: optionID, value: value))) }
    func resetAgentOptions(_ id: UUID) { sendCommand(.editThread(id, .resetAgentOptions)) }
    func saveACPAgent(_ agent: ACPAgentConfiguration) async throws { _ = try await enqueue(.saveACPAgent(agent)).value }
    func removeACPAgent(_ id: UUID) { sendCommand(.removeACPAgent(id)) }
    func models(for provider: ProviderKind) -> [ProviderModel] { providerModels[provider] ?? [] }
    func models(for thread: CodingThread) -> [ProviderModel] {
        guard thread.provider == .acp else { return models(for: thread.provider) }
        if let refreshed = acpModels[thread.id] { return refreshed }
        if let metadata = thread.providerMetadata { return ACPConfigurationOptions.models(metadata) }
        return []
    }
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
    func isImportingAttachments(_ id: UUID) -> Bool { attachmentImportCounts[id, default: 0] > 0 }
    func chooseAttachments(threadID: UUID) {
        let panel = NSOpenPanel(); panel.canChooseDirectories = false; panel.canChooseFiles = true
        panel.allowsMultipleSelection = true; panel.prompt = "Attach"
        panel.begin { [weak self] response in
            guard response == .OK else { return }; self?.importAttachments(files: panel.urls, threadID: threadID)
        }
    }
    func importAttachments(files: [URL] = [], providers: [NSItemProvider] = [], threadID: UUID) {
        guard !terminating, let engine else { return }
        guard files.count + providers.count <= AttachmentLimits.count else { errorMessage = "Attach up to 100 files per message."; return }
        let taskID = UUID()
        attachmentImportCounts[threadID, default: 0] += 1
        attachmentImportTasks[taskID] = Task {
            defer {
                attachmentImportCounts[threadID, default: 1] -= 1
                attachmentImportTasks.removeValue(forKey: taskID)
            }
            var references: [ChatAttachment] = [], errors: [String] = []
            for file in files {
                do { try Task.checkCancellation(); references.append(try await engine.attachments.importFile(file)) }
                catch is CancellationError { return }
                catch { errors.append("\(file.lastPathComponent): \(error.localizedDescription)") }
            }
            for provider in providers {
                do {
                    try Task.checkCancellation()
                    if provider.hasItemConformingToTypeIdentifier(UTType.fileURL.identifier) {
                        let data = try await NativePasteData.load(provider, type: UTType.fileURL.identifier)
                        guard let url = URL(dataRepresentation: data, relativeTo: nil), url.isFileURL else { throw CoincideError("This is not a local file.") }
                        references.append(try await engine.attachments.importFile(url))
                    } else if let type = provider.registeredTypeIdentifiers.first(where: { UTType($0)?.conforms(to: .image) == true }) {
                        let data = try await NativePasteData.load(provider, type: type)
                        let suffix = UTType(type)?.preferredFilenameExtension ?? "png"
                        references.append(try await engine.attachments.importData(data, name: provider.suggestedName ?? "Pasted image.\(suffix)"))
                    }
                } catch is CancellationError { return }
                catch { errors.append(error.localizedDescription) }
            }
            guard !terminating, !Task.isCancelled else { return }
            if !references.isEmpty {
                do { _ = try await enqueue(.addAttachments(threadID: threadID, attachments: references)).value }
                catch { errors.append(error.localizedDescription) }
            }
            if !errors.isEmpty { errorMessage = errors.joined(separator: "\n") }
        }
    }
    func removeAttachment(_ attachmentID: UUID, threadID: UUID) { sendCommand(.removeAttachment(threadID: threadID, attachmentID: attachmentID)) }
    func attachmentData(_ attachment: ChatAttachment) async throws -> Data {
        guard let engine else { throw CoincideError("The workspace runtime is unavailable.") }
        return try await engine.attachments.data(for: attachment)
    }
    func openAttachment(_ attachment: ChatAttachment) async {
        guard let engine else { return }
        do {
            _ = try await engine.attachments.data(for: attachment)
            let url = try await engine.attachments.url(for: attachment)
            guard !terminating else { return }
            if !NSWorkspace.shared.open(url) { errorMessage = "No application could open this attachment." }
        } catch { errorMessage = error.localizedDescription }
    }
    func copyAttachmentImage(_ attachment: ChatAttachment) async {
        do {
            let data = try await attachmentData(attachment)
            guard !terminating, attachment.isImage, let image = NSImage(data: data) else { return }
            NSPasteboard.general.clearContents(); NSPasteboard.general.writeObjects([image])
        } catch { if !terminating { errorMessage = error.localizedDescription } }
    }
    func saveAttachment(_ attachment: ChatAttachment) {
        let panel = NSSavePanel()
        let base = (attachment.name as NSString).deletingPathExtension
        panel.nameFieldStringValue = attachment.fileExtension.isEmpty ? attachment.name : base + "." + attachment.fileExtension
        if let type = UTType(mimeType: attachment.mimeType) { panel.allowedContentTypes = [type] }
        panel.begin { [weak self] response in
            guard response == .OK, let url = panel.url, let self else { return }
            Task {
                do {
                    let bytes = try await self.attachmentData(attachment)
                    guard !self.terminating else { return }
                    let scoped = url.startAccessingSecurityScopedResource(); defer { if scoped { url.stopAccessingSecurityScopedResource() } }
                    try bytes.write(to: url, options: .atomic)
                } catch { if !self.terminating { self.errorMessage = error.localizedDescription } }
            }
        }
    }

    func submit(_ text: String, threadID id: UUID) -> Task<Bool, Never> {
        let prompt = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let thread = thread(id), (!prompt.isEmpty || !thread.draftAttachments.isEmpty),
              !preparingWorkspaces.contains(id), !isImportingAttachments(id) else { return Task { false } }
        let executable = thread.provider == .acp ? thread.acpAgent?.executable ?? "" : thread.provider.executable
        guard !executable.isEmpty, ProcessChannel.findExecutable(executable) != nil else {
            errorMessage = "Install and sign in to \(thread.providerName) before sending a message."
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
    func choose(_ request: ApprovalRequest, threadID id: UUID, optionID: String) async {
        let task = enqueue(.respond(threadID: id, requestID: request.id, response: .option(optionID)))
        do { _ = try await task.value } catch { errorMessage = error.localizedDescription }
    }
    func removeQueued(_ queuedID: UUID, threadID: UUID) { sendCommand(.removeQueued(threadID: threadID, queuedID: queuedID)) }
    func editQueued(_ queuedID: UUID, threadID: UUID) {
        flushDrafts(); sendCommand(.editQueued(threadID: threadID, queuedID: queuedID))
    }
    func resumeQueue(_ threadID: UUID) { sendCommand(.resumeQueue(threadID: threadID)) }
    func openFile(_ url: URL, line: Int?, workspacePath: String) {
        if let thread = snapshot.threads.first(where: { $0.workspacePath == workspacePath }), !workspaceReady(for: thread) {
            errorMessage = "Wait for the repository to finish cloning before opening its files."; return
        }
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
            if kind == .acp, let thread = selectedThread, thread.acpAgent != nil {
                acpModels[thread.id] = try await engine.models(thread: thread)
            } else { providerModels[kind] = try await engine.models(provider: kind) }
        } catch { if !terminating { errorMessage = error.localizedDescription } }
    }
    func createWorktree(for id: UUID, branch: String) async {
        guard let thread = thread(id), thread.messages.isEmpty, !thread.isBusy, !preparingWorkspaces.contains(id) else {
            errorMessage = "Create the worktree before sending the first message."; return
        }
        guard workspaceReady(for: thread) else { errorMessage = "Wait for cloning to finish before creating a worktree."; return }
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
        terminating = true
        let creations = Array(projectCreationTasks.values)
        for task in creations { task.cancel() }
        for task in creations { _ = await task.result }
        let inspectors = Array(gitInspectors.values)
        for model in inspectors { model.prepareForShutdown() }
        for model in inspectors { await model.shutdown() }
        let imports = Array(attachmentImportTasks.values); for task in imports { task.cancel() }; for task in imports { await task.value }
        draftSaveTask?.cancel(); flushDrafts()
        await commandTail?.value
        await engine?.shutdown()
        updatesTask?.cancel(); updatesTask = nil
    }
}
