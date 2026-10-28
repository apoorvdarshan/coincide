import Foundation

/// A host's own command-line tool for pull and merge requests, run with the user's own sign-in, as
/// T3 Code's source control providers run them.
public enum ChangeRequestTool: String, Sendable, Hashable, CaseIterable {
    /// GitHub CLI.
    case gh
    /// GitLab CLI.
    case glab
    /// Azure CLI with its `azure-devops` extension.
    case az
    /// Gitea CLI, which also signs in to Forgejo servers such as Codeberg.
    case tea

    /// What to install and run so Coincide can use the tool.
    public nonisolated var setupMessage: String {
        switch self {
        case .gh: GitHubCLI.notReadyMessage
        case .glab: String(localized: "Install the GitLab CLI (glab) and run “glab auth login” to create merge requests.")
        case .az:
            String(
                localized:
                    "Install the Azure CLI (az) with its azure-devops extension and run “az login” to create pull requests.")
        case .tea: String(localized: "Install the Gitea CLI (tea) and run “tea login add” for this server to create pull requests.")
        }
    }

    /// Settings for this run only: never prompt, never install or update anything.
    nonisolated var environment: [String: String] {
        switch self {
        case .gh, .tea: [:]
        case .glab: ["NO_PROMPT": "1", "GLAB_CHECK_UPDATE": "false"]
        case .az:
            [
                "AZURE_CORE_ONLY_SHOW_ERRORS": "true", "AZURE_CORE_NO_COLOR": "true",
                // `az` offers to install a missing extension; Coincide never changes the user's setup.
                "AZURE_EXTENSION_USE_DYNAMIC_INSTALL": "no",
            ]
        }
    }
}

extension SourceControlKind {
    /// The tool Coincide uses for this host's change requests. Bitbucket and GitCafe have no CLI that
    /// does, so their pull requests are opened on the web.
    public nonisolated var tool: ChangeRequestTool? {
        switch self {
        case .github, .unknown: .gh
        case .gitlab: .glab
        case .azureDevOps: .az
        case .forgejo: .tea
        case .bitbucket, .gitcafe: nil
        }
    }
}

// MARK: Commands

/// The arguments each tool runs with, following T3 Code's `GitLabCli`, `AzureDevOpsCli` and `ForgejoCli`.
enum ChangeRequestCommands {
    // MARK: GitLab

    nonisolated static func glabAuthStatus(host: String) -> [String] {
        ["auth", "status", "--hostname", host]
    }

    nonisolated static func glabOpenMergeRequests(branch: String) -> [String] {
        ["mr", "list", "--source-branch", branch, "--per-page", "20", "--output", "json"]
    }

    /// Through the API rather than `glab mr create`, which can prompt: the description comes from a
    /// file and the reply is the merge request itself.
    nonisolated static func glabCreateMergeRequest(base: String, head: String, title: String, bodyFile: String)
        -> [String]
    {
        [
            "api", "--method", "POST", "projects/:fullpath/merge_requests",
            "--raw-field", "source_branch=\(head)",
            "--raw-field", "target_branch=\(base)",
            "--raw-field", "title=\(title)",
            "--field", "description=@\(bodyFile)",
        ]
    }

    nonisolated static let glabProject = ["api", "projects/:fullpath"]

    // MARK: Azure DevOps

    nonisolated static let azAccount = ["account", "show", "--query", "user.name", "--output", "tsv"]
    nonisolated static let azExtension = ["extension", "show", "--name", "azure-devops", "--output", "none"]

    nonisolated static func azOpenPullRequests(branch: String) -> [String] {
        [
            "repos", "pr", "list", "--detect", "true", "--source-branch", branch, "--status", "active", "--top", "20",
            "--only-show-errors", "--output", "json",
        ]
    }

    /// The title goes through a file too: `az` would read a title such as `@notes` from a file.
    nonisolated static func azCreatePullRequest(base: String, head: String, titleFile: String, bodyFile: String)
        -> [String]
    {
        [
            "repos", "pr", "create", "--detect", "true", "--target-branch", base, "--source-branch", head,
            "--title", "@\(titleFile)", "--description", "@\(bodyFile)", "--only-show-errors", "--output", "json",
        ]
    }

    nonisolated static let azRepository = ["repos", "show", "--detect", "true", "--only-show-errors", "--output", "json"]

    /// `az` replaces an argument, or the part after its first `=`, that starts with `@` by the contents
    /// of that file. Branch names never go through a file, so one with an `@` is not given to it.
    nonisolated static func azTakesLiterally(_ value: String) -> Bool {
        !value.contains("@")
    }

    // MARK: Forgejo and Gitea

    nonisolated static let teaLogins = ["login", "list", "--output", "json"]

    /// `tea api` reports the response status on standard error (`--include`), not in its exit status.
    nonisolated static func teaAPI(login: String, repository: String, method: String, url: String, hasBody: Bool)
        -> [String]
    {
        ["api", "--include", "--login", login, "--repo", repository, "--method", method]
            + (hasBody ? ["--data", "@-"] : []) + [url]
    }

    /// `<server>/api/v1/repos/<owner>/<repository>[/<route>]`, or nil when the login's server is not
    /// an http(s) address.
    nonisolated static func teaAPIURL(login: TeaLogin, repository: String, route: String?) -> String? {
        guard let server = GitRemoteURL.parse(login.url), server.transport == .https || server.transport == .http
        else { return nil }
        let base = login.url.trimmingCharacters(in: .whitespacesAndNewlines).replacing(/\/+$/, with: "")
        let segments = repository.split(separator: "/").map { SourceControlHost.encodePathSegment(String($0)) }
        return "\(base)/api/v1/repos/\(segments.joined(separator: "/"))" + (route.map { "/\($0)" } ?? "")
    }

    nonisolated static func teaOpenPullRequestsRoute(branch: String) -> String {
        "pulls?state=open&head=\(SourceControlHost.encodeQuery(branch))&sort=recentupdate&limit=50&page=1"
    }
}

/// A `tea login list --output json` entry.
struct TeaLogin: Sendable, Hashable {
    var name: String
    var url: String
    var sshHost: String?
    var user: String
    var isDefault: Bool
}

// MARK: Output

/// Reads what the tools print into Coincide's models (T3 Code's `*PullRequestJson` decoders).
/// Entries that don't read are skipped rather than failing the list.
enum ChangeRequestJSON {
    // MARK: GitLab

    nonisolated static func gitLabMergeRequests(_ output: String, host: SourceControlHost?) -> [GitPullRequest]? {
        JSONValue.parse(output)?.array?.compactMap { gitLabMergeRequest($0, host: host) }
    }

    nonisolated static func gitLabMergeRequest(_ output: String, host: SourceControlHost?) -> GitPullRequest? {
        JSONValue.parse(output).flatMap { gitLabMergeRequest($0, host: host) }
    }

    nonisolated static func gitLabMergeRequest(_ value: JSONValue, host: SourceControlHost?) -> GitPullRequest? {
        guard let number = value["iid"]?.exactInt, number > 0, let title = text(value["title"]),
            let head = text(value["source_branch"]), let base = text(value["target_branch"])
        else { return nil }
        let state: GitPullRequest.State =
            switch value["state"]?.string?.lowercased() {
            case "merged": .merged
            case "closed": .closed
            default: .open
            }
        return GitPullRequest(
            number: number, url: webURL(value["web_url"]?.string, number: number, host: host), title: title,
            state: state, baseBranch: base, headBranch: head,
            isDraft: value["draft"]?.bool == true || value["work_in_progress"]?.bool == true)
    }

    nonisolated static func gitLabDefaultBranch(_ output: String) -> String? {
        text(JSONValue.parse(output)?["default_branch"])
    }

    // MARK: Azure DevOps

    nonisolated static func azurePullRequests(_ output: String, host: SourceControlHost?) -> [GitPullRequest]? {
        JSONValue.parse(output)?.array?.compactMap { azurePullRequest($0, host: host) }
    }

    nonisolated static func azurePullRequest(_ output: String, host: SourceControlHost?) -> GitPullRequest? {
        JSONValue.parse(output).flatMap { azurePullRequest($0, host: host) }
    }

    nonisolated static func azurePullRequest(_ value: JSONValue, host: SourceControlHost?) -> GitPullRequest? {
        guard let number = value["pullRequestId"]?.exactInt, number > 0, let title = text(value["title"]),
            let head = text(value["sourceRefName"]).map(branchName), let base = text(value["targetRefName"]).map(branchName),
            let status = value["status"]?.string
        else { return nil }
        let state: GitPullRequest.State =
            switch status.lowercased() {
            case "completed": .merged
            case "abandoned": .closed
            default: .open
            }
        let url =
            azurePullRequestWebURL(
                number: number, webLink: value.at("_links.web.href")?.string,
                repositoryWebURL: value.at("repository.webUrl")?.string, restURL: value["url"]?.string,
                project: value.at("repository.project.name")?.string, repository: value.at("repository.name")?.string)
            ?? webURL(nil, number: number, host: host)
        return GitPullRequest(
            number: number, url: url, title: title, state: state, baseBranch: base, headBranch: head,
            isDraft: value["isDraft"]?.bool == true)
    }

    /// The pull request's page: its web link, else below the repository's page, else built from the
    /// organization in its REST address (T3 Code's `azureDevOpsPullRequestWebUrl`).
    nonisolated static func azurePullRequestWebURL(
        number: Int, webLink: String?, repositoryWebURL: String?, restURL: String?, project: String?,
        repository: String?
    ) -> String? {
        if let link = httpURL(webLink) { return link }
        if let repositoryWebURL = httpURL(repositoryWebURL) {
            return repositoryWebURL.replacing(/\/+$/, with: "") + "/pullrequest/\(number)"
        }
        guard let rest = httpURL(restURL).flatMap(URLComponents.init(string:)), let host = rest.host?.lowercased(),
            let project = trimmed(project), let repository = trimmed(repository)
        else { return nil }
        let segments = rest.percentEncodedPath.split(separator: "/").map(String.init)
        guard segments.contains(where: { $0.lowercased() == "_apis" }) else { return nil }
        let origin = "\(rest.scheme?.lowercased() ?? "https")://\(host)" + (rest.port.map { ":\($0)" } ?? "")
        let organizationBase: String
        if host == "dev.azure.com", let organization = segments.first {
            organizationBase = "\(origin)/\(organization)"
        } else if host.hasSuffix(".visualstudio.com") {
            organizationBase = origin
        } else {
            return nil
        }
        let encode = SourceControlHost.encodePathSegment
        return "\(organizationBase)/\(encode(project))/_git/\(encode(repository))/pullrequest/\(number)"
    }

    nonisolated static func azureDefaultBranch(_ output: String) -> String? {
        text(JSONValue.parse(output)?["defaultBranch"]).map(branchName).flatMap { $0.isEmpty ? nil : $0 }
    }

    // MARK: Forgejo and Gitea

    nonisolated static func forgejoPullRequests(_ output: String, host: SourceControlHost?) -> [GitPullRequest]? {
        JSONValue.parse(output)?.array?.compactMap { forgejoPullRequest($0, host: host) }
    }

    nonisolated static func forgejoPullRequest(_ output: String, host: SourceControlHost?) -> GitPullRequest? {
        JSONValue.parse(output).flatMap { forgejoPullRequest($0, host: host) }
    }

    nonisolated static func forgejoPullRequest(_ value: JSONValue, host: SourceControlHost?) -> GitPullRequest? {
        guard let number = value["number"]?.exactInt, number > 0, let title = value["title"]?.string,
            let head = text(value.at("head.ref")), let base = text(value.at("base.ref"))
        else { return nil }
        let state: GitPullRequest.State =
            value["merged"]?.bool == true ? .merged : value["state"]?.string?.lowercased() == "closed" ? .closed : .open
        let isDraft = value["draft"]?.bool ?? (title.range(of: #"^(\[WIP\]|WIP:)"#, options: [.regularExpression, .caseInsensitive]) != nil)
        return GitPullRequest(
            number: number, url: webURL(value["html_url"]?.string, number: number, host: host), title: title,
            state: state, baseBranch: base, headBranch: head, isDraft: isDraft)
    }

    nonisolated static func forgejoDefaultBranch(_ output: String) -> String? {
        text(JSONValue.parse(output)?["default_branch"])
    }

    nonisolated static func teaLogins(_ output: String) -> [TeaLogin]? {
        JSONValue.parse(output)?.array?.compactMap { value in
            guard let name = text(value["name"]), let url = text(value["url"]) else { return nil }
            return TeaLogin(
                name: name, url: url, sshHost: text(value["ssh_host"]), user: value["user"]?.string ?? "",
                isDefault: value["default"]?.string?.lowercased() == "true" || value["default"]?.bool == true)
        }
    }

    /// The response status `tea api --include` writes before the headers, such as `HTTP/1.1 201 Created`.
    nonisolated static func teaHTTPStatus(_ stderr: String) -> Int? {
        for line in stderr.split(whereSeparator: \.isNewline) where line.hasPrefix("HTTP/") {
            let fields = line.split(separator: " ")
            if fields.count >= 2, fields[1].count == 3, let status = Int(fields[1]) { return status }
        }
        return nil
    }

    // MARK: Shared

    /// The link a tool reported when it is a plain http(s) page, else the host's page for the number.
    nonisolated static func webURL(_ reported: String?, number: Int, host: SourceControlHost?) -> String {
        httpURL(reported) ?? host?.changeRequestURL(number: number)?.absoluteString ?? ""
    }

    /// `value` when it is an http(s) URL with a host and no credentials.
    nonisolated static func httpURL(_ value: String?) -> String? {
        guard let value = value?.trimmingCharacters(in: .whitespacesAndNewlines), !value.isEmpty,
            let components = URLComponents(string: value), let scheme = components.scheme?.lowercased(),
            scheme == "https" || scheme == "http", components.host?.isEmpty == false, components.user == nil,
            components.password == nil
        else { return nil }
        return value
    }

    private nonisolated static func text(_ value: JSONValue?) -> String? {
        trimmed(value?.string)
    }

    private nonisolated static func trimmed(_ value: String?) -> String? {
        guard let text = value?.trimmingCharacters(in: .whitespacesAndNewlines), !text.isEmpty else { return nil }
        return text
    }

    private nonisolated static func branchName(_ ref: String) -> String {
        ref.hasPrefix("refs/heads/") ? String(ref.dropFirst("refs/heads/".count)) : ref
    }
}

// MARK: Forgejo logins

extension TeaLogin {
    /// The one login for the server `remote` is on (T3 Code's `matchForgejoLogin`): over SSH by host
    /// name or SSH alias, over HTTP by server and mount path. Several logins for one server resolve to
    /// its default; nil when that is ambiguous.
    nonisolated static func match(_ logins: [TeaLogin], remote: GitRemoteURL) -> TeaLogin? {
        let overSSH = remote.transport == .ssh || remote.transport == .git
        let remotePath = remote.path.joined(separator: "/")
        var matches: [TeaLogin] = []
        for login in logins {
            guard let server = GitRemoteURL.parse(login.url) else { continue }
            let matched: Bool
            if overSSH {
                let alias = login.sshHost?.lowercased()
                matched = alias == remote.host || alias == remote.hostname || server.hostname == remote.hostname
            } else {
                let mount = server.path.joined(separator: "/")
                matched =
                    server.host == remote.host
                    && (mount.isEmpty || remotePath == mount || remotePath.hasPrefix(mount + "/"))
            }
            guard matched else { continue }
            if let index = matches.firstIndex(where: { $0.name == login.name }) {
                matches[index] = login
            } else {
                matches.append(login)
            }
        }
        if matches.count == 1 { return matches[0] }
        guard Set(matches.map(\.url)).count == 1 else { return nil }
        return matches.first(where: \.isDefault)
    }

    /// `owner/repository` on this login's server: the remote's path below the server's mount path.
    nonisolated func repository(for remote: GitRemoteURL) -> String? {
        var path = remote.path
        let mount = GitRemoteURL.parse(url)?.path ?? []
        if !mount.isEmpty, path.count > 2, Array(path.prefix(mount.count)) == mount { path.removeFirst(mount.count) }
        guard path.count == 2, path.allSatisfy({ !$0.isEmpty && $0 != "." && $0 != ".." && !$0.contains(where: \.isWhitespace) })
        else { return nil }
        return path.joined(separator: "/")
    }
}

// MARK: Running

/// Runs the host tools: whether one is signed in, the open change request for a branch, creating
/// one, and the repository's default branch. `gh` keeps going through `GitHubCLI`.
enum ChangeRequestCLI {
    struct TeaTarget: Sendable {
        var login: TeaLogin
        var repository: String
    }

    nonisolated static func run(
        _ tool: ChangeRequestTool, _ arguments: [String], in cwd: URL, input: String? = nil, timeout: TimeInterval = 60
    ) async -> ProcessRunner.Result? {
        await GitCLI.tool(
            tool.rawValue, arguments, in: cwd, environment: tool.environment, input: input, timeout: timeout)
    }

    /// Whether `tool` is installed and signed in to `host`.
    @concurrent nonisolated static func isReady(_ tool: ChangeRequestTool, host: SourceControlHost?, in cwd: URL) async
        -> Bool
    {
        switch tool {
        case .gh:
            return await GitHubCLI.isReady(cwd)
        case .glab:
            guard let host else { return false }
            let status = await run(.glab, ChangeRequestCommands.glabAuthStatus(host: host.remote.host), in: cwd, timeout: 20)
            return status?.succeeded ?? false
        case .az:
            guard host?.kind == .azureDevOps,
                let account = await run(.az, ChangeRequestCommands.azAccount, in: cwd, timeout: 30), account.succeeded,
                !account.stdout.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            else { return false }
            return await run(.az, ChangeRequestCommands.azExtension, in: cwd, timeout: 30)?.succeeded ?? false
        case .tea:
            guard let host else { return false }
            return await teaTarget(host, in: cwd) != nil
        }
    }

    /// The `tea` login for `host` and the repository on it.
    nonisolated static func teaTarget(_ host: SourceControlHost, in cwd: URL) async -> TeaTarget? {
        guard let result = await run(.tea, ChangeRequestCommands.teaLogins, in: cwd, timeout: 20), result.succeeded,
            let logins = ChangeRequestJSON.teaLogins(result.stdout), let login = TeaLogin.match(logins, remote: host.remote),
            let repository = login.repository(for: host.remote)
        else { return nil }
        return TeaTarget(login: login, repository: repository)
    }

    /// Settles a host no name identifies (T3 Code's `refineUnknownRemote`): a `glab` sign-in for it
    /// makes it a self-hosted GitLab, a `tea` login a Forgejo or Gitea server.
    @concurrent nonisolated static func refine(_ host: SourceControlHost, in cwd: URL) async -> SourceControlHost {
        guard host.kind == .unknown else { return host }
        if let status = await run(.glab, ChangeRequestCommands.glabAuthStatus(host: host.remote.host), in: cwd, timeout: 20),
            status.succeeded
        {
            return SourceControlHost(kind: .gitlab, name: "GitLab Self-Hosted", remote: host.remote)
        }
        if let result = await run(.tea, ChangeRequestCommands.teaLogins, in: cwd, timeout: 20), result.succeeded,
            let logins = ChangeRequestJSON.teaLogins(result.stdout), TeaLogin.match(logins, remote: host.remote) != nil
        {
            return SourceControlHost(kind: .forgejo, name: "Forgejo", remote: host.remote)
        }
        return host
    }

    /// The most recent open change request whose head is `branch`.
    @concurrent nonisolated static func openChangeRequest(
        for branch: String, tool: ChangeRequestTool, host: SourceControlHost?, in cwd: URL
    ) async -> GitPullRequest? {
        switch tool {
        case .gh:
            return await GitHubCLI.pullRequest(for: branch, in: cwd, state: "open")
        case .glab:
            guard let result = await run(.glab, ChangeRequestCommands.glabOpenMergeRequests(branch: branch), in: cwd),
                result.succeeded
            else { return nil }
            return ChangeRequestJSON.gitLabMergeRequests(result.stdout, host: host)?
                .first { $0.headBranch == branch && $0.state == .open }
        case .az:
            guard ChangeRequestCommands.azTakesLiterally(branch),
                let result = await run(.az, ChangeRequestCommands.azOpenPullRequests(branch: branch), in: cwd),
                result.succeeded
            else { return nil }
            return ChangeRequestJSON.azurePullRequests(result.stdout, host: host)?
                .first { $0.headBranch == branch && $0.state == .open }
        case .tea:
            guard let host, let target = await teaTarget(host, in: cwd),
                let output = await teaAPI(
                    target, method: "GET", route: ChangeRequestCommands.teaOpenPullRequestsRoute(branch: branch), in: cwd)
            else { return nil }
            return ChangeRequestJSON.forgejoPullRequests(output, host: host)?
                .first { $0.headBranch == branch && $0.state == .open }
        }
    }

    /// The repository's default branch as the host knows it.
    @concurrent nonisolated static func defaultBranch(tool: ChangeRequestTool, host: SourceControlHost?, in cwd: URL) async
        -> String?
    {
        switch tool {
        case .gh:
            return await GitHubCLI.defaultBranch(cwd)
        case .glab:
            guard let result = await run(.glab, ChangeRequestCommands.glabProject, in: cwd, timeout: 20), result.succeeded
            else { return nil }
            return ChangeRequestJSON.gitLabDefaultBranch(result.stdout)
        case .az:
            guard let result = await run(.az, ChangeRequestCommands.azRepository, in: cwd, timeout: 30), result.succeeded
            else { return nil }
            return ChangeRequestJSON.azureDefaultBranch(result.stdout)
        case .tea:
            guard let host, let target = await teaTarget(host, in: cwd),
                let output = await teaAPI(target, method: "GET", route: nil, in: cwd)
            else { return nil }
            return ChangeRequestJSON.forgejoDefaultBranch(output)
        }
    }

    /// Opens a pull or merge request from `head` into `base` and returns it.
    @concurrent nonisolated static func create(
        title: String, body: String, base: String, head: String, tool: ChangeRequestTool, host: SourceControlHost?,
        in cwd: URL
    ) async throws -> GitPullRequest {
        let term = host?.kind.changeRequest ?? .pullRequest
        let failure =
            term == .mergeRequest
            ? String(localized: "Could not create the merge request.") : String(localized: "Could not create the pull request.")
        switch tool {
        case .gh:
            return try await GitHubCLI.createPullRequest(title: title, body: body, base: base, head: head, in: cwd)
        case .glab:
            let bodyFile = try temporaryFile(body)
            defer { try? FileManager.default.removeItem(at: bodyFile) }
            let arguments = ChangeRequestCommands.glabCreateMergeRequest(
                base: base, head: head, title: title, bodyFile: bodyFile.path)
            guard let result = await run(.glab, arguments, in: cwd, timeout: 120) else {
                throw GitError(tool.setupMessage)
            }
            guard result.succeeded else { throw GitError.failed(failure, result) }
            return try await created(
                ChangeRequestJSON.gitLabMergeRequest(result.stdout, host: host), output: result.stdout, title: title,
                base: base, head: head, tool: tool, host: host, in: cwd)
        case .az:
            guard ChangeRequestCommands.azTakesLiterally(base), ChangeRequestCommands.azTakesLiterally(head) else {
                throw GitError(failure, detail: String(localized: "The Azure CLI can't take a branch name containing “@”."))
            }
            let titleFile = try temporaryFile(title)
            let bodyFile = try temporaryFile(body)
            defer {
                try? FileManager.default.removeItem(at: titleFile)
                try? FileManager.default.removeItem(at: bodyFile)
            }
            let arguments = ChangeRequestCommands.azCreatePullRequest(
                base: base, head: head, titleFile: titleFile.path, bodyFile: bodyFile.path)
            guard let result = await run(.az, arguments, in: cwd, timeout: 120) else { throw GitError(tool.setupMessage) }
            guard result.succeeded else { throw GitError.failed(failure, result) }
            return try await created(
                ChangeRequestJSON.azurePullRequest(result.stdout, host: host), output: result.stdout, title: title,
                base: base, head: head, tool: tool, host: host, in: cwd)
        case .tea:
            guard let host, let target = await teaTarget(host, in: cwd) else { throw GitError(tool.setupMessage) }
            let request: JSONValue = ["base": .string(base), "head": .string(head), "title": .string(title), "body": .string(body)]
            guard let url = ChangeRequestCommands.teaAPIURL(login: target.login, repository: target.repository, route: "pulls")
            else { throw GitError(tool.setupMessage) }
            let arguments = ChangeRequestCommands.teaAPI(
                login: target.login.name, repository: target.repository, method: "POST", url: url, hasBody: true)
            guard let result = await run(.tea, arguments, in: cwd, input: request.compactJSON, timeout: 120) else {
                throw GitError(tool.setupMessage)
            }
            let status = ChangeRequestJSON.teaHTTPStatus(result.stderr)
            guard result.succeeded, let status, (200..<300).contains(status) else {
                let detail = status.map { String(localized: "The server answered with HTTP status \($0).") }
                throw detail.map { GitError(failure, detail: $0) } ?? GitError.failed(failure, result)
            }
            return try await created(
                ChangeRequestJSON.forgejoPullRequest(result.stdout, host: host), output: result.stdout, title: title,
                base: base, head: head, tool: tool, host: host, in: cwd)
        }
    }

    /// The change request a create call made: as the tool printed it, else looked up by branch, else
    /// what is known of it.
    private nonisolated static func created(
        _ parsed: GitPullRequest?, output: String, title: String, base: String, head: String, tool: ChangeRequestTool,
        host: SourceControlHost?, in cwd: URL
    ) async throws -> GitPullRequest {
        if let parsed { return parsed }
        if let found = await openChangeRequest(for: head, tool: tool, host: host, in: cwd) { return found }
        let printed = output.split(whereSeparator: \.isWhitespace).lazy.map(String.init)
            .first { ChangeRequestLink.parse($0) != nil }
        let number = printed.flatMap(ChangeRequestLink.parse)?.number ?? 0
        return GitPullRequest(
            number: number, url: ChangeRequestJSON.webURL(printed, number: number, host: host), title: title,
            state: .open, baseBranch: base, headBranch: head)
    }

    private nonisolated static func teaAPI(_ target: TeaTarget, method: String, route: String?, in cwd: URL) async
        -> String?
    {
        guard let url = ChangeRequestCommands.teaAPIURL(login: target.login, repository: target.repository, route: route),
            let result = await run(
                .tea,
                ChangeRequestCommands.teaAPI(
                    login: target.login.name, repository: target.repository, method: method, url: url, hasBody: false),
                in: cwd),
            result.succeeded, let status = ChangeRequestJSON.teaHTTPStatus(result.stderr), (200..<300).contains(status)
        else { return nil }
        return result.stdout
    }

    private nonisolated static func temporaryFile(_ contents: String) throws -> URL {
        let file = FileManager.default.temporaryDirectory
            .appendingPathComponent("coincide-change-request-\(UUID().uuidString).txt")
        try contents.write(to: file, atomically: true, encoding: .utf8)
        return file
    }
}

// MARK: Remotes of a repository

extension GitOps {
    /// The host of the remote `branch` tracks, else of `origin` (or the first remote). Nil without a
    /// remote, or for one that names no host. `git remote get-url` applies `insteadOf` rewrites.
    @concurrent static func remoteHost(_ cwd: URL, branch: String?) async -> SourceControlHost? {
        let remotes = await remoteNames(cwd)
        var remote: String?
        if let branch, let tracked = await configValue("branch.\(branch).remote", in: cwd), remotes.contains(tracked) {
            remote = tracked
        }
        guard let name = remote ?? primaryRemote(remotes) else { return nil }
        let result = await GitCLI.git(["remote", "get-url", "--", name], in: cwd, timeout: 10)
        guard result.succeeded else { return nil }
        return SourceControlHost.recognize(remoteURL: result.stdout)
    }
}
