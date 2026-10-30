import AppKit
import CoincideKit
import WebKit

/// The browser's storage. By default every thread's browser uses one persistent WebKit profile, so sign-ins and site
/// data last across threads and relaunches, while each thread keeps its own page and back/forward history. With
/// private sessions on (Settings › Browser), each thread gets temporary storage of its own instead, as before.
final class BrowserProfile {
    /// While the app hosts tests, the shared profile is kept in memory, so tests that open a thread's browser leave
    /// nothing under ~/Library/WebKit. Tests of the persistent profile make one of their own.
    static let shared = BrowserProfile(directory: AppStore.shared.directory, isPersistent: !AppDelegate.isHostingTests)

    let settings: BrowserSettingsStore
    let library: BrowserLibrary
    let directory: URL
    /// Where Coincide keeps the Bitwarden session: the login Keychain, or memory while hosting tests so they never
    /// touch the Keychain.
    let secrets: SecretStore
    /// Coincide's own saved logins: their list beside the store's data, their passwords in the Keychain (memory in tests).
    let logins: CoincideLoginProvider
    private let isPersistent: Bool
    private var sharedStore: WKWebsiteDataStore?

    init(directory: URL, isPersistent: Bool = true) {
        settings = BrowserSettingsStore(directory: directory)
        library = BrowserLibrary(directory: directory)
        self.directory = directory
        self.isPersistent = isPersistent
        let testing = AppDelegate.isHostingTests
        secrets = testing ? MemorySecretStore() : KeychainSecretStore()
        logins = CoincideLoginProvider(directory: directory,
            secrets: testing ? MemorySecretStore() : KeychainSecretStore(service: "com.apoorvdarshan.coincide.browser-logins"))
    }

    /// The password managers Coincide can fill from, each used only while the user has it turned on.
    func passwordProviders() -> [PasswordProvider] {
        [logins, OnePasswordProvider(), BitwardenProvider(sessions: secrets)]
    }

    var usesPrivateSessions: Bool { settings.settings.usesPrivateSessions }

    /// The shared, persistent profile, named by `BrowserSettings.profileID` (kept under ~/Library/WebKit).
    var sharedDataStore: WKWebsiteDataStore {
        if let sharedStore { return sharedStore }
        let store = isPersistent ? WKWebsiteDataStore(forIdentifier: settings.settings.profileID) : .nonPersistent()
        sharedStore = store
        return store
    }

    /// The storage for a new thread browser.
    func makeDataStore() -> WKWebsiteDataStore {
        usesPrivateSessions ? .nonPersistent() : sharedDataStore
    }

    /// Removes cookies and site data from the shared profile, and history from Coincide's library. Bookmarks stay.
    func clear(siteData: Bool, history: Bool) async {
        if siteData {
            await sharedDataStore.removeData(ofTypes: WKWebsiteDataStore.allWebsiteDataTypes(), modifiedSince: .distantPast)
        }
        if history {
            library.clearHistory()
            library.flush()
            UIState.shared.update { state in
                state.previewAddresses.removeAll()
                state.previewTabs.removeAll()
            }
        }
    }

    /// Adds imported cookies to the shared profile. Returns how many WebKit accepted.
    func importCookies(_ cookies: [ImportedCookie]) async -> Int {
        let store = sharedDataStore.httpCookieStore
        var count = 0
        for cookie in cookies {
            guard let httpCookie = cookie.httpCookie else { continue }
            await store.setCookie(httpCookie)
            count += 1
        }
        return count
    }

    /// Deletes a profile's folder once WebKit lets go of it. For tests, which each use a profile of their own; the
    /// caller must have closed every browser using it.
    func removeProfile() async {
        let id = settings.settings.profileID
        sharedStore = nil
        for _ in 0..<5 {
            do {
                try await WKWebsiteDataStore.remove(forIdentifier: id)
                return
            } catch {
                try? await Task.sleep(for: .milliseconds(150))
            }
        }
        NSLog("Coincide: the test browser profile \(id.uuidString) is still in use and wasn't removed")
    }
}

/// Keeps thread browsers that aren't in the panel alive in a window that is never shown, so agents can drive them
/// headless. The panel takes a browser out when it shows that thread and returns it here. The window is ordered in,
/// far off every screen, only for the moment a screenshot needs it rendered.
final class PreviewParking {
    static let shared = PreviewParking()
    static let defaultSize = NSSize(width: 1280, height: 860)

    private lazy var window: NSWindow = {
        let window = NSWindow(
            contentRect: NSRect(origin: NSPoint(x: -20_000, y: -20_000), size: Self.defaultSize), styleMask: [.borderless],
            backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.isExcludedFromWindowsMenu = true
        window.collectionBehavior = [.transient, .ignoresCycle, .stationary, .fullScreenNone]
        window.ignoresMouseEvents = true
        window.hasShadow = false
        window.alphaValue = 0
        window.contentView = NSView(frame: NSRect(origin: .zero, size: Self.defaultSize))
        return window
    }()

    /// Moves `view` into the parking window at its last size (or the default), unless it's already shown elsewhere.
    func park(_ view: WKWebView) {
        guard let content = window.contentView, view.superview == nil || view.superview === content else { return }
        let size = view.frame.width > 0 && view.frame.height > 0 ? view.frame.size : Self.defaultSize
        view.translatesAutoresizingMaskIntoConstraints = true
        view.frame = NSRect(origin: .zero, size: size)
        if view.superview !== content { content.addSubview(view) }
    }

    func isParked(_ view: WKWebView) -> Bool { view.superview === window.contentView }

    /// Runs `body` with the parking window ordered in (off screen), so a parked page renders for a snapshot.
    func rendering<T>(_ view: WKWebView, _ body: () async throws -> T) async rethrows -> T {
        guard isParked(view) else { return try await body() }
        window.orderBack(nil)
        defer { window.orderOut(nil) }
        return try await body()
    }
}
