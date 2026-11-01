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
    @Test func thePanelExplainsMissingPasskeysAndRemembersItsDismissal() async throws {
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
            let warnings = AppStore(directory: harness.folder.appendingPathComponent("warnings"))
            let sessions = PreviewSessions(profile: harness.profile,
                bridge: PreviewBridge(directory: harness.folder.appendingPathComponent("passkey-bridge")), warningStore: warnings)
            defer { sessions.stop() }
            sessions.passkeys = PasskeySupport { _ in false }
            let id = UUID()
            try await sessions.enableAccess(for: id)
            let panel = PreviewViewController()
            panel.sessions = sessions
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

            let client = BridgeClient(try #require(sessions.bridge.access(for: id)))
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
            #expect(warnings.isWarningDismissed(WarningDismissalKey.passkeysUnavailable))
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

    @Test func theCapabilityWarningStaysDismissedAcrossBrowsersAndAppRestarts() async throws {
        let folder = TemporaryDirectory("persistent-passkey-warning")
        let directory = folder.url.appendingPathComponent("app")
        let warnings = AppStore(directory: directory)
        let html = """
            <!doctype html><meta charset=utf-8><title>Sign in</title>
            <script>
            navigator.credentials.get({publicKey: {}, signal: AbortSignal.abort()})
                .catch(error => { document.title = 'rejected ' + error.name; });
            </script>
            """
        let page = try await LoopbackPage.start(title: "Sign in", html: html)
        defer { page.stop() }
        let first = PreviewSession(dataStore: .nonPersistent(), isPrivate: true,
            passkeys: PasskeySupport { _ in false }, warningStore: warnings)
        let other = PreviewSession(dataStore: .nonPersistent(), isPrivate: true,
            passkeys: PasskeySupport { _ in false }, warningStore: warnings)
        defer { first.close(); other.close() }
        try first.navigate(page.url.absoluteString)
        try other.navigate(page.url.absoluteString)
        try await waitFor { first.activePasskeyNotice != nil && other.activePasskeyNotice != nil }
        var otherUpdates = 0
        other.onChange = { otherUpdates += 1 }
        first.dismissPasskeyNotice()
        #expect(first.activePasskeyNotice == nil)
        #expect(other.activePasskeyNotice == nil && other.passkeyNotice.notice == nil)
        #expect(otherUpdates > 0) // visible sibling panels are told to refresh immediately
        #expect(first.activeTab.passkeyRequested && other.activeTab.passkeyRequested)
        #expect(warnings.settings.dismissedWarnings == [WarningDismissalKey.passkeysUnavailable])
        first.close(); other.close()

        // Construct a new store from disk: no controller/session memory is reused.
        let reopened = AppStore(directory: directory)
        #expect(reopened.isWarningDismissed(WarningDismissalKey.passkeysUnavailable))
        let fresh = PreviewSession(dataStore: .nonPersistent(), isPrivate: true,
            passkeys: PasskeySupport { _ in false }, warningStore: reopened)
        defer { fresh.close() }
        try fresh.navigate(page.url.absoluteString + "?restarted")
        try await waitFor { fresh.activeTab.passkeyRequested && fresh.webView.title?.hasPrefix("rejected") == true }
        #expect(fresh.activePasskeyNotice == nil && fresh.passkeyNotice.notice == nil)
        let read = try await fresh.perform(.read(), directory: folder.url)
        #expect(read["passkey"]?.string == PasskeySupport.agentNote)
    }

    /// Rejects its passkey request like the panel test's page, then shows its cookies in the title, so a reload after
    /// the import is visible.
    static let cookiePage = """
        <!doctype html><meta charset=utf-8><title>Sign in</title>
        <script>
        navigator.credentials.get({publicKey: {}, signal: AbortSignal.abort()})
            .catch(error => { document.title = 'rejected ' + (document.cookie || 'signed out'); });
        </script>
        """

    /// "Open in Safari", then "Import Sign-In": the page goes to the user's browser, and the site's sign-in comes back
    /// into the shared profile and the page reloads with it. Nothing real opens or is read: the browser is a fake.
    @Test func theNoticeOpensThePageInTheUsersBrowserAndImportsItsSignInBack() async throws {
        let page = try await LoopbackPage.start(title: "Sign in", html: Self.cookiePage)
        defer { page.stop() }
        let harness = BrowserProfileTests.Harness()
        do {
            let warnings = AppStore(directory: harness.folder.appendingPathComponent("warnings"))
            let sessions = PreviewSessions(profile: harness.profile,
                bridge: PreviewBridge(directory: harness.folder.appendingPathComponent("handoff-bridge")), warningStore: warnings)
            defer { sessions.stop() }
            let fake = FakeHandoff()
            fake.outcomes = [.found([ImportedCookie(domain: "127.0.0.1", name: "sid", value: "imported-session", path: "/",
                expires: Date().addingTimeInterval(3600), isSecure: false, isHTTPOnly: false, sameSite: nil)])]
            sessions.passkeys = PasskeySupport { _ in false }
            sessions.passkeyHandoff = fake.services
            let panel = PreviewViewController()
            panel.sessions = sessions
            panel.threadID = UUID()
            _ = panel.view
            let session = try #require(panel.session)
            let banner = panel.passkeyBanner
            try session.navigate(page.url.absoluteString)
            try await waitFor { !banner.isHidden && session.webView.title?.hasPrefix("rejected") == true }
            #expect(session.webView.title == "rejected signed out")
            #expect(banner.text.contains("Sign in with your passkey in Safari, then import that sign-in here."))
            #expect(banner.text.contains("Try another way"))
            #expect(banner.actionTitle == "Open in Safari")
            #expect(banner.actionButton.accessibilityLabel() == "Open in Safari")

            banner.actionButton.performClick(nil)
            #expect(fake.opened.map { $0.url } == [page.url] && fake.opened.map { $0.browser } == [FakeHandoff.safari])
            #expect(banner.text == "Signed in to 127.0.0.1 in Safari? Import that sign-in to use it here.")
            #expect(banner.actionTitle == "Import Sign-In")

            banner.actionButton.performClick(nil)
            try await waitFor { session.activePasskeyNotice?.stage == .imported }
            #expect(fake.reads.map { $0.site } == ["127.0.0.1"] && fake.reads.map { $0.browser } == ["safari"])
            let cookies = await harness.profile.sharedDataStore.httpCookieStore.allCookies()
            #expect(cookies.contains { $0.name == "sid" && $0.value == "imported-session" })
            // Reloaded with the sign-in. The page asking for a passkey again keeps the confirmation.
            try await waitFor { session.webView.title == "rejected sid=imported-session" }
            try await Task.sleep(for: .milliseconds(200))
            #expect(session.activePasskeyNotice?.stage == .imported)
            #expect(banner.text.hasPrefix("Imported your 127.0.0.1 sign-in from Safari and reloaded the page."))
            #expect(banner.actionTitle == "Import Again")

            // × closes the confirmation for this site but leaves the notice on for the next one.
            banner.dismissButton.performClick(nil)
            #expect(banner.isHidden && session.passkeyNotice.dismissedSites == ["127.0.0.1"])
            #expect(!warnings.isWarningDismissed(WarningDismissalKey.passkeysUnavailable))
            #expect(fake.importsShown == 0 && fake.fullDiskAccessRequests == 0)
        }
        await harness.tearDown()
    }

    /// Each failed import says why and offers the next step; nothing is imported or reloaded.
    @Test func failedImportsSayWhyAndOfferTheNextStep() async throws {
        let page = try await LoopbackPage.start(title: "Sign in", html: Self.cookiePage)
        defer { page.stop() }
        let folder = TemporaryDirectory("passkey-handoff-failures")
        let warnings = AppStore(directory: folder.url.appendingPathComponent("app"))
        let fake = FakeHandoff()
        fake.browser = FakeHandoff.chrome
        fake.outcomes = [.nothingFound, .problem(.keyUnavailable), .problem(.needsFullDiskAccess)]
        let session = PreviewSession(dataStore: .nonPersistent(), isPrivate: true, passkeys: PasskeySupport { _ in false },
            passkeyHandoff: fake.services, warningStore: warnings)
        defer { session.close() }
        func content() -> PreviewPasskeyBanner.Content? { session.activePasskeyNotice.map { PreviewPasskeyBanner.content(for: $0) } }
        try session.navigate(page.url.absoluteString)
        try await waitFor { session.activePasskeyNotice != nil }
        #expect(content()?.button == "Open in Google Chrome" && content()?.action == .open)
        // Nothing to import before the page was opened there.
        session.importPasskeySignIn()
        #expect(fake.reads.isEmpty && session.activePasskeyNotice?.stage == .unavailable)

        session.openPasskeyPageInBrowser()
        // Chrome saves new cookies only every half minute, and asks for its Keychain key.
        #expect(content()?.message == "Signed in to 127.0.0.1 in Google Chrome? Wait half a minute for it to save the sign-in, then import it here.")
        session.importPasskeySignIn()
        #expect(session.activePasskeyNotice?.stage == .importing && content()?.button == nil)
        #expect(content()?.message.contains("choose Allow") == true)
        try await waitFor { session.activePasskeyNotice?.stage == .failed(.nothingFound) }
        #expect(content() == PreviewPasskeyBanner.Content(
            message: "Google Chrome has no sign-in for 127.0.0.1 yet. Sign in there, wait a moment, then try again.",
            button: "Try Again", action: .importSignIn))

        session.importPasskeySignIn()
        try await waitFor { session.activePasskeyNotice?.stage == .failed(.problem(.keyUnavailable)) }
        #expect(content()?.message.hasPrefix("Google Chrome’s Keychain key wasn’t available") == true && content()?.button == "Try Again")

        session.importPasskeySignIn()
        try await waitFor { session.activePasskeyNotice?.stage == .failed(.problem(.needsFullDiskAccess)) }
        #expect(content()?.button == "Allow Full Disk Access…" && content()?.action == .allowFullDiskAccess)
        session.allowFullDiskAccessForPasskeyImport()
        #expect(fake.fullDiskAccessRequests == 1 && session.activePasskeyNotice?.stage == .awaitingImport)
        #expect(fake.reads.map { $0.browser } == ["chrome", "chrome", "chrome"])
        #expect(await session.webView.configuration.websiteDataStore.httpCookieStore.allCookies().isEmpty)
        try await waitFor { session.webView.title == "rejected signed out" }

        // × before a sign-in was imported acknowledges the limitation, as before.
        session.dismissPasskeyNotice()
        #expect(warnings.isWarningDismissed(WarningDismissalKey.passkeysUnavailable))
    }

    /// Without a browser to name, "Open" uses whatever macOS opens links in; a browser Coincide can't import from by
    /// itself gets Settings' import, where the user picks one.
    @Test func browsersCoincideCantImportFromGoThroughSettings() async throws {
        let page = try await LoopbackPage.start(title: "Sign in", html: Self.cookiePage)
        defer { page.stop() }
        let folder = TemporaryDirectory("passkey-handoff-settings")
        let fake = FakeHandoff()
        fake.browser = nil
        let session = PreviewSession(dataStore: .nonPersistent(), isPrivate: true, passkeys: PasskeySupport { _ in false },
            passkeyHandoff: fake.services, warningStore: AppStore(directory: folder.url.appendingPathComponent("app")))
        defer { session.close() }
        func content() -> PreviewPasskeyBanner.Content? { session.activePasskeyNotice.map { PreviewPasskeyBanner.content(for: $0) } }
        try session.navigate(page.url.absoluteString)
        try await waitFor { session.activePasskeyNotice != nil }
        #expect(content()?.button == "Open in Default Browser")
        #expect(content()?.message.contains("Sign in with your passkey in your browser, then import that sign-in here.") == true)
        session.openPasskeyPageInBrowser()
        #expect(fake.opened.count == 1 && fake.opened.first?.browser == nil && fake.opened.first?.url == page.url)
        #expect(content() == PreviewPasskeyBanner.Content(
            message: "Signed in to 127.0.0.1 in your browser? Import that sign-in to use it here.",
            button: "Import Sign-In…", action: .importSignIn))
        session.importPasskeySignIn()
        #expect(fake.importsShown == 1 && fake.reads.isEmpty && session.activePasskeyNotice?.stage == .awaitingImport)

        // Named, but not one the importer reads.
        let duck = PasskeyHandoff.Browser(name: "DuckDuckGo", appURL: URL(fileURLWithPath: "/Applications/DuckDuckGo.app"), importable: nil)
        let opened = PasskeyNoticeState.Notice(tabID: "tab-1", site: "example.com", browser: duck, stage: .awaitingImport)
        #expect(PreviewPasskeyBanner.content(for: opened) == PreviewPasskeyBanner.Content(
            message: "Signed in to example.com in DuckDuckGo? Import that sign-in to use it here.",
            button: "Import Sign-In…", action: .importSignIn))
        #expect(PreviewPasskeyBanner.content(for: .init(tabID: "tab-1", site: "example.com", browser: duck)).button == "Open in DuckDuckGo")
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

    @Test func theNoticeWrapsAndKeepsItsButtonsInside() throws {
        let preview = PasskeyHandoff.Browser(name: "Safari Technology Preview",
            appURL: URL(fileURLWithPath: "/Applications/Safari Technology Preview.app"), importable: BrowserCatalog.all.first { $0.id == "safari-tp" })
        typealias Notice = PasskeyNoticeState.Notice
        let notices: [Notice?] = [nil,
            Notice(tabID: "tab-1", site: "accounts.example.com", browser: preview),
            Notice(tabID: "tab-1", site: "accounts.example.com", browser: FakeHandoff.chrome, stage: .importing),
            Notice(tabID: "tab-1", site: "accounts.example.com", browser: preview, stage: .imported)]
        for notice in notices { for width: CGFloat in [300, 420, 640] {
            let banner = PreviewPasskeyBanner()
            if let notice { banner.show(notice) }
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
            if banner.actionTitle != nil {
                let action = banner.actionButton.convert(banner.actionButton.bounds, to: banner)
                #expect(banner.bounds.contains(action) && action.maxX <= button.minX, "\(banner.actionTitle ?? "") outside at \(width)")
                #expect(action.height == 28, "\(banner.actionTitle ?? "") squashed at \(width)")
            }
            // Wraps to several lines rather than truncating; the whole message stays readable.
            #expect(banner.bounds.height > 40 && banner.bounds.height < 240, "height \(banner.bounds.height) at \(width)")
            #expect(banner.dismissButton.accessibilityLabel() == "Dismiss")
        } }
        #expect(NSImage(systemSymbolName: "person.badge.key.fill", accessibilityDescription: nil) != nil)
        try renderPNGs()
    }

    /// Writes the notice in light and dark when `COINCIDE_PASSKEY_PNG_DIR` names a folder.
    private func renderPNGs() throws {
        guard let folder = ProcessInfo.processInfo.environment["COINCIDE_PASSKEY_PNG_DIR"], !folder.isEmpty else { return }
        try FileManager.default.createDirectory(atPath: folder, withIntermediateDirectories: true)
        let stages: [(String, PasskeyNoticeState.Notice)] = [
            ("open", .init(tabID: "tab-1", site: "github.com", browser: FakeHandoff.safari)),
            ("import", .init(tabID: "tab-1", site: "github.com", browser: FakeHandoff.safari, stage: .awaitingImport)),
        ]
        for (suffix, name) in [("light", NSAppearance.Name.aqua), ("dark", .darkAqua)] { for width: CGFloat in [300, 420, 640] { for (stage, notice) in stages {
            let window = Self.offscreenWindow(size: NSSize(width: width, height: 240))
            window.appearance = NSAppearance(named: name)
            let root = window.contentView!
            root.wantsLayer = true
            root.effectiveAppearance.performAsCurrentDrawingAppearance { root.layer?.backgroundColor = Theme.contentBackground.cgColor }
            let banner = PreviewPasskeyBanner()
            banner.show(notice)
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
                .write(to: URL(fileURLWithPath: folder).appendingPathComponent("passkey-notice-\(stage)-\(Int(width))-\(suffix).png"))
        } } }
    }

    /// Stands in for the user's browser and its data: records what the notice opens and asks for, and answers imports
    /// from `outcomes` in turn.
    final class FakeHandoff {
        static let safari = PasskeyHandoff.Browser(name: "Safari", appURL: URL(fileURLWithPath: "/Applications/Safari.app"),
            importable: BrowserCatalog.all.first { $0.id == "safari" })
        static let chrome = PasskeyHandoff.Browser(name: "Google Chrome", appURL: URL(fileURLWithPath: "/Applications/Google Chrome.app"),
            importable: BrowserCatalog.all.first { $0.id == "chrome" })

        var browser: PasskeyHandoff.Browser? = FakeHandoff.safari
        var outcomes: [PasskeyHandoff.Outcome] = []
        private(set) var opened: [(url: URL, browser: PasskeyHandoff.Browser?)] = []
        private(set) var reads: [(site: String, browser: String)] = []
        private(set) var fullDiskAccessRequests = 0
        private(set) var importsShown = 0

        var services: PasskeyHandoffServices {
            PasskeyHandoffServices(
                defaultBrowser: { self.browser },
                open: { self.opened.append((url: $0, browser: $1)) },
                readSignIn: { site, definition in
                    self.reads.append((site: site, browser: definition.id))
                    return self.outcomes.isEmpty ? .nothingFound : self.outcomes.removeFirst()
                },
                requestFullDiskAccess: { self.fullDiskAccessRequests += 1 },
                showImport: { self.importsShown += 1 })
        }
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
