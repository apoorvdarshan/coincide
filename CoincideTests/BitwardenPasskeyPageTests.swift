import AppKit
import CoincideKit
import CryptoKit
import Testing
import WebKit
@testable import Coincide

/// Coincide's WebAuthn page script and its handler, end to end in a real web view: a simulated https page (no network)
/// asks for a passkey and gets a credential signed with a key generated here. The vault and the prompt are fakes, so no
/// Bitwarden, Keychain, sheet or Touch ID is involved, and the window is offscreen, transparent and never shown.
@MainActor @Suite(.serialized) struct BitwardenPasskeyPageTests {
    /// Signs for real with a generated key, like `BitwardenProvider` after `bw get item`.
    final class SigningVault: PasskeyVault, @unchecked Sendable {
        let key = P256.Signing.PrivateKey()
        let passkey = BitwardenPasskey(itemID: "item-1", itemName: "GitHub", userName: "octocat", rpID: "github.com",
            storedCredentialID: "b64.AQIDBA", credentialID: Data([1, 2, 3, 4]), userHandle: Data([0xa1, 0xb2]), counter: 0, discoverable: true)
        private let lock = NSLock()
        private var listed = 0

        var lists: Int { lock.withLock { listed } }

        func passkeys() async throws -> [BitwardenPasskey] {
            lock.withLock { listed += 1 }
            return [passkey]
        }

        func assertion(for passkey: BitwardenPasskey, rpID: String, clientDataJSON: Data, userVerified: Bool) async throws -> PasskeyAssertion {
            var flags: WebAuthnAssertion.Flags = [.userPresent, .backupEligible, .backedUp]
            if userVerified { flags.insert(.userVerified) }
            let data = WebAuthnAssertion.authenticatorData(rpID: rpID, flags: flags, signCount: 0)
            let signature = try WebAuthnAssertion.signature(authenticatorData: data, clientDataJSON: clientDataJSON, pkcs8: key.derRepresentation)
            return PasskeyAssertion(credentialID: passkey.credentialID, authenticatorData: data, signature: signature, userHandle: passkey.userHandle)
        }
    }

    @MainActor final class ClickingUI: PasskeySignInUI {
        var prompts: [PasskeySignInPrompt] = []
        var accept = true
        /// How many times Touch ID was asked for, and what it answers.
        var verifications = 0
        var verification = PasskeyUserVerification.verified
        func confirm(_ prompt: PasskeySignInPrompt) async -> BitwardenPasskey? {
            prompts.append(prompt)
            return accept ? prompt.choices.first : nil
        }
        func verifyUser(reason: String) async -> PasskeyUserVerification {
            verifications += 1
            return verification
        }
    }

    final class NoticeRecorder: NSObject, WKScriptMessageHandler {
        var kinds: [String] = []
        func userContentController(_ controller: WKUserContentController, didReceive message: WKScriptMessage) {
            kinds.append((message.body as? [String: Any])?["kind"] as? String ?? "?")
        }
    }

    struct Page {
        let webView: WKWebView
        let window: NSWindow
        let handler: BitwardenPasskeyHandler
        let notices: NoticeRecorder

        func run(_ body: String) async throws -> [String: Any] {
            let value = try await webView.callAsyncJavaScript(body, arguments: [:], in: nil, contentWorld: .page)
            return try #require(value as? [String: Any])
        }

        func close() {
            webView.configuration.userContentController.removeAllScriptMessageHandlers()
            webView.removeFromSuperview()
        }
    }

    /// Stands in for WebKit's own `get` and `create`, so requests passed on to the browser never reach the real passkey
    /// API: each rejects as it does without the entitlement, and counts the call.
    static let browserStub = #"""
        (() => {
            window.__browserCalls = 0;
            for (const name of ['get', 'create']) {
                const stub = {[name](options) { window.__browserCalls++; return Promise.reject(new DOMException('stub', 'NotAllowedError')); }}[name];
                Object.defineProperty(CredentialsContainer.prototype, name, {value: stub, writable: true, configurable: true, enumerable: true});
            }
        })();
        """#

    /// A tab's scripts in the order `PreviewSession.makeConfiguration` adds them (after the stub), on a simulated page.
    /// `touchID` stands for Settings' "Confirm passkey sign-ins with Touch ID".
    func open(_ url: String, vault: PasskeyVault?, ui: PasskeySignInUI, touchID: Bool = false,
        html: String = "<!doctype html><title>Sign in</title>") async throws -> Page {
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = .nonPersistent()
        let controller = configuration.userContentController
        controller.addUserScript(WKUserScript(source: Self.browserStub, injectionTime: .atDocumentStart, forMainFrameOnly: false, in: .page))
        controller.addUserScript(WKUserScript(source: PasskeySupport.detectionScript, injectionTime: .atDocumentStart, forMainFrameOnly: false, in: .page))
        let notices = NoticeRecorder()
        controller.add(notices, contentWorld: .page, name: PasskeySupport.messageHandler)
        let handler = BitwardenPasskeyHandler()
        handler.vault = { vault }
        handler.isShown = { _ in true }
        handler.makeUI = { _ in ui }
        handler.alwaysVerifiesUser = { touchID }
        BitwardenPasskeyHandler.install(in: configuration, handler: handler)
        let window = PasskeyFallbackTests.offscreenWindow()
        let webView = WKWebView(frame: window.contentView!.bounds, configuration: configuration)
        window.contentView!.addSubview(webView)
        webView.loadSimulatedRequest(URLRequest(url: try #require(URL(string: url))), responseHTML: html)
        for _ in 0..<500 where webView.isLoading || webView.url == nil || webView.title?.isEmpty != false {
            try await Task.sleep(for: .milliseconds(10))
        }
        return Page(webView: webView, window: window, handler: handler, notices: notices)
    }

    static let signIn = #"""
        const out = {};
        try {
            const credential = await navigator.credentials.get({publicKey: {
                challenge: new Uint8Array(32).fill(5), rpId: 'github.com', userVerification: 'preferred',
                allowCredentials: [{type: 'public-key', id: new Uint8Array([1, 2, 3, 4]), transports: ['internal']}],
            }});
            const b64 = buffer => btoa(String.fromCharCode(...new Uint8Array(buffer))).replace(/\+/g, '-').replace(/\//g, '_').replace(/=+$/, '');
            out.isCredential = credential instanceof PublicKeyCredential;
            out.isAssertion = credential.response instanceof AuthenticatorAssertionResponse;
            out.id = credential.id;
            out.rawId = b64(credential.rawId);
            out.type = credential.type;
            out.attachment = credential.authenticatorAttachment;
            out.clientDataJSON = b64(credential.response.clientDataJSON);
            out.authenticatorData = b64(credential.response.authenticatorData);
            out.signature = b64(credential.response.signature);
            out.userHandle = b64(credential.response.userHandle);
            out.extensions = JSON.stringify(credential.getClientExtensionResults());
            out.json = JSON.stringify(credential);
        } catch (error) {
            out.error = error.name;
            out.isDOMException = error instanceof DOMException;
        }
        return out;
        """#

    @Test func aPageSignsInWithASignatureFromTheVault() async throws {
        let vault = SigningVault()
        let ui = ClickingUI()
        let page = try await open("https://github.com/login", vault: vault, ui: ui)
        defer { page.close() }
        let out = try await page.run(Self.signIn)
        #expect(out["error"] == nil, "\(out)")
        #expect(out["isCredential"] as? Bool == true && out["isAssertion"] as? Bool == true)
        #expect(out["id"] as? String == "AQIDBA" && out["rawId"] as? String == "AQIDBA" && out["type"] as? String == "public-key")
        #expect(out["attachment"] as? String == "platform" && out["userHandle"] as? String == "obI" && out["extensions"] as? String == "{}")
        #expect(ui.prompts.map(\.title) == ["Sign in to github.com as octocat with your Bitwarden passkey?"])
        // By default the click alone signs in, as in Bitwarden's browser extension: no Touch ID for a site that only
        // prefers verification.
        #expect(ui.verifications == 0 && ui.prompts.first?.verifiesUser == false)

        // The client data names the frame's origin as WebKit knows it, and the signature checks out over exactly it.
        let clientData = try #require((out["clientDataJSON"] as? String).flatMap(Base64URL.decode))
        #expect(String(decoding: clientData, as: UTF8.self)
            == #"{"type":"webauthn.get","challenge":"BQUFBQUFBQUFBQUFBQUFBQUFBQUFBQUFBQUFBQUFBQU","origin":"https://github.com","crossOrigin":false}"#)
        let authenticatorData = try #require((out["authenticatorData"] as? String).flatMap(Base64URL.decode))
        // User present, backup eligible and backed up; not user verified.
        #expect(authenticatorData.count == 37 && authenticatorData[32] == 0x19)
        let signature = try P256.Signing.ECDSASignature(derRepresentation: try #require((out["signature"] as? String).flatMap(Base64URL.decode)))
        var signed = authenticatorData
        signed.append(Data(SHA256.hash(data: clientData)))
        #expect(vault.key.publicKey.isValidSignature(signature, for: signed))
        let json = try #require((out["json"] as? String).flatMap { JSONValue.parse(Data($0.utf8)) })
        #expect(json["rawId"]?.string == "AQIDBA" && json["response"]?["signature"]?.string == out["signature"] as? String)
        // Answered here, so the "Passkeys aren't available" notice wasn't asked for.
        #expect(page.notices.kinds.isEmpty)
        #expect(try await page.run("return {calls: window.__browserCalls};")["calls"] as? Int == 0)

        // Bitwarden counts as a platform authenticator that verifies the user; autofill-style sign-in isn't offered.
        let statics = try await page.run("""
            return {uv: await PublicKeyCredential.isUserVerifyingPlatformAuthenticatorAvailable(),
                conditional: await PublicKeyCredential.isConditionalMediationAvailable()};
            """)
        #expect(statics["uv"] as? Bool == true && statics["conditional"] as? Bool == false)
    }

    /// The flags of a page's sign-in, after `ui` answered.
    func signInFlags(_ page: Page, userVerification: String = "preferred") async throws -> (error: String?, flags: UInt8?) {
        let out = try await page.run(Self.signIn.replacingOccurrences(of: "userVerification: 'preferred'", with: "userVerification: '\(userVerification)'"))
        let flags = (out["authenticatorData"] as? String).flatMap(Base64URL.decode).flatMap { $0.count == 37 ? $0[32] : nil }
        return (out["error"] as? String, flags)
    }

    /// A site that requires user verification, or the Touch ID setting, asks for Touch ID after the click, and the
    /// assertion says the user was verified only when that succeeded.
    @Test func touchIDWhenTheSiteRequiresItOrTheSettingIsOn() async throws {
        let ui = ClickingUI()
        let page = try await open("https://github.com/login", vault: SigningVault(), ui: ui)
        defer { page.close() }
        let required = try await signInFlags(page, userVerification: "required")
        #expect(required.error == nil && required.flags == 0x1d && ui.verifications == 1)
        let discouraged = try await signInFlags(page, userVerification: "discouraged")
        #expect(discouraged.error == nil && discouraged.flags == 0x19 && ui.verifications == 1)
        ui.verification = .failed
        let failed = try await signInFlags(page, userVerification: "required")
        #expect(failed.error == "NotAllowedError" && failed.flags == nil && ui.verifications == 2)

        let always = ClickingUI()
        let settingOn = try await open("https://github.com/login", vault: SigningVault(), ui: always, touchID: true)
        defer { settingOn.close() }
        let preferred = try await signInFlags(settingOn)
        #expect(preferred.error == nil && preferred.flags == 0x1d && always.verifications == 1)
        #expect(always.prompts.first?.detail == "You’ll confirm with Touch ID or your Mac password next.")
        always.verification = .failed
        let cancelled = try await signInFlags(settingOn)
        #expect(cancelled.error == "NotAllowedError" && cancelled.flags == nil && always.verifications == 2)
    }

    /// Settings › Browser › Passwords' Touch ID switch starts off and is saved with the browser settings.
    @Test func theTouchIDSwitchIsSavedWithTheBrowserSettings() {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("coincide-passkey-settings-" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: folder) }
        let profile = BrowserProfile(directory: folder, isPersistent: false)
        let sessions = PreviewSessions(profile: profile, bridge: PreviewBridge(directory: folder.appendingPathComponent("bridge")))
        let model = PasswordsSettingsModel(sessions: sessions)
        #expect(!model.confirmsPasskeysWithTouchID && !profile.settings.settings.confirmsPasskeysWithTouchID)
        model.confirmsPasskeysWithTouchID = true
        #expect(profile.settings.settings.confirmsPasskeysWithTouchID && profile.settings.settings.usesBitwardenPasskeys)
        #expect(BrowserSettingsStore(directory: folder).settings.confirmsPasskeysWithTouchID)
        model.confirmsPasskeysWithTouchID = false
        #expect(!BrowserSettingsStore(directory: folder).settings.confirmsPasskeysWithTouchID)
    }

    @Test func cancellingRejectsLikeABrowser() async throws {
        let ui = ClickingUI()
        ui.accept = false
        let page = try await open("https://github.com/login", vault: SigningVault(), ui: ui)
        defer { page.close() }
        let out = try await page.run(Self.signIn)
        #expect(out["error"] as? String == "NotAllowedError" && out["isDOMException"] as? Bool == true)
        #expect(page.notices.kinds.isEmpty)
        // Cancelling the sheet never goes on to Touch ID, even when the site requires it.
        let required = try await signInFlags(page, userVerification: "required")
        #expect(required.error == "NotAllowedError" && ui.verifications == 0)
    }

    @Test func anotherSiteCantClaimTheRPID() async throws {
        let vault = SigningVault()
        let ui = ClickingUI()
        let page = try await open("https://github.com.evil.test/login", vault: vault, ui: ui)
        defer { page.close() }
        let out = try await page.run(Self.signIn)
        #expect(out["error"] as? String == "SecurityError")
        #expect(ui.prompts.isEmpty && vault.lists == 0)
    }

    /// Without Bitwarden (or with no matching passkey) the request goes on to the browser, which fails it as before and
    /// shows the notice; the browser's own answers to the capability checks stand.
    @Test func withoutBitwardenTheNoticeStillAnswers() async throws {
        let ui = ClickingUI()
        let page = try await open("https://github.com/login", vault: nil, ui: ui)
        defer { page.close() }
        let out = try await page.run(Self.signIn)
        #expect(out["error"] as? String == "NotAllowedError" && out["isCredential"] == nil)
        #expect(page.notices.kinds == ["get"] && ui.prompts.isEmpty)
        #expect(try await page.run("return {calls: window.__browserCalls};")["calls"] as? Int == 1)
        let native = try await page.run("return {uv: await PublicKeyCredential.isUserVerifyingPlatformAuthenticatorAvailable()};")
        #expect(native["uv"] as? Bool == false)

        let other = try await open("https://gitlab.com/users/sign_in", vault: SigningVault(), ui: ui)
        defer { other.close() }
        let unmatched = try await other.run(Self.signIn.replacingOccurrences(of: "rpId: 'github.com', ", with: ""))
        #expect(unmatched["error"] as? String == "NotAllowedError" && unmatched["isCredential"] == nil)
        #expect(other.notices.kinds == ["get"] && ui.prompts.isEmpty)
    }

    /// An AbortSignal made in another frame is still a signal, so the request is answered rather than left to the browser.
    @Test func aSignalFromAnotherFrameIsAnswered() async throws {
        let vault = SigningVault()
        let ui = ClickingUI()
        let page = try await open("https://github.com/login", vault: vault, ui: ui)
        defer { page.close() }
        let script = "const frame = document.body.appendChild(document.createElement('iframe'));\n" + Self.signIn.replacingOccurrences(
            of: "navigator.credentials.get({publicKey: {", with: "navigator.credentials.get({signal: new frame.contentWindow.AbortController().signal, publicKey: {")
        let out = try await page.run(script)
        #expect(out["isCredential"] as? Bool == true && out["error"] == nil)
        #expect(ui.prompts.count == 1 && vault.lists == 1)
        #expect(try await page.run("return {calls: window.__browserCalls};")["calls"] as? Int == 0)
    }

    /// Frames other than the main one never reach the vault, even posting to the handler themselves.
    @Test func framesCantUseTheHandler() async throws {
        let vault = SigningVault()
        let ui = ClickingUI()
        let html = """
            <!doctype html><title>Frames</title>
            <iframe srcdoc="<script>
                const handler = window.webkit.messageHandlers.coincideBitwardenPasskey;
                Promise.all([
                    handler.postMessage({kind: 'available'}),
                    handler.postMessage({kind: 'get', id: 'frame1', publicKey: {challenge: 'BQUFBQUFBQUFBQUFBQUFBQUFBQUFBQUFBQUFBQUFBQU', rpId: 'github.com'}}),
                ]).then(([available, reply]) => { top.document.title = 'frame ' + available + ' ' + reply.status; });
            </script>"></iframe>
            """
        let page = try await open("https://github.com/login", vault: vault, ui: ui, html: html)
        defer { page.close() }
        for _ in 0..<500 where page.webView.title?.hasPrefix("frame") != true { try await Task.sleep(for: .milliseconds(10)) }
        #expect(page.webView.title == "frame false fallback")
        #expect(ui.prompts.isEmpty && vault.lists == 0)
        // The main frame posting a malformed request gets the browser's own behavior, nothing more.
        let malformed = try await page.run("""
            return await window.webkit.messageHandlers.coincideBitwardenPasskey.postMessage({kind: 'get', id: 'x y', publicKey: {challenge: 5}});
            """)
        #expect(malformed["status"] as? String == "fallback" && vault.lists == 0)
    }

    /// Tabs of builds without Apple's passkey entitlement get the script in main frames, after the notice's; builds with
    /// it leave pages to the system.
    @Test func tabsGetTheScriptAfterTheNotice() {
        let without = PreviewSession(dataStore: .nonPersistent(), isPrivate: true, passkeys: PasskeySupport { _ in false })
        defer { without.close() }
        let scripts = without.webView.configuration.userContentController.userScripts
        let detection = scripts.firstIndex { $0.source == PasskeySupport.detectionScript }
        let bitwarden = scripts.firstIndex { $0.source == BitwardenPasskeyScript.source }
        #expect(detection != nil && bitwarden != nil && detection! < bitwarden!)
        #expect(bitwarden.map { scripts[$0].isForMainFrameOnly && scripts[$0].injectionTime == .atDocumentStart } == true)
        let entitled = PreviewSession(dataStore: .nonPersistent(), isPrivate: true, passkeys: PasskeySupport { _ in true })
        defer { entitled.close() }
        #expect(!entitled.webView.configuration.userContentController.userScripts.contains { $0.source == BitwardenPasskeyScript.source })
    }

    /// Plain http pages other than localhost don't get the script (WebKit doesn't even give them the credentials API).
    @Test func insecurePagesAreLeftAlone() async throws {
        let page = try await open("http://example.com/", vault: SigningVault(), ui: ClickingUI())
        defer { page.close() }
        let out = try await page.run("""
            const api = typeof CredentialsContainer === 'function';
            return {wrapped: api && String(CredentialsContainer.prototype.get).includes('describeRequest'),
                uv: typeof PublicKeyCredential === 'function' && String(PublicKeyCredential.isUserVerifyingPlatformAuthenticatorAvailable).includes('isAvailable')};
            """)
        #expect(out["wrapped"] as? Bool == false && out["uv"] as? Bool == false)
    }
}
