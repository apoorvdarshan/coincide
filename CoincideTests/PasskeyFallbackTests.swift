import AppKit
import CoincideKit
import Testing
import WebKit
@testable import Coincide

/// The browser's passkey fallback. Pages never reach the real passkey API here: the script test stubs it, and the panel
/// test's page sends options WebKit rejects before any system UI.
@MainActor @Suite(.serialized) struct PasskeyFallbackTests {
    /// Replaces `navigator.credentials.get` and `create` before Coincide's script wraps them. Each records its call
    /// and, by `options.mode`, resolves with, rejects with or throws a value the test can compare by identity.
    static let stubScript = #"""
        (() => {
            const stub = window.__stub = {calls: []};
            const make = name => ({
                [name](options) {
                    stub.calls.push({name, options, self: this, count: arguments.length});
                    const mode = options && options.mode;
                    if (mode === 'throw') throw (stub.thrown = new TypeError('thrown by ' + name));
                    if (mode === 'reject') return (stub.promise = Promise.reject(stub.error = new DOMException('no', 'NotAllowedError')));
                    return (stub.promise = Promise.resolve(stub.result = {id: name + '-' + stub.calls.length}));
                }
            })[name];
            for (const name of ['get', 'create'])
                Object.defineProperty(CredentialsContainer.prototype, name, {value: make(name), writable: true, configurable: true, enumerable: true});
        })();
        """#

    /// In a frame, asks for a passkey once loaded and tells the top page.
    static let framedPage = """
        <!doctype html><meta charset=utf-8><title>Credentials</title>
        <script>
        if (window === top) document.write('<iframe src="/frame"></iframe>');
        else navigator.credentials.get({publicKey: {}, mode: 'resolve'}).then(() => { top.document.title = 'Frame asked'; });
        </script>
        """

    final class Recorder: NSObject, WKScriptMessageHandler {
        var messages: [(kind: String, mainFrame: Bool)] = []
        func userContentController(_ controller: WKUserContentController, didReceive message: WKScriptMessage) {
            messages.append(((message.body as? [String: Any])?["kind"] as? String ?? "?", message.frameInfo.isMainFrame))
        }
    }

    @Test func theScriptPassesEveryCallThroughAndReportsOnlyPasskeyRequests() async throws {
        let page = try await LoopbackPage.start(title: "Credentials", html: Self.framedPage)
        defer { page.stop() }
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = .nonPersistent()
        let controller = configuration.userContentController
        controller.addUserScript(WKUserScript(source: Self.stubScript, injectionTime: .atDocumentStart, forMainFrameOnly: false, in: .page))
        controller.addUserScript(WKUserScript(source: PasskeySupport.detectionScript, injectionTime: .atDocumentStart, forMainFrameOnly: false, in: .page))
        let recorder = Recorder()
        controller.add(recorder, contentWorld: .page, name: PasskeySupport.messageHandler)
        let window = Self.offscreenWindow()
        let webView = WKWebView(frame: window.contentView!.bounds, configuration: configuration)
        window.contentView!.addSubview(webView)
        defer { controller.removeAllScriptMessageHandlers(); webView.removeFromSuperview() }
        webView.load(URLRequest(url: page.url))

        // Injected in every frame: the iframe's request is reported, and its result reached it.
        try await waitFor { webView.title == "Frame asked" }
        try await waitFor { !recorder.messages.isEmpty }
        #expect(recorder.messages.map(\.kind) == ["get"] && recorder.messages.first?.mainFrame == false)
        recorder.messages.removeAll()

        let result = try await webView.callAsyncJavaScript(#"""
            const c = navigator.credentials, stub = window.__stub, out = {};
            const passkey = {publicKey: {challenge: new Uint8Array(16)}, mode: 'resolve'};
            const resolved = c.get(passkey, 'extra');
            out.samePromise = resolved === stub.promise;
            out.sameResult = (await resolved) === stub.result;
            const last = stub.calls[stub.calls.length - 1];
            out.sameOptions = last.options === passkey;
            out.sameThis = last.self === c;
            out.argumentCount = last.count;

            const rejected = c.create({publicKey: {}, mode: 'reject'});
            out.sameRejectedPromise = rejected === stub.promise;
            try { await rejected; out.sameError = 'resolved' } catch (error) { out.sameError = error === stub.error }
            try { c.get({publicKey: {}, mode: 'throw'}); out.sameThrown = 'returned' } catch (error) { out.sameThrown = error === stub.thrown }

            // Not passkey requests: passed through and not reported.
            out.passwordResult = (await c.get({password: true, mode: 'resolve'})) === stub.result;
            await c.get();
            await c.create({mediation: 'silent', publicKey: null, mode: 'resolve'});
            try { c.get({mode: 'throw'}) } catch (error) { out.plainThrown = error === stub.thrown }

            // Still looks like the API it wraps.
            const descriptor = Object.getOwnPropertyDescriptor(CredentialsContainer.prototype, 'get');
            out.shape = [c.get.name, c.create.name, c.get.length, descriptor.enumerable, descriptor.writable, 'prototype' in c.get].join(',');
            return out;
            """#, arguments: [:], in: nil, contentWorld: .page)
        let out = try #require(result as? [String: Any])
        for key in ["samePromise", "sameResult", "sameOptions", "sameThis", "sameRejectedPromise", "sameError", "sameThrown",
            "passwordResult", "plainThrown"] {
            #expect(out[key] as? Bool == true, "\(key): \(String(describing: out[key]))")
        }
        #expect(out["argumentCount"] as? Int == 2)
        #expect(out["shape"] as? String == "get,create,1,true,true,false")
        try await Task.sleep(for: .milliseconds(200))
        #expect(recorder.messages.map(\.kind) == ["get", "create", "get"])
        #expect(recorder.messages.allSatisfy { $0.mainFrame })
    }

    /// The page's request fails as before; the panel shows the notice once, × keeps it away for the site, and the
    /// agent's read says why.
    @Test func thePanelExplainsMissingPasskeysOncePerSite() async throws {
        let html = """
            <!doctype html><meta charset=utf-8><title>Sign in</title>
            <script>
            navigator.credentials.get({publicKey: {}, signal: AbortSignal.abort()})
                .then(() => { document.title = 'resolved'; }, error => { document.title = 'rejected ' + error.name; });
            </script>
            """
        let page = try await LoopbackPage.start(title: "Sign in", html: html)
        defer { page.stop() }
        let harness = BrowserProfileTests.Harness()
        do {
            harness.sessions.passkeys = PasskeySupport { _ in false }
            let id = UUID()
            try await harness.sessions.enableAccess(for: id)
            let panel = PreviewViewController()
            panel.sessions = harness.sessions
            panel.threadID = id
            _ = panel.view
            let session = try #require(panel.session)
            #expect(panel.passkeyBanner.isHidden)
            try session.navigate(page.url.absoluteString)
            try await waitFor { session.webView.title?.hasPrefix("rejected") == true }
            #expect(session.webView.title != "rejected undefined")
            try await waitFor { !panel.passkeyBanner.isHidden }
            #expect(panel.passkeyBanner.text.contains("Try another way"))
            #expect(session.activePasskeyNotice?.site == "127.0.0.1")

            let client = BridgeClient(try #require(harness.sessions.bridge.access(for: id)))
            let read = try await client.send(["action": "read"])
            #expect(read["passkey"]?.string == PasskeySupport.agentNote)

            // Another tab: the notice belongs to the tab that asked.
            let first = session.activeTab!
            session.newTab()
            #expect(panel.passkeyBanner.isHidden)
            session.select(first)
            #expect(!panel.passkeyBanner.isHidden)

            panel.passkeyBanner.dismissButton.performClick(nil)
            #expect(panel.passkeyBanner.isHidden && session.passkeyNotice.dismissedSites == ["127.0.0.1"])
            try session.navigate(page.url.absoluteString + "?again")
            try await waitFor {
                session.webView.url?.query == "again" && session.webView.title?.hasPrefix("rejected") == true && !session.webView.isLoading
            }
            try await Task.sleep(for: .milliseconds(200))
            #expect(panel.passkeyBanner.isHidden)
            // The agent still learns why, page by page.
            #expect(try await client.send(["action": "read"])["passkey"]?.string == PasskeySupport.agentNote)
        }
        await harness.tearDown()
    }

    /// A build signed with the entitlement installs nothing: pages see the untouched API and the panel stays quiet.
    @Test func buildsWithTheEntitlementSkipTheFallback() async throws {
        let session = PreviewSession(dataStore: .nonPersistent(), isPrivate: true, passkeys: PasskeySupport { _ in true })
        defer { session.close() }
        let scripts = session.webView.configuration.userContentController.userScripts.map(\.source)
        #expect(!scripts.contains(PasskeySupport.detectionScript))
        let without = PreviewSession(dataStore: .nonPersistent(), isPrivate: true, passkeys: PasskeySupport { _ in false })
        defer { without.close() }
        #expect(without.webView.configuration.userContentController.userScripts.map(\.source).contains(PasskeySupport.detectionScript))
    }

    @Test func theNoticeWrapsAndKeepsItsDismissButtonInside() throws {
        for width: CGFloat in [300, 420, 640] {
            let banner = PreviewPasskeyBanner()
            let host = NSView(frame: NSRect(x: 0, y: 0, width: width, height: 400))
            banner.translatesAutoresizingMaskIntoConstraints = false
            host.addSubview(banner)
            NSLayoutConstraint.activate([
                banner.leadingAnchor.constraint(equalTo: host.leadingAnchor), banner.trailingAnchor.constraint(equalTo: host.trailingAnchor),
                banner.topAnchor.constraint(equalTo: host.topAnchor),
            ])
            // Wrapping labels settle their height on the second pass, as in the panel.
            host.layoutSubtreeIfNeeded()
            host.layoutSubtreeIfNeeded()
            let button = banner.dismissButton.convert(banner.dismissButton.bounds, to: banner)
            #expect(banner.bounds.width == width)
            #expect(banner.bounds.contains(button), "× outside the banner at \(width)")
            #expect(button.maxX > banner.bounds.width - 24, "× not at the trailing edge at \(width)")
            // Wraps to several lines rather than truncating; the whole message stays readable.
            #expect(banner.bounds.height > 40 && banner.bounds.height < 140, "height \(banner.bounds.height) at \(width)")
            #expect(banner.dismissButton.accessibilityLabel() == "Dismiss")
        }
        #expect(NSImage(systemSymbolName: "person.badge.key.fill", accessibilityDescription: nil) != nil)
        try renderPNGs()
    }

    /// Writes the notice in light and dark when `COINCIDE_PASSKEY_PNG_DIR` names a folder.
    private func renderPNGs() throws {
        guard let folder = ProcessInfo.processInfo.environment["COINCIDE_PASSKEY_PNG_DIR"], !folder.isEmpty else { return }
        try FileManager.default.createDirectory(atPath: folder, withIntermediateDirectories: true)
        for (suffix, name) in [("light", NSAppearance.Name.aqua), ("dark", .darkAqua)] { for width: CGFloat in [300, 420, 640] {
            let window = Self.offscreenWindow(size: NSSize(width: width, height: 160))
            window.appearance = NSAppearance(named: name)
            let root = window.contentView!
            root.wantsLayer = true
            root.effectiveAppearance.performAsCurrentDrawingAppearance { root.layer?.backgroundColor = Theme.contentBackground.cgColor }
            let banner = PreviewPasskeyBanner()
            banner.translatesAutoresizingMaskIntoConstraints = false
            root.addSubview(banner)
            NSLayoutConstraint.activate([
                banner.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 8),
                banner.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -8),
                banner.topAnchor.constraint(equalTo: root.topAnchor, constant: 8),
            ])
            root.layoutSubtreeIfNeeded()
            root.layoutSubtreeIfNeeded()
            let rep = try #require(root.bitmapImageRepForCachingDisplay(in: root.bounds))
            root.effectiveAppearance.performAsCurrentDrawingAppearance { root.cacheDisplay(in: root.bounds, to: rep) }
            try rep.representation(using: .png, properties: [:])?
                .write(to: URL(fileURLWithPath: folder).appendingPathComponent("passkey-notice-\(Int(width))-\(suffix).png"))
        } }
    }

    /// A borderless window far off screen and fully transparent, never ordered in.
    static func offscreenWindow(size: NSSize = NSSize(width: 800, height: 600)) -> NSWindow {
        let window = NSWindow(contentRect: NSRect(origin: NSPoint(x: -20_000, y: -20_000), size: size), styleMask: [.borderless],
            backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.alphaValue = 0
        window.contentView = NSView(frame: NSRect(origin: .zero, size: size))
        return window
    }

    private func waitFor(_ condition: () -> Bool) async throws {
        for _ in 0..<500 {
            if condition() { return }
            try await Task.sleep(for: .milliseconds(10))
        }
        Issue.record("Timed out waiting")
    }
}
