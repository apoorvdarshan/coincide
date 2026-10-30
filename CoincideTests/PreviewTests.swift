import AppKit
@testable import CoincideKit
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

    /// What agents need beyond clicking: typing like a keyboard (rich editors too), real key presses, answering the
    /// page's dialogs, scrolling, waiting, scoped reads and history.
    @Test func agentsUseKeysTypingDialogsAndScrolling() async throws {
        let fixture = try await PreviewFixture.start()
        defer { fixture.stop() }
        let session = PreviewSession()
        let window = NSWindow(contentRect: NSRect(x: -20_000, y: -20_000, width: 800, height: 600), styleMask: [.borderless], backing: .buffered, defer: false)
        window.alphaValue = 0
        window.contentView = session.webView
        window.orderBack(nil)
        defer { window.orderOut(nil) }
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("coincide-keys-test-" + UUID().uuidString)
        try session.navigate(fixture.url.absoluteString)
        for _ in 0..<500 {
            if session.webView.title == "Preview fixture", !session.webView.isLoading { break }
            try await Task.sleep(for: .milliseconds(10))
        }
        func perform(_ command: PreviewCommand) async throws -> JSONValue {
            try await PreviewBridge.run(command, within: 10) { try await session.perform(command, directory: folder) }
        }
        func waitForText(_ expected: String) async throws -> Bool {
            for _ in 0..<150 {
                if try await perform(.read())["text"]?.string?.contains(expected) == true { return true }
                try await Task.sleep(for: .milliseconds(20))
            }
            return false
        }

        // Typing, then Enter in the field, submits the form as a person would.
        _ = try await perform(.type(selector: "#q", text: "hello world", clear: false))
        _ = try await perform(.press(key: try #require(KeyPress("Enter")), selector: "#q"))
        #expect(try await waitForText("Submitted hello world"))
        _ = try await perform(.type(selector: "#q", text: "again", clear: true))
        let field = try await session.webView.callAsyncJavaScript("return document.getElementById('q').value", arguments: [:], in: nil, contentWorld: .page)
        #expect(field as? String == "again")

        // A rich editor gets the text as typed, lines included.
        _ = try await perform(.type(selector: "#editor", text: "Line one\nLine two", clear: false))
        let edited = try await session.webView.callAsyncJavaScript("return document.getElementById('editor').innerText", arguments: [:], in: nil, contentWorld: .page) as? String
        #expect(edited?.contains("Line one") == true && edited?.contains("Line two") == true)

        // Keys arrive as trusted key events.
        _ = try await perform(.press(key: try #require(KeyPress("Escape")), selector: nil))
        #expect(try await waitForText("Escape true"))

        // A confirmation blocks the page until answered; the click still returns and reports it.
        let click = try await perform(.click("#confirm"))
        #expect(click["dialog"]?["type"]?.string == "confirm")
        #expect(try await perform(.read())["dialog"]?["message"]?.string == "Delete it?")
        await #expect(throws: PreviewError.self) { _ = try await perform(.scroll(.top)) }
        _ = try await perform(.dialog(accept: true, text: nil))
        #expect(try await waitForText("Confirmed"))
        _ = try await perform(.click("#ask"))
        #expect(try await perform(.read())["dialog"]?["default"]?.string == "x")
        _ = try await perform(.dialog(accept: true, text: "Apoorv"))
        #expect(try await waitForText("Name: Apoorv"))
        await #expect(throws: PreviewError.self) { _ = try await perform(.dialog(accept: true, text: nil)) }

        // Scrolling, waiting and scoped reads.
        #expect(try await perform(.scroll(.bottom))["atBottom"]?.bool == true)
        #expect(try await perform(.scroll(.top))["scrollY"]?.number == 0)
        #expect(try await perform(.waitFor(selector: nil, text: "Ready later", timeout: 5))["found"]?.bool == true)
        await #expect(throws: PreviewError.self) { _ = try await perform(.waitFor(selector: "#never", text: nil, timeout: 0.5)) }
        let scoped = try await perform(.read(page: 1, scope: "#answer"))
        #expect(scoped["text"]?.string == "Name: Apoorv")
        #expect(scoped["pages"]?.number == 1)
        await #expect(throws: (any Error).self) { _ = try await perform(.read(page: 1, scope: "#missing")) }

        // History.
        try session.navigate(fixture.url.absoluteString + "?second")
        for _ in 0..<300 where session.webView.url?.query != "second" || session.webView.isLoading { try await Task.sleep(for: .milliseconds(10)) }
        #expect(try await perform(.back)["moved"]?.bool == true)
        for _ in 0..<300 where session.webView.url?.query == "second" || session.webView.isLoading { try await Task.sleep(for: .milliseconds(10)) }
        #expect(session.webView.url?.query == nil)
        #expect(try await perform(.forward)["moved"]?.bool == true)
    }

    @Test func downloadsCrossOriginFramesAndWebTestingTools() async throws {
        let fixture = try await PreviewFixture.start()
        defer { fixture.stop() }
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("coincide-tools-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let session = PreviewSession(dataStore: .nonPersistent(), isPrivate: true, downloadDirectory: folder.appendingPathComponent("downloads"))
        defer { session.close() }
        let window = NSWindow(contentRect: NSRect(x: -20_000, y: -20_000, width: 800, height: 600), styleMask: [.borderless], backing: .buffered, defer: false)
        window.alphaValue = 0
        window.contentView = session.webView
        window.orderBack(nil)
        defer { window.orderOut(nil) }
        func perform(_ command: PreviewCommand) async throws -> JSONValue {
            try await PreviewBridge.run(command, within: 10) { try await session.perform(command, directory: folder) }
        }
        try session.navigate(fixture.url.absoluteString)
        for _ in 0..<500 where session.webView.title != "Preview fixture" || session.webView.isLoading { try await Task.sleep(for: .milliseconds(10)) }

        let frameURL = fixture.url.absoluteString.replacingOccurrences(of: "127.0.0.1", with: "localhost") + "frame"
        _ = try await session.webView.callAsyncJavaScript("const el = document.createElement('iframe'); el.src = address; document.body.prepend(el); return true;",
            arguments: ["address": frameURL], in: nil, contentWorld: .page)
        var frameID: String?
        for _ in 0..<200 {
            frameID = try await perform(.frames)["frames"]?.array?.first(where: { $0["url"]?.string == frameURL })?["id"]?.string
            if frameID != nil { break }
            try await Task.sleep(for: .milliseconds(20))
        }
        let frame = try #require(frameID)
        _ = try await perform(.inFrame(frame, .type(selector: "#inside", text: "Across origins", clear: true)))
        _ = try await perform(.inFrame(frame, .click("#frameApply")))
        let embedded = try await perform(.inFrame(frame, .read()))
        #expect(embedded["text"]?.string?.contains("Across origins") == true)
        #expect(!embedded.compactJSON.contains("frame-password"))
        await #expect(throws: PreviewError.self) { _ = try await perform(.inFrame("frame-missing", .read())) }

        _ = try await session.webView.callAsyncJavaScript("console.warn('fixture warning'); setTimeout(() => { throw new Error('fixture script error'); }, 0); Promise.reject('fixture rejection'); return true;",
            arguments: [:], in: nil, contentWorld: .page)
        var logs: JSONValue = [:]
        for _ in 0..<100 {
            logs = try await perform(.console(clear: false))
            if logs.compactJSON.contains("fixture script error") && logs.compactJSON.contains("fixture rejection") { break }
            try await Task.sleep(for: .milliseconds(20))
        }
        #expect(logs.compactJSON.contains("fixture warning"))
        #expect(logs.compactJSON.contains("fixture script error"))
        #expect(logs.compactJSON.contains("fixture rejection"))
        _ = try await perform(.console(clear: true))
        #expect(try await perform(.console(clear: false))["entries"]?.array?.isEmpty == true)

        _ = try await session.webView.callAsyncJavaScript("const a = document.createElement('a'); a.href='/download'; a.id='export'; a.textContent='Export'; document.body.prepend(a); return true;",
            arguments: [:], in: nil, contentWorld: .page)
        _ = try await perform(.click("#export"))
        var download: JSONValue?
        for _ in 0..<200 {
            download = try await perform(.downloads)["downloads"]?.array?.first
            if download?["state"]?.string == "finished" { break }
            try await Task.sleep(for: .milliseconds(20))
        }
        #expect(download?["state"]?.string == "finished")
        let path = try #require(download?["path"]?.string)
        #expect(path.hasPrefix(folder.appendingPathComponent("downloads").path + "/"))
        #expect(try String(contentsOfFile: path, encoding: .utf8) == "invoice fixture")
        _ = try await perform(.click("#export"))
        var completed: [JSONValue] = []
        for _ in 0..<200 {
            completed = try await perform(.downloads)["downloads"]?.array?.filter { $0["state"]?.string == "finished" } ?? []
            if completed.count == 2 { break }
            try await Task.sleep(for: .milliseconds(20))
        }
        #expect(completed.count == 2)
        #expect(Set(completed.compactMap { $0["path"]?.string }).count == 2)

        _ = try await perform(.viewport(width: 390, height: 844))
        let dimensions = try await session.webView.callAsyncJavaScript("return {width: innerWidth, height: innerHeight}", arguments: [:], in: nil, contentWorld: .page) as? [String: Int]
        #expect(dimensions?["width"] == 390 && dimensions?["height"] == 844)
        let screenshot = try await perform(.fullPageScreenshot)
        let screenshotPath = try #require(screenshot["path"]?.string)
        let image = try #require(NSBitmapImageRep(data: Data(contentsOf: URL(fileURLWithPath: screenshotPath))))
        #expect(image.pixelsHigh > 844)
        #expect(image.pixelsWide <= 1600)
        #expect(session.webView.frame.size == NSSize(width: 390, height: 844))
        _ = try await perform(.viewport(width: nil, height: nil))

        _ = try await session.webView.callAsyncJavaScript("const el = document.createElement('div'); el.id='long'; el.textContent='A'.repeat(65000); document.body.append(el); for(let i=0;i<420;i++){const b=document.createElement('button'); b.textContent='Button '+i; document.body.append(b);} return true;", arguments: [:], in: nil, contentWorld: .page)
        let first = try await perform(.read(page: 1, scope: "#long"))
        let last = try await perform(.read(page: 3, scope: "#long"))
        #expect(first["pages"]?.number == 3)
        #expect(first["text"]?.string?.count == 30_000)
        #expect(last["text"]?.string?.count == 5_000)
        #expect(try await perform(.read(page: 3))["elements"]?.array?.isEmpty == false)
        _ = try await perform(.reload)
        for _ in 0..<200 where session.webView.isLoading { try await Task.sleep(for: .milliseconds(20)) }
        #expect(try await perform(.frames)["frames"]?.array?.isEmpty == true)
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
            try await session.perform(.read(), directory: folder)["text"]?.string ?? ""
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
            connection.receive(minimumIncompleteLength: 1, maximumLength: 8192) { request, _, _, _ in
                let route = String(data: request ?? Data(), encoding: .utf8)?.split(separator: " ").dropFirst().first ?? "/"
                if route == "/download" || route == "/frame" {
                    let download = route == "/download"
                    let text = download ? "invoice fixture" : #"<title>Embedded fixture</title><input id="inside"><input type="password" value="frame-password"><button id="frameApply" onclick="document.getElementById('out').textContent=document.getElementById('inside').value">Apply</button><p id="out">Frame ready</p>"#
                    let body = Data(text.utf8)
                    let type = download ? "application/octet-stream" : "text/html; charset=utf-8"
                    let disposition = download ? "Content-Disposition: attachment; filename=invoice.txt\r\n" : ""
                    var response = Data("HTTP/1.1 200 OK\r\nContent-Type: \(type)\r\n\(disposition)Content-Length: \(body.count)\r\nConnection: close\r\n\r\n".utf8)
                    response.append(body)
                    connection.send(content: response, completion: .contentProcessed { _ in connection.cancel() })
                    return
                }
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
                    <form id="search" onsubmit="event.preventDefault(); document.getElementById('submitted').textContent='Submitted '+document.getElementById('q').value"><input id="q"></form>
                    <p id="submitted">Not submitted</p>
                    <div id="editor" contenteditable="true" style="min-height:20px;border:1px solid #ccc"></div>
                    <p id="keys">No keys</p>
                    <button id="confirm" onclick="document.getElementById('answer').textContent = confirm('Delete it?') ? 'Confirmed' : 'Kept'">Delete</button>
                    <button id="ask" onclick="document.getElementById('answer').textContent = 'Name: ' + prompt('Your name?', 'x')">Ask</button>
                    <p id="answer">No answer</p>
                    <div style="height:3000px"></div><p id="end">The end</p>
                    <script>
                    document.addEventListener('keydown', e => { if (e.key === 'Escape') document.getElementById('keys').textContent = 'Escape ' + e.isTrusted; });
                    setTimeout(() => document.body.insertAdjacentHTML('beforeend', '<p>Ready later</p>'), 600);
                    </script>
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
