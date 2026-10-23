import Darwin
import Foundation
import Testing
@testable import CoincideCore

private extension WorktreeFixture {
    var taskCapture: TaskIsolationCapture { .init(environment: environment, gitExecutable: git) }
    func taskHead(at path: URL? = nil) async throws -> String {
        String(decoding: try await run(["rev-parse", "HEAD"], at: path).output, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
    }
    func linkedTaskWorkspace() async throws -> URL {
        let linked = root.appendingPathComponent("Linked parent")
        _ = try await run(["worktree", "add", "--detach", linked.path, "HEAD"])
        return linked
    }
}

@Test(.timeLimit(.minutes(1)))
func taskIsolationCapturePreservesDirtyIndexAndUntrackedFilesAndCreatesOnlyThePinnedHeadCheckout() async throws {
    let f = try await WorktreeFixture.make(); defer { f.cleanup() }
    let tracked = f.source.appendingPathComponent("README.md"), untracked = f.source.appendingPathComponent("unsent-parent.txt")
    try Data("Staged parent bytes\n".utf8).write(to: tracked); _ = try await f.run(["add", "--", "README.md"])
    try Data("Unstaged parent bytes\n".utf8).write(to: tracked); try Data("Untracked parent bytes\n".utf8).write(to: untracked)
    let index = f.source.appendingPathComponent(".git/index"), beforeIndex = try Data(contentsOf: index)
    let beforeStatus = try await f.run(["status", "--porcelain=v1", "-z"]).output
    let proof = try await f.taskCapture.capture(parentWorkspacePath: f.source.path, projectPath: f.source.path)
    try await f.taskCapture.validate(proof, requireCurrentHead: true)
    let request = GitWorktreeRequest(sourcePath: proof.sourceRepositoryPath, destinationRoot: f.destinations.path,
        selection: .createBranch(name: "task-from-captured-head", baseRef: proof.baseCommit), expectedSourceIdentity: proof.sourceRepositoryIdentity)
    let service = f.service(request), plan = try await service.prepare(), child = try await service.run(plan)
    #expect(child.headCommit == proof.baseCommit)
    #expect(try String(contentsOf: URL(fileURLWithPath: child.destinationPath).appendingPathComponent("README.md"), encoding: .utf8) == "Committed bytes\n")
    #expect(!FileManager.default.fileExists(atPath: child.destinationPath + "/unsent-parent.txt"))
    #expect(try Data(contentsOf: tracked) == Data("Unstaged parent bytes\n".utf8))
    #expect(try Data(contentsOf: untracked) == Data("Untracked parent bytes\n".utf8))
    #expect(try Data(contentsOf: index) == beforeIndex)
    #expect(try await f.run(["status", "--porcelain=v1", "-z"]).output == beforeStatus)
}

@Test(.timeLimit(.minutes(1)))
func taskIsolationCaptureUsesTheLinkedParentsOwnHeadAndPreservesNestedWorkingDirectoryOwnership() async throws {
    let f = try await WorktreeFixture.make(); defer { f.cleanup() }
    let linked = try await f.linkedTaskWorkspace(), nested = linked.appendingPathComponent("nested/deep")
    let projectNested = f.source.appendingPathComponent("project/nested")
    try FileManager.default.createDirectory(at: nested, withIntermediateDirectories: true)
    try FileManager.default.createDirectory(at: projectNested, withIntermediateDirectories: true)
    try Data("Linked-only commit".utf8).write(to: linked.appendingPathComponent("linked-only.txt"))
    _ = try await f.run(["add", "linked-only.txt"], at: linked); _ = try await f.run(["commit", "-m", "Linked parent commit"], at: linked)
    let linkedHead = try await f.taskHead(at: linked), mainHead = try await f.taskHead()
    #expect(linkedHead != mainHead)
    let proof = try await f.taskCapture.capture(parentWorkspacePath: nested.path, projectPath: projectNested.path)
    #expect(proof.sourcePath == nested.path && proof.projectPath == projectNested.path)
    #expect(proof.sourceRepositoryPath == linked.path && proof.projectRepositoryPath == f.source.path && proof.baseCommit == linkedHead)
    #expect(proof.sourceGitDirectoryPath != proof.commonDirectoryPath)
    try await f.taskCapture.validate(proof, requireCurrentHead: true)
    let foreign = f.root.appendingPathComponent("Foreign")
    try FileManager.default.createDirectory(at: foreign, withIntermediateDirectories: false)
    _ = try await f.run(["init", "--initial-branch=main"], at: foreign)
    await #expect(throws: TaskIsolationError.differentRepository) { _ = try await f.taskCapture.capture(parentWorkspacePath: nested.path, projectPath: foreign.path) }
}

@Test(.timeLimit(.minutes(1)))
func taskIsolationCaptureAllowsLaterParentHeadOnlyForAlreadyAcceptedPinnedIntent() async throws {
    let f = try await WorktreeFixture.make(); defer { f.cleanup() }
    let proof = try await f.taskCapture.capture(parentWorkspacePath: f.source.path, projectPath: f.source.path)
    try Data("A later parent commit\n".utf8).write(to: f.source.appendingPathComponent("README.md"))
    _ = try await f.run(["add", "README.md"]); _ = try await f.run(["commit", "-m", "Parent advances after accepted task"])
    try await f.taskCapture.validate(proof, requireCurrentHead: false)
    await #expect(throws: TaskIsolationError.changedRepository) { try await f.taskCapture.validate(proof, requireCurrentHead: true) }
    let request = f.request(.createBranch(name: "pinned-before-parent-advance", baseRef: proof.baseCommit))
    let service = f.service(request), plan = try await service.prepare(), result = try await service.run(plan)
    #expect(result.headCommit == proof.baseCommit)
    #expect(try String(contentsOf: URL(fileURLWithPath: result.destinationPath).appendingPathComponent("README.md"), encoding: .utf8) == "Committed bytes\n")
}

@Test(.timeLimit(.minutes(1)), arguments: ["source-root", "git-directory", "common-directory", "linked-admin", "git-pointer"])
func taskIsolationCaptureRefusesReplacedSourceOrGitOwnershipBeforeAnyChildMutation(change: String) async throws {
    let f = try await WorktreeFixture.make(); defer { f.cleanup() }
    let linked = try await f.linkedTaskWorkspace()
    let source = change == "source-root" || change == "git-directory" ? f.source : linked
    let proof = try await f.taskCapture.capture(parentWorkspacePath: source.path, projectPath: f.source.path)
    if change == "git-pointer" {
        let other = f.root.appendingPathComponent("Other-linked")
        _ = try await f.run(["worktree", "add", "--detach", other.path, "HEAD"])
        try Data(contentsOf: other.appendingPathComponent(".git")).write(to: linked.appendingPathComponent(".git"), options: .atomic)
    } else {
        let replaced: URL
        switch change {
        case "source-root": replaced = f.source
        case "git-directory", "common-directory": replaced = f.source.appendingPathComponent(".git")
        default: replaced = URL(fileURLWithPath: proof.sourceGitDirectoryPath)
        }
        let retained = f.root.appendingPathComponent("Retained-" + change)
        try FileManager.default.moveItem(at: replaced, to: retained)
        try FileManager.default.copyItem(at: retained, to: replaced)
    }
    await #expect(throws: (any Error).self) { try await f.taskCapture.validate(proof, requireCurrentHead: false) }
    #expect(try FileManager.default.contentsOfDirectory(atPath: f.destinations.path).isEmpty)
}

@Test(.timeLimit(.minutes(1)))
func taskIsolationCaptureUsesOnlyOfflineReadCommandsAndRefusesMissingLocalCommitWithoutFetch() async throws {
    var f = try await WorktreeFixture.make(); defer { f.cleanup() }
    let wrapper = f.root.appendingPathComponent("read-only-git"), log = f.root.appendingPathComponent("read-phases")
    try Data("""
    #!/bin/sh
    phase=unknown
    lazy=no
    replace=no
    content=no
    for arg in "$@"; do
      case "$arg" in
        --no-lazy-fetch) lazy=yes ;;
        --no-replace-objects) replace=yes ;;
        rev-parse|cat-file|worktree) phase="$arg" ;;
        --verify) content=yes ;;
      esac
    done
    [ "$GIT_ALLOW_PROTOCOL" = '' ] && [ "$GIT_PROTOCOL_FROM_USER" = 0 ] || exit 91
    case "$phase" in rev-parse|cat-file|worktree) ;; *) exit 92 ;; esac
    if [ "$phase" = cat-file ] || [ "$content" = yes ]; then
      [ "$lazy" = yes ] && [ "$replace" = yes ] || exit 93
    fi
    printf '%s %s %s\\n' "$phase" "$lazy" "$replace" >> "$COINCIDE_TASK_GIT_LOG"
    exec "$COINCIDE_TASK_REAL_GIT" "$@"
    """.utf8).write(to: wrapper)
    #expect(chmod(wrapper.path, 0o700) == 0)
    f.environment["COINCIDE_TASK_GIT_LOG"] = log.path; f.environment["COINCIDE_TASK_REAL_GIT"] = f.git.path
    let capture = TaskIsolationCapture(environment: f.environment, gitExecutable: wrapper)
    let proof = try await capture.capture(parentWorkspacePath: f.source.path, projectPath: f.source.path)
    try Data("New descendant commit".utf8).write(to: f.source.appendingPathComponent("README.md"))
    _ = try await f.run(["add", "README.md"]); _ = try await f.run(["commit", "-m", "Keep newer HEAD locally"])
    _ = try await f.run(["remote", "add", "origin", f.root.appendingPathComponent("Never-fetch-missing-origin").path])
    _ = try await f.run(["config", "remote.origin.promisor", "true"])
    let object = f.source.appendingPathComponent(".git/objects/" + String(proof.baseCommit.prefix(2)) + "/" + String(proof.baseCommit.dropFirst(2)))
    try FileManager.default.removeItem(at: object)
    await #expect(throws: TaskIsolationError.noLocalCommit) { try await capture.validate(proof) }
    let phases = try String(contentsOf: log, encoding: .utf8).split(separator: "\n").map(String.init)
    #expect(phases.contains("cat-file yes yes") && phases.contains("rev-parse yes yes"))
    #expect(phases.allSatisfy { ["rev-parse", "cat-file", "worktree"].contains($0.split(separator: " ").first.map(String.init) ?? "") })
}
