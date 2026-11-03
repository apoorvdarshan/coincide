import Foundation

/// Settings › Browser, kept in `browser.json` beside the store's data (so `COINCIDE_DATA_DIR` keeps test runs apart).
///
/// Coincide 0.1 gave every thread its own ephemeral WebKit storage and wrote no file; a missing file therefore means
/// the defaults: one shared, persistent profile (a fresh id, so nothing from before is reused) and Agent Control on.
public nonisolated struct BrowserSettings: Codable, Hashable, Sendable {
    /// Names the shared `WKWebsiteDataStore`. Clearing all data keeps it; it changes only when the file is new.
    public var profileID: UUID
    /// Each thread gets its own temporary storage instead of the shared profile, as before.
    public var usesPrivateSessions: Bool
    /// Whether threads the user hasn't switched on or off themselves let their agent use the thread's browser.
    public var agentControlByDefault: Bool
    /// Threads where the user turned Agent Control on or off in the browser panel, by thread id.
    public var agentControl: [String: Bool]
    /// Password managers the user turned on; none by default.
    public var passwordManagers: [PasswordManagerKind]
    /// Sites where the user let agents sign in with a login ("Always for this site").
    public var loginGrants: [LoginGrant]
    /// Agents' `fill-login` types the login on any site without asking, as if every site were granted. Off by
    /// default; `loginGrants` are kept for when it's turned off.
    public var agentsSignInWithoutAsking: Bool
    /// Offer to save a login in Coincide after the user signs in on a page (with Coincide's saved logins on).
    public var offersToSaveLogins: Bool
    /// Sites the user said never to offer saving for.
    public var neverSaveSites: [String]
    /// Agents Coincide starts get the enabled password managers' unlocked sessions (Bitwarden's `BW_SESSION`), so
    /// they can use the managers' command-line tools, for API keys and tokens, without asking. On by default.
    public var agentsUsePasswordManagers: Bool
    /// Pages can sign in with passkeys saved in Bitwarden while Bitwarden is turned on and unlocked, each time after the
    /// user confirms (`PasskeySignIn`). On by default.
    public var usesBitwardenPasskeys: Bool
    /// Every Bitwarden passkey sign-in also asks for Touch ID or the Mac's password after the user clicks Sign In. Off by
    /// default, like Bitwarden's browser extension: the click is enough unless the site requires user verification or
    /// the Bitwarden item has master password re-prompt on.
    public var confirmsPasskeysWithTouchID: Bool
    /// What the address bar searches with when what's typed isn't an address.
    public var searchEngine: SearchEngine

    public init(profileID: UUID = UUID()) {
        self.profileID = profileID
        usesPrivateSessions = false
        agentControlByDefault = true
        agentControl = [:]
        passwordManagers = []
        loginGrants = []
        agentsSignInWithoutAsking = false
        offersToSaveLogins = true
        neverSaveSites = []
        agentsUsePasswordManagers = true
        usesBitwardenPasskeys = true
        confirmsPasskeysWithTouchID = false
        searchEngine = .google
    }

    public init(from decoder: Decoder) throws {
        let defaults = BrowserSettings()
        let container = try decoder.container(keyedBy: CodingKeys.self)
        func value<T: Decodable>(_ key: CodingKeys, _ fallback: T) -> T {
            (try? container.decodeIfPresent(T.self, forKey: key)) ?? fallback
        }
        profileID = value(.profileID, defaults.profileID)
        usesPrivateSessions = value(.usesPrivateSessions, defaults.usesPrivateSessions)
        agentControlByDefault = value(.agentControlByDefault, defaults.agentControlByDefault)
        agentControl = value(.agentControl, defaults.agentControl)
        // A manager this version doesn't know is dropped rather than failing the whole list.
        passwordManagers = value(.passwordManagers, [String]()).compactMap(PasswordManagerKind.init(rawValue:))
        loginGrants = value(.loginGrants, [FailableGrant]()).compactMap(\.grant)
        agentsSignInWithoutAsking = value(.agentsSignInWithoutAsking, defaults.agentsSignInWithoutAsking)
        offersToSaveLogins = value(.offersToSaveLogins, defaults.offersToSaveLogins)
        neverSaveSites = value(.neverSaveSites, defaults.neverSaveSites)
        agentsUsePasswordManagers = value(.agentsUsePasswordManagers, defaults.agentsUsePasswordManagers)
        usesBitwardenPasskeys = value(.usesBitwardenPasskeys, defaults.usesBitwardenPasskeys)
        confirmsPasskeysWithTouchID = value(.confirmsPasskeysWithTouchID, defaults.confirmsPasskeysWithTouchID)
        searchEngine = value(.searchEngine, defaults.searchEngine)
    }

    private struct FailableGrant: Decodable {
        let grant: LoginGrant?
        init(from decoder: Decoder) throws { grant = try? LoginGrant(from: decoder) }
    }

    public func isAgentControlEnabled(for threadID: UUID) -> Bool {
        agentControl[threadID.uuidString] ?? agentControlByDefault
    }
}

/// Loads and saves `BrowserSettings`, and tells observers when they change.
@MainActor
public final class BrowserSettingsStore {
    public static let didChange = Notification.Name("coincide.browserSettingsChanged")

    public private(set) var settings: BrowserSettings
    /// True when the file didn't exist yet: the first launch since the browser had a shared profile.
    public let isNew: Bool
    private let url: URL

    public init(directory: URL) {
        url = directory.appendingPathComponent("browser.json")
        if let data = try? Data(contentsOf: url), let decoded = try? JSONDecoder().decode(BrowserSettings.self, from: data) {
            settings = decoded
            isNew = false
        } else {
            settings = BrowserSettings()
            isNew = true
            save()
        }
    }

    public func update(_ mutate: (inout BrowserSettings) -> Void) {
        let old = settings
        mutate(&settings)
        guard settings != old else { return }
        save()
        NotificationCenter.default.post(name: Self.didChange, object: self)
    }

    /// Forgets per-thread choices for threads that no longer exist.
    public func prune(keeping threads: Set<UUID>) {
        let keep = Set(threads.map(\.uuidString))
        guard settings.agentControl.keys.contains(where: { !keep.contains($0) }) else { return }
        update { $0.agentControl = $0.agentControl.filter { keep.contains($0.key) } }
    }

    private func save() {
        do {
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.sortedKeys, .prettyPrinted]
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try encoder.encode(settings).write(to: url, options: .atomic)
        } catch {
            NSLog("Coincide: failed to save browser settings: \(error.localizedDescription)")
        }
    }
}
