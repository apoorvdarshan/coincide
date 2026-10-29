import Foundation

/// What an API key may read about its own usage, by the service it belongs to. Only reads that cost nothing run on
/// their own: OpenRouter's `/key` and `/credits`. Anthropic reports a key's rate limits only in the headers of a model
/// request, so those are read only when the user asks (`probeAnthropicRateLimits`), with a one-token message. Services
/// that show a key nothing get a note saying so, never a guessed figure. Keys go in headers, never in a URL.
public enum APIKeyUsage {
    public enum Service: String, Sendable, Hashable {
        case anthropic, openAI, openRouter, xAI, gemini, openCodeZen
    }

    /// The service of a key in `variable`, for the variables Coincide's agents read keys from.
    public nonisolated static func service(forVariable variable: String?) -> Service? {
        switch variable {
        case "ANTHROPIC_API_KEY"?: .anthropic
        case "OPENAI_API_KEY"?: .openAI
        case "OPENROUTER_API_KEY"?: .openRouter
        case "XAI_API_KEY"?: .xAI
        case "GEMINI_API_KEY"?, "GOOGLE_GENERATIVE_AI_API_KEY"?: .gemini
        case "OPENCODE_API_KEY"?: .openCodeZen
        default: nil
        }
    }

    /// What the service does not show a key, so the account says why it has no balance.
    public nonisolated static func notes(for service: Service) -> [String] {
        switch service {
        case .anthropic:
            [String(localized: "Anthropic doesn’t show an API key its credit balance; the Console’s usage and cost reports need an Admin API key.")]
        case .openAI:
            [String(localized: "OpenAI doesn’t show an API key its balance; the organization’s usage and cost reports need an Admin key.")]
        case .xAI:
            [String(localized: "xAI shows a team’s balance only through its Management API, which needs a management key.")]
        case .gemini:
            [String(localized: "Google shows Gemini API quotas only in AI Studio; an API key can’t read them.")]
        case .openCodeZen:
            [String(localized: "OpenCode Zen shows its balance only in the OpenCode console.")]
        case .openRouter:
            []
        }
    }

    /// The automatic check of a key: OpenRouter's key and credits, the notes of every other service. Nil when the
    /// service is not one Coincide knows.
    @concurrent nonisolated static func read(
        variable: String?, key: String, fetch: @escaping UsageLimitsFetch = UsageLimitsHTTP.live,
        timeout: Duration = .seconds(10), now: Date = Date()
    ) async -> UsageLimitsOutcome? {
        guard let service = service(forVariable: variable) else { return nil }
        guard service == .openRouter else {
            return .limits(UsageLimits(windows: [], checkedAt: now, notes: notes(for: service)))
        }
        return await readOpenRouter(key: key, fetch: fetch, timeout: timeout, now: now)
    }

    // MARK: OpenRouter

    nonisolated static let openRouterKeyURL = URL(string: "https://openrouter.ai/api/v1/key")!
    nonisolated static let openRouterCreditsURL = URL(string: "https://openrouter.ai/api/v1/credits")!

    @concurrent nonisolated static func readOpenRouter(
        key: String, fetch: @escaping UsageLimitsFetch, timeout: Duration, now: Date
    ) async -> UsageLimitsOutcome {
        do {
            return try await usageLimitsWithTimeout(timeout) {
                let (data, response) = try await fetch(UsageLimitsHTTP.request(openRouterKeyURL, token: key, timeout: timeout.timeInterval))
                guard (200..<300).contains(response.statusCode), let body = JSONValue.parse(data), body["data"]?.object != nil
                else { return .failed }
                // The account's total credits need a management key; an ordinary key is refused, which is no failure.
                var credits: JSONValue?
                if let (data, response) = try? await fetch(
                    UsageLimitsHTTP.request(openRouterCreditsURL, token: key, timeout: timeout.timeInterval)),
                    (200..<300).contains(response.statusCode)
                {
                    credits = JSONValue.parse(data)
                }
                var notes: [String] = []
                if credits == nil {
                    notes.append(String(localized: "The account’s total credit balance needs an OpenRouter management key."))
                }
                return .limits(
                    UsageLimits(
                        windows: [], checkedAt: now, figures: openRouterFigures(key: body, credits: credits, now: now), notes: notes))
            }
        } catch {
            return .failed
        }
    }

    /// The figures of a `/key` answer (and a `/credits` one, when the key may read it). OpenRouter's credits are dollars.
    /// Its daily, weekly and monthly usage and limits start over at midnight UTC, weeks on Monday.
    nonisolated static func openRouterFigures(key: JSONValue, credits: JSONValue?, now: Date) -> [UsageFigure] {
        guard let data = key["data"], data.object != nil else { return [] }
        var figures: [UsageFigure] = []
        if let credits = credits?["data"], let total = credits["total_credits"]?.number, total.isFinite {
            figures.append(
                UsageFigure(
                    id: "credits", label: String(localized: "Account credits"), unit: .currency("USD"),
                    used: credits["total_usage"]?.number, limit: total))
        }
        if let limit = data["limit"]?.number, limit.isFinite {
            let period = data["limit_reset"]?.string
            figures.append(
                UsageFigure(
                    id: "key_limit", label: String(localized: "Key credit limit"), unit: .currency("USD"),
                    limit: limit, remaining: data["limit_remaining"]?.number,
                    resetsAt: period.flatMap { nextUTCBoundary($0, after: now) }))
        } else if data["limit"]?.isNull == true || data.object?["limit"] == nil {
            figures.append(
                UsageFigure(id: "key_limit", label: String(localized: "Key credit limit"), unit: .currency("USD"), detail: String(localized: "No limit")))
        }
        for (field, id, label, period) in [
            ("usage_daily", "usage_daily", String(localized: "Spent today"), "daily"),
            ("usage_weekly", "usage_weekly", String(localized: "Spent this week"), "weekly"),
            ("usage_monthly", "usage_monthly", String(localized: "Spent this month"), "monthly"),
        ] {
            guard let used = data[field]?.number, used.isFinite else { continue }
            figures.append(
                UsageFigure(id: id, label: label, unit: .currency("USD"), used: used, resetsAt: nextUTCBoundary(period, after: now)))
        }
        if let used = data["usage"]?.number, used.isFinite {
            figures.append(UsageFigure(id: "usage", label: String(localized: "Spent in total"), unit: .currency("USD"), used: used))
        }
        return figures
    }

    /// The next midnight UTC that starts a `daily`, `weekly` (Monday) or `monthly` period; nil for any other period.
    nonisolated static func nextUTCBoundary(_ period: String, after now: Date) -> Date? {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC") ?? .gmt
        calendar.firstWeekday = 2
        let component: Calendar.Component
        switch period {
        case "daily": component = .day
        case "weekly": component = .weekOfYear
        case "monthly": component = .month
        default: return nil
        }
        guard let start = calendar.dateInterval(of: component, for: now) else { return nil }
        return start.end
    }

    // MARK: Anthropic rate limits

    nonisolated static let anthropicMessagesURL = URL(string: "https://api.anthropic.com/v1/messages")!
    /// The cheapest current model, for the one-token request that reads the headers.
    nonisolated static let anthropicProbeModel = "claude-haiku-4-5"

    /// Sends a one-token message with `key` and reads the rate limits from the answer's headers: what the key may still
    /// send this minute and when that starts over. It costs a fraction of a cent, so only the user starts it.
    @concurrent nonisolated static func probeAnthropicRateLimits(
        key: String, fetch: @escaping UsageLimitsFetch = UsageLimitsHTTP.live, timeout: Duration = .seconds(20),
        now: Date = Date()
    ) async -> UsageLimitsOutcome {
        var request = URLRequest(url: anthropicMessagesURL, cachePolicy: .reloadIgnoringLocalAndRemoteCacheData, timeoutInterval: timeout.timeInterval)
        request.httpMethod = "POST"
        request.setValue(key, forHTTPHeaderField: "x-api-key")
        request.setValue("2023-06-01", forHTTPHeaderField: "anthropic-version")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = JSONValue.object([
            "model": .string(anthropicProbeModel), "max_tokens": .number(1),
            "messages": .array([.object(["role": .string("user"), "content": .string(".")])]),
        ]).compactJSON.data(using: .utf8)
        let probe = request
        do {
            return try await usageLimitsWithTimeout(timeout) {
                let (_, response) = try await fetch(probe)
                let figures = anthropicRateLimitFigures(response.allHeaderFields)
                // A refused key or a failed request reports no limits; a 429 still carries them.
                guard !figures.isEmpty else { return .failed }
                return .limits(UsageLimits(windows: [], checkedAt: now, figures: figures))
            }
        } catch {
            return .failed
        }
    }

    /// Anthropic's `anthropic-ratelimit-<kind>-limit|remaining|reset` headers as figures. Resets are RFC 3339 times.
    nonisolated static func anthropicRateLimitFigures(_ headers: [AnyHashable: Any]) -> [UsageFigure] {
        var lowercased: [String: String] = [:]
        for (name, value) in headers {
            guard let name = (name as? String)?.lowercased() else { continue }
            lowercased[name] = (value as? String) ?? (value as? NSNumber)?.stringValue
        }
        func number(_ name: String) -> Double? {
            lowercased[name].flatMap { Double($0.trimmingCharacters(in: .whitespaces)) }
        }
        let kinds: [(String, String, UsageFigure.Unit)] = [
            ("requests", String(localized: "Requests per minute"), .requests),
            ("tokens", String(localized: "Tokens per minute"), .tokens),
            ("input-tokens", String(localized: "Input tokens per minute"), .tokens),
            ("output-tokens", String(localized: "Output tokens per minute"), .tokens),
        ]
        return kinds.compactMap { kind, label, unit in
            let prefix = "anthropic-ratelimit-\(kind)-"
            let limit = number(prefix + "limit")
            let remaining = number(prefix + "remaining")
            guard limit != nil || remaining != nil else { return nil }
            return UsageFigure(
                id: "ratelimit_\(kind)", label: label, unit: unit, limit: limit, remaining: remaining,
                resetsAt: ClaudeUsageLimits.date(fromISO: lowercased[prefix + "reset"]))
        }
    }
}

extension UsageLimits {
    /// These limits with `other`'s figures and notes added (replacing figures of the same id), keeping the newer
    /// check time.
    public nonisolated func adding(_ other: UsageLimits) -> UsageLimits {
        var figures = self.figures.filter { mine in !other.figures.contains { $0.id == mine.id } }
        figures += other.figures
        var notes = self.notes
        for note in other.notes where !notes.contains(note) { notes.append(note) }
        return UsageLimits(
            windows: windows, checkedAt: max(checkedAt, other.checkedAt), plan: plan ?? other.plan, credits: credits ?? other.credits,
            modelWindows: modelWindows, figures: figures, notes: notes)
    }
}
