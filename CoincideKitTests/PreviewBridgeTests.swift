import Foundation
import Testing
@testable import CoincideKit

@Suite struct PreviewProtocolTests {
    @Test func onlyWebAddressesAndBoundedCommandsAreAccepted() throws {
        #expect(PreviewCommand.url("localhost:3000/path")?.absoluteString == "http://localhost:3000/path")
        #expect(PreviewCommand.url("https://example.test/page")?.scheme == "https")
        #expect(PreviewCommand.url("http://[::1]:8000")?.host != nil)
        // Like browsers, typed public names get HTTPS and development servers keep HTTP.
        #expect(PreviewCommand.url("apoorvdarshan.com")?.absoluteString == "https://apoorvdarshan.com")
        #expect(PreviewCommand.url("example.test/page?q=1")?.scheme == "https")
        for address in ["localhost", "127.0.0.1/x", "192.168.1.20", "myapp.local", "api.localhost", "devbox", "example.test:8080", "[::1]"] {
            #expect(PreviewCommand.url(address)?.scheme == "http", "\(address)")
        }
        #expect(PreviewCommand.url("http://example.test")?.scheme == "http")
        for address in ["file:///tmp/private", "file:/tmp/private", "javascript:alert(1)", "data:text/html,test", "about:blank", "https://user:password@example.test"] {
            #expect(PreviewCommand.url(address) == nil)
        }
        #expect(throws: PreviewError.self) { try PreviewCommand(json: ["action": "evaluate", "script": "alert(1)"]) }
        #expect(throws: PreviewError.self) { try PreviewCommand(json: ["action": "input", "selector": "input", "text": .string(String(repeating: "a", count: 65_537))]) }
    }

    @Test func HTTPParserRejectsOriginsAmbiguousHeadersAndOversizedBodies() throws {
        let prefix = "POST /preview/test HTTP/1.1\r\nHost: 127.0.0.1:1\r\nAuthorization: Bearer test\r\nContent-Type: application/json\r\n"
        #expect(try PreviewHTTPRequest.parse(Data((prefix + "Content-Length: 2\r\n\r\n{").utf8)) == nil)
        #expect(try PreviewHTTPRequest.parse(Data((prefix + "Content-Length: 2\r\n\r\n{}").utf8))?.body == Data("{}".utf8))
        for headers in ["Origin: https://untrusted.test\r\nContent-Length: 2", "Content-Length: 2\r\nContent-Length: 2", "Transfer-Encoding: chunked\r\nContent-Length: 2", "Content-Length: 1048577", "Content-Length: -1"] {
            #expect(throws: PreviewError.self) { try PreviewHTTPRequest.parse(Data((prefix + headers + "\r\n\r\n{}").utf8)) }
        }
        #expect(throws: PreviewError.self) { try PreviewHTTPRequest.parse(Data((prefix + "Content-Length: 2\r\n\r\n{}extra").utf8)) }
        #expect(throws: PreviewError.self) { try PreviewHTTPRequest.parse(Data(repeating: 65, count: 16_385)) }
    }
}

@MainActor @Suite(.serialized) struct PreviewBridgeTests {
    @Test func capabilityIsPrivateThreadScopedAndRevocable() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("coincide-preview-test-" + UUID().uuidString)
        let bridge = PreviewBridge(directory: directory)
        defer { bridge.stop() }
        let id = UUID(), other = UUID()
        var commands: [PreviewCommand] = []
        let access = try await bridge.enable(threadID: id) { command, folder in
            commands.append(command)
            #expect(folder.deletingLastPathComponent().path == directory.path)
            return ["title": "Local fixture"]
        }
        let curl = await ProcessRunner.run(URL(fileURLWithPath: "/usr/bin/curl"),
            ["--config", access.configuration.path, "--data-binary", #"{"action":"read"}"#], timeout: 5)
        #expect(curl.succeeded)
        #expect(JSONValue.parse(Data(curl.stdout.utf8))?["title"]?.string == "Local fixture")
        let config = try String(contentsOf: access.configuration, encoding: .utf8)
        let target = try #require(config.split(separator: "\n").first(where: { $0.hasPrefix("url = ") })?.split(separator: "\"")[1])
        let header = try #require(config.split(separator: "\n").first(where: { $0.contains("Authorization:") })?.split(separator: "\"")[1])
        let token = String(header.dropFirst("Authorization: ".count))
        let mode = try FileManager.default.attributesOfItem(atPath: access.configuration.path)[.posixPermissions] as? NSNumber
        #expect(mode?.intValue == 0o600)
        #expect(!access.instructions.contains(token))
        var request = URLRequest(url: try #require(URL(string: String(target))))
        request.httpMethod = "POST"
        request.httpBody = Data(#"{"action":"read"}"#.utf8)
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue(token, forHTTPHeaderField: "Authorization")
        let session = URLSession(configuration: .ephemeral)
        defer { session.invalidateAndCancel() }
        func status(_ request: URLRequest) async throws -> Int { try await (session.data(for: request).1 as? HTTPURLResponse)?.statusCode ?? 0 }
        #expect(try await status(request) == 200)
        #expect(commands == [.read, .read])
        var altered = request
        altered.setValue("Bearer invalid", forHTTPHeaderField: "Authorization")
        #expect(try await status(altered) == 403)
        altered = request
        altered.url = request.url?.deletingLastPathComponent().appendingPathComponent(other.uuidString)
        #expect(try await status(altered) == 403)
        altered = request
        altered.setValue("https://untrusted.test", forHTTPHeaderField: "Origin")
        #expect(try await status(altered) == 400)
        altered = request
        altered.url = request.url?.appendingPathComponent("../preview.curl")
        #expect(try await status(altered) == 403)
        #expect(commands == [.read, .read])
        bridge.disable(threadID: id)
        #expect(!FileManager.default.fileExists(atPath: access.configuration.path))
        #expect(try await status(request) == 403)
        let replacement = try await bridge.enable(threadID: id) { _, _ in ["ok": true] }
        #expect(try String(contentsOf: replacement.configuration, encoding: .utf8) != config)
        #expect(try await status(request) == 403)
    }
}
