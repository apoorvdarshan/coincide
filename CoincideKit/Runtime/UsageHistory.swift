import Foundation

/// One finished turn, containing only usage actually reported during that turn. Context/output/cost
/// are provider snapshots: their scope differs by provider, so they must never be summed as billing totals.
public struct UsageRecord: Codable, Hashable, Sendable, Identifiable {
    public var id: UUID
    public var threadID: UUID
    public var projectID: UUID
    public var provider: ProviderKind
    /// The provider account the turn ran with; nil for its default account (and for turns recorded before accounts
    /// were kept).
    public var accountID: String?
    public var modelID: String?
    public var startedAt: Date
    public var finishedAt: Date
    public var outcome: Outcome
    public var usage: TokenUsage

    public enum Outcome: String, Codable, Sendable { case completed, interrupted, failed }
    public var duration: TimeInterval { max(0, finishedAt.timeIntervalSince(startedAt)) }

    public init(id: UUID, threadID: UUID, projectID: UUID, provider: ProviderKind, accountID: String? = nil, modelID: String?,
                startedAt: Date, finishedAt: Date, outcome: Outcome, usage: TokenUsage) {
        self.id = id
        self.threadID = threadID
        self.projectID = projectID
        self.provider = provider
        self.accountID = ProviderAccount.storedID(accountID)
        self.modelID = modelID
        self.startedAt = startedAt
        self.finishedAt = max(startedAt, finishedAt)
        self.outcome = outcome
        func count(_ value: Int?) -> Int? { value.flatMap { $0 >= 0 ? $0 : nil } }
        self.usage = TokenUsage(inputTokens: count(usage.inputTokens), outputTokens: count(usage.outputTokens),
            cachedInputTokens: count(usage.cachedInputTokens), contextWindow: count(usage.contextWindow),
            costUSD: usage.costUSD.flatMap { $0.isFinite && $0 >= 0 ? $0 : nil },
            turnTotals: usage.turnTotals.flatMap { $0.isEmpty ? nil : $0 })
    }
}

/// A bounded local history. No prompt, response, file path, account detail, or error message is stored.
@MainActor
public final class UsageHistory {
    public static let didChange = Notification.Name("Coincide.usageHistoryChanged")
    public static let limit = 10_000
    public private(set) var records: [UsageRecord] = []
    public private(set) var error: String?
    private let file: URL
    private let writer = DispatchQueue(label: "Coincide.usage-history", qos: .utility)
    private var generation = 0
    private var unreadableOriginalBlocksWrites = false

    public init(directory: URL) {
        file = directory.appendingPathComponent("usage-history.json")
        guard FileManager.default.fileExists(atPath: file.path) else { return }
        do {
            let size = try file.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0
            guard size <= 16_000_000 else { throw CocoaError(.fileReadTooLarge) }
            let decoder = JSONDecoder()
            decoder.dateDecodingStrategy = .iso8601
            records = Array(try decoder.decode([UsageRecord].self, from: Data(contentsOf: file)).suffix(Self.limit))
        } catch {
            // Preserve unreadable data before the first new record replaces the history.
            do {
                try FileManager.default.moveItem(at: file, to: file.appendingPathExtension("unreadable-\(UUID())"))
            } catch {
                unreadableOriginalBlocksWrites = true
                self.error = error.localizedDescription
            }
        }
    }

    public func record(_ value: UsageRecord) {
        guard !unreadableOriginalBlocksWrites, !records.contains(where: { $0.id == value.id }) else { return }
        records.append(value)
        if records.count > Self.limit { records.removeFirst(records.count - Self.limit) }
        generation += 1
        let revision = generation
        let snapshot = records
        let file = file
        writer.async { [weak self] in
            var failure: String?
            do {
                let encoder = JSONEncoder()
                encoder.dateEncodingStrategy = .iso8601
                let data = try encoder.encode(snapshot)
                try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
                try data.write(to: file, options: .atomic)
            } catch {
                failure = error.localizedDescription
            }
            let message = failure
            Task { @MainActor [weak self] in
                guard let self, self.generation == revision, self.error != message else { return }
                self.error = message
                NotificationCenter.default.post(name: Self.didChange, object: self)
            }
        }
        NotificationCenter.default.post(name: Self.didChange, object: self)
    }

    /// Called on normal termination, and by persistence tests.
    public func flush() { writer.sync {} }

    public func filtered(since: Date, provider: ProviderKind? = nil, projectID: UUID? = nil) -> [UsageRecord] {
        records.filter { $0.finishedAt >= since && (provider == nil || $0.provider == provider)
            && (projectID == nil || $0.projectID == projectID) }
    }
}
