import Foundation

/// The agent account the user ran most recently in Coincide: the provider and account of the last turn started, which
/// the menu bar item follows by default (`MenuBarUsageChoice.lastActive`).
public struct LastActiveAgent: Codable, Hashable, Sendable {
    public var provider: ProviderKind
    /// `ProviderAccount.id`; the default account's is `ProviderAccount.defaultID`.
    public var accountID: String
    public var date: Date

    public nonisolated init(provider: ProviderKind, accountID: String?, date: Date) {
        self.provider = provider
        self.accountID = accountID ?? ProviderAccount.defaultID
        self.date = date
    }
}

/// Keeps `LastActiveAgent` across launches, in a small file of its own so recording a turn doesn't rewrite settings.
/// It holds no prompt, model, path or account detail beyond the account's id.
@MainActor
public final class LastActiveAgentStore {
    /// Posted when the last active agent changes to another provider or account.
    public static let didChange = Notification.Name("Coincide.lastActiveAgentChanged")

    public private(set) var value: LastActiveAgent?
    private let file: URL
    private let writer = DispatchQueue(label: "Coincide.last-active-agent", qos: .utility)

    public init(directory: URL) {
        file = directory.appendingPathComponent("last-active-agent.json")
        guard let data = try? Data(contentsOf: file) else { return }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        value = try? decoder.decode(LastActiveAgent.self, from: data)
    }

    /// Notes a turn started with `provider`'s `account` (nil for its default account).
    public func record(provider: ProviderKind, account: String?, at date: Date = Date()) {
        let agent = LastActiveAgent(provider: provider, accountID: account, date: date)
        let changed = value?.provider != agent.provider || value?.accountID != agent.accountID
        value = agent
        let file = file
        writer.async {
            let encoder = JSONEncoder()
            encoder.dateEncodingStrategy = .iso8601
            guard let data = try? encoder.encode(agent) else { return }
            try? FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
            try? data.write(to: file, options: .atomic)
        }
        if changed { NotificationCenter.default.post(name: Self.didChange, object: self) }
    }

    /// Waits for pending writes; for tests and quitting.
    public func flush() { writer.sync {} }
}
