import Foundation

/// Native transcript discovery/import only. Neither scanning nor adopting a
/// frozen review launches a provider, authenticates, or changes native files.
public actor AgentSessionScanner {
    private struct FileCandidate: Codable, Sendable { let profile: AgentSessionProfile; let components: [String]; let name: String; let cwd: String; let modified: Date }
    private struct View: Sendable { let id: UUID; let created: Date; let roots: [UUID: AgentSessionDirectory]; let files: [FileCandidate]; let result: AgentSessionScanResult; let bytes: Int }
    private struct Cursor: Sendable {
        let scanID: UUID; let projectID: UUID; let workspace: String; let identity: GitWorktreeNodeIdentity; let completedDigest: String
        var position = 0, filesUsed = 0, records = 0; var bytes: UInt64 = 0; var sessions: Set<String> = []
    }
    private struct Owned: Sendable { let cancel: @Sendable () -> Void; let drain: Task<Void, Never> }
    private struct RetainedPage: Encodable {
        let scanID: UUID, reviews: [AgentSessionImportReview], alreadyImported: [AgentSessionImportSource], duplicates: [AgentSessionImportSource]
        let skippedCount: Int, nextCursor: UUID?, complete: Bool
        init(_ page: AgentSessionImportPage) {
            scanID = page.scanID; reviews = page.reviews; alreadyImported = page.alreadyImported; duplicates = page.duplicates
            skippedCount = page.skippedCount; nextCursor = page.nextCursor; complete = page.complete
        }
    }
    private let profiles: [AgentSessionProfile], home: String, managed: [String]
    private let now: @Sendable () -> Date
    private var views: [UUID: View] = [:], order: [UUID] = [], cursors: [UUID: Cursor] = [:]
    private var pages: [String: AgentSessionImportPage] = [:], operations: [UUID: Owned] = [:]
    private var closing = false
    public init(profiles: [AgentSessionProfile], homeDirectory: String = FileManager.default.homeDirectoryForCurrentUser.path,
                managedWorktreeRoots: [String] = [], excludingWorkspaceRoots: [String] = [], now: @escaping @Sendable () -> Date = { Date() }) throws {
        guard profiles.count <= 64, Set(profiles.map(\.id)).count == profiles.count else { throw AgentSessionImportError.invalidProfile }
        self.profiles = profiles; home = Self.physical(homeDirectory); managed = (managedWorktreeRoots + excludingWorkspaceRoots).map(Self.physical); self.now = now
    }
    public func scan(projects: [WorkspaceProject] = []) async throws -> AgentSessionScanResult {
        guard !closing, operations.count < 2 else { throw AgentSessionImportError.limit }
        let id = UUID(), profiles = profiles, home = home, managed = managed, date = now()
        let task = Task.detached { try Self.discover(id: id, profiles: profiles, projects: projects, home: home, managed: managed, now: date) }
        let operation = own(task, id: id); defer { operations.removeValue(forKey: operation) }
        let view = try await withTaskCancellationHandler { try await task.value } onCancel: { task.cancel() }
        guard !closing else { throw CancellationError() }
        guard view.bytes <= 128 * 1_024 * 1_024 else { throw AgentSessionImportError.limit }
        while let first = order.first {
            let exceedsBytes = try cacheBytes() + view.bytes > 128 * 1_024 * 1_024
            guard order.count >= 4 || exceedsBytes else { break }
            release(scanID: first)
        }
        views[id] = view; order.append(id); return view.result
    }
    public func prepareImport(scanID: UUID, projectID: UUID, expectedWorkspaceRoot: String, cursor: UUID? = nil,
                              completedSources: [AgentSessionImportSource] = []) async throws -> AgentSessionImportPage {
        guard !closing, operations.count < 2, let view = views[scanID] else { throw AgentSessionImportError.staleScan }
        let digest = try AgentSessionImportProtocol.digest(completedSources)
        let key = scanID.uuidString + ":" + projectID.uuidString + ":" + Data(expectedWorkspaceRoot.utf8).base64EncodedString() + ":" + digest + ":" + (cursor?.uuidString ?? "first")
        if let cached = pages[key] { return cached }
        let workspace = try AgentSessionDirectory(path: expectedWorkspaceRoot)
        var state: Cursor
        if let cursor {
            guard let prior = cursors[cursor], prior.scanID == scanID, prior.projectID == projectID,
                  prior.workspace.utf8.elementsEqual(expectedWorkspaceRoot.utf8), prior.identity == workspace.identity,
                  prior.completedDigest == digest else { throw AgentSessionImportError.staleScan }
            state = prior
        } else { state = .init(scanID: scanID, projectID: projectID, workspace: expectedWorkspaceRoot, identity: workspace.identity, completedDigest: digest) }
        let id = UUID(), date = now()
        let task = Task.detached { try Self.readPage(view: view, state: state, completed: completedSources, workspace: workspace, now: date) }
        let operation = own(task, id: id); defer { operations.removeValue(forKey: operation) }
        let (page, next) = try await withTaskCancellationHandler { try await task.value } onCancel: { task.cancel() }
        guard !closing, views[scanID] != nil else { throw AgentSessionImportError.staleScan }
        let existingBytes = try cacheBytes()
        _ = try Self.validateRetainedPageCapacity(page, existingBytes: existingBytes, pageCount: pages.count)
        if let token = page.nextCursor { cursors[token] = next }
        pages[key] = page; return page
    }
    public func validate(_ review: AgentSessionImportReview) async throws {
        guard !closing, operations.count < 2, let view = views[review.scanID],
              let retained = pages.values.lazy.flatMap(\.reviews).first(where: { $0.id == review.id && $0.digest == review.digest }),
              try AgentSessionImportProtocol.payload(retained) == AgentSessionImportProtocol.payload(review) else { throw AgentSessionImportError.staleScan }
        let id = UUID()
        let task = Task.detached {
            let workspace = try AgentSessionDirectory(path: review.expectedWorkspaceRoot)
            guard workspace.identity == review.workspaceIdentity else { throw AgentSessionImportError.changed }
            for source in review.sources {
                guard let candidate = view.files.first(where: { $0.profile.id == source.providerInstanceID && Self.filePath($0, roots: view.roots).utf8.elementsEqual(source.filePath.utf8) }) else { throw AgentSessionImportError.changed }
                let file = try Self.open(candidate, roots: view.roots)
                let selected = try file.read(profile: candidate.profile, maximumBytes: file.size, maximumRecords: AgentSessionImportProtocol.maximumRecords, maximumSelectedBytes: AgentSessionImportProtocol.maximumHistoryBytes)
                guard try AgentSessionImportProtocol.payload(file.source(profile: candidate.profile, nativeID: source.providerSessionID, digest: selected.digest)) == AgentSessionImportProtocol.payload(source) else { throw AgentSessionImportError.changed }
            }
            try workspace.validate()
        }
        let operation = own(task, id: id); defer { operations.removeValue(forKey: operation) }
        try await withTaskCancellationHandler { try await task.value } onCancel: { task.cancel() }
        guard !closing, views[review.scanID] != nil else { throw AgentSessionImportError.staleScan }
    }
    /// The expensive content digest is checked before enqueue. This final queue
    /// barrier uses the same open-file and named-node identity, including ctime,
    /// without occupying conversation Stop's lane for another multi-GiB read.
    func validateAdmissionIdentity(_ review: AgentSessionImportReview) throws {
        guard !closing, let view = views[review.scanID],
              let retained = pages.values.lazy.flatMap(\.reviews).first(where: { $0.id == review.id && $0.digest == review.digest }),
              try AgentSessionImportProtocol.payload(retained) == AgentSessionImportProtocol.payload(review) else { throw AgentSessionImportError.staleScan }
        let workspace = try AgentSessionDirectory(path: review.expectedWorkspaceRoot)
        guard workspace.identity == review.workspaceIdentity else { throw AgentSessionImportError.changed }
        for source in review.sources {
            guard let candidate = view.files.first(where: { $0.profile.id == source.providerInstanceID && Self.filePath($0, roots: view.roots).utf8.elementsEqual(source.filePath.utf8) }) else { throw AgentSessionImportError.changed }
            let file = try Self.open(candidate, roots: view.roots); try file.validate()
            guard try AgentSessionImportProtocol.payload(file.source(profile: candidate.profile, nativeID: source.providerSessionID, digest: source.digest)) == AgentSessionImportProtocol.payload(source) else { throw AgentSessionImportError.changed }
        }
        try workspace.validate(); for root in view.roots.values { try root.validate() }
    }
    /// Free an admitted display/proof lease without discarding durable sources.
    public func release(reviewID: UUID) { pages = pages.filter { !$0.value.reviews.contains(where: { $0.id == reviewID }) } }
    public func release(scanID: UUID) {
        views.removeValue(forKey: scanID); order.removeAll { $0 == scanID }
        cursors = cursors.filter { $0.value.scanID != scanID }; pages = pages.filter { $0.value.scanID != scanID }
    }
    public func close() async {
        closing = true; let jobs = Array(operations.values); for job in jobs { job.cancel() }
        for job in jobs { await job.drain.value }; operations = [:]; views = [:]; cursors = [:]; pages = [:]; order = []
    }
    private func cacheBytes() throws -> Int {
        try views.values.reduce(0) { $0 + $1.bytes } + pages.values.reduce(0) { try $0 + Self.retainedPageBytes($1) }
    }
    nonisolated static func retainedPageBytes(_ page: AgentSessionImportPage) throws -> Int { try AgentSessionImportProtocol.payload(RetainedPage(page)).count }
    @discardableResult nonisolated static func validateRetainedPageCapacity(_ page: AgentSessionImportPage, existingBytes: Int, pageCount: Int) throws -> Int {
        let added = try retainedPageBytes(page), maximum = 128 * 1_024 * 1_024
        guard existingBytes >= 0, existingBytes <= maximum, added <= maximum - existingBytes, pageCount < 256 else { throw AgentSessionImportError.limit }
        return added
    }
    private func own<T: Sendable>(_ task: Task<T, any Error>, id: UUID) -> UUID {
        operations[id] = .init(cancel: { task.cancel() }, drain: Task { _ = await task.result }); return id
    }
    private static func discover(id: UUID, profiles: [AgentSessionProfile], projects: [WorkspaceProject], home: String, managed: [String], now: Date) throws -> View {
        var roots: [UUID: AgentSessionDirectory] = [:], files: [FileCandidate] = [], seenHomes: Set<String> = []
        var operations: [AgentSessionSource: Int] = [:], counts: [AgentSessionSource: Int] = [:], metadataBytes: [AgentSessionSource: UInt64] = [:]
        var metadataOperations: [AgentSessionSource: Int] = [:], metadataRecords: [AgentSessionSource: Int] = [:], truncated = false
        struct Job { let profile: AgentSessionProfile; let components: [String]; let remaining: Int }
        var jobs: [Job] = []
        for profile in profiles {
            guard let root = try? AgentSessionDirectory(path: profile.transcriptsRoot) else { continue }
            let identity = profile.source.rawValue + ":" + String(root.identity.device) + ":" + String(root.identity.inode)
            guard seenHomes.insert(identity).inserted else { continue }; roots[profile.id] = root
            jobs.append(.init(profile: profile, components: [profile.source == .codex ? "sessions" : "projects"], remaining: profile.source == .codex ? 3 : 1))
        }
        var index = 0
        while index < jobs.count {
            try Task.checkCancellation(); let job = jobs[index]; index += 1
            let source = job.profile.source
            guard operations[source, default: 0] < 20_000, counts[source, default: 0] < AgentSessionImportProtocol.maximumDiscoveredTranscripts,
                  metadataBytes[source, default: 0] < 64 * 1_024 * 1_024 else { truncated = true; continue }
            operations[source, default: 0] += 1
            guard var directory = roots[job.profile.id] else { continue }
            do { for component in job.components { directory = try directory.directory(component) } } catch { continue }
            guard let names = try? directory.names() else { truncated = true; continue }
            if job.remaining > 0 {
                for name in names.reversed() {
                    guard jobs.count < 20_000 else { truncated = true; break }
                    jobs.append(.init(profile: job.profile, components: job.components + [name], remaining: job.remaining - 1))
                }
                continue
            }
            for name in names.reversed() where name.hasSuffix(".jsonl") && (source != .codex || name.hasPrefix("rollout-")) {
                guard operations[source, default: 0] < 20_000, counts[source, default: 0] < AgentSessionImportProtocol.maximumDiscoveredTranscripts,
                      metadataBytes[source, default: 0] < 64 * 1_024 * 1_024,
                      metadataOperations[source, default: 0] < 19_999, metadataRecords[source, default: 0] < 100_000 else { truncated = true; break }
                operations[source, default: 0] += 1; counts[source, default: 0] += 1
                do {
                    let file = try directory.file(name)
                    let availableOperations = 20_000 - metadataOperations[source, default: 0] - 1
                    let reserved = min(file.size, 1_024 * 1_024, UInt64(64 * 1_024 * 1_024) - metadataBytes[source, default: 0], UInt64(availableOperations) * 8_192)
                    let recordReservation = min(1_000, 100_000 - metadataRecords[source, default: 0])
                    let operationReservation = Int((reserved + 8_191) / 8_192) + 1
                    metadataBytes[source, default: 0] += reserved
                    metadataOperations[source, default: 0] += operationReservation
                    metadataRecords[source, default: 0] += recordReservation
                    let read = try file.read(profile: job.profile, maximumBytes: reserved, maximumRecords: recordReservation, maximumSelectedBytes: 1_024 * 1_024, metadataOnly: true)
                    metadataBytes[source, default: 0] -= reserved - read.bytes
                    metadataRecords[source, default: 0] -= recordReservation - read.count
                    metadataOperations[source, default: 0] -= max(0, operationReservation - read.readOperations - 1)
                    guard let cwd = AgentSessionTranscriptParser.workspace(read.records, source: source), cwd.hasPrefix("/"), !excluded(cwd, home: home, managed: managed),
                          let workspace = try? AgentSessionDirectory(path: cwd), !excluded(workspace.path, home: home, managed: managed) else { continue }
                    try workspace.validate()
                    files.append(.init(profile: job.profile, components: job.components, name: name, cwd: workspace.path, modified: file.modified))
                } catch is CancellationError { throw CancellationError() } catch { continue }
            }
        }
        for root in roots.values { try root.validate() }
        let groups = Dictionary(grouping: files, by: { Data($0.cwd.utf8) })
        var candidates: [AgentSessionProjectCandidate] = []
        for values in groups.values {
            try Task.checkCancellation()
            let path = values[0].cwd
            guard let workspace = try? AgentSessionDirectory(path: path) else { continue }
            let metadata = try AgentSessionGitMetadata.read(workspace)
            guard !metadata.excludedWorktree else { continue }
            var candidate = AgentSessionProjectCandidate(id: TaskOrchestration.derivedID(id, path), path: path, title: URL(fileURLWithPath: path).lastPathComponent,
                projectID: projects.first(where: { physical($0.path).utf8.elementsEqual(path.utf8) })?.id,
                sources: Array(Set(values.map { $0.profile.source })).sorted { $0.rawValue < $1.rawValue }, threadCount: values.count,
                lastActiveAt: values.map(\.modified).max(), alreadyImported: projects.contains { physical($0.path).utf8.elementsEqual(path.utf8) })
            candidate.git = metadata.git; candidates.append(candidate)
        }
        candidates.sort { ($0.lastActiveAt ?? .distantPast) > ($1.lastActiveAt ?? .distantPast) }
        let result = AgentSessionScanResult(id: id, candidates: candidates, scannedAt: now, truncated: truncated)
        let bytes = try AgentSessionImportProtocol.payload(files).count + AgentSessionImportProtocol.payload(result).count
        return .init(id: id, created: now, roots: roots, files: files.sorted { $0.modified > $1.modified }, result: result, bytes: bytes)
    }
    private static func readPage(view: View, state initial: Cursor, completed: [AgentSessionImportSource], workspace: AgentSessionDirectory, now: Date) throws -> (AgentSessionImportPage, Cursor) {
        var state = initial, already: [AgentSessionImportSource] = [], duplicates: [AgentSessionImportSource] = [], skipped = 0, reviews: [AgentSessionImportReview] = []
        let eligible = view.files.filter { physical($0.cwd).utf8.elementsEqual(workspace.path.utf8) && $0.modified >= view.created.addingTimeInterval(-AgentSessionImportProtocol.recentInterval) && $0.modified <= view.created }
        while state.position < eligible.count && reviews.isEmpty {
            try Task.checkCancellation(); let candidate = eligible[state.position]; state.position += 1
            do {
                let file = try open(candidate, roots: view.roots)
                if let old = completed.first(where: { $0.providerInstanceID == candidate.profile.id && $0.provider == candidate.profile.source && $0.filePath.utf8.elementsEqual(file.path.utf8) }),
                   try AgentSessionImportProtocol.payload(file.source(profile: candidate.profile, nativeID: old.providerSessionID, digest: old.digest)) == AgentSessionImportProtocol.payload(old) {
                    try file.validate()
                    let key = candidate.profile.id.uuidString + ":" + Data(old.providerSessionID.utf8).base64EncodedString()
                    if state.sessions.insert(key).inserted { already.append(old) } else { duplicates.append(old) }
                    continue
                }
                guard state.filesUsed < AgentSessionImportProtocol.maximumRecentTranscripts, file.size <= UInt64(AgentSessionImportProtocol.maximumTranscriptBytes),
                      file.size <= UInt64(AgentSessionImportProtocol.maximumTranscriptBytes) - state.bytes,
                      state.records < AgentSessionImportProtocol.maximumRecords else { skipped += 1; continue }
                state.filesUsed += 1; state.bytes += file.size
                let read = try file.read(profile: candidate.profile, maximumBytes: file.size, maximumRecords: AgentSessionImportProtocol.maximumRecords - state.records, maximumSelectedBytes: AgentSessionImportProtocol.maximumHistoryBytes)
                state.records += read.count
                guard let parsed = try AgentSessionTranscriptParser.parse(read.records, profile: candidate.profile, fallbackSessionID: String(candidate.name.dropLast(6)), lastActive: file.modified),
                      physical(parsed.workspacePath).utf8.elementsEqual(workspace.path.utf8) else { skipped += 1; continue }
                let transcript = AgentSessionTranscript(source: parsed.source, providerInstanceID: parsed.providerInstanceID, providerSessionID: parsed.providerSessionID,
                    workspacePath: state.workspace, title: parsed.title, model: parsed.model, createdAt: parsed.createdAt, updatedAt: parsed.updatedAt,
                    messages: parsed.messages, omittedMessageCount: parsed.omittedMessageCount)
                let source = file.source(profile: candidate.profile, nativeID: transcript.providerSessionID, digest: read.digest)
                let session = candidate.profile.id.uuidString + ":" + Data(transcript.providerSessionID.utf8).base64EncodedString()
                if !state.sessions.insert(session).inserted { duplicates.append(source); continue }
                if try completed.contains(where: { try AgentSessionImportProtocol.payload($0) == AgentSessionImportProtocol.payload(source) }) { already.append(source); continue }
                let id = UUID(), sources = [source]
                let digest = try AgentSessionImportProtocol.digest(ReviewDigest(projectID: state.projectID, workspace: state.workspace, identity: workspace.identity, profile: candidate.profile, transcript: transcript, sources: sources))
                reviews.append(.init(id: id, digest: digest, scanID: view.id, projectID: state.projectID, expectedWorkspaceRoot: state.workspace,
                    workspaceIdentity: workspace.identity, profile: candidate.profile, transcript: transcript, sources: sources))
            } catch is CancellationError { throw CancellationError() } catch { skipped += 1 }
        }
        try workspace.validate(); for root in view.roots.values { try root.validate() }
        let complete = state.position >= eligible.count, token = complete ? nil : UUID()
        return (.init(scanID: view.id, reviews: reviews, alreadyImported: already, duplicates: duplicates, skippedCount: skipped, nextCursor: token, complete: complete), state)
    }
    private struct ReviewDigest: Encodable { let projectID: UUID; let workspace: String; let identity: GitWorktreeNodeIdentity; let profile: AgentSessionProfile; let transcript: AgentSessionTranscript; let sources: [AgentSessionImportSource] }
    private static func open(_ file: FileCandidate, roots: [UUID: AgentSessionDirectory]) throws -> AgentSessionFile {
        guard var directory = roots[file.profile.id] else { throw AgentSessionImportError.changed }
        for component in file.components { directory = try directory.directory(component) }; return try directory.file(file.name)
    }
    private static func filePath(_ file: FileCandidate, roots: [UUID: AgentSessionDirectory]) -> String { (roots[file.profile.id]?.path ?? "") + "/" + (file.components + [file.name]).joined(separator: "/") }
    private static func physical(_ path: String) -> String { URL(fileURLWithPath: path).standardizedFileURL.resolvingSymlinksInPath().path }
    private static func excluded(_ path: String, home: String, managed: [String]) -> Bool {
        let value = physical(path)
        if [home, "/tmp", "/private/tmp", FileManager.default.temporaryDirectory.standardizedFileURL.resolvingSymlinksInPath().path].contains(value) { return true }
        return [home + "/Downloads", home + "/Documents/Codex"].contains(where: { value == $0 || value.hasPrefix($0 + "/") }) ||
            managed.contains(where: { value == $0 || value.hasPrefix($0 + "/") }) || value.hasSuffix("/.t3/worktrees") || value.contains("/.t3/worktrees/")
    }
}
