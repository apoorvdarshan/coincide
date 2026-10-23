import Darwin
import Foundation
import Testing
@testable import CoincideCore

/// Real native helper + SQLite + local Git. The sole GitHub executable is a
/// private stand-in; its fetch wrapper permits only two exact local bare repos.
private struct RemotePRFixture: Sendable {
    let root: URL, workspace: URL, data: URL, host: URL, github: URL, proxy: URL
    let head: String, base: String
    var environment: [String: String] {
        ["PATH": root.appendingPathComponent("bin").path + ":/usr/bin:/bin:/usr/sbin:/sbin",
         "HOME": root.appendingPathComponent("home").path, "XDG_CONFIG_HOME": root.appendingPathComponent("home").path,
         "GH_CONFIG_DIR": root.appendingPathComponent("gh-home").path, "LANG": "en_US.UTF-8",
         "GIT_CONFIG_NOSYSTEM": "1", "GIT_CONFIG_SYSTEM": "/dev/null", "GIT_CONFIG_GLOBAL": "/dev/null",
         "GIT_ALLOW_PROTOCOL": "file", "GIT_TERMINAL_PROMPT": "0", "GCM_INTERACTIVE": "Never",
         "GIT_AUTHOR_NAME": "Private remote PR", "GIT_COMMITTER_NAME": "Private remote PR",
         "GIT_AUTHOR_EMAIL": "pr@example.invalid", "GIT_COMMITTER_EMAIL": "pr@example.invalid",
         "PYTHONNOUSERSITE": "1"]
    }
    var arguments: [String] {
        ["--stdio", "--data-directory", data.path, "--github-executable", github.path,
         "--github-configuration-directory", root.appendingPathComponent("gh-home").path,
         "--codex-executable", root.appendingPathComponent("provider-must-never-run").path,
         "--codex-home", root.appendingPathComponent("codex-home").path]
    }
    static func quote(_ text: String) -> String { "'" + text.replacingOccurrences(of: "'", with: "'\\''") + "'" }
    static func make(existing: Bool = false) async throws -> Self {
        let manager = FileManager.default
        let root = manager.temporaryDirectory.appendingPathComponent("coincide-remote-pr-\(UUID())").resolvingSymlinksInPath()
        try manager.createDirectory(at: root, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        do {
            let workspace = root.appendingPathComponent("workspace"), data = root.appendingPathComponent("data")
            for child in [workspace, data, root.appendingPathComponent("home"), root.appendingPathComponent("gh-home"),
                          root.appendingPathComponent("codex-home"), root.appendingPathComponent("bin")] {
                try manager.createDirectory(at: child, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
            }
            let ghPeer = try #require(Bundle.module.url(forResource: "remote_pull_request_gh", withExtension: "py", subdirectory: "Fixtures"))
            let gitPeer = try #require(Bundle.module.url(forResource: "remote_pull_request_git", withExtension: "py", subdirectory: "Fixtures"))
            let proxy = try #require(Bundle.module.url(forResource: "remote_pull_request_proxy", withExtension: "py", subdirectory: "Fixtures"))
            #if DEBUG
            let configuration = "debug"
            #else
            let configuration = "release"
            #endif
            let checkout = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            let helper = checkout.appendingPathComponent(".build/\(configuration)/CoincideEnvironment").resolvingSymlinksInPath()
            guard manager.isExecutableFile(atPath: helper.path) else { throw CoincideError("Build the native helper before remote PR acceptance.") }
            let host = root.appendingPathComponent("native-host"), github = root.appendingPathComponent("private-gh")
            for (path, contents) in [
                (host, "#!/bin/sh\numask 077\nprintf '%s\\n' \"$$\" >> \(quote(root.appendingPathComponent("host-pids.txt").path))\nexec \(quote(helper.path)) \"$@\"\n"),
                (github, "#!/bin/sh\nexec /usr/bin/python3 \(quote(ghPeer.path)) \(quote(root.path)) \"$@\"\n"),
                (root.appendingPathComponent("bin/git"), "#!/bin/sh\nexec /usr/bin/python3 \(quote(gitPeer.path)) \(quote(root.path)) \"$@\"\n"),
                (root.appendingPathComponent("provider-must-never-run"), "#!/bin/sh\nprintf '%s\\n' \"$$\" >> \(quote(root.appendingPathComponent("unexpected-provider-pids.txt").path))\nexit 73\n")
            ] {
                try contents.write(to: path, atomically: false, encoding: .utf8)
                try manager.setAttributes([.posixPermissions: 0o700], ofItemAtPath: path.path)
            }
            let seed = Self(root: root, workspace: workspace, data: data, host: host, github: github, proxy: proxy, head: "", base: "")
            _ = try await seed.git(["init", "--initial-branch=main"])
            _ = try await seed.git(["config", "commit.gpgsign", "false"])
            try Data("Private base\n".utf8).write(to: workspace.appendingPathComponent("README.md"))
            _ = try await seed.git(["add", "--", "README.md"]); _ = try await seed.git(["commit", "-m", "Private base"])
            let base = try await seed.git(["rev-parse", "HEAD"])
            _ = try await seed.git(["checkout", "-b", "feature/topic"])
            try Data("Private head\n".utf8).write(to: workspace.appendingPathComponent("feature.txt"))
            _ = try await seed.git(["add", "--", "feature.txt"]); _ = try await seed.git(["commit", "-m", "Private head"])
            let head = try await seed.git(["rev-parse", "HEAD"])
            for bare in ["base.git", "head.git"] { _ = try await seed.git(["init", "--bare", root.appendingPathComponent(bare).path]) }
            _ = try await seed.git(["push", root.appendingPathComponent("base.git").path, "main:refs/heads/main", "feature/topic:refs/pull/42/head"])
            _ = try await seed.git(["push", root.appendingPathComponent("head.git").path, "main:refs/heads/main", "feature/topic:refs/heads/feature/topic"])
            _ = try await seed.git(["remote", "add", "origin", "https://github.com/fork/project.git"])
            _ = try await seed.git(["remote", "add", "upstream", "https://github.com/upstream/project.git"])
            _ = try await seed.git(["config", "branch.feature/topic.remote", "origin"])
            _ = try await seed.git(["config", "branch.feature/topic.merge", "refs/heads/feature/topic"])
            _ = try await seed.git(["update-ref", "refs/remotes/origin/feature/topic", head])
            let f = Self(root: root, workspace: workspace, data: data, host: host, github: github, proxy: proxy, head: head, base: base)
            try f.writeState(["head": head, "base": base, "existing": existing, "creates": 0])
            return f
        } catch { try? manager.removeItem(at: root); throw error }
    }
    @discardableResult func git(_ args: [String], at directory: URL? = nil) async throws -> String {
        let result = try await CommandRunner.run("/usr/bin/git", ["--literal-pathspecs", "-C", (directory ?? workspace).path] + args,
            timeout: .seconds(10), environment: environment)
        guard result.status == 0 else { throw CoincideError("The private remote PR Git fixture failed.") }
        return result.text.trimmingCharacters(in: .newlines)
    }
    func state() throws -> [String: Any] { try #require(JSONSerialization.jsonObject(with: Data(contentsOf: root.appendingPathComponent("gh-state.json"))) as? [String: Any]) }
    func writeState(_ value: [String: Any]) throws {
        let path = root.appendingPathComponent("gh-state.json")
        try JSONSerialization.data(withJSONObject: value, options: [.sortedKeys]).write(to: path, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: path.path)
    }
    func change(_ change: (inout [String: Any]) -> Void) throws { var value = try state(); change(&value); try writeState(value) }
    func rows(_ name: String) throws -> [JSONValue] {
        let path = root.appendingPathComponent(name)
        guard FileManager.default.fileExists(atPath: path.path) else { return [] }
        return try Data(contentsOf: path).split(separator: 10).map { try JSONDecoder().decode(JSONValue.self, from: Data($0)) }
    }
    func connection(dropping commandID: UUID? = nil) throws -> JSONRPCConnection {
        if let commandID {
            return try .init(executable: URL(fileURLWithPath: "/usr/bin/python3"), arguments: [proxy.path, root.path, commandID.uuidString, host.path] + arguments,
                cwd: root, dialect: .jsonRPC2, maximumFrameSize: RemoteEnvironmentProtocol.maximumFrameBytes, environment: environment, drainProcessOnClose: true)
        }
        return try .init(executable: host, arguments: arguments, cwd: root, dialect: .jsonRPC2,
            maximumFrameSize: RemoteEnvironmentProtocol.maximumFrameBytes, environment: environment, drainProcessOnClose: true)
    }
    func register(_ client: RemoteEnvironmentClient, projectID: UUID? = nil) async throws -> RemoteWorkspaceTarget {
        let descriptor = try await client.discover(); try await client.trust(environmentID: descriptor.environmentID); _ = try await client.connect()
        let project = projectID ?? UUID(), thread = UUID()
        if projectID == nil { #expect(try await client.command(.addProject(id: project, path: workspace.path, title: "Private remote PR")).receipt.rejection == nil) }
        #expect(try await client.command(.createThread(id: thread, projectID: project, provider: .codex, title: "Private PR source",
            model: "private-pr-never-run", permission: .supervised)).receipt.rejection == nil)
        let owner = try await remotePRThread(client, thread)
        return try await client.bindPullRequestWorkspace(.init(environmentID: descriptor.environmentID, projectID: project, threadID: thread, configuration: .init(thread: owner)))
    }
    func release() {
        for name in ["release-create", "release-fetch", "release-commit"] {
            _ = FileManager.default.createFile(atPath: root.appendingPathComponent(name).path, contents: Data(), attributes: [.posixPermissions: 0o600])
        }
    }
    func finish(_ client: RemoteEnvironmentClient) async throws {
        release(); await client.close()
        var pids: [Int32] = []
        for name in ["host-pids.txt", "proxy-pids.txt"] {
            let path = root.appendingPathComponent(name)
            if FileManager.default.fileExists(atPath: path.path) { pids += try String(contentsOf: path, encoding: .utf8).split(whereSeparator: \.isNewline).compactMap { Int32($0) } }
        }
        for name in ["gh-wire.jsonl", "git-wire.jsonl"] {
            for row in try rows(name) { if case .number(let value) = row["pid"], let pid = Int32(exactly: value) { pids.append(pid) } }
        }
        let ownedPIDs = pids
        try await remotePREventually { ownedPIDs.allSatisfy { kill($0, 0) == -1 && errno == ESRCH } }
        #expect(!FileManager.default.fileExists(atPath: root.appendingPathComponent("unexpected-provider-pids.txt").path))
        try FileManager.default.removeItem(at: root)
    }
    func failed(_ client: RemoteEnvironmentClient) async {
        release(); await client.close()
        if let snapshot = await client.currentSnapshot(), let bytes = try? JSONEncoder().encode(snapshot) {
            _ = FileManager.default.createFile(atPath: root.appendingPathComponent("failed-snapshot.json").path, contents: bytes, attributes: [.posixPermissions: 0o600])
        }
        print("Private remote PR fixture retained at \(root.path)")
    }
}
private final class RemotePRConnections: @unchecked Sendable {
    let fixture: RemotePRFixture, dropped: UUID?
    private let lock = NSLock(); private var count = 0
    init(_ fixture: RemotePRFixture, dropping: UUID? = nil) { self.fixture = fixture; dropped = dropping }
    func make() throws -> JSONRPCConnection {
        try lock.withLock { let id = count == 0 ? dropped : nil; count += 1; return try fixture.connection(dropping: id) }
    }
}
private func remotePREventually(_ predicate: @escaping @Sendable () async throws -> Bool) async throws {
    let deadline = ContinuousClock.now + .seconds(12)
    while try await !predicate() {
        guard ContinuousClock.now < deadline else { throw CoincideError("The native remote PR fixture did not reach its owned boundary.") }
        try await Task.sleep(for: .milliseconds(10))
    }
}
private func remotePRThread(_ client: RemoteEnvironmentClient, _ id: UUID) async throws -> CodingThread {
    try #require(await client.snapshot().workspace.threads.first { $0.id == id })
}
private func remotePRReference() throws -> GitHubPullRequestReference { try .init(repository: .init(owner: "upstream", name: "project"), number: 42) }
private func remotePRCreation(_ client: RemoteEnvironmentClient, _ id: UUID) async throws -> PullRequestCreationOperation? {
    try await client.snapshot().workspace.pullRequestCreation(id)
}
private func remotePRCheckout(_ client: RemoteEnvironmentClient, _ id: UUID) async throws -> PullRequestCheckoutOperation? {
    try await client.snapshot().workspace.pullRequestCheckout(id)
}
private func remotePRBegin(_ target: RemoteWorkspaceTarget, _ review: RemotePullRequestReview) -> RemoteEnvironmentCommand {
    .pullRequest(target: target, action: .begin(reviewID: review.id, digest: review.digest))
}

@Test(.timeLimit(.minutes(1)))
func remotePRNativeHostReadsBoundGitHubMetadataAndDiscardsReviewWithoutGitOrProviderMutation() async throws {
    let f = try await RemotePRFixture.make(existing: true), connections = RemotePRConnections(f)
    let client = RemoteEnvironmentClient(factory: { try connections.make() })
    do {
        let target = try await f.register(client), beforeHead = try await f.git(["rev-parse", "HEAD"])
        let beforeIndex = try Data(contentsOf: f.workspace.appendingPathComponent(".git/index"))
        let context = try await client.readPullRequests(.init(target: target, query: .context))
        guard case .context(let value) = context.value else { throw CoincideError("The native PR context returned another value type.") }
        #expect(context.target == target && value.repository.nameWithOwner == "upstream/project" && value.headRepository?.nameWithOwner == "fork/project")
        let listed = try await client.readPullRequests(.init(target: target, query: .list(.init(state: .open, query: "private", limit: 1))))
        guard case .page(let page) = listed.value else { throw CoincideError("The native PR list returned another value type.") }
        #expect(page.items.count == 1 && page.truncated && page.items[0].headCommit == f.head)
        let detail = try await client.readPullRequests(.init(target: target, query: .detail(try remotePRReference())))
        guard case .detail(let found) = detail.value else { throw CoincideError("The native PR detail returned another value type.") }
        #expect(found.summary.reference.number == 42 && found.checks.first?.state == .success && found.body == "Private remote PR description")
        #expect(try await client.readPullRequests(.init(target: target, query: .resolve("https://github.com/upstream/project/pull/42"))).value == detail.value)
        let review = try await client.reviewPullRequest(.init(target: target, intent: .create(title: "Reviewed only", body: "Literal body", baseBranch: "main", isDraft: true)))
        let discarded = try await client.discardPullRequestReview(.init(target: target, reviewID: review.id, digest: review.digest))
        #expect(discarded.discarded)
        #expect(try await client.command(remotePRBegin(target, review)).receipt.rejection != nil)
        #expect(try await f.git(["rev-parse", "HEAD"]) == beforeHead)
        #expect(try Data(contentsOf: f.workspace.appendingPathComponent(".git/index")) == beforeIndex)
        #expect(try f.state()["creates"] as? Int == 0)
        #expect(try f.rows("git-wire.jsonl").isEmpty)
        try await f.finish(client)
    } catch { await f.failed(client); throw error }
}

@Test(.timeLimit(.minutes(1)))
func remotePRNativeHostLostCreateReplyKeepsOriginalUUIDReceiptAndExecutesOneExternalCreate() async throws {
    let f = try await RemotePRFixture.make(), commandID = UUID(), connections = RemotePRConnections(f, dropping: commandID)
    let client = RemoteEnvironmentClient(factory: { try connections.make() })
    do {
        let target = try await f.register(client), draft = "Preserve exact source draft e\u{301}"
        #expect(try await client.command(.editThread(threadID: target.threadID, edit: .draft(draft), expectedConfiguration: target.configuration)).receipt.rejection == nil)
        let title = "Literal $(never-run) `title`", body = "Leading paragraph\n\nExact remote body 🌍\n"
        let review = try await client.reviewPullRequest(.init(target: target, intent: .create(title: title, body: body, baseBranch: "main", isDraft: true)))
        try f.change { $0["commandID"] = commandID.uuidString; $0["reviewID"] = review.id.uuidString }
        let command = remotePRBegin(target, review)
        await #expect(throws: RemoteEnvironmentClientError(.commandUncertain, commandID: commandID)) { _ = try await client.command(command, id: commandID) }
        let dropped = try JSONDecoder().decode(JSONValue.self, from: Data(contentsOf: f.root.appendingPathComponent("dropped-response.json")))
        let accepted = try RemoteEnvironmentProtocol.decode(RemoteEnvironmentCommandResult.self, from: dropped["result"])
        #expect(accepted.receipt.commandID == commandID && accepted.receipt.rejection == nil)
        _ = try await client.reconnect()
        #expect(try await client.receipt(for: command, id: commandID).receipt == accepted.receipt)
        await #expect(throws: RemoteEnvironmentClientError(.commandAlreadyAttempted, commandID: commandID)) { _ = try await client.command(command, id: commandID) }
        let created = try #require(try await remotePRCreation(client, review.id))
        #expect(created.phase == .created && created.review.id == review.id)
        #expect(try f.state()["creates"] as? Int == 1)
        #expect(try f.state()["title"] as? String == title && f.state()["body"] as? String == body)
        #expect(try f.rows("gh-wire.jsonl").filter { $0["kind"].string == "create" }.count == 1)
        #expect(try await remotePRThread(client, target.threadID).draft.utf8.elementsEqual(draft.utf8))
        let rebound = try await client.bindPullRequestWorkspace(target)
        let read = try await client.readPullRequests(.init(target: rebound, query: .context))
        guard case .context(let context) = read.value else { throw CoincideError("The restored PR context returned another value type.") }
        #expect(context.existingPullRequest?.reference.number == 42 && context.existingPullRequest?.isDraft == true)
        try await f.finish(client)
    } catch { await f.failed(client); throw error }
}

@Test(.timeLimit(.minutes(1)), arguments: ["lost-before", "lost-after"])
func remotePRNativeHostInspectsUncertainCreationWithoutRetryAndAcknowledgesUnprovenAbsence(outcome: String) async throws {
    let f = try await RemotePRFixture.make(), connections = RemotePRConnections(f)
    let client = RemoteEnvironmentClient(factory: { try connections.make() })
    do {
        let target = try await f.register(client)
        let review = try await client.reviewPullRequest(.init(target: target, intent: .create(title: "Inspect exact creation", body: "Keep review bytes", baseBranch: "main", isDraft: false)))
        let id = UUID(); try f.change { $0["createOutcome"] = outcome; $0["commandID"] = id.uuidString; $0["reviewID"] = review.id.uuidString }
        #expect(try await client.command(remotePRBegin(target, review), id: id).receipt.rejection == nil)
        try await remotePREventually { try await remotePRCreation(client, review.id)?.phase == .unconfirmed }
        _ = try await client.reconnect(); let rebound = try await client.bindPullRequestWorkspace(target)
        #expect(try await remotePRCreation(client, review.id)?.phase == .unconfirmed)
        #expect(try await client.command(.pullRequest(target: rebound, action: .inspectCreation(operationID: review.id))).receipt.rejection == nil)
        let inspected = try #require(try await remotePRCreation(client, review.id))
        if outcome == "lost-after" {
            #expect(inspected.phase == .openedExisting)
            guard case .openedExisting(let detail)? = inspected.result else { throw CoincideError("PR inspection must report the observed existing request.") }
            #expect(detail.summary.reference == (try remotePRReference()))
        }
        else {
            #expect(inspected.phase == .unconfirmed && inspected.acknowledgedAt == nil)
            #expect(try await client.command(.pullRequest(target: rebound, action: .acknowledgeCreation(operationID: review.id))).receipt.rejection == nil)
            #expect(try await remotePRCreation(client, review.id)?.acknowledgedAt != nil)
        }
        #expect(try f.state()["creates"] as? Int == 1)
        #expect(try f.rows("gh-wire.jsonl").filter { $0["kind"].string == "create" }.count == 1)
        try await f.finish(client)
    } catch { await f.failed(client); throw error }
}

@Test(.timeLimit(.minutes(1)), arguments: ["local", "worktree", "reuse"])
func remotePRNativeHostImportsReviewedCheckoutIntoOneBlankConversationAndPreservesSourceAndOffHeadReuse(mode: String) async throws {
    let f = try await RemotePRFixture.make(existing: true), connections = RemotePRConnections(f)
    let client = RemoteEnvironmentClient(factory: { try connections.make() })
    do {
        _ = try await f.git(["checkout", "main"])
        let target = try await f.register(client), draft = "Keep the current source draft"
        #expect(try await client.command(.editThread(threadID: target.threadID, edit: .draft(draft), expectedConfiguration: target.configuration)).receipt.rejection == nil)
        let intent = RemotePullRequestIntent.checkout(reference: try remotePRReference(), mode: mode == "local" ? .local : .worktree, submodules: .none, title: "Reviewed remote PR")
        var review = try await client.reviewPullRequest(.init(target: target, intent: intent))
        var retainedHead: String?, reused: URL?
        if mode == "reuse" {
            guard case .checkout(let value) = review.value else { throw CoincideError("The checkout review had another value type.") }
            #expect(try await client.discardPullRequestReview(.init(target: target, reviewID: review.id, digest: review.digest)).discarded)
            let destination = f.root.appendingPathComponent("Retained registered checkout")
            _ = try await f.git(["worktree", "add", "-b", value.plan.requestedBranch, destination.path, f.base])
            try Data("Retained local commit\n".utf8).write(to: destination.appendingPathComponent("README.md"))
            _ = try await f.git(["add", "--", "README.md"], at: destination); _ = try await f.git(["commit", "-m", "Retained local commit"], at: destination)
            retainedHead = try await f.git(["rev-parse", "HEAD"], at: destination)
            try Data("Retained dirty bytes\n".utf8).write(to: destination.appendingPathComponent("README.md"))
            reused = destination
            review = try await client.reviewPullRequest(.init(target: target, intent: intent))
        }
        guard case .checkout(let captured) = review.value else { throw CoincideError("The native checkout review had another value type.") }
        #expect(!captured.reviewSetup && captured.targetConfiguration.nativeThreadID == nil && captured.plan.requestedHeadCommit == f.head)
        #expect(try await client.snapshot().workspace.threads.contains { $0.id == captured.targetThreadID } == false)
        let id = UUID(), reviewID = review.id, command = remotePRBegin(target, review)
        let accepted = try await client.command(command, id: id)
        #expect(accepted.receipt.rejection == nil)
        try await remotePREventually { try await remotePRCheckout(client, reviewID)?.phase == .completed }
        let completed = try #require(try await remotePRCheckout(client, review.id)), result = try #require(completed.result)
        let snapshot = try await client.snapshot(), imported = try #require(snapshot.workspace.threads.first { $0.id == captured.targetThreadID })
        #expect(snapshot.workspace.threads.count == 2 && imported.messages.isEmpty && imported.draft.isEmpty && imported.queuedTurns.isEmpty)
        #expect(imported.providerThreadID == nil && imported.activeRun == nil && imported.pullRequestCheckoutOperationID == review.id)
        #expect(imported.model == target.configuration.model && imported.workspacePath == result.destinationPath)
        #expect(snapshot.workspace.threads.first { $0.id == target.threadID }?.draft == draft)
        if let reused, let retainedHead {
            #expect(!result.isOnPullRequestHead && result.destinationPath == reused.path && result.headCommit == retainedHead)
            #expect(try await f.git(["rev-parse", "HEAD"], at: reused) == retainedHead)
            #expect(try Data(contentsOf: reused.appendingPathComponent("README.md")) == Data("Retained dirty bytes\n".utf8))
        } else { #expect(result.isOnPullRequestHead && result.headCommit == f.head) }
        #expect(try await f.git(["rev-parse", "HEAD"]) == (mode == "local" ? f.head : f.base))
        _ = try await client.reconnect()
        #expect(try await client.receipt(for: command, id: id).receipt == accepted.receipt)
        #expect(try await client.snapshot().workspace.threads.filter { $0.id == captured.targetThreadID }.count == 1)
        try await f.finish(client)
    } catch { await f.failed(client); throw error }
}

@Test(.timeLimit(.minutes(1)), arguments: ["digest", "configuration", "root", "owner"])
func remotePRNativeHostRefusesChangedReviewConfigurationRootAndOwnerBeforeAnyExternalCreate(change: String) async throws {
    let f = try await RemotePRFixture.make(), connections = RemotePRConnections(f)
    let client = RemoteEnvironmentClient(factory: { try connections.make() })
    do {
        let target = try await f.register(client), draft = "Exact draft survives refused PR"
        #expect(try await client.command(.editThread(threadID: target.threadID, edit: .draft(draft), expectedConfiguration: target.configuration)).receipt.rejection == nil)
        let review = try await client.reviewPullRequest(.init(target: target, intent: .create(title: "Refused review", body: "Keep exact body", baseBranch: "main", isDraft: false)))
        var command = remotePRBegin(target, review)
        switch change {
        case "digest": command = .pullRequest(target: target, action: .begin(reviewID: review.id, digest: String(repeating: "0", count: 64)))
        case "configuration":
            #expect(try await client.command(.editThread(threadID: target.threadID, edit: .model("newer-model"), expectedConfiguration: target.configuration)).receipt.rejection == nil)
        case "root":
            let old = f.root.appendingPathComponent("original-workspace")
            try FileManager.default.moveItem(at: f.workspace, to: old)
            try FileManager.default.copyItem(at: old, to: f.workspace)
        default:
            let other = try await f.register(client, projectID: target.projectID)
            command = .pullRequest(target: other, action: .begin(reviewID: review.id, digest: review.digest))
        }
        #expect(try await client.command(command).receipt.rejection != nil)
        let refused = try await remotePRThread(client, target.threadID)
        #expect(refused.draft == draft && refused.messages.isEmpty && refused.queuedTurns.isEmpty && refused.activeRun == nil)
        #expect(try await client.snapshot().workspace.pullRequestCreations?.isEmpty != false)
        #expect(try f.state()["creates"] as? Int == 0 && f.rows("git-wire.jsonl").isEmpty)
        try await f.finish(client)
    } catch { await f.failed(client); throw error }
}

@Test(.timeLimit(.minutes(1)))
func remotePRNativeHostRefusesReviewedLocalCheckoutWhileAnActualFileMutationOwnsItsRoot() async throws {
    let f = try await RemotePRFixture.make(existing: true), connections = RemotePRConnections(f)
    let client = RemoteEnvironmentClient(factory: { try connections.make() })
    do {
        _ = try await f.git(["checkout", "main"])
        let target = try await f.register(client)
        let review = try await client.reviewPullRequest(.init(target: target, intent: .checkout(reference: try remotePRReference(), mode: .local, submodules: .none, title: nil)))
        try f.change { $0["holdCommit"] = true }
        let commit = RemoteWorkspaceMutationRequest(target: target, mutation: .gitCommit(message: "Held empty private commit"))
        _ = try await client.beginWorkspaceOperation(commit)
        try await remotePREventually { try f.rows("git-wire.jsonl").contains { $0["kind"].string == "held-commit" } }
        #expect(try await client.workspaceOperation(commit)?.state == .running)
        #expect(try await client.command(remotePRBegin(target, review)).receipt.rejection != nil)
        #expect(try await client.snapshot().workspace.pullRequestCheckouts?.isEmpty != false)
        _ = try await client.cancelWorkspaceOperation(commit)
        try await remotePREventually { try await client.workspaceOperation(commit)?.state == .uncertain }
        #expect(try await f.git(["rev-parse", "HEAD"]) == f.base)
        #expect(try f.rows("git-wire.jsonl").filter { $0["kind"].string == "fetch" }.isEmpty)
        try await f.finish(client)
    } catch { await f.failed(client); throw error }
}

@Test(.timeLimit(.minutes(1)))
func remotePRNativeHostCancelsOwnedCheckoutThenInspectsAndAcknowledgesWithoutFetchReplayOrConversationPublication() async throws {
    let f = try await RemotePRFixture.make(existing: true), connections = RemotePRConnections(f)
    let client = RemoteEnvironmentClient(factory: { try connections.make() })
    do {
        _ = try await f.git(["checkout", "main"])
        let target = try await f.register(client)
        let review = try await client.reviewPullRequest(.init(target: target, intent: .checkout(reference: try remotePRReference(), mode: .worktree, submodules: .none, title: nil)))
        guard case .checkout(let captured) = review.value else { throw CoincideError("The native checkout review returned another value type.") }
        try f.change { $0["holdFetch"] = true }
        #expect(try await client.command(remotePRBegin(target, review)).receipt.rejection == nil)
        try await remotePREventually { try f.rows("git-wire.jsonl").contains { $0["kind"].string == "fetch" } }
        #expect(try await client.command(.pullRequest(target: target, action: .cancelCheckout(operationID: review.id))).receipt.rejection == nil)
        try await remotePREventually { try await remotePRCheckout(client, review.id)?.phase == .unconfirmed }
        #expect(try await client.snapshot().workspace.threads.contains { $0.id == captured.targetThreadID } == false)
        _ = try await client.reconnect(); let rebound = try await client.bindPullRequestWorkspace(target)
        #expect(try await client.command(.pullRequest(target: rebound, action: .inspectCheckout(operationID: review.id))).receipt.rejection == nil)
        #expect(try await remotePRCheckout(client, review.id)?.phase == .unconfirmed)
        #expect(try await client.command(.pullRequest(target: rebound, action: .acknowledgeCheckout(operationID: review.id))).receipt.rejection == nil)
        #expect(try await remotePRCheckout(client, review.id)?.acknowledgedAt != nil)
        #expect(try f.rows("git-wire.jsonl").filter { $0["kind"].string == "fetch" }.count == 1)
        #expect(try await f.git(["rev-parse", "HEAD"]) == f.base)
        #expect(try await client.snapshot().workspace.threads.count == 1)
        try await f.finish(client)
    } catch { await f.failed(client); throw error }
}
