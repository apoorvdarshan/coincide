import Foundation
import Testing

@testable import CoincideKit

struct ComputerUseRequestTests {
    @Test func nativeCallsAndLifecycleHaveSmallSeparateShapes() throws {
        #expect(try ComputerUseRequest(json: ["action": "tools"]) == .tools)
        #expect(try ComputerUseRequest(json: ["action": "status"]) == .status)
        #expect(try ComputerUseRequest(json: ["action": "release"]) == .release)
        #expect(try ComputerUseRequest(json: ["action": "call", "name": "list_windows", "arguments": ["app": "Calculator"]])
            == .call(name: "list_windows", arguments: ["app": "Calculator"]))
        for request: JSONValue in [
            [:], ["action": "start_session"], ["action": "status", "session": "other"],
            ["action": "call", "name": "click"], ["action": "call", "name": "click", "arguments": []],
            ["action": "call", "name": "click", "arguments": [:], "extra": true],
        ] { #expect(throws: ComputerUseError.self) { try ComputerUseRequest(json: request) } }
    }

    @Test func nativeCeilingRejectsBrowserScriptsSessionsAndControlPlaneOverrides() throws {
        for name in ["browser_click", "browser_prepare", "browser_eval", "get_browser_state", "run_script", "start_session",
            "end_session", "set_config", "request_permissions", "set_agent_cursor_theme", "get_guide", "history_query", "stop", "update"]
        {
            #expect(!ComputerUseToolPolicy.allows(name))
            #expect(throws: ComputerUseError.self) { try ComputerUseToolPolicy.validate(name: name, arguments: [:]) }
        }
        for key in ["session", "_session_id", "_meta", "permission_mode", "capability_manifest", "socket", "environment",
            "screenshot_out_file", "debug_image_out", "script"]
        {
            #expect(throws: ComputerUseError.self) {
                try ComputerUseToolPolicy.validate(name: "click", arguments: ["target": .object([key: "override"])])
            }
        }
        try ComputerUseToolPolicy.validate(name: "click", arguments: ["target": ["kind": "window", "pid": 100, "window_id": 200],
            "element_token": "s00000001:2"])
        try ComputerUseToolPolicy.validate(name: "invoke_menu", arguments: ["pid": 100, "path": ["File", "Save"]])
    }

    @Test func batchesValidateEveryActionAndTheirObservation() throws {
        let click: JSONValue = ["tool": "click", "args": ["pid": 100, "element_token": "s00000001:2"]]
        try ComputerUseToolPolicy.validate(name: "run_steps", arguments: ["steps": [click], "observe": ["pid": 100, "include_screenshot": true]])
        for arguments: [String: JSONValue] in [
            ["steps": []], ["steps": .array(Array(repeating: click, count: 65))],
            ["steps": [["tool": "browser_click", "args": [:]]]],
            ["steps": [["tool": "run_steps", "args": ["steps": [click]]]]],
            ["steps": [["tool": "click", "args": ["session": "other"]]]],
            ["steps": [["click": ["pid": 100]]]],
            ["steps": [click], "observe": ["tool": "browser_eval"]],
        ] { #expect(throws: ComputerUseError.self) { try ComputerUseToolPolicy.validate(name: "run_steps", arguments: arguments) } }
    }

    @Test func argumentDepthSizeAndNumbersAreBoundedBeforeRuntimeDispatch() {
        var nested: JSONValue = "leaf"
        for _ in 0..<15 { nested = ["child": nested] }
        for arguments: [String: JSONValue] in [
            ["value": nested], ["text": .string(String(repeating: "a", count: 65_537))], ["x": .number(.infinity)],
            ["text": "bad\0text"], ["items": .array(Array(repeating: true, count: 2_049))],
        ] { #expect(throws: ComputerUseError.self) { try ComputerUseToolPolicy.validate(name: "type_text", arguments: arguments) } }
    }
}

struct ComputerUseHTTPRequestTests {
    private let prefix = "POST /computer-use/test HTTP/1.1\r\nHost: 127.0.0.1:1234\r\nAuthorization: Bearer fixture\r\nContent-Type: application/json\r\n"

    @Test func refusesBrowserOriginsHeaderSmugglingAndExtraBodies() throws {
        let valid = prefix + "Content-Length: 2\r\n\r\n{}"
        #expect(try ComputerUseHTTPRequest.parse(Data(valid.utf8))?.body == Data("{}".utf8))
        #expect(try ComputerUseHTTPRequest.parse(Data((prefix + "Content-Length: 2\r\n\r\n{").utf8)) == nil)
        for headers in [
            "Origin: https://untrusted.test\r\nContent-Length: 2", "Origin: \r\nContent-Length: 2", "Transfer-Encoding: chunked\r\nContent-Length: 2",
            "Content-Length: 2\r\ncontent-length: 2", "Content-Length: -1", "Content-Length: +2", "Content-Length: 9999999",
            " Content-Length: 2", "Content Length: 2",
        ] {
            #expect(throws: ComputerUseError.self) { try ComputerUseHTTPRequest.parse(Data((prefix + headers + "\r\n\r\n{}").utf8)) }
        }
        #expect(throws: ComputerUseError.self) { try ComputerUseHTTPRequest.parse(Data((valid + "extra").utf8)) }
        #expect(throws: ComputerUseError.self) { try ComputerUseHTTPRequest.parse(Data(repeating: 65, count: 16_385)) }
    }
}

@MainActor @Suite(.serialized)
struct ComputerUseBridgeTests {
    @Test func grantsArePrivateThreadScopedHostBoundAndRevocable() async throws {
        let fixture = try await ComputerUseBridgeFixture()
        defer { fixture.bridge.stop() }
        let response = try await fixture.send(["action": "status"])
        #expect(response.status == 200 && response.json?["ok"]?.bool == true)
        let fileMode = try FileManager.default.attributesOfItem(atPath: fixture.access.configuration.path)[.posixPermissions] as? NSNumber
        let folderMode = try FileManager.default.attributesOfItem(atPath: fixture.access.directory.path)[.posixPermissions] as? NSNumber
        #expect(fileMode?.intValue == 0o600 && folderMode?.intValue == 0o700)
        #expect(!fixture.access.instructions.contains(fixture.authorization))
        for alteration in ["token", "thread", "host", "origin"] {
            var request = fixture.request(["action": "status"])
            switch alteration {
            case "token": request.setValue("Bearer other", forHTTPHeaderField: "Authorization")
            case "thread": request.url = request.url?.deletingLastPathComponent().appendingPathComponent(UUID().uuidString)
            case "host": request.setValue("untrusted.test", forHTTPHeaderField: "Host")
            default: request.setValue("https://untrusted.test", forHTTPHeaderField: "Origin")
            }
            let result = try await fixture.send(request)
            #expect(result.status == (alteration == "origin" ? 400 : 403))
        }
        let original = fixture.authorization
        fixture.bridge.disable(threadID: fixture.threadID)
        #expect(!FileManager.default.fileExists(atPath: fixture.access.configuration.path))
        #expect(try await fixture.send(["action": "status"]).status == 403)
        _ = try await fixture.bridge.enable(threadID: fixture.threadID) { _, _ in ["ok": true] }
        let rotated = try ComputerUseBridgeFixture.authorization(from: fixture.access.configuration) != original
        #expect(rotated)
        #expect(try await fixture.send(["action": "status"]).status == 403)
    }

    @Test func invalidNativeCallsNeverReachTheRuntime() async throws {
        var called = 0
        let fixture = try await ComputerUseBridgeFixture { _, _ in called += 1; return ["ok": true] }
        defer { fixture.bridge.stop() }
        for body: JSONValue in [
            ["action": "call", "name": "browser_click", "arguments": [:]],
            ["action": "call", "name": "click", "arguments": ["session": "other"]],
            ["action": "call", "name": "run_steps", "arguments": ["steps": [["tool": "run_script", "args": [:]]]]],
        ] { #expect(try await fixture.send(body).status == 400) }
        #expect(called == 0)
    }

    @Test func oneThreadCannotOverlapCallsAndRevocationCancelsPendingWork() async throws {
        let began = Gate(), finish = Gate()
        var cancelled = false
        let fixture = try await ComputerUseBridgeFixture { _, _ in
            began.open()
            await finish.wait()
            cancelled = Task.isCancelled
            return ["private_result": true]
        }
        defer { fixture.bridge.stop(); finish.open() }
        let pending = Task { try? await fixture.send(["action": "status"]) }
        await began.wait()
        let concurrent = try await fixture.send(["action": "status"])
        #expect(concurrent.status == 400 && concurrent.json?["error"]?.string != nil)
        fixture.bridge.disable(threadID: fixture.threadID)
        finish.open()
        let revoked = await pending.value
        #expect(revoked?.json?["private_result"] == nil)
        for _ in 0..<20 where !cancelled { await Task.yield() }
        #expect(cancelled)
    }

    @Test func oversizedRuntimeOutputIsBoundedAndStopRemovesCredentials() async throws {
        let fixture = try await ComputerUseBridgeFixture { _, _ in ["large": .string(String(repeating: "a", count: 4_194_305))] }
        let response = try await fixture.send(["action": "status"])
        #expect(response.status == 400 && response.json?["large"] == nil && response.json?["error"]?.string != nil)
        fixture.bridge.stop()
        #expect(!fixture.bridge.isReady && fixture.bridge.access(for: fixture.threadID) == nil)
        #expect(!FileManager.default.fileExists(atPath: fixture.access.configuration.path))
    }
}

@MainActor
private final class ComputerUseBridgeFixture {
    let bridge: ComputerUseBridge
    let threadID: UUID
    let access: ComputerUseBridge.Access
    let endpoint: URL
    let authorization: String

    init(handler: @escaping ComputerUseBridge.Handler = { _, _ in ["ok": true] }) async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("coincide-computer-use-test-" + UUID().uuidString)
        let bridge = ComputerUseBridge(directory: directory)
        let threadID = UUID()
        self.bridge = bridge
        self.threadID = threadID
        let access = try await bridge.enable(threadID: threadID, handler: handler)
        self.access = access
        let config = try String(contentsOf: access.configuration, encoding: .utf8)
        let line = try #require(config.split(separator: "\n").first { $0.hasPrefix("url = ") })
        endpoint = try #require(URL(string: String(line.split(separator: "\"")[1])))
        authorization = try Self.authorization(from: access.configuration)
    }

    static func authorization(from configuration: URL) throws -> String {
        let config = try String(contentsOf: configuration, encoding: .utf8)
        let header = try #require(config.split(separator: "\n").first(where: { $0.contains("Authorization:") })?.split(separator: "\"")[1])
        return String(header.dropFirst("Authorization: ".count))
    }

    func request(_ body: JSONValue) -> URLRequest {
        var request = URLRequest(url: endpoint)
        request.httpMethod = "POST"
        request.httpBody = Data(body.compactJSON.utf8)
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue(authorization, forHTTPHeaderField: "Authorization")
        return request
    }

    func send(_ body: JSONValue) async throws -> (status: Int, json: JSONValue?) { try await send(request(body)) }

    func send(_ request: URLRequest) async throws -> (status: Int, json: JSONValue?) {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 5
        let session = URLSession(configuration: configuration)
        defer { session.invalidateAndCancel() }
        let (data, response) = try await session.data(for: request)
        return ((response as? HTTPURLResponse)?.statusCode ?? 0, JSONValue.parse(data))
    }
}
