import Foundation
import SQLite3

/// Reads the OpenCode Go plan's usage windows from opencode.ai, following T3 Code's `readOpenCodeGoUsageLimits`.
///
/// The key is the one OpenCode itself uses: the Console key OpenCode 2 selected in its database, else the Go key in
/// `auth.json` (or `OPENCODE_API_KEY`). Coincide always runs its own `opencode serve`, so these are the files of the
/// OpenCode it launches; `XDG_DATA_HOME`, `OPENCODE_DB` and `OPENCODE_AUTH_CONTENT` move them as they move OpenCode's.
enum OpenCodeUsageLimits {
    nonisolated static let usageURL = URL(string: "https://opencode.ai/zen/go/v1/usage")!
    /// The only Console a stored key may belong to.
    nonisolated static let consoleServer = "https://opencode.ai/console"
    nonisolated static let sessionMinutes = 5 * 60
    nonisolated static let weekMinutes = 7 * 24 * 60

    /// Where OpenCode's credentials are read from. Tests pass their own, so they never touch the real files.
    struct Credentials: Sendable {
        /// A file's contents, nil when there is no such file.
        var readFile: @Sendable (URL) throws -> Data?
        /// The Console key OpenCode 2 selected in the database at a path, nil when there is none.
        var consoleKey: @Sendable (URL) -> String?
        /// Used when the environment has no `HOME`.
        var homeDirectory: URL

        nonisolated static let live = Credentials(
            readFile: readFileIfPresent, consoleKey: OpenCodeUsageLimits.consoleKey(databaseAt:),
            homeDirectory: FileManager.default.homeDirectoryForCurrentUser)
    }

    /// Reads the plan's windows within `timeout` (T3's 5 seconds). A key without a Go subscription reads nothing.
    @concurrent nonisolated static func read(
        environment: [String: String], credentials: Credentials = .live,
        fetch: @escaping UsageLimitsFetch = UsageLimitsHTTP.live, timeout: Duration = .seconds(5), now: Date = Date()
    ) async -> UsageLimitsOutcome {
        do {
            return try await usageLimitsWithTimeout(timeout) {
                try await readWindows(environment: environment, credentials: credentials, fetch: fetch, timeout: timeout, now: now)
            }
        } catch {
            return .failed
        }
    }

    private nonisolated static func readWindows(
        environment: [String: String], credentials: Credentials, fetch: UsageLimitsFetch, timeout: Duration, now: Date
    ) async throws -> UsageLimitsOutcome {
        func value(_ key: String) -> String? { environment[key].flatMap { $0.isEmpty ? nil : $0 } }
        let dataHome =
            value("XDG_DATA_HOME").map { URL(fileURLWithPath: $0) }
            ?? (value("HOME").map { URL(fileURLWithPath: $0) } ?? credentials.homeDirectory).appending(path: ".local/share")
        let directory = dataHome.appending(path: "opencode")
        let inline = value("OPENCODE_AUTH_CONTENT")
        let auth: JSONValue
        if let contents = try inline.map({ Data($0.utf8) }) ?? credentials.readFile(directory.appending(path: "auth.json")) {
            guard let parsed = JSONValue.parse(contents), parsed.object != nil else { throw CocoaError(.fileReadCorruptFile) }
            auth = parsed
        } else {
            auth = [:]
        }
        // OpenCode lays stored API credentials over the environment's.
        let goEntry = auth["opencode-go"]
        let storedKey = goEntry?["type"]?.string == "api" ? goEntry?["key"]?.string : nil
        let goKey = (storedKey ?? environment["OPENCODE_API_KEY"])?.trimmedNonEmpty
        // OpenCode 2 gets Go credentials from the Console. Inline auth overrides everything stored, the Console
        // connection included.
        let databaseFile = environment["OPENCODE_DB"] ?? "opencode.db"
        let consoleKey =
            inline != nil || databaseFile == ":memory:"
            ? nil
            : credentials.consoleKey(
                databaseFile.hasPrefix("/") ? URL(fileURLWithPath: databaseFile) : directory.appending(path: databaseFile))
        guard var key = consoleKey?.trimmedNonEmpty ?? goKey else { return .unsupported }

        func usage(_ key: String) async throws -> (Data, HTTPURLResponse) {
            try await fetch(UsageLimitsHTTP.request(usageURL, token: key, timeout: timeout.timeInterval))
        }
        var (data, response) = try await usage(key)
        if response.statusCode == 401 || response.statusCode == 403, let goKey, goKey != key {
            key = goKey
            (data, response) = try await usage(key)
        }
        // A valid Zen key can exist without a Go subscription.
        if response.statusCode == 403 { return .unsupported }
        guard (200..<300).contains(response.statusCode), let body = JSONValue.parse(data),
            let windows = windows(fromResponse: body)
        else { return .failed }
        return .limits(UsageLimits(windows: windows, checkedAt: now))
    }

    /// The Go plan's rolling five-hour, weekly and monthly windows; nil unless the answer has all three.
    nonisolated static func windows(fromResponse response: JSONValue) -> [UsageLimitWindow]? {
        func window(_ name: String) -> (used: Double, resetsAt: Date)? {
            guard let value = response.at("usage.\(name)"), let used = value["percent"]?.number, used.isFinite,
                let resetsAt = date(fromISO: value["resetsAt"]?.string)
            else { return nil }
            return (used, resetsAt)
        }
        guard let rolling = window("rolling"), let weekly = window("weekly"), let monthly = window("monthly") else {
            return nil
        }
        return [
            UsageLimitWindow(
                id: "go_rolling", kind: .session, label: String(localized: "Go · Session"), usedPercent: rolling.used,
                resetsAt: rolling.resetsAt, durationMinutes: sessionMinutes),
            UsageLimitWindow(
                id: "go_weekly", kind: .weekly, label: String(localized: "Go · Weekly"), usedPercent: weekly.used,
                resetsAt: weekly.resetsAt, durationMinutes: weekMinutes),
            UsageLimitWindow(
                id: "go_monthly", kind: .monthly, label: String(localized: "Go · Monthly"), usedPercent: monthly.used,
                resetsAt: monthly.resetsAt),
        ]
    }

    nonisolated static func date(fromISO text: String?) -> Date? {
        guard let text, !text.isEmpty else { return nil }
        return (try? Date.ISO8601FormatStyle(includingFractionalSeconds: true).parse(text))
            ?? (try? Date.ISO8601FormatStyle().parse(text))
    }

    /// The Console key in OpenCode 2's database, opened read-only: the `opencode` credential OpenCode selected (rows
    /// with no selection flag predate it and count by age). The row is picked before it is decoded, so an OAuth or
    /// self-hosted Console connection never falls through to another stored account. Nil when there is none or the
    /// database can't be read.
    nonisolated static func consoleKey(databaseAt url: URL) -> String? {
        var database: OpaquePointer?
        defer { sqlite3_close(database) }
        guard sqlite3_open_v2(url.path(percentEncoded: false), &database, SQLITE_OPEN_READONLY | SQLITE_OPEN_NOMUTEX, nil)
            == SQLITE_OK
        else {
            return nil
        }
        // Fail promptly while OpenCode holds a write lock.
        sqlite3_busy_timeout(database, 100)
        var statement: OpaquePointer?
        defer { sqlite3_finalize(statement) }
        let query = """
            SELECT value FROM credential
            WHERE integration_id = 'opencode' AND active IS NOT 0
            ORDER BY active DESC, time_created DESC, id DESC LIMIT 1
            """
        guard sqlite3_prepare_v2(database, query, -1, &statement, nil) == SQLITE_OK,
            sqlite3_step(statement) == SQLITE_ROW, sqlite3_column_type(statement, 0) == SQLITE_TEXT,
            let text = sqlite3_column_text(statement, 0)
        else { return nil }
        return consoleKey(fromStoredValue: String(cString: text))
    }

    /// The key of a stored credential, which OpenCode 2's database tags `key` (`auth.json` tags it `api`); nil for
    /// another kind of credential or one that belongs to a Console other than opencode.ai's.
    nonisolated static func consoleKey(fromStoredValue value: String) -> String? {
        guard let stored = JSONValue.parse(value), stored["type"]?.string == "key", let key = stored["key"]?.string
        else { return nil }
        let metadata = stored["metadata"]
        if let metadata, !metadata.isNull, metadata.object == nil { return nil }
        if let server = metadata?["server"]?.string {
            // Compared as origin and path without trailing slashes, as T3 compares them.
            guard let url = URL(string: server), let scheme = url.scheme?.lowercased(), let host = url.host()?.lowercased()
            else { return nil }
            var path = url.path()
            while path.hasSuffix("/") { path.removeLast() }
            let defaultPort = ["https": 443, "http": 80][scheme]
            let port = url.port.flatMap { $0 == defaultPort ? nil : ":\($0)" } ?? ""
            guard "\(scheme)://\(host)\(port)\(path)" == consoleServer else { return nil }
        }
        return key.trimmedNonEmpty
    }
}
