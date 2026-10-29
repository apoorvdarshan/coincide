import AppKit
import CoincideKit
import Network
import Testing
import WebKit
@testable import Coincide

/// Each test uses a profile of its own (a fresh `browser.json`, so a fresh WebKit profile id) and deletes it after;
/// the user's real browser profile, other browsers and the Keychain are never touched. Pages come from a loopback
/// fixture.
@MainActor @Suite(.serialized) struct BrowserProfileTests {
    /// A scratch profile and the sessions over it.
    final class Harness {
        let folder: URL
        let profile: BrowserProfile
        let sessions: PreviewSessions
        var revealed: [UUID] = []
        var notified: [UUID] = []

        init() {
            folder = FileManager.default.temporaryDirectory.appendingPathComponent("coincide-browser-" + UUID().uuidString)
            profile = BrowserProfile(directory: folder)
            sessions = PreviewSessions(profile: profile, bridge: PreviewBridge(directory: folder.appendingPathComponent("bridge")))
            sessions.reveal = { [unowned self] id in
                revealed.append(id)
                return true
            }
            sessions.notifyUser = { [unowned self] id, _ in notified.append(id) }
        }

        func tearDown() async {
            sessions.stop()
            await profile.removeProfile()
            try? FileManager.default.removeItem(at: folder)
        }
    }

    @Test func threadsShareOnePersistentProfileButKeepTheirOwnPages() async throws {
        let fixture = try await LoopbackPage.start(title: "Shared")
        defer { fixture.stop() }
        let harness = Harness()
        do {
            let first = harness.sessions.session(for: UUID()), second = harness.sessions.session(for: UUID())
            #expect(!first.isPrivate && first.webView.configuration.websiteDataStore.isPersistent)
            #expect(first.webView.configuration.websiteDataStore === second.webView.configuration.websiteDataStore)
            try first.navigate(fixture.url.absoluteString)
            try await waitForTitle("Shared", first)
            _ = try await first.webView.callAsyncJavaScript(
                "document.cookie = 'signed=in; max-age=3600; path=/'; localStorage.setItem('k', 'v'); return true", arguments: [:],
                in: nil, contentWorld: .page)
            try second.navigate(fixture.url.appendingPathComponent("other").absoluteString)
            try await waitForTitle("Shared", second)
            let seen = try await second.webView.callAsyncJavaScript(
                "return {cookie: document.cookie, stored: localStorage.getItem('k')}", arguments: [:], in: nil, contentWorld: .page) as? [String: Any]
            #expect(seen?["cookie"] as? String == "signed=in")
            #expect(seen?["stored"] as? String == "v")
            // Each thread keeps its own page and history.
            #expect(first.webView.url?.path == "/" && second.webView.url?.path == "/other")
            #expect(!first.webView.canGoBack && !second.webView.canGoBack)

            // A relaunch opens the same named store; the cookie is still there.
            let reopened = WKWebsiteDataStore(forIdentifier: harness.profile.settings.settings.profileID)
            let cookies = await reopened.httpCookieStore.allCookies()
            #expect(cookies.contains { $0.name == "signed" })
            #expect(harness.profile.library.history.contains { $0.url.hasPrefix(fixture.url.absoluteString) })
        }
        // Browsers using the profile must be gone before it can be deleted.
        await harness.tearDown()
    }

    @Test func privateSessionsAreIsolatedAndSwitchingResetsBrowsers() async throws {
        let harness = Harness()
        do {
            let id = UUID()
            let shared = harness.sessions.session(for: id)
            var resets = 0
            let observer = NotificationCenter.default.addObserver(forName: PreviewSessions.sessionsReset, object: nil, queue: .main) { _ in
                MainActor.assumeIsolated { resets += 1 }
            }
            defer { NotificationCenter.default.removeObserver(observer) }
            harness.sessions.start()
            harness.profile.settings.update { $0.usesPrivateSessions = true }
            for _ in 0..<100 where resets == 0 { try await Task.sleep(for: .milliseconds(10)) }
            #expect(resets == 1)
            let privateOne = harness.sessions.session(for: id)
            #expect(privateOne !== shared && privateOne.isPrivate)
            #expect(!privateOne.webView.configuration.websiteDataStore.isPersistent)
            let other = harness.sessions.session(for: UUID())
            #expect(privateOne.webView.configuration.websiteDataStore !== other.webView.configuration.websiteDataStore)
        }
        // Browsers using the profile must be gone before it can be deleted.
        await harness.tearDown()
    }

    @Test func importedCookiesLandInTheSharedProfile() async throws {
        let harness = Harness()
        do {
            let cookie = ImportedCookie(domain: ".imported.test", name: "fixture", value: "synthetic", path: "/",
                expires: Date().addingTimeInterval(3600), isSecure: true, isHTTPOnly: true, sameSite: .lax)
            #expect(await harness.profile.importCookies([cookie]) == 1)
            let stored = await harness.profile.sharedDataStore.httpCookieStore.allCookies()
            #expect(stored.contains { $0.name == "fixture" && $0.domain == ".imported.test" && $0.isHTTPOnly })
            await harness.profile.clear(siteData: true, history: true)
            #expect(await harness.profile.sharedDataStore.httpCookieStore.allCookies().isEmpty)
        }
        // Browsers using the profile must be gone before it can be deleted.
        await harness.tearDown()
    }

    /// The agent drives a thread's browser without the panel: it lives offscreen, never in a visible window.
    @Test func agentsDriveTheBrowserHeadless() async throws {
        let fixture = try await LoopbackPage.start(title: "Headless")
        defer { fixture.stop() }
        let harness = Harness()
        do {
            let id = UUID()
            try await harness.sessions.bridge.prepare()
            let instructions = try #require(harness.sessions.runtimeContext(for: id))
            #expect(instructions.contains("<coincide_browser>") && instructions.contains("ask-user"))
            #expect(harness.sessions.existingSession(for: id) == nil)
            let access = try #require(harness.sessions.bridge.access(for: id))
            let client = BridgeClient(access)
            _ = try await client.send(["action": "navigate", "url": .string(fixture.url.absoluteString)])
            let session = try #require(harness.sessions.existingSession(for: id))
            #expect(session.webView.window.map { $0.frame.maxX < 0 && $0.frame.maxY < 0 } == true)
            try await waitForTitle("Headless", session)
            let page = try await client.send(["action": "read"])
            #expect(page["title"]?.string == "Headless")
            #expect(!page.compactJSON.contains("hidden-password-value"))
            let shot = try await client.send(["action": "screenshot"])
            #expect(shot["path"]?.string.map { FileManager.default.fileExists(atPath: $0) } == true)
            #expect(session.lastAgentUse != nil)

            // Turning Agent Control off for the thread revokes the capability and stops the instructions.
            harness.sessions.setAgentControl(false, for: id)
            #expect(harness.sessions.bridge.access(for: id) == nil)
            #expect(harness.sessions.runtimeContext(for: id) == nil)
        }
        // Browsers using the profile must be gone before it can be deleted.
        await harness.tearDown()
    }

    /// `ask-user` opens the panel, shows the agent's message as a banner, and returns once the user clicks Done.
    @Test func userTurnBannerFlow() async throws {
        let harness = Harness()
        do {
            let id = UUID()
            try await harness.sessions.enableAccess(for: id)
            let panel = PreviewViewController()
            panel.sessions = harness.sessions
            panel.threadID = id
            _ = panel.view
            let client = BridgeClient(try #require(harness.sessions.bridge.access(for: id)))
            let shown = try await client.send(["action": "show"])
            #expect(shown["shown"]?.bool == true && harness.revealed == [id])
            let answer = Task { try await client.send(["action": "ask-user", "message": "Sign in to example.test, then click Done.", "timeout": 60]) }
            for _ in 0..<300 where panel.userTurnBanner.isHidden { try await Task.sleep(for: .milliseconds(10)) }
            #expect(!panel.userTurnBanner.isHidden)
            #expect(panel.userTurnBanner.accessibilityValue() as? String == "Sign in to example.test, then click Done.")
            #expect(harness.revealed == [id, id])
            panel.session?.userTurn.finish(.done)
            #expect(try await answer.value["result"]?.string == "done")
            #expect(panel.userTurnBanner.isHidden)

            // Not visible: the user is told, and Not Now ends the request as declined.
            harness.sessions.reveal = { _ in false }
            let declined = Task { try await client.send(["action": "ask-user", "message": "Choose a plan", "timeout": 60]) }
            for _ in 0..<300 where panel.userTurnBanner.isHidden { try await Task.sleep(for: .milliseconds(10)) }
            #expect(harness.notified == [id])
            panel.session?.userTurn.finish(.declined)
            #expect(try await declined.value["result"]?.string == "declined")
        }
        // Browsers using the profile must be gone before it can be deleted.
        await harness.tearDown()
    }

    private func waitForTitle(_ title: String, _ session: PreviewSession) async throws {
        for _ in 0..<500 {
            if session.webView.title == title, !session.webView.isLoading { return }
            try await Task.sleep(for: .milliseconds(10))
        }
        Issue.record("The page didn't load")
    }
}

/// Sends commands the way an agent's curl does.
@MainActor struct BridgeClient {
    let target: URL
    let authorization: String
    let session = URLSession(configuration: .ephemeral)

    init(_ access: PreviewBridge.Access) {
        let config = (try? String(contentsOf: access.configuration, encoding: .utf8)) ?? ""
        let lines = config.split(separator: "\n")
        target = URL(string: String(lines.first { $0.hasPrefix("url = ") }?.split(separator: "\"")[1] ?? ""))!
        authorization = String(lines.first { $0.contains("Authorization:") }?.split(separator: "\"")[1].dropFirst("Authorization: ".count) ?? "")
    }

    func send(_ json: JSONValue) async throws -> JSONValue {
        var request = URLRequest(url: target, timeoutInterval: 120)
        request.httpMethod = "POST"
        request.httpBody = Data(json.compactJSON.utf8)
        request.setValue(authorization, forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        let (data, _) = try await session.data(for: request)
        return JSONValue.parse(data) ?? .null
    }
}

/// A loopback page with a title and a password field holding a value that must never be read back.
@MainActor final class LoopbackPage {
    let listener: NWListener
    let url: URL

    private init(listener: NWListener, port: UInt16) {
        self.listener = listener
        url = URL(string: "http://127.0.0.1:\(port)/")!
    }

    static func start(title: String) async throws -> LoopbackPage {
        let parameters = NWParameters.tcp
        parameters.requiredLocalEndpoint = .hostPort(host: "127.0.0.1", port: .any)
        let listener = try NWListener(using: parameters)
        listener.newConnectionHandler = { connection in
            connection.start(queue: .main)
            connection.receive(minimumIncompleteLength: 1, maximumLength: 8192) { _, _, _, _ in
                let html = "<!doctype html><meta charset=utf-8><title>\(title)</title><h1>\(title)</h1>"
                    + "<input id=user><input id=pw type=password value=hidden-password-value><button id=go>Go</button>"
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
        return LoopbackPage(listener: listener, port: port)
    }

    func stop() { listener.cancel() }
}
