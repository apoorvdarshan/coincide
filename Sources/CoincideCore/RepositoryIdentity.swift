import Foundation

/// Local repository enrichment. Locator URLs are display metadata, never authentication input.
public struct RepositoryIdentity: Codable, Sendable, Equatable {
    public struct Locator: Codable, Sendable, Equatable {
        public let source: String
        public let remoteName: String
        public let remoteURL: String
        enum CodingKeys: String, CodingKey { case source, remoteName; case remoteURL = "remoteUrl" }
        fileprivate init(remoteName: String, remoteURL: String) { source = "git-remote"; self.remoteName = remoteName; self.remoteURL = remoteURL }
        public init(from decoder: any Decoder) throws {
            let values = try decoder.container(keyedBy: CodingKeys.self)
            source = try values.decode(String.self, forKey: .source); remoteName = try values.decode(String.self, forKey: .remoteName)
            remoteURL = try values.decode(String.self, forKey: .remoteURL)
            guard source == "git-remote", RepositoryIdentity.validRemoteName(remoteName),
                  RepositoryIdentity.normalizedRemote(remoteURL)?.remoteURL == remoteURL else { throw CoincideError("The repository locator is invalid or contains private URL data.") }
        }
    }
    public struct Origin: Codable, Sendable, Equatable {
        public let canonicalKey: String
        public let displayName: String
        fileprivate init(canonicalKey: String, displayName: String) { self.canonicalKey = canonicalKey; self.displayName = displayName }
        enum CodingKeys: String, CodingKey { case canonicalKey, displayName }
        public init(from decoder: any Decoder) throws {
            let values = try decoder.container(keyedBy: CodingKeys.self)
            canonicalKey = try values.decode(String.self, forKey: .canonicalKey); displayName = try values.decode(String.self, forKey: .displayName)
            guard RepositoryIdentity.validOrigin(self) else { throw CoincideError("The repository origin identity is invalid.") }
        }
    }
    public struct Remote: Sendable, Equatable {
        public let canonicalKey: String
        public let remoteURL: String
        public let displayName: String
        public let provider: String
    }
    public let canonicalKey: String
    public let locator: Locator
    /// The worktree root, or the explicit Git directory for a bare repository.
    public let rootPath: String
    /// Empty at the root; nil when the project is outside it (a container of a bare Git dir).
    public let projectRelativePath: String?
    public let displayName: String
    public let provider: String
    public let owner: String?
    public let name: String
    public let origin: Origin?
    public var groupingKey: String { origin?.canonicalKey ?? canonicalKey }
    public var groupingDisplayName: String { origin?.displayName ?? displayName }

    public init(remote: Remote, remoteName: String, rootPath: String, projectRelativePath: String?, origin: Remote? = nil) throws {
        canonicalKey = remote.canonicalKey
        locator = .init(remoteName: remoteName, remoteURL: remote.remoteURL)
        self.rootPath = rootPath; self.projectRelativePath = projectRelativePath
        displayName = remote.displayName; provider = remote.provider
        let segments = remote.displayName.split(separator: "/")
        owner = segments.count > 1 ? segments.first.map(String.init) : nil
        name = segments.last.map(String.init) ?? remote.displayName
        self.origin = origin.flatMap { $0.canonicalKey == remote.canonicalKey ? nil : .init(canonicalKey: $0.canonicalKey, displayName: $0.displayName) }
        try validate()
    }
    enum CodingKeys: String, CodingKey { case canonicalKey, locator, rootPath, projectRelativePath, displayName, provider, owner, name, origin }
    public init(from decoder: any Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        canonicalKey = try values.decode(String.self, forKey: .canonicalKey); locator = try values.decode(Locator.self, forKey: .locator)
        rootPath = try values.decode(String.self, forKey: .rootPath); projectRelativePath = try values.decodeIfPresent(String.self, forKey: .projectRelativePath)
        displayName = try values.decode(String.self, forKey: .displayName); provider = try values.decode(String.self, forKey: .provider)
        owner = try values.decodeIfPresent(String.self, forKey: .owner); name = try values.decode(String.self, forKey: .name)
        origin = try values.decodeIfPresent(Origin.self, forKey: .origin); try validate()
    }
    /// Read-only structural validation, suitable for future journal decoding without filesystem I/O.
    public func validate() throws {
        guard locator.source == "git-remote", Self.validRemoteName(locator.remoteName),
              let remote = Self.normalizedRemote(locator.remoteURL), remote.remoteURL == locator.remoteURL,
              canonicalKey == remote.canonicalKey, displayName == remote.displayName, provider == remote.provider,
              rootPath.hasPrefix("/"), !rootPath.contains("\0"), URL(fileURLWithPath: rootPath).standardizedFileURL.path == rootPath,
              projectRelativePath.map({ !$0.hasPrefix("/") && !$0.contains("\0") && !$0.split(separator: "/").contains(where: { $0 == "." || $0 == ".." }) }) ?? true,
              origin.map({ Self.validOrigin($0) && $0.canonicalKey != canonicalKey }) ?? true else { throw CoincideError("The repository identity is invalid or contains private URL data.") }
        let segments = displayName.split(separator: "/")
        guard name == segments.last.map(String.init), owner == (segments.count > 1 ? segments.first.map(String.init) : nil) else {
            throw CoincideError("The repository identity has inconsistent display metadata.")
        }
    }
    private static func validRemoteName(_ name: String) -> Bool {
        !name.isEmpty && name.utf8.count <= 1_024 && !name.contains("://") && !name.unicodeScalars.contains(where: { $0.value < 32 || $0.value == 127 || CharacterSet.newlines.contains($0) })
    }
    private static func validOrigin(_ origin: Origin) -> Bool {
        guard let host = origin.canonicalKey.split(separator: "/").first else { return false }
        let url = "https://" + String(host) + "/" + origin.displayName
        guard let remote = normalizedRemote(url), remote.remoteURL == url else { return false }
        return remote.canonicalKey == origin.canonicalKey && remote.displayName == origin.displayName
    }

    /// Matches the pinned grouping keys, including port-insensitive URL identity and Azure SSH
    /// aliases. Local paths and arbitrary remote helpers are not repository identities. Credentials,
    /// queries, and fragments are discarded before any returned value can be encoded or displayed.
    public static func normalizedRemote(_ input: String) -> Remote? {
        guard !input.unicodeScalars.contains(where: { $0.value < 32 || $0.value == 127 || CharacterSet.newlines.contains($0) }) else { return nil }
        let raw = input.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !raw.isEmpty, raw.utf8.count <= 16_384, !raw.hasPrefix("-"),
              !raw.unicodeScalars.contains(where: { CharacterSet.whitespacesAndNewlines.contains($0) || $0.value < 32 || $0.value == 127 }),
              let decoded = raw.removingPercentEncoding,
              !decoded.unicodeScalars.contains(where: { $0.value < 32 || $0.value == 127 || CharacterSet.newlines.contains($0) }) else { return nil }
        let host: String, repositoryPath: String, sanitized: String
        if raw.contains("://") {
            guard var url = URLComponents(string: raw), let scheme = url.scheme?.lowercased(),
                  ["https", "http", "ssh", "git"].contains(scheme),
                  url.url != nil, let hostname = url.host, validHost(hostname),
                  url.port.map({ (1...65_535).contains($0) }) ?? true else { return nil }
            repositoryPath = url.percentEncodedPath
            url.user = nil; url.password = nil; url.query = nil; url.fragment = nil
            url.scheme = scheme; url.host = hostname.lowercased()
            guard let value = url.url?.absoluteString, let canonicalHost = asciiHost(in: value, scheme: scheme) else { return nil }
            host = canonicalHost; sanitized = value
        } else {
            // A drive prefix is local even without a slash; a username permits a one-letter host.
            if raw.count > 1, raw[raw.index(after: raw.startIndex)] == ":", raw.first?.isLetter == true { return nil }
            guard !raw.hasPrefix("/"), !raw.hasPrefix("."), !raw.hasPrefix("~"),
                  let expression = try? NSRegularExpression(pattern: "^(?:[A-Za-z0-9._~-]+@)?(\\[[0-9A-Fa-f:.]+\\]|[A-Za-z0-9._~-]+):/?(.+)$"),
                  let match = expression.firstMatch(in: raw, range: NSRange(raw.startIndex..., in: raw)),
                  let hostRange = Range(match.range(at: 1), in: raw), let pathRange = Range(match.range(at: 2), in: raw) else { return nil }
            host = String(raw[hostRange]).lowercased()
            guard validHost(host) else { return nil }
            let path = String(raw[pathRange].prefix(while: { $0 != "?" && $0 != "#" }))
            guard !path.contains("@"), !path.contains(":"), !path.contains("\\") else { return nil }
            if host.count == 1 || host.hasPrefix("[") {
                // Removing an SCP username must not turn a one-letter host into a drive path.
                guard let url = URLComponents(string: "ssh://" + host + "/" + path), let value = url.url?.absoluteString else { return nil }
                repositoryPath = url.percentEncodedPath; sanitized = value
            } else { repositoryPath = path; sanitized = host + ":" + path }
        }
        var path = repositoryPath.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        if path.lowercased().hasSuffix(".git") { path.removeLast(4) }
        let segments = path.split(separator: "/").map(String.init)
        guard !segments.isEmpty, segments.allSatisfy({ !$0.isEmpty && $0 != "." && $0 != ".." }) else { return nil }
        let key: String, display: String
        let lowered = segments.map { $0.lowercased() }
        if ["ssh.dev.azure.com", "vs-ssh.visualstudio.com"].contains(host), lowered.count == 4, lowered[0] == "v3" {
            key = host == "ssh.dev.azure.com" ? "dev.azure.com/\(lowered[1])/\(lowered[2])/_git/\(lowered[3])" : "\(lowered[1]).visualstudio.com/\(lowered[2])/_git/\(lowered[3])"
            // The pinned resolver falls back to the canonical path when the SSH spelling differs.
            display = key.split(separator: "/").dropFirst().joined(separator: "/")
        } else { key = host + "/" + lowered.joined(separator: "/"); display = segments.joined(separator: "/") }
        return .init(canonicalKey: key, remoteURL: sanitized, displayName: display, provider: provider(for: host))
    }
    private static func validHost(_ host: String) -> Bool {
        guard !host.isEmpty, !host.hasPrefix("-"), !host.hasPrefix(".") else { return false }
        if host.hasPrefix("[") && host.hasSuffix("]") {
            let address = host.dropFirst().dropLast()
            return address.filter({ $0 == ":" }).count >= 2 && address.utf8.allSatisfy { (48...57).contains($0) || (65...70).contains($0) || (97...102).contains($0) || $0 == 58 || $0 == 46 }
        }
        // Inspect the decoded host, not user/password properties alone: Foundation accepts
        // percent-encoded userinfo separators inside a host while reporting nil user/password.
        return host.unicodeScalars.allSatisfy { CharacterSet.alphanumerics.contains($0) || "._-".unicodeScalars.contains($0) }
    }
    private static func asciiHost(in absoluteURL: String, scheme: String) -> String? {
        // NSURL's absolute URL contains IDNA ASCII, while URLComponents.host decodes IDNs.
        let authority = absoluteURL.dropFirst(scheme.count + 3).prefix(while: { $0 != "/" && $0 != "?" && $0 != "#" })
        let host: String
        if authority.hasPrefix("[") {
            guard let end = authority.firstIndex(of: "]") else { return nil }
            host = String(authority[...end])
        } else { host = String(authority.prefix(while: { $0 != ":" })) }
        guard host.unicodeScalars.allSatisfy(\.isASCII), validHost(host) else { return nil }
        return host.lowercased()
    }
    private static func provider(for host: String) -> String {
        let labels = Set(host.split(separator: ".").map(String.init))
        if host == "github.com" || host.hasSuffix(".ghe.com") || labels.contains("github") { return "github" }
        if host == "gitlab.com" || labels.contains("gitlab") { return "gitlab" }
        if host == "codeberg.org" || !labels.isDisjoint(with: ["forgejo", "gitea"]) { return "forgejo" }
        if host == "dev.azure.com" || host.hasSuffix(".dev.azure.com") || host.hasSuffix(".visualstudio.com") { return "azure-devops" }
        if host == "bitbucket.org" || labels.contains("bitbucket") { return "bitbucket" }
        if host == "git.cafe" || host == "staging.git.cafe" { return "gitcafe" }
        return "unknown"
    }
}
