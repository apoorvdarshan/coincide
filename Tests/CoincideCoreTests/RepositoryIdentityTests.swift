import Darwin
import Foundation
import Testing
@testable import CoincideCore

private struct IdentityFixture: Sendable {
    let root: URL
    let environment: [String: String]
    static func make() throws -> Self {
        let root = try temporaryWorkspace().resolvingSymlinksInPath(), home = root.appendingPathComponent("home")
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
        var env = ProcessChannel.environment()
        for key in env.keys where key.hasPrefix("GIT_") { env.removeValue(forKey: key) }
        env["HOME"] = home.path; env["XDG_CONFIG_HOME"] = home.appendingPathComponent(".config").path
        env["GIT_CONFIG_GLOBAL"] = home.appendingPathComponent(".gitconfig").path; env["GIT_CONFIG_NOSYSTEM"] = "1"
        return .init(root: root, environment: env)
    }
    @discardableResult func git(_ folder: URL, _ arguments: [String]) async throws -> CommandResult {
        let result = try await CommandRunner.run("git", ["--no-pager", "-C", folder.path] + arguments, cwd: root, environment: environment)
        guard result.status == 0 else { throw CoincideError("Repository identity fixture Git failed.") }
        return result
    }
    func repository(_ name: String, bare: Bool = false) async throws -> URL {
        let folder = root.appendingPathComponent(name)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try await git(folder, ["init", "--initial-branch=main"] + (bare ? ["--bare"] : []))
        return folder
    }
    func resolve(_ folder: URL, environment override: [String: String]? = nil) async throws -> RepositoryIdentity? {
        try await RepositoryIdentityResolver(root: folder, environment: override ?? environment).resolve()
    }
}

@Test func repositoryRemoteNormalizationPreservesNestedNamesAndMatchesPinnedProtocolPortAndAzureKeys() throws {
    let cases = [
        ("git@github.com:T3Tools/T3Code.git", "github.com/t3tools/t3code"),
        ("https://github.com/T3Tools/T3Code.git/", "github.com/t3tools/t3code"),
        ("ssh://deploy@github.com/T3Tools/T3Code", "github.com/t3tools/t3code"),
        ("git://github.com/T3Tools/T3Code", "github.com/t3tools/t3code"),
        ("gitlab@gitlab.example.com:Group/Platform/Repo.git", "gitlab.example.com/group/platform/repo"),
        ("code.example.test:/team/repo.git", "code.example.test/team/repo"),
        ("https://gitlab.company.com:8443/team/project.git", "gitlab.company.com/team/project"),
        ("ssh://git@gitlab.company.com:2222/team/project.git", "gitlab.company.com/team/project"),
        ("git@x:team/project.git", "x/team/project"),
        ("git@[2001:db8::1]:team/project.git", "[2001:db8::1]/team/project"),
        ("https://münich.example/Team/Repo.git", "xn--mnich-kva.example/team/repo"),
        ("https://xn--mnich-kva.example/Team/Repo.git", "xn--mnich-kva.example/team/repo"),
        ("git@ssh.dev.azure.com:v3/T3Tools/Platform/T3Code", "dev.azure.com/t3tools/platform/_git/t3code"),
        ("ssh://git@ssh.dev.azure.com:22/v3/T3Tools/Platform/T3Code", "dev.azure.com/t3tools/platform/_git/t3code"),
        ("https://T3Tools@dev.azure.com/T3Tools/Platform/_git/T3Code", "dev.azure.com/t3tools/platform/_git/t3code"),
        ("T3Tools@vs-ssh.visualstudio.com:v3/T3Tools/Platform/T3Code", "t3tools.visualstudio.com/platform/_git/t3code")
    ]
    for (input, expected) in cases {
        let remote = try #require(RepositoryIdentity.normalizedRemote(input))
        #expect(remote.canonicalKey == expected)
        #expect(RepositoryIdentity.normalizedRemote(remote.remoteURL) == remote)
    }
    let nested = try #require(RepositoryIdentity.normalizedRemote("git@gitlab.com:T3Tools/platform/T3Code.git"))
    let identity = try RepositoryIdentity(remote: nested, remoteName: "origin", rootPath: "/tmp/repository", projectRelativePath: "packages/web")
    #expect(identity.displayName == "T3Tools/platform/T3Code" && identity.owner == "T3Tools" && identity.name == "T3Code" && identity.provider == "gitlab")
    #expect(identity.groupingKey == nested.canonicalKey && identity.groupingDisplayName == nested.displayName)
    for (host, provider) in [("enterprise.ghe.com", "github"), ("eu.dev.azure.com", "azure-devops"), ("staging.git.cafe", "gitcafe")] {
        #expect(RepositoryIdentity.normalizedRemote("https://" + host + "/Team/Repo.git")?.provider == provider)
    }
}

@Test func repositoryRemoteNormalizationDiscardsPrivateURLDataAndRejectsLocalHelpersAndMalformedSources() throws {
    for input in ["https://test-user:private-password@github.com/Team/Repo.git?access_token=private-query#private-fragment",
                  "ssh://test-user:private-password@github.com/Team/Repo.git?access_token=private-query#private-fragment",
                  "test-user@github.com:Team/Repo.git?access_token=private-query#private-fragment"] {
        let remote = try #require(RepositoryIdentity.normalizedRemote(input))
        #expect(remote.canonicalKey == "github.com/team/repo" && remote.displayName == "Team/Repo")
        let identity = try RepositoryIdentity(remote: remote, remoteName: "origin", rootPath: "/tmp/repository", projectRelativePath: "")
        let data = try JSONEncoder().encode(identity), encoded = String(decoding: data, as: UTF8.self)
        for secret in ["test-user", "private-password", "access_token", "private-query", "private-fragment"] { #expect(!encoded.contains(secret)) }
        #expect(try JSONDecoder().decode(RepositoryIdentity.self, from: data) == identity)
    }
    for input in ["", "--upload-pack=bad", ".", "../repo", "/srv/git/repo.git", "file:///srv/git/repo.git", "C:/repos/project", "C:\\repos\\project", "C:relative",
                  "ext::sh -c bad", "helper::repository", "ftp://example.com/team/repo", "https://github.com/", "git@github.com:?access_token=private-query",
                  "user:password@github.com:team/repo", "https://example.com/team/%00repo", "https://example.com/team/%0Arepo", "git@host:team/repo\n", "https://host/team/%zz"] {
        #expect(RepositoryIdentity.normalizedRemote(input) == nil)
    }
    for host in ["synthetic-user%3Asynthetic-pass%40example.invalid", "bad%20host.invalid", "bad%2Fhost.invalid", "bad%5Chost.invalid", "bad%3Fhost.invalid"] {
        #expect(RepositoryIdentity.normalizedRemote("https://" + host + "/Team/Repo") == nil)
    }
}

@Test func repositoryIdentityDecoderRejectsCredentialURLsAndInconsistentOrUnsafeStoredMetadata() throws {
    let remote = try #require(RepositoryIdentity.normalizedRemote("https://github.com/Team/Repo.git"))
    let origin = try #require(RepositoryIdentity.normalizedRemote("git@github.com:Someone/Fork.git"))
    let identity = try RepositoryIdentity(remote: remote, remoteName: "origin", rootPath: "/tmp/repository", projectRelativePath: "", origin: origin)
    let data = try JSONEncoder().encode(identity)
    for field in ["credential", "canonicalKey", "displayName", "provider", "name", "owner", "rootPath", "projectRelativePath", "origin"] {
        var object = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
        switch field {
        case "credential":
            var locator = try #require(object["locator"] as? [String: Any]); locator["remoteUrl"] = "https://private-user:private-password@github.com/Team/Repo.git?token=private-query#private-fragment"; object["locator"] = locator
        case "rootPath": object[field] = "/tmp/../private"
        case "projectRelativePath": object[field] = "../outside"
        case "origin": object[field] = ["canonicalKey": "github.com/someone/fork?token=private-query", "displayName": "Someone/Fork"]
        default: object[field] = "inconsistent"
        }
        let invalid = try JSONSerialization.data(withJSONObject: object)
        #expect(throws: (any Error).self) { try JSONDecoder().decode(RepositoryIdentity.self, from: invalid) }
    }
    #expect(try JSONDecoder().decode(RepositoryIdentity.self, from: data) == identity)
}

@Test func repositoryIdentityReadsFetchURLsSelectsUpstreamAndPreservesDistinctForkOriginWithoutNetwork() async throws {
    let f = try IdentityFixture.make(); defer { try? FileManager.default.removeItem(at: f.root) }
    let repo = try await f.repository("fork")
    try await f.git(repo, ["remote", "add", "origin", "https://private-user:private-password@github.com/Someone/Fork.git?token=private-query#private-fragment"])
    try await f.git(repo, ["remote", "set-url", "--push", "origin", "ext::must-never-run"])
    try await f.git(repo, ["remote", "add", "upstream", "git@github.com:T3Tools/t3code.git"])
    try await f.git(repo, ["config", "remote.upstream.promisor", "true"])
    try await f.git(repo, ["config", "remote.upstream.partialclonefilter", "blob:none"])
    let identity = try #require(try await f.resolve(repo))
    #expect(identity.locator.remoteName == "upstream" && identity.canonicalKey == "github.com/t3tools/t3code")
    #expect(identity.displayName == "T3Tools/t3code" && identity.origin?.canonicalKey == "github.com/someone/fork")
    #expect(identity.groupingKey == "github.com/someone/fork" && identity.groupingDisplayName == "Someone/Fork")
    let encoded = String(decoding: try JSONEncoder().encode(identity), as: UTF8.self)
    for secret in ["private-user", "private-password", "private-query", "private-fragment", "token="] { #expect(!encoded.contains(secret)) }
    try await f.git(repo, ["remote", "remove", "upstream"])
    #expect(try await f.resolve(repo)?.locator.remoteName == "origin")
    #expect(try await f.resolve(repo)?.origin == nil)
    try await f.git(repo, ["remote", "remove", "origin"])
    try await f.git(repo, ["remote", "add", "Z-mirror", "git@gitlab.com:Team/nested/Repo.git"])
    try await f.git(repo, ["remote", "add", "a-mirror", "ssh://git@example.invalid/Team/First.git"])
    #expect(try await f.resolve(repo)?.locator.remoteName == "a-mirror")
}

@Test func repositoryIdentityIgnoresNonRepositoriesAndLocalFilePushAndHelperRemotes() async throws {
    let f = try IdentityFixture.make(); defer { try? FileManager.default.removeItem(at: f.root) }
    #expect(try await f.resolve(f.root) == nil)
    let repo = try await f.repository("local")
    #expect(try await f.resolve(repo) == nil)
    for (name, url) in [("gb-local", "."), ("backup", "/srv/git/repo.git"), ("archive", "file:///srv/git/repo.git"), ("windows", "C:/repos/project"), ("helper", "ext::must-never-run")] {
        try await f.git(repo, ["remote", "add", name, url])
    }
    try await f.git(repo, ["remote", "set-url", "--push", "gb-local", "https://github.com/Push/Only.git"])
    #expect(try await f.resolve(repo) == nil)
    try await f.git(repo, ["remote", "add", "mirror", "git@gitlab.com:Team/nested/Repo.git"])
    #expect(try await f.resolve(repo)?.canonicalKey == "gitlab.com/team/nested/repo")
    #expect(try await f.resolve(repo.appendingPathComponent(".git")) == nil)
}

@Test func repositoryIdentityPinsNestedAndSymlinkRootsAndIgnoresInheritedGitContextWithoutWritingTraceFiles() async throws {
    let f = try IdentityFixture.make(); defer { try? FileManager.default.removeItem(at: f.root) }
    let repo = try await f.repository("repository\n"), other = try await f.repository("unrelated")
    try await f.git(repo, ["remote", "add", "origin", "git@gitlab.com:Team/nested/Repo.git"])
    try await f.git(other, ["remote", "add", "origin", "https://github.com/Wrong/Repository.git"])
    let nested = repo.appendingPathComponent("packages/web"), alias = f.root.appendingPathComponent("alias")
    try FileManager.default.createDirectory(at: nested, withIntermediateDirectories: true)
    try FileManager.default.createSymbolicLink(at: alias, withDestinationURL: nested)
    var environment = f.environment
    for key in ["GIT_DIR", "GIT_COMMON_DIR", "GIT_OBJECT_DIRECTORY"] { environment[key] = other.appendingPathComponent(".git").path }
    environment["GIT_WORK_TREE"] = other.path; environment["GIT_INDEX_FILE"] = other.appendingPathComponent(".git/index").path
    environment["GIT_CONFIG_COUNT"] = "1"; environment["GIT_CONFIG_KEY_0"] = "remote.origin.url"; environment["GIT_CONFIG_VALUE_0"] = "https://github.com/Wrong/Injected.git"
    environment["GIT_CONFIG_PARAMETERS"] = "'remote.origin.url=https://github.com/Wrong/Injected.git'"
    environment["GIT_CEILING_DIRECTORIES"] = repo.path; environment["GIT_DISCOVERY_ACROSS_FILESYSTEM"] = "0"
    let trace = f.root.appendingPathComponent("trace-must-not-exist")
    environment["GIT_TRACE"] = trace.path; environment["GIT_TRACE2_EVENT"] = trace.path
    let identity = try #require(try await f.resolve(alias, environment: environment))
    #expect(identity.rootPath == repo.path && identity.projectRelativePath == "packages/web" && identity.canonicalKey == "gitlab.com/team/nested/repo")
    #expect(!FileManager.default.fileExists(atPath: trace.path))
    #expect(try await f.resolve(repo)?.projectRelativePath == "")
}

@Test func repositoryIdentitySupportsExplicitBareLayoutsAndDetachedWorktreeRootsAndRefreshesConfiguration() async throws {
    let f = try IdentityFixture.make(); defer { try? FileManager.default.removeItem(at: f.root) }
    for layout in ["bare", "dot-bare"] {
        let container = f.root.appendingPathComponent(layout)
        try FileManager.default.createDirectory(at: container, withIntermediateDirectories: true)
        let gitDirectory = layout == "bare" ? container : container.appendingPathComponent(".bare")
        try await f.git(container, ["init", "--bare", gitDirectory.path])
        if layout == "dot-bare" { try "gitdir: ./.bare\n".write(to: container.appendingPathComponent(".git"), atomically: true, encoding: .utf8) }
        try await f.git(container, ["--git-dir=" + gitDirectory.path, "remote", "add", "origin", "https://github.com/Team/Repo.git"])
        let identity = try #require(try await f.resolve(container))
        #expect(identity.rootPath == gitDirectory.path && identity.canonicalKey == "github.com/team/repo")
        #expect(identity.projectRelativePath == (layout == "bare" ? "" : nil))
        try await f.git(container, ["--git-dir=" + gitDirectory.path, "remote", "set-url", "origin", "git@gitlab.com:Team/Changed.git"])
        #expect(try await f.resolve(gitDirectory)?.canonicalKey == "gitlab.com/team/changed")
    }
    let repo = try await f.repository("worktree-main"), worktree = f.root.appendingPathComponent("detached-worktree")
    try await f.git(repo, ["remote", "add", "origin", "git@github.com:Team/Repo.git"])
    try await f.git(repo, ["-c", "user.name=Coincide Test", "-c", "user.email=test@example.invalid", "-c", "commit.gpgSign=false", "-c", "core.hooksPath=/dev/null", "commit", "--allow-empty", "--message", "Fixture"])
    try await f.git(repo, ["worktree", "add", "--detach", worktree.path, "HEAD"])
    let nested = worktree.appendingPathComponent("packages/app")
    try FileManager.default.createDirectory(at: nested, withIntermediateDirectories: true)
    let identity = try #require(try await f.resolve(nested))
    #expect(identity.rootPath == worktree.path && identity.projectRelativePath == "packages/app" && identity.canonicalKey == "github.com/team/repo")
}

private func identityWriterWhenReadStarts(_ path: String) async throws -> Int32 {
    let deadline = ContinuousClock.now + .seconds(5)
    while true {
        let descriptor = open(path, O_WRONLY | O_NONBLOCK | O_CLOEXEC)
        if descriptor >= 0 { return descriptor }
        guard errno == ENXIO, ContinuousClock.now < deadline else { throw CoincideError("Repository metadata fixture did not begin reading its isolated config pipe.") }
        try await Task.sleep(for: .milliseconds(10))
    }
}

@Test(.timeLimit(.minutes(1))) func repositoryIdentityCancellationWaitsForTheActualReadOnlyGitProcessToExit() async throws {
    let f = try IdentityFixture.make(); defer { try? FileManager.default.removeItem(at: f.root) }
    let repo = try await f.repository("cancel"), fifo = f.root.appendingPathComponent("config-pipe")
    #expect(mkfifo(fifo.path, 0o600) == 0)
    try await f.git(repo, ["config", "--local", "include.path", fifo.path])
    let task = Task { try await f.resolve(repo) }
    do {
        let writer = try await identityWriterWhenReadStarts(fifo.path); defer { close(writer) }
        task.cancel()
        await #expect(throws: CancellationError.self) { try await task.value }
        // With no reader left, a new nonblocking writer must fail, proving Git's FD closed.
        let probe = open(fifo.path, O_WRONLY | O_NONBLOCK | O_CLOEXEC), failure = errno
        if probe >= 0 { close(probe) }
        #expect(probe == -1 && failure == ENXIO)
        #expect(FileManager.default.fileExists(atPath: repo.appendingPathComponent(".git/config").path))
    } catch { task.cancel(); _ = try? await task.value; throw error }
}

@Test(.timeLimit(.minutes(1))) func repositoryIdentityBoundsMetadataAndDiagnosticsAndPropagatesCancellationBeforeLaunch() async throws {
    let f = try IdentityFixture.make(); defer { try? FileManager.default.removeItem(at: f.root) }
    let repo = try await f.repository("large")
    let configuration = repo.appendingPathComponent(".git/config")
    let before = try Data(contentsOf: configuration)
    var bytes = before
    bytes.append(Data(("\n[remote \"origin\"]\n\turl = https://private-user:private-password@example.invalid/Team/" + String(repeating: "a", count: 300_000) + "?token=private-query\n").utf8))
    try bytes.write(to: configuration)
    do { _ = try await f.resolve(repo); Issue.record("Oversized repository metadata was accepted.") }
    catch {
        #expect(error.localizedDescription.contains("size limit"))
        for secret in ["private-user", "private-password", "private-query", "token="] { #expect(!error.localizedDescription.contains(secret)) }
    }
    let unchanged = try Data(contentsOf: configuration) == bytes
    #expect(unchanged)
    let cancelled = Task { withUnsafeCurrentTask { $0?.cancel() }; return try await f.resolve(repo) }
    await #expect(throws: CancellationError.self) { try await cancelled.value }
}
