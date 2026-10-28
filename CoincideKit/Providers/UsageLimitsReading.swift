import Foundation

/// What a provider's own check of its plan's usage found. As T3 Code's `unavailable` reasons do, it tells an account
/// with no limits to read from a read that failed. Public because `ACPAgentFlavor.usageLimits` returns it.
public enum UsageLimitsOutcome: Sendable, Hashable {
    case limits(UsageLimits)
    /// Nothing to read for this setup: no plan login, an API key, a Keychain read the user has not allowed, …
    case unsupported
    /// The read failed, timed out or got an answer it could not use.
    case failed

    /// The windows read; nil for a setup without limits or a failed read.
    public nonisolated var limits: UsageLimits? {
        if case .limits(let limits) = self { return limits }
        return nil
    }

    /// The limits to show after this check, as T3's `resolveUsageLimitsAfterProbe`: a failed read keeps the ones the
    /// last check read, and a setup without limits drops them.
    nonisolated func resolved(after previous: UsageLimits?) -> UsageLimits? {
        switch self {
        case .limits(let limits): limits
        case .unsupported: nil
        case .failed: previous
        }
    }
}

/// Sends one request of a usage check and returns the body and response, so tests answer without the network.
typealias UsageLimitsFetch = @Sendable (URLRequest) async throws -> (Data, HTTPURLResponse)

enum UsageLimitsHTTP {
    /// An ephemeral session that keeps no cookies or cache and follows no redirect, so a bearer token goes only to
    /// the host it was meant for.
    nonisolated static let live: UsageLimitsFetch = fetch(configuration: configuration)

    /// The session settings `live` uses: ephemeral, without cookies or a cache.
    nonisolated static var configuration: URLSessionConfiguration {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.requestCachePolicy = .reloadIgnoringLocalAndRemoteCacheData
        configuration.urlCache = nil
        configuration.httpCookieStorage = nil
        configuration.httpShouldSetCookies = false
        return configuration
    }

    /// Sends requests through a session with `configuration` that follows no redirect: the redirect comes back as the
    /// answer. Tests pass a configuration whose protocol classes answer without the network.
    nonisolated static func fetch(configuration: URLSessionConfiguration) -> UsageLimitsFetch {
        let session = URLSession(configuration: configuration, delegate: NoRedirects(), delegateQueue: nil)
        return { request in
            let (data, response) = try await session.data(for: request)
            guard let response = response as? HTTPURLResponse else { throw URLError(.badServerResponse) }
            return (data, response)
        }
    }

    private final class NoRedirects: NSObject, URLSessionTaskDelegate, Sendable {
        nonisolated func urlSession(
            _ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
            newRequest request: URLRequest, completionHandler: @escaping @Sendable (URLRequest?) -> Void
        ) {
            completionHandler(nil)
        }
    }

    /// A request with a bearer token in its header (never in the URL).
    nonisolated static func request(_ url: URL, method: String = "GET", token: String, timeout: TimeInterval) -> URLRequest {
        var request = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalAndRemoteCacheData, timeoutInterval: timeout)
        request.httpMethod = method
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        return request
    }
}

/// A usage check that took longer than it may.
struct UsageLimitsTimeout: Error {}

/// Runs `operation` and returns its result, or throws `UsageLimitsTimeout` once `timeout` passes. Work that does not
/// stop when cancelled (a Keychain read waiting on the user) carries on in the background; the caller stops waiting.
nonisolated func usageLimitsWithTimeout<T: Sendable>(
    _ timeout: Duration, _ operation: @escaping @Sendable () async throws -> T
) async throws -> T {
    let first = FirstResult<T>()
    let work = Task {
        do {
            first.finish(.success(try await operation()))
        } catch {
            first.finish(.failure(error))
        }
    }
    let timer = Task {
        try? await Task.sleep(for: timeout)
        first.finish(.failure(UsageLimitsTimeout()))
    }
    defer {
        work.cancel()
        timer.cancel()
    }
    return try await withTaskCancellationHandler {
        try await first.value()
    } onCancel: {
        first.finish(.failure(CancellationError()))
    }
}

/// Keeps the first result it is given and hands it to whoever waits for it.
private final class FirstResult<T: Sendable>: @unchecked Sendable {
    private let lock = NSLock()
    private var result: Result<T, Error>?
    private var waiter: CheckedContinuation<T, Error>?

    nonisolated init() {}

    nonisolated func finish(_ result: Result<T, Error>) {
        let waiter = lock.withLock { () -> CheckedContinuation<T, Error>? in
            guard self.result == nil else { return nil }
            self.result = result
            defer { self.waiter = nil }
            return self.waiter
        }
        waiter?.resume(with: result)
    }

    nonisolated func value() async throws -> T {
        try await withCheckedThrowingContinuation { continuation in
            let result = lock.withLock { () -> Result<T, Error>? in
                if let result { return result }
                waiter = continuation
                return nil
            }
            if let result { continuation.resume(with: result) }
        }
    }
}

/// A file's contents, or nil when there is no such file; any other failure throws.
nonisolated func readFileIfPresent(_ url: URL) throws -> Data? {
    do {
        return try Data(contentsOf: url)
    } catch let error as CocoaError where error.code == .fileReadNoSuchFile || error.code == .fileNoSuchFile {
        return nil
    }
}

extension String {
    /// The text without surrounding whitespace, or nil when nothing is left: JavaScript's `value?.trim() || …`.
    nonisolated var trimmedNonEmpty: String? {
        let trimmed = trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }
}

extension Duration {
    /// The duration in seconds, for `URLRequest`'s timeout.
    nonisolated var timeInterval: TimeInterval {
        let (seconds, attoseconds) = components
        return TimeInterval(seconds) + TimeInterval(attoseconds) / 1e18
    }
}

/// Reset times and periods in providers' usage answers.
enum UsageLimitDates {
    /// An RFC 3339 instant such as `2026-09-18T03:10:30.159171+00:00`, as T3 Code's Grok `parsePeriodBoundary` accepts
    /// it: a whole date and time with a zone, no surrounding spaces, and a calendar day that exists (the system parser
    /// would roll February 30 over into March). Fractions of a second are kept to the millisecond, as in JavaScript.
    nonisolated static func instant(_ text: String?) -> Date? {
        guard let text,
            let match = text.wholeMatch(
                of:
                    /(?<year>[0-9]{4}|[+-][0-9]{6})-(?<month>0[1-9]|1[0-2])-(?<day>0[1-9]|[12][0-9]|3[01])T(?:(?<hour>[01][0-9]|2[0-3]):(?<minute>[0-5][0-9])(?::(?<second>[0-5][0-9])(?<fraction>\.[0-9]+)?)?|(?<midnight>24:00(?::00(?:\.0+)?)?))(?<zone>Z|[+-](?:[01][0-9]|2[0-3]):[0-5][0-9])/
            ), let year = Int(match.year),
            let month = Int(match.month), let day = Int(match.day), day <= daysInMonth(month, year: year)
        else { return nil }
        var seconds = Double(daysSinceEpoch(year: year, month: month, day: day)) * 86_400
        if match.midnight != nil {
            seconds += 86_400
        } else {
            let fraction = match.fraction.flatMap { Double("0" + $0) } ?? 0
            seconds += Double((Int(match.hour ?? "") ?? 0) * 3_600 + (Int(match.minute ?? "") ?? 0) * 60)
                + Double(Int(match.second ?? "") ?? 0) + (fraction * 1_000).rounded(.down) / 1_000
        }
        if match.zone != "Z" {
            let zone = match.zone
            let offset = (Int(zone.dropFirst().prefix(2)) ?? 0) * 3_600 + (Int(zone.suffix(2)) ?? 0) * 60
            seconds -= Double(zone.hasPrefix("-") ? -offset : offset)
        }
        return Date(timeIntervalSince1970: seconds)
    }

    private nonisolated static func daysInMonth(_ month: Int, year: Int) -> Int {
        guard month == 2 else { return [31, 28, 31, 30, 31, 30, 31, 31, 30, 31, 30, 31][month - 1] }
        return (year % 4 == 0 && year % 100 != 0) || year % 400 == 0 ? 29 : 28
    }

    /// Days from 1970-01-01 in the proleptic Gregorian calendar (Howard Hinnant's `days_from_civil`).
    private nonisolated static func daysSinceEpoch(year: Int, month: Int, day: Int) -> Int {
        let year = month <= 2 ? year - 1 : year
        let era = (year >= 0 ? year : year - 399) / 400
        let yearOfEra = year - era * 400
        let dayOfYear = (153 * (month > 2 ? month - 3 : month + 9) + 2) / 5 + day - 1
        let dayOfEra = yearOfEra * 365 + yearOfEra / 4 - yearOfEra / 100 + dayOfYear
        return era * 146_097 + dayOfEra - 719_468
    }
}
