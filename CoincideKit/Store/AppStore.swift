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
/// Every thread has a summary in memory (`threadSummaries`), read at launch from a small index
/// (`thread-index.json`) rather than from the thread files, so launch time and memory do not grow with the
/// length of the history. A thread's transcript is read from its file when something needs its items
/// (`thread(_:)`): opening it, running a turn, forking it. Transcripts stay in memory while something holds
/// them (`holdTranscript(_:)`: the open thread, a running turn) or has changes still to write; of the rest,
/// the `transcriptCacheLimit` most recently used stay and older ones leave memory. Lists use the summaries.
///
/// Files are encoded and written on a background queue, each thread at most once at a time, so a
/// long transcript that streams updates never stalls the main thread. After each save a thread waits in
/// proportion to its size, so a long transcript is not rewritten several times a second. Every write is
/// atomic. A file that cannot be read is set aside (`*.unreadable-…`) before anything replaces it, and
/// fields or items this version cannot read are skipped rather than losing the thread. A thread file
/// with such content (written by a newer version, say) is copied aside before its first save, which
/// would drop it.
@MainActor
public final class AppStore {
    public static let shared = AppStore(directory: AppStore.defaultDirectory)

    public private(set) var projects: [Project] = []
    /// Every thread, without its transcript.
    public private(set) var threadSummaries: [UUID: ThreadSummary] = [:]
    public private(set) var settings = AppSettings()

    public let directory: URL
    /// Threads whose transcript is in memory.
    private var loadedThreads: [UUID: ChatThread] = [:]
    /// When each loaded thread was last used, as a running count, to unload the least recently used first.
    private var lastUse: [UUID: UInt64] = [:]
    private var useCount: UInt64 = 0
    /// How many holds keep each thread's transcript in memory (`holdTranscript(_:)`).
    private var holds: [UUID: Int] = [:]
    /// Threads read from a file not named after them; every other thread is `threads/<id>.json`.
    private var sourceFiles: [UUID: URL] = [:]
    /// Further files holding a thread, older than the one it is read from. Deleting the thread deletes them.
    private var staleCopies: [UUID: [URL]] = [:]
    /// How many transcripts stay in memory besides those held or with changes to write, so reopening a
    /// recent thread does not read its file again.
    var transcriptCacheLimit = 8 {
        didSet { unloadIdleTranscripts() }
    }
    /// Transcripts read from disk so far, and summaries read from thread files at launch because the index
    /// did not cover them. For tests and measurements.
    private(set) var transcriptReads = 0
    private(set) var summaryReads = 0
    /// Handlers in registration order, so every change reaches observers in a fixed order.
    private var observers: [(id: UUID, handler: (StoreChange) -> Void)] = []
    private var pendingThreadSaves: Set<UUID> = []
    /// Threads whose write is on the save queue or cooling down after it, with the number of that write;
    /// newer changes wait for it.
    private var threadsBeingSaved: [UUID: Int] = [:]
    private var writeCount = 0
    private var saveScheduled = false
    /// Threads whose file an earlier run (or another version) wrote and that were not saved since. Before the
    /// first save replaces such a file, the file is checked for content this version could not read and, if
    /// it has some, copied aside. Their items left running or waiting can no longer finish, so they are
    /// settled as the transcript is read.
    private var filesFromEarlierRuns: Set<UUID> = []
    private var turnObserver: NSObjectProtocol?
    /// How long changes collect before they are written.
    var saveDelay: TimeInterval = 0.6
    /// How many bytes a thread's saves may write per second while it changes. A save rewrites the whole
    /// transcript, so after each one the thread waits in proportion to its size: a long transcript that
    /// streams updates is saved every few seconds instead of several times a second. The end of a turn and
    /// quitting save at once.
    var saveBytesPerSecond: Double = 2_000_000
    /// How long a thread whose save failed (a full disk, say) waits before trying again. Its transcript
    /// stays in memory meanwhile.
    var failedSaveRetryDelay: TimeInterval = 5
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
        // A finished turn is worth keeping at once, whatever the thread's cool-down after its last save.
        turnObserver = NotificationCenter.default.addObserver(
            forName: ThreadRunner.turnFinishedNotification, object: nil, queue: .main
        ) { [weak self] note in
            guard let threadID = note.userInfo?["threadID"] as? UUID else { return }
            MainActor.assumeIsolated { self?.saveNow(threadID) }
        }
    }

    isolated deinit {
        if let turnObserver { NotificationCenter.default.removeObserver(turnObserver) }
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
        for thread in threadSummaries.values where thread.projectID == id {
            removeThread(thread.id, deletingFile: true)
        }
        saveProjects()
        notify(.projects)
        notify(.threadList)
    }

    public func project(_ id: UUID) -> Project? { projects.first { $0.id == id } }

    // MARK: Threads

    /// Threads of a project, pinned first, then most recently updated. Archived threads are excluded unless asked for.
    public func threads(in projectID: UUID, includeArchived: Bool = false) -> [ThreadSummary] {
        threadSummaries.values
            .filter { $0.projectID == projectID && (includeArchived || !$0.isArchived) }
            .sorted { lhs, rhs in
                if lhs.isPinned != rhs.isPinned { return lhs.isPinned }
                return lhs.updatedAt > rhs.updatedAt
            }
    }

    /// All threads across projects, most recently updated first.
    public var recentThreads: [ThreadSummary] {
        threadSummaries.values.filter { !$0.isArchived }.sorted { $0.updatedAt > $1.updatedAt }
    }

    /// A thread's metadata, without reading its transcript.
    public func summary(_ id: UUID) -> ThreadSummary? { threadSummaries[id] }

    public func hasThread(_ id: UUID) -> Bool { threadSummaries[id] != nil }

    /// A thread with its transcript. One that is not in memory is read from its file first, which takes a
    /// moment for a long transcript, so code that only needs metadata uses `summary(_:)` instead.
    public func thread(_ id: UUID) -> ChatThread? {
        guard let thread = loadedThreads[id] else { return readTranscript(id) }
        markUsed(id)
        return thread
    }

    /// Keeps a thread's transcript in memory for as long as the returned hold is alive: the thread on screen,
    /// one running a turn. Holds do not read the transcript; `thread(_:)` does that when it is needed.
    public func holdTranscript(_ id: UUID) -> TranscriptHold {
        holds[id, default: 0] += 1
        return TranscriptHold { [weak self] in self?.releaseHold(id) }
    }

    /// Whether the thread's transcript is in memory.
    func isTranscriptLoaded(_ id: UUID) -> Bool { loadedThreads[id] != nil }

    /// How many transcripts are in memory.
    var loadedTranscriptCount: Int { loadedThreads.count }

    /// Working directory for a thread: its worktree when it has one, otherwise the project folder.
    public func workingDirectory(for threadID: UUID) -> URL? {
        guard let thread = threadSummaries[threadID] else { return nil }
        if let worktree = thread.worktreePath { return URL(fileURLWithPath: worktree) }
        return project(thread.projectID)?.url
    }

    @discardableResult
    public func createThread(in projectID: UUID, selection: ModelSelection? = nil) -> ChatThread {
        let thread = ChatThread(
            projectID: projectID, selection: selection ?? settings.defaultSelection,
            accessMode: settings.defaultAccessMode)
        loadedThreads[thread.id] = thread
        threadSummaries[thread.id] = ThreadSummary(thread)
        markUsed(thread.id)
        scheduleSave(thread.id)
        notify(.threadList)
        return thread
    }

    /// Changes thread metadata. Use `append` / `updateItem` for transcript changes.
    public func updateThread(_ id: UUID, touch: Bool = false, _ mutate: (inout ChatThread) -> Void) {
        guard var thread = thread(id) else { return }
        let before = (thread.title, thread.isPinned, thread.isArchived, thread.branch, thread.worktreePath)
        mutate(&thread)
        if touch { thread.updatedAt = Date() }
        loadedThreads[id] = thread
        threadSummaries[id] = ThreadSummary(thread)
        scheduleSave(id)
        notify(.thread(id))
        let after = (thread.title, thread.isPinned, thread.isArchived, thread.branch, thread.worktreePath)
        if touch || before != after { notify(.threadList) }
    }

    /// Appends a transcript item and returns its id.
    @discardableResult
    public func append(_ item: TranscriptItem, to threadID: UUID) -> UUID {
        guard loadIfNeeded(threadID) else { return item.id }
        let now = Date()
        // Changed in place, so a long transcript is not copied.
        loadedThreads[threadID]?.items.append(item)
        loadedThreads[threadID]?.updatedAt = now
        threadSummaries[threadID]?.noteAppended(item, at: now)
        scheduleSave(threadID)
        notify(.items(threadID, changed: [item.id], appended: true))
        return item.id
    }

    /// Mutates one transcript item in place.
    public func updateItem(_ itemID: UUID, in threadID: UUID, _ mutate: (inout TranscriptItem) -> Void) {
        // Streaming updates almost always touch one of the newest items, so search from the end.
        guard loadIfNeeded(threadID), let index = loadedThreads[threadID]?.items.lastIndex(where: { $0.id == itemID })
        else { return }
        let kind = loadedThreads[threadID]!.items[index].kind
        mutate(&loadedThreads[threadID]!.items[index])
        if loadedThreads[threadID]!.items[index].kind != kind { refreshSummary(threadID) }
        scheduleSave(threadID)
        notify(.items(threadID, changed: [itemID], appended: false))
    }

    public func item(_ itemID: UUID, in threadID: UUID) -> TranscriptItem? {
        guard loadIfNeeded(threadID) else { return nil }
        return loadedThreads[threadID]?.items.last { $0.id == itemID }
    }

    public func deleteThread(_ id: UUID) {
        removeThread(id, deletingFile: true)
        notify(.threadList)
    }

    /// Removes the transcript from (and including) the given item, so the user can edit and resend
    /// or revert to a checkpoint.
    public func truncate(_ threadID: UUID, from itemID: UUID) {
        guard loadIfNeeded(threadID), let index = loadedThreads[threadID]?.items.firstIndex(where: { $0.id == itemID })
        else { return }
        loadedThreads[threadID]?.items.removeSubrange(index...)
        // Native sessions have seen the removed turns, so they cannot be resumed faithfully.
        loadedThreads[threadID]?.sessions = [:]
        refreshSummary(threadID)
        scheduleSave(threadID)
        notify(.thread(threadID))
        notify(.items(threadID, changed: [], appended: false))
    }

    // MARK: Transcripts in memory

    /// Whether the thread's transcript is in memory, reading it first when it is not.
    private func loadIfNeeded(_ id: UUID) -> Bool {
        if loadedThreads[id] != nil {
            markUsed(id)
            return true
        }
        return readTranscript(id) != nil
    }

    /// Reads a known thread's transcript from its file. A file that is gone or cannot be read (it is set
    /// aside then) drops the thread from the list.
    private func readTranscript(_ id: UUID) -> ChatThread? {
        guard threadSummaries[id] != nil else { return nil }
        transcriptReads += 1
        guard let file = Self.read(ThreadFile.self, from: sourceFiles[id] ?? threadURL(id), decoder: StoreWriter.makeDecoder()),
            file.thread.id == id
        else {
            NSLog("Coincide: the file of thread \(id.uuidString) is missing or unreadable")
            removeThread(id, deletingFile: false)
            notify(.threadList)
            return nil
        }
        var thread = file.thread
        if filesFromEarlierRuns.contains(id) { Self.settleUnfinishedItems(of: &thread) }
        loadedThreads[id] = thread
        markUsed(id)
        unloadIdleTranscripts(keeping: id)
        return thread
    }

    /// Anything left running when an earlier run quit can no longer finish.
    private static func settleUnfinishedItems(of thread: inout ChatThread) {
        for index in thread.items.indices
        where thread.items[index].status == .running || thread.items[index].status == .waiting {
            let kind = thread.items[index].kind
            thread.items[index].status = kind == .approval || kind == .question ? .declined : .failed
        }
    }

    private func markUsed(_ id: UUID) {
        useCount += 1
        lastUse[id] = useCount
    }

    private func refreshSummary(_ id: UUID) {
        if let thread = loadedThreads[id] { threadSummaries[id] = ThreadSummary(thread) }
    }

    private func releaseHold(_ id: UUID) {
        guard let count = holds[id] else { return }
        holds[id] = count > 1 ? count - 1 : nil
        if holds[id] == nil { unloadIdleTranscripts() }
    }

    /// A transcript can leave memory once nothing holds it and all of it is on disk.
    private func canUnload(_ id: UUID) -> Bool {
        holds[id] == nil && !pendingThreadSaves.contains(id) && threadsBeingSaved[id] == nil
    }

    /// Unloads the least recently used transcripts that can leave memory, beyond `transcriptCacheLimit` of
    /// them. `kept` stays in any case: the transcript just read for a caller.
    private func unloadIdleTranscripts(keeping kept: UUID? = nil) {
        let idle = loadedThreads.keys.filter(canUnload)
        let excess = idle.count - max(transcriptCacheLimit, 0)
        guard excess > 0 else { return }
        let oldestFirst = idle.filter { $0 != kept }.sorted { lastUse[$0, default: 0] < lastUse[$1, default: 0] }
        for id in oldestFirst.prefix(excess) {
            loadedThreads[id] = nil
            lastUse[id] = nil
        }
    }

    /// Forgets a thread, deleting its file unless it is already gone or set aside.
    private func removeThread(_ id: UUID, deletingFile: Bool) {
        threadSummaries[id] = nil
        loadedThreads[id] = nil
        lastUse[id] = nil
        pendingThreadSaves.remove(id)
        filesFromEarlierRuns.remove(id)
        let source = sourceFiles.removeValue(forKey: id)
        let copies = staleCopies.removeValue(forKey: id) ?? []
        if deletingFile {
            for url in [threadURL(id)] + [source].compactMap(\.self) + copies { writer.remove(url) }
        } else {
            writer.forget(source ?? threadURL(id))
        }
    }

    // MARK: Settings

    public func updateSettings(_ mutate: (inout AppSettings) -> Void) {
        mutate(&settings)
        ACPAgentNames.shared.register(settings.acpAgents)
        writer.write(settings, to: settingsURL)
        notify(.settings)
    }

    // MARK: Persistence

    /// Writes every pending change and waits until it is on disk. Call before quitting.
    public func flush() {
        startPendingSaves(waitingForBusyThreads: true)
        writer.writeIndexNow()
        writer.waitUntilIdle()
    }

    /// Starts writing a thread's pending changes now, even while it cools down after its last save.
    /// Runs at the end of every turn (`ThreadRunner.turnFinishedNotification`).
    public func saveNow(_ id: UUID) {
        guard pendingThreadSaves.remove(id) != nil else { return }
        startSave(id)
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

    /// Hands pending threads to the writer. A thread whose previous write is still running or cooling
    /// down waits for it (unless `waitingForBusyThreads`, when quitting), so slow writes never pile up
    /// copies and a long transcript is not rewritten several times a second.
    private func startPendingSaves(waitingForBusyThreads: Bool) {
        for id in pendingThreadSaves {
            if threadsBeingSaved[id] != nil && !waitingForBusyThreads { continue }
            pendingThreadSaves.remove(id)
            startSave(id)
        }
    }

    /// Writes one thread. It counts as busy until the write is done and a cool-down in proportion to the
    /// bytes written has passed (`saveBytesPerSecond`); a newer write of the same thread takes over. A write
    /// that fails leaves the thread with changes to save, tried again after `failedSaveRetryDelay`.
    private func startSave(_ id: UUID) {
        guard let thread = loadedThreads[id] else { return }
        writeCount += 1
        let write = writeCount
        threadsBeingSaved[id] = write
        let url = threadURL(id)
        if filesFromEarlierRuns.remove(id) != nil { writer.preserveIfPartlyUnreadable(url) }
        // From now on the thread is read from the file named after it.
        if let source = sourceFiles.removeValue(forKey: id) { staleCopies[id, default: []].append(source) }
        let bytesPerSecond = max(saveBytesPerSecond, 1)
        let retryDelay = failedSaveRetryDelay
        writer.writeThread(thread, summary: ThreadSummary(thread), to: url) { [weak self] bytes, saved in
            DispatchQueue.main.asyncAfter(deadline: .now() + (saved ? Double(bytes) / bytesPerSecond : retryDelay)) {
                MainActor.assumeIsolated {
                    guard let self else { return }
                    if !saved, self.loadedThreads[id] != nil { self.pendingThreadSaves.insert(id) }
                    guard self.threadsBeingSaved[id] == write else { return }
                    self.threadsBeingSaved[id] = nil
                    if self.pendingThreadSaves.contains(id) { self.scheduleFlush(after: self.saveDelay) }
                    self.unloadIdleTranscripts()
                }
            }
        }
    }

    private var threadsDirectory: URL { directory.appendingPathComponent("threads", isDirectory: true) }
    private var settingsURL: URL { directory.appendingPathComponent("settings.json") }
    private var projectsURL: URL { directory.appendingPathComponent("projects.json") }
    private var indexURL: URL { directory.appendingPathComponent("thread-index.json") }

    private func threadURL(_ id: UUID) -> URL { threadsDirectory.appendingPathComponent("\(id.uuidString).json") }

    private func saveProjects() {
        writer.write(projects, to: projectsURL)
    }

    private func load() {
        try? FileManager.default.createDirectory(at: threadsDirectory, withIntermediateDirectories: true)
        let decoder = StoreWriter.makeDecoder()
        if let value = Self.read(AppSettings.self, from: settingsURL, decoder: decoder) { settings = value }
        ACPAgentNames.shared.register(settings.acpAgents)
        if let value = Self.read(LenientList<Project>.self, from: projectsURL, decoder: decoder) {
            projects = value.elements
            if value.skipped > 0 { Self.setAside(projectsURL, copy: true) }
        }
        loadThreadSummaries()
    }

    /// Lists every thread from the index, reading the summary of each thread file the index does not cover
    /// as it is now (all of them when there is no index yet, such as the first launch of this version).
    private func loadThreadSummaries() {
        let files = (try? FileManager.default.contentsOfDirectory(at: threadsDirectory, includingPropertiesForKeys: nil)) ?? []
        let threadFiles = files.filter { $0.pathExtension == "json" }
        let index = Self.readIndex(at: indexURL)
        var entries: [String: ThreadIndexEntry] = [:]
        var unindexed: [(url: URL, stamp: FileStamp)] = []
        for url in threadFiles {
            guard let stamp = FileStamp(of: url) else { continue }
            if let entry = index?[url.lastPathComponent], entry.stamp == stamp {
                entries[entry.file] = entry
            } else {
                unindexed.append((url, stamp))
            }
        }
        let indexed = entries.count
        // Summaries are read in parallel: with many long transcripts this is most of such a launch.
        let toRead = unindexed
        let read = ParallelSlots<ThreadIndexEntry>(count: toRead.count)
        DispatchQueue.concurrentPerform(iterations: toRead.count) { index in
            let (url, stamp) = toRead[index]
            guard let file = Self.read(ThreadSummaryFile.self, from: url, decoder: StoreWriter.makeDecoder()) else { return }
            read.set(index, ThreadIndexEntry(file: url.lastPathComponent, stamp: stamp, summary: file.summary))
        }
        summaryReads = unindexed.count
        for entry in read.values { entries[entry.file] = entry }
        // A thread found in more than one file is read from the one named after it.
        for entry in entries.values.sorted(by: { $0.file < $1.file }) {
            let id = entry.summary.id
            let url = threadsDirectory.appendingPathComponent(entry.file)
            let canonical = "\(id.uuidString).json"
            if threadSummaries[id] != nil, entry.file != canonical {
                staleCopies[id, default: []].append(url)
                continue
            }
            if let previous = sourceFiles.removeValue(forKey: id) { staleCopies[id, default: []].append(previous) }
            threadSummaries[id] = entry.summary
            if entry.file != canonical { sourceFiles[id] = url }
        }
        filesFromEarlierRuns = Set(threadSummaries.keys)
        let changed = index == nil || !unindexed.isEmpty || index?.count != indexed
        writer.startIndex(at: indexURL, entries: entries, write: changed)
    }

    /// The index's entries by file name, or nil when there is none this version can use. It only caches the
    /// thread files, so one that cannot be read is rebuilt rather than set aside.
    private nonisolated static func readIndex(at url: URL) -> [String: ThreadIndexEntry]? {
        guard let data = try? Data(contentsOf: url) else { return nil }
        do {
            let file = try StoreWriter.makeDecoder().decode(ThreadIndexFile.self, from: data)
            guard file.version == ThreadIndexFile.currentVersion else { return nil }
            return Dictionary(file.entries.map { ($0.file, $0) }) { _, last in last }
        } catch {
            NSLog("Coincide: rebuilding \(url.lastPathComponent), which could not be read: \(error)")
            return nil
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
    fileprivate nonisolated static func setAside(_ url: URL, copy: Bool) {
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
///
/// It also keeps the thread index (`ThreadIndexFile`): each thread write records the summary it wrote and
/// the file's new stamp, and the index is written a little later, so a burst of saves writes it once.
private final class StoreWriter: @unchecked Sendable {
    private let queue = DispatchQueue(label: "com.apoorvdarshan.coincide.store", qos: .utility)
    private let encoder: JSONEncoder = {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.sortedKeys]
        return encoder
    }()
    /// How long index changes collect before the index is written.
    private let indexDelay: TimeInterval = 2
    // Used on the queue only.
    private var indexURL: URL?
    private var indexEntries: [String: ThreadIndexEntry] = [:]
    private var indexChanged = false
    private var indexWriteScheduled = false

    nonisolated static func makeDecoder() -> JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }

    /// `completion` gets the number of bytes encoded (0 when encoding failed).
    nonisolated func write<T: Encodable & Sendable>(
        _ value: T, to url: URL, completion: (@Sendable (_ bytes: Int) -> Void)? = nil
    ) {
        queue.async {
            let (bytes, _) = self.encodeAndWrite(value, to: url)
            completion?(bytes)
        }
    }

    /// Writes a thread and records it in the index. `completion` gets the number of bytes encoded and
    /// whether the file was written.
    nonisolated func writeThread(
        _ thread: ChatThread, summary: ThreadSummary, to url: URL,
        completion: @escaping @Sendable (_ bytes: Int, _ saved: Bool) -> Void
    ) {
        queue.async {
            let (bytes, saved) = self.encodeAndWrite(thread, to: url)
            if saved, let stamp = FileStamp(of: url) {
                self.indexEntries[url.lastPathComponent] = ThreadIndexEntry(file: url.lastPathComponent, stamp: stamp, summary: summary)
                self.noteIndexChange()
            }
            completion(bytes, saved)
        }
    }

    private nonisolated func encodeAndWrite<T: Encodable>(_ value: T, to url: URL) -> (bytes: Int, saved: Bool) {
        var bytes = 0
        do {
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            let data = try encoder.encode(value)
            bytes = data.count
            try data.write(to: url, options: .atomic)
            return (bytes, true)
        } catch {
            NSLog("Coincide: failed to save \(url.lastPathComponent): \(error)")
            return (bytes, false)
        }
    }

    /// Deletes a thread file and its index entry.
    nonisolated func remove(_ url: URL) {
        queue.async {
            try? FileManager.default.removeItem(at: url)
            self.dropIndexEntry(url)
        }
    }

    /// Drops a thread file's index entry, leaving the file alone.
    nonisolated func forget(_ url: URL) {
        queue.async { self.dropIndexEntry(url) }
    }

    private nonisolated func dropIndexEntry(_ url: URL) {
        guard indexEntries.removeValue(forKey: url.lastPathComponent) != nil else { return }
        noteIndexChange()
    }

    /// Takes over the index read at launch, writing it soon when it did not match the files.
    nonisolated func startIndex(at url: URL, entries: [String: ThreadIndexEntry], write: Bool) {
        queue.async {
            self.indexURL = url
            self.indexEntries = entries
            if write { self.noteIndexChange() }
        }
    }

    /// Writes the index now if it changed, rather than after the delay.
    nonisolated func writeIndexNow() {
        queue.async { self.writeIndexIfChanged() }
    }

    private nonisolated func noteIndexChange() {
        indexChanged = true
        guard !indexWriteScheduled else { return }
        indexWriteScheduled = true
        queue.asyncAfter(deadline: .now() + indexDelay) {
            self.indexWriteScheduled = false
            self.writeIndexIfChanged()
        }
    }

    private nonisolated func writeIndexIfChanged() {
        guard indexChanged, let indexURL else { return }
        indexChanged = false
        let file = ThreadIndexFile(entries: indexEntries.values.sorted { $0.file < $1.file })
        _ = encodeAndWrite(file, to: indexURL)
    }

    /// Copies a thread file aside (see `AppStore.setAside`) when it holds something this version could not
    /// read, or cannot be read at all, so the write queued after this cannot lose it.
    nonisolated func preserveIfPartlyUnreadable(_ url: URL) {
        queue.async {
            guard let data = try? Data(contentsOf: url) else { return }
            let decoder = Self.makeDecoder()
            decoder.userInfo[.checksUnreadContent] = true
            let unread = (try? decoder.decode(ThreadFile.self, from: data))?.hasUnreadContent ?? true
            if unread { AppStore.setAside(url, copy: true) }
        }
    }

    nonisolated func waitUntilIdle() {
        queue.sync {}
    }
}

/// An array whose unreadable elements are skipped and counted.
struct LenientList<Element: Decodable>: Decodable {
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

/// Results of work done in parallel, one slot per task.
private final class ParallelSlots<Value>: @unchecked Sendable {
    private let lock = NSLock()
    private var slots: [Value?]

    nonisolated init(count: Int) {
        slots = Array(repeating: nil, count: count)
    }

    nonisolated func set(_ index: Int, _ value: Value?) {
        lock.withLock { slots[index] = value }
    }

    nonisolated var values: [Value] { lock.withLock { slots.compactMap { $0 } } }
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

/// Keeps a thread's transcript in memory until released (`AppStore.holdTranscript(_:)`).
@MainActor
public final class TranscriptHold {
    private let release: () -> Void

    init(release: @escaping () -> Void) {
        self.release = release
    }

    isolated deinit {
        release()
    }
}
