import Foundation
import Testing
@testable import CoincideCore

@Suite struct OpenCodeSSEConnectionTests {
    @Test func readinessRequiresHeadersAndGenerationRoutesPreserveTheirRealScope() async throws {
        for generation in OpenCodeGeneration.allCases {
            try await withOpenCodeSSEFixture { fixture, client in
                let directory = "/tmp/native project/漢字 ?a&b=1+#directory"
                let opening = Task { try await OpenCodeSSEConnection.open(client: client, generation: generation, directory: URL(fileURLWithPath: directory)) }
                let channel = try await fixture.started()
                let url = try #require(channel.request.url)
                let components = try #require(URLComponents(url: url, resolvingAgainstBaseURL: false))
                #expect(components.path == (generation == .v1 ? "/event" : "/api/event"))
                #expect(components.queryItems == (generation == .v1 ? [.init(name: "directory", value: directory)] : nil))
                #expect(channel.request.value(forHTTPHeaderField: "Accept") == "text/event-stream")
                channel.respond(status: 200, headers: ["Content-Type": "text/event-stream; charset=utf-8"])
                // No data byte is sent: native HTTP headers alone establish readiness.
                let connection = try await opening.value
                await connection.close()
                try await fixture.stopped()
                #expect(fixture.stopCount == 1)
            }
        }
    }

    @Test func invalidDirectoryAndDeadlineFailBeforeAnyHTTPSubscription() async throws {
        try await withOpenCodeSSEFixture { fixture, client in
            for url in [URL(string: "https://example.invalid/project")!, URL(string: "file://other-host/tmp/project")!,
                        URL(string: "file:///tmp/project?query")!, URL(string: "file:///tmp/link/../project")!] {
                await #expect(throws: OpenCodeSSEConnectionError.invalidDirectory) {
                    try await OpenCodeSSEConnection.open(client: client, generation: .v2, directory: url)
                }
            }
            await #expect(throws: OpenCodeSSEConnectionError.invalidWatchdog) {
                try await OpenCodeSSEConnection.open(client: client, generation: .v2, directory: URL(fileURLWithPath: "/tmp/project"), silenceTimeout: .zero)
            }
            #expect(fixture.startCount == 0)
        }
    }

    @Test func rejectedEventHeadersDoNotCreateAReadyConnection() async throws {
        try await withOpenCodeSSEFixture { fixture, client in
            let opening = Task { try await OpenCodeSSEConnection.open(client: client, generation: .v2, directory: URL(fileURLWithPath: "/tmp/project")) }
            let channel = try await fixture.started()
            channel.respond(status: 401, headers: ["Content-Type": "application/json"])
            await #expect(throws: OpenCodeHTTPError.eventResponseRejected(status: 401)) { try await opening.value }
            try await fixture.stopped()
            #expect(fixture.startCount == 1)
        }
    }

    @Test func nativeByteStreamAndParserPreserveSplitUnicodeAndCommittedFrameBoundaries() async throws {
        try await withOpenCodeSSEFixture { fixture, client in
            let opening = Task { try await OpenCodeSSEConnection.open(client: client, generation: .v2, directory: URL(fileURLWithPath: "/tmp/project")) }
            let channel = try await fixture.started()
            channel.respond(status: 200, headers: ["Content-Type": "text/event-stream"])
            let connection = try await opening.value, events = connection.events
            let observed = Task { try await firstOpenCodeSSEEvent(events) }
            for byte in Data("id: é\r\ndata: 🌍\r\n\r\n".utf8) { channel.send(Data([byte])) }
            let event = try await observed.value
            #expect(event.event == "message" && event.data == "🌍" && event.id == "é")
            await connection.close()
        }
    }

    @Test func commentBytesKeepWatchdogAliveWithoutInventingEvents() async throws {
        try await withOpenCodeSSEFixture { fixture, client in
            let opening = Task { try await OpenCodeSSEConnection.open(client: client, generation: .v2, directory: URL(fileURLWithPath: "/tmp/project"), silenceTimeout: .milliseconds(600)) }
            let channel = try await fixture.started()
            channel.respond(status: 200, headers: ["Content-Type": "text/event-stream"])
            let connection = try await opening.value, events = connection.events
            let observed = Task { try await firstOpenCodeSSEEvent(events) }
            // More than a complete watchdog interval elapses, with only comments.
            for _ in 0..<8 {
                try await Task.sleep(for: .milliseconds(100))
                channel.send(Data(": heartbeat\r\n\r\n".utf8))
            }
            #expect(fixture.stopCount == 0)
            channel.send(Data("data: actual event\n\n".utf8))
            #expect(try await observed.value.data == "actual event")
            await connection.close()
        }
    }

    @Test func byteSilenceFailsExplicitlyAndDrainsTheNativeRequest() async throws {
        try await withOpenCodeSSEFixture { fixture, client in
            let opening = Task { try await OpenCodeSSEConnection.open(client: client, generation: .v2, directory: URL(fileURLWithPath: "/tmp/project"), silenceTimeout: .milliseconds(80)) }
            let channel = try await fixture.started()
            channel.respond(status: 200, headers: ["Content-Type": "text/event-stream"])
            let connection = try await opening.value, events = connection.events
            // An EOF fallback bounds a broken-watchdog test without retrying it.
            let fallback = Task {
                do { try await Task.sleep(for: .seconds(3)); channel.finish() }
                catch { /* The observed watchdog failure cancels this fallback. */ }
            }
            let observed = await collectOpenCodeSSEEvents(events)
            fallback.cancel()
            #expect(observed.events.isEmpty && observed.failure == .heartbeatTimedOut)
            await connection.close()
            try await fixture.stopped()
            #expect(fixture.stopCount == 1)
        }
    }

    @Test func EOFDiscardsTheUnfinishedEventAndRequiresReconciliation() async throws {
        try await withOpenCodeSSEFixture { fixture, client in
            let opening = Task { try await OpenCodeSSEConnection.open(client: client, generation: .v2, directory: URL(fileURLWithPath: "/tmp/project")) }
            let channel = try await fixture.started()
            channel.respond(status: 200, headers: ["Content-Type": "text/event-stream"])
            let connection = try await opening.value, events = connection.events
            channel.send(Data("data: committed\n\ndata: unfinished\n".utf8)); channel.finish()
            let observed = await collectOpenCodeSSEEvents(events)
            #expect(observed.events.map(\.data) == ["committed"])
            #expect(observed.failure == .disconnected)
            await connection.close()
            #expect(fixture.startCount == 1)
        }
    }

    @Test func typedRawHTTPFailureSurvivesTheRealClientSSEPathWithoutPublishingPrivateErrorDetails() async throws {
        try await withOpenCodeSSEFixture { fixture, client in
            let opening = Task { try await OpenCodeSSEConnection.open(client: client, generation: .v1, directory: URL(fileURLWithPath: "/tmp/project")) }
            let channel = try await fixture.started()
            channel.respond(status: 200, headers: ["Content-Type": "text/event-stream"])
            let connection = try await opening.value
            channel.fail(NSError(domain: "private-stream-domain-canary", code: 918_273,
                userInfo: [NSLocalizedDescriptionKey: "private-stream-description-canary", "private-field": "private-stream-payload-canary"]))
            let observed = await collectOpenCodeSSEEvents(connection.events)
            #expect(observed.events.isEmpty && observed.failure == .rawHTTPFailure(.transportFailure))
            #expect(observed.failure?.diagnosticCategory == "raw-http-transport-failure")
            #expect(observed.failure?.errorDescription == OpenCodeSSEConnectionError.disconnected.errorDescription)
            #expect(!observed.unexpectedError && observed.framingFailure == nil)
            await connection.close()
            // Error classification must not close the client or retry the stream.
            let independent = Task { try await client.request(path: ["provider"]) }
            let metadata = try await fixture.started(index: 1)
            metadata.respond(status: 200, headers: ["Content-Type": "application/json"])
            metadata.send(Data("{}".utf8)); metadata.finish()
            let response = try await independent.value
            #expect(response.status == 200 && fixture.startCount == 2)
        }
    }

    @Test func rawFailureDiagnosticsAllowOnlyFixedTypedCategoriesAndSanitizeUnknownErrors() {
        let overflow = OpenCodeSSEConnectionError.sanitizingStreamFailure(OpenCodeHTTPError.eventBufferOverflow)
        #expect(overflow == .rawHTTPFailure(.eventBufferOverflow))
        #expect(overflow.diagnosticCategory == "raw-http-event-buffer-overflow")
        let status = OpenCodeSSEConnectionError.sanitizingStreamFailure(OpenCodeHTTPError.eventResponseRejected(status: 413))
        #expect(status.diagnosticCategory == "raw-http-event-response-rejected")
        #expect(status.errorDescription == OpenCodeSSEConnectionError.disconnected.errorDescription)
        let unknown = OpenCodeSSEConnectionError.sanitizingStreamFailure(NSError(domain: "private-stream-domain-canary", code: 918_273,
            userInfo: [NSLocalizedDescriptionKey: "private-stream-description-canary", "private-field": "private-stream-payload-canary"]))
        #expect(unknown == .disconnected && unknown.diagnosticCategory == "sse-disconnected")
        #expect(unknown.errorDescription == OpenCodeSSEConnectionError.disconnected.errorDescription)
        #expect(!unknown.diagnosticCategory.contains("canary") && !unknown.diagnosticCategory.contains("918273"))
    }

    @Test func malformedUTF8FailsFramingWithoutPublishingPrivateWireData() async throws {
        try await withOpenCodeSSEFixture { fixture, client in
            let opening = Task { try await OpenCodeSSEConnection.open(client: client, generation: .v2, directory: URL(fileURLWithPath: "/tmp/project")) }
            let channel = try await fixture.started()
            channel.respond(status: 200, headers: ["Content-Type": "text/event-stream"])
            let connection = try await opening.value, events = connection.events
            channel.send(Data([100, 97, 116, 97, 58, 0xFF, 10, 10]))
            let observed = await collectOpenCodeSSEEvents(events)
            #expect(observed.events.isEmpty && observed.framingFailure == .invalidEvent)
            await connection.close()
            try await fixture.stopped()
            #expect(fixture.stopCount == 1)
        }
    }

    @Test func slowConsumerFailsOnItsSeventeenthEventInsteadOfDroppingAnEvent() async throws {
        try await withOpenCodeSSEFixture { fixture, client in
            let opening = Task { try await OpenCodeSSEConnection.open(client: client, generation: .v2, directory: URL(fileURLWithPath: "/tmp/project")) }
            let channel = try await fixture.started()
            channel.respond(status: 200, headers: ["Content-Type": "text/event-stream"])
            let connection = try await opening.value, events = connection.events
            channel.send(Data((0..<17).map { "data: event-\($0)\n\n" }.joined().utf8))
            try await fixture.stopped()
            let observed = await collectOpenCodeSSEEvents(events)
            #expect(observed.events.map(\.data) == (0..<16).map { "event-\($0)" })
            #expect(observed.failure == .eventBufferOverflow)
            await connection.close()
        }
    }

    @Test func concurrentCloseJoinsOnlyTheSubscriptionAndPreservesAnIndependentMetadataRead() async throws {
        try await withOpenCodeSSEFixture { fixture, client in
            let opening = Task { try await OpenCodeSSEConnection.open(client: client, generation: .v2, directory: URL(fileURLWithPath: "/tmp/project")) }
            let channel = try await fixture.started()
            channel.respond(status: 200, headers: ["Content-Type": "text/event-stream"])
            let connection = try await opening.value
            let metadata = Task { try await client.request(path: ["api", "info"]) }
            let independent = try await fixture.started(index: 1)
            async let first: Void = connection.close()
            async let second: Void = connection.close()
            _ = await (first, second)
            try await fixture.stopped()
            #expect(fixture.stopCount == 1)
            independent.respond(status: 200, headers: ["Content-Type": "application/json"])
            independent.send(Data("{}".utf8)); independent.finish()
            let response = try await metadata.value
            #expect(response.status == 200 && response.body == Data("{}".utf8))
            let observed = await collectOpenCodeSSEEvents(connection.events)
            #expect(observed.events.isEmpty && observed.failure == nil && !observed.unexpectedError)
        }
    }

    @Test func consumerCancellationStopsAndDrainsTheOwnedSubscription() async throws {
        try await withOpenCodeSSEFixture { fixture, client in
            let opening = Task { try await OpenCodeSSEConnection.open(client: client, generation: .v2, directory: URL(fileURLWithPath: "/tmp/project")) }
            let channel = try await fixture.started()
            channel.respond(status: 200, headers: ["Content-Type": "text/event-stream"])
            let connection = try await opening.value, events = connection.events
            let consumer = Task { await collectOpenCodeSSEEvents(events) }
            consumer.cancel(); _ = await consumer.value
            try await fixture.stopped()
            await connection.close()
            #expect(fixture.stopCount == 1)
        }
    }

    @Test func idleWorkersDoNotRetainAnAbandonedConnection() async throws {
        try await withOpenCodeSSEFixture { fixture, client in
            var opening: Task<OpenCodeSSEConnection, Error>? = Task { try await OpenCodeSSEConnection.open(client: client, generation: .v2, directory: URL(fileURLWithPath: "/tmp/project")) }
            let channel = try await fixture.started()
            channel.respond(status: 200, headers: ["Content-Type": "text/event-stream"])
            var connection: OpenCodeSSEConnection? = try await opening?.value
            opening = nil
            weak let released = connection
            connection = nil
            try await fixture.stopped()
            #expect(released == nil && fixture.stopCount == 1)
        }
    }
}

private struct OpenCodeSSEObservation: Sendable {
    var events: [OpenCodeSSEEvent] = []
    var failure: OpenCodeSSEConnectionError?
    var framingFailure: OpenCodeProtocolError?
    var unexpectedError = false
}

private func collectOpenCodeSSEEvents(_ events: AsyncThrowingStream<OpenCodeSSEEvent, Error>) async -> OpenCodeSSEObservation {
    var observed = OpenCodeSSEObservation()
    do { for try await event in events { observed.events.append(event) } }
    catch {
        observed.failure = error as? OpenCodeSSEConnectionError; observed.framingFailure = error as? OpenCodeProtocolError
        observed.unexpectedError = observed.failure == nil && observed.framingFailure == nil
    }
    return observed
}

private func firstOpenCodeSSEEvent(_ events: AsyncThrowingStream<OpenCodeSSEEvent, Error>) async throws -> OpenCodeSSEEvent {
    for try await event in events { return event }
    throw OpenCodeSSEFixtureError.timeout
}

private func withOpenCodeSSEFixture(_ body: @Sendable (OpenCodeSSEFixture, OpenCodeHTTPClient) async throws -> Void) async throws {
    let fixture = OpenCodeSSEFixture()
    let client = try OpenCodeHTTPClient(origin: fixture.origin, configuration: fixture.configuration)
    do { try await body(fixture, client); await client.close(); fixture.remove() }
    catch { await client.close(); fixture.remove(); throw error }
}

private enum OpenCodeSSEFixtureError: Error { case timeout }

/// Opaque fake hosts are intercepted by URLProtocol; no socket or provider is used.
private final class OpenCodeSSEFixture: @unchecked Sendable {
    private static let registryLock = NSLock()
    nonisolated(unsafe) private static var registry: [String: OpenCodeSSEFixture] = [:]
    private let lock = NSLock()
    private var channels: [OpenCodeSSEFixtureProtocol] = []
    private var stops = 0
    private let host: String

    init() {
        host = "opencode-sse-\(UUID().uuidString.lowercased()).invalid"
        Self.registryLock.withLock { Self.registry[host] = self }
    }
    var origin: URL { URL(string: "https://\(host)")! }
    var configuration: URLSessionConfiguration {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [OpenCodeSSEFixtureProtocol.self]
        return configuration
    }
    var startCount: Int { lock.withLock { channels.count } }
    var stopCount: Int { lock.withLock { stops } }
    func remove() { _ = Self.registryLock.withLock { Self.registry.removeValue(forKey: host) } }
    static func find(_ host: String?) -> OpenCodeSSEFixture? { registryLock.withLock { host.flatMap { registry[$0] } } }
    func didStart(_ channel: OpenCodeSSEFixtureProtocol) { lock.withLock { channels.append(channel) } }
    func didStop() { lock.withLock { stops += 1 } }
    func started(index: Int = 0) async throws -> OpenCodeSSEFixtureProtocol {
        for _ in 0..<300 {
            if let channel = lock.withLock({ channels.indices.contains(index) ? channels[index] : nil }) { return channel }
            try await Task.sleep(for: .milliseconds(10))
        }
        throw OpenCodeSSEFixtureError.timeout
    }
    func stopped() async throws {
        for _ in 0..<300 {
            if stopCount > 0 { return }
            try await Task.sleep(for: .milliseconds(10))
        }
        throw OpenCodeSSEFixtureError.timeout
    }
}

private final class OpenCodeSSEFixtureProtocol: URLProtocol, @unchecked Sendable {
    private let fixtureLock = NSRecursiveLock()
    private var stopped = false

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        guard let fixture = OpenCodeSSEFixture.find(request.url?.host) else {
            client?.urlProtocol(self, didFailWithError: URLError(.unsupportedURL)); return
        }
        fixture.didStart(self)
    }
    override func stopLoading() {
        fixtureLock.withLock {
            guard !stopped else { return }; stopped = true
            OpenCodeSSEFixture.find(request.url?.host)?.didStop()
        }
    }
    func respond(status: Int, headers: [String: String]) {
        fixtureLock.withLock {
            guard !stopped, let url = request.url,
                  let response = HTTPURLResponse(url: url, statusCode: status, httpVersion: "HTTP/1.1", headerFields: headers) else { return }
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        }
    }
    func send(_ bytes: Data) { fixtureLock.withLock { if !stopped { client?.urlProtocol(self, didLoad: bytes) } } }
    func finish() { fixtureLock.withLock { if !stopped { client?.urlProtocolDidFinishLoading(self) } } }
    func fail(_ error: any Error) { fixtureLock.withLock { if !stopped { client?.urlProtocol(self, didFailWithError: error) } } }
}
