import Foundation

/// Decides which saved logins belong to a page, like a password manager: the same host first, then a parent host the
/// login was saved for, then the same site (`login.example.com` for a login saved on `example.com`). Lookalikes
/// (`example.com.evil.test`, `evil-example.com`) never match; local addresses match only exactly, port included; and a
/// login saved for HTTPS is never offered on plain HTTP.
public nonisolated enum LoginMatcher {
    public enum Strength: Int, Comparable, Sendable {
        case site = 1
        case parentHost = 2
        case exactHost = 3

        public static func < (lhs: Self, rhs: Self) -> Bool { lhs.rawValue < rhs.rawValue }
    }

    /// How well a login saved for `saved` matches `page`, or nil when it mustn't be filled there.
    public static func match(saved: String, page: URL) -> Strength? {
        guard let pageScheme = page.scheme?.lowercased(), ["http", "https"].contains(pageScheme),
            let pageHost = page.host.map(WebDomain.normalize), !pageHost.isEmpty,
            let login = parse(saved)
        else { return nil }
        let pageIsLocal = WebDomain.site(of: pageHost) == nil
        let loginIsLocal = WebDomain.site(of: login.host) == nil
        if pageIsLocal || loginIsLocal {
            guard pageHost == login.host, login.port == nil || login.port == page.port ?? defaultPort(pageScheme) else { return nil }
            return .exactHost
        }
        // A secure login stays off insecure pages.
        if login.scheme == "https", pageScheme != "https" { return nil }
        if pageHost == login.host { return .exactHost }
        if WebDomain.host(pageHost, isWithin: login.host) { return .parentHost }
        if let pageSite = WebDomain.site(of: pageHost), pageSite == WebDomain.site(of: login.host) { return .site }
        return nil
    }

    /// The best strength over all of a login's addresses.
    public static func match(_ item: LoginItem, page: URL) -> Strength? {
        item.urls.compactMap { match(saved: $0, page: page) }.max()
    }

    /// `items` that match `page`, best first, then by title.
    public static func ranked(_ items: [LoginItem], page: URL) -> [LoginItem] {
        let scored: [(item: LoginItem, strength: Strength)] = items.compactMap { item in
            guard let strength = match(item, page: page) else { return nil }
            return (item, strength)
        }
        let sorted = scored.sorted { lhs, rhs in
            if lhs.strength != rhs.strength { return lhs.strength > rhs.strength }
            return lhs.item.title.localizedStandardCompare(rhs.item.title) == .orderedAscending
        }
        return sorted.map(\.item)
    }

    /// Narrows `items` to those a hint names: an item id, or text in the title or username.
    public static func filter(_ items: [LoginItem], hint: String?) -> [LoginItem] {
        guard let hint = hint?.trimmingCharacters(in: .whitespacesAndNewlines), !hint.isEmpty else { return items }
        let exact = items.filter { $0.itemID == hint || $0.id == hint }
        if !exact.isEmpty { return exact }
        return items.filter { $0.title.localizedCaseInsensitiveContains(hint) || $0.username.localizedCaseInsensitiveContains(hint) }
    }

    private struct Saved {
        var scheme: String?
        var host: String
        var port: Int?
    }

    /// A saved address, with or without a scheme ("example.com", "https://example.com/login", "localhost:3000").
    private static func parse(_ text: String) -> Saved? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        let hasScheme = trimmed.range(of: "^[A-Za-z][A-Za-z0-9+.-]*://", options: .regularExpression) != nil
        guard let components = URLComponents(string: hasScheme ? trimmed : "placeholder://" + trimmed),
            let host = components.host.map(WebDomain.normalize), !host.isEmpty
        else { return nil }
        let scheme = hasScheme ? components.scheme?.lowercased() : nil
        if let scheme, !["http", "https"].contains(scheme) { return nil }
        return Saved(scheme: scheme, host: host, port: components.port)
    }

    private static func defaultPort(_ scheme: String) -> Int { scheme == "https" ? 443 : 80 }
}
