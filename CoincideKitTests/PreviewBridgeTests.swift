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
        // Uploads take 1–20 absolute paths, and may name a tab.
        let upload = try PreviewCommand(json: ["action": "upload", "selector": "#cv", "files": ["/tmp/a/../cv.pdf"], "tab": "t1"])
        #expect(upload == .inTab("t1", .upload(selector: "#cv", files: [URL(fileURLWithPath: "/tmp/cv.pdf")])))
        for files: JSONValue in [[], ["cv.pdf"], ["~/cv.pdf"], [1], .array(Array(repeating: "/tmp/x", count: 21))] {
            #expect(throws: PreviewError.self) { try PreviewCommand(json: ["action": "upload", "selector": "#cv", "files": files]) }
        }
        #expect(throws: PreviewError.self) { try PreviewCommand(json: ["action": "upload", "files": ["/tmp/cv.pdf"]]) }
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

/// What typing in the address bar opens: addresses, development servers and local files directly, anything else as a
/// search with the chosen engine.
@Suite struct BrowserAddressTests {
    private func resolve(_ text: String, _ engine: SearchEngine = .google, files: Bool = true, home: URL = URL(fileURLWithPath: "/nonexistent-home")) -> BrowserAddress.Destination? {
        BrowserAddress.resolve(text, engine: engine, allowsFiles: files, home: home)
    }

    @Test func wordsSearchAndAddressesOpen() throws {
        #expect(resolve("best pizza near me")?.url.absoluteString == "https://www.google.com/search?q=best%20pizza%20near%20me")
        #expect(resolve("hello") == .search(try #require(URL(string: "https://www.google.com/search?q=hello"))))
        #expect(resolve("next.js")?.url.host == "www.google.com")
        #expect(resolve("notes.txt")?.url.host == "www.google.com")
        #expect(resolve("?apoorvdarshan.com")?.url.host == "www.google.com")
        #expect(resolve("apoorvdarshan.com") == .web(try #require(URL(string: "https://apoorvdarshan.com"))))
        #expect(resolve("github.com/apoorvdarshan")?.url.absoluteString == "https://github.com/apoorvdarshan")
        #expect(resolve("https://example.com/a b")?.url.absoluteString == "https://example.com/a%20b")
        #expect(resolve("ftp://example.com") == nil)
        #expect(resolve("  ") == nil)
        #expect(resolve("cats", .duckDuckGo)?.url.absoluteString == "https://duckduckgo.com/?q=cats")
        for engine in SearchEngine.allCases { #expect(engine.url(for: "a&b=c")?.query?.contains("a%26b%3Dc") == true, "\(engine)") }
    }

    @Test func developmentServersNeverGoToTheSearchEngine() {
        for address in ["localhost", "localhost:3000", "localhost:3000/api", "127.0.0.1", "127.0.0.1:8080", "192.168.1.20", "[::1]:8000",
            "myapp.local", "api.localhost", "devbox:8080", "devbox/"]
        {
            let destination = resolve(address)
            guard case .web(let url) = destination else { Issue.record("\(address) → \(String(describing: destination))"); continue }
            #expect(url.scheme == "http", "\(address)")
        }
    }

    @Test func localFilesOpenOnlyWhenTheUserTypesThem() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("coincide-address-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let page = folder.appendingPathComponent("index.html")
        try Data("<title>Local</title>".utf8).write(to: page)
        #expect(resolve(page.path) == .file(page.standardizedFileURL))
        #expect(resolve(page.absoluteString) == .file(page.standardizedFileURL))
        #expect(resolve("~/index.html", home: folder) == .file(page.standardizedFileURL))
        #expect(resolve(page.path, files: false) == nil)
        // A folder or a missing file doesn't open; a missing path searches like other words.
        #expect(resolve(folder.path)?.url.host == "www.google.com")
        #expect(resolve("file:///nonexistent/page.html") == nil)
    }
}
