import Darwin
import Foundation
import Testing
@testable import CoincideCore

private struct CheckpointFile: Sendable, Equatable {
    let bytes: Data
    let mode: UInt16
    let link: String?
}

private struct CheckpointUserState: Sendable, Equatable {
    let indexFiles: [String: Data]
    let head: Data
    let branches: Data
    let staged: Data
    let flags: Data
    let files: [String: CheckpointFile]
}

private struct CheckpointFixture: Sendable {
    let root: URL
    let repository: URL
    let git: URL
    var environment: [String: String]

    static func make(initialCommit: Bool = true) async throws -> Self {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("coincide-checkpoint-" + UUID().uuidString).resolvingSymlinksInPath()
        let repository = root.appendingPathComponent("Repository"), home = root.appendingPathComponent("Home")
        for directory in [repository, home, root.appendingPathComponent("No hooks")] {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        }
        var environment = ProcessInfo.processInfo.environment
        for key in environment.keys where key.hasPrefix("GIT_") { environment.removeValue(forKey: key) }
        environment["HOME"] = home.path
        environment["XDG_CONFIG_HOME"] = home.appendingPathComponent(".config").path
        environment["GIT_CONFIG_NOSYSTEM"] = "1"
        environment["GIT_CONFIG_GLOBAL"] = "/dev/null"
        // Reading status or index entries must not refresh the user's index in the fixture.
        environment["GIT_OPTIONAL_LOCKS"] = "0"
        let git = try #require(ProcessChannel.findExecutable("git"))
        let fixture = Self(root: root, repository: repository, git: git, environment: environment)
        do {
            _ = try await fixture.run(["init", "--initial-branch=main"])
            for (key, value) in [("user.name", "Checkpoint Fixture"), ("user.email", "fixture@example.invalid"),
                                 ("commit.gpgsign", "false"), ("tag.gpgsign", "false"), ("core.hooksPath", root.appendingPathComponent("No hooks").path)] {
                _ = try await fixture.run(["config", key, value])
            }
            if initialCommit {
                try fixture.write("tracked.txt", "Committed bytes\n")
                _ = try await fixture.run(["add", "--", "tracked.txt"])
                _ = try await fixture.run(["commit", "-m", "Initial fixture"])
            }
            return fixture
        } catch {
            try? FileManager.default.removeItem(at: root)
            throw error
        }
    }

    func run(_ arguments: [String], at directory: URL? = nil, succeeds: Bool = true, input: Data? = nil) async throws -> CommandResult {
        let result = try await CommandRunner.run(git.path, ["--no-pager", "--no-optional-locks", "--literal-pathspecs", "-C", (directory ?? repository).path] + arguments,
                                                 input: input, environment: environment)
        if succeeds, result.status != 0 { throw CoincideError("An isolated checkpoint fixture command failed.") }
        return result
    }

    func service(at directory: URL? = nil, executable: URL? = nil) -> GitCheckpointService {
        .init(root: directory ?? repository, environment: environment, gitExecutable: executable ?? git)
    }

    func write(_ path: String, _ text: String) throws {
        let file = repository.appendingPathComponent(path)
        try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(text.utf8).write(to: file)
    }

    func commitAll() async throws {
        _ = try await run(["add", "--all"])
        _ = try await run(["commit", "-m", "Checkpoint fixture state"])
    }

    func admin(at directory: URL? = nil) async throws -> URL {
        let text = try await run(["rev-parse", "--absolute-git-dir"], at: directory).text
        return URL(fileURLWithPath: String(text.dropLast(text.hasSuffix("\n") ? 1 : 0)))
    }

    func state(at directory: URL? = nil) async throws -> CheckpointUserState {
        let checkout = directory ?? repository, admin = try await admin(at: checkout)
        var indexes: [String: Data] = [:]
        for file in try FileManager.default.contentsOfDirectory(at: admin, includingPropertiesForKeys: nil)
            where file.lastPathComponent == "index" || file.lastPathComponent.hasPrefix("sharedindex.") {
            indexes[file.lastPathComponent] = try Data(contentsOf: file)
        }
        return .init(indexFiles: indexes, head: try Data(contentsOf: admin.appendingPathComponent("HEAD")),
                     branches: try await run(["for-each-ref", "--format=%(refname) %(objectname)", "refs/heads/"], at: checkout).output,
                     staged: try await run(["ls-files", "--stage", "-z"], at: checkout).output,
                     flags: try await run(["ls-files", "-v", "-z"], at: checkout).output,
                     files: try files(below: checkout))
    }

    func files(below directory: URL) throws -> [String: CheckpointFile] {
        var result: [String: CheckpointFile] = [:]
        func visit(_ folder: URL, prefix: String) throws {
            for file in try FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil) where file.lastPathComponent != ".git" {
                let path = prefix + file.lastPathComponent
                var info = stat()
                guard lstat(file.path, &info) == 0 else { throw CoincideError("An isolated checkpoint fixture file disappeared.") }
                let kind = info.st_mode & mode_t(S_IFMT)
                if kind == mode_t(S_IFDIR) { try visit(file, prefix: path + "/") }
                else if kind == mode_t(S_IFLNK) {
                    result[path] = .init(bytes: Data(), mode: UInt16(info.st_mode & 0o777), link: try FileManager.default.destinationOfSymbolicLink(atPath: file.path))
                } else {
                    result[path] = .init(bytes: try Data(contentsOf: file), mode: UInt16(info.st_mode & 0o777), link: nil)
                }
            }
        }
        try visit(directory, prefix: "")
        return result
    }

    func blob(_ receipt: GitCheckpointReceipt, _ path: String) async throws -> Data {
        try await run(["show", receipt.commit + ":" + path]).output
    }

    func paths(_ receipt: GitCheckpointReceipt) async throws -> Set<String> {
        Set(try await run(["ls-tree", "--name-only", "-r", "-z", receipt.tree]).output.split(separator: 0).map { String(decoding: $0, as: UTF8.self) })
    }

    func attempt(_ plan: GitCheckpointPlan) -> URL {
        URL(fileURLWithPath: plan.commonDirectoryPath).appendingPathComponent(".coincide-checkpoint-" + plan.id.uuidString)
    }

    func cleanup() { try? FileManager.default.removeItem(at: root) }
}

private func checkpointExpectError(_ expected: GitCheckpointError.Kind, _ body: () async throws -> Void) async throws {
    do { try await body(); Issue.record("An invalid checkpoint operation unexpectedly succeeded.") }
    catch let error as GitCheckpointError { #expect(error.kind == expected) }
}

private func checkpointEventually(_ predicate: @escaping @Sendable () -> Bool) async throws {
    let deadline = ContinuousClock.now + .seconds(8)
    while !predicate() {
        guard ContinuousClock.now < deadline else { throw CoincideError("The isolated checkpoint fixture did not reach its gate.") }
        try await Task.sleep(for: .milliseconds(10))
    }
}

@Test func gitCheckpointModelsRejectMalformedPersistedOwnershipAndNeverStoreConfigurationValues() throws {
    let identity = GitWorktreeNodeIdentity(device: 1, inode: 2)
    let plan = try GitCheckpointPlan(workspacePath: "/fixture/repository/Project", repositoryPath: "/fixture/repository",
        gitDirectoryPath: "/fixture/repository/.git", commonDirectoryPath: "/fixture/repository/.git", workspaceIdentity: identity,
        repositoryIdentity: identity, gitDirectoryIdentity: identity, commonDirectoryIdentity: identity, objectDirectoryIdentity: identity,
        headCommit: String(repeating: "a", count: 40),
        configurationDigest: String(repeating: "b", count: 64), indexRevision: nil)
    #expect(plan.reference == "refs/coincide/checkpoints/" + plan.id.uuidString.lowercased())
    #expect(try JSONDecoder().decode(GitCheckpointPlan.self, from: JSONEncoder().encode(plan)) == plan)
    let original = try #require(JSONSerialization.jsonObject(with: JSONEncoder().encode(plan)) as? [String: Any])
    for (key, value) in [("workspacePath", "/other/project"), ("repositoryPath", "relative"), ("gitDirectoryPath", "/foreign/admin"),
                         ("objectFormat", "md5"), ("headCommit", "HEAD"), ("configurationDigest", "https://user:synthetic-secret@example.invalid")] {
        var changed = original
        changed[key] = value
        #expect(throws: GitCheckpointError.self) { try JSONDecoder().decode(GitCheckpointPlan.self, from: JSONSerialization.data(withJSONObject: changed)) }
    }
    for invalid in [GitCheckpointIndexRevision(identity: identity, byteLength: -1, modifiedSeconds: 0, modifiedNanoseconds: 0, digest: String(repeating: "c", count: 64)),
                    GitCheckpointIndexRevision(identity: identity, byteLength: 1, modifiedSeconds: 0, modifiedNanoseconds: 1_000_000_000, digest: String(repeating: "c", count: 64)),
                    GitCheckpointIndexRevision(identity: identity, byteLength: 1, modifiedSeconds: 0, modifiedNanoseconds: 0, digest: "invalid")] {
        var changed = original
        changed["indexRevision"] = try JSONSerialization.jsonObject(with: JSONEncoder().encode(invalid))
        #expect(throws: GitCheckpointError.self) { try JSONDecoder().decode(GitCheckpointPlan.self, from: JSONSerialization.data(withJSONObject: changed)) }
    }
    #expect(throws: GitCheckpointError.self) { try GitCheckpointReceipt(plan: plan, commit: "HEAD", tree: String(repeating: "c", count: 40)) }
}

@Test(.timeLimit(.minutes(1)))
func gitCheckpointCapturesDirtyStagedAndUntrackedBytesWithoutChangingUserState() async throws {
    let fixture = try await CheckpointFixture.make(); defer { fixture.cleanup() }
    try fixture.write("deleted.txt", "Delete this tracked file\n")
    try fixture.write(".gitignore", "ignored.txt\n")
    try await fixture.commitAll()
    try fixture.write("tracked.txt", "Staged bytes\n")
    _ = try await fixture.run(["add", "--", "tracked.txt"])
    try fixture.write("tracked.txt", "Working bytes after staging\n")
    try FileManager.default.removeItem(at: fixture.repository.appendingPathComponent("deleted.txt"))
    try fixture.write("untracked.txt", "Untracked bytes\n")
    try fixture.write("ignored.txt", "Ignored private fixture bytes\n")
    let before = try await fixture.state(), service = fixture.service(), plan = try await service.prepare()
    #expect(try await fixture.state() == before)
    #expect(try await service.inspect(plan) == .missing)
    #expect(!FileManager.default.fileExists(atPath: fixture.attempt(plan).path))
    #expect(!FileManager.default.fileExists(atPath: URL(fileURLWithPath: plan.gitDirectoryPath).appendingPathComponent(".coincide-checkpoint-" + plan.id.uuidString + ".index").path))
    let receipt = try await service.capture(plan)
    #expect(try await fixture.blob(receipt, "tracked.txt") == Data("Working bytes after staging\n".utf8))
    #expect(try await fixture.blob(receipt, "untracked.txt") == Data("Untracked bytes\n".utf8))
    let paths = try await fixture.paths(receipt)
    #expect(!paths.contains("deleted.txt"))
    #expect(!paths.contains("ignored.txt"))
    #expect(try await service.inspect(plan) == .ready(receipt))
    #expect(try await fixture.service().capture(plan) == receipt)
    #expect(try await fixture.state() == before)
    #expect(!FileManager.default.fileExists(atPath: fixture.repository.appendingPathComponent(".git/index.lock").path))
}

@Test(.timeLimit(.minutes(1)), arguments: [false, true])
func gitCheckpointCapturesUnbornRepositoryWithOrWithoutARealIndex(stage: Bool) async throws {
    let fixture = try await CheckpointFixture.make(initialCommit: false); defer { fixture.cleanup() }
    try fixture.write("new.txt", "Initial staged bytes\n")
    if stage { _ = try await fixture.run(["add", "--", "new.txt"]) }
    try fixture.write("new.txt", "Current unborn bytes\n")
    let before = try await fixture.state(), service = fixture.service(), plan = try await service.prepare()
    #expect(plan.headCommit == nil)
    #expect((plan.indexRevision != nil) == stage)
    let receipt = try await service.capture(plan)
    #expect(try await fixture.blob(receipt, "new.txt") == Data("Current unborn bytes\n".utf8))
    #expect(try await fixture.run(["rev-parse", "--verify", "HEAD"], succeeds: false).status != 0)
    #expect(try await fixture.state() == before)
    #expect(try await service.inspect(plan) == .ready(receipt))
}

@Test(.timeLimit(.minutes(1)))
func gitCheckpointPreservesExecutableSymlinkAndLiteralNewlineFilenames() async throws {
    let fixture = try await CheckpointFixture.make(); defer { fixture.cleanup() }
    let newline = "line\nbreak.txt", literal = ":(glob)**.txt"
    try fixture.write("run.sh", "#!/bin/sh\nprintf original\n")
    #expect(chmod(fixture.repository.appendingPathComponent("run.sh").path, 0o755) == 0)
    try fixture.write(newline, "Newline filename bytes\n")
    try fixture.write(literal, "Literal pathspec-looking filename\n")
    try FileManager.default.createSymbolicLink(atPath: fixture.repository.appendingPathComponent("link").path, withDestinationPath: newline)
    try await fixture.commitAll()
    try fixture.write("run.sh", "#!/bin/sh\nprintf changed\n")
    let before = try await fixture.state(), service = fixture.service(), receipt = try await service.capture(service.prepare())
    #expect(try await fixture.paths(receipt).isSuperset(of: ["run.sh", "link", newline, literal]))
    #expect(try await fixture.blob(receipt, "link") == Data(newline.utf8))
    #expect(try await fixture.blob(receipt, literal) == Data("Literal pathspec-looking filename\n".utf8))
    #expect(try await fixture.run(["ls-tree", receipt.tree, "--", "run.sh"]).text.hasPrefix("100755 blob "))
    #expect(try await fixture.run(["ls-tree", receipt.tree, "--", "link"]).text.hasPrefix("120000 blob "))
    #expect(try await fixture.state() == before)
}

@Test(.timeLimit(.minutes(1)))
func gitCheckpointSubdirectoryCaptureDoesNotIncludeOtherProjectsWorkingChanges() async throws {
    let fixture = try await CheckpointFixture.make(); defer { fixture.cleanup() }
    try fixture.write("Project/in.txt", "Committed inside\n")
    try fixture.write("Other/out.txt", "Committed outside\n")
    try await fixture.commitAll()
    try fixture.write("Project/in.txt", "Current inside\n")
    try fixture.write("Project/new.txt", "New inside\n")
    try fixture.write("Other/out.txt", "Keep outside staged bytes\n")
    _ = try await fixture.run(["add", "--", "Other/out.txt"])
    try fixture.write("Other/out.txt", "Keep outside working bytes\n")
    try fixture.write("Other/new.txt", "Keep outside untracked bytes\n")
    let before = try await fixture.state(), service = fixture.service(at: fixture.repository.appendingPathComponent("Project"))
    let receipt = try await service.capture(service.prepare())
    #expect(receipt.plan.workspacePath == fixture.repository.appendingPathComponent("Project").path)
    #expect(try await fixture.blob(receipt, "Project/in.txt") == Data("Current inside\n".utf8))
    #expect(try await fixture.blob(receipt, "Project/new.txt") == Data("New inside\n".utf8))
    #expect(try await fixture.blob(receipt, "Other/out.txt") == Data("Committed outside\n".utf8))
    let paths = try await fixture.paths(receipt)
    #expect(!paths.contains("Other/new.txt"))
    #expect(try await fixture.state() == before)
}

@Test(.timeLimit(.minutes(1)))
func gitCheckpointIgnoresLocalReplaceRefsForPinnedTreesInspectionAndDiff() async throws {
    let fixture = try await CheckpointFixture.make(); defer { fixture.cleanup() }
    try fixture.write("Project/in.txt", "Original project bytes\n")
    try fixture.write("Outside/out.txt", "Original outside bytes\n")
    try await fixture.commitAll()
    let original = try await fixture.run(["rev-parse", "HEAD"]).text.trimmingCharacters(in: .whitespacesAndNewlines)
    try fixture.write("Outside/out.txt", "Replacement outside bytes\n")
    try fixture.write("Outside/ghost.txt", "Replacement-only ghost\n")
    try await fixture.commitAll()
    let replacement = try await fixture.run(["rev-parse", "HEAD"]).text.trimmingCharacters(in: .whitespacesAndNewlines)
    _ = try await fixture.run(["reset", "--hard", original])
    _ = try await fixture.run(["replace", original, replacement])
    // Prove this fixture really changes ordinary Git's view of the pinned commit.
    #expect(try await fixture.run(["show", original + ":Outside/out.txt"]).output == Data("Replacement outside bytes\n".utf8))
    let before = try await fixture.state(), service = fixture.service(at: fixture.repository.appendingPathComponent("Project"))
    let first = try await service.capture(service.prepare())
    #expect(first.plan.headCommit == original)
    #expect(try await fixture.blob(first, "Outside/out.txt") == Data("Original outside bytes\n".utf8))
    let firstPaths = try await fixture.paths(first)
    #expect(!firstPaths.contains("Outside/ghost.txt"))
    #expect(try await fixture.state() == before)
    try fixture.write("Project/in.txt", "Changed project bytes\n")
    let second = try await service.capture(service.prepare())
    _ = try await fixture.run(["replace", first.commit, second.commit])
    let afterReplacement = try await fixture.state()
    #expect(try await service.inspect(first.plan) == .ready(first))
    #expect(try await service.inspect(second.plan) == .ready(second))
    let diff = try await service.diff(from: first, to: second, paths: ["in.txt"])
    #expect(diff.patch.contains("Original project bytes"))
    #expect(diff.patch.contains("Changed project bytes"))
    #expect(try await fixture.run(["rev-parse", "refs/replace/" + original]).text == replacement + "\n")
    #expect(try await fixture.run(["rev-parse", "refs/replace/" + first.commit]).text == second.commit + "\n")
    #expect(try await fixture.state() == afterReplacement)
}

@Test(.timeLimit(.minutes(1)))
func gitCheckpointPrivateIndexHandlesSplitIndexAndManualFlagsWithoutChangingTheRealIndex() async throws {
    let fixture = try await CheckpointFixture.make(); defer { fixture.cleanup() }
    try fixture.write("assumed.txt", "Original assumed bytes\n")
    try fixture.write("skipped.txt", "Original manually skipped bytes\n")
    try await fixture.commitAll()
    _ = try await fixture.run(["update-index", "--split-index"])
    _ = try await fixture.run(["update-index", "--assume-unchanged", "--", "assumed.txt"])
    _ = try await fixture.run(["update-index", "--skip-worktree", "--", "skipped.txt"])
    try fixture.write("assumed.txt", "Current assumed bytes\n")
    try fixture.write("skipped.txt", "Current manually skipped bytes\n")
    let before = try await fixture.state(), service = fixture.service(), receipt = try await service.capture(service.prepare())
    #expect(before.indexFiles.keys.contains(where: { $0.hasPrefix("sharedindex.") }))
    #expect(try await fixture.blob(receipt, "assumed.txt") == Data("Current assumed bytes\n".utf8))
    #expect(try await fixture.blob(receipt, "skipped.txt") == Data("Current manually skipped bytes\n".utf8))
    #expect(try await fixture.state() == before)
}

@Test(.timeLimit(.minutes(1)), arguments: [false, true])
func gitCheckpointConeSparseIndexKeepsExcludedTrackedFilesAndCapturesIncludedChanges(sparseIndex: Bool) async throws {
    let fixture = try await CheckpointFixture.make(); defer { fixture.cleanup() }
    try fixture.write("Included/file.txt", "Original included\n")
    try fixture.write("Included/assumed.txt", "Original assumed included\n")
    try fixture.write("Included/manual-missing.txt", "Original manually skipped included\n")
    try fixture.write("Excluded/file.txt", "Original excluded\n")
    try await fixture.commitAll()
    _ = try await fixture.run(["sparse-checkout", "init", "--cone", sparseIndex ? "--sparse-index" : "--no-sparse-index"])
    _ = try await fixture.run(["sparse-checkout", "set", "Included"])
    #expect(!FileManager.default.fileExists(atPath: fixture.repository.appendingPathComponent("Excluded/file.txt").path))
    _ = try await fixture.run(["update-index", "--assume-unchanged", "--", "Included/assumed.txt"])
    _ = try await fixture.run(["update-index", "--skip-worktree", "--", "Included/manual-missing.txt"])
    try fixture.write("Included/file.txt", "Current included\n")
    try fixture.write("Included/assumed.txt", "Current assumed included\n")
    try FileManager.default.removeItem(at: fixture.repository.appendingPathComponent("Included/manual-missing.txt"))
    let before = try await fixture.state(), service = fixture.service(), receipt = try await service.capture(service.prepare())
    #expect(try await fixture.blob(receipt, "Included/file.txt") == Data("Current included\n".utf8))
    #expect(try await fixture.blob(receipt, "Included/assumed.txt") == Data("Current assumed included\n".utf8))
    #expect(try await fixture.blob(receipt, "Excluded/file.txt") == Data("Original excluded\n".utf8))
    let paths = try await fixture.paths(receipt)
    #expect(!paths.contains("Included/manual-missing.txt"))
    #expect(try await fixture.state() == before)
}

@Test(.timeLimit(.minutes(1)))
func gitCheckpointNonconeSparseLayoutFailsVisiblyAndPreservesFilesAndStaging() async throws {
    let fixture = try await CheckpointFixture.make(); defer { fixture.cleanup() }
    try fixture.write("Included/file.txt", "Included bytes\n")
    try fixture.write("Excluded/file.txt", "Excluded bytes\n")
    try await fixture.commitAll()
    _ = try await fixture.run(["sparse-checkout", "init", "--no-cone"])
    _ = try await fixture.run(["sparse-checkout", "set", "--no-cone", "/Included/"])
    let before = try await fixture.state()
    try await checkpointExpectError(.unsupportedConfiguration) { _ = try await fixture.service().prepare() }
    #expect(try await fixture.state() == before)
}

@Test(.timeLimit(.minutes(1)), arguments: ["clean", "process"])
func gitCheckpointNeverExecutesConfiguredCleanOrProcessFilters(kind: String) async throws {
    let fixture = try await CheckpointFixture.make(); defer { fixture.cleanup() }
    let sentinel = fixture.root.appendingPathComponent("filter-must-not-run")
    try fixture.write(".gitattributes", "*.txt filter=fixture\n")
    _ = try await fixture.run(["config", "filter.fixture." + kind, "touch '" + sentinel.path + "'"])
    let before = try await fixture.state()
    try await checkpointExpectError(.unsupportedConfiguration) { _ = try await fixture.service().prepare() }
    var inherited = fixture
    inherited.environment["GIT_CONFIG"] = "/dev/null"
    try await checkpointExpectError(.unsupportedConfiguration) { _ = try await inherited.service().prepare() }
    #expect(!FileManager.default.fileExists(atPath: sentinel.path))
    #expect(try await fixture.state() == before)
}

@Test(.timeLimit(.minutes(1)), arguments: ["clean", "process"])
func gitCheckpointAddUsesFrozenConfigurationWhenRealFiltersChangeDuringCapture(kind: String) async throws {
    var fixture = try await CheckpointFixture.make(); defer { fixture.cleanup() }
    let started = fixture.root.appendingPathComponent("add-started"), release = fixture.root.appendingPathComponent("add-release")
    let sentinel = fixture.root.appendingPathComponent("concurrent-filter-must-not-run"), wrapper = fixture.root.appendingPathComponent("add-gated-git")
    try Data("""
    #!/bin/sh
    for argument in "$@"; do
      if [ "$argument" = add ]; then
        : > "$COINCIDE_CHECKPOINT_STARTED"
        trap 'exit 130' TERM INT
        while [ ! -f "$COINCIDE_CHECKPOINT_RELEASE" ]; do sleep 0.05; done
      fi
    done
    exec "$COINCIDE_REAL_GIT" "$@"
    """.utf8).write(to: wrapper)
    #expect(chmod(wrapper.path, 0o755) == 0)
    fixture.environment["COINCIDE_CHECKPOINT_STARTED"] = started.path
    fixture.environment["COINCIDE_CHECKPOINT_RELEASE"] = release.path
    fixture.environment["COINCIDE_REAL_GIT"] = fixture.git.path
    let service = fixture.service(executable: wrapper), plan = try await service.prepare()
    let task = Task { try await service.capture(plan) }
    do {
        try await checkpointEventually { FileManager.default.fileExists(atPath: started.path) }
        _ = try await fixture.run(["config", "filter.fixture." + kind, "touch '" + sentinel.path + "'"])
        try fixture.write(".gitattributes", "*.txt filter=fixture\n")
        try fixture.write("tracked.txt", "Current bytes with a newly configured filter\n")
        let changed = try await fixture.state()
        try Data().write(to: release)
        try await checkpointExpectError(.configurationChanged) { _ = try await task.value }
        #expect(!FileManager.default.fileExists(atPath: sentinel.path))
        #expect(try await fixture.state() == changed)
        #expect(try await fixture.service().inspect(plan) == .incomplete)
        #expect(try await fixture.run(["rev-parse", "--verify", plan.reference], succeeds: false).status != 0)
    } catch {
        task.cancel()
        try? Data().write(to: release)
        _ = await task.result
        throw error
    }
}

@Test(.timeLimit(.minutes(1)))
func gitCheckpointFrozenGlobalAndInfoIgnoresAndAttributesPreserveGitSemantics() async throws {
    let fixture = try await CheckpointFixture.make(); defer { fixture.cleanup() }
    let globalIgnore = fixture.root.appendingPathComponent("global ignore"), globalAttributes = fixture.root.appendingPathComponent("global attributes")
    let admin = try await fixture.admin(), info = admin.appendingPathComponent("info")
    try FileManager.default.createDirectory(at: info, withIntermediateDirectories: true)
    let infoIgnore = info.appendingPathComponent("exclude"), infoAttributes = info.appendingPathComponent("attributes")
    let auxiliary: [(URL, Data)] = [
        (globalIgnore, Data("global-ignored.txt\n".utf8)),
        (infoIgnore, Data("info-ignored.txt\n".utf8)),
        (globalAttributes, Data("global.txt text eol=lf\noverride.txt text eol=lf\n".utf8)),
        (infoAttributes, Data("info.txt text eol=lf\noverride.txt -text\n".utf8))
    ]
    for (file, bytes) in auxiliary { try bytes.write(to: file) }
    _ = try await fixture.run(["config", "core.excludesFile", globalIgnore.path])
    _ = try await fixture.run(["config", "core.attributesFile", globalAttributes.path])
    _ = try await fixture.run(["config", "core.autocrlf", "true"])
    try fixture.write("global.txt", "Global attributes normalize\r\nSecond global line\r\n")
    try fixture.write("info.txt", "Info attributes normalize\r\n")
    try fixture.write("override.txt", "Info attributes preserve these CRLF bytes\r\n")
    try fixture.write("global-ignored.txt", "Preserve global ignored bytes\r\n")
    try fixture.write("info-ignored.txt", "Preserve info ignored bytes\r\n")
    let before = try await fixture.state(), service = fixture.service(), receipt = try await service.capture(service.prepare())
    #expect(try await fixture.blob(receipt, "global.txt") == Data("Global attributes normalize\nSecond global line\n".utf8))
    #expect(try await fixture.blob(receipt, "info.txt") == Data("Info attributes normalize\n".utf8))
    #expect(try await fixture.blob(receipt, "override.txt") == Data("Info attributes preserve these CRLF bytes\r\n".utf8))
    let paths = try await fixture.paths(receipt)
    #expect(!paths.contains("global-ignored.txt"))
    #expect(!paths.contains("info-ignored.txt"))
    #expect(try await service.inspect(receipt.plan) == .ready(receipt))
    #expect(try await fixture.state() == before)
    for (file, bytes) in auxiliary { #expect(try Data(contentsOf: file) == bytes) }
}

@Test(.timeLimit(.minutes(1)), arguments: ["configuration", "index", "HEAD"])
func gitCheckpointRejectsAStalePlanWithoutChangingTheNewUserState(change: String) async throws {
    let fixture = try await CheckpointFixture.make(); defer { fixture.cleanup() }
    let service = fixture.service(), plan = try await service.prepare()
    switch change {
    case "configuration": _ = try await fixture.run(["config", "remote.origin.url", "https://user:synthetic-password@example.invalid/private?token=synthetic-query"])
    case "index":
        try fixture.write("staged-later.txt", "New staged bytes\n")
        _ = try await fixture.run(["add", "--", "staged-later.txt"])
    default:
        try fixture.write("tracked.txt", "New HEAD bytes\n")
        try await fixture.commitAll()
    }
    let before = try await fixture.state()
    try await checkpointExpectError(.configurationChanged) { _ = try await service.capture(plan) }
    #expect(try await fixture.state() == before)
    #expect(try await fixture.run(["rev-parse", "--verify", plan.reference], succeeds: false).status != 0)
    let encoded = String(decoding: try JSONEncoder().encode(plan), as: UTF8.self)
    #expect(!encoded.contains("synthetic-password"))
    #expect(!encoded.contains("synthetic-query"))
}

@Test(.timeLimit(.minutes(1)))
func gitCheckpointLinkedAdminPointerReplacementDoesNotBorrowAnotherWorktreesIdentity() async throws {
    let fixture = try await CheckpointFixture.make(); defer { fixture.cleanup() }
    let linked = fixture.root.appendingPathComponent("Linked"), foreign = fixture.root.appendingPathComponent("Foreign")
    _ = try await fixture.run(["worktree", "add", "-b", "linked", "--", linked.path, "HEAD"])
    _ = try await fixture.run(["worktree", "add", "-b", "foreign", "--", foreign.path, "HEAD"])
    let service = fixture.service(at: linked), plan = try await service.prepare()
    let originalIndex = try Data(contentsOf: URL(fileURLWithPath: plan.gitDirectoryPath).appendingPathComponent("index"))
    let foreignPointer = try Data(contentsOf: foreign.appendingPathComponent(".git"))
    try foreignPointer.write(to: linked.appendingPathComponent(".git"), options: .atomic)
    let foreignBefore = try await fixture.state(at: foreign)
    try await checkpointExpectError(.ownershipLost) { _ = try await service.capture(plan) }
    #expect(try Data(contentsOf: linked.appendingPathComponent(".git")) == foreignPointer)
    #expect(try Data(contentsOf: URL(fileURLWithPath: plan.gitDirectoryPath).appendingPathComponent("index")) == originalIndex)
    #expect(try await fixture.state(at: foreign) == foreignBefore)
    #expect(try await fixture.run(["rev-parse", "--verify", plan.reference], succeeds: false).status != 0)
}

@Test(.timeLimit(.minutes(1)))
func gitCheckpointExistingReferenceWithoutReceiptIsNeverClaimedOrReplaced() async throws {
    let fixture = try await CheckpointFixture.make(); defer { fixture.cleanup() }
    let service = fixture.service(), plan = try await service.prepare(), head = try #require(plan.headCommit)
    _ = try await fixture.run(["update-ref", plan.reference, head])
    let before = try await fixture.state()
    #expect(try await service.inspect(plan) == .incomplete)
    try await checkpointExpectError(.refCollision) { _ = try await service.capture(plan) }
    #expect(try await fixture.run(["rev-parse", plan.reference]).text == head + "\n")
    #expect(try await fixture.state() == before)
}

@Test(.timeLimit(.minutes(1)))
func gitCheckpointExistingUnprovenAttemptMetadataIsPreservedAndNeverContinued() async throws {
    let fixture = try await CheckpointFixture.make(); defer { fixture.cleanup() }
    let service = fixture.service(), plan = try await service.prepare(), attempt = fixture.attempt(plan)
    try FileManager.default.createDirectory(at: attempt, withIntermediateDirectories: true)
    let recordedPlan = try JSONEncoder().encode(plan), sentinel = Data("Preserve unproven attempt evidence\n".utf8)
    try recordedPlan.write(to: attempt.appendingPathComponent("plan.json"))
    try sentinel.write(to: attempt.appendingPathComponent("unknown-partial"))
    let before = try await fixture.state()
    #expect(try await service.inspect(plan) == .incomplete)
    try await checkpointExpectError(.incomplete) { _ = try await service.capture(plan) }
    #expect(try Data(contentsOf: attempt.appendingPathComponent("plan.json")) == recordedPlan)
    #expect(try Data(contentsOf: attempt.appendingPathComponent("unknown-partial")) == sentinel)
    #expect(!FileManager.default.fileExists(atPath: attempt.appendingPathComponent("complete.json").path))
    #expect(try await fixture.run(["rev-parse", "--verify", plan.reference], succeeds: false).status != 0)
    #expect(try await fixture.state() == before)
}

@Test(.timeLimit(.minutes(1)))
func gitCheckpointCancellationPreservesClaimedPartialAndNeverInventsCompletion() async throws {
    var fixture = try await CheckpointFixture.make(); defer { fixture.cleanup() }
    let started = fixture.root.appendingPathComponent("read-tree-started"), release = fixture.root.appendingPathComponent("read-tree-release")
    let wrapper = fixture.root.appendingPathComponent("gated-git")
    try Data("""
    #!/bin/sh
    for argument in "$@"; do
      if [ "$argument" = read-tree ]; then
        : > "$COINCIDE_CHECKPOINT_STARTED"
        trap 'exit 130' TERM INT
        while [ ! -f "$COINCIDE_CHECKPOINT_RELEASE" ]; do sleep 0.05; done
      fi
    done
    exec "$COINCIDE_REAL_GIT" "$@"
    """.utf8).write(to: wrapper)
    #expect(chmod(wrapper.path, 0o755) == 0)
    fixture.environment["COINCIDE_CHECKPOINT_STARTED"] = started.path
    fixture.environment["COINCIDE_CHECKPOINT_RELEASE"] = release.path
    fixture.environment["COINCIDE_REAL_GIT"] = fixture.git.path
    let service = fixture.service(executable: wrapper), plan = try await service.prepare(), before = try await fixture.state()
    let task = Task { try await service.capture(plan) }
    do {
        try await checkpointEventually { FileManager.default.fileExists(atPath: started.path) }
        #expect(try await fixture.service().inspect(plan) == .incomplete)
        task.cancel()
        await #expect(throws: CancellationError.self) { try await task.value }
        #expect(try await fixture.service().inspect(plan) == .incomplete)
        let partialPlan = try Data(contentsOf: fixture.attempt(plan).appendingPathComponent("plan.json"))
        let privateIndex = URL(fileURLWithPath: plan.gitDirectoryPath).appendingPathComponent(".coincide-checkpoint-" + plan.id.uuidString + ".index")
        let partialIndex = try Data(contentsOf: privateIndex)
        try await checkpointExpectError(.incomplete) { _ = try await fixture.service().capture(plan) }
        #expect(try Data(contentsOf: fixture.attempt(plan).appendingPathComponent("plan.json")) == partialPlan)
        #expect(try Data(contentsOf: privateIndex) == partialIndex)
        #expect(try await fixture.state() == before)
        #expect(try await fixture.run(["rev-parse", "--verify", plan.reference], succeeds: false).status != 0)
        #expect(FileManager.default.fileExists(atPath: fixture.attempt(plan).appendingPathComponent("plan.json").path))
        #expect(!FileManager.default.fileExists(atPath: fixture.attempt(plan).appendingPathComponent("complete.json").path))
    } catch {
        task.cancel()
        try? Data().write(to: release)
        _ = await task.result
        throw error
    }
}

@Test(.timeLimit(.minutes(1)))
func gitCheckpointTamperedCompletionEvidenceCannotBlessOrOverwriteAReference() async throws {
    let fixture = try await CheckpointFixture.make(); defer { fixture.cleanup() }
    let service = fixture.service(), plan = try await service.prepare(), receipt = try await service.capture(plan)
    let completion = fixture.attempt(plan).appendingPathComponent("complete.json")
    var changed = try #require(JSONSerialization.jsonObject(with: Data(contentsOf: completion)) as? [String: Any])
    changed["tree"] = String(repeating: "f", count: 40)
    let invalid = try JSONSerialization.data(withJSONObject: changed)
    try invalid.write(to: completion, options: .atomic)
    let before = try await fixture.state()
    try await checkpointExpectError(.metadataInvalid) { _ = try await service.inspect(plan) }
    try await checkpointExpectError(.metadataInvalid) { _ = try await service.capture(plan) }
    #expect(try Data(contentsOf: completion) == invalid)
    #expect(try await fixture.run(["rev-parse", plan.reference]).text == receipt.commit + "\n")
    #expect(try await fixture.state() == before)

    // A blob can imitate every visible commit header and message. Matching bytes, a ref,
    // and a receipt still cannot prove that the referenced object is a commit.
    let imitation = Data(("tree " + receipt.tree + "\n" + (plan.headCommit.map { "parent " + $0 + "\n" } ?? "")
        + "author Fixture <fixture@example.invalid> 0 +0000\ncommitter Fixture <fixture@example.invalid> 0 +0000\n\nCoincide checkpoint "
        + plan.id.uuidString.lowercased() + "\n").utf8)
    let blob = try await fixture.run(["hash-object", "-w", "--stdin"], input: imitation).text.trimmingCharacters(in: .whitespacesAndNewlines)
    #expect(try await fixture.run(["cat-file", "-t", blob]).text == "blob\n")
    let forged = try GitCheckpointReceipt(plan: plan, commit: blob, tree: receipt.tree, capturedAt: receipt.capturedAt)
    let forgedEvidence = try JSONEncoder().encode(forged)
    try forgedEvidence.write(to: completion, options: .atomic)
    _ = try await fixture.run(["update-ref", plan.reference, blob, receipt.commit])
    try await checkpointExpectError(.metadataInvalid) { _ = try await service.inspect(plan) }
    try await checkpointExpectError(.metadataInvalid) { _ = try await service.capture(plan) }
    #expect(try Data(contentsOf: completion) == forgedEvidence)
    #expect(try await fixture.run(["rev-parse", plan.reference]).text == blob + "\n")
    #expect(try await fixture.state() == before)
}

@Test(.timeLimit(.minutes(1)), arguments: ["reference", "mapping"])
func gitCheckpointInspectionRechecksReferenceAndMappingAfterObjectReads(change: String) async throws {
    var fixture = try await CheckpointFixture.make(); defer { fixture.cleanup() }
    let linked = fixture.root.appendingPathComponent("Linked"), foreign = fixture.root.appendingPathComponent("Foreign")
    _ = try await fixture.run(["worktree", "add", "-b", "linked", "--", linked.path, "HEAD"])
    _ = try await fixture.run(["worktree", "add", "-b", "foreign", "--", foreign.path, "HEAD"])
    let capture = fixture.service(at: linked), receipt = try await capture.capture(capture.prepare()), plan = receipt.plan
    let head = try #require(plan.headCommit)
    let before = try await fixture.state(), foreignBefore = try await fixture.state(at: foreign), linkedFiles = try fixture.files(below: linked)
    let originalIndex = try Data(contentsOf: URL(fileURLWithPath: plan.gitDirectoryPath).appendingPathComponent("index"))
    let started = fixture.root.appendingPathComponent("cat-file-started"), release = fixture.root.appendingPathComponent("cat-file-release")
    let wrapper = fixture.root.appendingPathComponent("cat-file-gated-git")
    try Data("""
    #!/bin/sh
    for argument in "$@"; do
      if [ "$argument" = cat-file ]; then
        : > "$COINCIDE_CHECKPOINT_STARTED"
        trap 'exit 130' TERM INT
        while [ ! -f "$COINCIDE_CHECKPOINT_RELEASE" ]; do sleep 0.05; done
      fi
    done
    exec "$COINCIDE_REAL_GIT" "$@"
    """.utf8).write(to: wrapper)
    #expect(chmod(wrapper.path, 0o755) == 0)
    fixture.environment["COINCIDE_CHECKPOINT_STARTED"] = started.path
    fixture.environment["COINCIDE_CHECKPOINT_RELEASE"] = release.path
    fixture.environment["COINCIDE_REAL_GIT"] = fixture.git.path
    let service = fixture.service(at: linked, executable: wrapper)
    let task = Task { try await service.inspect(plan) }
    do {
        try await checkpointEventually { FileManager.default.fileExists(atPath: started.path) }
        if change == "reference" {
            _ = try await fixture.run(["update-ref", plan.reference, head, receipt.commit])
        } else {
            try Data(contentsOf: foreign.appendingPathComponent(".git")).write(to: linked.appendingPathComponent(".git"), options: .atomic)
        }
        try Data().write(to: release)
        try await checkpointExpectError(change == "reference" ? .metadataInvalid : .ownershipLost) { _ = try await task.value }
        #expect(try await fixture.state() == before)
        #expect(try await fixture.state(at: foreign) == foreignBefore)
        #expect(try fixture.files(below: linked) == linkedFiles)
        #expect(try Data(contentsOf: URL(fileURLWithPath: plan.gitDirectoryPath).appendingPathComponent("index")) == originalIndex)
        if change == "reference" {
            #expect(try await fixture.run(["rev-parse", plan.reference]).text == head + "\n")
        } else {
            #expect(try Data(contentsOf: linked.appendingPathComponent(".git")) == Data(contentsOf: foreign.appendingPathComponent(".git")))
        }
    } catch {
        task.cancel()
        try? Data().write(to: release)
        _ = await task.result
        throw error
    }
}

@Test(.timeLimit(.minutes(1)))
func gitCheckpointDiffIsLiteralBoundedRedactedAndNeverExecutesExternalDiffOrTextconv() async throws {
    let fixture = try await CheckpointFixture.make(); defer { fixture.cleanup() }
    let sentinel = fixture.root.appendingPathComponent("diff-must-not-run")
    try fixture.write("literal[1].txt", "Before exact file\n")
    try fixture.write("literal1.txt", "Before neighbor\n")
    try fixture.write("whitespace.txt", "one two\n")
    try fixture.write(".gitattributes", "*.txt diff=fixture\n")
    try await fixture.commitAll()
    _ = try await fixture.run(["config", "diff.fixture.textconv", "touch '" + sentinel.path + "'"])
    _ = try await fixture.run(["config", "diff.external", "touch '" + sentinel.path + "'"])
    let service = fixture.service(), first = try await service.capture(service.prepare())
    try fixture.write("literal[1].txt", "After exact file https://user:synthetic-password@example.invalid/path?token=synthetic-query\n" + String(repeating: "Large exact fixture line\n", count: 300))
    try fixture.write("literal1.txt", "After neighbor\n")
    try fixture.write("whitespace.txt", "one    two\n")
    let second = try await service.capture(service.prepare()), before = try await fixture.state()
    let exact = try await service.diff(from: first, to: second, paths: ["literal[1].txt"])
    #expect(exact.patch.contains("After exact file"))
    #expect(!exact.patch.contains("After neighbor"))
    #expect(!exact.patch.contains("synthetic-password"))
    #expect(!exact.patch.contains("synthetic-query"))
    #expect(!exact.truncated)
    let bounded = try await service.diff(from: first, to: second, paths: ["literal[1].txt"], maxBytes: 512)
    #expect(bounded.truncated)
    #expect(bounded.patch.utf8.count <= 512)
    let ignored = try await service.diff(from: first, to: second, paths: ["whitespace.txt"], ignoreWhitespace: true)
    #expect(ignored.patch.isEmpty)
    for path in ["../outside", "/absolute", "bad\0name"] {
        try await checkpointExpectError(.invalidPlan) { _ = try await service.diff(from: first, to: second, paths: [path]) }
    }
    #expect(!FileManager.default.fileExists(atPath: sentinel.path))
    #expect(try await fixture.state() == before)
}
