import Foundation
import Security

/// Reads the Cursor plan's usage from Cursor's dashboard API (`GetCurrentPeriodUsage`) as monthly windows, following
/// T3 Code's `readCursorUsageLimits`. The token is the CLI's own login: `CURSOR_AUTH_TOKEN`, else the login the CLI
/// keeps in the macOS Keychain (read only when the user allowed it in Settings, and only for Cursor's own endpoint),
/// or in `~/.cursor/auth.json` when the CLI stores it in a file. An API key may belong to another account, so it
/// reads nothing.
enum CursorUsageLimits {
    nonisolated static let defaultEndpoint = "https://api2.cursor.sh"
    nonisolated static let usagePath = "/aiserver.v1.DashboardService/GetCurrentPeriodUsage"

    /// Cursor's usage pools, in T3's order: `totalPercentUsed` combines the other two rather than being a third quota,
    /// `autoPercentUsed` is what Cursor's own models (and Auto) use first and `apiPercentUsed` the other models.
    nonisolated static func label(forPool id: String) -> String? {
        switch id {
        case "totalPercentUsed": String(localized: "Overall")
        case "autoPercentUsed": String(localized: "Cursor Models")
        case "apiPercentUsed": String(localized: "Other Models")
        default: nil
        }
    }

    private nonisolated static let pools = ["totalPercentUsed", "autoPercentUsed", "apiPercentUsed"]

    /// Where the CLI's login is read from. Tests pass their own, so they never touch the real Keychain or files.
    struct Credentials: Sendable {
        /// The CLI's login in the macOS Keychain; macOS may ask the user to allow the read.
        var keychainToken: @Sendable () async throws -> String?
        /// A file's contents, nil when there is no such file.
        var readFile: @Sendable (URL) throws -> Data?
        /// Used when the environment has no `HOME`.
        var homeDirectory: URL

        nonisolated static let live = Credentials(
            keychainToken: { try await CursorKeychain.shared.accessToken() }, readFile: readFileIfPresent,
            homeDirectory: FileManager.default.homeDirectoryForCurrentUser)
    }

    /// Reads the plan's windows. `allowKeychain` is the user's Settings choice; without it a Keychain login reads
    /// nothing, so macOS never asks on its own. The request and file read get `timeout` (T3's 10 seconds); the
    /// Keychain read, which may wait for the user to answer macOS, gets T3's Keychain timeout of its own.
    @concurrent nonisolated static func read(
        environment: [String: String], allowKeychain: Bool, credentials: Credentials = .live,
        fetch: @escaping UsageLimitsFetch = UsageLimitsHTTP.live, timeout: Duration = .seconds(10),
        keychainTimeout: Duration = .seconds(30), now: Date = Date()
    ) async -> UsageLimitsOutcome {
        let configured = environment["CURSOR_API_ENDPOINT"]?.trimmedNonEmpty ?? defaultEndpoint
        let endpoint = configured.hasSuffix("/") ? String(configured.dropLast()) : configured
        let explicitToken = environment["CURSOR_AUTH_TOKEN"]?.trimmedNonEmpty
        // An explicit API key can name a different account from the stored login.
        if explicitToken == nil, environment["CURSOR_API_KEY"]?.trimmedNonEmpty != nil { return .unsupported }
        let store = environment["AGENT_CLI_CREDENTIAL_STORE"]
        if explicitToken == nil, store == "memory" { return .unsupported }
        do {
            var known = explicitToken
            if known == nil, store != "file" {
                // On macOS the CLI keeps its login in the Keychain unless told to use a file. That token never goes
                // to another endpoint.
                guard allowKeychain, endpoint == defaultEndpoint else { return .unsupported }
                let token = try await usageLimitsWithTimeout(keychainTimeout) { try await credentials.keychainToken() }
                guard let token = token?.trimmedNonEmpty else { return .unsupported }
                known = token
            }
            let token = known
            return try await usageLimitsWithTimeout(timeout) {
                let resolved: String
                if let token {
                    resolved = token
                } else {
                    let home = environment["HOME"]?.trimmedNonEmpty.map { URL(fileURLWithPath: $0) } ?? credentials.homeDirectory
                    let file = try credentials.readFile(home.appending(path: ".cursor/auth.json"))
                    guard let token = try accessToken(fromAuthFile: file) else { return .unsupported }
                    resolved = token
                }
                guard let url = URL(string: endpoint + usagePath), url.host() != nil else { return .failed }
                var request = UsageLimitsHTTP.request(url, method: "POST", token: resolved, timeout: timeout.timeInterval)
                request.setValue("1", forHTTPHeaderField: "connect-protocol-version")
                request.setValue("cli", forHTTPHeaderField: "x-cursor-client-type")
                request.setValue("application/json", forHTTPHeaderField: "Content-Type")
                request.httpBody = Data("{}".utf8)
                let (data, response) = try await fetch(request)
                guard (200..<300).contains(response.statusCode), let body = JSONValue.parse(data), body.object != nil
                else { return .failed }
                let windows = windows(fromResponse: body)
                return windows.isEmpty ? .unsupported : .limits(UsageLimits(windows: windows, checkedAt: now))
            }
        } catch {
            return .failed
        }
    }

    /// The `accessToken` of the CLI's `auth.json`, nil when the file is missing or has none. Throws when the file
    /// is not JSON.
    nonisolated static func accessToken(fromAuthFile data: Data?) throws -> String? {
        guard let data else { return nil }
        guard let json = JSONValue.parse(data), json.object != nil else { throw CocoaError(.fileReadCorruptFile) }
        return json["accessToken"]?.string?.trimmedNonEmpty
    }

    /// The windows of a `GetCurrentPeriodUsage` answer: a monthly window per pool Cursor reports, resetting when the
    /// billing cycle ends. Cursor's dashboard percentages include bonus usage; spend / limit does not. A pool Cursor
    /// leaves out is left out here too, rather than shown as unused.
    nonisolated static func windows(fromResponse response: JSONValue) -> [UsageLimitWindow] {
        let resetsAt = billingCycleEnd(response["billingCycleEnd"])
        guard let usage = response["planUsage"], usage.object != nil else { return [] }
        return pools.compactMap { id in
            guard let used = usage[id]?.number, used.isFinite, let label = label(forPool: id) else { return nil }
            return UsageLimitWindow(id: id, kind: .monthly, label: label, usedPercent: used, resetsAt: resetsAt)
        }
    }

    /// `billingCycleEnd` is epoch milliseconds, as a number or as text.
    private nonisolated static func billingCycleEnd(_ value: JSONValue?) -> Date? {
        guard let millis = value?.number ?? value?.string.flatMap({ Double($0.trimmingCharacters(in: .whitespaces)) }),
            millis.isFinite, millis > 0, millis <= 8.64e15
        else { return nil }
        return Date(timeIntervalSince1970: millis / 1000)
    }
}

/// The Cursor CLI's login in the macOS Keychain (service `cursor-access-token`, account `cursor-user`), read as T3
/// Code's `CursorKeychain` reads it: macOS may ask the user to allow the read, so callers share one read, a token is
/// kept for five minutes, and a read the caller stopped waiting for still finishes for the next one.
actor CursorKeychain {
    static let shared = CursorKeychain()

    private let read: @Sendable () throws -> String?
    private let lifetime: TimeInterval
    private var cached: (token: String, until: Date)?
    private var pending: Task<String?, Error>?

    init(lifetime: TimeInterval = 5 * 60, read: @escaping @Sendable () throws -> String? = CursorKeychain.readItem) {
        self.lifetime = lifetime
        self.read = read
    }

    func accessToken() async throws -> String? {
        if let cached, cached.until > Date() { return cached.token }
        let task: Task<String?, Error>
        if let pending {
            task = pending
        } else {
            // The read blocks while macOS asks the user, so it runs off the actor.
            let read = self.read
            task = Task.detached { try read() }
            pending = task
        }
        defer { if pending == task { pending = nil } }
        let token = try await task.value
        cached = token.map { ($0, Date().addingTimeInterval(lifetime)) }
        return token
    }

    /// The Keychain item the CLI writes (through `@napi-rs/keyring`), nil when there is none. A failure reports only
    /// its status code.
    nonisolated static func readItem() throws -> String? {
        let query: [CFString: Any] = [
            kSecClass: kSecClassGenericPassword,
            kSecAttrService: "cursor-access-token",
            kSecAttrAccount: "cursor-user",
            kSecReturnData: true,
            kSecMatchLimit: kSecMatchLimitOne,
        ]
        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess, let data = result as? Data else {
            throw NSError(domain: NSOSStatusErrorDomain, code: Int(status))
        }
        return String(decoding: data, as: UTF8.self)
    }
}
