import Foundation

/// Transport failures intentionally contain no request URL, credentials or server payload.
public enum OpenCodeHTTPError: Error, Sendable, Equatable, CustomStringConvertible, LocalizedError {
    case invalidOrigin, invalidPath, invalidQuery, invalidMethod, invalidLimit
    case requestBodyTooLarge, responseBodyTooLarge, invalidResponse, redirectDenied
    case eventResponseRejected(status: Int), eventBufferOverflow, transportFailure, clientClosed

    public var errorDescription: String? { description }

    public var description: String {
        switch self {
        case .invalidOrigin: "OpenCode requires an HTTPS origin or a loopback HTTP origin."
        case .invalidPath: "The OpenCode request path is invalid."
        case .invalidQuery: "The OpenCode request query is invalid."
        case .invalidMethod: "The OpenCode request method is invalid."
        case .invalidLimit: "The OpenCode response limit is invalid."
        case .requestBodyTooLarge: "The OpenCode request exceeds the size limit."
        case .responseBodyTooLarge: "The OpenCode response exceeds the size limit."
        case .invalidResponse: "OpenCode returned an invalid HTTP response."
        case .redirectDenied: "OpenCode HTTP redirects are not permitted."
        case .eventResponseRejected(let status): "OpenCode rejected the event stream (HTTP \(status))."
        case .eventBufferOverflow: "The OpenCode event consumer fell behind the bounded buffer."
        case .transportFailure: "The OpenCode HTTP connection failed."
        case .clientClosed: "The OpenCode HTTP client is closed."
        }
    }
}

public struct OpenCodeHTTPResponse: Sendable {
    public let status: Int
    /// Header names are lowercased. Header and body sizes are bounded independently.
    public let headers: [String: String]
    public let body: Data

    public init(status: Int, headers: [String: String], body: Data) {
        self.status = status; self.headers = headers; self.body = body
    }
}

/// Closing cancels and drains this request only; it never interrupts a provider session.
public struct OpenCodeHTTPByteStream: Sendable {
    public let stream: AsyncThrowingStream<Data, Error>
    private let cancelRequest: @Sendable () async -> Void
    private let waitForRequest: @Sendable () async -> Void

    fileprivate init(stream: AsyncThrowingStream<Data, Error>, cancel: @escaping @Sendable () async -> Void,
                     wait: @escaping @Sendable () async -> Void) {
        self.stream = stream; cancelRequest = cancel; waitForRequest = wait
    }

    public func cancel() async { await cancelRequest() }
    public func close() async { await cancelRequest() }
    /// Joins natural request completion without consuming bytes or cancelling it.
    func waitUntilFinished() async { await waitForRequest() }
}

/// A credential is held only by this runtime client and sent only in an Authorization header.
public actor OpenCodeHTTPClient {
    private let origin: URLComponents
    private let credential: OpenCodeHTTPCredential?
    private let owner: OpenCodeHTTPSessionOwner

    public init(origin: URL, credential: OpenCodeHTTPCredential? = nil,
                configuration: URLSessionConfiguration? = nil) throws {
        self.origin = try Self.validateOrigin(origin)
        self.credential = credential
        owner = OpenCodeHTTPSessionOwner(configuration: configuration)
    }

    deinit { owner.beginClose() }

    public func request(method: String = "GET", path: [String], query: [URLQueryItem] = [],
                        body: Data? = nil, maximumBytes: Int = 4 * 1_024 * 1_024) async throws -> OpenCodeHTTPResponse {
        guard (1...16 * 1_024 * 1_024).contains(maximumBytes) else { throw OpenCodeHTTPError.invalidLimit }
        let request = try makeRequest(method: method, path: path, query: query, body: body, events: false)
        try Task.checkCancellation()
        let operation = OpenCodeHTTPTaskState(maximumBytes: maximumBytes, events: false)
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                operation.setResponseContinuation(continuation)
                owner.start(operation, request: request)
            }
        } onCancel: { operation.cancel() }
    }

    /// Returns only after the server accepted a 200 text/event-stream response.
    public func openEvents(path: [String], query: [URLQueryItem] = []) async throws -> OpenCodeHTTPByteStream {
        let request = try makeRequest(method: "GET", path: path, query: query, body: nil, events: true)
        try Task.checkCancellation()
        let operation = OpenCodeHTTPTaskState(maximumBytes: 0, events: true)
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                operation.setEventContinuation(continuation)
                owner.start(operation, request: request)
            }
        } onCancel: { operation.cancel() }
    }

    public func close() async { await owner.close() }

    private static func validateOrigin(_ url: URL) throws -> URLComponents {
        guard var components = URLComponents(url: url, resolvingAgainstBaseURL: false),
              let scheme = components.scheme?.lowercased(), ["http", "https"].contains(scheme),
              let host = components.host, !host.isEmpty,
              components.user == nil, components.password == nil,
              components.query == nil, components.fragment == nil,
              components.percentEncodedPath.isEmpty || components.percentEncodedPath == "/",
              components.port.map({ (1...65_535).contains($0) }) ?? true else {
            throw OpenCodeHTTPError.invalidOrigin
        }
        if scheme == "http", !isLoopback(host) { throw OpenCodeHTTPError.invalidOrigin }
        components.scheme = scheme; components.path = ""; components.queryItems = nil
        return components
    }

    private static func isLoopback(_ host: String) -> Bool {
        let normalized = host.lowercased()
        if ["localhost", "::1", "[::1]"].contains(normalized) { return true }
        let parts = normalized.split(separator: ".", omittingEmptySubsequences: false)
        return parts.count == 4 && parts[0] == "127" && parts.allSatisfy {
            guard let number = UInt8($0) else { return false }
            return String(number) == $0
        }
    }

    private func makeRequest(method: String, path: [String], query: [URLQueryItem], body: Data?, events: Bool) throws -> URLRequest {
        guard ["GET", "POST", "PUT", "PATCH", "DELETE", "HEAD", "OPTIONS"].contains(method) else {
            throw OpenCodeHTTPError.invalidMethod
        }
        guard (body?.count ?? 0) <= 4 * 1_024 * 1_024 else { throw OpenCodeHTTPError.requestBodyTooLarge }
        let allowed = CharacterSet(charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-._~")
        guard path.count <= 64, path.allSatisfy({ component in
            !component.isEmpty && component != "." && component != ".." && component.utf8.count <= 2_048 &&
            !component.contains("/") && !component.contains("\\") &&
            !component.unicodeScalars.contains(where: CharacterSet.controlCharacters.contains)
        }) else { throw OpenCodeHTTPError.invalidPath }
        let forbidden = Set(["auth", "key"])
        let credentialWords = ["authorization", "password", "token", "apikey", "secret", "credential"]
        guard query.count <= 64, query.allSatisfy({ item in
            let normalized = item.name.lowercased().filter { $0.isLetter || $0.isNumber }
            return !item.name.isEmpty && item.name.utf8.count <= 256 && (item.value?.utf8.count ?? 0) <= 16_384 &&
                !forbidden.contains(normalized) && !credentialWords.contains(where: normalized.contains) &&
                !item.name.unicodeScalars.contains(where: CharacterSet.controlCharacters.contains) &&
                !(item.value?.unicodeScalars.contains(where: CharacterSet.controlCharacters.contains) ?? false)
        }) else { throw OpenCodeHTTPError.invalidQuery }
        var components = origin
        components.percentEncodedPath = "/" + path.map { $0.addingPercentEncoding(withAllowedCharacters: allowed)! }.joined(separator: "/")
        components.queryItems = query.isEmpty ? nil : query
        guard let url = components.url, url.absoluteString.utf8.count <= 64 * 1_024 else { throw OpenCodeHTTPError.invalidPath }
        var request = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 60)
        request.httpMethod = method; request.httpBody = body
        request.httpShouldHandleCookies = false
        request.setValue(events ? "text/event-stream" : "application/json", forHTTPHeaderField: "Accept")
        if body != nil { request.setValue("application/json", forHTTPHeaderField: "Content-Type") }
        if let credential { request.setValue(credential.authorizationHeader, forHTTPHeaderField: "Authorization") }
        return request
    }
}

/// The lock protects task creation and invalidation across actor cancellation and delegate callbacks.
private final class OpenCodeHTTPSessionOwner: NSObject, URLSessionDataDelegate, @unchecked Sendable {
    private let lock = NSLock()
    private var session: URLSession!
    private var operations: [Int: OpenCodeHTTPTaskState] = [:]
    private var closing = false
    private var invalidated = false
    private var closeWaiters: [CheckedContinuation<Void, Never>] = []

    init(configuration supplied: URLSessionConfiguration?) {
        super.init()
        // Preserve only the injectable protocol fixture. A supplied background/default
        // configuration must never change this client's ephemeral storage guarantee.
        let configuration = URLSessionConfiguration.ephemeral
        if let protocolClasses = supplied?.protocolClasses { configuration.protocolClasses = protocolClasses }
        configuration.httpCookieStorage = nil; configuration.httpShouldSetCookies = false
        configuration.urlCredentialStorage = nil; configuration.urlCache = nil
        configuration.httpAdditionalHeaders = [:]
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        configuration.connectionProxyDictionary = [:]
        configuration.waitsForConnectivity = false
        configuration.timeoutIntervalForRequest = 60
        configuration.timeoutIntervalForResource = 86_400
        let queue = OperationQueue(); queue.maxConcurrentOperationCount = 1
        queue.name = "Coincide.OpenCode.HTTP"
        session = URLSession(configuration: configuration, delegate: self, delegateQueue: queue)
    }

    func start(_ operation: OpenCodeHTTPTaskState, request: URLRequest) {
        lock.lock()
        guard !closing else { lock.unlock(); operation.failWithoutTask(.clientClosed); return }
        let task = session.dataTask(with: request)
        operations[task.taskIdentifier] = operation
        operation.attach(task)
        lock.unlock()
        task.resume()
    }

    func beginClose() {
        let active = lock.withLock { () -> [OpenCodeHTTPTaskState]? in
            if closing { return nil }; closing = true; return Array(operations.values)
        }
        if let active {
            for operation in active { operation.cancel() }
            session.invalidateAndCancel()
        }
    }

    func close() async {
        beginClose()
        await withCheckedContinuation { continuation in
            let alreadyInvalidated = lock.withLock {
                if invalidated { return true }
                closeWaiters.append(continuation); return false
            }
            if alreadyInvalidated { continuation.resume() }
        }
    }

    private func operation(for task: URLSessionTask) -> OpenCodeHTTPTaskState? {
        lock.withLock { operations[task.taskIdentifier] }
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive response: URLResponse,
                    completionHandler: @escaping @Sendable (URLSession.ResponseDisposition) -> Void) {
        guard let operation = operation(for: dataTask) else { completionHandler(.cancel); return }
        completionHandler(operation.receive(response) ? .allow : .cancel)
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
        operation(for: dataTask)?.receive(data)
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest, completionHandler: @escaping @Sendable (URLRequest?) -> Void) {
        operation(for: task)?.reject(.redirectDenied)
        completionHandler(nil)
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didReceive challenge: URLAuthenticationChallenge,
                    completionHandler: @escaping @Sendable (URLSession.AuthChallengeDisposition, URLCredential?) -> Void) {
        if challenge.protectionSpace.authenticationMethod == NSURLAuthenticationMethodServerTrust {
            completionHandler(.performDefaultHandling, nil)
        } else {
            // Never consult Keychain/default credentials, prompt, or resend a mutation for authentication.
            operation(for: task)?.rejectAuthentication(challenge.failureResponse)
            completionHandler(.cancelAuthenticationChallenge, nil)
        }
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        let operation = lock.withLock { operations.removeValue(forKey: task.taskIdentifier) }
        operation?.complete(error)
    }

    func urlSession(_ session: URLSession, didBecomeInvalidWithError error: Error?) {
        let (remaining, waiters) = lock.withLock {
            invalidated = true
            let remaining = Array(operations.values), waiters = closeWaiters
            operations.removeAll(); closeWaiters.removeAll()
            return (remaining, waiters)
        }
        for operation in remaining { operation.failWithoutTask(.clientClosed) }
        for waiter in waiters { waiter.resume() }
    }
}

/// Each URLSession response is consumed incrementally. No unbounded `data(for:)` allocation occurs.
final class OpenCodeHTTPTaskState: @unchecked Sendable {
    private let lock = NSLock()
    private let maximumBytes: Int
    private let events: Bool
    private var task: URLSessionDataTask?
    private var response: OpenCodeHTTPResponse?
    private var body = Data()
    private var failure: OpenCodeHTTPError?
    private var cancelled = false
    private var finished = false
    private var authenticationRejected = false
    private var responseContinuation: CheckedContinuation<OpenCodeHTTPResponse, Error>?
    private var openingContinuation: CheckedContinuation<OpenCodeHTTPByteStream, Error>?
    private var drainWaiters: [CheckedContinuation<Void, Never>] = []
    private var byteStream: OpenCodeHTTPByteStream?
    private var eventBuffer: OpenCodeHTTPEventBuffer?

    init(maximumBytes: Int, events: Bool) {
        self.maximumBytes = maximumBytes; self.events = events
        if events {
            // Enforce the byte budget independently of URLSession callback
            // fragmentation, while keeping the same 512KiB maximum backlog.
            let buffer = OpenCodeHTTPEventBuffer(onCancel: { [weak self] in self?.cancel() })
            eventBuffer = buffer
            byteStream = OpenCodeHTTPByteStream(stream: buffer.makeStream(),
                cancel: { [weak self] in await self?.cancelAndWait() },
                wait: { [weak self] in await self?.waitUntilFinished() })
        }
    }

    func setResponseContinuation(_ continuation: CheckedContinuation<OpenCodeHTTPResponse, Error>) {
        lock.withLock { responseContinuation = continuation }
    }

    func setEventContinuation(_ continuation: CheckedContinuation<OpenCodeHTTPByteStream, Error>) {
        lock.withLock { openingContinuation = continuation }
    }

    func attach(_ task: URLSessionDataTask) {
        let shouldCancel = lock.withLock { self.task = task; return cancelled }
        if shouldCancel { task.cancel() }
    }

    func cancel() {
        let task = lock.withLock { () -> URLSessionDataTask? in
            guard !finished else { return nil }; cancelled = true; return self.task
        }
        task?.cancel()
    }

    func cancelAndWait() async {
        cancel()
        await waitUntilFinished()
    }

    func waitUntilFinished() async {
        await withCheckedContinuation { continuation in
            let alreadyFinished = lock.withLock {
                if finished { return true }; drainWaiters.append(continuation); return false
            }
            if alreadyFinished { continuation.resume() }
        }
    }

    func reject(_ reason: OpenCodeHTTPError) {
        let task = lock.withLock { () -> URLSessionDataTask? in
            guard !finished else { return nil }; if failure == nil { failure = reason }; return self.task
        }
        task?.cancel()
    }

    func rejectAuthentication(_ rawResponse: URLResponse?) {
        guard let rawResponse = rawResponse as? HTTPURLResponse, [401, 407].contains(rawResponse.statusCode) else {
            reject(.transportFailure); return
        }
        let _ = receive(rawResponse)
        lock.withLock { authenticationRejected = true }
    }

    func receive(_ rawResponse: URLResponse) -> Bool {
        guard let http = rawResponse as? HTTPURLResponse, let headers = Self.headers(http) else {
            reject(.invalidResponse); return false
        }
        var ready: (CheckedContinuation<OpenCodeHTTPByteStream, Error>, OpenCodeHTTPByteStream)?
        let accepted = lock.withLock { () -> Bool in
            guard !finished, !cancelled, failure == nil else { return false }
            response = OpenCodeHTTPResponse(status: http.statusCode, headers: headers, body: Data())
            if events {
                let mediaType = headers["content-type"]?.split(separator: ";", maxSplits: 1).first?
                    .trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
                guard http.statusCode == 200, mediaType == "text/event-stream" else {
                    failure = .eventResponseRejected(status: http.statusCode); return false
                }
                if let continuation = openingContinuation, let stream = byteStream {
                    ready = (continuation, stream); openingContinuation = nil; byteStream = nil
                }
            } else if http.expectedContentLength > Int64(maximumBytes) {
                failure = .responseBodyTooLarge; return false
            }
            return true
        }
        if let (continuation, stream) = ready { continuation.resume(returning: stream) }
        return accepted
    }

    func receive(_ data: Data) {
        guard !data.isEmpty else { return }
        if events {
            let buffer = lock.withLock {
                !finished && !cancelled && failure == nil && response != nil ? eventBuffer : nil
            }
            guard let buffer else { return }
            switch buffer.append(data) {
            case .enqueued: break
            case .overflow: reject(.eventBufferOverflow)
            case .terminated: cancel()
            }
        } else {
            let overflow = lock.withLock { () -> Bool in
                guard !finished, !cancelled, failure == nil else { return false }
                guard data.count <= maximumBytes - body.count else { failure = .responseBodyTooLarge; return true }
                body.append(data); return false
            }
            if overflow { lock.withLock { task }?.cancel() }
        }
    }

    func complete(_ underlyingError: Error?) {
        lock.lock()
        guard !finished else { lock.unlock(); return }
        finished = true
        let resultError: Error? = if let failure { failure }
            else if cancelled { CancellationError() }
            else if underlyingError != nil && !authenticationRejected { OpenCodeHTTPError.transportFailure }
            else if response == nil { OpenCodeHTTPError.invalidResponse }
            else { nil }
        let response = response.map { OpenCodeHTTPResponse(status: $0.status, headers: $0.headers, body: body) }
        let responseContinuation = responseContinuation, openingContinuation = openingContinuation
        let eventBuffer = eventBuffer, waiters = drainWaiters
        // Dropping the last unreturned stream can synchronously invoke its
        // onTermination callback, which re-enters cancel(). Release it unlocked.
        let pendingByteStream = byteStream
        self.responseContinuation = nil; self.openingContinuation = nil; self.eventBuffer = nil
        self.byteStream = nil; self.task = nil; body = Data(); drainWaiters.removeAll()
        lock.unlock()
        if let responseContinuation {
            if let resultError { responseContinuation.resume(throwing: resultError) }
            else if let response { responseContinuation.resume(returning: response) }
        }
        if let openingContinuation {
            openingContinuation.resume(throwing: resultError ?? OpenCodeHTTPError.invalidResponse)
        }
        eventBuffer?.finish(throwing: resultError)
        withExtendedLifetime(pendingByteStream) { }
        for waiter in waiters { waiter.resume() }
    }

    func failWithoutTask(_ reason: OpenCodeHTTPError) { lock.withLock { failure = reason }; complete(nil) }

    private static func headers(_ response: HTTPURLResponse) -> [String: String]? {
        guard response.allHeaderFields.count <= 128 else { return nil }
        var headers: [String: String] = [:], size = 0
        for (key, value) in response.allHeaderFields {
            guard let key = key as? String, let value = value as? String else { return nil }
            size += key.utf8.count + value.utf8.count
            guard size <= 16 * 1_024 else { return nil }
            headers[key.lowercased()] = value
        }
        return headers
    }
}
