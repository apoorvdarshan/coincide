import Foundation

/// What a provider's own check of its plan's usage found. As T3 Code's `unavailable` reasons do, it tells an account
/// with no limits to read from a read that failed.
enum UsageLimitsOutcome: Sendable, Hashable {
    case limits(UsageLimits)
    /// Nothing to read for this setup: no plan login, an API key, a Keychain read the user has not allowed, …
    case unsupported
    /// The read failed, timed out or got an answer it could not use.
    case failed

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
    nonisolated static let live: UsageLimitsFetch = { request in
        let (data, response) = try await session.data(for: request)
        guard let response = response as? HTTPURLResponse else { throw URLError(.badServerResponse) }
        return (data, response)
    }

    private nonisolated static let session: URLSession = {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.requestCachePolicy = .reloadIgnoringLocalAndRemoteCacheData
        configuration.urlCache = nil
        configuration.httpCookieStorage = nil
        configuration.httpShouldSetCookies = false
        return URLSession(configuration: configuration, delegate: NoRedirects(), delegateQueue: nil)
    }()

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
