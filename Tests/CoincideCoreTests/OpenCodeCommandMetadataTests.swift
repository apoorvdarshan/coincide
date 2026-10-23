import Foundation
import Testing
@testable import CoincideCore

/// The production URLSession/delegate transport handles these private fake
/// HTTPS origins. Every request is intercepted; no socket or provider starts.
private final class CommandMetadataFixture: @unchecked Sendable {
    private static let registryLock = NSLock()
    nonisolated(unsafe) private static var registry: [String: CommandMetadataFixture] = [:]
    private let lock = NSLock()
    private var recorded: [URLRequest] = []
    private var stopped: [String] = []
    let host = "command-metadata-" + UUID().uuidString.lowercased() + ".invalid"
    let handler: @Sendable (URLRequest, Int) -> OpenCodeHTTPResponse?
    init(_ handler: @escaping @Sendable (URLRequest, Int) -> OpenCodeHTTPResponse?) {
        self.handler = handler; Self.registryLock.withLock { Self.registry[host] = self }
    }
    static func find(_ host: String?) -> CommandMetadataFixture? { registryLock.withLock { host.flatMap { registry[$0] } } }
    func remove() { _ = Self.registryLock.withLock { Self.registry.removeValue(forKey: host) } }
    var requests: [URLRequest] { lock.withLock { recorded } }
    var stoppedPaths: [String] { lock.withLock { stopped } }
    func reply(_ request: URLRequest) -> OpenCodeHTTPResponse? {
        let count = lock.withLock { recorded.append(request); return recorded.count }
        return handler(request, count)
    }
    func didStop(_ request: URLRequest) { lock.withLock { stopped.append(request.url?.path ?? "") } }
    func client() throws -> OpenCodeHTTPClient {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [CommandMetadataProtocol.self]
        return try OpenCodeHTTPClient(origin: #require(URL(string: "https://" + host)), configuration: configuration)
    }
    static func json(_ value: Any) -> OpenCodeHTTPResponse {
        .init(status: 200, headers: ["Content-Type": "application/json; charset=utf-8"], body: try! JSONSerialization.data(withJSONObject: value))
    }
    static func info(pid: Int = 500) -> OpenCodeHTTPResponse { json(["version": "2.1.2", "pid": pid]) }
    static func located(_ value: Any, directory: String) -> OpenCodeHTTPResponse { json(["location": ["directory": directory], "data": value]) }
    static var commands: [[String: Any]] {
        [["name": "inspect", "description": "Inspect changes", "hints": ["Optional focus"], "template": "private-template-canary"]]
    }
    static var skills: [[String: Any]] {
        [["id": "native-review-id", "name": "Friendly Review 工作", "path": "native/SKILL.md", "location": "legacy/SKILL.md",
          "content": "private-skill-body-canary", "headers": ["Authorization": "private-header-canary"]]]
    }
}
private final class CommandMetadataProtocol: URLProtocol, @unchecked Sendable {
    private let lock = NSLock()
    private var owner: CommandMetadataFixture?
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        guard let owner = CommandMetadataFixture.find(request.url?.host) else {
            client?.urlProtocol(self, didFailWithError: OpenCodeProtocolError.closed); return
        }
        lock.withLock { self.owner = owner }
        guard let reply = owner.reply(request), let url = request.url,
              let response = HTTPURLResponse(url: url, statusCode: reply.status, httpVersion: "HTTP/1.1", headerFields: reply.headers) else { return }
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: reply.body)
        if reply.headers["Content-Type"] != "text/event-stream" { client?.urlProtocolDidFinishLoading(self) }
    }
    override func stopLoading() {
        let owner = lock.withLock { let result = self.owner; self.owner = nil; return result }
        owner?.didStop(request)
    }
}
private func commandMetadataEventually(_ predicate: () -> Bool) async throws {
    let deadline = ContinuousClock.now + .seconds(3)
    while !predicate() {
        guard ContinuousClock.now < deadline else { throw CoincideError("The native command metadata request did not reach its owned boundary.") }
        try await Task.sleep(for: .milliseconds(5))
    }
}

@Test(.timeLimit(.minutes(1)), arguments: [OpenCodeGeneration.v1, .v2])
func openCodeCommandMetadataUsesExactGenerationLocationAndWireIDsWithoutCreatingOrAttachingSession(generation: OpenCodeGeneration) async throws {
    let directory = "/private-fixture/工作 ?a&b=1+#folder"
    let fixture = CommandMetadataFixture { request, _ in
        switch request.url?.path {
        case "/api/info": CommandMetadataFixture.info()
        case "/global/health": CommandMetadataFixture.json(["healthy": true, "version": "1.14.19"])
        case "/api/command": CommandMetadataFixture.located(CommandMetadataFixture.commands, directory: directory)
        case "/api/skill": CommandMetadataFixture.located(CommandMetadataFixture.skills, directory: directory)
        case "/command": CommandMetadataFixture.json(CommandMetadataFixture.commands)
        case "/skill": CommandMetadataFixture.json(CommandMetadataFixture.skills)
        default: .init(status: 404, headers: [:], body: Data())
        }
    }
    defer { fixture.remove() }
    let client = try fixture.client(), connection = OpenCodeMetadataConnection(client: client, expectedGeneration: generation,
        ownedProcessIdentifier: generation == .v2 ? 500 : nil)
    do {
        let inventory = try await connection.commands(directory: URL(fileURLWithPath: directory))
        #expect(inventory.cwd == directory && !inventory.isPartial)
        #expect(inventory.commands.map(\.name) == ["compact", "inspect"] && inventory.commands.last?.hints == ["Optional focus"])
        let skill = try #require(inventory.skills.first)
        if generation == .v2 {
            #expect(skill.name == "native-review-id" && skill.nativeID == "native-review-id" && skill.displayName == "Friendly Review 工作")
        } else { #expect(skill.name == "Friendly Review 工作" && skill.nativeID == "Friendly Review 工作") }
        for canary in ["private-template-canary", "private-skill-body-canary", "private-header-canary"] {
            #expect(!String(reflecting: inventory).contains(canary))
        }
        let prefix = generation == .v2 ? "/api" : ""
        let identity = generation == .v2 ? "/api/info" : "/global/health"
        #expect(fixture.requests.count == 4 && fixture.requests.filter { $0.url?.path == identity }.count == 2)
        let scoped = fixture.requests.filter { $0.url?.path == prefix + "/command" || $0.url?.path == prefix + "/skill" }
        #expect(scoped.count == 2)
        for request in scoped {
            let url = try #require(request.url), query = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems
            #expect(query == [.init(name: generation == .v2 ? "location[directory]" : "directory", value: directory)])
        }
        #expect(fixture.requests.allSatisfy { $0.httpMethod == "GET" && $0.httpBody == nil })
        await connection.close(); await client.close()
    } catch { await connection.close(); await client.close(); throw error }
}

@Test(.timeLimit(.minutes(1)), arguments: ["partial404", "partial503", "unsupported", "unavailable", "unauthorized", "malformed", "wrongLocation", "changedPID", "wrongOwnedPID", "oversized"])
func openCodeCommandMetadataDistinguishesPartialUnsupportedAndUnsafeIdentityOrPayload(kind: String) async throws {
    let directory = "/private-fixture/metadata"
    let fixture = CommandMetadataFixture { request, count in
        switch request.url?.path {
        case "/api/info": return CommandMetadataFixture.info(pid: kind == "wrongOwnedPID" || kind == "changedPID" && count > 1 ? 501 : 500)
        case "/api/command":
            switch kind {
            case "unsupported": return .init(status: 404, headers: [:], body: Data())
            case "unavailable": return .init(status: 503, headers: [:], body: Data())
            case "unauthorized": return .init(status: 401, headers: [:], body: Data("private-native-error-canary".utf8))
            case "malformed": return .init(status: 200, headers: ["Content-Type": "application/json"], body: Data("not-json private-native-error-canary".utf8))
            case "oversized": return .init(status: 200, headers: ["Content-Type": "application/json"], body: Data(repeating: 65, count: 4_194_305))
            default: return CommandMetadataFixture.located(CommandMetadataFixture.commands, directory: directory)
            }
        case "/api/skill":
            switch kind {
            case "unsupported", "partial404": return .init(status: 405, headers: [:], body: Data())
            case "unavailable", "partial503": return .init(status: 503, headers: [:], body: Data())
            default: return CommandMetadataFixture.located(CommandMetadataFixture.skills, directory: kind == "wrongLocation" ? "/foreign/workspace" : directory)
            }
        default: return .init(status: 404, headers: [:], body: Data())
        }
    }
    defer { fixture.remove() }
    let client = try fixture.client(), connection = OpenCodeMetadataConnection(client: client, expectedGeneration: .v2, ownedProcessIdentifier: 500)
    do {
        let inventory = try await connection.commands(directory: URL(fileURLWithPath: directory))
        #expect(kind == "partial404" || kind == "partial503")
        #expect(inventory.isPartial && inventory.commands.map(\.name) == ["compact", "inspect"] && inventory.skills.isEmpty)
        #expect(inventory.problems.count == 1 && inventory.problems.first?.component == .skills)
    } catch {
        switch kind {
        case "unsupported": #expect(error as? ProviderCommandError == ProviderCommandError(.unsupported))
        case "unavailable": #expect(error as? ProviderCommandError == ProviderCommandError(.unavailable))
        case "unauthorized": #expect(error as? OpenCodeProtocolError == .unauthorized)
        case "malformed": #expect(error as? OpenCodeProtocolError == .invalidCatalog)
        case "wrongLocation": #expect(error as? OpenCodeProtocolError == .wrongDirectory)
        case "changedPID", "wrongOwnedPID": #expect(error as? OpenCodeProtocolError == .invalidIdentity)
        case "oversized": #expect(error as? OpenCodeHTTPError == .responseBodyTooLarge)
        default: Issue.record("A healthy partial metadata read unexpectedly failed.")
        }
        #expect(!error.localizedDescription.contains("private-native-error-canary"))
    }
    if kind == "wrongOwnedPID" { #expect(fixture.requests.count == 1) }
    #expect(fixture.requests.allSatisfy { $0.httpMethod == "GET" })
    await connection.close(); await client.close()
}

@Test(.timeLimit(.minutes(1)), arguments: [false, true])
func openCodeCommandMetadataCloseAndCallerCancellationJoinOnlyTheirOwnHeldRequests(cancelCaller: Bool) async throws {
    let fixture = CommandMetadataFixture { request, _ in
        switch request.url?.path {
        case "/api/command", "/api/skill": nil
        case "/api/event": .init(status: 200, headers: ["Content-Type": "text/event-stream"], body: Data())
        default: CommandMetadataFixture.info()
        }
    }
    defer { fixture.remove() }
    let client = try fixture.client(), connection = OpenCodeMetadataConnection(client: client, expectedGeneration: .v2, ownedProcessIdentifier: 500)
    let events = try await client.openEvents(path: ["api", "event"])
    let read = Task { try await connection.commands(directory: URL(fileURLWithPath: "/private-fixture/metadata")) }
    do {
        try await commandMetadataEventually { fixture.requests.contains { $0.url?.path == "/api/command" } && fixture.requests.contains { $0.url?.path == "/api/skill" } }
        if cancelCaller { read.cancel() }
        await connection.close()
        let result = await read.result
        switch result { case .success: Issue.record("Closing the metadata reader returned a held inventory."); case .failure: break }
        try await commandMetadataEventually { fixture.stoppedPaths.contains("/api/command") && fixture.stoppedPaths.contains("/api/skill") }
        #expect(!fixture.stoppedPaths.contains("/api/event"))
        #expect(try await client.request(path: ["independent-read"]).status == 200)
        await events.close(); await client.close()
        try await commandMetadataEventually { fixture.stoppedPaths.contains("/api/event") }
    } catch {
        read.cancel(); await connection.close(); _ = await read.result
        await events.close(); await client.close(); throw error
    }
}
