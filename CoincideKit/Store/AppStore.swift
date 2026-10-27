import Foundation

public enum StoreChange: Sendable, Equatable {
    case projects
    case threadList
    /// Thread metadata such as title, model or access mode.
    case thread(UUID)
    /// Transcript items changed. `appended` is true when items were only added at the end.
    /// An empty `changed` list with `appended == false` means "reload everything".
    case items(UUID, changed: [UUID], appended: Bool)
    /// A turn started, finished, or its usage changed.
    case runState(UUID)
    case settings
    case providers
}

/// Owns projects, threads and settings, persists them as JSON, and tells observers what changed.
@MainActor
public final class AppStore {
    public static let shared = AppStore(directory: AppStore.defaultDirectory)

    public private(set) var projects: [Project] = []
    public private(set) var threads: [UUID: ChatThread] = [:]
    public private(set) var settings = AppSettings()

    public let directory: URL
    private var observers: [UUID: (StoreChange) -> Void] = [:]
    private var pendingThreadSaves: Set<UUID> = []
    private var saveScheduled = false

    /// `~/Library/Application Support/Coincide`, or `COINCIDE_DATA_DIR` when set (used for testing).
    public static var defaultDirectory: URL {
        if let override = ProcessInfo.processInfo.environment["COINCIDE_DATA_DIR"], !override.isEmpty {
            return URL(fileURLWithPath: (override as NSString).expandingTildeInPath, isDirectory: true)
        }
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        return base.appendingPathComponent("Coincide", isDirectory: true)
    }

    public init(directory: URL) {
        self.directory = directory
        load()
    }

    // MARK: Observation

    /// Registers a handler for store changes. Keep the token alive for as long as you want updates.
    public func observe(_ handler: @escaping (StoreChange) -> Void) -> ObservationToken {
        let id = UUID()
        observers[id] = handler
        return ObservationToken { [weak self] in self?.observers.removeValue(forKey: id) }
    }

    public func notify(_ change: StoreChange) {
        for handler in Array(observers.values) { handler(change) }
    }

    // MARK: Projects

    @discardableResult
    public func addProject(at url: URL) -> Project {
        let path = url.standardizedFileURL.path
        if let existing = projects.first(where: { $0.path == path }) { return existing }
        let project = Project(name: url.lastPathComponent, path: path)
        projects.append(project)
        saveProjects()
        notify(.projects)
        return project
    }

    public func updateProject(_ id: UUID, _ mutate: (inout Project) -> Void) {
        guard let index = projects.firstIndex(where: { $0.id == id }) else { return }
        mutate(&projects[index])
        saveProjects()
        notify(.projects)
    }

    public func moveProject(from source: Int, to destination: Int) {
        guard projects.indices.contains(source) else { return }
        let project = projects.remove(at: source)
        projects.insert(project, at: min(max(0, destination), projects.count))
        saveProjects()
        notify(.projects)
    }

    public func removeProject(_ id: UUID) {
        projects.removeAll { $0.id == id }
        for thread in threads.values where thread.projectID == id {
            deleteThreadFile(thread.id)
            threads.removeValue(forKey: thread.id)
        }
        saveProjects()
        notify(.projects)
        notify(.threadList)
    }

    public func project(_ id: UUID) -> Project? { projects.first { $0.id == id } }

    // MARK: Threads

    /// Threads of a project, pinned first, then most recently updated. Archived threads are excluded unless asked for.
    public func threads(in projectID: UUID, includeArchived: Bool = false) -> [ChatThread] {
        threads.values
            .filter { $0.projectID == projectID && (includeArchived || !$0.isArchived) }
            .sorted { lhs, rhs in
                if lhs.isPinned != rhs.isPinned { return lhs.isPinned }
                return lhs.updatedAt > rhs.updatedAt
            }
    }

    /// All threads across projects, most recently updated first.
    public var recentThreads: [ChatThread] {
        threads.values.filter { !$0.isArchived }.sorted { $0.updatedAt > $1.updatedAt }
    }

    public func thread(_ id: UUID) -> ChatThread? { threads[id] }

    /// Working directory for a thread: its worktree when it has one, otherwise the project folder.
    public func workingDirectory(for threadID: UUID) -> URL? {
        guard let thread = threads[threadID] else { return nil }
        if let worktree = thread.worktreePath { return URL(fileURLWithPath: worktree) }
        return project(thread.projectID)?.url
    }

    @discardableResult
    public func createThread(in projectID: UUID, selection: ModelSelection? = nil) -> ChatThread {
        let thread = ChatThread(
            projectID: projectID, selection: selection ?? settings.defaultSelection,
            accessMode: settings.defaultAccessMode)
        threads[thread.id] = thread
        scheduleSave(thread.id)
        notify(.threadList)
        return thread
    }

    /// Changes thread metadata. Use `append` / `updateItem` for transcript changes.
    public func updateThread(_ id: UUID, touch: Bool = false, _ mutate: (inout ChatThread) -> Void) {
        guard var thread = threads[id] else { return }
        let before = (thread.title, thread.isPinned, thread.isArchived, thread.branch, thread.worktreePath)
        mutate(&thread)
        if touch { thread.updatedAt = Date() }
        threads[id] = thread
        scheduleSave(id)
        notify(.thread(id))
        let after = (thread.title, thread.isPinned, thread.isArchived, thread.branch, thread.worktreePath)
        if touch || before != after { notify(.threadList) }
    }

    /// Appends a transcript item and returns its id.
    @discardableResult
    public func append(_ item: TranscriptItem, to threadID: UUID) -> UUID {
        guard threads[threadID] != nil else { return item.id }
        threads[threadID]?.items.append(item)
        threads[threadID]?.updatedAt = Date()
        scheduleSave(threadID)
        notify(.items(threadID, changed: [item.id], appended: true))
        return item.id
    }

    /// Mutates one transcript item in place.
    public func updateItem(_ itemID: UUID, in threadID: UUID, _ mutate: (inout TranscriptItem) -> Void) {
        guard let index = threads[threadID]?.items.firstIndex(where: { $0.id == itemID }) else { return }
        mutate(&threads[threadID]!.items[index])
        scheduleSave(threadID)
        notify(.items(threadID, changed: [itemID], appended: false))
    }

    public func item(_ itemID: UUID, in threadID: UUID) -> TranscriptItem? {
        threads[threadID]?.items.first { $0.id == itemID }
    }

    public func deleteThread(_ id: UUID) {
        threads.removeValue(forKey: id)
        deleteThreadFile(id)
        notify(.threadList)
    }

    /// Removes the transcript from (and including) the given item, so the user can edit and resend
    /// or revert to a checkpoint.
    public func truncate(_ threadID: UUID, from itemID: UUID) {
        guard let index = threads[threadID]?.items.firstIndex(where: { $0.id == itemID }) else { return }
        threads[threadID]?.items.removeSubrange(index...)
        // Native sessions have seen the removed turns, so they cannot be resumed faithfully.
        threads[threadID]?.sessions = [:]
        scheduleSave(threadID)
        notify(.thread(threadID))
        notify(.items(threadID, changed: [], appended: false))
    }

    // MARK: Settings

    public func updateSettings(_ mutate: (inout AppSettings) -> Void) {
        mutate(&settings)
        write(settings, to: directory.appendingPathComponent("settings.json"))
        notify(.settings)
    }

    // MARK: Persistence

    /// Writes pending thread changes now. Call before quitting.
    public func flush() {
        let ids = pendingThreadSaves
        pendingThreadSaves.removeAll()
        for id in ids {
            if let thread = threads[id] { write(thread, to: threadURL(id)) }
        }
    }

    private func scheduleSave(_ id: UUID) {
        pendingThreadSaves.insert(id)
        guard !saveScheduled else { return }
        saveScheduled = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) { [weak self] in
            guard let self else { return }
            self.saveScheduled = false
            self.flush()
        }
    }

    private var threadsDirectory: URL { directory.appendingPathComponent("threads", isDirectory: true) }

    private func threadURL(_ id: UUID) -> URL { threadsDirectory.appendingPathComponent("\(id.uuidString).json") }

    private func deleteThreadFile(_ id: UUID) {
        pendingThreadSaves.remove(id)
        try? FileManager.default.removeItem(at: threadURL(id))
    }

    private func saveProjects() {
        write(projects, to: directory.appendingPathComponent("projects.json"))
    }

    private func load() {
        try? FileManager.default.createDirectory(at: threadsDirectory, withIntermediateDirectories: true)
        let decoder = Self.decoder
        if let data = try? Data(contentsOf: directory.appendingPathComponent("settings.json")),
            let value = try? decoder.decode(AppSettings.self, from: data)
        {
            settings = value
        }
        if let data = try? Data(contentsOf: directory.appendingPathComponent("projects.json")),
            let value = try? decoder.decode([Project].self, from: data)
        {
            projects = value
        }
        let files = (try? FileManager.default.contentsOfDirectory(at: threadsDirectory, includingPropertiesForKeys: nil)) ?? []
        for file in files where file.pathExtension == "json" {
            guard let data = try? Data(contentsOf: file), var thread = try? decoder.decode(ChatThread.self, from: data) else {
                continue
            }
            // Anything left running when the app quit can no longer finish.
            for index in thread.items.indices
            where thread.items[index].status == .running || thread.items[index].status == .waiting {
                let kind = thread.items[index].kind
                thread.items[index].status = kind == .approval || kind == .question ? .declined : .failed
            }
            threads[thread.id] = thread
        }
    }

    private func write<T: Encodable>(_ value: T, to url: URL) {
        do {
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            let data = try Self.encoder.encode(value)
            try data.write(to: url, options: .atomic)
        } catch {
            NSLog("Coincide: failed to save \(url.lastPathComponent): \(error)")
        }
    }

    static let encoder: JSONEncoder = {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.sortedKeys]
        return encoder
    }()

    static let decoder: JSONDecoder = {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }()
}

/// Cancels a store observation when released.
@MainActor
public final class ObservationToken {
    private let cancel: () -> Void

    init(cancel: @escaping () -> Void) {
        self.cancel = cancel
    }

    isolated deinit {
        cancel()
    }
}
