import AppKit
import CoincideKit
import LocalAuthentication
import WebKit

/// Signs pages in with the user's Bitwarden passkeys, Coincide acting as the authenticator the way Bitwarden's browser
/// extension does in browsers: `BitwardenPasskeyScript` forwards a main frame's `navigator.credentials.get`, and this
/// answers it once the user clicks Sign In in a sheet and confirms with Touch ID or the Mac's password
/// (`PasskeySignIn`). The origin is WebKit's record of the frame, never the page's word; the private key is read from
/// `bw` for that one signature and never reaches the page.
final class BitwardenPasskeyHandler: NSObject, WKScriptMessageHandlerWithReply {
    /// The browser's password managers; tests replace it.
    var vault: () -> PasskeyVault? = { PreviewSessions.shared.vault.bitwardenPasskeys }
    /// Whether the user can see `webView` and its window can take a sheet now, so the prompt would be seen; tests
    /// replace it. Requests from tabs in the background or browsers running headless go to the notice instead.
    var isShown: (WKWebView) -> Bool = { webView in
        guard let window = webView.window else { return false }
        return window.isVisible && window.attachedSheet == nil && !PreviewParking.shared.isParked(webView)
    }
    /// The sheet and Touch ID for a sign-in in `webView`; tests replace it.
    var makeUI: (WKWebView) -> PasskeySignInUI? = { webView in webView.window.map { PasskeySheetUI(window: $0, webView: webView) } }
    /// Sign-ins waiting on the user, one per web view.
    private var pending: [ObjectIdentifier: PendingSignIn] = [:]

    /// Adds the script and a handler to a new tab's configuration. Call after `PasskeySupport.detectionScript` is added,
    /// so requests nobody here can answer still reach the passkey notice.
    @discardableResult
    static func install(in configuration: WKWebViewConfiguration, handler: BitwardenPasskeyHandler = BitwardenPasskeyHandler()) -> BitwardenPasskeyHandler {
        let controller = configuration.userContentController
        controller.addUserScript(
            WKUserScript(source: BitwardenPasskeyScript.source, injectionTime: .atDocumentStart, forMainFrameOnly: true, in: .page))
        controller.addScriptMessageHandler(handler, contentWorld: .page, name: BitwardenPasskeyScript.messageHandler)
        return handler
    }

    func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage,
        replyHandler: @escaping @MainActor @Sendable (Any?, String?) -> Void) {
        let body = message.body as? [String: Any]
        let kind = body?["kind"] as? String
        guard let webView = message.webView, let origin = Self.origin(of: message.frameInfo) else {
            replyHandler(kind == "available" ? false : WebAuthnReply.fallback.message, nil)
            return
        }
        switch kind {
        case "available":
            replyHandler(vault() != nil, nil)
        case "abort":
            if let id = body?["id"] as? String, let sign = pending[ObjectIdentifier(webView)], sign.id == id { sign.task.cancel() }
            replyHandler(nil, nil)
        case "get":
            start(message.body, from: origin, in: webView, reply: replyHandler)
        default:
            replyHandler(nil, nil)
        }
    }

    /// The main frame's origin when WebAuthn may run there and the frame's document address agrees with it. Other
    /// frames (cross-origin iframes included) get nothing: the script only runs in main frames, and a page can't post
    /// on another frame's behalf.
    static func origin(of frame: WKFrameInfo) -> WebAuthnOrigin? {
        guard frame.isMainFrame else { return nil }
        let security = frame.securityOrigin
        guard let origin = WebAuthnOrigin(scheme: security.protocol, host: security.host, port: security.port),
            let address = frame.request.url, WebAuthnOrigin(url: address) == origin
        else { return nil }
        return origin
    }

    private func start(_ body: Any, from origin: WebAuthnOrigin, in webView: WKWebView,
        reply: @escaping @MainActor @Sendable (Any?, String?) -> Void) {
        guard let request = WebAuthnGetRequest(message: body), let vault = vault(), isShown(webView), let ui = makeUI(webView) else {
            reply(WebAuthnReply.fallback.message, nil)
            return
        }
        let key = ObjectIdentifier(webView)
        guard pending[key] == nil else {
            reply(WebAuthnReply.pending.message, nil)
            return
        }
        let task = Task { @MainActor in
            await PasskeySignIn.answer(request, from: origin, vault: vault, ui: ui)
        }
        let sign = PendingSignIn(id: request.id, task: task)
        pending[key] = sign
        // Leaving the page's origin ends the request, as a browser's does.
        sign.observation = webView.observe(\.url, options: [.new]) { webView, _ in
            MainActor.assumeIsolated {
                if webView.url.flatMap(WebAuthnOrigin.init(url:)) != origin { sign.task.cancel() }
            }
        }
        let limit = request.waitLimit
        sign.timer = Task { @MainActor in
            try? await Task.sleep(for: .seconds(limit))
            sign.task.cancel()
        }
        Task { @MainActor [weak self, weak webView] in
            let answer = await task.value
            sign.timer?.cancel()
            sign.observation = nil
            if let self, self.pending[key] === sign { self.pending.removeValue(forKey: key) }
            // A page that went away gets nothing.
            reply(webView == nil || task.isCancelled ? WebAuthnReply.notAllowed.message : answer.message, nil)
        }
    }
}

/// One sign-in waiting on the user.
private final class PendingSignIn {
    let id: String
    let task: Task<WebAuthnReply, Never>
    var timer: Task<Void, Never>?
    var observation: NSKeyValueObservation?

    init(id: String, task: Task<WebAuthnReply, Never>) {
        self.id = id
        self.task = task
    }
}

/// "Sign in to github.com as octocat with your Bitwarden passkey?" as a sheet on the browser's window, with an
/// account picker when several passkeys match, then Touch ID or the Mac's password.
@MainActor
final class PasskeySheetUI: PasskeySignInUI {
    private weak var window: NSWindow?
    private weak var webView: WKWebView?

    init(window: NSWindow, webView: WKWebView) {
        self.window = window
        self.webView = webView
    }

    /// The sheet's alert for `prompt`, and its account picker when there is one.
    static func alert(for prompt: PasskeySignInPrompt) -> (NSAlert, NSPopUpButton?) {
        let alert = NSAlert()
        alert.messageText = prompt.title
        alert.informativeText = prompt.detail
        if let icon = NSImage(systemSymbolName: "person.badge.key.fill", accessibilityDescription: nil) { alert.icon = icon }
        alert.addButton(withTitle: String(localized: "Sign In"))
        alert.addButton(withTitle: String(localized: "Cancel"))
        guard prompt.choices.count > 1 else { return (alert, nil) }
        let picker = NSPopUpButton(frame: NSRect(x: 0, y: 0, width: 300, height: 26), pullsDown: false)
        // Menu items directly: two accounts may read alike, and addItem(withTitle:) would merge them.
        for choice in prompt.choices { picker.menu?.addItem(NSMenuItem(title: prompt.label(for: choice), action: nil, keyEquivalent: "")) }
        picker.selectItem(at: 0)
        picker.setAccessibilityLabel(String(localized: "Account"))
        alert.accessoryView = picker
        return (alert, picker)
    }

    func confirm(_ prompt: PasskeySignInPrompt) async -> BitwardenPasskey? {
        guard !Task.isCancelled, let window, let webView, webView.window === window, window.attachedSheet == nil else { return nil }
        let (alert, picker) = Self.alert(for: prompt)
        let sheet = SheetHandle(alert: alert, window: window)
        let confirmed = await withTaskCancellationHandler {
            await withCheckedContinuation { (continuation: CheckedContinuation<Bool, Never>) in
                alert.beginSheetModal(for: window) { response in continuation.resume(returning: response == .alertFirstButtonReturn) }
            }
        } onCancel: {
            Task { @MainActor in sheet.end() }
        }
        // Closing the tab or leaving the page while the sheet was up cancels.
        guard confirmed, !Task.isCancelled, self.webView?.window != nil else { return nil }
        return prompt.choices[picker.map { max(0, $0.indexOfSelectedItem) } ?? 0]
    }

    func verifyUser(reason: String) async -> PasskeyUserVerification {
        guard !Task.isCancelled else { return .failed }
        let context = LAContext()
        context.localizedCancelTitle = String(localized: "Cancel")
        var error: NSError?
        guard context.canEvaluatePolicy(.deviceOwnerAuthentication, error: &error) else { return .unavailable }
        let handle = ContextHandle(context: context)
        return await withTaskCancellationHandler {
            await withCheckedContinuation { (continuation: CheckedContinuation<PasskeyUserVerification, Never>) in
                context.evaluatePolicy(.deviceOwnerAuthentication, localizedReason: reason) { @Sendable success, _ in
                    continuation.resume(returning: success ? .verified : .failed)
                }
            }
        } onCancel: {
            handle.context.invalidate()
        }
    }
}

/// Lets a cancelled sign-in close its sheet from the cancellation handler.
private nonisolated final class SheetHandle: @unchecked Sendable {
    private weak var alert: NSAlert?
    private weak var window: NSWindow?

    init(alert: NSAlert, window: NSWindow) {
        self.alert = alert
        self.window = window
    }

    @MainActor func end() {
        guard let alert, let window, window.attachedSheet === alert.window else { return }
        window.endSheet(alert.window, returnCode: .cancel)
    }
}

/// Lets a cancelled sign-in stop the Touch ID or password dialog; `invalidate` may be called from any thread.
private nonisolated final class ContextHandle: @unchecked Sendable {
    let context: LAContext
    init(context: LAContext) { self.context = context }
}
