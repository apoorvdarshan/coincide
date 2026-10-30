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

    /// A path typed in the address bar opens the local file; words search with the chosen engine.
    @Test func typedPathsOpenLocalFiles() async throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("coincide-local-page-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let page = folder.appendingPathComponent("index.html")
        try Data("<!doctype html><title>Local page</title><p>From disk</p>".utf8).write(to: page)
        let session = PreviewSession()
        try session.navigate(page.path)
        for _ in 0..<500 {
            if session.webView.title == "Local page", !session.webView.isLoading { break }
            try await Task.sleep(for: .milliseconds(10))
        }
        #expect(session.webView.title == "Local page")
        #expect(session.webView.url?.isFileURL == true)
        session.searchEngine = { .duckDuckGo }
        try session.navigate("coincide browser")
        #expect(session.activeTab.url?.absoluteString == "https://duckduckgo.com/?q=coincide%20browser")
    }

    /// An agent's upload answers the page's file chooser itself: no dialog, the files arrive as if picked, through the
    /// input or a button that opens a hidden one.
    @Test func agentUploadsReachFileInputsWithoutADialog() async throws {
        let fixture = try await PreviewFixture.start()
        defer { fixture.stop() }
        let session = PreviewSession()
        let window = NSWindow(contentRect: NSRect(x: -20_000, y: -20_000, width: 800, height: 600), styleMask: [.borderless], backing: .buffered, defer: false)
        window.alphaValue = 0
        window.contentView = session.webView
        window.orderBack(nil)
        defer { window.orderOut(nil) }
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("coincide-upload-test-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let resume = folder.appendingPathComponent("resume.pdf")
        let cover = folder.appendingPathComponent("cover letter.txt")
        try Data("%PDF-1.4 fixture".utf8).write(to: resume)
        try Data("hello".utf8).write(to: cover)
        try session.navigate(fixture.url.absoluteString)
        for _ in 0..<500 {
            if session.webView.title == "Preview fixture", !session.webView.isLoading { break }
            try await Task.sleep(for: .milliseconds(10))
        }
        func text() async throws -> String {
            try await session.perform(.read, directory: folder)["text"]?.string ?? ""
        }

        let direct = try await session.perform(.upload(selector: "#file", files: [resume, cover]), directory: folder)
        #expect(direct["uploaded"]?.array?.compactMap(\.string) == ["resume.pdf", "cover letter.txt"])
        for _ in 0..<100 {
            if try await text().contains("Files:") { break }
            try await Task.sleep(for: .milliseconds(20))
        }
        #expect(try await text().contains("Files: resume.pdf 16, cover letter.txt 5"))

        _ = try await session.perform(.upload(selector: "#pick", files: [resume]), directory: folder)
        for _ in 0..<100 {
            if try await text().contains("Hidden:") { break }
            try await Task.sleep(for: .milliseconds(20))
        }
        #expect(try await text().contains("Hidden: resume.pdf"))

        await #expect(throws: PreviewError.self) {
            _ = try await session.perform(.upload(selector: "#file", files: [folder.appendingPathComponent("missing.pdf")]), directory: folder)
        }
        await #expect(throws: PreviewError.self) {
            _ = try await session.perform(.upload(selector: "#file", files: [folder]), directory: folder)
        }
        // An element that opens no chooser leaves the files unattached.
        await #expect(throws: PreviewError.self) {
            _ = try await session.perform(.upload(selector: "#apply", files: [resume]), directory: folder)
        }
        #expect(NSApp.windows.filter { $0.isVisible && $0 !== window }.allSatisfy { !($0 is NSOpenPanel) })
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
                    <input id="file" type="file" multiple onchange="document.getElementById('files').textContent='Files: '+[...this.files].map(f=>f.name+' '+f.size).join(', ')">
                    <input id="hidden" type="file" style="display:none" onchange="document.getElementById('files').textContent='Hidden: '+this.files[0].name">
                    <button id="pick" onclick="document.getElementById('hidden').click()">Attach</button>
                    <p id="files">No files</p>
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
