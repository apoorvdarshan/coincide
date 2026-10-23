import Foundation
import Testing
@testable import CoincideCore

private func appMCPRedactionConnection() throws -> AppMCPConnection {
    try .init(endpoint: URL(string: "http://127.0.0.1:12345/mcp")!,
        authorizationHeader: "Bearer " + String(repeating: "r", count: 43), scopeID: UUID())
}

@Test(.timeLimit(.minutes(1)), arguments: [false, true])
func appMCPRedactionCoversInboundRepliesErrorsKeysNotificationsRequestsAndCallbacksWithoutChangingOutgoingHeaders(claude: Bool) async throws {
    let file = try #require(Bundle.module.url(forResource: "app_mcp_redaction", withExtension: "py", subdirectory: "Fixtures"))
    let rpc = try JSONRPCConnection(executable: URL(fileURLWithPath: "/usr/bin/python3"), arguments: [file.path, claude ? "claude" : "codex"], dialect: claude ? .claudeControl : .jsonRPC)
    let connection = try appMCPRedactionConnection()
    try await rpc.configureAppMCPRedaction(connection)
    let observed = AppMCPRedactionObserved()
    let reader = Task {
        for await event in rpc.events {
            switch event {
            case .request(let id, let method, let params): await observed.add(.object(["id": id, "method": .string(method), "params": params]))
            case .notification(let method, let params): await observed.add(.object(["method": .string(method), "params": params]))
            case .disconnected(let message): await observed.add(.string(message))
            case .callback(let callback): await callback()
            case .barrier(let finish): finish()
            }
        }
    }
    do {
        let result = try await rpc.request("echo", params: .object(["header": .string(connection.authorizationHeader)]), onResponse: { value in
            if case .success(let response) = value { await observed.add(response) }
        })
        #expect(result["header"] == .string("[private app tool credential]"))
        #expect(result["nested"].array?.first == .string("[private app tool credential]"))
        #expect(result["nested"].array?.last?["[private app tool credential]"] == .string("literal safe text"))
        do {
            _ = try await rpc.request("error", params: .object(["header": .string(connection.authorizationHeader)]))
            Issue.record("Expected the synthetic remote error.")
        } catch {
            #expect(!error.localizedDescription.contains(connection.authorizationHeader))
            #expect(!error.localizedDescription.contains(String(connection.authorizationHeader.dropFirst(7))))
            if let remote = error as? JSONRPCRemoteError {
                #expect(remote.code == -32000 && remote.data["bare"] == .string("[private app tool credential]"))
            }
        }
        await rpc.flushEvents()
        await #expect(throws: (any Error).self) { try await rpc.configureAppMCPRedaction(connection) }
        await rpc.close(); await reader.value
        let values = await observed.values
        #expect(values.count == 4)
        let rendered = JSONValue.array(values).pretty
        #expect(!rendered.contains(connection.authorizationHeader) && !rendered.contains(String(connection.authorizationHeader.dropFirst(7))))
    } catch { await rpc.close(); await reader.value; throw error }
}

@Test func appMCPRedactionRejectsReplacementAndBoundsNestedInspectionWithoutRawFallback() async throws {
    let connection = try appMCPRedactionConnection()
    var nested = JSONValue.string(connection.authorizationHeader)
    for _ in 0..<200 { nested = .array([nested]) }
    let result = connection.redacting(.object(["deep": nested, "safe": .string("unchanged")]))
    #expect(result["safe"] == .string("unchanged"))
    #expect(!result.pretty.contains(String(connection.authorizationHeader.dropFirst(7))))
    let rpc = try fixtureConnection("hang")
    do {
        try await rpc.configureAppMCPRedaction(connection)
        try await rpc.configureAppMCPRedaction(connection)
        await #expect(throws: (any Error).self) { try await rpc.configureAppMCPRedaction(appMCPRedactionConnection()) }
        await rpc.close()
    } catch { await rpc.close(); throw error }
}

@Test func appMCPRedactionDoesNotChangeUnconfiguredProviderReplies() async throws {
    let rpc = try fixtureConnection("reverse"), connection = try appMCPRedactionConnection()
    do {
        async let first = rpc.request("echo", params: .string(connection.authorizationHeader))
        async let second = rpc.request("echo", params: .string("ordinary reply"))
        let replies = try await [first, second]
        #expect(replies == [.string(connection.authorizationHeader), .string("ordinary reply")])
        await rpc.close()
    } catch { await rpc.close(); throw error }
}

private actor AppMCPRedactionObserved {
    private(set) var values: [JSONValue] = []
    func add(_ value: JSONValue) { values.append(value) }
}
