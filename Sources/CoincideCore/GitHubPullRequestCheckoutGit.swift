import Foundation

extension GitHubPullRequestCheckoutService {
    func local(at path: String) async throws -> GitHubPullRequestLocal {
        let api: GitHubPullRequestService
        if let environment { api = .init(root: URL(fileURLWithPath: path), environment: environment, gitExecutable: gitExecutable, githubExecutable: githubExecutable, timeout: timeout) }
        else { api = .init(root: URL(fileURLWithPath: path), timeout: timeout) }
        return try await api.localContext()
    }
    func git(_ arguments: [String], local: GitHubPullRequestLocal, protocols: String = "", allowFailure: Bool = false) async throws -> GitWorktreeCommandResult {
        try local.validate()
        let result = try await command.run(["--no-lazy-fetch", "--no-replace-objects"] + arguments,
            cwdFD: local.repository.fd, timeout: timeout, maximumOutput: 2_097_152, gitDirectory: local.admin.path,
            commonDirectory: local.common.path, workTree: local.repository.path, allowedProtocols: protocols)
        try local.validate()
        guard allowFailure || result.status == 0 else { throw GitHubPullRequestCheckoutError(.commandFailed) }
        return result
    }
    func status(_ local: GitHubPullRequestLocal) async throws -> Data {
        try await git(["status", "--porcelain=v1", "-z", "--untracked-files=all"], local: local).output
    }
    func trackedStatus(_ local: GitHubPullRequestLocal) async throws -> Data {
        try await git(["status", "--porcelain=v1", "-z", "--untracked-files=no"], local: local).output
    }
    func indexDigest(_ local: GitHubPullRequestLocal) throws -> String? {
        try local.admin.read("index", maximum: 16_777_216, allowEmpty: true).map(GitHubPullRequestService.digest)
    }
    func configurationDigest(_ local: GitHubPullRequestLocal) async throws -> String {
        GitHubPullRequestService.digest(try await git(["config", "--null", "--list", "--show-origin"], local: local).output)
    }
    func optionalCommit(_ revision: String, local: GitHubPullRequestLocal) async throws -> String? {
        let result = try await git(["rev-parse", "--verify", "--quiet", "--end-of-options", revision + "^{commit}"], local: local, allowFailure: true)
        if result.status != 0 { return nil }
        let value = try GitHubPullRequestService.line(result.output)
        guard GitHubValidation.object(value) else { throw GitHubPullRequestCheckoutError(.invalidResponse) }; return value
    }
    func configuration(_ key: String, local: GitHubPullRequestLocal) async throws -> String? {
        let result = try await git(["config", "--null", "--get-all", key], local: local, allowFailure: true)
        if result.status == 1 { return nil }
        guard result.status == 0 else { throw GitHubPullRequestCheckoutError(.commandFailed) }
        let values = result.output.split(separator: 0)
        guard values.count == 1, let value = String(data: Data(values[0]), encoding: .utf8), !value.contains("\0") else { throw GitHubPullRequestCheckoutError(.unsupportedRemote) }
        return value
    }
    func remote(for repository: GitHubRepository, local: GitHubPullRequestLocal) async throws -> GitHubPullRequestCheckoutRemote {
        let matches = local.remotes.filter { $0.repository == repository }.sorted { $0.name < $1.name }
        let known = matches.first(where: { $0.name == "origin" }) ?? matches.first
        var name = known?.name ?? repository.owner
        if known == nil {
            let names = Set(local.remotes.map(\.name)); var suffix = 1
            while names.contains(name) { name = repository.owner + "-" + String(suffix); suffix += 1 }
        }
        let url: String, configurationURL: String
        if let override = transportOverrides[repository] {
            guard override.isFileURL, override.host == nil || override.host == "", override.query == nil, override.fragment == nil else { throw GitHubPullRequestCheckoutError(.unsupportedRemote) }
            url = override.absoluteString
            if let known, let raw = try await configuration("remote." + known.name + ".url", local: local) { configurationURL = raw }
            else {
                let origin = try await configuration("remote.origin.url", local: local) ?? ""
                configurationURL = origin.hasPrefix("git@") || origin.hasPrefix("ssh://")
                    ? "git@" + repository.host + ":" + repository.nameWithOwner + ".git" : "https://" + repository.selector + ".git"
            }
        } else if let known, let configured = try await configuration("remote." + known.name + ".url", local: local) {
            url = configured; configurationURL = configured
        } else {
            let command = GitHubPullRequestCommand(environment: environment, executable: githubExecutable, timeout: timeout)
            let response = try await command.run(["api", "--hostname=" + repository.host, "--method=GET", "repos/" + repository.nameWithOwner], directory: local.workspace, host: repository.host)
            guard response.status == 0 else { throw GitHubPullRequestCheckoutError(.unsupportedRemote) }
            let row = try GitHubPullRequestJSON.object(response.output)
            guard (row["full_name"] as? String)?.lowercased() == repository.nameWithOwner else { throw GitHubPullRequestCheckoutError(.invalidResponse) }
            let origin = try await configuration("remote.origin.url", local: local) ?? ""
            let ssh = origin.hasPrefix("git@") || origin.hasPrefix("ssh://")
            guard let value = row[ssh ? "ssh_url" : "clone_url"] as? String else { throw GitHubPullRequestCheckoutError(.unsupportedRemote) }; url = value; configurationURL = value
        }
        let value = try GitHubPullRequestCheckoutRemote(name: name, url: url, repository: repository, needsCreation: known == nil, configurationURL: configurationURL)
        try validateTransport(value); return value
    }
    func validateTransport(_ remote: GitHubPullRequestCheckoutRemote) throws {
        try remote.validate()
        if remote.url.hasPrefix("file:") {
            guard transportOverrides[remote.repository]?.absoluteString == remote.url else { throw GitHubPullRequestCheckoutError(.unsupportedRemote) }
        }
    }
    func defaultBranch(local: GitHubPullRequestLocal) async throws -> String {
        let repository = request.reference.repository
        let api = GitHubPullRequestCommand(environment: environment, executable: githubExecutable, timeout: timeout)
        let response = try await api.run(["api", "--hostname=" + repository.host, "--method=GET", "repos/" + repository.nameWithOwner], directory: local.workspace, host: repository.host)
        guard response.status == 0 else { throw GitHubPullRequestCheckoutError(.commandFailed) }
        let row = try GitHubPullRequestJSON.object(response.output)
        guard (row["full_name"] as? String)?.lowercased() == repository.nameWithOwner,
              let branch = row["default_branch"] as? String, GitHubValidation.branch(branch) else { throw GitHubPullRequestCheckoutError(.invalidResponse) }; return branch
    }
    func protocols(local: GitHubPullRequestLocal) async throws -> String {
        let result = try await git(["config", "--null", "--get-regexp", #"^protocol\..*allow$"#], local: local, allowFailure: true)
        guard result.status == 0 || result.status == 1 else { throw GitHubPullRequestCheckoutError(.unsupportedRemote) }
        return try GitWorktreeSubmodulePolicy.allowlist(configuration: result.output, inherited: command.inheritedProtocolAllowlist)
    }
    func assertSource(_ local: GitHubPullRequestLocal, plan: GitHubPullRequestCheckoutPlan, original: Bool) async throws {
        try local.workspace.validate(expected: plan.proof.sourceIdentity); try local.repository.validate(expected: plan.proof.repositoryIdentity)
        try local.admin.validate(expected: plan.proof.gitDirectoryIdentity); try local.common.validate(expected: plan.proof.commonDirectoryIdentity)
        guard local.workspace.path == plan.sourcePath, local.repository.path == plan.repositoryPath,
              local.admin.path == plan.proof.gitDirectoryPath, local.common.path == plan.commonDirectoryPath else { throw GitHubPullRequestCheckoutError(.staleReview) }
        if original, plan.request.mode != .local, let expected = plan.proof.repositoryFingerprint {
            guard try await repositoryFingerprint(local, baseRemote: plan.baseRemote, headRemote: plan.headRemote) == expected else { throw GitHubPullRequestCheckoutError(.staleReview) }
        } else if original {
            let fingerprint = plan.proof.repositoryFingerprint == nil ? local.proof : try await destinationFingerprint(local, plan: plan)
            let configuration = plan.proof.repositoryFingerprint == nil ? try await configurationDigest(local) : try await policyConfigurationDigest(local)
            guard fingerprint == plan.proof.sourceFingerprint, try indexDigest(local) == plan.proof.indexDigest,
                  configuration == plan.proof.configurationDigest,
                  GitHubPullRequestService.digest(try await status(local)) == plan.proof.statusDigest else { throw GitHubPullRequestCheckoutError(.staleReview) }
        }
    }
    func assertReuse(_ local: GitHubPullRequestLocal, plan: GitHubPullRequestCheckoutPlan) async throws {
        try local.repository.validate(expected: plan.proof.destinationIdentity); try local.admin.validate(expected: plan.proof.destinationGitDirectoryIdentity)
        guard local.repository.path == plan.destinationPath, local.common.path == plan.commonDirectoryPath,
              local.admin.path == plan.proof.destinationGitDirectoryPath, local.head == plan.proof.destinationHeadCommit,
              local.branch == plan.proof.destinationBranch, try indexDigest(local) == plan.proof.destinationIndexDigest,
              GitHubPullRequestService.digest(try await status(local)) == plan.proof.destinationStatusDigest else { throw GitHubPullRequestCheckoutError(.staleReview) }
        let fingerprint: String, configuration: String
        if plan.proof.repositoryFingerprint != nil {
            fingerprint = try await destinationFingerprint(local, plan: plan)
            configuration = try await policyConfigurationDigest(local)
        } else { fingerprint = local.proof; configuration = try await configurationDigest(local) }
        guard fingerprint == plan.proof.destinationFingerprint, configuration == plan.proof.destinationConfigurationDigest else { throw GitHubPullRequestCheckoutError(.staleReview) }
    }
    func protectUntracked(commit: String, local: GitHubPullRequestLocal) async throws {
        let tracked = try paths(await git(["ls-tree", "-r", "--name-only", "-z", commit], local: local).output)
        let untracked = try paths(await git(["ls-files", "--others", "--exclude-standard", "-z"], local: local).output)
        let ignored = try paths(await git(["ls-files", "--others", "--ignored", "--exclude-standard", "-z"], local: local).output)
        let leaves = Set(tracked)
        func prefixes(_ path: String) -> [String] {
            var result: [String] = [], prefix = ""
            for piece in path.split(separator: "/") { prefix += (prefix.isEmpty ? "" : "/") + piece; result.append(prefix) }
            return result
        }
        let ancestors = Set(tracked.flatMap(prefixes))
        for path in untracked + ignored {
            if ancestors.contains(path) || prefixes(path).contains(where: leaves.contains) { throw GitHubPullRequestCheckoutError(.dirtyCheckout) }
        }
    }
    private func paths(_ data: Data) throws -> [String] {
        let parts = data.split(separator: 0)
        guard parts.count <= 65_536 else { throw GitHubPullRequestCheckoutError(.outputLimit) }
        return try parts.map {
            guard $0.count <= 4_096, let value = String(data: Data($0), encoding: .utf8), !value.isEmpty else { throw GitHubPullRequestCheckoutError(.invalidResponse) }; return value
        }
    }
}
