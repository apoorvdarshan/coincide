import Foundation
import Security

/// Whether the browser can use passkeys and security keys (WebAuthn) on any site.
///
/// On macOS, WebKit hands a page's `navigator.credentials` request to AuthenticationServices, which serves arbitrary
/// sites only for apps signed with Apple's managed `com.apple.developer.web-browser.public-key-credential`
/// entitlement. Without it the request fails, so the browser offers other ways to sign in (`PasskeyHandoff`). Turning
/// it on is opt-in at build time (see `Coincide/Passkeys.entitlements` and `Signing.xcconfig`); this reads what the
/// running app was actually signed with.
public nonisolated struct PasskeySupport: Sendable {
    public static let entitlement = "com.apple.developer.web-browser.public-key-credential"

    /// Reads one entitlement of the running app. Tests pass their own.
    public typealias EntitlementReader = @Sendable (String) -> Bool

    private let hasEntitlement: EntitlementReader

    public init(hasEntitlement: @escaping EntitlementReader) {
        self.hasEntitlement = hasEntitlement
    }

    /// The running app's own signature.
    public static let current = PasskeySupport(hasEntitlement: currentProcessHasEntitlement)

    /// True when the app is signed with the browser passkey entitlement, so pages' passkey requests can reach the
    /// system's passkey sheet.
    public var isAvailable: Bool { hasEntitlement(Self.entitlement) }

    /// The entitlement's value on this process's code signature, true only for a Boolean true.
    public static func currentProcessHasEntitlement(_ key: String) -> Bool {
        guard let task = SecTaskCreateFromSelf(nil) else { return false }
        return SecTaskCopyValueForEntitlement(task, key as CFString, nil) as? Bool == true
    }

    /// What an agent's `read` says after the page asked for a passkey. Agent-facing, so not localized.
    public static let agentNote = "This page asked for a passkey, but passkeys aren't available in Coincide's browser yet, so "
        + "that request fails. Choose another way to sign in (such as \"Try another way\"), then use fill-login, or use ask-user "
        + "to hand this step to the user: the panel can open the page in their own browser, where their passkey works, and "
        + "import that sign-in back."

    /// Message handler name for `detectionScript`.
    public static let messageHandler = "coincidePasskey"

    /// Wraps `navigator.credentials.get` and `create` in the page's own script world (the only place a page's calls
    /// can be seen). Each wrapper reports a request that carries `publicKey` options, then calls the original with the
    /// same `this` and arguments and returns exactly what it returns: the same promise, so the same credential or
    /// error, and a synchronous exception propagates unchanged. Requests without `publicKey` (passwords, federated
    /// sign-in, OTP) are not reported. Nothing is installed where WebKit has no credentials API or no handler.
    public static let detectionScript = #"""
        (() => {
            const handlers = window.webkit && window.webkit.messageHandlers;
            const handler = handlers && handlers.coincidePasskey;
            const proto = typeof CredentialsContainer === 'function' && CredentialsContainer.prototype;
            if (!handler || !proto) return;
            const post = handler.postMessage.bind(handler);
            for (const name of ['get', 'create']) {
                const descriptor = Object.getOwnPropertyDescriptor(proto, name);
                const original = descriptor && descriptor.value;
                if (typeof original !== 'function') continue;
                // Method syntax keeps the built-in's name and, like a native method, has no prototype.
                const wrapped = {
                    [name](options) {
                        try {
                            if (options && typeof options === 'object' && options.publicKey) post({kind: name});
                        } catch (error) {}
                        return Reflect.apply(original, this, arguments);
                    }
                }[name];
                Object.defineProperty(wrapped, 'length', {value: original.length});
                Object.defineProperty(proto, name, {...descriptor, value: wrapped});
            }
        })();
        """#
}

/// The way around a missing passkey here, as cmux does it: the page opens in the user's own browser, where the passkey
/// works, and once they've signed in there the site's sign-in comes back through the browser import, the site's
/// cookies only.
public nonisolated enum PasskeyHandoff {
    /// The browser "Open in" names and opens the page in.
    public struct Browser: Equatable, Sendable {
        /// The app's name, such as "Safari" or "Google Chrome".
        public let name: String
        public let appURL: URL
        /// Its entry in the import catalog; nil when Coincide can't import from it (an unknown browser, DuckDuckGo).
        public let importable: BrowserCatalog.Definition?

        public init(name: String, appURL: URL, importable: BrowserCatalog.Definition?) {
            self.name = name
            self.appURL = appURL
            self.importable = importable
        }
    }

    /// The browser from what macOS reports as the default app for web links: its location, bundle identifier and
    /// display name. Nil when there is none, or when it is Coincide itself (`ownBundleID`), which would only open the
    /// page here again.
    public static func browser(appURL: URL?, bundleID: String?, name: String?, ownBundleID: String?) -> Browser? {
        guard let appURL else { return nil }
        if let bundleID, bundleID == ownBundleID { return nil }
        let definition = bundleID.flatMap { id in BrowserCatalog.all.first { $0.bundleIDs.contains(id) } }
        var shown = name?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        // The display name keeps ".app" when Finder shows every extension.
        if shown.lowercased().hasSuffix(".app") { shown = String(shown.dropLast(4)) }
        if shown.isEmpty { shown = definition?.name ?? appURL.deletingPathExtension().lastPathComponent }
        let importable = definition.flatMap { definition -> BrowserCatalog.Definition? in
            if case .unsupported = definition.engine { return nil }
            return definition
        }
        return Browser(name: shown, appURL: appURL, importable: importable)
    }

    /// What reading a site's sign-in from a browser found.
    public enum Outcome: Equatable, Sendable {
        /// The site's unexpired cookies, at least one.
        case found([ImportedCookie])
        /// The browser has none for the site, or hasn't saved them yet.
        case nothingFound
        case problem(BrowserImportProblem.Reason)
    }

    /// Reads `site`'s cookies from `browser` (as `BrowserCatalog.detect` found it, nil when it didn't), in the profile
    /// links open in, with the existing importer. Runs off the main thread: macOS may ask for a Chromium browser's
    /// Keychain key (`safeStorage`) first.
    public static func readSignIn(
        site: String, from browser: BrowserCatalog.Detected?, home: URL, safeStorage: ([String]) -> Data?, now: Date = Date()
    ) -> Outcome {
        guard let browser else { return .problem(.unreadable) }
        switch browser.status {
        case .needsFullDiskAccess: return .problem(.needsFullDiskAccess)
        case .unsupported: return .problem(.unreadable)
        case .available: break
        }
        guard let profile = BrowserCatalog.preferredProfile(of: browser, home: home) else { return .nothingFound }
        let data = BrowserImporter.scan(browser, profile: profile, kinds: [.cookies], home: home, safeStorage: safeStorage)
        // A problem wins over what was read: without its key a Chromium browser yields only unencrypted cookies, never
        // a sign-in.
        if let problem = data.problems.first(where: { $0.kind == .cookies }) { return .problem(problem.reason) }
        let cookies = data.cookies(forSites: [site], at: now)
        return cookies.isEmpty ? .nothingFound : .found(cookies)
    }
}

/// When a thread's browser panel shows "Passkeys aren't available", and how far its way around it has got: on a page's
/// first passkey request, until the user dismisses it (then not again for that site in this browser) or the tab moves
/// to another site.
public nonisolated struct PasskeyNoticeState: Equatable, Sendable {
    public struct Notice: Equatable, Sendable {
        public let tabID: String
        public let site: String
        /// The user's browser when the notice appeared, which "Open in" names and the import reads from.
        public let browser: PasskeyHandoff.Browser?
        public fileprivate(set) var stage: Stage

        public init(tabID: String, site: String, browser: PasskeyHandoff.Browser? = nil, stage: Stage = .unavailable) {
            self.tabID = tabID
            self.site = site
            self.browser = browser
            self.stage = stage
        }
    }

    public enum Stage: Equatable, Sendable {
        /// Passkeys aren't available here; the page can open in the user's browser.
        case unavailable
        /// The page is open in the user's browser; the sign-in made there can be imported.
        case awaitingImport
        case importing
        /// The sign-in was imported and the page reloaded.
        case imported
        case failed(ImportFailure)
    }

    public enum ImportFailure: Equatable, Sendable {
        case nothingFound
        case problem(BrowserImportProblem.Reason)
    }

    public private(set) var notice: Notice?
    public private(set) var dismissedSites: Set<String> = []

    public init() {}

    /// A passkey request from `tabID` on `host`; `browser` is asked for only when a new notice appears. The page asking
    /// again, as it may after reloading, keeps the notice where it is. True when the notice changed.
    @discardableResult
    public mutating func requested(tabID: String, host: String, browser: @autoclosure () -> PasskeyHandoff.Browser? = nil) -> Bool {
        let site = WebDomain.siteOrHost(host)
        guard !dismissedSites.contains(site), notice?.tabID != tabID || notice?.site != site else { return false }
        notice = Notice(tabID: tabID, site: site, browser: browser())
        return true
    }

    /// "Open in": the page is open in the user's browser, so the import is offered. True when the notice changed.
    @discardableResult
    public mutating func openedElsewhere() -> Bool { move(to: .awaitingImport) { $0 != .importing } }

    /// Offers the import again, as after the user went to turn on Full Disk Access. True when the notice changed.
    @discardableResult
    public mutating func offerImport() -> Bool { move(to: .awaitingImport) { $0 != .unavailable && $0 != .importing } }

    /// The import started. False when there is nothing to import yet (the page wasn't opened elsewhere) or one is
    /// already running.
    @discardableResult
    public mutating func importStarted() -> Bool { move(to: .importing) { $0 != .unavailable && $0 != .importing } }

    /// The import for `tabID` on `site` ended, without `failure` when it imported the sign-in. Ignored when the notice
    /// moved on meanwhile (another site, the tab closed, ×). True when the notice changed.
    @discardableResult
    public mutating func importFinished(tabID: String, site: String, failure: ImportFailure?) -> Bool {
        guard notice?.tabID == tabID, notice?.site == site else { return false }
        return move(to: failure.map(Stage.failed) ?? .imported) { $0 == .importing }
    }

    private mutating func move(to stage: Stage, from allowed: (Stage) -> Bool) -> Bool {
        guard var next = notice, allowed(next.stage), next.stage != stage else { return false }
        next.stage = stage
        notice = next
        return true
    }

    /// The ×: hides the notice and keeps it hidden for that site.
    public mutating func dismiss() {
        guard let notice else { return }
        dismissedSites.insert(notice.site)
        self.notice = nil
    }

    /// The tab committed a page on `host`. Another site's page clears the tab's notice. True when it changed.
    @discardableResult
    public mutating func navigated(tabID: String, host: String) -> Bool {
        guard let notice, notice.tabID == tabID, notice.site != WebDomain.siteOrHost(host) else { return false }
        self.notice = nil
        return true
    }

    /// The tab closed. True when its notice went with it.
    @discardableResult
    public mutating func closed(tabID: String) -> Bool {
        guard notice?.tabID == tabID else { return false }
        notice = nil
        return true
    }
}
