import Darwin
import Foundation
import Testing
@testable import CoincideCore

private struct WorktreeFixture: Sendable {
    let root: URL, source: URL, destinations: URL, git: URL
    var environment: [String: String]
    static func make() async throws -> Self {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("coincide-worktree-" + UUID().uuidString).resolvingSymlinksInPath()
        let source = root.appendingPathComponent("Source"), destinations = root.appendingPathComponent("Worktrees"), home = root.appendingPathComponent("Home")
        for url in [source, destinations, home] { try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true) }
        var environment = ProcessInfo.processInfo.environment
        environment["HOME"] = home.path; environment["XDG_CONFIG_HOME"] = home.appendingPathComponent(".config").path
        environment["GIT_CONFIG_NOSYSTEM"] = "1"; environment["GIT_CONFIG_GLOBAL"] = "/dev/null"
        for key in environment.keys where key.hasPrefix("GIT_") && !["GIT_CONFIG_NOSYSTEM", "GIT_CONFIG_GLOBAL"].contains(key) { environment.removeValue(forKey: key) }
        let git = try #require(ProcessChannel.findExecutable("git"))
        let fixture = Self(root: root, source: source, destinations: destinations, git: git, environment: environment)
        do {
            _ = try await fixture.run(["init", "--initial-branch=main"])
            _ = try await fixture.run(["config", "user.name", "Worktree Fixture"])
            _ = try await fixture.run(["config", "user.email", "fixture@example.invalid"])
            _ = try await fixture.run(["config", "commit.gpgsign", "false"])
            try Data("Committed bytes\n".utf8).write(to: source.appendingPathComponent("README.md"))
            _ = try await fixture.run(["add", "--", "README.md"])
            _ = try await fixture.run(["commit", "-m", "Initial fixture"])
            return fixture
        } catch { try? FileManager.default.removeItem(at: root); throw error }
    }
    func run(_ arguments: [String], at: URL? = nil, succeeds: Bool = true) async throws -> CommandResult {
        let result = try await CommandRunner.run(git.path, ["-C", (at ?? source).path] + arguments, environment: environment)
        if succeeds { #expect(result.status == 0, "An isolated Git fixture command failed.") }
        return result
    }
    func request(_ selection: GitWorktreeSelection, source: URL? = nil, submodules: ProjectWorktreeSubmoduleMode = .none) -> GitWorktreeRequest {
        .init(sourcePath: (source ?? self.source).path, destinationRoot: destinations.path, selection: selection, submodules: submodules)
    }
    func service(_ request: GitWorktreeRequest, executable: URL? = nil) -> GitWorktreeService {
        .init(request: request, environment: environment, gitExecutable: executable ?? git)
    }
    func cleanup() { try? FileManager.default.removeItem(at: root) }
    func installHook() throws -> (started: URL, release: URL) {
        let hook = source.appendingPathComponent(".git/hooks/post-checkout")
        try Data("""
        #!/bin/sh
        : > "$COINCIDE_WORKTREE_STARTED"
        trap 'exit 130' TERM INT
        while [ ! -f "$COINCIDE_WORKTREE_RELEASE" ]; do sleep 0.05; done
        """.utf8).write(to: hook)
        #expect(chmod(hook.path, 0o755) == 0)
        return (root.appendingPathComponent("hook-started"), root.appendingPathComponent("hook-release"))
    }
}

private extension WorktreeFixture {
    func nestedSubmodules() async throws -> (inner: URL, nested: URL) {
        let inner = root.appendingPathComponent("Inner origin"), nested = root.appendingPathComponent("Nested origin")
        for (url, file) in [(nested, "NESTED.md"), (inner, "INNER.md")] {
            try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
            _ = try await run(["init", "--initial-branch=main"], at: url)
            _ = try await run(["config", "user.name", "Module Fixture"], at: url)
            _ = try await run(["config", "user.email", "fixture@example.invalid"], at: url)
            _ = try await run(["config", "commit.gpgsign", "false"], at: url)
            try Data(("Committed " + file + "\n").utf8).write(to: url.appendingPathComponent(file))
            _ = try await run(["add", "."], at: url); _ = try await run(["commit", "-m", "Module fixture"], at: url)
        }
        _ = try await run(["-c", "protocol.file.allow=always", "submodule", "add", "--", nested.path, "nested"], at: inner)
        _ = try await run(["commit", "-am", "Nested module"], at: inner)
        _ = try await run(["-c", "protocol.file.allow=always", "submodule", "add", "--", inner.path, "inner"])
        _ = try await run(["commit", "-am", "Top module"])
        _ = try await run(["-c", "protocol.file.allow=always", "submodule", "update", "--init", "--recursive"])
        _ = try await run(["config", "protocol.file.allow", "always"])
        return (source.appendingPathComponent("inner"), source.appendingPathComponent("inner/nested"))
    }
}

@Test func gitWorktreeSubmoduleSelectionLegacyDecodeAndTransportPolicyRemainConservative() throws {
    let request = GitWorktreeRequest(sourcePath: "/fixture/source", destinationRoot: "/fixture/worktrees", selection: .createBranch(name: "feature", baseRef: "HEAD"))
    var json = try #require(JSONSerialization.jsonObject(with: JSONEncoder().encode(request)) as? [String: Any])
    json.removeValue(forKey: "submodules")
    #expect(try JSONDecoder().decode(GitWorktreeRequest.self, from: JSONSerialization.data(withJSONObject: json)).submodules == .none)
    let invalid = GitWorktreeRequest(sourcePath: request.sourcePath, destinationRoot: request.destinationRoot, selection: .reuse(path: request.sourcePath), submodules: .recursive)
    #expect(throws: GitWorktreeError.self) { try invalid.validate() }
    #expect(try GitWorktreeSubmodulePolicy.allowlist(configuration: Data(), inherited: nil) == "http:https:ssh:git")
    let configured = Data("protocol.allow\nnever\0protocol.https.allow\nalways\0protocol.file.allow\nalways\0protocol.ssh.allow\nuser\0".utf8)
    #expect(try GitWorktreeSubmodulePolicy.allowlist(configuration: configured, inherited: nil) == "https:file")
    #expect(try GitWorktreeSubmodulePolicy.allowlist(configuration: configured, inherited: "https:ssh:ext") == "https")
    #expect(try GitWorktreeSubmodulePolicy.allowlist(configuration: configured, inherited: "") == "")
    #expect(throws: GitWorktreeError.self) { try GitWorktreeSubmodulePolicy.allowlist(configuration: Data("protocol.file.allow\nunsupported\0".utf8), inherited: nil) }
    let tampered = GitWorktreeResult(destinationPath: request.destinationPath, headCommit: String(repeating: "a", count: 40), branch: "feature", submoduleWarning: "https://user:synthetic-secret@example.invalid")
    #expect(throws: GitWorktreeError.self) { try tampered.validate() }
}

@Test(.timeLimit(.minutes(1)))
func gitWorktreeSubmoduleModesPopulateOnlyNewCheckoutsAndPreserveDirtySourceModules() async throws {
    let fixture = try await WorktreeFixture.make(); defer { fixture.cleanup() }
    let modules = try await fixture.nestedSubmodules()
    let sourceInner = modules.inner.appendingPathComponent("INNER.md"), sourceNested = modules.nested.appendingPathComponent("NESTED.md")
    try Data("Keep dirty inner bytes\n".utf8).write(to: sourceInner); try Data("Keep dirty nested bytes\n".utf8).write(to: sourceNested)
    let innerHead = try await fixture.run(["rev-parse", "HEAD"], at: modules.inner).output
    let nestedHead = try await fixture.run(["rev-parse", "HEAD"], at: modules.nested).output
    let sentinel = fixture.root.appendingPathComponent("custom-update-must-not-run")
    _ = try await fixture.run(["config", "submodule.inner.update", "!touch '" + sentinel.path + "'"])
    for mode in [ProjectWorktreeSubmoduleMode.none, .topLevel, .recursive] {
        let request = fixture.request(.createBranch(name: "mode-" + mode.rawValue, baseRef: "HEAD"), submodules: mode)
        let service = fixture.service(request), plan = try await service.prepare(), result = try await service.run(plan)
        #expect(result.submoduleWarning == nil)
        #expect(FileManager.default.fileExists(atPath: request.destinationPath + "/inner/INNER.md") == (mode != .none))
        #expect(FileManager.default.fileExists(atPath: request.destinationPath + "/inner/nested/NESTED.md") == (mode == .recursive))
        #expect(try await fixture.service(request).inspectCompletion(plan) == result)
        #expect(try String(contentsOf: sourceInner, encoding: .utf8) == "Keep dirty inner bytes\n")
        #expect(try String(contentsOf: sourceNested, encoding: .utf8) == "Keep dirty nested bytes\n")
        #expect(try await fixture.run(["rev-parse", "HEAD"], at: modules.inner).output == innerHead)
        #expect(try await fixture.run(["rev-parse", "HEAD"], at: modules.nested).output == nestedHead)
        #expect(!FileManager.default.fileExists(atPath: sentinel.path))
    }
}

@Test(.timeLimit(.minutes(1)))
func gitWorktreeSubmoduleFailureRecordsOnlyGenericWarningAndRecoversWithoutNetworkOrHelpers() async throws {
    let fixture = try await WorktreeFixture.make(); defer { fixture.cleanup() }
    let sentinel = fixture.root.appendingPathComponent("ext-helper-must-not-run")
    let config = "[submodule \"unavailable\"]\n path = unavailable\n url = ext::touch " + sentinel.path + "\n"
    try Data(config.utf8).write(to: fixture.source.appendingPathComponent(".gitmodules"))
    _ = try await fixture.run(["add", "--", ".gitmodules"])
    let head = String(decoding: try await fixture.run(["rev-parse", "HEAD"]).output, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
    _ = try await fixture.run(["update-index", "--add", "--cacheinfo", "160000," + head + ",unavailable"])
    _ = try await fixture.run(["commit", "-m", "Unavailable module fixture"])
    let request = fixture.request(.createBranch(name: "module-warning", baseRef: "HEAD"), submodules: .recursive)
    let service = fixture.service(request), plan = try await service.prepare(), result = try await service.run(plan)
    #expect(result.submoduleWarning == GitWorktreeResult.submoduleFailureWarning)
    #expect(FileManager.default.fileExists(atPath: request.destinationPath + "/README.md"))
    #expect(!FileManager.default.fileExists(atPath: sentinel.path))
    #expect(try await fixture.service(request).inspectCompletion(plan) == result)
    #expect(try await fixture.service(request).run(plan) == result)
    let receipt = try Data(contentsOf: fixture.destinations.appendingPathComponent(GitWorktreeCompletion.filename(plan.id)))
    #expect(!String(decoding: receipt, as: UTF8.self).contains("ext::"))
    #expect(!String(decoding: receipt, as: UTF8.self).contains(sentinel.path))
    // A gitlink can exist without a committed URL mapping. Selected initialization
    // must ask Git and report its ordinary failure rather than skip this stage.
    _ = try await fixture.run(["rm", "--", ".gitmodules"])
    _ = try await fixture.run(["commit", "-m", "Missing module URL mapping"])
    _ = try await fixture.run(["config", "--remove-section", "submodule.unavailable"], succeeds: false)
    let missing = fixture.request(.createBranch(name: "missing-module-configuration", baseRef: "HEAD"), submodules: .topLevel)
    let missingService = fixture.service(missing), missingPlan = try await missingService.prepare()
    let missingResult = try await missingService.run(missingPlan)
    #expect(missingResult.submoduleWarning == GitWorktreeResult.submoduleFailureWarning)
    #expect(try await fixture.service(missing).inspectCompletion(missingPlan) == missingResult)
    #expect(!FileManager.default.fileExists(atPath: sentinel.path))
}

@Test(.timeLimit(.minutes(1)))
func gitWorktreeSubmoduleCancellationDrainsItsProcessAndNeverRecordsACompletionReceipt() async throws {
    var fixture = try await WorktreeFixture.make(); defer { fixture.cleanup() }
    _ = try await fixture.nestedSubmodules()
    let request = fixture.request(.createBranch(name: "cancel-module-init", baseRef: "HEAD"), submodules: .recursive)
    let started = fixture.root.appendingPathComponent("submodule-started"), release = fixture.root.appendingPathComponent("submodule-release")
    let partial = URL(fileURLWithPath: request.destinationPath).appendingPathComponent("preserved-partial.txt")
    let wrapper = fixture.root.appendingPathComponent("gated-git")
    try Data("""
    #!/bin/sh
    for arg in "$@"; do
      if [ "$arg" = submodule ]; then
        printf 'Preserve partial module work\\n' > "$COINCIDE_MODULE_PARTIAL"
        : > "$COINCIDE_MODULE_STARTED"
        trap 'exit 130' TERM INT
        while [ ! -f "$COINCIDE_MODULE_RELEASE" ]; do sleep 0.05; done
      fi
    done
    exec "$COINCIDE_REAL_GIT" "$@"
    """.utf8).write(to: wrapper)
    #expect(chmod(wrapper.path, 0o755) == 0)
    fixture.environment["COINCIDE_MODULE_PARTIAL"] = partial.path; fixture.environment["COINCIDE_MODULE_STARTED"] = started.path
    fixture.environment["COINCIDE_MODULE_RELEASE"] = release.path; fixture.environment["COINCIDE_REAL_GIT"] = fixture.git.path
    let service = fixture.service(request, executable: wrapper), plan = try await service.prepare()
    let task = Task { try await service.run(plan) }
    do {
        try await worktreeEventually { FileManager.default.fileExists(atPath: started.path) }
        #expect(try await fixture.service(request).inspectCompletion(plan) == nil)
        task.cancel(); await #expect(throws: CancellationError.self) { try await task.value }
        #expect(try String(contentsOf: partial, encoding: .utf8) == "Preserve partial module work\n")
        #expect(!FileManager.default.fileExists(atPath: fixture.destinations.appendingPathComponent(GitWorktreeCompletion.filename(plan.id)).path))
        #expect(try await fixture.service(request).inspectCompletion(plan) == nil)
        await #expect(throws: GitWorktreeError.self) { try await fixture.service(request).run(plan) }
    } catch { task.cancel(); try? Data().write(to: release); _ = await task.result; throw error }
}

@Test(.timeLimit(.minutes(1)))
func gitWorktreeSubmoduleConfigurationReplacementDuringPolicyReadNeverStartsInitialization() async throws {
    var fixture = try await WorktreeFixture.make(); defer { fixture.cleanup() }
    _ = try await fixture.nestedSubmodules()
    let request = fixture.request(.createBranch(name: "changed-module-configuration", baseRef: "HEAD"), submodules: .recursive)
    let started = fixture.root.appendingPathComponent("policy-started"), release = fixture.root.appendingPathComponent("policy-release")
    let invoked = fixture.root.appendingPathComponent("initialization-must-not-start"), wrapper = fixture.root.appendingPathComponent("policy-gated-git")
    try Data("""
    #!/bin/sh
    for arg in "$@"; do
      if [ "$arg" = --get-regexp ]; then
        : > "$COINCIDE_POLICY_STARTED"
        trap 'exit 130' TERM INT
        while [ ! -f "$COINCIDE_POLICY_RELEASE" ]; do sleep 0.05; done
      fi
      if [ "$arg" = submodule ]; then : > "$COINCIDE_MODULE_INVOKED"; fi
    done
    exec "$COINCIDE_REAL_GIT" "$@"
    """.utf8).write(to: wrapper)
    #expect(chmod(wrapper.path, 0o755) == 0)
    fixture.environment["COINCIDE_POLICY_STARTED"] = started.path; fixture.environment["COINCIDE_POLICY_RELEASE"] = release.path
    fixture.environment["COINCIDE_MODULE_INVOKED"] = invoked.path; fixture.environment["COINCIDE_REAL_GIT"] = fixture.git.path
    let service = fixture.service(request, executable: wrapper), plan = try await service.prepare()
    let task = Task { try await service.run(plan) }
    do {
        try await worktreeEventually { FileManager.default.fileExists(atPath: started.path) }
        let configuration = URL(fileURLWithPath: request.destinationPath).appendingPathComponent(".gitmodules")
        let replacement = Data("[submodule \"foreign\"]\n path = foreign\n url = ext::must-not-execute\n".utf8)
        try replacement.write(to: configuration, options: .atomic)
        try Data().write(to: release)
        do { _ = try await task.value; Issue.record("Changed submodule configuration was used.") }
        catch let error as GitWorktreeError { #expect(error.failure == .ownershipLost) }
        #expect(!FileManager.default.fileExists(atPath: invoked.path))
        #expect(!FileManager.default.fileExists(atPath: fixture.destinations.appendingPathComponent(GitWorktreeCompletion.filename(plan.id)).path))
        #expect(try Data(contentsOf: configuration) == replacement)
        #expect(try await fixture.service(request).inspectCompletion(plan) == nil)
    } catch { task.cancel(); try? Data().write(to: release); _ = await task.result; throw error }
}

private func worktreeEventually(_ condition: @escaping @Sendable () -> Bool) async throws {
    let deadline = ContinuousClock.now + .seconds(8)
    while !condition() {
        guard ContinuousClock.now < deadline else { throw CoincideError("The isolated worktree fixture did not reach its gate.") }
        try await Task.sleep(for: .milliseconds(10))
    }
}

@Test func gitWorktreeRequestValidationRejectsOptionsCredentialsAndMalformedPlansBeforePersistence() async throws {
    let base = GitWorktreeRequest(sourcePath: "/fixture/source", destinationRoot: "/fixture/worktrees", selection: .createBranch(name: "feature/native", baseRef: "refs/heads/main"))
    try base.validate()
    #expect(base.destinationPath == "/fixture/worktrees/" + base.id.uuidString)
    for root in ["/var/folders/fixture/Worktrees", "/private/var/folders/fixture/Worktrees"] {
        let request = GitWorktreeRequest(sourcePath: root + "/Source", destinationRoot: root, selection: .existingBranch(name: "main"))
        try request.validate()
        #expect(request.destinationPath == root + "/" + request.id.uuidString)
        #expect(try JSONDecoder().decode(GitWorktreeRequest.self, from: JSONEncoder().encode(request)) == request)
        let reused = GitWorktreeRequest(sourcePath: request.sourcePath, destinationRoot: root, selection: .reuse(path: root + "/Checkout\nwith newline"))
        try reused.validate()
        #expect(reused.destinationPath == root + "/Checkout\nwith newline")
    }
    for path in ["relative/path", "/", "/fixture/./source", "/fixture/../source", "/fixture//source", "/fixture/source/", "/fixture/\0source"] {
        let request = GitWorktreeRequest(sourcePath: path, destinationRoot: base.destinationRoot, selection: .existingBranch(name: "main"))
        #expect(throws: GitWorktreeError.self) { try request.validate() }
    }
    for ref in ["-bad", "https://user:synthetic-password@example.invalid/repo?token=secret", "user@example.invalid:repo", "ssh://example.invalid/repo", "ext::helper", "HEAD\nother", "bad\0ref"] {
        let request = GitWorktreeRequest(sourcePath: base.sourcePath, destinationRoot: base.destinationRoot, selection: .createBranch(name: "feature/native", baseRef: ref))
        #expect(throws: GitWorktreeError.self) { try request.validate() }
        #expect(throws: (any Error).self) { try JSONDecoder().decode(GitWorktreeRequest.self, from: JSONEncoder().encode(request)) }
    }
    for name in ["-flag", "bad branch", "bad..branch", "bad@{ref}", "bad\nbranch", ".hidden", "bad.lock"] {
        let request = GitWorktreeRequest(sourcePath: base.sourcePath, destinationRoot: base.destinationRoot, selection: .existingBranch(name: name))
        #expect(throws: GitWorktreeError.self) { try request.validate() }
    }
    for value in ["https://example.invalid/local/path", "file://remote.invalid/local/path", "file:///local/path?token=synthetic-secret", "file:///local/path#fragment", "file://user:synthetic-secret@localhost/local/path"] {
        let service = GitWorktreeService(source: try #require(URL(string: value)))
        await #expect(throws: GitWorktreeError.self) { try await service.inventory() }
        await #expect(throws: GitWorktreeError.self) { try await service.prepare(base) }
    }
}

@Test func gitWorktreeInventoryParsesOnlyNULRecordsAndPreservesNewlinePathsAndLockReasons() throws {
    let oid = String(repeating: "a", count: 40)
    let raw = "worktree /fixture/main\0HEAD \(oid)\0branch refs/heads/main\0\0worktree /private/var/fixture/new\nline\0HEAD \(oid)\0branch refs/heads/feature/native\0locked reason\nwith newline\0\0worktree /fixture/gone\0HEAD \(oid)\0detached\0prunable\0\0"
    let inventory = try GitWorktreeService.parseInventory(Data(raw.utf8), sourcePath: "/fixture/main", commonDirectoryPath: "/fixture/main/.git")
    #expect(inventory.worktrees.map(\.path) == ["/fixture/main", "/private/var/fixture/new\nline", "/fixture/gone"])
    #expect(inventory.worktrees[1].lockedReason == "reason\nwith newline" && inventory.worktrees[2].prunableReason == "")
    #expect(inventory.worktrees[2].isDetached && inventory.worktrees[2].branch == nil)
    for invalid in [String(raw.dropLast()), raw + "\0", "worktree /fixture/main\0HEAD \(oid)\0HEAD \(oid)\0branch refs/heads/main\0\0"] {
        #expect(throws: (any Error).self) { try GitWorktreeService.parseInventory(Data(invalid.utf8), sourcePath: "/fixture/main", commonDirectoryPath: "/fixture/main/.git") }
    }
}

@Test(.timeLimit(.minutes(1)))
func gitWorktreeCreatesPinnedCommittedBytesPreservesDirtySourceAndRecoversCompletedReceipt() async throws {
    let fixture = try await WorktreeFixture.make(); defer { fixture.cleanup() }
    try Data("Unsaved source bytes\n".utf8).write(to: fixture.source.appendingPathComponent("README.md"))
    try Data("Keep untracked\n".utf8).write(to: fixture.source.appendingPathComponent("untracked.txt"))
    let request = fixture.request(.createBranch(name: "feature/native", baseRef: "refs/heads/main")), service = fixture.service(request)
    let plan = try await service.prepare()
    #expect(!FileManager.default.fileExists(atPath: plan.destinationPath))
    #expect(try JSONDecoder().decode(GitWorktreePlan.self, from: JSONEncoder().encode(plan)) == plan)
    let result = try await service.run(plan)
    #expect(result.destinationPath == request.destinationPath && result.branch == "feature/native" && result.headCommit == plan.baseCommit)
    #expect(try String(contentsOfFile: plan.destinationPath + "/README.md", encoding: .utf8) == "Committed bytes\n")
    #expect(try String(contentsOf: fixture.source.appendingPathComponent("README.md"), encoding: .utf8) == "Unsaved source bytes\n")
    #expect(try String(contentsOf: fixture.source.appendingPathComponent("untracked.txt"), encoding: .utf8) == "Keep untracked\n")
    let recovered = fixture.service(request)
    #expect(try await recovered.inspectCompletion(plan) == result)
    #expect(try await recovered.run(plan) == result)
    // Pre-submodule receipts omit the new choice entirely. Decoding must preserve
    // their no-network intent rather than infer recursive initialization.
    func legacy(_ value: Any) -> Any {
        if let object = value as? [String: Any] { return object.filter { $0.key != "submodules" && $0.key != "submoduleWarning" }.mapValues(legacy) }
        if let array = value as? [Any] { return array.map(legacy) }
        return value
    }
    for name in [GitWorktreeOwnership.filename(plan.id), GitWorktreeCompletion.filename(plan.id)] {
        let file = fixture.destinations.appendingPathComponent(name)
        let object = try JSONSerialization.jsonObject(with: Data(contentsOf: file))
        try JSONSerialization.data(withJSONObject: legacy(object)).write(to: file)
    }
    #expect(try await fixture.service(request).inspectCompletion(plan) == result)
    #expect(try await fixture.service(request).run(plan) == result)
    let inventory = try await GitWorktreeService(source: fixture.source, environment: fixture.environment, gitExecutable: fixture.git).inventory()
    #expect(inventory.worktrees.contains { $0.path == plan.destinationPath && $0.branch == "feature/native" })
}

@Test(.timeLimit(.minutes(1)))
func gitWorktreeExistingBranchAndExplicitReuseVerifyRegistrationCommonDirectoryAndNewlinePaths() async throws {
    let fixture = try await WorktreeFixture.make(); defer { fixture.cleanup() }
    _ = try await fixture.run(["branch", "existing"])
    let request = fixture.request(.existingBranch(name: "existing")), service = fixture.service(request), plan = try await service.prepare()
    _ = try await service.run(plan)
    do { _ = try await fixture.service(fixture.request(.existingBranch(name: "existing"))).prepare(); Issue.record("An in-use branch was offered as a new checkout.") }
    catch let error as GitWorktreeError { #expect(error.failure == .branchInUse && error.existingWorktree?.path == plan.destinationPath) }
    let newline = fixture.root.appendingPathComponent("Checkout\nwith newline")
    _ = try await fixture.run(["worktree", "add", "-b", "newline", "--", newline.path, "HEAD"])
    let reuse = fixture.request(.reuse(path: newline.path)), reuseService = fixture.service(reuse), reusePlan = try await reuseService.prepare()
    #expect(reusePlan.destinationPath == newline.path && reusePlan.destinationIdentity != nil)
    #expect(try await reuseService.inspectCompletion(reusePlan)?.branch == "newline")
    #expect(try await reuseService.run(reusePlan).destinationPath == newline.path)
    let unrelated = fixture.root.appendingPathComponent("Unregistered")
    try FileManager.default.createDirectory(at: unrelated, withIntermediateDirectories: true)
    await #expect(throws: (any Error).self) { try await fixture.service(fixture.request(.reuse(path: unrelated.path))).prepare() }
}

@Test(.timeLimit(.minutes(1)))
func gitWorktreeDestinationRacesAndParentReplacementNeverOverwriteOrCreateBranches() async throws {
    let fixture = try await WorktreeFixture.make(); defer { fixture.cleanup() }
    let request = fixture.request(.createBranch(name: "collision", baseRef: "HEAD")), service = fixture.service(request), plan = try await service.prepare()
    try FileManager.default.createDirectory(atPath: plan.destinationPath, withIntermediateDirectories: true)
    let sentinel = URL(fileURLWithPath: plan.destinationPath).appendingPathComponent("user.txt")
    try Data("User bytes\n".utf8).write(to: sentinel)
    await #expect(throws: GitWorktreeError.self) { try await service.run(plan) }
    #expect(try String(contentsOf: sentinel, encoding: .utf8) == "User bytes\n")
    #expect(try await fixture.run(["show-ref", "--verify", "--quiet", "refs/heads/collision"], succeeds: false).status != 0)
    let second = fixture.request(.createBranch(name: "parent-race", baseRef: "HEAD")), secondService = fixture.service(second), secondPlan = try await secondService.prepare()
    let moved = fixture.root.appendingPathComponent("Moved Worktrees")
    try FileManager.default.moveItem(at: fixture.destinations, to: moved)
    try FileManager.default.createDirectory(at: fixture.destinations, withIntermediateDirectories: true)
    await #expect(throws: GitWorktreeError.self) { try await secondService.run(secondPlan) }
    #expect(try String(contentsOf: moved.appendingPathComponent(request.id.uuidString + "/user.txt"), encoding: .utf8) == "User bytes\n")
    #expect(!FileManager.default.fileExists(atPath: secondPlan.destinationPath))
}

@Test(.timeLimit(.minutes(1)))
func gitWorktreeCompletionRequiresPostExitReceiptAndExactPinnedHead() async throws {
    let fixture = try await WorktreeFixture.make(); defer { fixture.cleanup() }
    let request = fixture.request(.createBranch(name: "receipt", baseRef: "HEAD")), service = fixture.service(request), plan = try await service.prepare()
    _ = try await service.run(plan)
    let receipt = fixture.destinations.appendingPathComponent(GitWorktreeCompletion.filename(plan.id))
    try FileManager.default.removeItem(at: receipt)
    #expect(try await fixture.service(request).inspectCompletion(plan) == nil)
    await #expect(throws: GitWorktreeError.self) { try await fixture.service(request).run(plan) }
    let reuse = fixture.request(.reuse(path: plan.destinationPath)), reuseService = fixture.service(reuse), reusePlan = try await reuseService.prepare()
    #expect(try await reuseService.run(reusePlan).headCommit == plan.baseCommit)
    let checkout = URL(fileURLWithPath: plan.destinationPath)
    try Data("Later committed bytes\n".utf8).write(to: checkout.appendingPathComponent("README.md"))
    _ = try await fixture.run(["add", "--", "README.md"], at: checkout)
    _ = try await fixture.run(["commit", "-m", "Later fixture"], at: checkout)
    #expect(try await reuseService.inspectCompletion(reusePlan) == nil)
    await #expect(throws: GitWorktreeError.self) { try await reuseService.run(reusePlan) }
    #expect(try String(contentsOf: checkout.appendingPathComponent("README.md"), encoding: .utf8) == "Later committed bytes\n")
}

@Test(.timeLimit(.minutes(1)))
func gitWorktreeRunningPostCheckoutHookCannotProduceCompletionUntilOwnedGitExits() async throws {
    var fixture = try await WorktreeFixture.make(); defer { fixture.cleanup() }
    let gate = try fixture.installHook()
    fixture.environment["COINCIDE_WORKTREE_STARTED"] = gate.started.path; fixture.environment["COINCIDE_WORKTREE_RELEASE"] = gate.release.path
    let request = fixture.request(.createBranch(name: "held", baseRef: "HEAD")), service = fixture.service(request), plan = try await service.prepare()
    let running = Task { try await service.run(plan) }
    do {
        try await worktreeEventually { FileManager.default.fileExists(atPath: gate.started.path) }
        #expect(try await fixture.service(request).inspectCompletion(plan) == nil)
        try Data().write(to: gate.release)
        let result = try await running.value
        #expect(try await fixture.service(request).inspectCompletion(plan) == result)
    } catch { running.cancel(); try? Data().write(to: gate.release); _ = await running.result; throw error }
}

@Test(.timeLimit(.minutes(1)))
func gitWorktreeCancellationDrainsOwnedGitAndPreservesPartialAttemptsForNewDestinationRetry() async throws {
    var fixture = try await WorktreeFixture.make(); defer { fixture.cleanup() }
    let gate = try fixture.installHook()
    fixture.environment["COINCIDE_WORKTREE_STARTED"] = gate.started.path; fixture.environment["COINCIDE_WORKTREE_RELEASE"] = gate.release.path
    let request = fixture.request(.createBranch(name: "cancelled", baseRef: "HEAD")), service = fixture.service(request), plan = try await service.prepare()
    let running = Task { try await service.run(plan) }
    do {
        try await worktreeEventually { FileManager.default.fileExists(atPath: gate.started.path) }
        running.cancel()
        await #expect(throws: CancellationError.self) { try await running.value }
        #expect(try await fixture.service(request).inspectCompletion(plan) == nil)
        try FileManager.default.createDirectory(atPath: plan.destinationPath, withIntermediateDirectories: true)
        let sentinel = URL(fileURLWithPath: plan.destinationPath).appendingPathComponent("preserved.txt")
        try Data("Preserved attempt\n".utf8).write(to: sentinel)
        await #expect(throws: GitWorktreeError.self) { try await fixture.service(request).run(plan) }
        #expect(try String(contentsOf: sentinel, encoding: .utf8) == "Preserved attempt\n")
        try Data().write(to: gate.release)
        let retry = fixture.request(.createBranch(name: "retry", baseRef: "HEAD")), retryService = fixture.service(retry), retryPlan = try await retryService.prepare()
        #expect(retryPlan.destinationPath != plan.destinationPath)
        _ = try await retryService.run(retryPlan)
        #expect(try String(contentsOf: sentinel, encoding: .utf8) == "Preserved attempt\n")
    } catch { running.cancel(); try? Data().write(to: gate.release); _ = await running.result; throw error }
}

@Test(.timeLimit(.minutes(1)))
func gitWorktreeLinkedSourcePointerRedirectionAfterDiscoveryCannotMutateEitherRepository() async throws {
    var fixture = try await WorktreeFixture.make(); defer { fixture.cleanup() }
    let linked = fixture.root.appendingPathComponent("Linked Source"), foreign = fixture.root.appendingPathComponent("Foreign")
    _ = try await fixture.run(["worktree", "add", "-b", "linked-source", "--", linked.path, "HEAD"])
    try FileManager.default.createDirectory(at: foreign, withIntermediateDirectories: true)
    _ = try await fixture.run(["init", "--initial-branch=foreign"], at: foreign)
    for (key, value) in [("user.name", "Foreign Fixture"), ("user.email", "foreign@example.invalid"), ("commit.gpgsign", "false")] { _ = try await fixture.run(["config", key, value], at: foreign) }
    try Data("Foreign repository\n".utf8).write(to: foreign.appendingPathComponent("README.md"))
    _ = try await fixture.run(["add", "--", "README.md"], at: foreign)
    _ = try await fixture.run(["commit", "-m", "Foreign fixture"], at: foreign)
    let arm = fixture.root.appendingPathComponent("arm"), started = fixture.root.appendingPathComponent("list-started"), release = fixture.root.appendingPathComponent("list-release")
    let wrapper = fixture.root.appendingPathComponent("fixture-git")
    try Data("""
    #!/bin/sh
    for argument in "$@"; do
      if [ "$argument" = list ] && [ -f "$COINCIDE_WORKTREE_ARM" ] && [ ! -f "$COINCIDE_WORKTREE_LIST_STARTED" ]; then
        : > "$COINCIDE_WORKTREE_LIST_STARTED"
        while [ ! -f "$COINCIDE_WORKTREE_LIST_RELEASE" ]; do sleep 0.05; done
      fi
    done
    exec "$COINCIDE_WORKTREE_REAL_GIT" "$@"
    """.utf8).write(to: wrapper)
    #expect(chmod(wrapper.path, 0o755) == 0)
    fixture.environment["COINCIDE_WORKTREE_ARM"] = arm.path; fixture.environment["COINCIDE_WORKTREE_LIST_STARTED"] = started.path
    fixture.environment["COINCIDE_WORKTREE_LIST_RELEASE"] = release.path; fixture.environment["COINCIDE_WORKTREE_REAL_GIT"] = fixture.git.path
    let request = fixture.request(.createBranch(name: "redirected", baseRef: "HEAD"), source: linked), service = fixture.service(request, executable: wrapper)
    let plan = try await service.prepare(), pointer = linked.appendingPathComponent(".git"), original = try Data(contentsOf: pointer)
    #expect(plan.sourceGitDirectoryPath != plan.commonDirectoryPath)
    try Data().write(to: arm)
    let running = Task { try await service.run(plan) }
    do {
        try await worktreeEventually { FileManager.default.fileExists(atPath: started.path) }
        try Data(("gitdir: " + foreign.appendingPathComponent(".git").path + "\n").utf8).write(to: pointer)
        try Data().write(to: release)
        await #expect(throws: GitWorktreeError.self) { try await running.value }
        try original.write(to: pointer)
        #expect(try await fixture.run(["show-ref", "--verify", "--quiet", "refs/heads/redirected"], succeeds: false).status != 0)
        #expect(try await fixture.run(["show-ref", "--verify", "--quiet", "refs/heads/redirected"], at: foreign, succeeds: false).status != 0)
        #expect(!FileManager.default.fileExists(atPath: plan.destinationPath))
        #expect(try String(contentsOf: foreign.appendingPathComponent("README.md"), encoding: .utf8) == "Foreign repository\n")
        #expect(try String(contentsOf: fixture.source.appendingPathComponent("README.md"), encoding: .utf8) == "Committed bytes\n")
    } catch { running.cancel(); try? Data().write(to: release); _ = await running.result; try? original.write(to: pointer); throw error }
}

@Test(.timeLimit(.minutes(1)))
func gitWorktreeCompletionRejectsReplacedCheckoutWithoutTouchingOriginalOrForeignReplacement() async throws {
    let fixture = try await WorktreeFixture.make(); defer { fixture.cleanup() }
    let request = fixture.request(.createBranch(name: "replacement", baseRef: "HEAD")), service = fixture.service(request), plan = try await service.prepare()
    _ = try await service.run(plan)
    let destination = URL(fileURLWithPath: plan.destinationPath), moved = fixture.root.appendingPathComponent("Moved Checkout")
    try FileManager.default.moveItem(at: destination, to: moved)
    try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: true)
    try Data("Foreign replacement\n".utf8).write(to: destination.appendingPathComponent("user.txt"))
    await #expect(throws: GitWorktreeError.self) { try await fixture.service(request).inspectCompletion(plan) }
    await #expect(throws: GitWorktreeError.self) { try await fixture.service(request).run(plan) }
    #expect(try String(contentsOf: moved.appendingPathComponent("README.md"), encoding: .utf8) == "Committed bytes\n")
    #expect(try String(contentsOf: destination.appendingPathComponent("user.txt"), encoding: .utf8) == "Foreign replacement\n")
}

@Test(.timeLimit(.minutes(1)))
func gitWorktreeOwnershipMetadataPipesAreRejectedWithoutWaitingOrReplacingThem() async throws {
    let fixture = try await WorktreeFixture.make(); defer { fixture.cleanup() }
    let request = fixture.request(.createBranch(name: "metadata-pipe", baseRef: "HEAD")), service = fixture.service(request), plan = try await service.prepare()
    let owner = fixture.destinations.appendingPathComponent(GitWorktreeOwnership.filename(plan.id))
    #expect(mkfifo(owner.path, 0o600) == 0)
    await #expect(throws: GitWorktreeError.self) { try await service.inspectCompletion(plan) }
    await #expect(throws: GitWorktreeError.self) { try await service.run(plan) }
    var value = stat(); #expect(lstat(owner.path, &value) == 0 && value.st_mode & S_IFMT == S_IFIFO)
    #expect(!FileManager.default.fileExists(atPath: plan.destinationPath))
    #expect(try await fixture.run(["show-ref", "--verify", "--quiet", "refs/heads/metadata-pipe"], succeeds: false).status != 0)
}
