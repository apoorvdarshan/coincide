import Foundation

/// An organization's usage and cost as Anthropic's Admin API reports them, read with an Admin API key the user added to
/// a Claude Code API-key account (Usage and Cost API: `GET /v1/organizations/usage_report/messages` and
/// `GET /v1/organizations/cost_report`). Tokens are narrowed to the account's own API key when the organization's key
/// list (`GET /v1/organizations/api_keys`) names exactly one key matching it; costs can't be narrowed to a key, so
/// they are always the organization's. Days are UTC, as the reports bucket them. Neither report shows a prepaid
/// credit balance.
///
/// The key goes only in the `x-api-key` header, never in a URL or a log. Nothing here runs on its own: `UsageInsights`
/// reads the reports at most every 15 minutes and when the user refreshes.
public enum AnthropicAdminUsage {
    /// Whose usage a figure covers.
    public enum Scope: Sendable, Hashable {
        /// The account's own API key, by its name in the Console.
        case apiKey(name: String)
        case organization
    }

    /// Tokens of one report row, as the usage report splits them.
    public struct Tokens: Sendable, Hashable {
        public var uncachedInput = 0
        public var cacheRead = 0
        /// Cache writes, five-minute and one-hour together.
        public var cacheCreation = 0
        public var output = 0

        public nonisolated init(uncachedInput: Int = 0, cacheRead: Int = 0, cacheCreation: Int = 0, output: Int = 0) {
            self.uncachedInput = uncachedInput
            self.cacheRead = cacheRead
            self.cacheCreation = cacheCreation
            self.output = output
        }

        public nonisolated var total: Int { uncachedInput + cacheRead + cacheCreation + output }

        nonisolated static func + (lhs: Tokens, rhs: Tokens) -> Tokens {
            Tokens(
                uncachedInput: lhs.uncachedInput + rhs.uncachedInput, cacheRead: lhs.cacheRead + rhs.cacheRead,
                cacheCreation: lhs.cacheCreation + rhs.cacheCreation, output: lhs.output + rhs.output)
        }
    }

    /// One model's tokens and cost this month.
    public struct ModelLine: Sendable, Hashable, Identifiable {
        public var model: String
        public var tokens: Tokens
        /// In dollars, the organization's; nil when the cost report names no cost for the model.
        public var cost: Double?
        public var id: String { model }

        public nonisolated init(model: String, tokens: Tokens, cost: Double?) {
            self.model = model
            self.tokens = tokens
            self.cost = cost
        }
    }

    /// What the reports said, for today and this month (UTC).
    public struct Report: Sendable, Hashable {
        /// Whose tokens these are: the account's key when it could be told apart, else the organization's.
        public var tokenScope: Scope
        public var tokensToday = Tokens()
        public var tokensThisMonth = Tokens()
        /// The organization's spend in dollars; nil when the cost report could not be read.
        public var costToday: Double?
        public var costThisMonth: Double?
        /// This month by model, most tokens first.
        public var models: [ModelLine] = []
        public var checkedAt: Date

        public nonisolated init(tokenScope: Scope, checkedAt: Date) {
            self.tokenScope = tokenScope
            self.checkedAt = checkedAt
        }
    }

    public enum Outcome: Sendable, Hashable {
        case report(Report)
        /// 401: Anthropic did not accept the key.
        case unauthorized
        /// 403: the key is no Admin API key, or may not read the reports.
        case forbidden
        case failed
    }

    nonisolated static let baseURL = URL(string: "https://api.anthropic.com/v1/organizations/")!
    nonisolated static let version = "2023-06-01"
    /// Pages read per report at most, so a bad cursor can't loop.
    nonisolated static let maxPages = 10

    // MARK: Requests

    /// A GET of `path` with `query`, signed with the Admin key in the `x-api-key` header.
    nonisolated static func request(_ path: String, query: [URLQueryItem], adminKey: String, timeout: TimeInterval) -> URLRequest {
        var components = URLComponents(url: baseURL.appendingPathComponent(path), resolvingAgainstBaseURL: false)!
        components.queryItems = query.isEmpty ? nil : query
        var request = URLRequest(url: components.url!, cachePolicy: .reloadIgnoringLocalAndRemoteCacheData, timeoutInterval: timeout)
        request.httpMethod = "GET"
        request.setValue(adminKey, forHTTPHeaderField: "x-api-key")
        request.setValue(version, forHTTPHeaderField: "anthropic-version")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        return request
    }

    /// The usage report's query: daily buckets from `start`, by model, for one key when given.
    nonisolated static func usageQuery(from start: Date, apiKeyID: String?, page: String?) -> [URLQueryItem] {
        var query = [
            URLQueryItem(name: "starting_at", value: iso(start)), URLQueryItem(name: "bucket_width", value: "1d"),
            URLQueryItem(name: "limit", value: "31"), URLQueryItem(name: "group_by[]", value: "model"),
        ]
        if let apiKeyID { query.append(URLQueryItem(name: "api_key_ids[]", value: apiKeyID)) }
        if let page { query.append(URLQueryItem(name: "page", value: page)) }
        return query
    }

    /// The cost report's query: daily buckets from `start`, by description (which names the model).
    nonisolated static func costQuery(from start: Date, page: String?) -> [URLQueryItem] {
        var query = [
            URLQueryItem(name: "starting_at", value: iso(start)), URLQueryItem(name: "bucket_width", value: "1d"),
            URLQueryItem(name: "limit", value: "31"), URLQueryItem(name: "group_by[]", value: "description"),
        ]
        if let page { query.append(URLQueryItem(name: "page", value: page)) }
        return query
    }

    // MARK: Reading

    /// Reads the key list, the usage report and the cost report for today and this month (UTC) with `adminKey`,
    /// narrowing tokens to `apiKey` when the key list names it.
    @concurrent nonisolated static func read(
        adminKey: String, apiKey: String?, fetch: @escaping UsageLimitsFetch = UsageLimitsHTTP.live,
        timeout: Duration = .seconds(30), now: Date = Date()
    ) async -> Outcome {
        let seconds = timeout.timeInterval
        enum Refused: Error { case status(Int) }
        @Sendable func get(_ path: String, _ query: [URLQueryItem]) async throws -> JSONValue {
            let (data, response) = try await fetch(request(path, query: query, adminKey: adminKey, timeout: seconds))
            guard (200..<300).contains(response.statusCode) else { throw Refused.status(response.statusCode) }
            guard let body = JSONValue.parse(data) else { throw Refused.status(0) }
            return body
        }
        @Sendable func pages(_ path: String, _ query: @Sendable (String?) -> [URLQueryItem]) async throws -> [JSONValue] {
            var buckets: [JSONValue] = []
            var page: String?
            for _ in 0..<maxPages {
                let body = try await get(path, query(page))
                buckets += body["data"]?.array ?? []
                guard body["has_more"]?.bool == true, let next = body["next_page"]?.string, !next.isEmpty, next != page else { break }
                page = next
            }
            return buckets
        }
        do {
            return try await usageLimitsWithTimeout(timeout) {
                let start = monthStart(now)
                // The key list only narrows the tokens; without it they are the organization's.
                var keyMatch: (id: String, name: String)?
                if let apiKey {
                    do {
                        keyMatch = matchingKey(apiKey, in: try await keyList(get))
                    } catch Refused.status(let status) where status == 401 || status == 403 {
                        throw Refused.status(status)
                    } catch {}
                }
                let keyID = keyMatch?.id
                let usage = try await pages("usage_report/messages") { usageQuery(from: start, apiKeyID: keyID, page: $0) }
                let cost: [JSONValue]?
                do {
                    cost = try await pages("cost_report") { costQuery(from: start, page: $0) }
                } catch Refused.status(let status) where status == 401 || status == 403 {
                    throw Refused.status(status)
                } catch {
                    cost = nil
                }
                return .report(
                    report(
                        usage: usage, cost: cost, scope: keyMatch.map { .apiKey(name: $0.name) } ?? .organization, now: now))
            }
        } catch Refused.status(401) {
            return .unauthorized
        } catch Refused.status(403) {
            return .forbidden
        } catch {
            return .failed
        }
    }

    /// Every active key of the organization, following `after_id` pages.
    private nonisolated static func keyList(
        _ get: @Sendable (String, [URLQueryItem]) async throws -> JSONValue
    ) async throws -> [JSONValue] {
        var keys: [JSONValue] = []
        var after: String?
        for _ in 0..<maxPages {
            var query = [URLQueryItem(name: "limit", value: "1000"), URLQueryItem(name: "status", value: "active")]
            if let after { query.append(URLQueryItem(name: "after_id", value: after)) }
            let body = try await get("api_keys", query)
            keys += body["data"]?.array ?? []
            guard body["has_more"]?.bool == true, let last = body["last_id"]?.string, last != after else { break }
            after = last
        }
        return keys
    }

    /// The key whose `partial_key_hint` ("sk-ant-api03-R2D...igAA") fits `apiKey`: the start before the dots and the
    /// end after them. Only a single fitting key counts, so tokens are never narrowed to the wrong one.
    nonisolated static func matchingKey(_ apiKey: String, in keys: [JSONValue]) -> (id: String, name: String)? {
        let key = apiKey.trimmingCharacters(in: .whitespacesAndNewlines)
        let matches = keys.compactMap { entry -> (id: String, name: String)? in
            guard let id = entry["id"]?.string, let hint = entry["partial_key_hint"]?.string,
                let dots = hint.range(of: "...")
            else { return nil }
            let head = String(hint[..<dots.lowerBound])
            let tail = String(hint[dots.upperBound...])
            // A hint must keep enough of the key to tell keys apart.
            guard head.count >= 8, tail.count >= 2, key.count > head.count + tail.count, key.hasPrefix(head), key.hasSuffix(tail)
            else { return nil }
            return (id, entry["name"]?.string ?? id)
        }
        return matches.count == 1 ? matches[0] : nil
    }

    /// Sums the reports' buckets into today and this month, and the month by model.
    nonisolated static func report(usage: [JSONValue], cost: [JSONValue]?, scope: Scope, now: Date) -> Report {
        var report = Report(tokenScope: scope, checkedAt: now)
        let today = dayStart(now)
        let month = monthStart(now)
        var modelTokens: [String: Tokens] = [:]
        for bucket in usage {
            guard let start = date(bucket["starting_at"]?.string), start >= month else { continue }
            for row in bucket["results"]?.array ?? [] {
                let tokens = Tokens(
                    uncachedInput: count(row["uncached_input_tokens"]), cacheRead: count(row["cache_read_input_tokens"]),
                    cacheCreation: count(row["cache_creation"]?["ephemeral_5m_input_tokens"])
                        + count(row["cache_creation"]?["ephemeral_1h_input_tokens"]),
                    output: count(row["output_tokens"]))
                report.tokensThisMonth = report.tokensThisMonth + tokens
                if start >= today { report.tokensToday = report.tokensToday + tokens }
                if let model = row["model"]?.string, !model.isEmpty {
                    modelTokens[model] = (modelTokens[model] ?? Tokens()) + tokens
                }
            }
        }
        var modelCost: [String: Double] = [:]
        if let cost {
            var todayCost = 0.0
            var monthCost = 0.0
            for bucket in cost {
                guard let start = date(bucket["starting_at"]?.string), start >= month else { continue }
                for row in bucket["results"]?.array ?? [] {
                    // Amounts are decimal strings in cents (the lowest unit of USD, the only currency so far).
                    guard (row["currency"]?.string ?? "USD") == "USD", let cents = row["amount"]?.string.flatMap(Double.init)
                        ?? row["amount"]?.number, cents.isFinite
                    else { continue }
                    let dollars = cents / 100
                    monthCost += dollars
                    if start >= today { todayCost += dollars }
                    if let model = row["model"]?.string, !model.isEmpty { modelCost[model, default: 0] += dollars }
                }
            }
            report.costToday = todayCost
            report.costThisMonth = monthCost
        }
        let models = Set(modelTokens.keys).union(modelCost.keys)
        report.models = models.map { ModelLine(model: $0, tokens: modelTokens[$0] ?? Tokens(), cost: modelCost[$0]) }
            .sorted { ($0.tokens.total, $0.cost ?? 0, $1.model) > ($1.tokens.total, $1.cost ?? 0, $0.model) }
        return report
    }

    // MARK: Presenting

    /// The report as an account's figures: spend today and this month (the organization's), and tokens today and this
    /// month (the key's or the organization's, as `tokenScope` says), each starting over at the next UTC day or month.
    public nonisolated static func figures(_ report: Report) -> [UsageFigure] {
        let organization = String(localized: "Organization")
        let tokenScope: String =
            switch report.tokenScope {
            case .apiKey(let name): String(localized: "Key “\(name)”")
            case .organization: organization
            }
        let nextDay = dayStart(report.checkedAt).addingTimeInterval(86_400)
        let nextMonth = utc.date(byAdding: .month, value: 1, to: monthStart(report.checkedAt))
        var figures: [UsageFigure] = []
        if let costToday = report.costToday {
            figures.append(
                UsageFigure(
                    id: "admin_cost_today", label: String(localized: "Spent today"), unit: .currency("USD"), used: costToday,
                    resetsAt: nextDay, detail: organization))
        }
        if let costThisMonth = report.costThisMonth {
            figures.append(
                UsageFigure(
                    id: "admin_cost_month", label: String(localized: "Spent this month"), unit: .currency("USD"), used: costThisMonth,
                    resetsAt: nextMonth, detail: organization))
        }
        figures.append(
            UsageFigure(
                id: "admin_tokens_today", label: String(localized: "Tokens today"), unit: .tokens,
                used: Double(report.tokensToday.total), resetsAt: nextDay, detail: tokenScope))
        figures.append(
            UsageFigure(
                id: "admin_tokens_month", label: String(localized: "Tokens this month"), unit: .tokens,
                used: Double(report.tokensThisMonth.total), resetsAt: nextMonth, detail: tokenScope))
        return figures
    }

    /// Why the reports could not be read, for the account's notes.
    public nonisolated static func problem(_ outcome: Outcome) -> String? {
        switch outcome {
        case .report: nil
        case .unauthorized:
            String(localized: "Anthropic didn’t accept the Admin API key. Check it in Settings › Providers.")
        case .forbidden:
            String(localized: "This key can’t read usage reports. Use an Admin API key (sk-ant-admin01-…) from the Claude Console.")
        case .failed:
            String(localized: "Anthropic’s usage and cost reports couldn’t be read. Coincide tries again later.")
        }
    }

    /// The note an account with an Admin key keeps: the reports have no prepaid balance.
    public nonisolated static var balanceNote: String {
        String(localized: "Anthropic’s API doesn’t report the prepaid credit balance; the Claude Console shows it.")
    }

    // MARK: Dates

    nonisolated static var utc: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC") ?? .gmt
        return calendar
    }

    nonisolated static func dayStart(_ date: Date) -> Date { utc.startOfDay(for: date) }

    nonisolated static func monthStart(_ date: Date) -> Date {
        utc.dateInterval(of: .month, for: date)?.start ?? dayStart(date)
    }

    private nonisolated static func iso(_ date: Date) -> String {
        date.formatted(Date.ISO8601FormatStyle(timeZone: .gmt))
    }

    private nonisolated static func date(_ text: String?) -> Date? {
        ClaudeUsageLimits.date(fromISO: text)
    }

    private nonisolated static func count(_ value: JSONValue?) -> Int {
        guard let number = value?.number, number.isFinite, number > 0 else { return 0 }
        return Int(number)
    }
}
