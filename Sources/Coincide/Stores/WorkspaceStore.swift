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

struct ProjectRemovalRequest: Identifiable {
    let id: UUID
    let name: String
    let path: String
    let threadIDs: [UUID]
    let dirtyEditorIDs: Set<UUID>
}

struct ProjectGroupRemovalRequest: Identifiable {
    let id: String
    let name: String
    let projects: [ProjectGroupMemberReference]
    let threadIDs: [UUID]
    let dirtyEditorIDs: Set<UUID>
}

private struct ProjectRemovalCleanup {
    let projectIDs: Set<UUID>
    let task: Task<Void, Never>
}

@MainActor private final class WeakTerminalStore {
    weak var value: TerminalWorkspaceStore?
    init(_ value: TerminalWorkspaceStore) { self.value = value }
}

@MainActor @Observable
final class WorkspaceStore {
    typealias ProjectCreator = @Sendable (String, URL) async throws -> ManagedProjectCreationResult
    let managedProjectsRoot: URL
    let worktreesRoot: URL
    private let projectCreator: ProjectCreator
    var snapshot = WorkspaceSnapshot()
    var selectedThreadID: UUID? {
        didSet {
            guard !isLoading, !terminating, selectedThreadID != oldValue,
                  selectedThreadID.map({ id in snapshot.threads.contains { $0.id == id } }) ?? true else { return }
            sendCommand(.selectConversation(threadID: selectedThreadID))
        }
    }
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
    private var attachmentImportOwners: [UUID: UUID] = [:]
    private var worktreeTasks: [UUID: Task<Void, any Error>] = [:]
    private var projectCloneRetryTasks: [UUID: Task<Void, Never>] = [:]
    private var removalCleanupTasks: [UUID: ProjectRemovalCleanup] = [:]
    private var terminalStores: [ObjectIdentifier: WeakTerminalStore] = [:]
    private var dirtyEditors: [UUID: String] = [:]
    private var removalEditorLocks: [UUID: Set<String>] = [:]
    private var gitInspectors: [String: GitInspectorStore] = [:]
    private var retryingProjectClones: Set<UUID> = []
    private var projectCreationTasks: [UUID: Task<ManagedProjectCreationResult, any Error>] = [:]
    private var lastSequence: Int64 = -1
    private var terminating = false

    init(databaseURL: URL? = nil) {
        managedProjectsRoot = (databaseURL?.deletingLastPathComponent() ?? Self.applicationDataRoot).appendingPathComponent("Projects", isDirectory: true)
        worktreesRoot = (databaseURL?.deletingLastPathComponent() ?? Self.applicationDataRoot).appendingPathComponent("Worktrees", isDirectory: true)
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
        self.worktreesRoot = (managedProjectsRoot?.deletingLastPathComponent() ?? Self.applicationDataRoot).appendingPathComponent("Worktrees", isDirectory: true)
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
    var orderedProjects: [WorkspaceProject] { snapshot.orderedProjects }
    var orderedProjectGroups: [ProjectGroup] { snapshot.orderedProjectGroups }
    var projectGroupingMode: ProjectGroupingMode { snapshot.effectiveSidebarPreferences.groupingMode }
    var projectSortMode: ProjectSortMode { snapshot.effectiveSidebarPreferences.sortMode }
    func projectGroup(containing projectID: UUID) -> ProjectGroup? {
        snapshot.projectGroups.first { $0.memberProjectIDs.contains(projectID) }
    }
    func isProjectGroupExpanded(_ key: String) -> Bool { snapshot.isProjectGroupExpanded(key) }
    func sidebarThreads(groupKey: String) -> [CodingThread] {
        guard let group = snapshot.projectGroups.first(where: { $0.key == groupKey }) else { return [] }
        let members = Set(group.memberProjectIDs)
        let threads = visibleThreads.filter { members.contains($0.projectID) }
        return isProjectGroupExpanded(groupKey) ? threads : threads.filter { $0.id == selectedThreadID }
    }
    func preferredProject(in group: ProjectGroup) -> WorkspaceProject? {
        let members = Set(group.memberProjectIDs)
        let activeID = snapshot.effectiveSidebarPreferences.activeProjectByGroup[group.key]
        if let project = snapshot.projects.first(where: { $0.id == activeID && members.contains($0.id) && ($0.clone?.isReady ?? true) }) { return project }
        let selectedID = selectedProjectID ?? selectedThread?.projectID
        if let project = snapshot.projects.first(where: { $0.id == selectedID && members.contains($0.id) }) { return project }
        return group.members.first(where: { $0.clone?.isReady ?? true }) ?? group.members.first
    }
    func setProjectGroupingMode(_ mode: ProjectGroupingMode) { sendCommand(.setProjectGroupingMode(mode)) }
    func setProjectGroupingOverride(_ id: UUID, mode: ProjectGroupingMode?) { sendCommand(.setProjectGroupingOverride(projectID: id, mode: mode)) }
    func setProjectGroupExpanded(_ group: ProjectGroup, expanded: Bool) {
        sendCommand(.setProjectGroupExpanded(groupKey: group.key, expectedProjectIDs: group.memberProjectIDs, expanded: expanded))
    }
    func setProjectGroupCheckout(_ group: ProjectGroup, projectID: UUID) {
        sendCommand(.setProjectGroupCheckout(groupKey: group.key, expectedProjectIDs: group.memberProjectIDs, projectID: projectID))
    }
    func refreshRepositoryIdentity(_ id: UUID) {
        guard !terminating, let engine else { return }
        Task {
            do { _ = try await engine.refreshRepositoryIdentity(projectID: id); apply(await engine.current()) }
            catch is CancellationError { }
            catch { if !terminating, snapshot.projects.contains(where: { $0.id == id }) { errorMessage = GitService.redactURLs(error.localizedDescription) } }
        }
    }
    func moveProjectGroup(_ key: String, by offset: Int) {
        let groups = snapshot.projectGroups
        guard projectSortMode == .manual, let index = groups.firstIndex(where: { $0.key == key }),
              [-1, 1].contains(offset), groups.indices.contains(index + offset) else { return }
        moveProjectGroups(fromOffsets: IndexSet(integer: index), toOffset: offset > 0 ? index + 2 : index - 1)
    }
    func moveProjectGroups(fromOffsets offsets: IndexSet, toOffset destination: Int) {
        let groups = snapshot.projectGroups, order = snapshot.projects.map(\.id)
        guard projectSortMode == .manual, !offsets.isEmpty, offsets.allSatisfy({ groups.indices.contains($0) }),
              (0...groups.count).contains(destination) else { return }
        let movingMembers = Set(offsets.flatMap { groups[$0].memberProjectIDs })
        let moving = order.filter { movingMembers.contains($0) }
        var next = order.filter { !movingMembers.contains($0) }
        let remainingGroups = groups.enumerated().filter { !offsets.contains($0.offset) }.map(\.element)
        let groupInsertion = destination - offsets.filter { $0 < destination }.count
        var nextGroups = remainingGroups
        nextGroups.insert(contentsOf: offsets.map { groups[$0] }, at: groupInsertion)
        guard nextGroups.map(\.key) != groups.map(\.key) else { return }
        let insertion: Int
        if remainingGroups.indices.contains(groupInsertion) {
            let target = Set(remainingGroups[groupInsertion].memberProjectIDs)
            insertion = next.firstIndex(where: { target.contains($0) }) ?? next.count
        } else { insertion = next.count }
        next.insert(contentsOf: moving, at: insertion)
        let membership = Dictionary(uniqueKeysWithValues: groups.map { ($0.key, $0.memberProjectIDs) })
        sendCommand(.reorderProjectGroups(projectIDs: next, expectedOrder: order, expectedGroups: membership))
    }
    func isProjectExpanded(_ id: UUID) -> Bool { snapshot.isProjectExpanded(id) }
    func sidebarThreads(projectID: UUID) -> [CodingThread] {
        let threads = visibleThreads.filter { $0.projectID == projectID }
        return isProjectExpanded(projectID) ? threads : threads.filter { $0.id == selectedThreadID }
    }
    func renameProject(_ id: UUID, title: String) { sendCommand(.renameProject(projectID: id, title: title)) }
    func renameProjectGroup(_ group: ProjectGroup, title: String) {
        sendCommand(.renameProjectGroup(groupKey: group.key, expectedProjects: group.memberProjectReferences, title: title))
    }
    func registerTerminals(_ terminals: TerminalWorkspaceStore) { terminalStores[ObjectIdentifier(terminals)] = WeakTerminalStore(terminals) }
    func unregisterTerminals(_ terminals: TerminalWorkspaceStore) { terminalStores.removeValue(forKey: ObjectIdentifier(terminals)) }
    func setEditorDirty(_ id: UUID, workspacePath: String, dirty: Bool) {
        if dirty { dirtyEditors[id] = Self.canonicalPath(workspacePath) } else { dirtyEditors.removeValue(forKey: id) }
    }
    func canEditWorkspace(_ path: String) -> Bool {
        let path = Self.canonicalPath(path)
        guard !terminating, !removalEditorLocks.values.contains(where: { $0.contains(path) }) else { return false }
        return !snapshot.threads.contains { removalEditorLocks[$0.projectID] != nil && Self.canonicalPath($0.workspacePath) == path }
    }
    func projectRemovalRequest(_ id: UUID) -> ProjectRemovalRequest? {
        guard let project = snapshot.projects.first(where: { $0.id == id }) else { return nil }
        let threads = snapshot.threads.filter { $0.projectID == id }
        let paths = Set(([project.path] + threads.map(\.workspacePath)).map(Self.canonicalPath))
        return .init(id: id, name: project.name, path: project.path, threadIDs: threads.map(\.id).sorted { $0.uuidString < $1.uuidString },
                     dirtyEditorIDs: Set(dirtyEditors.compactMap { paths.contains($0.value) ? $0.key : nil }))
    }
    func removeProject(_ request: ProjectRemovalRequest) async throws {
        guard !terminating, let engine, removalEditorLocks[request.id] == nil,
              let current = projectRemovalRequest(request.id), let project = snapshot.projects.first(where: { $0.id == request.id }) else { throw CancellationError() }
        guard current.path == request.path else { throw CoincideError("The checkout changed. Review the project removal again.") }
        guard current.dirtyEditorIDs.isSubset(of: request.dirtyEditorIDs) else {
            throw CoincideError("New unsaved file edits appeared. Review the project removal again before discarding them.")
        }
        removalEditorLocks[request.id] = Set(([project.path] + snapshot.threads.filter { $0.projectID == request.id }.map(\.workspacePath)).map(Self.canonicalPath))
        defer { removalEditorLocks.removeValue(forKey: request.id) }
        _ = try await enqueue(.removeProject(projectID: request.id, expectedThreadIDs: request.threadIDs), preflight: {
            guard let latest = self.projectRemovalRequest(request.id) else { throw CancellationError() }
            guard latest.path == request.path else { throw CoincideError("The checkout changed. Review the project removal again.") }
            guard latest.dirtyEditorIDs.isSubset(of: request.dirtyEditorIDs) else {
                throw CoincideError("New unsaved file edits appeared. Review the project removal again before discarding them.")
            }
            let paths = [latest.path] + self.snapshot.threads.filter { $0.projectID == request.id }.map(\.workspacePath)
            self.extendRemovalLocks(projectIDs: [request.id], paths: paths)
        }).value
        await engine.awaitProjectRemovalCleanup(projectID: request.id)
        await awaitRemovalCleanup(projectIDs: [request.id])
    }
    func projectGroupRemovalRequest(_ key: String) -> ProjectGroupRemovalRequest? {
        guard let group = snapshot.projectGroups.first(where: { $0.key == key }) else { return nil }
        let members = Set(group.memberProjectIDs), threads = snapshot.threads.filter { members.contains($0.projectID) }
        let paths = Set((group.memberProjectReferences.map(\.path) + threads.map(\.workspacePath)).map(Self.canonicalPath))
        return .init(id: key, name: group.displayName, projects: group.memberProjectReferences,
                     threadIDs: threads.map(\.id).sorted { $0.uuidString < $1.uuidString },
                     dirtyEditorIDs: Set(dirtyEditors.compactMap { paths.contains($0.value) ? $0.key : nil }))
    }
    private func validateGroupRemoval(_ request: ProjectGroupRemovalRequest) throws {
        guard let current = projectGroupRemovalRequest(request.id),
              current.projects.sorted(by: { $0.id.uuidString < $1.id.uuidString }) == request.projects.sorted(by: { $0.id.uuidString < $1.id.uuidString }),
              current.threadIDs == request.threadIDs else {
            throw CoincideError("The group's checkouts or conversations changed. Review the group removal again.")
        }
        guard current.dirtyEditorIDs.isSubset(of: request.dirtyEditorIDs) else {
            throw CoincideError("New unsaved file edits appeared. Review the group removal again before discarding them.")
        }
    }
    func removeProjectGroup(_ request: ProjectGroupRemovalRequest) async throws {
        guard !terminating, let engine else { throw CancellationError() }
        try validateGroupRemoval(request)
        let members = Set(request.projects.map(\.id))
        guard !members.isEmpty, members.allSatisfy({ removalEditorLocks[$0] == nil }) else { throw CancellationError() }
        let threads = snapshot.threads.filter { members.contains($0.projectID) }
        let paths = Set((request.projects.map(\.path) + threads.map(\.workspacePath)).map(Self.canonicalPath))
        for id in members { removalEditorLocks[id] = paths }
        defer { for id in members { removalEditorLocks.removeValue(forKey: id) } }
        _ = try await enqueue(.removeProjectGroup(groupKey: request.id, expectedProjects: request.projects, expectedThreadIDs: request.threadIDs), preflight: {
            try self.validateGroupRemoval(request)
            let paths = request.projects.map(\.path) + self.snapshot.threads.filter { members.contains($0.projectID) }.map(\.workspacePath)
            self.extendRemovalLocks(projectIDs: members, paths: paths)
        }).value
        for id in members { await engine.awaitProjectRemovalCleanup(projectID: id) }
        await awaitRemovalCleanup(projectIDs: members)
    }
    private func awaitRemovalCleanup(projectIDs: Set<UUID>) async {
        while true {
            let tasks = removalCleanupTasks.values.filter { !$0.projectIDs.isDisjoint(with: projectIDs) }.map(\.task)
            guard !tasks.isEmpty else { return }
            for task in tasks { await task.value }
        }
    }
    private func extendRemovalLocks(projectIDs: Set<UUID>, paths: [String]) {
        let added = Set(paths.map(Self.canonicalPath))
        for id in projectIDs { removalEditorLocks[id, default: []].formUnion(added) }
    }
    private static func canonicalPath(_ path: String) -> String {
        URL(fileURLWithPath: path).standardizedFileURL.resolvingSymlinksInPath().path
    }
    func setProjectExpanded(_ id: UUID, expanded: Bool) { sendCommand(.setProjectExpanded(projectID: id, expanded: expanded)) }
    func setProjectSortMode(_ mode: ProjectSortMode) { sendCommand(.setProjectSortMode(mode)) }
    func moveProject(_ id: UUID, by offset: Int) {
        let order = snapshot.projects.map(\.id)
        guard projectSortMode == .manual, let index = order.firstIndex(of: id), [-1, 1].contains(offset), order.indices.contains(index + offset) else { return }
        var next = order; next.remove(at: index); next.insert(id, at: index + offset)
        sendCommand(.reorderProjects(projectIDs: next, expectedOrder: order))
    }
    func moveProjects(fromOffsets offsets: IndexSet, toOffset destination: Int) {
        let order = snapshot.projects.map(\.id)
        guard projectSortMode == .manual, !offsets.isEmpty,
              offsets.allSatisfy({ order.indices.contains($0) }), (0...order.count).contains(destination) else { return }
        let moving = offsets.map { order[$0] }
        var next = order.enumerated().filter { !offsets.contains($0.offset) }.map(\.element)
        let insertion = destination - offsets.filter { $0 < destination }.count
        next.insert(contentsOf: moving, at: insertion)
        sendCommand(.reorderProjects(projectIDs: next, expectedOrder: order))
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
            selectedThreadID = snapshot.effectiveSidebarPreferences.selectedThreadID
                ?? snapshot.threads.first(where: { !$0.isArchived })?.id
            selectedProjectID = selectedThread?.projectID ?? snapshot.projects.first?.id
            showArchived = selectedThread?.isArchived ?? false
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
        let removedThreads = Set(snapshot.threads.map(\.id)).subtracting(update.snapshot.threads.map(\.id))
        let removedProjects = Set(snapshot.projects.map(\.id)).subtracting(update.snapshot.projects.map(\.id))
        lastSequence = update.sequence; snapshot = update.snapshot
        if !removedThreads.isEmpty || !removedProjects.isEmpty { reconcileRemovedResources(threadIDs: removedThreads, projectIDs: removedProjects) }
        if let error = update.error, !terminating { errorMessage = error }
    }
    private func reconcileRemovedResources(threadIDs: Set<UUID>, projectIDs: Set<UUID>) {
        for id in threadIDs {
            pendingDrafts.removeValue(forKey: id); draftOverrides.removeValue(forKey: id); acpModels.removeValue(forKey: id)
        }
        let imports = attachmentImportTasks.compactMap { key, task in attachmentImportOwners[key].map { threadIDs.contains($0) } == true ? task : nil }
        let worktrees = worktreeTasks.filter { threadIDs.contains($0.key) }.map(\.value)
        let retries = projectCloneRetryTasks.filter { projectIDs.contains($0.key) }.map(\.value)
        for task in imports { task.cancel() }; for task in worktrees { task.cancel() }; for task in retries { task.cancel() }
        let terminals = terminalStores.values.compactMap(\.value)
        terminalStores = terminalStores.filter { $0.value.value != nil }
        let closingTerminals = terminals.flatMap { $0.remove(threadIDs: threadIDs) }
        let referencedPaths = Set((snapshot.projects.map(\.path) + snapshot.threads.map(\.workspacePath)).map(Self.canonicalPath))
        dirtyEditors = dirtyEditors.filter { referencedPaths.contains($0.value) }
        let discardedInspectors = gitInspectors.filter { !referencedPaths.contains($0.key) }
        for (path, inspector) in discardedInspectors { inspector.prepareForShutdown(); gitInspectors.removeValue(forKey: path) }
        if let navigation = fileNavigation, !referencedPaths.contains(Self.canonicalPath(navigation.workspacePath)) { fileNavigation = nil }
        if selectedThreadID.map({ threadIDs.contains($0) }) == true {
            let fallback = snapshot.threads.first(where: { $0.isArchived == showArchived })
                ?? snapshot.threads.first(where: { !$0.isArchived }) ?? snapshot.threads.first
            selectedThreadID = fallback?.id
            showArchived = fallback?.isArchived ?? false
        }
        if selectedProjectID.map({ projectIDs.contains($0) }) == true {
            selectedProjectID = selectedThread?.projectID ?? snapshot.projects.first?.id
        }
        let cleanupID = UUID()
        let task: Task<Void, Never> = Task { [weak self] in
            for task in imports { await task.value }
            for task in worktrees { _ = await task.result }
            for task in retries { await task.value }
            for terminal in closingTerminals { await terminal.waitForClose() }
            for inspector in discardedInspectors.values { await inspector.shutdown() }
            self?.removalCleanupTasks.removeValue(forKey: cleanupID)
        }
        removalCleanupTasks[cleanupID] = .init(projectIDs: projectIDs, task: task)
    }
    private func enqueue(_ command: WorkspaceCommand, preflight: (@MainActor () throws -> Void)? = nil) -> Task<WorkspaceCommandReceipt, any Error> {
        let previous = commandTail, engine = engine
        let task = Task<WorkspaceCommandReceipt, any Error> {
            await previous?.value
            try preflight?()
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
            do { _ = try await task.value; if let added = snapshot.projects.first(where: { $0.path == project.path }) { selectedProjectID = added.id } }
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
        if snapshot.threads.contains(where: { $0.id == thread.id }) { selectedProjectID = result.project.id; selectedThreadID = thread.id; showArchived = false }
        return result
    }
    func cloneRepository(source: String, destination: URL) async throws {
        let plan = try GitClonePlan.prepare(source: source, destination: destination)
        var project = WorkspaceProject(path: plan.destinationPath); project.clone = .init(plan: plan)
        let thread = CodingThread(project: project)
        _ = try await enqueue(.startProjectClone(project: project, thread: thread)).value
        if snapshot.threads.contains(where: { $0.id == thread.id }) { selectedProjectID = project.id; selectedThreadID = thread.id; showArchived = false }
    }
    func cancelProjectClone(_ projectID: UUID) { sendCommand(.cancelProjectClone(projectID)) }
    func retryProjectClone(_ projectID: UUID) {
        guard !terminating, snapshot.projects.first(where: { $0.id == projectID })?.clone?.canRetry == true,
              retryingProjectClones.insert(projectID).inserted else { return }
        projectCloneRetryTasks[projectID] = Task {
            defer { retryingProjectClones.remove(projectID); projectCloneRetryTasks.removeValue(forKey: projectID) }
            guard let engine else { return }
            do { _ = try await engine.retryProjectClone(projectID); apply(await engine.current()) }
            catch { if !terminating, snapshot.projects.contains(where: { $0.id == projectID }) { errorMessage = GitService.redactURLs(error.localizedDescription) } }
        }
    }
    func isRetryingProjectClone(_ projectID: UUID) -> Bool { retryingProjectClones.contains(projectID) }
    func newThread(projectID: UUID? = nil) {
        let project: WorkspaceProject
        if let projectID {
            // A stale checkout menu must never redirect its action to another workspace.
            guard let selected = snapshot.projects.first(where: { $0.id == projectID }) else { return }
            project = selected
        } else if let currentID = selectedProjectID ?? selectedThread?.projectID,
                  let group = projectGroup(containing: currentID), let selected = preferredProject(in: group) {
            project = selected
        } else if let selected = snapshot.projects.first { project = selected }
        else { addProject(); return }
        let thread = CodingThread(project: project)
        let task = enqueue(.createThread(thread))
        Task {
            do {
                _ = try await task.value
                guard self.thread(thread.id) != nil else { return }
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
        guard !terminating, thread(id) != nil else { return }
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
            guard thread(id) != nil else { continue }
            let task = enqueue(.editThread(id, .draft(text)))
            Task {
                do { _ = try await task.value; if draftOverrides[id] == text { draftOverrides.removeValue(forKey: id) } }
                catch { if !terminating, thread(id) != nil { errorMessage = error.localizedDescription } }
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
        guard !terminating, let engine, thread(threadID) != nil else { return }
        guard files.count + providers.count <= AttachmentLimits.count else { errorMessage = "Attach up to 100 files per message."; return }
        let taskID = UUID()
        attachmentImportOwners[taskID] = threadID
        attachmentImportCounts[threadID, default: 0] += 1
        attachmentImportTasks[taskID] = Task {
            defer {
                let remaining = attachmentImportCounts[threadID, default: 1] - 1
                attachmentImportCounts[threadID] = remaining > 0 ? remaining : nil
                attachmentImportTasks.removeValue(forKey: taskID)
                attachmentImportOwners.removeValue(forKey: taskID)
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
            guard !terminating, !Task.isCancelled, thread(threadID) != nil else { return }
            if !references.isEmpty {
                do { _ = try await enqueue(.addAttachments(threadID: threadID, attachments: references)).value }
                catch { errors.append(error.localizedDescription) }
            }
            if !errors.isEmpty, thread(threadID) != nil { errorMessage = errors.joined(separator: "\n") }
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
                guard self.thread(id) != nil else { return false }
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
        let normalizedPath = Self.canonicalPath(workspacePath)
        let threads = snapshot.threads.filter { Self.canonicalPath($0.workspacePath) == normalizedPath }
        let projects = snapshot.projects.filter { Self.canonicalPath($0.path) == normalizedPath }
        guard !terminating, canEditWorkspace(workspacePath), !threads.isEmpty || !projects.isEmpty else { return }
        if threads.contains(where: { !workspaceReady(for: $0) }) || projects.contains(where: { $0.clone.map { !$0.isReady } ?? false }) {
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
                let models = try await engine.models(thread: thread)
                guard let current = self.thread(thread.id), current.provider == thread.provider,
                      current.acpAgent == thread.acpAgent, current.workspacePath == thread.workspacePath else { return }
                acpModels[thread.id] = models
            } else { providerModels[kind] = try await engine.models(provider: kind) }
        } catch is CancellationError { }
        catch { if !terminating { errorMessage = error.localizedDescription } }
    }
    /// Completed worktree assignments share the UI command order with confirmations and drafts.
    func setWorkspacePath(_ path: String, threadID: UUID) -> Task<WorkspaceCommandReceipt, any Error> {
        enqueue(.editThread(threadID, .workspacePath(path)))
    }
    func createWorktree(for id: UUID, branch: String) async {
        guard let thread = thread(id), thread.messages.isEmpty, !thread.isBusy, !preparingWorkspaces.contains(id) else {
            errorMessage = "Create the worktree before sending the first message."; return
        }
        guard workspaceReady(for: thread) else { errorMessage = "Wait for cloning to finish before creating a worktree."; return }
        preparingWorkspaces.insert(id); defer { preparingWorkspaces.remove(id) }
        do {
            let parent = worktreesRoot
            try FileManager.default.createDirectory(at: parent, withIntermediateDirectories: true)
            let path = parent.appendingPathComponent(id.uuidString)
            let task = Task { try await GitService(root: URL(fileURLWithPath: thread.workspacePath)).createWorktree(at: path, branch: branch) }
            worktreeTasks[id] = task
            defer { worktreeTasks.removeValue(forKey: id) }
            try await withTaskCancellationHandler { try await task.value } onCancel: { task.cancel() }
            try Task.checkCancellation()
            guard self.thread(id) != nil, !terminating else { return }
            _ = try await setWorkspacePath(path.path, threadID: id).value
        } catch is CancellationError { }
        catch { if self.thread(id) != nil, !terminating { errorMessage = error.localizedDescription } }
    }
    func shutdown() async {
        terminating = true
        let creations = Array(projectCreationTasks.values)
        for task in creations { task.cancel() }
        for task in creations { _ = await task.result }
        let worktrees = Array(worktreeTasks.values); for task in worktrees { task.cancel() }; for task in worktrees { _ = await task.result }
        let retries = Array(projectCloneRetryTasks.values); for task in retries { task.cancel() }; for task in retries { await task.value }
        let inspectors = Array(gitInspectors.values)
        for model in inspectors { model.prepareForShutdown() }
        for model in inspectors { await model.shutdown() }
        let imports = Array(attachmentImportTasks.values); for task in imports { task.cancel() }; for task in imports { await task.value }
        draftSaveTask?.cancel(); flushDrafts()
        await commandTail?.value
        for cleanup in Array(removalCleanupTasks.values) { await cleanup.task.value }
        for terminals in terminalStores.values.compactMap(\.value) { for session in terminals.removeAll() { await session.waitForClose() } }
        await engine?.shutdown()
        updatesTask?.cancel(); updatesTask = nil
    }
}
