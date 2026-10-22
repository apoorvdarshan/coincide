import CryptoKit
import Foundation

struct GitHubPullRequestRemote: Sendable, Codable {
    let name: String
    let repository: GitHubRepository?
    let urlDigest: String
    let resolved: String?
    let pushMatchesFetch: Bool
}

struct GitHubPullRequestLocal: Sendable {
    let workspace: GitWorktreeDirectory
    let repository: GitWorktreeDirectory
    let admin: GitWorktreeDirectory
    let common: GitWorktreeDirectory
    let pointer: Data?
    let commonPointer: Data?
    let backlink: Data?
    let branch: String?
    let head: String?
    let upstreamRemote: String?
    let upstreamBranch: String?
    let pushOverride: String?
    let remotes: [GitHubPullRequestRemote]
    let proof: String

    func validate() throws {
        try workspace.validate(); try repository.validate(); try admin.validate(); try common.validate()
        if admin.path != repository.path + "/.git", try repository.read(".git", allowEmpty: true) != pointer { throw GitHubPullRequestError(.staleReview) }
        guard try admin.read("commondir", allowEmpty: true) == commonPointer,
              try admin.read("gitdir", allowEmpty: true) == backlink else { throw GitHubPullRequestError(.staleReview) }
    }
    func baseRepository() throws -> GitHubRepository {
        let available = remotes.filter { $0.repository != nil }
        let marked = available.filter { $0.resolved != nil }
        if marked.count == 1 {
            let chosen = marked[0]
            if chosen.resolved == "base", let repository = chosen.repository { return repository }
            if let value = chosen.resolved, let host = chosen.repository?.host {
                let parts = value.split(separator: "/", omittingEmptySubsequences: false)
                if parts.count == 2 { return try .init(host: host, owner: String(parts[0]), name: String(parts[1])) }
            }
            throw GitHubPullRequestError(.ambiguousRemote)
        }
        guard marked.isEmpty else { throw GitHubPullRequestError(.ambiguousRemote) }
        for preferred in ["upstream", "github", "origin"] {
            let matches = available.filter { $0.name.lowercased() == preferred }
            if matches.count == 1, let repository = matches[0].repository { return repository }
            if matches.count > 1 { throw GitHubPullRequestError(.ambiguousRemote) }
        }
        guard available.count == 1, let repository = available[0].repository else {
            throw GitHubPullRequestError(available.isEmpty ? .unsupportedRemote : .ambiguousRemote)
        }
        return repository
    }
    var headRemote: GitHubPullRequestRemote? {
        guard let upstreamRemote, pushOverride == nil || pushOverride == upstreamRemote else { return nil }
        return remotes.first { $0.name == upstreamRemote && $0.pushMatchesFetch }
    }
}

extension GitHubPullRequestService {
    func localContext() async throws -> GitHubPullRequestLocal {
        try Task.checkCancellation()
        guard root.isFileURL, root.host == nil || root.host == "localhost", root.query == nil, root.fragment == nil else { throw GitHubPullRequestError(.invalidRequest) }
        let path = root.standardizedFileURL.resolvingSymlinksInPath().path
        let workspace: GitWorktreeDirectory
        do { workspace = try .init(path: path) } catch { throw GitHubPullRequestError(.notRepository) }
        let command = GitWorktreeCommand(environment: environment, executable: gitExecutable)
        func discover(_ args: [String]) async throws -> String {
            try workspace.validate()
            let result = try await command.run(args, cwdFD: workspace.fd, timeout: timeout, maximumOutput: 262_144)
            try workspace.validate()
            guard result.status == 0 else { throw GitHubPullRequestError(.notRepository) }
            return try Self.line(result.output)
        }
        let repository = try GitWorktreeDirectory(path: Self.canonical(try await discover(["rev-parse", "--path-format=absolute", "--show-toplevel"])))
        let admin = try GitWorktreeDirectory(path: Self.canonical(try await discover(["rev-parse", "--absolute-git-dir"])))
        let common = try GitWorktreeDirectory(path: Self.canonical(try await discover(["rev-parse", "--path-format=absolute", "--git-common-dir"])))
        guard path == repository.path || path.hasPrefix(repository.path + "/"),
              admin.path == common.path || admin.path.hasPrefix(common.path + "/worktrees/") else { throw GitHubPullRequestError(.notRepository) }
        let pointer = admin.path == repository.path + "/.git" ? nil : try repository.read(".git", allowEmpty: true)
        if admin.path != repository.path + "/.git", pointer == nil { throw GitHubPullRequestError(.notRepository) }
        let commonPointer = try admin.read("commondir", allowEmpty: true), backlink = try admin.read("gitdir", allowEmpty: true)
        func validate() throws {
            try workspace.validate(); try repository.validate(); try admin.validate(); try common.validate()
            if admin.path != repository.path + "/.git", try repository.read(".git", allowEmpty: true) != pointer { throw GitHubPullRequestError(.staleReview) }
            guard try admin.read("commondir", allowEmpty: true) == commonPointer,
                  try admin.read("gitdir", allowEmpty: true) == backlink else { throw GitHubPullRequestError(.staleReview) }
        }
        func run(_ args: [String]) async throws -> GitWorktreeCommandResult {
            try validate()
            let result = try await command.run(["--no-lazy-fetch", "--no-replace-objects"] + args, cwdFD: repository.fd,
                timeout: timeout, maximumOutput: 1_048_576, gitDirectory: admin.path, commonDirectory: common.path, workTree: repository.path)
            try validate(); return result
        }
        func config(_ key: String) async throws -> [String] {
            let value = try await run(["config", "--null", "--get-all", key])
            if value.status == 1 { return [] }
            guard value.status == 0 else { throw GitHubPullRequestError(.commandFailed) }
            return try value.output.split(separator: 0).map { data in
                guard let text = String(data: Data(data), encoding: .utf8), GitHubValidation.text(text, maximum: 16_384, allowEmpty: true) else { throw GitHubPullRequestError(.unsupportedRemote) }
                return text
            }
        }
        let symbolic = try await run(["symbolic-ref", "--quiet", "HEAD"])
        let branch: String?
        if symbolic.status == 1 { branch = nil }
        else {
            let value = try Self.line(symbolic.output)
            guard symbolic.status == 0, value.hasPrefix("refs/heads/") else { throw GitHubPullRequestError(.commandFailed) }
            branch = String(value.dropFirst(11))
            guard GitHubValidation.branch(branch!) else { throw GitHubPullRequestError(.invalidRequest) }
        }
        let resolved = try await run(["rev-parse", "--verify", "HEAD^{commit}"])
        let head = resolved.status == 0 ? try Self.line(resolved.output) : nil
        guard head.map(GitHubValidation.object) ?? true else { throw GitHubPullRequestError(.invalidResponse) }
        let namesResult = try await run(["remote"])
        guard namesResult.status == 0, let namesText = String(data: namesResult.output, encoding: .utf8) else { throw GitHubPullRequestError(.commandFailed) }
        let names = namesText.split(separator: "\n").map(String.init)
        guard names.count <= 100, Set(names).count == names.count, names.allSatisfy(GitHubValidation.refToken) else { throw GitHubPullRequestError(.ambiguousRemote) }
        var remotes: [GitHubPullRequestRemote] = []
        for name in names.sorted() {
            let urls = try await config("remote." + name + ".url"), push = try await config("remote." + name + ".pushurl")
            let marks = try await config("remote." + name + ".gh-resolved")
            let repository = urls.count == 1 ? try Self.remoteRepository(urls[0]) : nil
            let pushed = push.isEmpty ? repository : (push.count == 1 ? try Self.remoteRepository(push[0]) : nil)
            let digest = Self.digest(Data((urls.joined(separator: "\0") + "\0PUSH\0" + push.joined(separator: "\0")).utf8))
            remotes.append(.init(name: name, repository: repository, urlDigest: digest, resolved: marks.count == 1 ? marks[0] : marks.isEmpty ? nil : "invalid/multiple/marks", pushMatchesFetch: repository != nil && repository == pushed))
        }
        var remote: String?, remoteBranch: String?, pushOverride: String?
        if let branch {
            let upstreams = try await config("branch." + branch + ".remote"), merges = try await config("branch." + branch + ".merge")
            if upstreams.count == 1, merges.count == 1, merges[0].hasPrefix("refs/heads/") {
                remote = upstreams[0]; remoteBranch = String(merges[0].dropFirst(11))
                guard remote.map(GitHubValidation.refToken) ?? true, remoteBranch.map(GitHubValidation.branch) ?? true else { throw GitHubPullRequestError(.ambiguousRemote) }
            } else if !upstreams.isEmpty || !merges.isEmpty { remote = "ambiguous" }
            let overrides = try await config("branch." + branch + ".pushRemote")
            let defaults = try await config("remote.pushDefault")
            let values = overrides.isEmpty ? defaults : overrides
            pushOverride = values.count == 1 ? values[0] : values.isEmpty ? nil : "ambiguous"
        }
        let finalHead = try await run(["rev-parse", "--verify", "HEAD^{commit}"])
        let finalSymbolic = try await run(["symbolic-ref", "--quiet", "HEAD"])
        guard finalHead.status == resolved.status, finalHead.output == resolved.output,
              finalSymbolic.status == symbolic.status, finalSymbolic.output == symbolic.output else { throw GitHubPullRequestError(.staleReview) }
        struct Proof: Encodable {
            let paths: [String], identities: [GitWorktreeNodeIdentity], pointers: [String]
            let branch: String?, head: String?, remote: String?, remoteBranch: String?, pushOverride: String?
            let remotes: [GitHubPullRequestRemote]
        }
        let proof = Proof(paths: [path, repository.path, admin.path, common.path], identities: [workspace.identity, repository.identity, admin.identity, common.identity],
            pointers: [pointer, commonPointer, backlink].map { Self.digest($0 ?? Data()) },
            branch: branch, head: head, remote: remote, remoteBranch: remoteBranch, pushOverride: pushOverride, remotes: remotes)
        let encoder = JSONEncoder(); encoder.outputFormatting = .sortedKeys
        let value = GitHubPullRequestLocal(workspace: workspace, repository: repository, admin: admin, common: common,
            pointer: pointer, commonPointer: commonPointer, backlink: backlink, branch: branch, head: head,
            upstreamRemote: remote, upstreamBranch: remoteBranch, pushOverride: pushOverride, remotes: remotes, proof: Self.digest(try encoder.encode(proof)))
        try value.validate(); return value
    }
    static func remoteRepository(_ raw: String) throws -> GitHubRepository? {
        if raw.contains("://") {
            guard let c = URLComponents(string: raw), c.password == nil, c.query == nil, c.fragment == nil,
                  c.port == nil,
                  c.scheme == "ssh" || c.user == nil else { throw GitHubPullRequestError(.unsupportedRemote) }
        }
        guard let normalized = RepositoryIdentity.normalizedRemote(raw) else { return nil }
        let parts = normalized.canonicalKey.split(separator: "/", omittingEmptySubsequences: false)
        guard parts.count == 3 else { return nil }
        return try .init(host: String(parts[0]), owner: String(parts[1]), name: String(parts[2]))
    }
    static func line(_ data: Data) throws -> String {
        var bytes = data; if bytes.last == 10 { bytes.removeLast() }
        guard let text = String(data: bytes, encoding: .utf8), !text.contains("\0") else { throw GitHubPullRequestError(.invalidResponse) }; return text
    }
    static func canonical(_ path: String) -> String { URL(fileURLWithPath: path).standardizedFileURL.resolvingSymlinksInPath().path }
    static func digest(_ data: Data) -> String { SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined() }
}
