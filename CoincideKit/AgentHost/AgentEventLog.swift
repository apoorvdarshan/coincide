import Foundation

/// The events of one hosted session, kept until the app says it applied them, so an app that was closed (or
/// crashed) catches up on what its agents did meanwhile.
///
/// Two files per session in the host's folder: `<key>.jsonl`, one `LoggedAgentEvent` per line in order, and
/// `<key>.meta.json` with how far the app got. Events the app applied leave memory at once and the file once
/// enough of them collect (or all are applied), so a long session does not grow the log without end.
@MainActor
public final class AgentEventLog {
    public let key: AgentSessionKey
    public private(set) var lastSequence: Int
    public private(set) var acknowledgedSequence: Int
    /// Whether a turn ran right after the last applied event.
    public private(set) var turnWasActiveAtAcknowledged: Bool
    /// Events not applied yet, oldest first.
    public private(set) var backlog: [LoggedAgentEvent]

    private let eventsURL: URL
    private let metaURL: URL
    private var handle: FileHandle?
    /// Applied events still in the file; past this many the file is rewritten without them.
    private var appliedInFile = 0
    nonisolated static let compactionThreshold = 2_000

    private struct Meta: Codable {
        var key: AgentSessionKey
        var acknowledged: Int
        var turnActiveAtAcknowledged: Bool
        /// The last sequence handed out, kept for when the events file is empty.
        var last: Int
    }

    /// `startingAfter` is the last sequence an earlier log of the key handed out in this run of the host, so a
    /// session started again after its log was removed never reuses a number the app already applied.
    init(key: AgentSessionKey, directory: URL, startingAfter: Int = 0) {
        self.key = key
        eventsURL = directory.appendingPathComponent("\(key).jsonl")
        metaURL = directory.appendingPathComponent("\(key).meta.json")
        let meta = (try? Data(contentsOf: metaURL)).flatMap { try? AgentHostWire.decode(Meta.self, from: $0) }
        acknowledgedSequence = meta?.acknowledged ?? 0
        turnWasActiveAtAcknowledged = meta?.turnActiveAtAcknowledged ?? false
        var events: [LoggedAgentEvent] = []
        if let data = try? Data(contentsOf: eventsURL) {
            // A line cut short by a crash mid-write is skipped; everything before it is intact.
            for line in data.split(separator: UInt8(ascii: "\n")) {
                if let event = try? AgentHostWire.decode(LoggedAgentEvent.self, from: Data(line)) { events.append(event) }
            }
        }
        let applied = meta?.acknowledged ?? 0
        appliedInFile = events.count { $0.sequence <= applied }
        backlog = events.filter { $0.sequence > applied }
        lastSequence = max(meta?.last ?? 0, applied, events.last?.sequence ?? 0, startingAfter)
    }

    isolated deinit {
        try? handle?.close()
    }

    /// Whether the log holds anything worth keeping: events not applied, or how far the app got.
    public var isEmpty: Bool { backlog.isEmpty && lastSequence == 0 }

    /// The last event logged, if it is still in memory.
    public var lastEvent: LoggedAgentEvent? { backlog.last }

    /// Logs an event (nil for a host note that only changes `turnActive`) and returns it with its sequence.
    @discardableResult
    public func append(_ event: AgentEvent?, turnActive: Bool, at date: Date = Date()) -> LoggedAgentEvent {
        lastSequence += 1
        let logged = LoggedAgentEvent(sequence: lastSequence, date: date, event: event, turnActive: turnActive)
        backlog.append(logged)
        write(logged)
        return logged
    }

    /// The logged events after `sequence`, oldest first.
    public func events(after sequence: Int) -> [LoggedAgentEvent] {
        backlog.filter { $0.sequence > sequence }
    }

    /// Notes that the app applied everything up to `sequence`, dropping those events.
    public func acknowledge(_ sequence: Int) {
        let sequence = min(sequence, lastSequence)
        guard sequence > acknowledgedSequence else { return }
        if let applied = backlog.last(where: { $0.sequence <= sequence }) {
            turnWasActiveAtAcknowledged = applied.turnActive
        }
        let dropped = backlog.count { $0.sequence <= sequence }
        backlog.removeFirst(dropped)
        appliedInFile += dropped
        acknowledgedSequence = sequence
        if backlog.isEmpty || appliedInFile >= Self.compactionThreshold { rewriteEvents() }
        writeMeta()
    }

    /// Deletes both files.
    public func remove() {
        try? handle?.close()
        handle = nil
        try? FileManager.default.removeItem(at: eventsURL)
        try? FileManager.default.removeItem(at: metaURL)
        backlog = []
    }

    // MARK: Files

    private func write(_ event: LoggedAgentEvent) {
        guard var line = try? AgentHostWire.encode(event) else { return }
        line.append(UInt8(ascii: "\n"))
        if handle == nil {
            if !FileManager.default.fileExists(atPath: eventsURL.path) {
                writeMeta()
                FileManager.default.createFile(atPath: eventsURL.path, contents: nil, attributes: [.posixPermissions: 0o600])
            }
            handle = try? FileHandle(forWritingTo: eventsURL)
            _ = try? handle?.seekToEnd()
        }
        try? handle?.write(contentsOf: line)
    }

    /// Writes the file anew with only the events not applied yet.
    private func rewriteEvents() {
        try? handle?.close()
        handle = nil
        var data = Data()
        for event in backlog {
            guard let line = try? AgentHostWire.encode(event) else { continue }
            data.append(line)
            data.append(UInt8(ascii: "\n"))
        }
        try? data.write(to: eventsURL, options: .atomic)
        appliedInFile = 0
    }

    private func writeMeta() {
        let meta = Meta(
            key: key, acknowledged: acknowledgedSequence, turnActiveAtAcknowledged: turnWasActiveAtAcknowledged,
            last: lastSequence)
        guard let data = try? AgentHostWire.encode(meta) else { return }
        try? data.write(to: metaURL, options: .atomic)
    }
}

/// The host's event logs, one per session, in its own folder.
@MainActor
public final class AgentEventLogStore {
    public let directory: URL

    public init(directory: URL) {
        self.directory = directory
        try? FileManager.default.createDirectory(
            at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
    }

    /// Removed logs' last sequences: a key's numbers only go up for as long as the host runs, as an app connected
    /// to it remembers how far it got by number.
    private var retiredSequences: [AgentSessionKey: Int] = [:]

    public func open(_ key: AgentSessionKey) -> AgentEventLog {
        AgentEventLog(key: key, directory: directory, startingAfter: retiredSequences[key] ?? 0)
    }

    /// Deletes the log's files, keeping its last sequence for the next log of its key.
    public func remove(_ log: AgentEventLog) {
        retiredSequences[log.key] = max(retiredSequences[log.key] ?? 0, log.lastSequence)
        log.remove()
    }

    /// The sessions with a log on disk, as an earlier run of the host left them.
    public func existingKeys() -> [AgentSessionKey] {
        let names = (try? FileManager.default.contentsOfDirectory(atPath: directory.path)) ?? []
        return names.compactMap { name -> AgentSessionKey? in
            guard name.hasSuffix(".meta.json") else { return nil }
            let parts = name.dropLast(".meta.json".count).split(separator: ".", maxSplits: 1)
            guard parts.count == 2, let threadID = UUID(uuidString: String(parts[0])),
                let provider = ProviderKind(rawValue: String(parts[1]))
            else { return nil }
            return AgentSessionKey(threadID: threadID, provider: provider)
        }
        .sorted { $0.description < $1.description }
    }
}
