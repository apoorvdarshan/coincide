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
///
/// Files are encoded and written on a background queue, each thread at most once at a time, so a
/// long transcript that streams updates never stalls the main thread. Every write is atomic. A file
/// that cannot be read is set aside (`*.unreadable-…`) before anything replaces it, and fields or items
/// this version cannot read are skipped rather than losing the thread.
@MainActor
public final class AppStore {
    public static let shared = AppStore(directory: AppStore.defaultDirectory)

    public private(set) var projects: [Project] = []
    public private(set) var threads: [UUID: ChatThread] = [:]
    public private(set) var settings = AppSettings()

    public let directory: URL
    /// Handlers in registration order, so every change reaches observers in a fixed order.
    private var observers: [(id: UUID, handler: (StoreChange) -> Void)] = []
    private var pendingThreadSaves: Set<UUID> = []
    /// Threads whose write is on the save queue; a newer change waits for it.
    private var threadsBeingSaved: Set<UUID> = []
    private var saveScheduled = false
    /// How long changes collect before they are written.
    var saveDelay: TimeInterval = 0.6
    private let writer = StoreWriter()

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
    /// Handlers run in the order they were registered.
    public func observe(_ handler: @escaping (StoreChange) -> Void) -> ObservationToken {
        let id = UUID()
        observers.append((id, handler))
        return ObservationToken { [weak self] in self?.observers.removeAll { $0.id == id } }
    }

    public func notify(_ change: StoreChange) {
        for observer in observers { observer.handler(change) }
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

    /// Points a project at its folder's new location. A name that was the old folder's follows the new one.
    /// Live agent sessions of its threads still run in the old folder; the caller shuts them down
    /// (`ThreadRunner.shutdown(threadID:)`).
    public func relocateProject(_ id: UUID, to url: URL) {
        let path = url.standardizedFileURL.path
        updateProject(id) { project in
            if project.name == (project.path as NSString).lastPathComponent { project.name = url.lastPathComponent }
            project.path = path
        }
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
        // Streaming updates almost always touch one of the newest items, so search from the end.
        guard let index = threads[threadID]?.items.lastIndex(where: { $0.id == itemID }) else { return }
        mutate(&threads[threadID]!.items[index])
        scheduleSave(threadID)
        notify(.items(threadID, changed: [itemID], appended: false))
    }

    public func item(_ itemID: UUID, in threadID: UUID) -> TranscriptItem? {
        threads[threadID]?.items.last { $0.id == itemID }
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
        writer.write(settings, to: settingsURL)
        notify(.settings)
    }

    // MARK: Persistence

    /// Writes every pending change and waits until it is on disk. Call before quitting.
    public func flush() {
        startPendingSaves(waitingForBusyThreads: true)
        writer.waitUntilIdle()
    }

    private func scheduleSave(_ id: UUID) {
        pendingThreadSaves.insert(id)
        scheduleFlush(after: saveDelay)
    }

    private func scheduleFlush(after delay: TimeInterval) {
        guard !saveScheduled else { return }
        saveScheduled = true
        DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in
            MainActor.assumeIsolated {
                guard let self else { return }
                self.saveScheduled = false
                self.startPendingSaves(waitingForBusyThreads: false)
            }
        }
    }

    /// Hands pending threads to the writer. A thread whose previous write is still running waits for
    /// it (unless `waitingForBusyThreads`, when quitting), so slow writes never pile up copies.
    private func startPendingSaves(waitingForBusyThreads: Bool) {
        for id in pendingThreadSaves {
            if threadsBeingSaved.contains(id) && !waitingForBusyThreads { continue }
            pendingThreadSaves.remove(id)
            guard let thread = threads[id] else { continue }
            threadsBeingSaved.insert(id)
            writer.write(thread, to: threadURL(id)) { [weak self] in
                DispatchQueue.main.async {
                    MainActor.assumeIsolated {
                        guard let self else { return }
                        self.threadsBeingSaved.remove(id)
                        if self.pendingThreadSaves.contains(id) { self.scheduleFlush(after: self.saveDelay) }
                    }
                }
            }
        }
    }

    private var threadsDirectory: URL { directory.appendingPathComponent("threads", isDirectory: true) }
    private var settingsURL: URL { directory.appendingPathComponent("settings.json") }
    private var projectsURL: URL { directory.appendingPathComponent("projects.json") }

    private func threadURL(_ id: UUID) -> URL { threadsDirectory.appendingPathComponent("\(id.uuidString).json") }

    private func deleteThreadFile(_ id: UUID) {
        pendingThreadSaves.remove(id)
        writer.remove(threadURL(id))
    }

    private func saveProjects() {
        writer.write(projects, to: projectsURL)
    }

    private func load() {
        try? FileManager.default.createDirectory(at: threadsDirectory, withIntermediateDirectories: true)
        let decoder = StoreWriter.makeDecoder()
        if let value = Self.read(AppSettings.self, from: settingsURL, decoder: decoder) { settings = value }
        if let value = Self.read(LenientList<Project>.self, from: projectsURL, decoder: decoder) {
            projects = value.elements
            if value.skipped > 0 { Self.setAside(projectsURL, copy: true) }
        }
        let files = (try? FileManager.default.contentsOfDirectory(at: threadsDirectory, includingPropertiesForKeys: nil)) ?? []
        let threadFiles = files.filter { $0.pathExtension == "json" }
        // Threads decode in parallel: with many long transcripts this is most of the launch time.
        let loaded = LoadedThreads(count: threadFiles.count)
        DispatchQueue.concurrentPerform(iterations: threadFiles.count) { index in
            loaded.set(index, Self.read(ChatThread.self, from: threadFiles[index], decoder: StoreWriter.makeDecoder()))
        }
        for var thread in loaded.values {
            // Anything left running when the app quit can no longer finish.
            for index in thread.items.indices
            where thread.items[index].status == .running || thread.items[index].status == .waiting {
                let kind = thread.items[index].kind
                thread.items[index].status = kind == .approval || kind == .question ? .declined : .failed
            }
            threads[thread.id] = thread
        }
    }

    /// Decodes a file. One that exists but cannot be read is set aside, so a later save cannot replace
    /// the only copy of the user's data.
    private nonisolated static func read<T: Decodable>(_ type: T.Type, from url: URL, decoder: JSONDecoder) -> T? {
        guard let data = try? Data(contentsOf: url) else { return nil }
        do {
            return try decoder.decode(type, from: data)
        } catch {
            NSLog("Coincide: could not read \(url.lastPathComponent): \(error)")
            setAside(url, copy: false)
            return nil
        }
    }

    /// Moves (or copies) an unreadable file next to itself under a dated name that is no longer loaded.
    private nonisolated static func setAside(_ url: URL, copy: Bool) {
        let stamp = ISO8601DateFormatter().string(from: Date()).replacingOccurrences(of: ":", with: "-")
        let target = url.appendingPathExtension("unreadable-\(stamp)")
        if copy {
            try? FileManager.default.copyItem(at: url, to: target)
        } else {
            try? FileManager.default.moveItem(at: url, to: target)
        }
    }
}

/// Encodes and writes the store's files on one serial queue, so writes of the same file land in order.
private final class StoreWriter: @unchecked Sendable {
    private let queue = DispatchQueue(label: "com.apoorvdarshan.coincide.store", qos: .utility)
    private let encoder: JSONEncoder = {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.sortedKeys]
        return encoder
    }()

    nonisolated static func makeDecoder() -> JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }

    nonisolated func write<T: Encodable & Sendable>(_ value: T, to url: URL, completion: (@Sendable () -> Void)? = nil) {
        queue.async { [encoder] in
            do {
                try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
                let data = try encoder.encode(value)
                try data.write(to: url, options: .atomic)
            } catch {
                NSLog("Coincide: failed to save \(url.lastPathComponent): \(error)")
            }
            completion?()
        }
    }

    nonisolated func remove(_ url: URL) {
        queue.async { try? FileManager.default.removeItem(at: url) }
    }

    nonisolated func waitUntilIdle() {
        queue.sync {}
    }
}

/// An array whose unreadable elements are skipped and counted.
private struct LenientList<Element: Decodable>: Decodable {
    var elements: [Element] = []
    var skipped = 0

    nonisolated init(from decoder: Decoder) throws {
        var container = try decoder.unkeyedContainer()
        while !container.isAtEnd {
            if let element = try? container.decode(Element.self) {
                elements.append(element)
            } else if (try? container.decode(JSONValue.self)) != nil {
                skipped += 1
            } else {
                break
            }
        }
    }
}

/// Results of decoding thread files in parallel.
private final class LoadedThreads: @unchecked Sendable {
    private let lock = NSLock()
    private var slots: [ChatThread?]

    nonisolated init(count: Int) {
        slots = Array(repeating: nil, count: count)
    }

    nonisolated func set(_ index: Int, _ thread: ChatThread?) {
        lock.withLock { slots[index] = thread }
    }

    nonisolated var values: [ChatThread] { lock.withLock { slots.compactMap { $0 } } }
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
