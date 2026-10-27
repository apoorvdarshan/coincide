import Foundation
import Testing

@testable import CoincideKit

@MainActor
struct ACPConnectionTests {
    private final class Wire {
        var lines: [JSONValue] = []
    }

    private func makeConnection() -> (ACPConnection, Wire) {
        let wire = Wire()
        let connection = ACPConnection(write: { wire.lines.append(JSONValue.parse($0) ?? .null) })
        return (connection, wire)
    }

    @Test func requestsAreNumberedAndMatchedToResponses() async throws {
        let (connection, wire) = makeConnection()
        var first: Result<JSONValue, Error>?
        var second: Result<JSONValue, Error>?
        connection.send("initialize", params: ["protocolVersion": 1]) { first = $0 }
        connection.send("session/new", params: ["cwd": "/tmp"]) { second = $0 }

        #expect(wire.lines.count == 2)
        #expect(wire.lines[0]["jsonrpc"] == "2.0")
        #expect(wire.lines[0]["id"] == 1)
        #expect(wire.lines[0]["method"] == "initialize")
        #expect(wire.lines[1]["id"] == 2)

        // Responses can arrive in any order.
        connection.receive(#"{"jsonrpc":"2.0","id":2,"result":{"sessionId":"abc"}}"#)
        connection.receive(#"{"jsonrpc":"2.0","id":1,"result":{"protocolVersion":1}}"#)
        #expect(try second?.get()["sessionId"] == "abc")
        #expect(try first?.get()["protocolVersion"] == 1)
        #expect(!connection.hasPendingRequests)
    }

    @Test func errorResponsesBecomeACPErrors() async {
        let (connection, _) = makeConnection()
        var received: Error?
        connection.send("session/new", params: [:]) { if case .failure(let error) = $0 { received = error } }
        connection.receive(
            #"{"jsonrpc":"2.0","id":1,"error":{"code":-32000,"message":"Authentication required","data":{"details":"run grok login"}}}"#)
        let error = try? #require(received as? ACPError)
        #expect(error?.code == ACPError.authRequired)
        #expect(error?.localizedDescription == "Authentication required: run grok login")
    }

    @Test func malformedErrorsStillFail() {
        let (connection, _) = makeConnection()
        var received: Result<JSONValue, Error>?
        connection.send("session/prompt", params: [:]) { received = $0 }
        connection.receive(#"{"jsonrpc":"2.0","id":1,"error":{"message":"no code"}}"#)
        guard case .failure(let error)? = received else {
            Issue.record("Expected a failure, got \(String(describing: received))")
            return
        }
        #expect((error as? ACPError)?.code == ACPError.internalError)
    }

    @Test func hugeNumbersNeverTrap() {
        #expect(JSONValue.number(1e20).acpInt == nil)
        #expect(JSONValue.number(2.5).acpInt == nil)
        #expect(JSONValue.number(42).acpInt == 42)
        let (connection, wire) = makeConnection()
        var received: Result<JSONValue, Error>?
        connection.send("initialize", params: [:]) { received = $0 }
        connection.receive(#"{"jsonrpc":"2.0","id":1e20,"result":{}}"#)
        #expect(received == nil)
        // A result that cannot be encoded still answers the request.
        let request = ACPConnection.IncomingRequest(id: 9, method: "x", params: .null)
        connection.respond(to: request, result: ["value": .number(.infinity)])
        #expect(wire.lines.last?.at("error.code") == -32603)
    }

    @Test func asyncRequestResumesWithResult() async throws {
        let (connection, wire) = makeConnection()
        async let result = connection.request("session/set_mode", params: ["modeId": "plan"])
        await acpWaitUntil { wire.lines.count == 1 }
        connection.receive(#"{"jsonrpc":"2.0","id":1,"result":{}}"#)
        #expect(try await result == [:])
    }

    @Test func notificationsAndRequestsFromTheAgentAreDispatched() {
        let (connection, wire) = makeConnection()
        var notified: [String] = []
        var requested: [ACPConnection.IncomingRequest] = []
        connection.onNotification = { method, _ in notified.append(method) }
        connection.onRequest = { requested.append($0) }

        connection.receive(#"{"jsonrpc":"2.0","method":"session/update","params":{"sessionId":"s"}}"#)
        connection.receive(#"{"jsonrpc":"2.0","id":"req-7","method":"fs/read_text_file","params":{"path":"/a"}}"#)
        #expect(notified == ["session/update"])
        #expect(requested.first?.id == "req-7")
        #expect(requested.first?.params["path"] == "/a")

        // String ids are echoed back unchanged.
        connection.respond(to: requested[0], result: ["content": "hi"])
        connection.respond(to: requested[0], error: .methodNotFound("x"))
        #expect(wire.lines[0]["id"] == "req-7")
        #expect(wire.lines[0].at("result.content") == "hi")
        #expect(wire.lines[1].at("error.code") == -32601)
    }

    @Test func nonJSONLinesAreReportedSeparately() {
        let (connection, _) = makeConnection()
        var unparsed: [String] = []
        connection.onUnparsedLine = { unparsed.append($0) }
        connection.receive("Open the following link to authenticate the ACP server: https://accounts.google.com/x")
        connection.receive("   ")
        connection.receive("{not json")
        #expect(unparsed == ["Open the following link to authenticate the ACP server: https://accounts.google.com/x", "{not json"])
    }

    @Test func closingFailsPendingAndLaterRequests() {
        let (connection, wire) = makeConnection()
        var failures = 0
        connection.send("session/prompt", params: [:]) { if case .failure = $0 { failures += 1 } }
        connection.close(with: AgentError.notRunning)
        connection.send("session/prompt", params: [:]) { if case .failure = $0 { failures += 1 } }
        connection.notify("session/cancel", params: [:])
        #expect(failures == 2)
        #expect(wire.lines.count == 1)
        #expect(connection.isClosed)
    }

    @Test func requestsTimeOut() async {
        let (connection, _) = makeConnection()
        var outcome: Error?
        connection.send("initialize", params: [:], timeout: 0.05) { if case .failure(let error) = $0 { outcome = error } }
        await acpWaitUntil { outcome != nil }
        #expect(outcome?.localizedDescription.contains("initialize") == true)
        // A late response is ignored.
        connection.receive(#"{"jsonrpc":"2.0","id":1,"result":{}}"#)
    }
}
