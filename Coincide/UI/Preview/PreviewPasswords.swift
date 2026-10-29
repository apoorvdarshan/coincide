import AppKit
import CoincideKit
import WebKit

/// A sign-in the user submitted, waiting for Save, Never or Not Now. The password stays in memory until then.
struct SavePrompt {
    let url: URL
    let username: String
    fileprivate let password: String
    var site: String { WebDomain.siteOrHost(url.host ?? "") }
}

/// Receives sign-in submissions from Coincide's script world. Holds its session weakly; WebKit retains the handler.
final class LoginSubmitHandler: NSObject, WKScriptMessageHandler {
    static let name = "coincideLogin"
    weak var session: PreviewSession?

    func userContentController(_ controller: WKUserContentController, didReceive message: WKScriptMessage) {
        guard message.frameInfo.isMainFrame, let session, let body = message.body as? [String: Any],
            let password = body["password"] as? String, !password.isEmpty, password.utf8.count <= 4096,
            let url = session.webView.url, PreviewCommand.url(url.absoluteString) != nil
        else { return }
        let username = String((body["username"] as? String ?? "").prefix(500))
        session.onLoginSubmitted?(url, username, password)
    }
}

extension PreviewSession {
    struct FillResult {
        var fields: [String]
        var filledCode: Bool
    }

    /// Types a login into the page: the username and password on a sign-in page, the one-time code on a two-factor
    /// page. Values go to WebKit as script arguments in Coincide's own script world, never into the page's scripts or
    /// any response.
    func fill(_ secret: LoginSecret, credentials: Bool = true, code: Bool = true) async throws -> FillResult {
        var arguments = secret.fillArguments
        arguments["wantCredentials"] = credentials
        if !code { arguments["loginCode"] = "" }
        let value = try await webView.callAsyncJavaScript(Self.fillScript, arguments: arguments, in: nil, contentWorld: .defaultClient)
        let fields = ((value as? [String: Any])?["filled"] as? [String]) ?? []
        return FillResult(fields: fields.filter { $0 != "oneTimeCode" }, filledCode: fields.contains("oneTimeCode"))
    }

    func answerSavePrompt(save: Bool, never: Bool, provider: CoincideLoginProvider, settings: BrowserSettingsStore) {
        guard let prompt = savePrompt else { return }
        savePrompt = nil
        if save { _ = try? provider.save(url: prompt.url, username: prompt.username, password: prompt.password) }
        if never, !settings.settings.neverSaveSites.contains(prompt.site) { settings.update { $0.neverSaveSites.append(prompt.site) } }
    }

    static let fillScript = #"""
        const usable = el => el && el.getClientRects().length && !el.disabled && !el.readOnly;
        const inputs = [...document.querySelectorAll('input')].filter(usable);
        const describe = el => [el.name, el.id, el.getAttribute('aria-label'), el.placeholder, el.autocomplete].join(' ');
        const codeField = inputs.find(el => el.autocomplete === 'one-time-code')
            || inputs.find(el => el.type !== 'password' && /(^|[^a-z])(otp|totp|2fa|mfa|one.?time|verification.?code|auth.?code|security.?code)([^a-z]|$)/i.test(describe(el)));
        const passwords = inputs.filter(el => el.type === 'password');
        const password = passwords.find(el => !/new|confirm|repeat/i.test(describe(el))) || passwords[0];
        window.__coincideSecretFields = window.__coincideSecretFields || new WeakSet();
        function set(el, value) {
            el.focus();
            Object.getOwnPropertyDescriptor(HTMLInputElement.prototype, 'value').set.call(el, value);
            el.dispatchEvent(new Event('input', {bubbles: true}));
            el.dispatchEvent(new Event('change', {bubbles: true}));
        }
        const filled = [];
        const textual = el => ['text', 'email', 'tel', ''].includes(el.type) && el !== codeField;
        if (wantCredentials && password) {
            const scope = password.form || document;
            const before = [...scope.querySelectorAll('input')].filter(el => usable(el) && textual(el)
                && (el.compareDocumentPosition(password) & Node.DOCUMENT_POSITION_FOLLOWING));
            const user = before.find(el => el.autocomplete === 'username') || before[before.length - 1];
            if (user && loginUsername) { set(user, loginUsername); filled.push('username'); }
            set(password, loginPassword);
            window.__coincideSecretFields.add(password);
            filled.push('password');
        } else if (wantCredentials && loginUsername) {
            // A page that asks for the username first.
            const user = inputs.find(el => textual(el) && (el.autocomplete === 'username' || el.type === 'email' || /user|email|login|account/i.test(describe(el))));
            if (user) { set(user, loginUsername); filled.push('username'); }
        }
        if (loginCode && codeField) {
            set(codeField, loginCode);
            window.__coincideSecretFields.add(codeField);
            filled.push('oneTimeCode');
        }
        return {filled};
        """#

    static let maskScript = #"""
        const fields = window.__coincideSecretFields;
        if (!fields) return 0;
        let count = 0;
        for (const el of document.querySelectorAll('input')) {
            if (!fields.has(el) || el.type === 'password') continue;
            if (mask) el.style.setProperty('-webkit-text-security', 'disc', 'important');
            else el.style.removeProperty('-webkit-text-security');
            count++;
        }
        return count;
        """#

    /// Posts a sign-in form's username and password when the user submits it, unless Coincide filled them.
    static let loginWatcherScript = #"""
        (() => {
            let last = 0;
            function capture(form) {
                const scope = form || document;
                const password = [...scope.querySelectorAll('input[type=password]')].find(el => el.value);
                if (!password || (window.__coincideSecretFields && window.__coincideSecretFields.has(password))) return;
                if (Date.now() - last < 1500) return;
                last = Date.now();
                const users = [...scope.querySelectorAll('input')].filter(el => ['text', 'email', 'tel'].includes(el.type) && el.value
                    && (el.compareDocumentPosition(password) & Node.DOCUMENT_POSITION_FOLLOWING));
                const user = users.find(el => el.autocomplete === 'username') || users[users.length - 1];
                window.webkit.messageHandlers.coincideLogin.postMessage({username: user ? user.value : '', password: password.value});
            }
            document.addEventListener('submit', event => capture(event.target), true);
            document.addEventListener('click', event => {
                const button = event.target.closest && event.target.closest('button, input[type=submit]');
                if (button && (button.type === 'submit' || button.form)) capture(button.form);
            }, true);
            document.addEventListener('keydown', event => {
                if (event.key === 'Enter' && event.target && event.target.type === 'password') capture(event.target.form);
            }, true);
        })();
        """#
}

extension PreviewSessions {
    /// `fill-login` from an agent: find the login, ask the user the first time for this site and item, then type it.
    /// The reply names the item and username; never the password or code.
    func fillLogin(threadID id: UUID, hint: String?) async throws -> JSONValue {
        let session = session(for: id)
        session.lastAgentUse = Date()
        guard let page = session.webView.url, let host = page.host else { throw LoginFillError.notAWebPage }
        let item = try await vault.resolve(page: page, hint: hint)
        if !vault.isApproved(item, page: page, threadID: id) {
            let site = WebDomain.siteOrHost(host)
            let waiting = Task { await session.loginApproval.ask(site: site, item: item) }
            await Task.yield()
            if !reveal(id) {
                notifyUser(id, String(localized: "The agent wants to sign in to \(site) with \(item.title)."))
            }
            let approval = await waiting.value
            vault.record(approval, for: item, page: page, threadID: id)
            guard approval != .deny else { throw LoginFillError.denied(site: site) }
        }
        let secret = try await vault.secret(for: item)
        // The page may have moved on while the user decided; fill only where the login still matches.
        guard let current = session.webView.url, LoginMatcher.match(item, page: current) != nil else {
            throw LoginFillError.noMatch(site: WebDomain.siteOrHost(session.webView.url?.host ?? host))
        }
        let result = try await session.fill(secret)
        var reply: [String: JSONValue] = [
            "filled": .bool(!result.fields.isEmpty || result.filledCode),
            "item": .string(item.title),
            "source": .string(item.source.displayName),
            "fields": .array(result.fields.map(JSONValue.string)),
            "oneTimeCode": .string(result.filledCode ? "filled" : secret.hasTOTP ? "available" : "none"),
        ]
        if !secret.username.isEmpty { reply["username"] = .string(secret.username) }
        return .object(reply)
    }

    /// The user's own sign-in from the address bar's key: no approval needed.
    func autofill(_ item: LoginItem, in session: PreviewSession, codeOnly: Bool) async throws {
        let secret = try await vault.secret(for: item)
        guard let page = session.webView.url, LoginMatcher.match(item, page: page) != nil else { throw LoginFillError.notAWebPage }
        _ = try await session.fill(secret, credentials: !codeOnly, code: true)
    }

    /// After the user submits a sign-in, offers to save it in Coincide when that's turned on and it's new.
    func offerToSave(_ url: URL, username: String, password: String, in session: PreviewSession) {
        let settings = profile.settings.settings
        guard !session.isPrivate, settings.passwordManagers.contains(.coincide), settings.offersToSaveLogins,
            let host = url.host, !settings.neverSaveSites.contains(WebDomain.siteOrHost(host)),
            !profile.logins.isSaved(url: url, username: username, password: password)
        else { return }
        session.savePrompt = SavePrompt(url: url, username: username, password: password)
    }
}
