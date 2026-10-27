import Foundation

/// Splits a server-sent events byte stream into the data payload of each event.
struct SSEParser {
    private var buffer = Data()
    private var dataLines: [String] = []

    nonisolated init() {}

    /// Feeds a chunk and returns the payloads of the events it completed.
    nonisolated mutating func feed(_ chunk: Data) -> [String] {
        buffer.append(chunk)
        var payloads: [String] = []
        while let newline = buffer.firstIndex(of: 0x0A) {
            var lineData = buffer[buffer.startIndex..<newline]
            buffer.removeSubrange(buffer.startIndex...newline)
            if lineData.last == 0x0D { lineData = lineData.dropLast() }
            let line = String(decoding: lineData, as: UTF8.self)
            if line.isEmpty {
                if !dataLines.isEmpty { payloads.append(dataLines.joined(separator: "\n")) }
                dataLines = []
                continue
            }
            if line.hasPrefix(":") { continue }
            let field: Substring
            var value: Substring
            if let colon = line.firstIndex(of: ":") {
                field = line[..<colon]
                value = line[line.index(after: colon)...]
                if value.hasPrefix(" ") { value = value.dropFirst() }
            } else {
                field = line[...]
                value = ""
            }
            if field == "data" { dataLines.append(String(value)) }
        }
        return payloads
    }
}

/// Follows an OpenCode server's `/api/event` stream and hands each event to the main actor, in order.
final class OpenCodeEventStream: NSObject, URLSessionDataDelegate, @unchecked Sendable {
    /// Heartbeats arrive every 10–15 seconds, so longer silence means the stream is stuck.
    nonisolated static let silenceTimeout: TimeInterval = 45

    private let request: URLRequest
    private let onEvent: @MainActor (JSONValue) -> Void
    private let onClose: @MainActor (_ reason: String) -> Void
    private let queue: OperationQueue
    private let lock = NSLock()
    private var urlSession: URLSession?
    /// Only touched on `queue`.
    private var parser = SSEParser()
    private var cancelled = false
    private var finished = false

    nonisolated init(
        api: OpenCodeAPI, onEvent: @escaping @MainActor (JSONValue) -> Void,
        onClose: @escaping @MainActor (_ reason: String) -> Void
    ) {
        var request = api.urlRequest("GET", "/api/event", timeout: Self.silenceTimeout)
        request.setValue("text/event-stream", forHTTPHeaderField: "Accept")
        self.request = request
        self.onEvent = onEvent
        self.onClose = onClose
        queue = OperationQueue()
        queue.maxConcurrentOperationCount = 1
        queue.name = "Coincide.OpenCodeEventStream"
        super.init()
    }

    nonisolated func start() {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.connectionProxyDictionary = [:]
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        configuration.urlCache = nil
        configuration.httpShouldSetCookies = false
        configuration.timeoutIntervalForRequest = Self.silenceTimeout
        configuration.timeoutIntervalForResource = 60 * 60 * 24 * 30
        let session = URLSession(configuration: configuration, delegate: self, delegateQueue: queue)
        lock.withLock { urlSession = session }
        session.dataTask(with: request).resume()
    }

    /// Stops reading. No callbacks follow.
    nonisolated func cancel() {
        let session = lock.withLock { () -> URLSession? in
            cancelled = true
            defer { urlSession = nil }
            return urlSession
        }
        session?.invalidateAndCancel()
    }

    nonisolated func urlSession(
        _ session: URLSession, dataTask: URLSessionDataTask, didReceive response: URLResponse,
        completionHandler: @escaping @Sendable (URLSession.ResponseDisposition) -> Void
    ) {
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        guard status == 200 else {
            completionHandler(.cancel)
            finish(String(localized: "The OpenCode server refused the event stream (HTTP \(status))."))
            return
        }
        completionHandler(.allow)
    }

    nonisolated func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
        let events = parser.feed(data).compactMap { JSONValue.parse($0) }
        guard !events.isEmpty else { return }
        DispatchQueue.main.async { [weak self] in
            MainActor.assumeIsolated {
                guard let self, !self.isCancelled else { return }
                for event in events { self.onEvent(event) }
            }
        }
    }

    nonisolated func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        finish(error.map { String(localized: "The OpenCode event stream stopped: \($0.localizedDescription)") })
        session.finishTasksAndInvalidate()
    }

    private nonisolated var isCancelled: Bool { lock.withLock { cancelled } }

    /// Reports the end once, after the events already received.
    private nonisolated func finish(_ error: String?) {
        let shouldReport = lock.withLock { () -> Bool in
            guard !cancelled, !finished else { return false }
            finished = true
            return true
        }
        guard shouldReport else { return }
        let message = error ?? String(localized: "The OpenCode server closed the event stream.")
        DispatchQueue.main.async { [weak self] in
            MainActor.assumeIsolated {
                guard let self, !self.isCancelled else { return }
                self.onClose(message)
            }
        }
    }
}
