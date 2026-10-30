import Foundation
import Security

/// Whether the browser can use passkeys and security keys (WebAuthn) on any site.
///
/// On macOS, WebKit hands a page's `navigator.credentials` request to AuthenticationServices, which serves arbitrary
/// sites only for apps signed with Apple's managed `com.apple.developer.web-browser.public-key-credential`
/// entitlement. Without it the request fails, so the browser tells the user to sign in another way instead. Turning it
/// on is opt-in at build time (see `Coincide/Passkeys.entitlements` and `Signing.xcconfig`); this reads what the
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
        + "to hand this step to the user."

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

/// When a thread's browser panel shows "Passkeys aren't available": on a page's first passkey request, until the user
/// dismisses it (then not again for that site in this browser) or the tab moves to another site.
public nonisolated struct PasskeyNoticeState: Equatable, Sendable {
    public struct Notice: Equatable, Sendable {
        public let tabID: String
        public let site: String
    }

    public private(set) var notice: Notice?
    public private(set) var dismissedSites: Set<String> = []

    public init() {}

    /// A passkey request from `tabID` on `host`. True when the notice changed.
    @discardableResult
    public mutating func requested(tabID: String, host: String) -> Bool {
        let site = WebDomain.siteOrHost(host)
        guard !dismissedSites.contains(site) else { return false }
        let next = Notice(tabID: tabID, site: site)
        guard notice != next else { return false }
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
