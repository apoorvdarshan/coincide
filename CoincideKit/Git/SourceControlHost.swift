import Foundation

/// The source control hosts Coincide knows, as T3 Code's `source-control-*` packages define them.
public enum SourceControlKind: String, Sendable, Hashable, CaseIterable {
    case github
    case gitlab
    case gitcafe
    case forgejo
    case bitbucket
    case azureDevOps = "azure-devops"
    /// A host none of the others claims. Coincide leaves it to `gh`, as it did before it knew other
    /// hosts, since GitHub Enterprise runs on any host name.
    case unknown

    /// What the host calls a request to merge a branch.
    public nonisolated var changeRequest: ChangeRequestTerm { self == .gitlab ? .mergeRequest : .pullRequest }
}

/// What a host calls a request to merge one branch into another: GitLab's merge requests and
/// everyone else's pull requests (T3 Code's `ChangeRequestTerminology`).
public enum ChangeRequestTerm: Sendable, Hashable {
    case pullRequest
    case mergeRequest

    /// "PR" or "MR".
    public nonisolated var shortLabel: String {
        switch self {
        case .pullRequest: String(localized: "PR", comment: "Short for pull request")
        case .mergeRequest: String(localized: "MR", comment: "Short for merge request")
        }
    }

    /// "Pull Request" or "Merge Request", for menu items.
    public nonisolated var title: String {
        switch self {
        case .pullRequest: String(localized: "Pull Request")
        case .mergeRequest: String(localized: "Merge Request")
        }
    }

    /// How the host refers to one: `#12` for a pull request, `!12` for a GitLab merge request.
    public nonisolated func reference(_ number: Int) -> String {
        (self == .mergeRequest ? "!" : "#") + String(number)
    }
}

// MARK: Remotes

/// A git remote's address read into its host and repository path, as T3 Code's
/// `parseGitRemoteHost` and `parseGitRemoteRepository` read it. User names and passwords in the
/// address are dropped and never kept.
public struct GitRemoteURL: Sendable, Hashable {
    public enum Transport: Sendable, Hashable {
        case https
        case http
        /// `ssh://`, `git+ssh://`, or scp-like `user@host:path`.
        case ssh
        case git
    }

    public var transport: Transport
    /// Lower case, without a port.
    public var hostname: String
    /// The port the address names, if any.
    public var port: Int?
    /// The repository path's segments, percent-decoded, without a trailing `.git`.
    public var path: [String]

    public nonisolated init(transport: Transport, hostname: String, port: Int? = nil, path: [String]) {
        self.transport = transport
        self.hostname = hostname
        self.port = port
        self.path = path
    }

    /// Lower case. Keeps the port of an HTTP remote, never an SSH one, whose port is not the web server's.
    public nonisolated var host: String {
        guard let port, transport == .https || transport == .http else { return hostname }
        return "\(hostname):\(port)"
    }

    /// Nil for a remote that names no host, such as a local path or a `file://` URL.
    public nonisolated static func parse(_ remote: String) -> GitRemoteURL? {
        let trimmed = remote.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, !trimmed.contains(where: \.isNewline) else { return nil }
        if let separator = trimmed.range(of: "://") {
            return parseURL(scheme: trimmed[..<separator.lowerBound].lowercased(), rest: trimmed[separator.upperBound...])
        }
        return parseSCP(trimmed)
    }

    private nonisolated static func parseURL(scheme: String, rest: Substring) -> GitRemoteURL? {
        let transport: Transport
        switch scheme {
        case "https": transport = .https
        case "http": transport = .http
        case "ssh", "git+ssh", "ssh+git": transport = .ssh
        case "git": transport = .git
        default: return nil
        }
        let authorityEnd = rest.firstIndex { $0 == "/" || $0 == "?" || $0 == "#" } ?? rest.endIndex
        var authority = rest[..<authorityEnd]
        // Credentials end at the last `@`; a password may contain an escaped one.
        if let at = authority.lastIndex(of: "@") { authority = authority[authority.index(after: at)...] }
        guard let (hostname, port) = splitHostAndPort(authority) else { return nil }
        var pathPart = rest[authorityEnd...]
        if let end = pathPart.firstIndex(where: { $0 == "?" || $0 == "#" }) { pathPart = pathPart[..<end] }
        return GitRemoteURL(transport: transport, hostname: hostname, port: port, path: segments(pathPart))
    }

    /// `[user@]host:path`, which git reads as SSH when a colon comes before any slash.
    private nonisolated static func parseSCP(_ value: String) -> GitRemoteURL? {
        guard let colon = value.firstIndex(of: ":") else { return nil }
        let prefix = value[..<colon]
        guard !prefix.isEmpty, !prefix.contains("/"), !prefix.contains("\\") else { return nil }
        var hostPart = prefix
        var hasUser = false
        if let at = prefix.lastIndex(of: "@") {
            hostPart = prefix[prefix.index(after: at)...]
            hasUser = true
        }
        // A userless one-letter prefix is a Windows drive, not a host.
        if !hasUser, hostPart.count == 1 { return nil }
        let hostname = hostPart.lowercased()
        guard isHostName(hostname) else { return nil }
        let path = segments(value[value.index(after: colon)...])
        // Without a user, `name:path` is only a remote when it names an `owner/repository` path.
        if !hasUser, path.count < 2 { return nil }
        return GitRemoteURL(transport: .ssh, hostname: hostname, port: nil, path: path)
    }

    private nonisolated static func splitHostAndPort(_ authority: Substring) -> (String, Int?)? {
        var host = authority
        var portText: Substring?
        if authority.hasPrefix("[") {
            guard let close = authority.firstIndex(of: "]") else { return nil }
            host = authority[...close]
            let after = authority[authority.index(after: close)...]
            if after.hasPrefix(":") { portText = after.dropFirst() } else if !after.isEmpty { return nil }
        } else if let colon = authority.lastIndex(of: ":") {
            host = authority[..<colon]
            portText = authority[authority.index(after: colon)...]
        }
        let hostname = host.lowercased()
        guard isHostName(hostname) else { return nil }
        guard let portText, !portText.isEmpty else { return (hostname, nil) }
        guard portText.allSatisfy(\.isASCIIDigit), let port = Int(portText), (1...65_535).contains(port) else {
            return nil
        }
        return (hostname, port)
    }

    /// Host names as git accepts them, SSH aliases from `~/.ssh/config` included, or a bracketed IPv6 address.
    private nonisolated static func isHostName(_ value: String) -> Bool {
        if value.hasPrefix("[") {
            return value.count > 2 && value.hasSuffix("]")
                && value.dropFirst().dropLast().allSatisfy { $0.isHexDigit || $0 == ":" || $0 == "." }
        }
        return !value.isEmpty && !value.hasPrefix("-") && !value.hasPrefix(".")
            && value.allSatisfy { ($0.isASCII && ($0.isLetter || $0.isNumber)) || $0 == "." || $0 == "-" || $0 == "_" }
    }

    private nonisolated static func segments(_ path: Substring) -> [String] {
        var parts = path.split(separator: "/").map { String($0).removingPercentEncoding ?? String($0) }
        if let last = parts.last, last.lowercased().hasSuffix(".git") {
            let name = String(last.dropLast(4))
            if name.isEmpty { parts.removeLast() } else { parts[parts.count - 1] = name }
        }
        return parts.filter { !$0.isEmpty }
    }
}

extension Character {
    fileprivate nonisolated var isASCIIDigit: Bool { isASCII && isNumber }
}

// MARK: Hosts

/// The host a repository's remote is on, and its web pages for that repository.
public struct SourceControlHost: Sendable, Hashable {
    public var kind: SourceControlKind
    /// T3 Code's name for the provider, such as "GitHub" or "GitLab Self-Hosted"; the host for an unknown one.
    public var name: String
    public var remote: GitRemoteURL

    public nonisolated init(kind: SourceControlKind, name: String, remote: GitRemoteURL) {
        self.kind = kind
        self.name = name
        self.remote = remote
    }

    /// GitCafe has no self-hosted installs: production and staging are its only hosts.
    nonisolated static let gitCafeHosts: Set<String> = ["git.cafe", "staging.git.cafe"]

    /// The host a remote is on, or nil for a remote that names no host (a local path).
    public nonisolated static func recognize(remoteURL: String) -> SourceControlHost? {
        GitRemoteURL.parse(remoteURL).map(recognize)
    }

    /// Claims the remote for the first host that recognizes its name, in T3 Code's recognition order,
    /// which differs from display order because a name can carry several hosts' labels
    /// (`gitea.github.example`).
    public nonisolated static func recognize(_ remote: GitRemoteURL) -> SourceControlHost {
        let hostname = remote.hostname
        let labels = Set(hostname.split(separator: ".").map(String.init))
        if gitCafeHosts.contains(hostname) {
            return SourceControlHost(kind: .gitcafe, name: "GitCafe", remote: remote)
        }
        if hostname == "codeberg.org" || labels.contains("forgejo") || labels.contains("gitea") {
            return SourceControlHost(kind: .forgejo, name: "Forgejo", remote: remote)
        }
        // `*.ghe.com` is GitHub Enterprise Cloud with data residency, one subdomain per enterprise.
        if hostname == "github.com" || hostname.hasSuffix(".ghe.com") || labels.contains("github") {
            return SourceControlHost(
                kind: .github, name: hostname == "github.com" ? "GitHub" : "GitHub Self-Hosted", remote: remote)
        }
        if hostname == "gitlab.com" || labels.contains("gitlab") {
            return SourceControlHost(
                kind: .gitlab, name: hostname == "gitlab.com" ? "GitLab" : "GitLab Self-Hosted", remote: remote)
        }
        // `ssh.dev.azure.com` is the SSH clone host; legacy organizations stay under `.visualstudio.com`.
        if hostname == "dev.azure.com" || hostname.hasSuffix(".dev.azure.com") || hostname.hasSuffix(".visualstudio.com") {
            return SourceControlHost(kind: .azureDevOps, name: "Azure DevOps", remote: remote)
        }
        if hostname == "bitbucket.org" || labels.contains("bitbucket") {
            return SourceControlHost(
                kind: .bitbucket, name: hostname == "bitbucket.org" ? "Bitbucket" : "Bitbucket Self-Hosted",
                remote: remote)
        }
        return SourceControlHost(kind: .unknown, name: remote.host, remote: remote)
    }

    /// The name to show, such as "GitLab" or "Codeberg".
    public nonisolated var displayName: String {
        switch kind {
        case .github: "GitHub"
        case .gitlab: "GitLab"
        case .gitcafe: "GitCafe"
        case .bitbucket: "Bitbucket"
        case .azureDevOps: "Azure DevOps"
        case .forgejo:
            if remote.hostname == "codeberg.org" {
                "Codeberg"
            } else if remote.hostname.split(separator: ".").contains("gitea") {
                "Gitea"
            } else {
                "Forgejo"
            }
        case .unknown: remote.hostname
        }
    }

    // MARK: Web pages

    /// The host's web address. Always `https`: an HTTP remote's host is asked for over HTTPS, and nil
    /// when that can't be named, as for an HTTP remote on a port of its own. SSH ports are never the
    /// web server's, so they are dropped.
    public nonisolated var webOrigin: URL? {
        guard let (hostname, port) = webHostAndPort,
            !hostname.hasPrefix("["), !hostname.contains("_")  // Not web host names.
        else { return nil }
        var components = URLComponents()
        components.scheme = "https"
        components.host = hostname
        components.port = port
        return components.url
    }

    private nonisolated var webHostAndPort: (String, Int?)? {
        // Azure names one repository differently over SSH and on the web.
        if kind == .azureDevOps, remote.path.first == "v3", remote.path.count == 4 {
            if remote.hostname == "ssh.dev.azure.com" { return ("dev.azure.com", nil) }
            if remote.hostname == "vs-ssh.visualstudio.com" { return ("\(remote.path[1].lowercased()).visualstudio.com", nil) }
        }
        switch remote.transport {
        case .https: return (remote.hostname, remote.port == 443 ? nil : remote.port)
        case .http: return remote.port == nil || remote.port == 80 ? (remote.hostname, nil) : nil
        case .ssh, .git: return (remote.hostname, nil)
        }
    }

    /// Whether this is Bitbucket Data Center (Server), whose pages differ from bitbucket.org's.
    nonisolated var isBitbucketServer: Bool {
        kind == .bitbucket && remote.hostname != "bitbucket.org" && !remote.hostname.hasSuffix(".bitbucket.org")
    }

    /// The repository's path on the host's web pages, such as `group/project` or
    /// `org/project/_git/repository`. Nil when the remote's path is not one the host serves.
    public nonisolated var repositoryWebPath: [String]? {
        let path = remote.path
        guard !path.contains(where: { $0 == "." || $0 == ".." }) else { return nil }
        switch kind {
        case .github, .gitcafe:
            return path.count == 2 ? path : nil
        case .gitlab, .forgejo, .unknown:
            return path.count >= 2 ? path : nil
        case .bitbucket:
            guard isBitbucketServer else { return path.count == 2 ? path : nil }
            // Data Center clones over `<context>/scm/<project>/<repository>` (HTTP) or `<project>/<repository>` (SSH).
            let scm = path.firstIndex { $0.lowercased() == "scm" }
            let context = scm.map { Array(path[..<$0]) } ?? []
            let rest = scm.map { Array(path[path.index(after: $0)...]) } ?? path
            guard rest.count == 2 else { return nil }
            let (project, repository) = (rest[0], rest[1])
            if project.hasPrefix("~") { return context + ["users", String(project.dropFirst()), "repos", repository] }
            return context + ["projects", project, "repos", repository]
        case .azureDevOps:
            if path.first == "v3", path.count == 4, remote.hostname == "ssh.dev.azure.com" {
                return [path[1], path[2], "_git", path[3]]
            }
            if path.first == "v3", path.count == 4, remote.hostname == "vs-ssh.visualstudio.com" {
                return [path[2], "_git", path[3]]
            }
            guard path.count >= 3, path[path.count - 2] == "_git" else { return nil }
            return path
        }
    }

    /// The repository's home page.
    public nonisolated var repositoryURL: URL? {
        webURL(route: [], query: [])
    }

    /// The host's page for opening a pull or merge request from `head` into `base`, as the host itself
    /// links to it after a push. Nil for hosts without one (GitCafe) or an unknown host.
    public nonisolated func newChangeRequestURL(base: String, head: String) -> URL? {
        guard Self.isBranchName(base), Self.isBranchName(head) else { return nil }
        switch kind {
        case .github:
            return webURL(route: ["compare"], rawTail: "\(Self.encodeBranch(base))...\(Self.encodeBranch(head))", query: [("expand", "1")])
        case .forgejo:
            return webURL(route: ["compare"], rawTail: "\(Self.encodeBranch(base))...\(Self.encodeBranch(head))", query: [])
        case .gitlab:
            return webURL(
                route: ["-", "merge_requests", "new"],
                query: [("merge_request[source_branch]", head), ("merge_request[target_branch]", base)])
        case .bitbucket:
            if isBitbucketServer {
                return webURL(
                    route: ["pull-requests"],
                    query: [("create", nil), ("sourceBranch", "refs/heads/\(head)"), ("targetBranch", "refs/heads/\(base)")])
            }
            return webURL(route: ["pull-requests", "new"], query: [("source", head), ("dest", base), ("t", "1")])
        case .azureDevOps:
            return webURL(route: ["pullrequestcreate"], query: [("sourceRef", head), ("targetRef", base)])
        case .gitcafe, .unknown:
            return nil
        }
    }

    /// The page of change request `number` (T3 Code's `changeRequestUrl`).
    public nonisolated func changeRequestURL(number: Int) -> URL? {
        guard number > 0 else { return nil }
        let route: [String]
        switch kind {
        case .github: route = ["pull"]
        case .gitlab: route = ["-", "merge_requests"]
        case .bitbucket: route = ["pull-requests"]
        case .azureDevOps: route = ["pullrequest"]
        case .forgejo, .gitcafe: route = ["pulls"]
        case .unknown: return nil
        }
        return webURL(route: route + [String(number)], query: [])
    }

    private nonisolated func webURL(route: [String], rawTail: String? = nil, query: [(String, String?)]) -> URL? {
        guard let origin = webOrigin, let path = repositoryWebPath, !path.isEmpty else { return nil }
        var encoded = (path + route).map(Self.encodePathSegment)
        if let rawTail { encoded.append(rawTail) }
        var components = URLComponents(url: origin, resolvingAgainstBaseURL: false)
        components?.percentEncodedPath = "/" + encoded.joined(separator: "/")
        if !query.isEmpty {
            components?.percentEncodedQuery = query.map { name, value in
                value.map { "\(Self.encodeQuery(name))=\(Self.encodeQuery($0))" } ?? Self.encodeQuery(name)
            }.joined(separator: "&")
        }
        guard let url = components?.url, url.scheme == "https" else { return nil }
        return url
    }

    /// Branch names as git allows them, so `..` can't step out of the repository's pages.
    private nonisolated static func isBranchName(_ name: String) -> Bool {
        !name.isEmpty && !name.contains("..") && !name.hasPrefix("/") && !name.hasSuffix("/")
            && !name.contains(where: { $0.isNewline || $0 == "\\" })
    }

    nonisolated static let unreserved = CharacterSet(
        charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-._~")
    private nonisolated static let pathSegmentAllowed = unreserved.union(CharacterSet(charactersIn: "!$&'()*+,;=:@"))
    private nonisolated static let branchAllowed = pathSegmentAllowed.union(CharacterSet(charactersIn: "/"))

    /// Percent-encodes one path segment, keeping only the ASCII a path segment allows.
    nonisolated static func encodePathSegment(_ value: String) -> String {
        value.addingPercentEncoding(withAllowedCharacters: pathSegmentAllowed) ?? ""
    }

    /// A branch in a path keeps its slashes, as hosts write `compare/main...feature/x`.
    private nonisolated static func encodeBranch(_ value: String) -> String {
        value.addingPercentEncoding(withAllowedCharacters: branchAllowed) ?? ""
    }

    /// Percent-encodes everything but ASCII letters, digits and `-._~`.
    nonisolated static func encodeQuery(_ value: String) -> String {
        value.addingPercentEncoding(withAllowedCharacters: unreserved) ?? ""
    }
}

// MARK: Change request links

/// A pull or merge request page, read from its URL (T3 Code's `parseChangeRequestUrl`).
public struct ChangeRequestLink: Sendable, Hashable {
    public var kind: SourceControlKind
    /// Lower case, without a port.
    public var host: String
    /// The repository path, lower case, such as `group/project`.
    public var repository: String
    public var number: Int

    public nonisolated init(kind: SourceControlKind, host: String, repository: String, number: Int) {
        self.kind = kind
        self.host = host
        self.repository = repository
        self.number = number
    }

    /// Nil when `string` is not an http(s) URL of a change request page. GitCafe claims first, because
    /// GitHub and Forgejo accept the same routes on any host name.
    public nonisolated static func parse(_ string: String) -> ChangeRequestLink? {
        guard let components = URLComponents(string: string.trimmingCharacters(in: .whitespacesAndNewlines)),
            let scheme = components.scheme?.lowercased(), scheme == "https" || scheme == "http",
            let host = components.host?.lowercased(), !host.isEmpty
        else { return nil }
        let segments = components.percentEncodedPath.split(separator: "/").map(String.init)
        func link(_ kind: SourceControlKind, _ repository: ArraySlice<String>, _ number: String) -> ChangeRequestLink? {
            guard !repository.isEmpty, number.allSatisfy(\.isASCIIDigit), let value = Int(number), value > 0 else {
                return nil
            }
            return ChangeRequestLink(
                kind: kind, host: host, repository: repository.joined(separator: "/").lowercased(), number: value)
        }
        // `/<owner>/<repository>/<route>/<number>`, routes that never nest groups.
        func twoSegment(_ kind: SourceControlKind, _ routes: Set<String>) -> ChangeRequestLink? {
            guard segments.count >= 4, routes.contains(segments[2]) else { return nil }
            return link(kind, segments[0..<2], segments[3])
        }
        if SourceControlHost.gitCafeHosts.contains(host), let found = twoSegment(.gitcafe, ["pull", "pulls"]) {
            return found
        }
        if let found = twoSegment(.github, ["pull"]) { return found }
        // GitLab nests projects in groups: `/<group>/<subgroup>/<project>/-/merge_requests/<n>`.
        if let dash = segments.lastIndex(of: "-"), dash >= 2, segments.count > dash + 2,
            segments[dash + 1] == "merge_requests", let found = link(.gitlab, segments[..<dash], segments[dash + 2])
        {
            return found
        }
        // Forgejo and Gitea can be mounted below a path.
        if let pulls = segments.lastIndex(of: "pulls"), pulls >= 2, segments.count > pulls + 1,
            let found = link(.forgejo, segments[..<pulls], segments[pulls + 1])
        {
            return found
        }
        if host == "bitbucket.org" || host.split(separator: ".").contains("bitbucket"),
            let found = twoSegment(.bitbucket, ["pull-requests"])
        {
            return found
        }
        // Azure DevOps Server runs on any host name; its `_git` route identifies it.
        if let git = segments.lastIndex(of: "_git"), segments.count > git + 3, segments[git + 2] == "pullrequest",
            let found = link(.azureDevOps, segments[...(git + 1)], segments[git + 3])
        {
            return found
        }
        return nil
    }
}
