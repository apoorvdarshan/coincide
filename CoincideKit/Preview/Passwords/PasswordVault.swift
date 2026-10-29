import Foundation

/// A site the user let agents sign in to with one login ("Always for this site"). Kept in `BrowserSettings`;
/// Settings › Browser › Passwords lists and revokes them.
public nonisolated struct LoginGrant: Codable, Hashable, Sendable, Identifiable {
    public var id: String { "\(site)|\(source.rawValue)|\(itemID)" }
    public var site: String
    public var source: PasswordManagerKind
    public var itemID: String
    public var itemTitle: String
    public var username: String
    public var granted: Date

    public init(site: String, item: LoginItem, granted: Date = Date()) {
        self.site = site
        source = item.source
        itemID = item.itemID
        itemTitle = item.title
        username = item.username
        self.granted = granted
    }
}

/// The user's answer to "Allow agents to sign in to example.com with …?".
public nonisolated enum LoginApproval: String, Sendable {
    case allowOnce
    case always
    case deny
}

public nonisolated enum LoginFillError: LocalizedError, Equatable {
    case noPasswordManager
    case notAWebPage
    case noMatch(site: String)
    case ambiguous(site: String, choices: [String])
    case denied(site: String)

    public var errorDescription: String? {
        switch self {
        case .noPasswordManager:
            String(localized: "No password manager is turned on. The user can turn one on in Settings › Browser › Passwords.")
        case .notAWebPage: String(localized: "Open the site's sign-in page first.")
        case .noMatch(let site): String(localized: "No saved login matches \(site).")
        case .ambiguous(let site, let choices):
            String(localized: "Several logins match \(site): \(choices.joined(separator: "; ")). Send item with a title or username.")
        case .denied(let site): String(localized: "The user didn't allow signing in to \(site).")
        }
    }
}

/// The enabled password managers, which login fits a page, and who may use it.
///
/// Agents get a login only through `fill-login`, after the user approved the site and item; the user's own clicks on
/// the address bar's key need no approval. "Allow once" covers that thread, site and item for five minutes, enough
/// for a sign-in followed by its two-factor page.
@MainActor
public final class PasswordVault {
    public static let onceDuration: TimeInterval = 300
    public private(set) var providers: [PasswordManagerKind: PasswordProvider]
    let settings: BrowserSettingsStore
    private var onceGrants: [String: Date] = [:]

    public init(settings: BrowserSettingsStore, providers: [PasswordProvider]) {
        self.settings = settings
        self.providers = Dictionary(uniqueKeysWithValues: providers.map { ($0.kind, $0) })
    }

    public var enabledKinds: [PasswordManagerKind] {
        PasswordManagerKind.allCases.filter { settings.settings.passwordManagers.contains($0) && providers[$0] != nil }
    }

    /// Matching logins from every enabled manager, best first. Managers that fail (locked, missing) are skipped and
    /// reported.
    public func candidates(for page: URL) async -> (items: [LoginItem], failures: [PasswordManagerKind: String]) {
        var items: [LoginItem] = []
        var failures: [PasswordManagerKind: String] = [:]
        for kind in enabledKinds {
            guard let provider = providers[kind] else { continue }
            do { items += try await provider.logins(for: page) } catch { failures[kind] = error.localizedDescription }
        }
        return (LoginMatcher.ranked(items, page: page), failures)
    }

    /// The one login an agent's `fill-login` means: the best match, narrowed by `hint`; a site's granted item breaks
    /// ties. Throws when there's none, or several equally good ones without a hint.
    public func resolve(page: URL, hint: String?) async throws -> LoginItem {
        guard !enabledKinds.isEmpty else { throw LoginFillError.noPasswordManager }
        guard let host = page.host, ["http", "https"].contains(page.scheme?.lowercased() ?? "") else { throw LoginFillError.notAWebPage }
        let site = WebDomain.siteOrHost(host)
        let matches = LoginMatcher.filter(await candidates(for: page).items, hint: hint)
        guard let best = matches.first else { throw LoginFillError.noMatch(site: site) }
        let strength = LoginMatcher.match(best, page: page)
        let top = matches.filter { LoginMatcher.match($0, page: page) == strength }
        if top.count == 1 { return best }
        if let granted = top.first(where: { item in settings.settings.loginGrants.contains { $0.site == site && $0.source == item.source && $0.itemID == item.itemID } }) {
            return granted
        }
        throw LoginFillError.ambiguous(site: site, choices: top.prefix(8).map { item in
            [item.title, item.username.isEmpty ? nil : item.username, item.source.displayName].compactMap { $0 }.joined(separator: " · ")
        })
    }

    public func isApproved(_ item: LoginItem, page: URL, threadID: UUID, now: Date = Date()) -> Bool {
        guard let host = page.host else { return false }
        let site = WebDomain.siteOrHost(host)
        if settings.settings.loginGrants.contains(where: { $0.site == site && $0.source == item.source && $0.itemID == item.itemID }) {
            return true
        }
        return onceGrants[onceKey(item, site: site, threadID: threadID)].map { $0 > now } ?? false
    }

    public func record(_ approval: LoginApproval, for item: LoginItem, page: URL, threadID: UUID, now: Date = Date()) {
        guard let host = page.host else { return }
        let site = WebDomain.siteOrHost(host)
        switch approval {
        case .allowOnce: onceGrants[onceKey(item, site: site, threadID: threadID)] = now.addingTimeInterval(Self.onceDuration)
        case .always:
            settings.update { settings in
                let grant = LoginGrant(site: site, item: item, granted: now)
                settings.loginGrants.removeAll { $0.id == grant.id }
                settings.loginGrants.append(grant)
            }
        case .deny: onceGrants.removeValue(forKey: onceKey(item, site: site, threadID: threadID))
        }
    }

    public func revoke(_ grant: LoginGrant) {
        settings.update { $0.loginGrants.removeAll { $0.id == grant.id } }
    }

    public func secret(for item: LoginItem) async throws -> LoginSecret {
        guard settings.settings.passwordManagers.contains(item.source), let provider = providers[item.source] else {
            throw LoginFillError.noPasswordManager
        }
        return try await provider.secret(for: item)
    }

    private func onceKey(_ item: LoginItem, site: String, threadID: UUID) -> String {
        "\(threadID.uuidString)|\(site)|\(item.id)"
    }
}
