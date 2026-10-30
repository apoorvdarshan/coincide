import Foundation

/// The search engine the browser's address bar searches with when what's typed isn't an address.
public enum SearchEngine: String, Codable, CaseIterable, Hashable, Sendable {
    case google
    case duckDuckGo
    case bing
    case brave
    case ecosia
    case kagi

    public nonisolated var name: String {
        switch self {
        case .google: "Google"
        case .duckDuckGo: "DuckDuckGo"
        case .bing: "Bing"
        case .brave: "Brave Search"
        case .ecosia: "Ecosia"
        case .kagi: "Kagi"
        }
    }

    private nonisolated var base: String {
        switch self {
        case .google: "https://www.google.com/search"
        case .duckDuckGo: "https://duckduckgo.com/"
        case .bing: "https://www.bing.com/search"
        case .brave: "https://search.brave.com/search"
        case .ecosia: "https://www.ecosia.org/search"
        case .kagi: "https://kagi.com/search"
        }
    }

    /// The results page for `query`.
    public nonisolated func url(for query: String) -> URL? {
        var components = URLComponents(string: base)
        components?.queryItems = [URLQueryItem(name: "q", value: query)]
        return components?.url
    }
}

/// What the address bar opens for what the user typed: a web address when it looks like one (development servers,
/// IP addresses and `.local` names included, over HTTP), a local file by its path, and otherwise a search. A leading
/// `?` always searches.
public enum BrowserAddress {
    public enum Destination: Equatable, Sendable {
        case web(URL)
        case file(URL)
        case search(URL)

        public var url: URL {
            switch self {
            case .web(let url), .file(let url), .search(let url): url
            }
        }
    }

    /// Endings of files and code that are not web domains, so `notes.txt` or `next.js` searches instead of failing.
    static let fileEndings: Set<String> = [
        "c", "cpp", "css", "csv", "env", "gif", "h", "htm", "html", "java", "jpeg", "jpg", "js", "json", "jsx", "kt", "lock",
        "log", "mjs", "pdf", "png", "py", "sh", "svg", "swift", "toml", "ts", "tsx", "txt", "xml", "yaml", "yml", "zip",
    ]

    /// `allowsFiles` lets paths (`/…`, `~/…`, `file://…`) open existing local files; only the user's own typing does.
    public nonisolated static func resolve(
        _ text: String, engine: SearchEngine, allowsFiles: Bool, home: URL = FileManager.default.homeDirectoryForCurrentUser
    ) -> Destination? {
        let typed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !typed.isEmpty, typed.utf8.count <= 8192 else { return nil }
        if typed.hasPrefix("?") {
            let query = typed.dropFirst().trimmingCharacters(in: .whitespaces)
            return query.isEmpty ? nil : engine.url(for: query).map(Destination.search)
        }
        if let file = fileURL(typed, home: home) {
            guard allowsFiles else { return nil }
            var isDirectory: ObjCBool = false
            if FileManager.default.fileExists(atPath: file.path, isDirectory: &isDirectory), !isDirectory.boolValue {
                return .file(file)
            }
            return typed.lowercased().hasPrefix("file:") ? nil : engine.url(for: typed).map(Destination.search)
        }
        if typed.contains("://") {
            return PreviewCommand.url(typed).map(Destination.web)
        }
        if looksLikeAddress(typed), let url = PreviewCommand.url(typed) { return .web(url) }
        return engine.url(for: typed).map(Destination.search)
    }

    /// A path to a local file: `file:` addresses, absolute paths and `~/` paths.
    nonisolated static func fileURL(_ typed: String, home: URL) -> URL? {
        if typed.lowercased().hasPrefix("file:") {
            guard let url = URL(string: typed), url.isFileURL, !url.path.isEmpty else { return nil }
            return url.standardizedFileURL
        }
        if typed.hasPrefix("/") { return URL(fileURLWithPath: typed).standardizedFileURL }
        if typed.hasPrefix("~/") { return home.appendingPathComponent(String(typed.dropFirst(2))).standardizedFileURL }
        return nil
    }

    /// Whether text without a scheme names a site rather than being words to search: no spaces, and a host that is a
    /// development server (localhost, an IP address, `.local`, a port), or a domain whose last part isn't a file ending.
    nonisolated static func looksLikeAddress(_ typed: String) -> Bool {
        guard !typed.contains(where: \.isWhitespace) else { return false }
        let authority = typed.split(whereSeparator: { "/?#".contains($0) }).first.map(String.init) ?? typed
        let host = (authority.hasPrefix("[") ? authority : String(authority.split(separator: ":").first ?? "")).lowercased()
        if authority.hasPrefix("[") { return true }
        let hasPort = authority.contains(":")
        if host == "localhost" || host.hasSuffix(".localhost") || host.hasSuffix(".local") || hasPort { return true }
        let labels = host.split(separator: ".", omittingEmptySubsequences: false)
        if labels.count == 4, labels.allSatisfy({ UInt8($0) != nil }) { return true }
        // A single word searches, unless typed as a path such as `devbox/`.
        guard labels.count > 1 else { return typed.hasPrefix(host + "/") }
        guard labels.allSatisfy({ !$0.isEmpty }), let last = labels.last else { return false }
        return last.count >= 2 && last.allSatisfy(\.isLetter) && !fileEndings.contains(String(last))
    }
}
