import AppKit
import CoincideKit

/// Where a web link the user opens goes.
nonisolated enum LinkDestination: Equatable, Sendable {
    /// The thread's browser preview, beside the conversation.
    case coincideBrowser
    /// A new tab of the thread's browser (⌘⌥-click, or the link menu's Open in New Tab).
    case coincideBrowserNewTab
    /// The user's default browser, through `SafeLinks`.
    case defaultBrowser
}

/// A web link and where the user chose to open it. `ChatTextView` hands this to its `onOpenLink` in place of the raw
/// link for http(s) links, so its hosts open it there; other links (files, mail, other schemes) are passed on as before.
nonisolated struct WebLinkRequest: Equatable, Sendable {
    let url: URL
    let destination: LinkDestination
}

/// Decides where clicked web links open. By default a click opens the thread's browser preview and a ⌘-click the
/// default browser; Settings › General › "Open links in your default browser" swaps the two. Only http(s) links are
/// routed: every other link keeps going where it went before (`SafeLinks`).
///
/// A link opened here loads as an ordinary navigation of the user's in the thread's browser (its active tab, or a new
/// tab with ⌘⌥-click). It gives the agent no control it did not have.
enum LinkRouting {
    /// The http(s) URL a link names: a `URL`, or text the transcript keeps as a link (`www.` included). Nil for files,
    /// mail, other schemes, and web addresses without a host.
    nonisolated static func webURL(_ link: Any) -> URL? {
        let url: URL?
        if let link = link as? URL {
            url = link
        } else if let text = (link as? String)?.trimmingCharacters(in: .whitespacesAndNewlines), !text.isEmpty {
            url = text.lowercased().hasPrefix("www.") ? URL(string: "https://" + text) : URL(string: text)
        } else {
            url = nil
        }
        guard let url, let scheme = url.scheme?.lowercased(), scheme == "http" || scheme == "https",
            let host = url.host, !host.isEmpty
        else { return nil }
        return url
    }

    /// Where a click goes: the preview, unless the setting or ⌘ (but not both) asks for the default browser.
    nonisolated static func destination(commandKey: Bool, opensInDefaultBrowser: Bool) -> LinkDestination {
        commandKey != opensInDefaultBrowser ? .defaultBrowser : .coincideBrowser
    }

    /// What a click on `link` asks for: a `WebLinkRequest` for a web link, nil for any other link.
    nonisolated static func request(for link: Any, commandKey: Bool, optionKey: Bool = false, opensInDefaultBrowser: Bool)
        -> WebLinkRequest?
    {
        guard let url = webURL(link) else { return nil }
        if commandKey && optionKey { return WebLinkRequest(url: url, destination: .coincideBrowserNewTab) }
        return WebLinkRequest(url: url, destination: destination(commandKey: commandKey, opensInDefaultBrowser: opensInDefaultBrowser))
    }

    /// The setting as it is now.
    static var opensInDefaultBrowser: Bool { AppStore.shared.settings.opensLinksInDefaultBrowser }

    /// The line a web link's tooltip adds under its address, saying what a click and a ⌘-click do.
    nonisolated static func hint(opensInDefaultBrowser: Bool) -> String {
        opensInDefaultBrowser
            ? String(localized: "Click to open in your browser · ⌘-click to open in Coincide")
            : String(localized: "Click to open in Coincide · ⌘-click to open in your browser")
    }

    /// The title of the context menu item that opens a link in `destination`.
    nonisolated static func menuTitle(_ destination: LinkDestination) -> String {
        switch destination {
        case .coincideBrowser: String(localized: "Open in Coincide Browser")
        case .coincideBrowserNewTab: String(localized: "Open in New Tab")
        case .defaultBrowser: String(localized: "Open in Default Browser")
        }
    }

    /// Opens a web link where it was asked to go. The preview needs the main window and a thread; without them, or for
    /// an address the preview does not load, the link opens in the default browser instead.
    static func open(_ request: WebLinkRequest, from window: NSWindow?) {
        if request.destination != .defaultBrowser,
            let controller = (window ?? NSApp.mainWindow)?.windowController as? MainWindowController,
            controller.openInBrowserPreview(request.url, newTab: request.destination == .coincideBrowserNewTab)
        {
            return
        }
        SafeLinks.openExternal(request.url, from: window)
    }
}
