import Foundation

/// GitHub reads and explicit PR creation through the installed, already authenticated CLI.
/// No method pushes, forks, changes checkout, signs in, or installs a tool.
public struct GitHubPullRequestService: GitHubPullRequestSession, Sendable {
    public let root: URL
    let environment: [String: String]?
    let gitExecutable: URL?
    let githubExecutable: URL?
    let timeout: Duration
    public init(root: URL, timeout: Duration = .seconds(30)) {
        self.root = root; self.timeout = timeout; environment = nil; gitExecutable = nil
        githubExecutable = ProcessChannel.findExecutable("gh")?.resolvingSymlinksInPath()
    }
    init(root: URL, environment: [String: String], gitExecutable: URL? = nil, githubExecutable: URL?, timeout: Duration = .seconds(30)) {
        self.root = root; self.environment = environment; self.gitExecutable = gitExecutable
        self.githubExecutable = githubExecutable; self.timeout = timeout
    }
    private var command: GitHubPullRequestCommand { .init(environment: environment, executable: githubExecutable, timeout: timeout) }

    public func context() async throws -> GitHubPullRequestContext {
        let local = try await localContext(), base = try local.baseRepository()
        let info = try await repositoryInfo(base, local: local)
        let branches = try await baseBranches(base, local: local)
        let headRepository = local.headRemote?.repository
        let published: String?
        if let headRepository, let branch = local.upstreamBranch {
            published = try await branchCommit(branch, repository: headRepository, local: local)
        } else { published = nil }
        let upstream: GitHubPullRequestUpstream?
        if let remote = local.upstreamRemote, let branch = local.upstreamBranch {
            upstream = try .init(remoteName: remote, branch: branch, commit: published)
        } else { upstream = nil }
        var readiness: GitHubPullRequestReadiness
        if local.branch == nil { readiness = .detachedHead }
        else if local.upstreamRemote == nil || local.upstreamBranch == nil { readiness = .unpublished }
        else if headRepository == nil || headRepository?.host != base.host { readiness = .ambiguousRemote }
        else if local.head == nil || published == nil { readiness = .unpublished }
        else if local.head != published { readiness = .unpushedCommits }
        else if headRepository == base && local.upstreamBranch == info { readiness = .defaultBranch }
        else { readiness = .ready }
        var existing: GitHubPullRequestSummary?
        if let headRepository, let branch = local.upstreamBranch {
            do { existing = try await existingOpen(repository: base, headRepository: headRepository, branch: branch, local: local) }
            catch let error as GitHubPullRequestError where error.kind == .ambiguousRemote { readiness = .ambiguousRemote }
        }
        let current = try await localContext()
        guard current.proof == local.proof else { throw GitHubPullRequestError(.staleReview) }
        let fingerprint = Self.digest(Data([local.proof, base.selector, headRepository?.selector ?? "", published ?? "", info].joined(separator: "\0").utf8))
        return try .init(workspacePath: local.workspace.path, repositoryPath: local.repository.path, commonDirectoryPath: local.common.path,
            repository: base, headRepository: headRepository, branch: local.branch, headCommit: local.head, upstream: upstream,
            defaultBranch: info, baseBranches: branches.names, baseBranchesTruncated: branches.truncated,
            existingPullRequest: existing, readiness: readiness, sourceFingerprint: fingerprint)
    }

    public func list(query: GitHubPullRequestListQuery = .init()) async throws -> GitHubPullRequestPage {
        try query.validate()
        let local = try await localContext(), repository = try local.baseRepository()
        var arguments = ["pr", "list", "--repo=" + repository.selector, "--state=" + query.state.rawValue,
            "--limit=" + String(query.limit), "--json=" + GitHubPullRequestJSON.fields]
        if let query = query.query { arguments.append("--search=" + query) }
        if let author = query.author { arguments.append("--author=" + author) }
        if let base = query.baseBranch { arguments.append("--base=" + base) }
        if let head = query.headBranch { arguments.append("--head=" + head) }
        let result = try await run(arguments, local: local, repository: repository)
        let rows = try GitHubPullRequestJSON.array(result.output)
        guard rows.count <= query.limit else { throw GitHubPullRequestError(.invalidResponse) }
        let items = try rows.map { try GitHubPullRequestJSON.summary($0, repository: repository) }
        guard Set(items.map(\.reference)).count == items.count else { throw GitHubPullRequestError(.invalidResponse) }
        return .init(items: items, truncated: items.count == query.limit)
    }

    public func detail(_ reference: GitHubPullRequestReference) async throws -> GitHubPullRequestDetail {
        try reference.validate(); let local = try await localContext()
        let result = try await run(["pr", "view", String(reference.number), "--repo=" + reference.repository.selector,
            "--json=" + GitHubPullRequestJSON.detailFields], local: local, repository: reference.repository)
        return try GitHubPullRequestJSON.detail(result.output, reference: reference)
    }

    public func resolve(_ reference: String) async throws -> GitHubPullRequestDetail {
        let value = reference.trimmingCharacters(in: .whitespacesAndNewlines)
        guard GitHubValidation.text(value, maximum: 2_048), !value.hasPrefix("-") else { throw GitHubPullRequestError(.invalidRequest) }
        let local = try await localContext(), base = try local.baseRepository()
        if value.hasPrefix("https://") {
            guard GitHubValidation.safeWebURL(value), let c = URLComponents(string: value), let host = c.host else { throw GitHubPullRequestError(.invalidRequest) }
            let parts = c.path.split(separator: "/", omittingEmptySubsequences: false)
            guard parts.count == 5, parts[0].isEmpty, parts[3] == "pull", let number = Int(parts[4]), number > 0 else { throw GitHubPullRequestError(.invalidRequest) }
            return try await detail(.init(repository: .init(host: host, owner: String(parts[1]), name: String(parts[2])), number: number))
        }
        let numbered = value.hasPrefix("#") ? String(value.dropFirst()) : value
        if numbered.utf8.allSatisfy({ (48...57).contains($0) }), let number = Int(numbered), number > 0 {
            return try await detail(.init(repository: base, number: number))
        }
        guard GitHubValidation.branch(value) else { throw GitHubPullRequestError(.invalidRequest) }
        let result = try await run(["pr", "view", value, "--repo=" + base.selector, "--json=" + GitHubPullRequestJSON.detailFields], local: local, repository: base)
        let number = try GitHubPullRequestJSON.integer(GitHubPullRequestJSON.object(result.output), "number")
        return try GitHubPullRequestJSON.detail(result.output, reference: .init(repository: base, number: number))
    }

    public func reviewCreate(title: String, body: String, baseBranch: String? = nil, isDraft: Bool = false) async throws -> GitHubPullRequestCreateReview {
        let context = try await context(), local = try await localContext()
        let base = context.existingPullRequest?.baseBranch ?? baseBranch ?? context.defaultBranch
        try Self.requirePublished(context, base: base)
        guard let commit = try await branchCommit(base, repository: context.repository, local: local) else { throw GitHubPullRequestError(.invalidRequest) }
        let fresh = try await self.context()
        guard Self.sameSource(fresh, context) else { throw GitHubPullRequestError(.staleReview) }
        return try .init(context: context, title: title, body: body, baseBranch: base, baseCommit: commit, isDraft: isDraft)
    }

    public func create(_ review: GitHubPullRequestCreateReview) async throws -> GitHubPullRequestCreateOutcome {
        try review.validate()
        guard Self.canonical(root.path) == review.context.workspacePath else { throw GitHubPullRequestError(.staleReview) }
        return try await GitOperationGate.shared.perform(key: review.context.commonDirectoryPath) {
            let current = try await context()
            guard Self.sameSource(current, review.context) else { throw GitHubPullRequestError(.staleReview) }
            if let existing = current.existingPullRequest {
                let result = try await detail(existing.reference)
                guard Self.matchesExisting(result, review: review) else { throw GitHubPullRequestError(.staleReview) }
                return .openedExisting(result)
            }
            try Self.requirePublished(current, base: review.baseBranch)
            let local = try await localContext()
            guard let baseCommit = try await branchCommit(review.baseBranch, repository: current.repository, local: local), baseCommit == review.baseCommit else { throw GitHubPullRequestError(.staleReview) }
            let refreshed = try await localContext()
            guard refreshed.proof == local.proof else { throw GitHubPullRequestError(.staleReview) }
            guard let head = current.headRepository, let branch = current.upstream?.branch else { throw GitHubPullRequestError(.notPublished) }
            // An explicit head suppresses gh's implicit push/fork behavior. Body is
            // an unlinked private descriptor, never a shell argument or repo file.
            let headSelector = head == current.repository ? branch : head.owner + ":" + branch
            var arguments = ["pr", "create", "--repo=" + current.repository.selector, "--head=" + headSelector,
                "--base=" + review.baseBranch, "--title=" + review.title, "--body-file=-"]
            if review.isDraft { arguments.append("--draft") }
            try local.validate(); try Task.checkCancellation()
            let result: GitWorktreeCommandResult
            do { result = try await command.run(arguments, directory: local.workspace, host: current.repository.host, input: Data(review.body.utf8)) }
            catch { throw GitHubPullRequestError(.outcomeUncertain) }
            if result.status != 0 {
                let output = String(decoding: result.output, as: UTF8.self)
                if output.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                   Self.isAuthenticationFailure(result) { throw GitHubPullRequestError(.unauthenticated) }
                throw GitHubPullRequestError(.outcomeUncertain)
            }
            do {
                let text = try Self.line(result.output).trimmingCharacters(in: .whitespacesAndNewlines)
                let resolved = try await resolve(text)
                let finalLocal = try await localContext()
                guard Self.matches(resolved, review: review), finalLocal.proof == local.proof else { throw GitHubPullRequestError(.outcomeUncertain) }
                return .created(resolved)
            } catch { throw GitHubPullRequestError(.outcomeUncertain) }
        }
    }

    /// Absence is not proof that a previous POST did not succeed. The caller must
    /// keep uncertain intent durable and must never automatically repeat creation.
    public func reconcileCreate(_ review: GitHubPullRequestCreateReview) async throws -> GitHubPullRequestCreateReconciliation {
        try review.validate(); let local = try await localContext()
        guard local.workspace.path == review.context.workspacePath, local.repository.path == review.context.repositoryPath,
              local.common.path == review.context.commonDirectoryPath, let head = review.context.headRepository,
              let branch = review.context.upstream?.branch, try local.baseRepository() == review.context.repository,
              local.headRemote?.repository == head, local.upstreamBranch == branch,
              local.branch == review.context.branch, local.head == review.context.headCommit else { throw GitHubPullRequestError(.staleReview) }
        let expected = Self.digest(Data([local.proof, review.context.repository.selector, head.selector,
            review.context.upstream?.commit ?? "", review.context.defaultBranch].joined(separator: "\0").utf8))
        guard expected == review.context.sourceFingerprint else { throw GitHubPullRequestError(.staleReview) }
        guard let row = try await existingOpen(repository: review.context.repository, headRepository: head, branch: branch, local: local) else { return .notFound }
        let result = try await detail(row.reference)
        return Self.matches(result, review: review) ? .found(result) : .notFound
    }

    private static func requirePublished(_ context: GitHubPullRequestContext, base: String) throws {
        guard GitHubValidation.branch(base), context.readiness == .ready || context.readiness == .defaultBranch,
              let head = context.headRepository, let branch = context.upstream?.branch,
              context.headCommit != nil, context.upstream?.commit == context.headCommit,
              head != context.repository || branch != base else { throw GitHubPullRequestError(.notPublished) }
    }
    private static func matches(_ result: GitHubPullRequestDetail, review: GitHubPullRequestCreateReview) -> Bool {
        let row = result.summary
        return matchesExisting(result, review: review) && row.baseBranch == review.baseBranch && row.baseCommit == review.baseCommit
    }
    private static func matchesExisting(_ result: GitHubPullRequestDetail, review: GitHubPullRequestCreateReview) -> Bool {
        let row = result.summary
        return row.state == .open && row.reference.repository == review.context.repository &&
            row.headRepository == review.context.headRepository && row.headBranch == review.context.upstream?.branch && row.headCommit == review.context.headCommit
    }
    private static func sameSource(_ a: GitHubPullRequestContext, _ b: GitHubPullRequestContext) -> Bool {
        a.sourceFingerprint == b.sourceFingerprint && a.workspacePath == b.workspacePath &&
            a.repositoryPath == b.repositoryPath && a.commonDirectoryPath == b.commonDirectoryPath &&
            a.repository == b.repository && a.headRepository == b.headRepository && a.branch == b.branch &&
            a.headCommit == b.headCommit && a.upstream == b.upstream && a.defaultBranch == b.defaultBranch
    }
    private func repositoryInfo(_ repository: GitHubRepository, local: GitHubPullRequestLocal) async throws -> String {
        let data = try await api("repos/" + repository.nameWithOwner, repository: repository, local: local)
        let row = try GitHubPullRequestJSON.object(data)
        let fullName = try GitHubPullRequestJSON.string(row, "full_name")
        guard fullName.lowercased() == repository.nameWithOwner else { throw GitHubPullRequestError(.invalidResponse) }
        let branch = try GitHubPullRequestJSON.string(row, "default_branch")
        guard GitHubValidation.branch(branch) else { throw GitHubPullRequestError(.invalidResponse) }; return branch
    }
    private func baseBranches(_ repository: GitHubRepository, local: GitHubPullRequestLocal) async throws -> (names: [String], truncated: Bool) {
        let data = try await api("repos/" + repository.nameWithOwner + "/branches?per_page=100", repository: repository, local: local)
        let rows = try GitHubPullRequestJSON.array(data)
        guard rows.count <= 100 else { throw GitHubPullRequestError(.invalidResponse) }
        let names = try rows.map { try GitHubPullRequestJSON.string($0, "name") }
        guard Set(names).count == names.count, names.allSatisfy(GitHubValidation.branch) else { throw GitHubPullRequestError(.invalidResponse) }
        return (names.sorted(), names.count == 100)
    }
    private func branchCommit(_ branch: String, repository: GitHubRepository, local: GitHubPullRequestLocal) async throws -> String? {
        guard GitHubValidation.branch(branch) else { throw GitHubPullRequestError(.invalidRequest) }
        let encoded = branch.addingPercentEncoding(withAllowedCharacters: .alphanumerics.union(CharacterSet(charactersIn: "-._~/")))!
        let result = try await run(["api", "--hostname=" + repository.host, "--method=GET", "repos/" + repository.nameWithOwner + "/git/ref/heads/" + encoded], local: local, repository: repository, allowFailure: true)
        if result.status != 0 {
            let row = try? GitHubPullRequestJSON.object(result.output)
            if row?["status"] as? String == "404" || row?["status"] as? Int == 404 { return nil }
            throw Self.failure(result)
        }
        let row = try GitHubPullRequestJSON.object(result.output)
        guard row["ref"] as? String == "refs/heads/" + branch, let object = row["object"] as? [String: Any],
              object["type"] as? String == "commit", let sha = object["sha"] as? String, GitHubValidation.object(sha) else { throw GitHubPullRequestError(.invalidResponse) }
        return sha
    }
    private func existingOpen(repository: GitHubRepository, headRepository: GitHubRepository, branch: String,
                              local: GitHubPullRequestLocal) async throws -> GitHubPullRequestSummary? {
        let result = try await run(["pr", "list", "--repo=" + repository.selector, "--state=open", "--head=" + branch,
            "--limit=100", "--json=" + GitHubPullRequestJSON.fields], local: local, repository: repository)
        let rows = try GitHubPullRequestJSON.array(result.output)
        guard rows.count <= 100 else { throw GitHubPullRequestError(.invalidResponse) }
        let matches = try rows.map { try GitHubPullRequestJSON.summary($0, repository: repository) }.filter {
            $0.state == .open && $0.headBranch == branch && $0.headRepository == headRepository
        }
        guard matches.count <= 1, !matches.isEmpty || rows.count < 100 else { throw GitHubPullRequestError(.ambiguousRemote) }
        return matches.first
    }
    private func api(_ endpoint: String, repository: GitHubRepository, local: GitHubPullRequestLocal) async throws -> Data {
        try await run(["api", "--hostname=" + repository.host, "--method=GET", endpoint], local: local, repository: repository).output
    }
    private func run(_ arguments: [String], local: GitHubPullRequestLocal, repository: GitHubRepository, allowFailure: Bool = false) async throws -> GitWorktreeCommandResult {
        try local.validate()
        let result = try await command.run(arguments, directory: local.workspace, host: repository.host)
        try local.validate()
        if !allowFailure, result.status != 0 { throw Self.failure(result) }
        return result
    }
    private static func isAuthenticationFailure(_ result: GitWorktreeCommandResult) -> Bool {
        let text = String(decoding: result.errorOutput, as: UTF8.self).lowercased()
        return result.status == 4 || text.contains("http 401") || text.contains("not logged") || text.contains("authentication required") || text.contains("not authenticated")
    }
    private static func failure(_ result: GitWorktreeCommandResult) -> GitHubPullRequestError {
        let text = String(decoding: result.errorOutput, as: UTF8.self).lowercased()
        if text.contains("rate limit") || text.contains("http 429") { return .init(.rateLimited) }
        if isAuthenticationFailure(result) { return .init(.unauthenticated) }
        return .init(text.contains("http 403") ? .accessDenied : .commandFailed)
    }
}
