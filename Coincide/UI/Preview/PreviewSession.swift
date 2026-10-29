import AppKit
import CoincideKit
import WebKit

/// Each thread owns a browser: its own WebKit view with its page and back/forward history, over the shared profile or
/// a private store (`BrowserProfile`). Switching panels never retargets an agent's commands. A browser not shown in the
/// panel stays alive offscreen (`PreviewParking`), so agents can use it headless.
final class PreviewSession: NSObject, WKNavigationDelegate, WKUIDelegate {
    let webView: WKWebView
    /// Whether the session uses temporary storage of its own rather than the shared profile.
    let isPrivate: Bool
    /// The agent's open "your turn" request, shown as a banner in the panel.
    let userTurn = UserTurnGate()
    /// When an agent last sent this browser a command, for the panel's footer.
    var lastAgentUse: Date?
    /// When the session was last shown or used, so the least recently used one can be closed first.
    var lastUse = Date()
    var onChange: (() -> Void)?
    var onNavigate: ((URL, String?) -> Void)?
    private(set) var error: String?
    private var observations: [NSKeyValueObservation] = []

    convenience override init() {
        self.init(dataStore: .nonPersistent(), isPrivate: true)
    }

    init(dataStore: WKWebsiteDataStore, isPrivate: Bool) {
        self.isPrivate = isPrivate
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = dataStore
        configuration.mediaTypesRequiringUserActionForPlayback = .all
        webView = WKWebView(frame: NSRect(x: 0, y: 0, width: 800, height: 600), configuration: configuration)
        super.init()
        webView.navigationDelegate = self
        webView.uiDelegate = self
        webView.allowsBackForwardNavigationGestures = true
        for key in [\WKWebView.isLoading, \WKWebView.canGoBack, \WKWebView.canGoForward] {
            observations.append(webView.observe(key, options: [.new]) { [weak self] _, _ in
                MainActor.assumeIsolated { self?.onChange?() }
            })
        }
        observations.append(webView.observe(\.url, options: [.new]) { [weak self] _, _ in
            MainActor.assumeIsolated { self?.onChange?() }
        })
        userTurn.onChange = { [weak self] in self?.onChange?() }
    }

    /// Ends the session: stops loading and lets an agent waiting on the user go.
    func close() {
        userTurn.finish(.cancelled)
        webView.stopLoading()
        webView.removeFromSuperview()
    }

    func navigate(_ address: String) throws {
        guard let url = PreviewCommand.url(address) else { throw PreviewError.invalidAddress }
        error = nil
        webView.load(URLRequest(url: url))
        onChange?()
    }

    func perform(_ command: PreviewCommand, directory: URL) async throws -> JSONValue {
        lastAgentUse = Date()
        lastUse = Date()
        defer { onChange?() }
        switch command {
        case .show, .askUser:
            // The panel's commands; `PreviewSessions` answers them.
            throw PreviewError.invalidCommand
        case .navigate(let url):
            try navigate(url.absoluteString)
            return ["loading": true, "url": .string(url.absoluteString)]
        case .read:
            let result = try await script(Self.readScript)
            var object = result.object ?? [:]
            object["loading"] = .bool(webView.isLoading)
            if let error { object["error"] = .string(error) }
            return .object(object)
        case .click(let selector):
            return try await script(Self.clickScript, arguments: ["selector": selector])
        case .input(let selector, let text):
            return try await script(Self.inputScript, arguments: ["selector": selector, "text": text])
        case .screenshot:
            let configuration = WKSnapshotConfiguration()
            if webView.superview == nil { PreviewParking.shared.park(webView) }
            let scale = webView.window?.backingScaleFactor ?? 2
            configuration.snapshotWidth = min(1600 / scale, webView.bounds.width) as NSNumber
            let image = try await PreviewParking.shared.rendering(webView) { try await webView.takeSnapshot(configuration: configuration) }
            guard let tiff = image.tiffRepresentation, let bitmap = NSBitmapImageRep(data: tiff),
                let png = bitmap.representation(using: .png, properties: [:]) else { throw PreviewError.unavailable }
            // A fixed path bounds disk usage; no path supplied by the caller is accepted.
            let url = directory.appendingPathComponent("preview.png")
            guard FileManager.default.createFile(atPath: url.path, contents: png, attributes: [.posixPermissions: 0o600])
            else { throw PreviewError.unavailable }
            return ["path": .string(url.path), "mimeType": "image/png"]
        }
    }

    private func script(_ body: String, arguments: [String: Any] = [:]) async throws -> JSONValue {
        let value = try await webView.callAsyncJavaScript(body, arguments: arguments, in: nil, contentWorld: .defaultClient)
        guard let value, JSONSerialization.isValidJSONObject(value),
            let result = JSONValue.parse(try JSONSerialization.data(withJSONObject: value))
        else { throw PreviewError.invalidCommand }
        return result
    }

    func webView(_ webView: WKWebView, didStartProvisionalNavigation navigation: WKNavigation!) {
        error = nil
        onChange?()
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        if let url = webView.url { onNavigate?(url, webView.title) }
        onChange?()
    }

    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) { failed(error) }
    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) { failed(error) }
    func webViewWebContentProcessDidTerminate(_ webView: WKWebView) {
        error = String(localized: "The preview stopped. Reload the page to continue.")
        onChange?()
    }

    private func failed(_ failure: Error) {
        guard (failure as NSError).code != NSURLErrorCancelled else { return }
        error = failure.localizedDescription
        onChange?()
    }

    func webView(_ webView: WKWebView, decidePolicyFor navigationAction: WKNavigationAction,
        decisionHandler: @escaping @MainActor @Sendable (WKNavigationActionPolicy) -> Void) {
        let allowed = navigationAction.request.url.flatMap { PreviewCommand.url($0.absoluteString) } != nil
        decisionHandler(allowed ? .allow : .cancel)
        if !allowed { error = PreviewError.invalidAddress.localizedDescription; onChange?() }
    }

    func webView(_ webView: WKWebView, decidePolicyFor navigationResponse: WKNavigationResponse,
        decisionHandler: @escaping @MainActor @Sendable (WKNavigationResponsePolicy) -> Void) {
        let addressAllowed = navigationResponse.response.url.flatMap { PreviewCommand.url($0.absoluteString) } != nil
        decisionHandler(navigationResponse.canShowMIMEType && addressAllowed ? .allow : .cancel)
    }

    func webView(_ webView: WKWebView, createWebViewWith configuration: WKWebViewConfiguration,
        for navigationAction: WKNavigationAction, windowFeatures: WKWindowFeatures) -> WKWebView? {
        if let url = navigationAction.request.url, PreviewCommand.url(url.absoluteString) != nil {
            webView.load(navigationAction.request)
        }
        return nil
    }

    func webView(_ webView: WKWebView, requestMediaCapturePermissionFor origin: WKSecurityOrigin,
        initiatedByFrame frame: WKFrameInfo, type: WKMediaCaptureType,
        decisionHandler: @escaping @MainActor @Sendable (WKPermissionDecision) -> Void) { decisionHandler(.deny) }

    // Static code, with selector/text passed as WebKit arguments instead of interpolated into JavaScript.
    private static let readScript = #"""
        function selectorFor(el) {
            if (el.id) return '#' + CSS.escape(el.id);
            const parts = [];
            for (let node = el; node && node.nodeType === 1; node = node.parentElement) {
                const tag = node.tagName.toLowerCase();
                const siblings = node.parentElement ? [...node.parentElement.children].filter(n => n.tagName === node.tagName) : [node];
                parts.unshift(tag + ':nth-of-type(' + (siblings.indexOf(node) + 1) + ')');
            }
            return parts.join(' > ');
        }
        const elements = [...document.querySelectorAll('a,button,input,textarea,select,[role="button"],[contenteditable="true"]')]
            .filter(el => el.getClientRects().length).slice(0, 200).map(el => ({
                selector: selectorFor(el).slice(0, 4096), tag: el.tagName.toLowerCase(), type: el.type || '',
                label: (el.getAttribute('aria-label') || el.innerText || el.getAttribute('placeholder') || '').slice(0, 300),
                value: el.type === 'password' || el.type === 'file' ? '' : String(el.value || '').slice(0, 1000),
                disabled: !!el.disabled
            }));
        return {url: location.href.slice(0, 8192), title: document.title.slice(0, 1000), text: (document.body?.innerText || '').slice(0, 30000), elements};
        """#
    private static let clickScript = #"""
        const el = document.querySelector(selector);
        if (!el || !el.getClientRects().length || el.disabled || el.type === 'file') throw new Error('No visible enabled element matches the selector.');
        el.scrollIntoView({block: 'center'});
        el.click();
        return {clicked: true};
        """#
    private static let inputScript = #"""
        const el = document.querySelector(selector);
        if (!el || !el.getClientRects().length || el.disabled || el.readOnly || el.type === 'file') throw new Error('No editable element matches the selector.');
        el.focus();
        if (el.isContentEditable) el.textContent = text;
        else {
            const prototype = el instanceof HTMLTextAreaElement ? HTMLTextAreaElement.prototype
                : el instanceof HTMLSelectElement ? HTMLSelectElement.prototype
                : el instanceof HTMLInputElement ? HTMLInputElement.prototype : null;
            if (!prototype) throw new Error('The element is not an input.');
            Object.getOwnPropertyDescriptor(prototype, 'value').set.call(el, text);
        }
        el.dispatchEvent(new Event('input', {bubbles: true}));
        el.dispatchEvent(new Event('change', {bubbles: true}));
        return {filled: true};
        """#
}
