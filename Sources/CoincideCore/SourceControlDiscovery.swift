import Foundation

public struct SourceControlToolStatus: Sendable, Equatable {
    public let name: String
    public let path: String?
    public let version: String?
    public let minimumVersion: String?
    public let error: String?
    public var isInstalled: Bool { path != nil }
    public init(name: String, path: String?, version: String?, minimumVersion: String?, error: String?) {
        self.name = name; self.path = path; self.version = version; self.minimumVersion = minimumVersion; self.error = error
    }
    public var meetsMinimum: Bool? {
        guard let version, let minimumVersion else { return nil }
        return SourceControlDiscovery.compareVersions(version, minimumVersion) != .orderedAscending
    }
}

public struct GitHubAuthAccount: Sendable, Equatable, Identifiable {
    public let host: String
    public let login: String
    public let authenticated: Bool
    public let active: Bool
    public let error: String?
    /// Where gh found the credential, e.g. `keyring`, `GH_TOKEN` or a config path. Never the token.
    public let tokenSource: String?
    public var id: String { host + "\u{0}" + login }
    public var environmentVariable: String? {
        tokenSource.flatMap { $0.range(of: "^(GH|GITHUB)_(ENTERPRISE_)?TOKEN$", options: .regularExpression) != nil ? $0 : nil }
    }
    public init(host: String, login: String, authenticated: Bool, active: Bool, error: String? = nil, tokenSource: String? = nil) {
        self.host = host.lowercased(); self.login = login; self.authenticated = authenticated; self.active = active; self.error = error; self.tokenSource = tokenSource
    }
}

public struct SourceControlHostStatus: Sendable, Equatable, Identifiable {
    public let host: String
    public let accounts: [GitHubAuthAccount]
    public let usedByProjects: Bool
    public var id: String { host }
    public init(host: String, accounts: [GitHubAuthAccount], usedByProjects: Bool) { self.host = host; self.accounts = accounts; self.usedByProjects = usedByProjects }
    /// T3's precedence: an environment token, then the active authenticated account, then any authenticated one.
    public var effectiveAccount: GitHubAuthAccount? {
        let usable = accounts.filter(\.authenticated)
        return usable.first { $0.environmentVariable != nil } ?? usable.first(where: \.active) ?? usable.first
    }
}

public struct SourceControlDiscoveryReport: Sendable, Equatable {
    public let git: SourceControlToolStatus
    public let gh: SourceControlToolStatus
    public let hosts: [SourceControlHostStatus]
    /// False when gh's structured status was unavailable and the text fallback was used.
    public let structuredStatus: Bool
    public let authError: String?
    public let scannedAt: Date
    public init(git: SourceControlToolStatus, gh: SourceControlToolStatus, hosts: [SourceControlHostStatus], structuredStatus: Bool, authError: String?, scannedAt: Date) {
        self.git = git; self.gh = gh; self.hosts = hosts; self.structuredStatus = structuredStatus; self.authError = authError; self.scannedAt = scannedAt
    }
}

/// Detects Git and GitHub CLI and reads `gh auth status` per host. Only fixed read-only commands
/// run; `--show-token` is never passed and no raw output is retained.
public struct SourceControlDiscovery: Sendable {
    public static let minimumGitHubCLI = "2.81.0"
    let environment: [String: String]?
    let gitExecutable: URL?
    let githubExecutable: URL?
    let credentials: GitHubCredentialOverrides?
    let timeout: Duration
    public init(timeout: Duration = .seconds(15)) {
        environment = nil; gitExecutable = ProcessChannel.findExecutable("git"); githubExecutable = ProcessChannel.findExecutable("gh")
        credentials = .shared; self.timeout = timeout
    }
    init(environment: [String: String], gitExecutable: URL?, githubExecutable: URL?, credentials: GitHubCredentialOverrides? = nil, timeout: Duration = .seconds(15)) {
        self.environment = environment; self.gitExecutable = gitExecutable; self.githubExecutable = githubExecutable; self.credentials = credentials; self.timeout = timeout
    }

    public func scan(hosts projectHosts: [String]) async -> SourceControlDiscoveryReport {
        let git = await tool("Git", executable: gitExecutable, arguments: ["--version"], minimum: nil)
        let gh = await tool("GitHub CLI", executable: githubExecutable, arguments: ["--version"], minimum: Self.minimumGitHubCLI)
        let requested = Set(projectHosts.map { $0.lowercased() }).union(["github.com"])
        var accounts: [GitHubAuthAccount] = [], structured = false, authError: String?
        if let executable = githubExecutable, gh.version != nil {
            if gh.meetsMinimum == true, let result = try? await run(executable, ["auth", "status", "--json", "hosts"]),
               let parsed = Self.parseAuthStatusJSON(result.output) {
                accounts = parsed; structured = true
            } else if let result = try? await run(executable, ["auth", "status"]) {
                accounts = Self.parseAuthStatusText(String(decoding: result.output + result.error, as: UTF8.self))
                if accounts.isEmpty { authError = String(localized: "GitHub CLI is not signed in to any host.") }
            } else { authError = String(localized: "GitHub CLI sign-in status could not be read.") }
        }
        let names = requested.union(accounts.map(\.host)).sorted { $0 == "github.com" ? true : $1 == "github.com" ? false : $0 < $1 }
        let hosts = names.map { host in
            SourceControlHostStatus(host: host, accounts: accounts.filter { $0.host == host }, usedByProjects: projectHosts.contains { $0.lowercased() == host })
        }
        return .init(git: git, gh: gh, hosts: hosts, structuredStatus: structured, authError: authError, scannedAt: Date())
    }

    private func tool(_ name: String, executable: URL?, arguments: [String], minimum: String?) async -> SourceControlToolStatus {
        guard let executable else { return .init(name: name, path: nil, version: nil, minimumVersion: minimum, error: nil) }
        do {
            let result = try await run(executable, arguments)
            guard result.status == 0, let version = Self.parseVersion(String(decoding: result.output, as: UTF8.self)) else {
                return .init(name: name, path: executable.path, version: nil, minimumVersion: minimum, error: String(localized: "The version could not be read."))
            }
            return .init(name: name, path: executable.path, version: version, minimumVersion: minimum, error: nil)
        } catch { return .init(name: name, path: executable.path, version: nil, minimumVersion: minimum, error: String(localized: "The version could not be read.")) }
    }

    private func run(_ executable: URL, _ arguments: [String]) async throws -> CommandResult {
        var env = environment ?? ProcessChannel.environment()
        for key in ["GH_DEBUG", "DEBUG", "GH_FORCE_TTY", "CLICOLOR_FORCE", "GH_REPO", "GIT_TRACE", "GIT_CURL_VERBOSE"] { env.removeValue(forKey: key) }
        env["GH_PROMPT_DISABLED"] = "1"; env["GH_NO_UPDATE_NOTIFIER"] = "1"; env["GH_NO_EXTENSION_UPDATE_NOTIFIER"] = "1"; env["GH_SPINNER_DISABLED"] = "1"
        env["NO_COLOR"] = "1"; env["CLICOLOR"] = "0"; env["GH_PAGER"] = "/bin/cat"; env["GH_TELEMETRY"] = "false"; env["LC_ALL"] = "C"; env["GIT_TERMINAL_PROMPT"] = "0"
        credentials?.apply(to: &env, host: "github.com")
        return try await CommandRunner.run(executable.path, arguments, limit: 1_048_576, timeout: timeout, environment: env)
    }

    public static func parseVersion(_ text: String) -> String? {
        guard let regex = try? NSRegularExpression(pattern: "(?:git|gh) version ([0-9]+(?:\\.[0-9]+){1,3})"),
              let match = regex.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)), let range = Range(match.range(at: 1), in: text) else { return nil }
        return String(text[range])
    }
    public static func compareVersions(_ a: String, _ b: String) -> ComparisonResult {
        let left = a.split(separator: ".").map { Int($0) ?? 0 }, right = b.split(separator: ".").map { Int($0) ?? 0 }
        for index in 0..<max(left.count, right.count) {
            let x = index < left.count ? left[index] : 0, y = index < right.count ? right[index] : 0
            if x != y { return x < y ? .orderedAscending : .orderedDescending }
        }
        return .orderedSame
    }

    /// `gh auth status --json hosts` (gh 2.81+). Unknown fields are ignored; tokens are never read.
    public static func parseAuthStatusJSON(_ data: Data) -> [GitHubAuthAccount]? {
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any], let hosts = root["hosts"] as? [String: Any] else { return nil }
        var accounts: [GitHubAuthAccount] = []
        for key in hosts.keys.sorted() {
            guard let rows = hosts[key] as? [[String: Any]] else { return nil }
            for row in rows.prefix(32) {
                guard let host = (row["host"] as? String)?.trimmingCharacters(in: .whitespaces), !host.isEmpty, host.utf8.count <= 253,
                      let login = (row["login"] as? String)?.trimmingCharacters(in: .whitespaces), !login.isEmpty, login.utf8.count <= 256 else { continue }
                accounts.append(.init(host: host, login: login, authenticated: row["state"] as? String == "success", active: row["active"] as? Bool ?? false,
                                      error: (row["error"] as? String).map { String($0.prefix(500)) }.flatMap { $0.isEmpty ? nil : $0 },
                                      tokenSource: (row["tokenSource"] as? String).flatMap { safeSource($0) }))
            }
        }
        return accounts
    }

    /// Text from older gh releases, e.g. `✓ Logged in to github.com account octocat (keyring)`
    /// followed by `- Active account: true`. Token lines are ignored.
    public static func parseAuthStatusText(_ text: String) -> [GitHubAuthAccount] {
        guard let regex = try? NSRegularExpression(pattern: "^\\s*(✓|X|x|×)\\s+(Logged in|Failed to log in) to (\\S+) (?:account|as) (\\S+?)(?: \\(([^)]*)\\))?\\s*$") else { return [] }
        var accounts: [GitHubAuthAccount] = []
        for line in text.components(separatedBy: .newlines) {
            if let match = regex.firstMatch(in: line, range: NSRange(line.startIndex..., in: line)) {
                func group(_ index: Int) -> String? { Range(match.range(at: index), in: line).map { String(line[$0]) } }
                guard let host = group(3), let login = group(4) else { continue }
                accounts.append(.init(host: host, login: login, authenticated: group(2) == "Logged in", active: true, tokenSource: group(5).flatMap(safeSource)))
            } else if let last = accounts.last, line.trimmingCharacters(in: .whitespaces).lowercased().hasPrefix("- active account:") {
                let active = line.lowercased().contains("true")
                accounts[accounts.count - 1] = .init(host: last.host, login: last.login, authenticated: last.authenticated, active: active, error: last.error, tokenSource: last.tokenSource)
            }
        }
        return accounts
    }
    /// Keeps a short credential source label and drops anything that could be a secret or a private path.
    static func safeSource(_ value: String) -> String? {
        let trimmed = value.trimmingCharacters(in: .whitespaces)
        if ["keyring", "oauth_token", "GH_TOKEN", "GITHUB_TOKEN", "GH_ENTERPRISE_TOKEN", "GITHUB_ENTERPRISE_TOKEN"].contains(trimmed) { return trimmed }
        if trimmed.hasSuffix("hosts.yml") { return "hosts.yml" }
        return nil
    }
}
