import CoincideKit
import WebKit

/// Registers native frame handles from an isolated script world, including cross-origin frames. Console output
/// comes from page scripts and is untrusted. It is bounded, held in memory, and never evaluates object getters.
final class PreviewPageTools: NSObject, WKScriptMessageHandler {
    struct Frame {
        let id: String
        let info: WKFrameInfo
        let title: String
    }
    private struct Page {
        var frames: [Frame] = []
        var logs: [JSONValue] = []
    }
    private var nextFrame = 1
    private var pages: [ObjectIdentifier: Page] = [:]

    func reset(_ view: WKWebView) { pages[ObjectIdentifier(view)] = nil }

    func frames(in view: WKWebView) -> [Frame] { pages[ObjectIdentifier(view)]?.frames ?? [] }

    func console(in view: WKWebView, clear: Bool) -> JSONValue {
        let key = ObjectIdentifier(view)
        let logs = pages[key]?.logs ?? []
        if clear { pages[key]?.logs.removeAll() }
        return ["entries": .array(logs)]
    }

    func install(in configuration: WKWebViewConfiguration) {
        let controller = configuration.userContentController
        controller.add(self, contentWorld: .defaultClient, name: "coincideFrames")
        controller.addUserScript(WKUserScript(source: Self.frameScript, injectionTime: .atDocumentEnd,
            forMainFrameOnly: false, in: .defaultClient))
        controller.add(self, contentWorld: .page, name: "coincideConsole")
        controller.addUserScript(WKUserScript(source: Self.consoleScript, injectionTime: .atDocumentStart,
            forMainFrameOnly: false, in: .page))
    }

    func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage) {
        guard let view = message.webView, let body = message.body as? [String: Any] else { return }
        let key = ObjectIdentifier(view)
        var page = pages[key] ?? Page()
        if message.name == "coincideFrames", !message.frameInfo.isMainFrame, page.frames.count < 64 {
            page.frames.append(Frame(id: "frame-\(nextFrame)", info: message.frameInfo,
                title: String((body["title"] as? String ?? "").prefix(300))))
            nextFrame += 1
        } else if message.name == "coincideConsole", let text = body["text"] as? String {
            page.logs.append(["level": .string(String((body["level"] as? String ?? "log").prefix(32))),
                "text": .string(String(text.prefix(2000))),
                "url": .string(String((message.frameInfo.request.url?.absoluteString ?? "").prefix(8192)))])
            if page.logs.count > 200 { page.logs.removeFirst(page.logs.count - 200) }
        }
        pages[key] = page
    }

    private static let frameScript = #"""
        if (window !== window.top) window.webkit.messageHandlers.coincideFrames.postMessage({title: document.title});
        """#

    private static let consoleScript = #"""
        (() => {
            const post = window.webkit.messageHandlers.coincideConsole.postMessage.bind(window.webkit.messageHandlers.coincideConsole);
            // A page owns its logs. Record primitive arguments only, avoiding getters, cycles and large object dumps.
            const text = value => typeof value === 'string' ? value.slice(0, 2000)
                : value === null ? 'null' : value instanceof Error ? String(Object.getOwnPropertyDescriptor(value, 'message')?.value || 'Error').slice(0, 2000)
                : ['number', 'boolean', 'undefined', 'bigint'].includes(typeof value) ? String(value).slice(0, 2000) : '[object]';
            const emit = (level, args) => { try { post({level, text: args.slice(0, 20).map(text).join(' ').slice(0, 2000)}); } catch (_) {} };
            for (const level of ['log', 'info', 'warn', 'error', 'debug']) {
                const original = console[level];
                console[level] = function(...args) { emit(level, args); return original.apply(this, args); };
            }
            window.addEventListener('error', event => emit('error', [event.message, event.filename, event.lineno]));
            window.addEventListener('unhandledrejection', event => emit('unhandledrejection', [event.reason]));
        })();
        """#
}
