import CryptoKit
import Foundation

/// Reads Antigravity's subscription quotas from Google's Cloud Code service, following T3 Code's
/// `antigravityUsageLimits`: the private profile's sign-in (`acp_token.json`) is refreshed into a short-lived access
/// token, which asks both Cloud Code endpoints for the account's quota summary, or for per-model quotas on accounts
/// that have no summary.
enum AntigravityUsageLimits {
    /// Both Cloud Code endpoints. Their quota groups differ, so both are asked and their answers merged.
    nonisolated static let endpoints = ["https://daily-cloudcode-pa.googleapis.com", "https://cloudcode-pa.googleapis.com"]
    nonisolated static let tokenURL = URL(string: "https://oauth2.googleapis.com/token")!
    nonisolated static let sessionMinutes = 5 * 60
    nonisolated static let weekMinutes = 7 * 24 * 60
    /// Each request gets T3's 10 seconds, which bounds a check (refresh, summary, model quotas) to about 30.
    nonisolated static let requestTimeout: Duration = .seconds(10)

    /// The Google sign-in Antigravity keeps in the profile (T3's `TokenFile`).
    struct Token: Sendable, Hashable {
        var clientID: String
        var clientSecret: String
        var refreshToken: String
        var projectID: String?
    }

    /// The token file's sign-in, nil when it is not the expected shape.
    nonisolated static func token(fromFile data: Data) -> Token? {
        guard let json = JSONValue.parse(data), json.object != nil,
            let clientID = json["client_id"]?.string, !clientID.isEmpty,
            let clientSecret = json["client_secret"]?.string, !clientSecret.isEmpty,
            let refreshToken = json["refresh_token"]?.string, !refreshToken.isEmpty,
            json["project_id"] == nil || json["project_id"]?.string != nil
        else { return nil }
        return Token(clientID: clientID, clientSecret: clientSecret, refreshToken: refreshToken, projectID: json["project_id"]?.string)
    }

    /// Identifies a sign-in without keeping its secrets as a key: a cached access token is only reused for the same one.
    nonisolated static func fingerprint(_ token: Token) -> String {
        let text = token.clientID + "\0" + token.refreshToken + "\0" + (token.projectID ?? "")
        return SHA256.hash(data: Data(text.utf8)).map { String(format: "%02x", $0) }.joined()
    }

    /// Exchanges the refresh token for an access token. The secrets go in the form body, never in the URL.
    nonisolated static func refreshRequest(_ token: Token) -> URLRequest {
        var request = URLRequest(
            url: tokenURL, cachePolicy: .reloadIgnoringLocalAndRemoteCacheData, timeoutInterval: requestTimeout.timeInterval)
        request.httpMethod = "POST"
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        request.httpBody = formBody([
            ("client_id", token.clientID), ("client_secret", token.clientSecret), ("refresh_token", token.refreshToken),
            ("grant_type", "refresh_token"),
        ])
        return request
    }

    /// The access token and its lifetime in seconds from a refresh answer.
    nonisolated static func accessToken(fromRefresh response: JSONValue) -> (token: String, expiresIn: TimeInterval)? {
        guard let token = response["access_token"]?.string, !token.isEmpty, let expiresIn = response["expires_in"]?.number,
            expiresIn.isFinite, expiresIn > 0
        else { return nil }
        return (token, expiresIn)
    }

    /// `v1internal:<operation>` on one endpoint, for the token's project when it names one.
    nonisolated static func quotaRequest(endpoint: String, operation: String, accessToken: String, projectID: String?) -> URLRequest {
        var request = UsageLimitsHTTP.request(
            URL(string: "\(endpoint)/v1internal:\(operation)")!, method: "POST", token: accessToken,
            timeout: requestTimeout.timeInterval)
        request.setValue(userAgent, forHTTPHeaderField: "User-Agent")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        let body: JSONValue = projectID.flatMap { $0.isEmpty ? nil : $0 }.map { ["project": .string($0)] } ?? [:]
        request.httpBody = Data(body.compactJSON.utf8)
        return request
    }

    /// The client Google's quota service expects (T3's), with Node's names for the platform and architecture.
    nonisolated static var userAgent: String {
        let architecture = AntigravityRelease.hostArchitecture == "arm64" ? "arm64" : "x64"
        return "antigravity/hub/1.0.0 (aidev_client; os_type=darwin; arch=\(architecture); cl=963137146)"
    }

    /// The windows of a `retrieveUserQuotaSummary` answer: a five-hour and a weekly window for Gemini and for the
    /// Claude and GPT models, which share theirs. Disabled buckets and ones without a remaining fraction are left out.
    /// Nil when the answer is not the expected shape.
    nonisolated static func windows(fromSummary response: JSONValue) -> [UsageLimitWindow]? {
        guard response.object != nil else { return nil }
        let groups: [(name: String?, buckets: [JSONValue])]
        do {
            let listed = try (field(response["groups"], \.array) ?? []).map { group -> (name: String?, buckets: [JSONValue]) in
                guard group.object != nil else { throw Malformed() }
                return (try field(group["displayName"], \.string), try field(group["buckets"], \.array) ?? [])
            }
            let ungrouped = try field(response["buckets"], \.array) ?? []
            for bucket in listed.flatMap(\.buckets) + ungrouped where !isBucket(bucket) { throw Malformed() }
            groups = listed.contains { !$0.buckets.isEmpty } ? listed : [(nil, ungrouped)]
        } catch {
            return nil
        }
        var windows: [String: UsageLimitWindow] = [:]
        for group in groups {
            for bucket in group.buckets where bucket["disabled"]?.bool != true {
                guard let id = bucket["bucketId"]?.string else { continue }
                let family =
                    id.hasPrefix("gemini-")
                    ? "Gemini"
                    : id.hasPrefix("3p-")
                        ? String(localized: "Claude & GPT (shared)") : group.name?.trimmedNonEmpty ?? id
                let window = bucket["window"]?.string
                let kind: UsageLimitWindow.Kind = window == "weekly" ? .weekly : window == "5h" ? .session : .other
                let period =
                    switch kind {
                    case .weekly: String(localized: "Weekly")
                    case .session: String(localized: "5-hour")
                    default: bucket["displayName"]?.string?.trimmedNonEmpty ?? String(localized: "Quota")
                    }
                if let window = quotaWindow(
                    id: id, label: String(localized: "\(family) · \(period)"), quota: bucket, kind: kind,
                    minutes: kind == .weekly ? weekMinutes : kind == .session ? sessionMinutes : nil)
                {
                    windows[id] = window
                }
            }
        }
        return Array(windows.values)
    }

    /// The windows of a `fetchAvailableModels` answer, for older accounts without a quota summary: each model family's
    /// most used quota. These name no window length, so none is invented. Nil when the answer is not the expected shape.
    nonisolated static func windows(fromModels response: JSONValue) -> [UsageLimitWindow]? {
        guard response.object != nil, let models = response["models"]?.object,
            models.values.allSatisfy({ model in
                model.object != nil && (model["modelProvider"] == nil || model["modelProvider"]?.string != nil)
                    && ["quotaInfo", "weeklyQuotaInfo"].allSatisfy { model[$0] == nil || isQuota(model[$0]!) }
            })
        else { return nil }
        var windows: [String: UsageLimitWindow] = [:]
        for (id, model) in models.sorted(by: { $0.key < $1.key }) {
            let provider = model["modelProvider"]?.string
            let family: String
            if provider == "MODEL_PROVIDER_GOOGLE" || id.hasPrefix("gemini-") {
                family = "Gemini"
            } else if provider == "MODEL_PROVIDER_ANTHROPIC" || id.hasPrefix("claude-") {
                family = "Claude"
            } else if provider == "MODEL_PROVIDER_OPENAI" || id.hasPrefix("gpt-") {
                family = "GPT"
            } else {
                continue
            }
            for (suffix, quota) in [("quota", model["quotaInfo"]), ("weekly", model["weeklyQuotaInfo"])] {
                guard let quota else { continue }
                let weekly = suffix == "weekly"
                let period = weekly ? String(localized: "Weekly") : String(localized: "Reported quota")
                guard
                    let window = quotaWindow(
                        id: "\(family.lowercased())-\(suffix)", label: String(localized: "\(family) · \(period)"), quota: quota,
                        kind: weekly ? .weekly : .other, minutes: weekly ? weekMinutes : nil)
                else { continue }
                if let previous = windows[window.id], previous.usedPercent >= window.usedPercent { continue }
                windows[window.id] = window
            }
        }
        return Array(windows.values)
    }

    /// The answers of both endpoints as one list, in endpoint order: each window as the answer that used most of it
    /// reports it.
    nonisolated static func merged(_ answers: [[UsageLimitWindow]]) -> [UsageLimitWindow] {
        var windows: [String: UsageLimitWindow] = [:]
        for window in answers.joined() {
            if let previous = windows[window.id], previous.usedPercent >= window.usedPercent { continue }
            windows[window.id] = window
        }
        return Array(windows.values)
    }

    private struct Malformed: Error {}

    private nonisolated static func quotaWindow(
        id: String, label: String, quota: JSONValue, kind: UsageLimitWindow.Kind, minutes: Int?
    ) -> UsageLimitWindow? {
        guard let remaining = quota["remainingFraction"]?.number, remaining.isFinite else { return nil }
        return UsageLimitWindow(
            id: id, kind: kind, label: label, usedPercent: (1 - min(1, max(0, remaining))) * 100,
            resetsAt: UsageLimitDates.instant(quota["resetTime"]?.string), durationMinutes: minutes)
    }

    /// A quota: an object whose `remainingFraction` (a number) and `resetTime` (text) may each be missing.
    private nonisolated static func isQuota(_ value: JSONValue) -> Bool {
        value.object != nil && (value["remainingFraction"] == nil || value["remainingFraction"]?.number != nil)
            && (value["resetTime"] == nil || value["resetTime"]?.string != nil)
    }

    /// A summary bucket: a quota with a `bucketId`, and optional `window`, `displayName` and `disabled`.
    private nonisolated static func isBucket(_ value: JSONValue) -> Bool {
        guard isQuota(value), let id = value["bucketId"]?.string, !id.isEmpty else { return false }
        return ["window", "displayName"].allSatisfy { value[$0] == nil || value[$0]?.string != nil }
            && (value["disabled"] == nil || value["disabled"]?.bool != nil)
    }

    /// An optional field: absent is fine, a value of another type than `read` takes is not.
    private nonisolated static func field<T>(_ value: JSONValue?, _ read: (JSONValue) -> T?) throws -> T? {
        guard let value else { return nil }
        guard let typed = read(value) else { throw Malformed() }
        return typed
    }

    /// `application/x-www-form-urlencoded`, as a browser's `URLSearchParams` writes it.
    nonisolated static func formBody(_ fields: [(String, String)]) -> Data {
        let allowed = CharacterSet(charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789*-._ ")
        func encode(_ text: String) -> String {
            (text.addingPercentEncoding(withAllowedCharacters: allowed) ?? "").replacingOccurrences(of: " ", with: "+")
        }
        return Data(fields.map { encode($0.0) + "=" + encode($0.1) }.joined(separator: "&").utf8)
    }

    /// Sends one request within `requestTimeout`: the answer's JSON when its status is 2xx, else nil.
    nonisolated static func send(_ request: URLRequest, with fetch: @escaping UsageLimitsFetch) async -> JSONValue? {
        try? await usageLimitsWithTimeout(requestTimeout) { () async throws -> JSONValue? in
            let (data, response) = try await fetch(request)
            return (200..<300).contains(response.statusCode) ? JSONValue.parse(data) : nil
        }
    }
}

/// Reads Antigravity's limits for a profile, keeping the access token between checks until a minute before it expires
/// (T3 Code's `makeAntigravityUsageProbe`). A changed sign-in, a sign-out or `clear` drops it.
@MainActor
final class AntigravityUsageProbe {
    static let shared = AntigravityUsageProbe()

    private struct Access {
        var fingerprint: String
        var token: String
        var expiresAt: Date
    }

    private let fetch: UsageLimitsFetch
    private let now: () -> Date
    /// Access tokens by token file.
    private var cached: [String: Access] = [:]
    /// Bumped by `clear`, so a check that was running then does not keep the token it got.
    private var generation = 0

    /// `fetch` and `now` replace the network and the clock in tests.
    init(fetch: @escaping UsageLimitsFetch = UsageLimitsHTTP.live, now: @escaping () -> Date = Date.init) {
        self.fetch = fetch
        self.now = now
    }

    func read(_ profile: AntigravityProfile) async -> UsageLimitsOutcome {
        let key = profile.tokenFile.path
        let started = generation
        let checkedAt = now()
        guard profile.isSignedIn else {
            cached[key] = nil
            return .unsupported
        }
        guard let data = try? Data(contentsOf: profile.tokenFile), let token = AntigravityUsageLimits.token(fromFile: data)
        else { return .failed }
        let fingerprint = AntigravityUsageLimits.fingerprint(token)
        let accessToken: String
        if let access = cached[key], access.fingerprint == fingerprint, access.expiresAt > checkedAt.addingTimeInterval(60) {
            accessToken = access.token
        } else {
            cached[key] = nil
            guard let answer = await AntigravityUsageLimits.send(AntigravityUsageLimits.refreshRequest(token), with: fetch),
                let refreshed = AntigravityUsageLimits.accessToken(fromRefresh: answer)
            else { return .failed }
            accessToken = refreshed.token
            if generation == started {
                cached[key] = Access(
                    fingerprint: fingerprint, token: refreshed.token, expiresAt: checkedAt.addingTimeInterval(refreshed.expiresIn))
            }
        }
        var windows = await quotaWindows(
            "retrieveUserQuotaSummary", accessToken: accessToken, projectID: token.projectID,
            parse: AntigravityUsageLimits.windows(fromSummary:))
        if windows.isEmpty {
            windows = await quotaWindows(
                "fetchAvailableModels", accessToken: accessToken, projectID: token.projectID,
                parse: AntigravityUsageLimits.windows(fromModels:))
        }
        guard !windows.isEmpty else { return .failed }
        return .limits(UsageLimits(windows: windows, checkedAt: checkedAt))
    }

    /// Forgets the access tokens, after a sign-out.
    func clear() {
        cached.removeAll()
        generation += 1
    }

    /// Asks both endpoints at once; one that fails or answers in another shape counts as having no windows.
    private func quotaWindows(
        _ operation: String, accessToken: String, projectID: String?,
        parse: @escaping @Sendable (JSONValue) -> [UsageLimitWindow]?
    ) async -> [UsageLimitWindow] {
        let requests = AntigravityUsageLimits.endpoints.map {
            AntigravityUsageLimits.quotaRequest(endpoint: $0, operation: operation, accessToken: accessToken, projectID: projectID)
        }
        let fetch = fetch
        let answers = await withTaskGroup(of: (Int, [UsageLimitWindow]).self) { group in
            for (index, request) in requests.enumerated() {
                group.addTask {
                    let windows = await AntigravityUsageLimits.send(request, with: fetch).flatMap(parse)
                    return (index, windows ?? [])
                }
            }
            var answers: [(Int, [UsageLimitWindow])] = []
            for await answer in group { answers.append(answer) }
            return answers
        }
        return AntigravityUsageLimits.merged(answers.sorted { $0.0 < $1.0 }.map(\.1))
    }
}
