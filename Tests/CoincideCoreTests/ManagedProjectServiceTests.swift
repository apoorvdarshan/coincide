import Foundation
import Testing
import Darwin
@testable import CoincideCore

private struct ManagedProjectFixture: Sendable {
    let root: URL, projects: URL, home: URL
    let environment: [String: String]
    static func make(identity: Bool = true) async throws -> Self {
        let root = try temporaryWorkspace().resolvingSymlinksInPath(), home = root.appendingPathComponent("home")
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
        var env = ProcessChannel.environment()
        for key in env.keys where key.hasPrefix("GIT_") || key == "EMAIL" { env.removeValue(forKey: key) }
        env["HOME"] = home.path; env["XDG_CONFIG_HOME"] = home.appendingPathComponent(".config").path
        env["GIT_CONFIG_NOSYSTEM"] = "1"; env["GIT_CONFIG_GLOBAL"] = home.appendingPathComponent(".gitconfig").path
        let fixture = Self(root: root, projects: root.appendingPathComponent("Projects"), home: home, environment: env)
        do {
            try await fixture.configure("user.useConfigOnly", "true")
            try await fixture.configure("commit.gpgSign", "false")
            if identity { try await fixture.configure("user.name", "Coincide Test"); try await fixture.configure("user.email", "test@example.invalid") }
            return fixture
        } catch { try? FileManager.default.removeItem(at: root); throw error }
    }
    var service: ManagedProjectService { ManagedProjectService(root: projects, environment: environment) }
    func configure(_ key: String, _ value: String) async throws {
        let result = try await CommandRunner.run("git", ["config", "--global", key, value], cwd: root, environment: environment)
        guard result.status == 0 else { throw CoincideError("Managed fixture configuration failed.") }
    }
    @discardableResult func git(_ folder: URL, _ args: [String]) async throws -> CommandResult {
        try await CommandRunner.run("git", ["--no-pager", "-C", folder.path] + args, cwd: root, environment: environment)
    }
    func hook(_ contents: String) async throws {
        let directory = root.appendingPathComponent("hooks")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let script = directory.appendingPathComponent("pre-commit")
        try ("#!/bin/sh\n" + contents + "\n").write(to: script, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: script.path)
        try await configure("core.hooksPath", directory.path)
    }
}

private func managedEventually(_ description: String, _ condition: @escaping @Sendable () -> Bool) async throws {
    let deadline = ContinuousClock.now.advanced(by: .seconds(5))
    while !condition() {
        guard ContinuousClock.now < deadline else { throw CoincideError("Managed project fixture did not reach \(description).") }
        try await Task.sleep(for: .milliseconds(10))
    }
}

@Test func managedProjectNamesMatchUnicodeSlugsReservedNamesAndTheUpstreamLengthLimit() throws {
    let cases = ["  Café & Tools  ": "cafe-tools", "İstanbul São Paulo": "istanbul-sao-paulo", "a\u{301}bc": "abc", "１２３ ①": "123-1",
                 "---Hello___World---": "hello-world", "🤖✨": "project", "中文": "project", "CON": "con-project", "prn": "prn-project",
                 "NUL": "nul-project", "Aux": "aux-project", "COM1": "com1-project", "lpt9": "lpt9-project", "com0": "com0", "com10": "com10",
                 "../a/b\\c": "a-b-c", "con.txt": "con-txt", "Straße": "stra-e"]
    for (name, expected) in cases { #expect(ManagedProjectService.folderName(for: name) == expected) }
    #expect(ManagedProjectService.folderName(for: String(repeating: "A", count: 100)) == String(repeating: "a", count: 64))
    #expect(ManagedProjectService.folderName(for: String(repeating: "a", count: 63) + " b") == String(repeating: "a", count: 63))
    #expect(try ManagedProjectService.validatedName("  Preserve Café ✨  ") == "Preserve Café ✨")
    #expect(try ManagedProjectService.validatedName("Family 👨‍👩‍👧‍👦") == "Family 👨‍👩‍👧‍👦")
    #expect(try ManagedProjectService.validatedName(String(repeating: "🤖", count: 100)).utf16.count == 200)
    for name in ["", "  \n\t", "bad\0name", "bad\nname", "bad\tname", "bad\u{0085}name", "bad\u{2028}name", "bad\u{2029}name", String(repeating: "a", count: 201), String(repeating: "🤖", count: 101)] {
        #expect(throws: (any Error).self) { try ManagedProjectService.validatedName(name) }
    }
}

@Test func managedProjectCreatesPrivateNativeStarterRepositoryWithDisplayTitleAndInitialCommit() async throws {
    let f = try await ManagedProjectFixture.make(); defer { try? FileManager.default.removeItem(at: f.root) }
    let globalBefore = try Data(contentsOf: f.home.appendingPathComponent(".gitconfig"))
    let result = try await f.service.create(name: "  Café & Tools  "), folder = URL(fileURLWithPath: result.project.path)
    #expect(result.project.name == "Café & Tools" && folder.lastPathComponent == "cafe-tools" && result.project.clone == nil)
    #expect(result.commitWarning == nil)
    #expect(folder.deletingLastPathComponent().path == f.projects.path)
    #expect(try await f.git(folder, ["branch", "--show-current"]).text.trimmingCharacters(in: .newlines) == "main")
    #expect(try await f.git(folder, ["log", "-1", "--format=%s"]).text == "Initial commit\n")
    #expect(try await f.git(folder, ["ls-tree", "-r", "--name-only", "HEAD"]).text == "README.md\nassets/icon.svg\n")
    #expect(try await f.git(folder, ["status", "--porcelain"]).text.isEmpty)
    #expect(try await f.git(folder, ["remote"]).text.isEmpty)
    let readme = try String(contentsOf: folder.appendingPathComponent("README.md"), encoding: .utf8)
    #expect(readme.contains("# Café & Tools") && readme.contains("assets/icon.svg") && readme.contains("https://github.com/apoorvdarshan/coincide"))
    let svg = try String(contentsOf: folder.appendingPathComponent("assets/icon.svg"), encoding: .utf8)
    #expect(svg.contains("<title>Café &amp; Tools</title>") && svg.contains("viewBox=\"0 0 64 64\""))
    #expect(try FileManager.default.attributesOfItem(atPath: f.projects.path)[.posixPermissions] as? Int == 0o700)
    #expect(try FileManager.default.attributesOfItem(atPath: folder.path)[.posixPermissions] as? Int == 0o700)
    #expect(try Data(contentsOf: f.home.appendingPathComponent(".gitconfig")) == globalBefore)
}

@Test func managedProjectHonorsConfiguredBranchAndForceAddsExactlyTwoGloballyIgnoredStarterFiles() async throws {
    let f = try await ManagedProjectFixture.make(); defer { try? FileManager.default.removeItem(at: f.root) }
    try await f.configure("init.defaultBranch", "trunk/native")
    let ignore = f.root.appendingPathComponent("global-ignore")
    try "*.md\n*.svg\nassets/\n".write(to: ignore, atomically: true, encoding: .utf8)
    try await f.configure("core.excludesFile", ignore.path)
    let result = try await f.service.create(name: "Reserved COM1"), folder = URL(fileURLWithPath: result.project.path)
    #expect(result.commitWarning == nil)
    #expect(try await f.git(folder, ["branch", "--show-current"]).text == "trunk/native\n")
    #expect(try await f.git(folder, ["ls-tree", "-r", "--name-only", "HEAD"]).text == "README.md\nassets/icon.svg\n")
    #expect(try await f.git(folder, ["status", "--porcelain"]).text.isEmpty)
}

@Test func managedProjectMissingIdentityLeavesValidRepositoryAndStagedFilesWithActionableWarning() async throws {
    let f = try await ManagedProjectFixture.make(identity: false); defer { try? FileManager.default.removeItem(at: f.root) }
    let result = try await f.service.create(name: "No Identity"), folder = URL(fileURLWithPath: result.project.path)
    let warning = try #require(result.commitWarning)
    #expect(warning.contains("user.name") && warning.contains("user.email"))
    #expect(try await f.git(folder, ["rev-parse", "--verify", "HEAD"]).status != 0)
    #expect(try await f.git(folder, ["ls-files"]).text == "README.md\nassets/icon.svg\n")
    #expect(FileManager.default.fileExists(atPath: folder.appendingPathComponent("README.md").path))
    #expect(try await f.git(folder, ["config", "--get", "user.email"]).status != 0)
}

@Test(arguments: ["signing", "hook"])
func managedProjectSigningAndHookFailuresRemainNonfatalAndRedactRemoteCredentials(_ failure: String) async throws {
    let f = try await ManagedProjectFixture.make(); defer { try? FileManager.default.removeItem(at: f.root) }
    if failure == "signing" {
        try await f.configure("commit.gpgSign", "true"); try await f.configure("gpg.program", "/usr/bin/false"); try await f.configure("user.signingKey", "fixture")
    } else {
        try await f.hook("printf '%s\\n' 'denied https://private-user:private-password@host/repo?token=private-token' >&2\nexit 1")
    }
    let result = try await f.service.create(name: "Failed " + failure), folder = URL(fileURLWithPath: result.project.path)
    let warning = try #require(result.commitWarning)
    #expect(warning.contains("initial commit"))
    for secret in ["private-user", "private-password", "private-token"] { #expect(!warning.contains(secret)) }
    #expect(try await f.git(folder, ["rev-parse", "--verify", "HEAD"]).status != 0)
    #expect(try await f.git(folder, ["ls-files"]).text == "README.md\nassets/icon.svg\n")
}

@Test func managedProjectConcurrentCreationAtomicallyClaimsDistinctFolders() async throws {
    let f = try await ManagedProjectFixture.make(); defer { try? FileManager.default.removeItem(at: f.root) }
    let results = try await withThrowingTaskGroup(of: ManagedProjectCreationResult.self) { group in
        for _ in 1...8 { group.addTask { try await f.service.create(name: "Same Name") } }
        var values: [ManagedProjectCreationResult] = []; for try await value in group { values.append(value) }; return values
    }
    let names = Set(results.map { URL(fileURLWithPath: $0.project.path).lastPathComponent })
    #expect(names == Set(["same-name"] + (2...8).map { "same-name-\($0)" }))
    #expect(Set(results.map(\.project.id)).count == 8 && results.allSatisfy { $0.project.name == "Same Name" && $0.commitWarning == nil })
    for value in results { #expect(try await f.git(URL(fileURLWithPath: value.project.path), ["rev-parse", "--verify", "HEAD"]).status == 0) }
}

@Test func managedProjectClaimsSkipExistingFilesDirectoriesAndSymlinksWithoutAlteringTheirData() async throws {
    let f = try await ManagedProjectFixture.make(); defer { try? FileManager.default.removeItem(at: f.root) }
    try FileManager.default.createDirectory(at: f.projects, withIntermediateDirectories: true)
    try "existing file".write(to: f.projects.appendingPathComponent("project"), atomically: true, encoding: .utf8)
    let outside = f.root.appendingPathComponent("outside")
    try FileManager.default.createDirectory(at: outside, withIntermediateDirectories: true)
    try "outside data".write(to: outside.appendingPathComponent("precious"), atomically: true, encoding: .utf8)
    try FileManager.default.createSymbolicLink(at: f.projects.appendingPathComponent("project-2"), withDestinationURL: outside)
    let existing = f.projects.appendingPathComponent("project-3")
    try FileManager.default.createDirectory(at: existing, withIntermediateDirectories: true)
    try "existing data".write(to: existing.appendingPathComponent("precious"), atomically: true, encoding: .utf8)
    let result = try await f.service.create(name: "🤖")
    #expect(URL(fileURLWithPath: result.project.path).lastPathComponent == "project-4" && result.project.name == "🤖")
    #expect(try String(contentsOf: f.projects.appendingPathComponent("project"), encoding: .utf8) == "existing file")
    #expect(try String(contentsOf: outside.appendingPathComponent("precious"), encoding: .utf8) == "outside data")
    #expect(try FileManager.default.contentsOfDirectory(atPath: outside.path) == ["precious"])
    #expect(try String(contentsOf: existing.appendingPathComponent("precious"), encoding: .utf8) == "existing data")
    let rootLink = f.root.appendingPathComponent("linked-projects")
    try FileManager.default.createSymbolicLink(at: rootLink, withDestinationURL: outside)
    await #expect(throws: (any Error).self) { _ = try await ManagedProjectService(root: rootLink, environment: f.environment).create(name: "Must Not Escape") }
    #expect(try FileManager.default.contentsOfDirectory(atPath: outside.path) == ["precious"])
}

@Test func managedProjectExhaustedCollisionCandidatesAndInvalidNamesCreateNoExtraFolders() async throws {
    let f = try await ManagedProjectFixture.make(); defer { try? FileManager.default.removeItem(at: f.root) }
    try FileManager.default.createDirectory(at: f.projects, withIntermediateDirectories: true)
    for index in 1...100 { try FileManager.default.createDirectory(at: f.projects.appendingPathComponent(index == 1 ? "busy" : "busy-\(index)"), withIntermediateDirectories: false) }
    await #expect(throws: (any Error).self) { _ = try await f.service.create(name: "Busy") }
    await #expect(throws: (any Error).self) { _ = try await f.service.create(name: "") }
    #expect(try FileManager.default.contentsOfDirectory(atPath: f.projects.path).count == 100)
}

@Test func managedProjectHardGitFailurePreservesClaimedFolderAndReportsItsRecoveryPath() async throws {
    let f = try await ManagedProjectFixture.make(); defer { try? FileManager.default.removeItem(at: f.root) }
    try await f.configure("init.defaultBranch", "invalid..branch")
    let claimed = f.projects.appendingPathComponent("recover-me")
    do { _ = try await f.service.create(name: "Recover Me"); Issue.record("Invalid configured branch unexpectedly initialized.") }
    catch {
        #expect(error.localizedDescription.contains("preserved at " + claimed.path))
        #expect(FileManager.default.fileExists(atPath: claimed.path))
    }
    #expect(try await f.git(f.root, ["config", "--global", "--get", "init.defaultBranch"]).text == "invalid..branch\n")
}

@Test func managedProjectClearsInheritedGitContextAndNeverStagesIntoAnotherRepository() async throws {
    let f = try await ManagedProjectFixture.make(); defer { try? FileManager.default.removeItem(at: f.root) }
    let outside = f.root.appendingPathComponent("outside")
    try FileManager.default.createDirectory(at: outside, withIntermediateDirectories: true)
    #expect(try await f.git(outside, ["init", "--initial-branch=external"]).status == 0)
    try "untracked outside".write(to: outside.appendingPathComponent("precious"), atomically: true, encoding: .utf8)
    var corrupted = f.environment
    corrupted["GIT_DIR"] = outside.appendingPathComponent(".git").path; corrupted["GIT_WORK_TREE"] = outside.path
    corrupted["GIT_INDEX_FILE"] = outside.appendingPathComponent("index-other").path
    corrupted["GIT_CONFIG_COUNT"] = "1"; corrupted["GIT_CONFIG_KEY_0"] = "core.worktree"; corrupted["GIT_CONFIG_VALUE_0"] = outside.path
    let result = try await ManagedProjectService(root: f.projects, environment: corrupted).create(name: "Isolated")
    #expect(result.commitWarning == nil)
    #expect(try await f.git(outside, ["ls-files"]).text.isEmpty)
    #expect(try await f.git(outside, ["branch", "--show-current"]).text == "external\n")
    #expect(try String(contentsOf: outside.appendingPathComponent("precious"), encoding: .utf8) == "untracked outside")
    #expect(!FileManager.default.fileExists(atPath: outside.appendingPathComponent("index-other").path))
}

@Test func managedProjectCancellationPreservesRepositoryAndStarterFilesWithoutReportingSuccess() async throws {
    let f = try await ManagedProjectFixture.make(); defer { try? FileManager.default.removeItem(at: f.root) }
    let started = f.root.appendingPathComponent("hook-started"), release = f.root.appendingPathComponent("hook-release"), pidFile = f.root.appendingPathComponent("hook-pid")
    try await f.hook(#"""
    printf '%s\n' "$$" > "$MANAGED_HOOK_PID"
    : > "$MANAGED_HOOK_STARTED"
    i=0
    while [ ! -f "$MANAGED_HOOK_RELEASE" ] && [ "$i" -lt 200 ]; do
      /bin/sleep 0.02
      i=$((i+1))
    done
    exit 0
    """#)
    var env = f.environment
    env["MANAGED_HOOK_STARTED"] = started.path; env["MANAGED_HOOK_RELEASE"] = release.path; env["MANAGED_HOOK_PID"] = pidFile.path
    let service = ManagedProjectService(root: f.projects, environment: env)
    let task = Task { try await service.create(name: "Cancelled") }
    do { try await managedEventually("hook startup") { FileManager.default.fileExists(atPath: started.path) } }
    catch { task.cancel(); try? "release".write(to: release, atomically: true, encoding: .utf8); _ = await task.result; throw error }
    task.cancel(); try "release".write(to: release, atomically: true, encoding: .utf8)
    switch await task.result { case .success: Issue.record("Cancelled project creation reported success."); case .failure(let error): #expect(error is CancellationError) }
    let hookPID = try #require(Int32(String(contentsOf: pidFile, encoding: .utf8).trimmingCharacters(in: .whitespacesAndNewlines)))
    // Cancellation may kill the hook before its next instruction. Observe its exit instead of
    // requiring it to write a marker afterward; signal zero never sends a signal to that PID.
    try await managedEventually("owned hook process exit") { kill(hookPID, 0) == -1 && errno == ESRCH }
    let folder = f.projects.appendingPathComponent("cancelled")
    #expect(FileManager.default.fileExists(atPath: folder.appendingPathComponent("README.md").path))
    #expect(FileManager.default.fileExists(atPath: folder.appendingPathComponent("assets/icon.svg").path))
    #expect(try await f.git(folder, ["rev-parse", "--git-dir"]).status == 0)
}

@Test func managedProjectCommitTimeoutIsNonfatalAndLeavesAUsableRepository() async throws {
    let f = try await ManagedProjectFixture.make(); defer { try? FileManager.default.removeItem(at: f.root) }
    try await f.hook("exec /bin/sleep 0.4")
    let service = ManagedProjectService(root: f.projects, environment: f.environment, commitTimeout: .milliseconds(100))
    let result = try await service.create(name: "Timed Out"), folder = URL(fileURLWithPath: result.project.path)
    #expect(result.commitWarning?.contains("timed out") == true)
    #expect(try await f.git(folder, ["rev-parse", "--git-dir"]).status == 0)
    #expect(try await f.git(folder, ["ls-files"]).text == "README.md\nassets/icon.svg\n")
    // The hook's short-lived child exits naturally; do not leave a test-owned process behind.
    try await Task.sleep(for: .milliseconds(500))
}
