import Foundation
@preconcurrency import Network
import Testing
@testable import CoincideCore

@Test(arguments: ["duplicate-length", "transfer-encoding", "negative-length", "overflow-length", "extra-body", "folded-header", "non-post", "too-many-headers", "oversize"])
func scheduledTaskHTTPParserRejectsAmbiguousOrUnboundedFraming(mode: String) throws {
    let suffix: String
    switch mode {
    case "duplicate-length": suffix = "Content-Length: 0\r\ncontent-length: 0\r\n\r\n"
    case "transfer-encoding": suffix = "Content-Length: 0\r\nTransfer-Encoding: chunked\r\n\r\n"
    case "negative-length": suffix = "Content-Length: -1\r\n\r\n"
    case "overflow-length": suffix = "Content-Length: 9999999999999999999999999999999999\r\n\r\n"
    case "extra-body": suffix = "Content-Length: 0\r\n\r\nPOST /next HTTP/1.1"
    case "folded-header": suffix = "Content-Length: 0\r\n Authorization: Bearer no\r\n\r\n"
    case "too-many-headers": suffix = (0..<65).map { "x-\($0): x\r\n" }.joined() + "Content-Length: 0\r\n\r\n"
    case "oversize": suffix = "x-body: " + String(repeating: "x", count: 16_384) + "\r\nContent-Length: 0\r\n\r\n"
    default: suffix = "Content-Length: 0\r\n\r\n"
    }
    let verb = mode == "non-post" ? "GET" : "POST"
    #expect(throws: ScheduledTaskError.invalidWebhook) { try ScheduledTaskHTTPParser.parse(Data("\(verb) /hooks/00000000-0000-0000-0000-000000000001 HTTP/1.1\r\n".utf8) + Data(suffix.utf8)) }
}

@Test func scheduledTaskHTTPParserWaitsForCompleteExactBinaryBodyAndDoesNotTreatUTF8AsByteCount() throws {
    let body = Data([0, 1, 255]) + Data("😀工作".utf8)
    let header = Data("POST /hooks/00000000-0000-0000-0000-000000000001 HTTP/1.1\r\nContent-Length: \(body.count)\r\nAuthorization: Bearer private-fixture\r\n\r\n".utf8)
    #expect(try ScheduledTaskHTTPParser.parse(header) == nil)
    #expect(try ScheduledTaskHTTPParser.parse(header + body.dropLast()) == nil)
    let request = try #require(try ScheduledTaskHTTPParser.parse(header + body))
    #expect(request.body == body && request.headers["authorization"] == "Bearer private-fixture")
}

private actor ScheduledHTTPProbe {
    private(set) var bodies: [Data] = []
    func receive(_ request: ScheduledTaskHTTPRequest) -> ScheduledTaskHTTPResponse { bodies.append(request.body); return .init(status: 202, outcome: "accepted") }
}
@Test(.timeLimit(.minutes(1)))
func scheduledTaskOwnedLoopbackHTTPListenerDeliversExactBodyAndJoinsPartialReadersOnShutdown() async throws {
    let probe = ScheduledHTTPProbe(), server = ScheduledTaskHTTPServer { await probe.receive($0) }
    let port = try await server.start()
    let configuration = URLSessionConfiguration.ephemeral; configuration.connectionProxyDictionary = [:]; configuration.urlCredentialStorage = nil; configuration.httpCookieStorage = nil
    let session = URLSession(configuration: configuration)
    defer { session.invalidateAndCancel() }
    do {
        let body = Data("Private offline 🌍 webhook".utf8)
        var request = URLRequest(url: URL(string: "http://127.0.0.1:\(port)/hooks/00000000-0000-0000-0000-000000000001")!)
        request.httpMethod = "POST"; request.httpBody = body
        request.setValue("Bearer private-test-only", forHTTPHeaderField: "Authorization")
        let (_, response) = try await session.data(for: request)
        #expect((response as? HTTPURLResponse)?.statusCode == 202)
        let observed = await probe.bodies
        #expect(observed == [body])
        let settled = ContinuousClock.now + .seconds(8)
        while await server.activeConnectionCount != 0 {
            guard ContinuousClock.now < settled else { throw ScheduledTaskError.unavailable }
            try await Task.sleep(for: .milliseconds(5))
        }
        let partial = NWConnection(host: "127.0.0.1", port: NWEndpoint.Port(rawValue: port)!, using: .tcp)
        defer { partial.cancel() }
        partial.start(queue: DispatchQueue(label: "coincide.scheduler.test.partial"))
        partial.send(content: Data("POST /hooks/incomplete HTTP/1.1\r\n".utf8), completion: .idempotent)
        let deadline = ContinuousClock.now + .seconds(8)
        while await server.activeConnectionCount == 0 {
            guard ContinuousClock.now < deadline else { throw ScheduledTaskError.unavailable }
            try await Task.sleep(for: .milliseconds(5))
        }
        await server.shutdown()
        #expect(await server.activeConnectionCount == 0)
        partial.cancel()
        #expect(await probe.bodies.count == 1)
    } catch { await server.shutdown(); throw error }
}

private actor ScheduledAcceptedHTTPGate {
    let entered: AsyncStream<Void>
    private let signal: AsyncStream<Void>.Continuation
    private var continuation: CheckedContinuation<Void, Never>?
    private(set) var finished = false
    init() { let pair = AsyncStream<Void>.makeStream(bufferingPolicy: .bufferingNewest(1)); entered = pair.stream; signal = pair.continuation }
    func handle() async -> ScheduledTaskHTTPResponse {
        signal.yield(()); signal.finish()
        await withCheckedContinuation { continuation = $0 }
        finished = true; return .init(status: 202, outcome: "accepted")
    }
    func release() { continuation?.resume(); continuation = nil }
}
@Test(.timeLimit(.minutes(1)))
func scheduledTaskHTTPShutdownJoinsAcceptedHandlerWithoutDroppingItsOriginalAdmission() async throws {
    let gate = ScheduledAcceptedHTTPGate(), server = ScheduledTaskHTTPServer { _ in await gate.handle() }
    let port = try await server.start()
    let configuration = URLSessionConfiguration.ephemeral; configuration.connectionProxyDictionary = [:]
    configuration.urlCredentialStorage = nil; configuration.httpCookieStorage = nil
    let session = URLSession(configuration: configuration); defer { session.invalidateAndCancel() }
    var request = URLRequest(url: URL(string: "http://127.0.0.1:\(port)/hooks/00000000-0000-0000-0000-000000000001")!)
    request.httpMethod = "POST"; request.httpBody = Data("owned private request".utf8)
    let delivery = Task { try await session.data(for: request) }
    for await _ in gate.entered { break }
    let shutdown = Task { await server.shutdown() }
    #expect(await gate.finished == false)
    await gate.release()
    await shutdown.value
    _ = await delivery.result
    #expect(await gate.finished)
    #expect(await server.activeConnectionCount == 0)
}
