import Foundation

/// A website whose usage pages Coincide may read with the user's sign-in in its own browser profile, for details the
/// agents' official APIs don't give: chatgpt.com for Codex's credit limit and credit history, and the Claude Console
/// (platform.claude.com) for the prepaid API credit balance. Each is off until the user turns it on in Settings › Usage.
///
/// These are the websites' own internal endpoints, not public APIs, so they may change without notice; a read that
/// fails leaves what Coincide shows without them and says why. The sign-in never leaves the Mac: its cookies go only
/// in the `Cookie` header of read-only requests to the site they belong to, and nothing here logs cookies, tokens or
/// response bodies.
public enum BrowserUsageSource: String, Codable, CaseIterable, Sendable, Identifiable {
    case chatGPT = "chatgpt"
    case claudeConsole = "claude-console"

    public nonisolated var id: String { rawValue }

    /// The agent whose accounts the details belong to.
    public nonisolated var provider: ProviderKind {
        switch self {
        case .chatGPT: .codex
        case .claudeConsole: .claude
        }
    }

    /// The site the sign-in is for, as the user knows it.
    public nonisolated var host: String {
        switch self {
        case .chatGPT: "chatgpt.com"
        case .claudeConsole: "platform.claude.com"
        }
    }

    /// The page that asks the user to sign in, then shows the usage the details come from.
    public nonisolated var signInURL: URL {
        switch self {
        case .chatGPT: URL(string: "https://chatgpt.com/codex/cloud/settings/analytics")!
        case .claudeConsole: URL(string: "https://platform.claude.com/settings/billing")!
        }
    }
}

/// Why a read of a site's usage pages gave nothing.
public enum BrowserUsageProblem: Sendable, Hashable {
    /// No sign-in for the site in Coincide's browser.
    case notSignedIn
    /// The site no longer accepts the sign-in.
    case sessionExpired
    /// Signed in, but the account may not see the page (a member without billing access, say).
    case forbidden
    /// The Claude account has no Console API organization.
    case noAPIOrganization
    /// The site answered in a shape Coincide doesn't know: it may have changed.
    case unrecognized
    case rateLimited
    /// The site answered with this HTTP status, or a challenge page.
    case unavailable(Int)
    /// The request didn't reach the site.
    case offline

    /// What went wrong, as a sentence of its own.
    public nonisolated var reason: String {
        switch self {
        case .notSignedIn: String(localized: "You aren’t signed in there in Coincide’s browser.")
        case .sessionExpired: String(localized: "The sign-in has expired. Sign in again.")
        case .forbidden: String(localized: "This account may not see its billing.")
        case .noAPIOrganization: String(localized: "This account has no Claude Console API organization.")
        case .unrecognized: String(localized: "The page has changed in a way Coincide doesn’t understand.")
        case .rateLimited: String(localized: "Too many requests. Coincide will try again later.")
        case .unavailable(let status): String(localized: "The site answered with error \(status).")
        case .offline: String(localized: "The site couldn’t be reached.")
        }
    }

    /// Whether signing in (again) is the fix.
    public nonisolated var needsSignIn: Bool {
        switch self {
        case .notSignedIn, .sessionExpired: true
        default: false
        }
    }

    /// The note an account shows instead of the details: "Couldn't read chatgpt.com. … Showing Coincide's own record."
    public nonisolated func note(_ source: BrowserUsageSource) -> String {
        String(localized: "Couldn’t read \(source.host). \(reason) Showing Coincide’s own record.")
    }

    /// The problem an HTTP status other than 200 stands for. A redirect means the site sent the request to its sign-in.
    nonisolated static func forStatus(_ status: Int) -> BrowserUsageProblem {
        switch status {
        case 300..<400: .notSignedIn
        case 401: .sessionExpired
        case 403: .forbidden
        case 429: .rateLimited
        default: .unavailable(status)
        }
    }
}

/// What one read of a site gave: figures to add to the agent's accounts, and who is signed in.
public struct BrowserUsageReading: Sendable, Hashable {
    public var source: BrowserUsageSource
    public var checkedAt: Date
    /// Added to the matching accounts' figures, replacing any with the same ID.
    public var figures: [UsageFigure]
    /// The account's credits, used only where the agent itself reported none.
    public var credits: UsageCredits?
    /// Who the sign-in is, for Settings › Usage: the ChatGPT email or the Console organization's name.
    public var identity: String?
    /// The signed-in email, which picks the Codex account the details belong to.
    public var email: String?

    public nonisolated init(
        source: BrowserUsageSource, checkedAt: Date, figures: [UsageFigure] = [], credits: UsageCredits? = nil,
        identity: String? = nil, email: String? = nil
    ) {
        self.source = source
        self.checkedAt = checkedAt
        self.figures = figures
        self.credits = credits
        self.identity = identity
        self.email = email
    }
}

public enum BrowserUsageOutcome: Sendable, Hashable {
    case reading(BrowserUsageReading)
    case problem(BrowserUsageProblem)
}

/// How a site's reads stand: the last that worked, and why the latest one didn't if it didn't.
public struct BrowserUsageState: Sendable, Hashable {
    public var source: BrowserUsageSource
    public var reading: BrowserUsageReading?
    public var problem: BrowserUsageProblem?
    public var checkedAt: Date?
    public var isReading = false

    public nonisolated init(
        source: BrowserUsageSource, reading: BrowserUsageReading? = nil, problem: BrowserUsageProblem? = nil, checkedAt: Date? = nil
    ) {
        self.source = source
        self.reading = reading
        self.problem = problem
        self.checkedAt = checkedAt
    }
}

/// The `Cookie` header for a site, made from the cookies of Coincide's browser profile.
public enum BrowserCookieHeader {
    /// The cookies that apply to `host` (its own and its parent domains', unexpired), as a `Cookie` header; nil when
    /// none do. Only the names and values go in; nothing is logged.
    public nonisolated static func make(_ cookies: [HTTPCookie], host: String, now: Date = Date()) -> String? {
        let host = host.lowercased()
        let pairs = cookies.filter { cookie in
            if let expires = cookie.expiresDate, expires <= now { return false }
            return applies(domain: cookie.domain, to: host)
        }
        .sorted { $0.path.count > $1.path.count }
        .map { "\($0.name)=\($0.value)" }
        return pairs.isEmpty ? nil : pairs.joined(separator: "; ")
    }

    /// Whether a cookie set for `domain` goes to `host`: the same host, or a host under a domain cookie (`.example.com`
    /// or `example.com` set as a domain cookie).
    nonisolated static func applies(domain: String, to host: String) -> Bool {
        var domain = domain.lowercased()
        if domain.hasPrefix(".") { domain.removeFirst() }
        guard !domain.isEmpty else { return false }
        return host == domain || host.hasSuffix("." + domain)
    }

    /// Whether the header holds a cookie named `name` (or one of its numbered chunks, `name.0`).
    nonisolated static func contains(_ header: String, name: String) -> Bool {
        header.split(separator: ";").contains { pair in
            let key = pair.split(separator: "=", maxSplits: 1).first.map { $0.trimmingCharacters(in: .whitespaces) } ?? ""
            return key == name || key.hasPrefix(name + ".")
        }
    }
}

/// Requests both readers send: read-only GETs that carry the profile's cookies for the one site, follow no redirect
/// (`UsageLimitsHTTP.live`), and cache nothing.
enum BrowserUsageHTTP {
    nonisolated static func get(_ url: URL, cookie: String, headers: [String: String] = [:], timeout: TimeInterval = 15) -> URLRequest {
        var request = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalAndRemoteCacheData, timeoutInterval: timeout)
        request.httpMethod = "GET"
        request.httpShouldHandleCookies = false
        request.setValue(cookie, forHTTPHeaderField: "Cookie")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue("en-US,en;q=0.9", forHTTPHeaderField: "Accept-Language")
        request.setValue("Coincide", forHTTPHeaderField: "User-Agent")
        for (name, value) in headers { request.setValue(value, forHTTPHeaderField: name) }
        return request
    }

    /// Sends `request` and returns its JSON, or the problem. A body that isn't JSON (a challenge page, say) is
    /// `unrecognized` when the status was 200.
    nonisolated static func json(_ request: URLRequest, fetch: UsageLimitsFetch) async -> Result<JSONValue, BrowserUsageProblemError> {
        let data: Data
        let response: HTTPURLResponse
        do {
            (data, response) = try await fetch(request)
        } catch {
            return .failure(BrowserUsageProblemError(problem: .offline))
        }
        guard response.statusCode == 200 else { return .failure(BrowserUsageProblemError(problem: .forStatus(response.statusCode))) }
        guard let json = JSONValue.parse(data) else { return .failure(BrowserUsageProblemError(problem: .unrecognized)) }
        return .success(json)
    }

    /// A number the site may send as a number or as text.
    nonisolated static func number(_ value: JSONValue?) -> Double? {
        if let number = value?.number, number.isFinite { return number }
        if let text = value?.string, let number = Double(text.trimmingCharacters(in: .whitespaces)), number.isFinite { return number }
        return nil
    }

    /// A non-empty trimmed string.
    nonisolated static func text(_ value: JSONValue?) -> String? {
        guard let text = value?.string?.trimmingCharacters(in: .whitespacesAndNewlines), !text.isEmpty else { return nil }
        return text
    }
}

/// A `BrowserUsageProblem` as an `Error`, for `Result`.
struct BrowserUsageProblemError: Error, Hashable {
    var problem: BrowserUsageProblem
}
