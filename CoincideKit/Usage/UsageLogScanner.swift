import Foundation

/// Where one provider account's CLI keeps its session logs.
public struct UsageLogSource: Sendable, Hashable {
    public var provider: ProviderKind
    /// The account (`ProviderAccount.id`) the logs belong to.
    public var accountID: String
    /// Folders searched for `.jsonl` logs.
    public var roots: [URL]

    public nonisolated init(provider: ProviderKind, accountID: String, roots: [URL]) {
        self.provider = provider
        self.accountID = accountID
        self.roots = roots
    }

    /// The log folders of a CLI whose state is in `home`: Claude Code's `projects`, Codex's live and archived sessions.
    public nonisolated static func roots(for provider: ProviderKind, home: URL) -> [URL] {
        switch provider {
        case .claude: [home.appendingPathComponent("projects", isDirectory: true)]
        case .codex:
            [home.appendingPathComponent("sessions", isDirectory: true),
             home.appendingPathComponent("archived_sessions", isDirectory: true)]
        default: []
        }
    }

    /// The CLI's home in `environment`: its own variable (`CLAUDE_CONFIG_DIR`, `CODEX_HOME`) or the usual folder.
    public nonisolated static func home(for provider: ProviderKind, environment: [String: String]) -> URL? {
        let home = FileManager.default.homeDirectoryForCurrentUser
        switch provider {
        case .claude:
            return environment["CLAUDE_CONFIG_DIR"]?.trimmedNonEmpty.map { URL(fileURLWithPath: $0, isDirectory: true) }
                ?? home.appendingPathComponent(".claude", isDirectory: true)
        case .codex:
            return environment["CODEX_HOME"]?.trimmedNonEmpty.map { URL(fileURLWithPath: $0, isDirectory: true) }
                ?? home.appendingPathComponent(".codex", isDirectory: true)
        default:
            return nil
        }
    }
}

/// One session log's requests, with what tells whose session it was.
public struct LoggedSession: Sendable, Hashable {
    public var provider: ProviderKind
    public var accountID: String
    public var sessionID: String?
    /// The client that started the session, when the log says (Codex's `originator`).
    public var originator: String?
    public var requests: [LoggedRequest]
}

/// What a scan found.
public struct UsageLogScan: Sendable {
    public var sessions: [LoggedSession]
    /// Logs read anew or in part this time (the rest came from the cache).
    public var filesRead: Int
    public var bytesRead: Int64
    public var duration: TimeInterval
}

/// Reads Claude Code's and Codex's session logs into requests, keeping what it read in a cache file so the next scan
/// only reads what was appended since. Nothing leaves the Mac; the cache keeps token counts, model names, session ids and
/// hashed response ids, never prompts or replies. Scans run one at a time, off the main actor.
public final class UsageLogScanner: @unchecked Sendable {
    private let cacheFile: URL
    private let lock = NSLock()
    private var cache: Cache?

    public nonisolated init(cacheFile: URL) {
        self.cacheFile = cacheFile
    }

    /// Reads every log of `sources`. Blocking; call it from a background task.
    public nonisolated func scan(_ sources: [UsageLogSource]) -> UsageLogScan {
        lock.lock()
        defer { lock.unlock() }
        let start = Date()
        var cache = self.cache ?? Self.load(cacheFile)
        var seen: Set<String> = []
        var sessions: [LoggedSession] = []
        var filesRead = 0
        var bytesRead: Int64 = 0
        var changed = false
        for source in sources where source.provider == .claude || source.provider == .codex {
            for file in Self.logFiles(in: source.roots) where seen.insert(file.url.path).inserted {
                var entry = cache.files[file.url.path]
                if entry?.provider != source.provider || entry?.isCurrent(size: file.size, modified: file.modified) != true {
                    let previous = entry.flatMap {
                        $0.canResume(size: file.size, modified: file.modified, provider: source.provider)
                            && Self.endsLine(file.url, at: $0.offset) ? $0 : nil
                    }
                    let read = Self.read(file, provider: source.provider, resuming: previous)
                    entry = read.entry
                    filesRead += 1
                    bytesRead += read.bytes
                    cache.files[file.url.path] = read.entry
                    changed = true
                }
                guard let entry, !entry.isEmpty else { continue }
                sessions.append(
                    LoggedSession(
                        provider: source.provider, accountID: source.accountID, sessionID: entry.sessionID,
                        originator: entry.originator, requests: entry.requests()))
            }
        }
        // Logs that are gone (or no longer in a source) leave the cache.
        let stale = cache.files.keys.filter { !seen.contains($0) }
        if !stale.isEmpty {
            for path in stale { cache.files[path] = nil }
            changed = true
        }
        self.cache = cache
        if changed { Self.save(cache, to: cacheFile) }
        return UsageLogScan(sessions: sessions, filesRead: filesRead, bytesRead: bytesRead, duration: Date().timeIntervalSince(start))
    }

    // MARK: Files

    struct LogFile {
        var url: URL
        var size: Int64
        var modified: Double
    }

    private nonisolated static func logFiles(in roots: [URL]) -> [LogFile] {
        var files: [LogFile] = []
        let keys: [URLResourceKey] = [.fileSizeKey, .contentModificationDateKey, .isRegularFileKey]
        for root in roots {
            guard let enumerator = FileManager.default.enumerator(at: root, includingPropertiesForKeys: keys, options: [.skipsHiddenFiles])
            else { continue }
            for case let url as URL in enumerator where url.pathExtension == "jsonl" {
                guard let values = try? url.resourceValues(forKeys: Set(keys)), values.isRegularFile == true else { continue }
                files.append(
                    LogFile(
                        url: url, size: Int64(values.fileSize ?? 0),
                        modified: values.contentModificationDate?.timeIntervalSince1970 ?? 0))
            }
        }
        return files.sorted { $0.url.path < $1.url.path }
    }

    /// Reads a log from where `previous` stopped (or from the start), up to its last complete line.
    nonisolated static func read(_ file: LogFile, provider: ProviderKind, resuming previous: CachedLog?) -> (entry: CachedLog, bytes: Int64) {
        var entry = previous ?? CachedLog(provider: provider)
        var codex = entry.codex ?? CodexLogParser()
        let start = previous?.offset ?? 0
        let end = forEachLine(of: file.url, from: start) { line in
            switch provider {
            case .claude:
                guard ClaudeLogParser.isCandidate(line), let read = ClaudeLogParser.request(fromLine: Data(line)) else { return }
                if entry.sessionID == nil { entry.sessionID = read.sessionID }
                entry.append(read.request)
            default:
                guard CodexLogParser.isCandidate(line), let request = codex.consume(Data(line)) else { return }
                entry.append(request)
            }
        }
        if provider == .codex {
            entry.codex = codex
            entry.sessionID = codex.sessionID
            entry.originator = codex.originator
        }
        entry.offset = end
        entry.size = file.size
        entry.modified = file.modified
        return (entry, end - start)
    }

    /// Whether a line ends just before `offset`, as it did when reading stopped there: a log rewritten since reads anew.
    private nonisolated static func endsLine(_ url: URL, at offset: Int64) -> Bool {
        guard offset > 0 else { return true }
        guard let handle = try? FileHandle(forReadingFrom: url) else { return false }
        defer { try? handle.close() }
        guard (try? handle.seek(toOffset: UInt64(offset - 1))) != nil, let byte = try? handle.read(upToCount: 1) else { return false }
        return byte.first == 0x0A
    }

    /// Calls `body` with each complete line from `offset` on; returns the offset after the last complete line.
    private nonisolated static func forEachLine(of url: URL, from offset: Int64, _ body: (UnsafeRawBufferPointer) -> Void) -> Int64 {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return offset }
        defer { try? handle.close() }
        do { try handle.seek(toOffset: UInt64(offset)) } catch { return offset }
        var consumed = offset
        var carry = Data()
        while true {
            let chunk: Data
            do {
                guard let data = try handle.read(upToCount: 4 << 20), !data.isEmpty else { break }
                chunk = data
            } catch {
                break
            }
            var buffer = carry
            buffer.append(chunk)
            let used = buffer.withUnsafeBytes { bytes -> Int in
                guard let base = bytes.baseAddress else { return 0 }
                var lineStart = 0
                while lineStart < bytes.count,
                    let newline = memchr(base + lineStart, 0x0A, bytes.count - lineStart)
                {
                    let lineEnd = base.distance(to: UnsafeRawPointer(newline))
                    if lineEnd > lineStart {
                        body(UnsafeRawBufferPointer(rebasing: bytes[lineStart..<lineEnd]))
                    }
                    lineStart = lineEnd + 1
                }
                return lineStart
            }
            consumed += Int64(used)
            carry = buffer.subdata(in: used..<buffer.count)
        }
        return consumed
    }

    // MARK: Cache

    struct Cache: Codable {
        static let version = 2
        var version = Cache.version
        var files: [String: CachedLog] = [:]
    }

    /// What one log held when last read, and where reading stopped.
    struct CachedLog: Codable, Hashable {
        var provider: ProviderKind
        var size: Int64 = 0
        var modified: Double = 0
        var offset: Int64 = 0
        var sessionID: String?
        var originator: String?
        var codex: CodexLogParser?
        var models: [String] = []
        /// Ten little-endian 64-bit numbers per request (see `append`).
        var rows = Data()

        init(provider: ProviderKind) { self.provider = provider }

        var isEmpty: Bool { rows.isEmpty }

        func isCurrent(size: Int64, modified: Double) -> Bool { self.size == size && self.modified == modified }

        /// Whether the log only grew since it was read (session logs are append-only), so reading can go on from
        /// `offset`.
        func canResume(size: Int64, modified: Double, provider: ProviderKind) -> Bool {
            self.provider == provider && size >= self.size && offset <= size && modified >= self.modified
        }

        static let fields = 10

        mutating func append(_ request: LoggedRequest) {
            // Claude Code logs a response once per content block, one line after another: keep one row with the
            // largest counts, so the cache holds each response once.
            let stride = Self.fields * 8
            if request.key != 0, rows.count >= stride, let last = requests(from: rows.count - stride).first, last.key == request.key {
                rows.removeLast(stride)
                var merged = request
                merged.date = min(last.date, request.date)
                merged.tokens = last.tokens.fieldwiseMax(request.tokens)
                merged.promptTokens = max(last.promptTokens, request.promptTokens)
                if merged.model == nil { merged.model = last.model }
                return append(merged)
            }
            var modelIndex = -1
            if let model = request.model {
                if let index = models.firstIndex(of: model) {
                    modelIndex = index
                } else {
                    models.append(model)
                    modelIndex = models.count - 1
                }
            }
            let values: [Int64] = [
                Int64((request.date.timeIntervalSince1970 * 1000).rounded()), Int64(modelIndex), Int64(request.tokens.input),
                Int64(request.tokens.cacheRead), Int64(request.tokens.cacheWrite), Int64(request.tokens.cacheWriteLong),
                Int64(request.tokens.output), Int64(request.tokens.reasoning), Int64(request.promptTokens),
                Int64(bitPattern: request.key),
            ]
            values.withUnsafeBufferPointer { buffer in
                for value in buffer {
                    withUnsafeBytes(of: value.littleEndian) { rows.append(contentsOf: $0) }
                }
            }
        }

        /// The requests the rows hold, from the row at byte `start` on.
        func requests(from start: Int = 0) -> [LoggedRequest] {
            let stride = Self.fields * 8
            let count = rows.count / stride
            let first = start / stride
            var requests: [LoggedRequest] = []
            requests.reserveCapacity(max(0, count - first))
            rows.withUnsafeBytes { bytes in
                for row in first..<max(first, count) {
                    func value(_ field: Int) -> Int64 {
                        Int64(littleEndian: bytes.loadUnaligned(fromByteOffset: row * stride + field * 8, as: Int64.self))
                    }
                    func int(_ field: Int) -> Int { Int(clamping: value(field)) }
                    let modelIndex = int(1)
                    requests.append(
                        LoggedRequest(
                            date: Date(timeIntervalSince1970: Double(value(0)) / 1000),
                            model: models.indices.contains(modelIndex) ? models[modelIndex] : nil,
                            tokens: TokenTotals(
                                input: int(2), cacheRead: int(3), cacheWrite: int(4), cacheWriteLong: int(5), output: int(6),
                                reasoning: int(7)),
                            promptTokens: int(8), key: UInt64(bitPattern: value(9))))
                }
            }
            return requests
        }
    }

    private nonisolated static func load(_ url: URL) -> Cache {
        guard let data = try? Data(contentsOf: url), let cache = try? PropertyListDecoder().decode(Cache.self, from: data),
            cache.version == Cache.version
        else { return Cache() }
        return cache
    }

    private nonisolated static func save(_ cache: Cache, to url: URL) {
        let encoder = PropertyListEncoder()
        encoder.outputFormat = .binary
        guard let data = try? encoder.encode(cache) else { return }
        try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? data.write(to: url, options: [.atomic])
    }
}
