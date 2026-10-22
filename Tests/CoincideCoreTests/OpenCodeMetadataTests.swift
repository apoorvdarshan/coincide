import Foundation
import Testing
@testable import CoincideCore

@Test func openCodeVersionFollowsSemanticPrecedenceAndKeepsHTTPGenerationsExplicit() throws {
    let ordered = ["2.0.18-alpha", "2.0.18-alpha.1", "2.0.18-alpha.beta", "2.0.18-beta", "2.0.18-beta.2", "2.0.18-beta.11", "2.0.18-rc.1", "2.0.18"]
    let versions = try ordered.map(OpenCodeVersion.init)
    for (a, b) in zip(versions, versions.dropFirst()) { #expect(a < b) }
    #expect(try OpenCodeVersion("v2.1.2+local.007").description == "2.1.2+local.007")
    #expect(try OpenCodeVersion("2.0.18+build.1") == OpenCodeVersion("2.0.18+build.2"))
    #expect(try OpenCodeVersion("1.14.18").supportedGeneration == nil)
    #expect(try OpenCodeVersion("1.14.19").supportedGeneration == .v1)
    #expect(try OpenCodeVersion("2.0.17").supportedGeneration == nil)
    #expect(try OpenCodeVersion("2.0.18-rc.1").supportedGeneration == nil)
    #expect(try OpenCodeVersion("2.0.18").supportedGeneration == .v2)
    #expect(try OpenCodeVersion("3.0.0").supportedGeneration == nil)
    for invalid in ["", "opencode 2.1.2", "2.1", "2.1.2.3", "02.1.2", "2.01.2", "2.1.-1", "2.1.2-01", "2.1.2-a..b", "2.1.2+", "2.1.2\n", "99999999999999999999999.0.0"] {
        #expect(throws: OpenCodeProtocolError.invalidVersion) { try OpenCodeVersion(invalid) }
    }
}

@Test func openCodeCredentialsHaveOnlyRuntimeRedactedPresentationAndValidateHeaderInput() throws {
    let credential = try OpenCodeHTTPCredential(password: "native-fixture-秘密")
    #expect(credential.authorizationHeader == "Basic " + Data("opencode:native-fixture-秘密".utf8).base64EncodedString())
    #expect(!String(describing: credential).contains("native-fixture"))
    #expect(!String(reflecting: credential).contains("秘密"))
    #expect(!String(reflecting: credential).contains("Basic"))
    for (username, password) in [("", "value"), ("name:second", "value"), ("name", ""), ("name", "value\r\nHeader"), ("name\0", "value")] {
        #expect(throws: OpenCodeProtocolError.invalidCredential) { try OpenCodeHTTPCredential(username: username, password: password) }
    }
}

@Test func openCodeIdentityRejectsHTML200AndUsesOnlyTheActualV1HealthContract() async throws {
    let fixture = OpenCodeMetadataFixture { request, _ in
        if request.url?.path == "/api/info" { return .init(status: 200, headers: ["Content-Type": "text/html"], body: Data("<html>Wrong generation UI</html>".utf8)) }
        return OpenCodeMetadataFixture.json(["healthy": true, "version": "1.14.19"])
    }
    defer { fixture.remove() }
    let connection = try fixture.connection()
    let identity = try await connection.identify()
    #expect(identity.generation == .v1 && identity.processIdentifier == nil)
    #expect(identity.version.description == "1.14.19")
    #expect(fixture.requests.map { $0.url?.path } == ["/api/info", "/global/health"])
    await connection.close()
}

@Test(arguments: [401, 403, 503]) func openCodeIdentityAuthOrStartingResponseNeverFallsBackToAnotherGeneration(status: Int) async throws {
    let fixture = OpenCodeMetadataFixture { _, _ in .init(status: status, headers: [:], body: Data("private fixture detail".utf8)) }
    defer { fixture.remove() }
    let connection = try fixture.connection()
    await #expect(throws: status == 503 ? OpenCodeProtocolError.unavailable : .unauthorized) { try await connection.identify() }
    #expect(fixture.requests.count == 1)
    await connection.close()
}

@Test(arguments: ["missing", "fraction", "zero", "boolean", "overflow"])
func openCodeV2IdentityRequiresAnActualPositiveBoundedProcessID(kind: String) async throws {
    let fixture = OpenCodeMetadataFixture { _, _ in
        var value: [String: Any] = ["version": "2.1.2"]
        switch kind { case "fraction": value["pid"] = 12.5; case "zero": value["pid"] = 0
        case "boolean": value["pid"] = true; case "overflow": value["pid"] = Double(Int32.max) + 1; default: break }
        return OpenCodeMetadataFixture.json(value)
    }
    defer { fixture.remove() }
    let connection = try fixture.connection(generation: .v2)
    await #expect(throws: OpenCodeProtocolError.invalidIdentity) { try await connection.identify() }
    await connection.close()
}

@Test func openCodeIdentityRejectsTheWrongOwnedProcessAndUnknownOrMismatchedGeneration() async throws {
    for (version, pid, expected, owner, error) in [
        ("2.1.2", 100, OpenCodeGeneration.v2, Int32(101), OpenCodeProtocolError.invalidIdentity),
        ("3.0.0", 100, .v2, nil, .unsupportedVersion),
        ("2.0.17", 100, .v2, nil, .unsupportedVersion),
        ("1.14.19", 100, .v2, nil, .wrongGeneration)
    ] {
        let fixture = OpenCodeMetadataFixture { _, _ in OpenCodeMetadataFixture.json(["version": version, "pid": pid]) }
        defer { fixture.remove() }
        let connection = try fixture.connection(generation: expected, owner: owner)
        await #expect(throws: error) { try await connection.identify() }
        #expect(fixture.requests.count == 1)
        await connection.close()
    }
}

@Test func openCodeV2MetadataKeepsWireSelectionsVariantsDirectoryAndAgentIdentityWithoutRawPrivateFields() async throws {
    let directory = "/tmp/native project/漢字 ?a&b=1+#folder"
    let fixture = OpenCodeMetadataFixture { request, _ in
        switch request.url?.path {
        case "/api/info": OpenCodeMetadataFixture.info()
        case "/api/model": OpenCodeMetadataFixture.located([OpenCodeMetadataFixture.model()], directory: directory)
        case "/api/model/default": OpenCodeMetadataFixture.located(OpenCodeMetadataFixture.model(), directory: directory)
        case "/api/agent": OpenCodeMetadataFixture.located([["id": "agent-wire-id", "name": "Build Display", "mode": "primary", "hidden": false,
                                                            "request": ["headers": ["Authorization": "fixture-private-header" ]], "system": "fixture-private-system"]], directory: directory)
        default: .init(status: 404, headers: [:], body: Data())
        }
    }
    defer { fixture.remove() }
    let connection = try fixture.connection(generation: .v2, owner: 500)
    let snapshot = try await connection.inventory(directory: URL(fileURLWithPath: directory))
    #expect(snapshot.models.first?.selection == .init(providerID: "upstream-provider", id: "advertised-wire-id"))
    #expect(snapshot.models.first?.variants == ["future-deep", "fast"])
    #expect(snapshot.models.first?.input == ["text", "image"])
    #expect(snapshot.defaults == [.init(providerID: "upstream-provider", id: "advertised-wire-id")])
    #expect(snapshot.agents.first?.id == "agent-wire-id" && snapshot.agents.first?.name == "Build Display")
    #expect(!String(reflecting: snapshot).contains("fixture-private"))
    let scoped = fixture.requests.filter { $0.url?.path != "/api/info" }
    #expect(scoped.count == 3)
    #expect(scoped.allSatisfy { URLComponents(url: $0.url!, resolvingAgainstBaseURL: false)?.queryItems == [.init(name: "location[directory]", value: directory)] })
    #expect(fixture.requests.allSatisfy { $0.httpMethod == "GET" })
    await connection.close()
}

@Test func openCodeV1MetadataUsesItsOwnCatalogShapeConnectedProvidersAndNameBasedAgents() async throws {
    let directory = "/tmp/native-v1"
    let fixture = OpenCodeMetadataFixture { request, _ in
        switch request.url?.path {
        case "/global/health": OpenCodeMetadataFixture.json(["healthy": true, "version": "1.14.19"])
        case "/provider": OpenCodeMetadataFixture.json([
            "all": [["id": "connected-provider", "models": ["wire-key": ["id": "wire/id", "name": "Connected Model", "variants": ["future-effort": [:]], "toolcall": true]]],
                    ["id": "disconnected-provider", "models": ["other": ["id": "other", "name": "Unavailable"]]]],
            "connected": ["connected-provider"], "default": ["connected-provider": "wire/id", "disconnected-provider": "other"]
        ])
        case "/agent": OpenCodeMetadataFixture.json([["name": "build", "mode": "primary", "prompt": "fixture-private-system"]])
        default: .init(status: 404, headers: [:], body: Data())
        }
    }
    defer { fixture.remove() }
    let connection = try fixture.connection(generation: .v1)
    let snapshot = try await connection.inventory(directory: URL(fileURLWithPath: directory))
    #expect(snapshot.models.count == 1 && snapshot.models.first?.selection.id == "wire/id")
    #expect(snapshot.models.first?.variants == ["future-effort"])
    #expect(snapshot.defaults == [.init(providerID: "connected-provider", id: "wire/id")])
    #expect(snapshot.agents.first?.id == "build" && snapshot.agents.first?.hidden == false)
    #expect(!String(reflecting: snapshot).contains("fixture-private"))
    #expect(fixture.requests.filter { $0.url?.path == "/provider" || $0.url?.path == "/agent" }.allSatisfy {
        URLComponents(url: $0.url!, resolvingAgainstBaseURL: false)?.queryItems == [.init(name: "directory", value: directory)]
    })
    await connection.close()
}

@Test func openCodeMetadataDoesNotTreatAStillSettlingEmptyCatalogAsUnsupported() async throws {
    let directory = "/tmp/empty-catalog"
    let fixture = OpenCodeMetadataFixture { request, _ in
        request.url?.path == "/api/info" ? OpenCodeMetadataFixture.info() :
            OpenCodeMetadataFixture.located(request.url?.path == "/api/model/default" ? NSNull() : [], directory: directory)
    }
    defer { fixture.remove() }
    let connection = try fixture.connection(generation: .v2)
    let snapshot = try await connection.inventory(directory: URL(fileURLWithPath: directory))
    #expect(snapshot.models.isEmpty && snapshot.agents.isEmpty && snapshot.defaults.isEmpty)
    await connection.close()
}

@Test func openCodeMetadataRejectsCrossDirectoryResponsesAndAServerReplacementDuringTheRead() async throws {
    for wrongDirectory in [false, true] {
        let fixture = OpenCodeMetadataFixture { request, ordinal in
            if request.url?.path == "/api/info" { return OpenCodeMetadataFixture.info(pid: ordinal == 1 || wrongDirectory ? 500 : 501) }
            return OpenCodeMetadataFixture.located(request.url?.path == "/api/model/default" ? NSNull() : [], directory: wrongDirectory ? "/tmp/other" : "/tmp/expected")
        }
        defer { fixture.remove() }
        let connection = try fixture.connection(generation: .v2)
        await #expect(throws: wrongDirectory ? OpenCodeProtocolError.wrongDirectory : .invalidIdentity) {
            try await connection.inventory(directory: URL(fileURLWithPath: "/tmp/expected"))
        }
        await connection.close()
    }
}

@Test func openCodeMetadataRejectsFileAuthoritiesAndDirectoryAliasesBeforeMisroutingAWorkspace() async throws {
    let fixture = OpenCodeMetadataFixture { _, _ in OpenCodeMetadataFixture.info() }
    defer { fixture.remove() }
    let connection = try fixture.connection(generation: .v2)
    for source in ["file://other-host/tmp/project", "file://user@localhost/tmp/project", "file:///tmp/project?other=value", "file:///tmp/project#other"] {
        let directory = try #require(URL(string: source))
        await #expect(throws: OpenCodeProtocolError.wrongDirectory) { try await connection.inventory(directory: directory) }
    }
    #expect(fixture.requests.isEmpty)
    let aliased: JSONValue = .object(["location": .object(["directory": .string("/tmp/link/../expected")]), "data": .array([])])
    #expect(throws: OpenCodeProtocolError.wrongDirectory) { try OpenCodeCatalog.v2Models(aliased, directory: "/tmp/expected") }
    await connection.close()
}

@Test func openCodeCatalogRejectsAmbiguousSelectionsControlTextAndMalformedAgentModes() throws {
    let directory = "/tmp/catalog"
    func json(_ value: Any) throws -> JSONValue { try JSONDecoder().decode(JSONValue.self, from: JSONSerialization.data(withJSONObject: value)) }
    for models in [[OpenCodeMetadataFixture.model(), OpenCodeMetadataFixture.model()],
                   [OpenCodeMetadataFixture.model(name: "name\0suffix")],
                   [OpenCodeMetadataFixture.model(variants: ["duplicate", "duplicate"])]] {
        #expect(throws: OpenCodeProtocolError.invalidCatalog) { try OpenCodeCatalog.v2Models(json(["location": ["directory": directory], "data": models]), directory: directory) }
    }
    #expect(throws: OpenCodeProtocolError.invalidCatalog) {
        try OpenCodeCatalog.v2Agents(json(["location": ["directory": directory], "data": [["id": "agent", "name": "Agent", "mode": "invented-mode", "hidden": false]]]), directory: directory)
    }
    #expect(throws: OpenCodeProtocolError.invalidCatalog) {
        try OpenCodeCatalog.v2Models(.object(["location": .object(["directory": .string(directory)]), "data": .array(Array(repeating: .null, count: OpenCodeCatalog.maximumModels + 1))]), directory: directory)
    }
}

@Test func openCodeMetadataCloseCancelsAnOwnedReadAndRejectsNewReadsWithoutReplay() async throws {
    let fixture = OpenCodeMetadataFixture { _, _ in nil }
    defer { fixture.remove() }
    let connection = try fixture.connection(generation: .v2)
    let read = Task { try await connection.identify() }
    for _ in 0..<300 {
        if !fixture.requests.isEmpty { break }
        try await Task.sleep(for: .milliseconds(10))
    }
    #expect(fixture.requests.count == 1)
    await connection.close()
    await #expect(throws: CancellationError.self) { try await read.value }
    await #expect(throws: OpenCodeProtocolError.closed) { try await connection.identify() }
    #expect(fixture.requests.count == 1)
}

@Test func openCodeMetadataCloseKeepsASharedEventRequestAndOtherHTTPReadsAlive() async throws {
    let fixture = OpenCodeMetadataFixture { request, _ in
        switch request.url?.path {
        case "/api/event": .init(status: 200, headers: ["Content-Type": "text/event-stream"], body: Data(": heartbeat\n".utf8))
        case "/api/info": nil
        default: OpenCodeMetadataFixture.info()
        }
    }
    defer { fixture.remove() }
    let client = try fixture.client()
    let connection = OpenCodeMetadataConnection(client: client, expectedGeneration: .v2)
    let events = try await client.openEvents(path: ["api", "event"])
    let metadata = Task { try await connection.identify() }
    for _ in 0..<300 {
        if fixture.requests.contains(where: { $0.url?.path == "/api/info" }) { break }
        try await Task.sleep(for: .milliseconds(10))
    }
    #expect(fixture.requests.contains { $0.url?.path == "/api/info" })
    await connection.close()
    await #expect(throws: CancellationError.self) { try await metadata.value }
    #expect(!fixture.stoppedPaths.contains("/api/event"))
    #expect(try await client.request(path: ["other-read"]).status == 200)
    await events.close(); await client.close()
    #expect(fixture.stoppedPaths.contains("/api/event"))
}

private final class OpenCodeMetadataFixture: @unchecked Sendable {
    private static let registryLock = NSLock()
    nonisolated(unsafe) private static var registry: [String: OpenCodeMetadataFixture] = [:]
    private let lock = NSLock()
    private var recorded: [URLRequest] = []
    private var stopped: [String] = []
    let handler: @Sendable (URLRequest, Int) -> OpenCodeHTTPResponse?
    let host = "metadata-\(UUID().uuidString.lowercased()).invalid"
    init(_ handler: @escaping @Sendable (URLRequest, Int) -> OpenCodeHTTPResponse?) {
        self.handler = handler; Self.registryLock.withLock { Self.registry[host] = self }
    }
    var requests: [URLRequest] { lock.withLock { recorded } }
    var stoppedPaths: [String] { lock.withLock { stopped } }
    func didStop(_ request: URLRequest) { lock.withLock { stopped.append(request.url?.path ?? "") } }
    func remove() { _ = Self.registryLock.withLock { Self.registry.removeValue(forKey: host) } }
    static func find(_ host: String?) -> OpenCodeMetadataFixture? { registryLock.withLock { host.flatMap { registry[$0] } } }
    func respond(_ request: URLRequest) -> OpenCodeHTTPResponse? {
        let count = lock.withLock { recorded.append(request); return recorded.count }
        return handler(request, count)
    }
    func connection(generation: OpenCodeGeneration? = nil, owner: Int32? = nil) throws -> OpenCodeMetadataConnection {
        .init(client: try client(), expectedGeneration: generation, ownedProcessIdentifier: owner)
    }
    func client() throws -> OpenCodeHTTPClient {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [OpenCodeMetadataProtocol.self]
        return try OpenCodeHTTPClient(origin: URL(string: "https://\(host)")!, configuration: configuration)
    }
    static func json(_ value: Any) -> OpenCodeHTTPResponse {
        .init(status: 200, headers: ["Content-Type": "application/json; charset=utf-8"], body: try! JSONSerialization.data(withJSONObject: value))
    }
    static func info(pid: Int = 500) -> OpenCodeHTTPResponse { json(["version": "2.1.2", "pid": pid, "paths": ["tmp": "/tmp/opencode-fixture"]]) }
    static func located(_ value: Any, directory: String) -> OpenCodeHTTPResponse { json(["location": ["directory": directory], "data": value]) }
    static func model(name: String = "Advertised Model", variants: [String] = ["future-deep", "fast"]) -> [String: Any] {
        ["id": "advertised-wire-id", "providerID": "upstream-provider", "modelID": "ignored-upstream-internal-id", "name": name,
         "enabled": true, "capabilities": ["tools": true, "input": ["text", "image"], "output": ["text"], "temperature": true],
         "variants": variants.map { ["id": $0, "headers": ["Authorization": "fixture-private-header"]] }, "headers": ["Authorization": "fixture-private-header"]]
    }
}

private final class OpenCodeMetadataProtocol: URLProtocol, @unchecked Sendable {
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        guard let fixture = OpenCodeMetadataFixture.find(request.url?.host) else { client?.urlProtocol(self, didFailWithError: OpenCodeProtocolError.closed); return }
        guard let reply = fixture.respond(request), let response = HTTPURLResponse(url: request.url!, statusCode: reply.status, httpVersion: "HTTP/1.1", headerFields: reply.headers) else { return }
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: reply.body)
        if reply.headers["Content-Type"] != "text/event-stream" { client?.urlProtocolDidFinishLoading(self) }
    }
    override func stopLoading() { OpenCodeMetadataFixture.find(request.url?.host)?.didStop(request) }
}
