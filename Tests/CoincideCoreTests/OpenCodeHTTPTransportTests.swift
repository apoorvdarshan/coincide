import Foundation
import Testing
@testable import CoincideCore

@Suite struct OpenCodeHTTPTransportTests {
    @Test func onlyOriginURLsAndLoopbackHTTPAreAccepted() async throws {
        for source in ["https://server.example", "http://127.0.0.1:49152/", "http://127.2.3.4", "http://[::1]:49152", "http://localhost:49152"] {
            let client = try OpenCodeHTTPClient(origin: #require(URL(string: source)))
            await client.close()
        }
        for source in ["http://server.example", "file:///tmp/provider", "ftp://localhost", "https://name:password@server.example",
                       "https://server.example/api", "https://server.example/%2F", "https://server.example?", "https://server.example#", "http://127.01.0.1", "http://127.0.0.1:0"] {
            #expect(throws: OpenCodeHTTPError.invalidOrigin) {
                try OpenCodeHTTPClient(origin: #require(URL(string: source)))
            }
        }
    }

    @Test func literalPathAndDirectoryQueryPreserveUnicodeAndReservedCharacters() async throws {
        let fixture = OpenCodeHTTPFixture(); defer { fixture.remove() }
        let credential = try OpenCodeHTTPCredential(username: "utilisateur", password: "clé 🌍:x")
        let client = try OpenCodeHTTPClient(origin: fixture.origin, credential: credential, configuration: fixture.configuration)
        let directory = "/tmp/project spaces/漢字?x=a&b=2+#literal"
        let operation = Task {
            try await client.request(path: ["api", "session", "résumé ?#%"],
                                     query: [.init(name: "location[directory]", value: directory)])
        }
        let channel = try await fixture.started()
        let requestURL = try #require(channel.request.url)
        let components = try #require(URLComponents(url: requestURL, resolvingAgainstBaseURL: false))
        #expect(components.percentEncodedPath == "/api/session/r%C3%A9sum%C3%A9%20%3F%23%25")
        #expect(components.queryItems == [.init(name: "location[directory]", value: directory)])
        #expect(components.user == nil && components.password == nil)
        #expect(channel.request.value(forHTTPHeaderField: "Authorization") == "Basic " + Data("utilisateur:clé 🌍:x".utf8).base64EncodedString())
        #expect(!(channel.request.url?.absoluteString.contains("clé") ?? true))
        channel.respond(status: 200, headers: ["Content-Type": "application/json"])
        channel.send(Data("{}".utf8)); channel.finish()
        let response = try await operation.value
        #expect(response.status == 200 && response.headers["content-type"] == "application/json" && response.body == Data("{}".utf8))
        await client.close()
    }

    @Test func pathTraversalMethodsAndCredentialQueriesFailBeforeNetwork() async throws {
        let fixture = OpenCodeHTTPFixture(); defer { fixture.remove() }
        let client = try OpenCodeHTTPClient(origin: fixture.origin, configuration: fixture.configuration)
        for path in [["api", ".."], ["api", "."], ["api", "a/b"], ["api", "a\\b"], ["api", ""], ["api", "line\nvalue"]] {
            await #expect(throws: OpenCodeHTTPError.invalidPath) { try await client.request(path: path) }
        }
        for name in ["token", "Authorization", "API-key", "access_token", "password", "secret", "headers[Authorization]"] {
            await #expect(throws: OpenCodeHTTPError.invalidQuery) {
                try await client.request(path: ["api", "info"], query: [.init(name: name, value: "fixture-value")])
            }
        }
        await #expect(throws: OpenCodeHTTPError.invalidMethod) { try await client.request(method: "GET\r\nX-Header: injected", path: ["api"]) }
        await #expect(throws: OpenCodeHTTPError.invalidLimit) { try await client.request(path: ["api"], maximumBytes: 0) }
        await #expect(throws: OpenCodeHTTPError.requestBodyTooLarge) {
            try await client.request(method: "POST", path: ["api"], body: Data(repeating: 0, count: 4 * 1_024 * 1_024 + 1))
        }
        #expect(fixture.startCount == 0)
        await client.close()
    }

    @Test func untrustedConfigurationCannotSupplyCookiesOrAdditionalCredentials() async throws {
        let fixture = OpenCodeHTTPFixture(); defer { fixture.remove() }
        let configuration = fixture.configuration
        configuration.httpAdditionalHeaders = ["Cookie": "fixture-cookie", "Authorization": "fixture-unrelated-credential", "X-Unrelated": "fixture"]
        configuration.urlCredentialStorage = .shared
        let client = try OpenCodeHTTPClient(origin: fixture.origin, configuration: configuration)
        let operation = Task { try await client.request(path: ["api", "info"]) }
        let channel = try await fixture.started()
        #expect(channel.request.value(forHTTPHeaderField: "Cookie") == nil)
        #expect(channel.request.value(forHTTPHeaderField: "Authorization") == nil)
        #expect(channel.request.value(forHTTPHeaderField: "X-Unrelated") == nil)
        #expect(!channel.request.httpShouldHandleCookies)
        channel.respond(status: 200); channel.finish()
        _ = try await operation.value
        await client.close()
    }

    @Test func nonSuccessHTTPStatusAndBoundedBodyAreReturnedWithoutRetry() async throws {
        let fixture = OpenCodeHTTPFixture(); defer { fixture.remove() }
        let client = try OpenCodeHTTPClient(origin: fixture.origin, configuration: fixture.configuration)
        let operation = Task { try await client.request(method: "POST", path: ["api", "session"], body: Data("{}".utf8), maximumBytes: 64) }
        let channel = try await fixture.started()
        channel.respond(status: 401, headers: ["Content-Type": "application/json"])
        channel.send(Data("{\"error\":\"unauthorized\"}".utf8)); channel.finish()
        let response = try await operation.value
        #expect(response.status == 401)
        #expect(response.body == Data("{\"error\":\"unauthorized\"}".utf8))
        #expect(fixture.startCount == 1)
        await client.close()
    }

    @Test func oversizedResponseCancelsIncrementallyBeforeServerFinishes() async throws {
        let fixture = OpenCodeHTTPFixture(); defer { fixture.remove() }
        let client = try OpenCodeHTTPClient(origin: fixture.origin, configuration: fixture.configuration)
        let operation = Task { try await client.request(path: ["api", "info"], maximumBytes: 4) }
        let channel = try await fixture.started()
        channel.respond(status: 503, headers: ["Content-Type": "application/json"])
        channel.send(Data([1, 2, 3])); channel.send(Data([4, 5]))
        await #expect(throws: OpenCodeHTTPError.responseBodyTooLarge) { try await operation.value }
        try await fixture.stopped()
        #expect(fixture.stopCount == 1)
        await client.close()
    }

    @Test func declaredOversizedResponseCancelsWithoutConsumingTheBody() async throws {
        let fixture = OpenCodeHTTPFixture(); defer { fixture.remove() }
        let client = try OpenCodeHTTPClient(origin: fixture.origin, configuration: fixture.configuration)
        let operation = Task { try await client.request(path: ["api", "info"], maximumBytes: 4) }
        let channel = try await fixture.started()
        channel.respond(status: 200, headers: ["Content-Type": "application/json", "Content-Length": "5"])
        await #expect(throws: OpenCodeHTTPError.responseBodyTooLarge) { try await operation.value }
        try await fixture.stopped()
        await client.close()
    }

    @Test func redirectsAreRejectedBeforeFollowingEvenAtSameOrigin() async throws {
        for sameOrigin in [true, false] {
            let fixture = OpenCodeHTTPFixture(); defer { fixture.remove() }
            let client = try OpenCodeHTTPClient(origin: fixture.origin, credential: OpenCodeHTTPCredential(password: "fixture-only"), configuration: fixture.configuration)
            let operation = Task { try await client.request(method: "POST", path: ["api", "session"], body: Data("{}".utf8)) }
            let channel = try await fixture.started()
            let destination = sameOrigin ? fixture.origin.appendingPathComponent("redirected") : URL(string: "https://other-fixture.invalid/private")!
            channel.redirect(to: destination)
            await #expect(throws: OpenCodeHTTPError.redirectDenied) { try await operation.value }
            #expect(fixture.startCount == 1)
            await client.close()
        }
    }

    @Test func eventsRequireSuccessfulEventStreamHeadersBeforeOpening() async throws {
        for (status, contentType) in [(401, "text/event-stream"), (200, "text/html"), (204, "text/event-stream")] {
            let fixture = OpenCodeHTTPFixture(); defer { fixture.remove() }
            let client = try OpenCodeHTTPClient(origin: fixture.origin, configuration: fixture.configuration)
            let operation = Task { try await client.openEvents(path: ["api", "event"]) }
            let channel = try await fixture.started()
            channel.respond(status: status, headers: ["Content-Type": contentType])
            await #expect(throws: OpenCodeHTTPError.eventResponseRejected(status: status)) { try await operation.value }
            try await fixture.stopped()
            await client.close()
        }
    }

    @Test func eventReadinessDoesNotWaitForFirstByteAndSplitUTF8IsLossless() async throws {
        let fixture = OpenCodeHTTPFixture(); defer { fixture.remove() }
        let client = try OpenCodeHTTPClient(origin: fixture.origin, configuration: fixture.configuration)
        let operation = Task { try await client.openEvents(path: ["api", "event"]) }
        let channel = try await fixture.started()
        #expect(channel.request.value(forHTTPHeaderField: "Accept") == "text/event-stream")
        channel.respond(status: 200, headers: ["Content-Type": "TEXT/EVENT-STREAM; charset=utf-8"])
        let stream = try await operation.value
        let expected = Data("data: {\"text\":\"🌍漢\"}\r\n\r\n".utf8)
        for byte in expected { channel.send(Data([byte])) }
        channel.finish()
        var observed = Data()
        for try await bytes in stream.stream { observed.append(bytes) }
        #expect(observed == expected)
        await stream.close(); await client.close()
    }

    @Test func slowConsumerOverflowFailsAndCancelsInsteadOfDroppingSilently() async throws {
        let fixture = OpenCodeHTTPFixture(); defer { fixture.remove() }
        let client = try OpenCodeHTTPClient(origin: fixture.origin, configuration: fixture.configuration)
        let opening = Task { try await client.openEvents(path: ["api", "event"]) }
        let channel = try await fixture.started()
        channel.respond(status: 200, headers: ["Content-Type": "text/event-stream"])
        let stream = try await opening.value
        channel.send(Data(repeating: 65, count: 33 * 16 * 1_024))
        try await fixture.stopped()
        var observed = Data(), failure: OpenCodeHTTPError?
        do { for try await bytes in stream.stream { observed.append(bytes) } }
        catch { failure = error as? OpenCodeHTTPError }
        #expect(failure == .eventBufferOverflow)
        #expect(observed.count == 32 * 16 * 1_024)
        await stream.close(); await client.close()
    }

    @Test func tinyFragmentBurstWithinByteBudgetPreservesEveryByteForAHeldConsumer() async throws {
        let fixture = OpenCodeHTTPFixture(); defer { fixture.remove() }
        let client = try OpenCodeHTTPClient(origin: fixture.origin, configuration: fixture.configuration)
        do {
            let opening = Task { try await client.openEvents(path: ["api", "event"]) }
            let channel = try await fixture.started()
            channel.respond(status: 200, headers: ["Content-Type": "text/event-stream"])
            let stream = try await opening.value
            let expected = Data((0..<(33 * 11)).map { UInt8(65 + $0 % 26) })
            // The consumer deliberately starts only after all callbacks. These
            // 363 bytes are far below the existing 32 * 16KiB byte allowance;
            // callback fragmentation must not independently exhaust it.
            for index in 0..<33 { channel.send(expected.subdata(in: (index * 11)..<((index + 1) * 11))) }
            channel.finish()
            await stream.waitUntilFinished()
            var observed = Data(), failed = false, failure: OpenCodeHTTPError?
            do { for try await chunk in stream.stream { observed.append(chunk) } }
            catch { failed = true; failure = error as? OpenCodeHTTPError }
            #expect(!failed && failure == nil)
            #expect(observed == expected)
            #expect(fixture.startCount == 1)
            await stream.close(); await client.close()
        } catch { await client.close(); throw error }
    }

    @Test func independentTinyDelegateCallbacksWithinTheByteBudgetRemainLossless() async throws {
        let operation = OpenCodeHTTPTaskState(maximumBytes: 0, events: true)
        let response = try #require(HTTPURLResponse(url: URL(string: "https://callback-fixture.invalid/event")!,
            statusCode: 200, httpVersion: "HTTP/1.1", headerFields: ["Content-Type": "text/event-stream"]))
        let stream: OpenCodeHTTPByteStream = try await withCheckedThrowingContinuation { continuation in
            operation.setEventContinuation(continuation)
            #expect(operation.receive(response))
        }
        // Inject at the actual delegate boundary: URLProtocol and real TCP can
        // coalesce writes, so neither proves how many Data callbacks arrived.
        let expected = Data((0..<(33 * 11)).map { UInt8(65 + $0 % 26) })
        for index in 0..<33 { operation.receive(expected.subdata(in: (index * 11)..<((index + 1) * 11))) }
        operation.complete(nil)
        var observed = Data(), failure: OpenCodeHTTPError?
        do { for try await chunk in stream.stream { observed.append(chunk) } }
        catch { failure = error as? OpenCodeHTTPError; #expect(error is OpenCodeHTTPError) }
        #expect(failure == nil)
        #expect(observed == expected)
        await stream.close()
    }

    @Test func cancellingAnOpeningRequestStopsItsExactOwnedTask() async throws {
        let fixture = OpenCodeHTTPFixture(); defer { fixture.remove() }
        let client = try OpenCodeHTTPClient(origin: fixture.origin, configuration: fixture.configuration)
        let opening = Task { try await client.openEvents(path: ["api", "event"]) }
        _ = try await fixture.started()
        opening.cancel()
        await #expect(throws: CancellationError.self) { try await opening.value }
        try await fixture.stopped()
        #expect(fixture.startCount == 1 && fixture.stopCount == 1)
        await client.close()
    }

    @Test func streamCloseDrainsOnlyItsRequestAndClientClosePreventsNewRequests() async throws {
        let fixture = OpenCodeHTTPFixture(); defer { fixture.remove() }
        let client = try OpenCodeHTTPClient(origin: fixture.origin, configuration: fixture.configuration)
        let opening = Task { try await client.openEvents(path: ["api", "event"]) }
        let channel = try await fixture.started()
        channel.respond(status: 200, headers: ["Content-Type": "text/event-stream"])
        let stream = try await opening.value
        let body = Task { try await client.request(path: ["api", "info"]) }
        let independent = try await fixture.started(index: 1)
        await stream.close()
        try await fixture.stopped()
        #expect(fixture.stopCount == 1)
        await #expect(throws: CancellationError.self) {
            for try await _ in stream.stream { }
        }
        independent.respond(status: 200); independent.send(Data("{}".utf8)); independent.finish()
        #expect(try await body.value.body == Data("{}".utf8))
        await client.close(); await client.close()
        await #expect(throws: OpenCodeHTTPError.clientClosed) { try await client.request(path: ["api", "info"]) }
        #expect(fixture.startCount == 2)
    }

    @Test func abandoningAnUnreadByteStreamCancelsOnlyItsOwnedRequest() async throws {
        let fixture = OpenCodeHTTPFixture(); defer { fixture.remove() }
        let client = try OpenCodeHTTPClient(origin: fixture.origin, configuration: fixture.configuration)
        do {
            var opening: Task<OpenCodeHTTPByteStream, any Error>? = Task { try await client.openEvents(path: ["api", "event"]) }
            let channel = try await fixture.started()
            channel.respond(status: 200, headers: ["Content-Type": "text/event-stream"])
            var stream = try await opening?.value
            opening = nil
            #expect(stream != nil)
            stream = nil
            try await fixture.stopped()
            #expect(fixture.stopCount == 1)
            let metadata = Task { try await client.request(path: ["provider"]) }
            let independent = try await fixture.started(index: 1)
            #expect(fixture.startCount == 2 && fixture.stopCount == 1)
            independent.respond(status: 200); independent.send(Data("{}".utf8)); independent.finish()
            #expect(try await metadata.value.body == Data("{}".utf8))
            await client.close()
        } catch { await client.close(); throw error }
    }

    @Test func requestCancellationPreservesCancellationAndNeverReplaysAMutation() async throws {
        let fixture = OpenCodeHTTPFixture(); defer { fixture.remove() }
        let client = try OpenCodeHTTPClient(origin: fixture.origin, configuration: fixture.configuration)
        let operation = Task { try await client.request(method: "POST", path: ["api", "session"], body: Data("{}".utf8)) }
        let channel = try await fixture.started()
        channel.respond(status: 200); channel.send(Data([1]))
        operation.cancel()
        await #expect(throws: CancellationError.self) { try await operation.value }
        try await fixture.stopped()
        #expect(fixture.startCount == 1 && fixture.stopCount == 1)
        await client.close()
    }

    @Test func clientCloseCancelsAndDrainsPendingBodies() async throws {
        let fixture = OpenCodeHTTPFixture(); defer { fixture.remove() }
        let client = try OpenCodeHTTPClient(origin: fixture.origin, configuration: fixture.configuration)
        let operation = Task { try await client.request(path: ["api", "info"]) }
        let channel = try await fixture.started()
        channel.respond(status: 200); channel.send(Data([1]))
        await client.close()
        await #expect(throws: CancellationError.self) { try await operation.value }
        try await fixture.stopped()
        #expect(fixture.stopCount == 1)
    }

    @Test func underlyingErrorsCannotExposePrivateRequestOrResponseText() async throws {
        let fixture = OpenCodeHTTPFixture(); defer { fixture.remove() }
        let client = try OpenCodeHTTPClient(origin: fixture.origin, configuration: fixture.configuration)
        let operation = Task { try await client.request(method: "POST", path: ["api", "session"], body: Data("private-prompt-sentinel".utf8)) }
        let channel = try await fixture.started()
        channel.fail(NSError(domain: "fixture-private-domain", code: 17,
                             userInfo: [NSLocalizedDescriptionKey: "private-response-sentinel https://name:password@private.invalid/token"]))
        do { _ = try await operation.value; Issue.record("The transport accepted a failed request.") }
        catch {
            #expect(error as? OpenCodeHTTPError == .transportFailure)
            #expect(!String(describing: error).contains("sentinel"))
            #expect(!String(describing: error).contains("password"))
            #expect(!String(reflecting: error).contains("private.invalid"))
        }
        #expect(fixture.startCount == 1)
        await client.close()
    }
}

private enum OpenCodeHTTPFixtureError: Error { case timeout }

/// Every fixture owns an opaque fake HTTPS host. URLProtocol handles it without opening a socket.
private final class OpenCodeHTTPFixture: @unchecked Sendable {
    private static let registryLock = NSLock()
    nonisolated(unsafe) private static var registry: [String: OpenCodeHTTPFixture] = [:]
    private let lock = NSLock()
    private var channels: [OpenCodeHTTPFixtureProtocol] = []
    private var stops = 0
    let host: String

    init() {
        host = "opencode-\(UUID().uuidString.lowercased()).invalid"
        Self.registryLock.withLock { Self.registry[host] = self }
    }

    var origin: URL { URL(string: "https://\(host)")! }
    var configuration: URLSessionConfiguration {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [OpenCodeHTTPFixtureProtocol.self]
        return configuration
    }
    var startCount: Int { lock.withLock { channels.count } }
    var stopCount: Int { lock.withLock { stops } }
    func remove() { _ = Self.registryLock.withLock { Self.registry.removeValue(forKey: host) } }
    static func find(_ host: String?) -> OpenCodeHTTPFixture? { registryLock.withLock { host.flatMap { registry[$0] } } }
    func didStart(_ channel: OpenCodeHTTPFixtureProtocol) { lock.withLock { channels.append(channel) } }
    func didStop() { lock.withLock { stops += 1 } }

    func started(index: Int = 0) async throws -> OpenCodeHTTPFixtureProtocol {
        for _ in 0..<300 {
            if let channel = lock.withLock({ channels.indices.contains(index) ? channels[index] : nil }) { return channel }
            try await Task.sleep(for: .milliseconds(10))
        }
        throw OpenCodeHTTPFixtureError.timeout
    }

    func stopped() async throws {
        for _ in 0..<300 {
            if stopCount > 0 { return }
            try await Task.sleep(for: .milliseconds(10))
        }
        throw OpenCodeHTTPFixtureError.timeout
    }
}

private final class OpenCodeHTTPFixtureProtocol: URLProtocol, @unchecked Sendable {
    private let fixtureLock = NSRecursiveLock()
    private var stopped = false

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        guard let fixture = OpenCodeHTTPFixture.find(request.url?.host) else {
            fail(URLError(.unsupportedURL)); return
        }
        fixture.didStart(self)
    }
    override func stopLoading() {
        fixtureLock.withLock {
            guard !stopped else { return }; stopped = true
            OpenCodeHTTPFixture.find(request.url?.host)?.didStop()
        }
    }
    func respond(status: Int, headers: [String: String] = [:]) {
        fixtureLock.withLock {
            guard !stopped, let url = request.url,
                  let response = HTTPURLResponse(url: url, statusCode: status, httpVersion: "HTTP/1.1", headerFields: headers) else { return }
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        }
    }
    func send(_ bytes: Data) {
        fixtureLock.withLock { if !stopped { client?.urlProtocol(self, didLoad: bytes) } }
    }
    func finish() {
        fixtureLock.withLock { if !stopped { client?.urlProtocolDidFinishLoading(self) } }
    }
    func fail(_ error: Error) {
        fixtureLock.withLock { if !stopped { client?.urlProtocol(self, didFailWithError: error) } }
    }
    func redirect(to destination: URL) {
        fixtureLock.withLock {
            guard !stopped, let url = request.url,
                  let response = HTTPURLResponse(url: url, statusCode: 307, httpVersion: "HTTP/1.1", headerFields: ["Location": destination.absoluteString]) else { return }
            var redirected = request; redirected.url = destination
            client?.urlProtocol(self, wasRedirectedTo: redirected, redirectResponse: response)
        }
    }
}
