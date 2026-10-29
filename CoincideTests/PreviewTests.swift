import AppKit
import CoincideKit
import Network
import Testing
import WebKit
@testable import Coincide

@MainActor @Suite(.serialized) struct PreviewTests {
    @Test func realWebKitPageCanBeDrivenThroughItsScopedBridge() async throws {
        let fixture = try await PreviewFixture.start()
        defer { fixture.stop() }
        let session = PreviewSession()
        // Headless: far off every screen and fully transparent, never activated.
        let window = NSWindow(contentRect: NSRect(x: -20_000, y: -20_000, width: 800, height: 600), styleMask: [.borderless], backing: .buffered, defer: false)
        window.alphaValue = 0
        window.contentView = session.webView
        window.orderBack(nil)
        defer { window.orderOut(nil) }
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("coincide-webkit-test-" + UUID().uuidString)
        let bridge = PreviewBridge(directory: directory)
        defer { bridge.stop() }
        let access = try await bridge.enable(threadID: UUID()) { command, folder in try await session.perform(command, directory: folder) }
        let config = try String(contentsOf: access.configuration, encoding: .utf8)
        let target = try #require(config.split(separator: "\n").first(where: { $0.hasPrefix("url = ") })?.split(separator: "\"")[1])
        let header = try #require(config.split(separator: "\n").first(where: { $0.contains("Authorization:") })?.split(separator: "\"")[1])
        let client = URLSession(configuration: .ephemeral)
        defer { client.invalidateAndCancel() }
        func command(_ json: JSONValue) async throws -> JSONValue {
            var request = URLRequest(url: try #require(URL(string: String(target))))
            request.httpMethod = "POST"
            request.httpBody = Data(json.compactJSON.utf8)
            request.setValue(String(header.dropFirst("Authorization: ".count)), forHTTPHeaderField: "Authorization")
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            let (data, response) = try await client.data(for: request)
            #expect((response as? HTTPURLResponse)?.statusCode == 200)
            return try #require(JSONValue.parse(data))
        }
        _ = try await command(["action": "navigate", "url": .string(fixture.url.absoluteString)])
        for _ in 0..<500 {
            if session.webView.title == "Preview fixture", !session.webView.isLoading { break }
            try await Task.sleep(for: .milliseconds(10))
        }
        #expect(session.webView.title == "Preview fixture")
        let first = try await command(["action": "read"])
        #expect(first["title"]?.string == "Preview fixture")
        #expect(first["elements"]?.array?.contains { $0["selector"]?.string == "#name" } == true)
        #expect(!first.compactJSON.contains("do-not-read-password"))
        let text = "Quotes ' \\\n and </script> stay literal"
        _ = try await command(["action": "input", "selector": "#name", "text": .string(text)])
        _ = try await command(["action": "click", "selector": "#apply"])
        let changed = try await command(["action": "read"])
        #expect(changed["text"]?.string?.contains("stay literal") == true)
        let screenshot = try await command(["action": "screenshot"])
        let path = try #require(screenshot["path"]?.string)
        #expect(path.hasPrefix(access.directory.path + "/"))
        let png = try Data(contentsOf: URL(fileURLWithPath: path))
        #expect(png.starts(with: [137, 80, 78, 71, 13, 10, 26, 10]))
        #expect((800...1600).contains(NSBitmapImageRep(data: png)?.pixelsWide ?? 0))

        _ = try await session.webView.callAsyncJavaScript("document.title = 'x'.repeat(10000); return true", arguments: [:], in: nil, contentWorld: .page)
        let bounded = try await command(["action": "read"])
        #expect(bounded["title"]?.string?.count == 1000)

        // A second session has separate storage and page state, even for the same local origin.
        _ = try await session.webView.callAsyncJavaScript("localStorage.setItem('thread', 'first'); return true", arguments: [:], in: nil, contentWorld: .page)
        let second = PreviewSession()
        try second.navigate(fixture.url.absoluteString)
        for _ in 0..<500 {
            if second.webView.title == "Preview fixture", !second.webView.isLoading { break }
            try await Task.sleep(for: .milliseconds(10))
        }
        let stored = try await second.webView.callAsyncJavaScript("return {value: localStorage.getItem('thread')}", arguments: [:], in: nil, contentWorld: .page) as? [String: Any]
        #expect(stored?["value"] is NSNull)

        // The navigation delegate rejects an unsupported scheme, without opening another app.
        session.webView.load(URLRequest(url: try #require(URL(string: "file:///tmp/forbidden-preview-file"))))
        for _ in 0..<100 where session.error == nil { try await Task.sleep(for: .milliseconds(10)) }
        #expect(session.error == PreviewError.invalidAddress.localizedDescription)
        #expect(session.webView.url?.scheme == "http")
    }
}

/// An in-process HTTP fixture, confined to loopback. The tests never navigate public or authenticated pages.
@MainActor private final class PreviewFixture {
    let listener: NWListener
    let url: URL
    private init(listener: NWListener, port: UInt16) {
        self.listener = listener
        url = URL(string: "http://127.0.0.1:\(port)/")!
    }
    static func start() async throws -> PreviewFixture {
        let parameters = NWParameters.tcp
        parameters.requiredLocalEndpoint = .hostPort(host: "127.0.0.1", port: .any)
        let listener = try NWListener(using: parameters)
        listener.newConnectionHandler = { connection in
            connection.start(queue: .main)
            connection.receive(minimumIncompleteLength: 1, maximumLength: 8192) { _, _, _, _ in
                let html = #"""
                    <!doctype html><meta charset="utf-8"><title>Preview fixture</title>
                    <style>body{font:18px system-ui;padding:40px;background:#f3f5f8;color:#202838}input,button{font:inherit;padding:10px}</style>
                    <h1>Native browser preview</h1><p>A local fixture controlled through Coincide's thread-scoped bridge.</p>
                    <input id="name" placeholder="Your message"><input id="secret" type="password" value="do-not-read-password">
                    <button id="apply" onclick="document.getElementById('result').textContent=document.getElementById('name').value">Apply</button>
                    <p id="result">Waiting for input</p>
                    """#
                let body = Data(html.utf8)
                var response = Data("HTTP/1.1 200 OK\r\nContent-Type: text/html; charset=utf-8\r\nContent-Length: \(body.count)\r\nConnection: close\r\n\r\n".utf8)
                response.append(body)
                connection.send(content: response, completion: .contentProcessed { _ in connection.cancel() })
            }
        }
        let port: UInt16 = try await withCheckedThrowingContinuation { continuation in
            listener.stateUpdateHandler = { state in
                switch state {
                case .ready:
                    listener.stateUpdateHandler = nil
                    continuation.resume(returning: listener.port!.rawValue)
                case .failed(let error):
                    listener.stateUpdateHandler = nil
                    continuation.resume(throwing: error)
                default: break
                }
            }
            listener.start(queue: .main)
        }
        return PreviewFixture(listener: listener, port: port)
    }
    func stop() { listener.cancel() }
}
