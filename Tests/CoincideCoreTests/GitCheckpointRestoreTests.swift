import Darwin
import Foundation
import Testing
@testable import CoincideCore

private func restoreEventually(_ predicate: @escaping @Sendable () -> Bool) async throws {
    let deadline = ContinuousClock.now + .seconds(8)
    while !predicate() {
        guard ContinuousClock.now < deadline else { throw CoincideError("The isolated restore fixture did not reach its gate.") }
        try await Task.sleep(for: .milliseconds(10))
    }
}
private func restoreFailure(_ body: () async throws -> Void) async throws -> GitCheckpointRestoreError {
    do { try await body(); throw CoincideError("The isolated restore unexpectedly succeeded.") }
    catch let failure as GitCheckpointRestoreError { return failure }
}
private func restoreSaved(_ fixture: CheckpointFixture, at root: URL? = nil) async throws -> GitCheckpointReceipt {
    let service = fixture.service(at: root)
    return try await service.capture(service.prepare())
}

@Test(.timeLimit(.minutes(1)))
func gitCheckpointRestoreReplaysWholeScopeAndClearsStagingWithoutMovingHead() async throws {
    let f = try await CheckpointFixture.make(); defer { f.cleanup() }
    try f.write("removed-by-target", "Tracked old file\n")
    try f.write(".gitignore", "ignored.txt\n")
    try await f.commitAll()
    try f.write("tracked.txt", "Reviewed target bytes\n")
    try f.write("saved-untracked", "Saved untracked bytes\n")
    try FileManager.default.removeItem(at: f.repository.appendingPathComponent("removed-by-target"))
    let target = try await restoreSaved(f)
    try f.write("tracked.txt", "Later staged bytes\n")
    try f.write("new-staged", "Later staged addition\n")
    _ = try await f.run(["add", "--all"])
    try f.write("tracked.txt", "Later working bytes\n")
    try f.write("fresh/sub/file", "Nonignored addition\n")
    try f.write("ignored.txt", "Preserve ignored bytes\n")
    let source = try await f.state(), service = f.service(), review = try await service.reviewRestore(target: target)
    #expect(try await f.state() == source)
    #expect(Set(review.affectedPaths).isSuperset(of: ["tracked.txt", "new-staged", "fresh", "fresh/sub/file"]))
    #expect(try await service.inspectRestore(review: review) == .notStarted)
    let receipt = try await service.restore(review: review)
    #expect(try Data(contentsOf: f.repository.appendingPathComponent("tracked.txt")) == Data("Reviewed target bytes\n".utf8))
    #expect(try Data(contentsOf: f.repository.appendingPathComponent("saved-untracked")) == Data("Saved untracked bytes\n".utf8))
    #expect(try Data(contentsOf: f.repository.appendingPathComponent("ignored.txt")) == Data("Preserve ignored bytes\n".utf8))
    for path in ["new-staged", "fresh", "removed-by-target"] { #expect(!FileManager.default.fileExists(atPath: f.repository.appendingPathComponent(path).path)) }
    #expect(try await f.run(["diff", "--cached", "--exit-code"]).status == 0)
    let after = try await f.state()
    #expect(after.head == source.head); #expect(after.branches == source.branches)
    #expect(try await service.inspectRestore(review: review) == .ready(receipt))
    #expect(try await f.service().restore(review: review) == receipt)
    let backup = f.repository.deletingLastPathComponent().appendingPathComponent(".coincide-restore-" + review.id.uuidString + "/recovery/tracked.txt")
    #expect(try Data(contentsOf: backup) == Data("Later working bytes\n".utf8))
}

@Test(.timeLimit(.minutes(1)))
func gitCheckpointRestoreUsesRestoredIgnoreRulesAndPreservesNestedRepository() async throws {
    let f = try await CheckpointFixture.make(); defer { f.cleanup() }
    try f.write(".gitignore", "target-ignored\n")
    let target = try await restoreSaved(f)
    try f.write(".gitignore", "currently-ignored\n")
    try f.write("currently-ignored", "Will become nonignored and removed\n")
    try f.write("target-ignored", "Will become ignored and preserved\n")
    let nested = f.repository.appendingPathComponent("Nested")
    try FileManager.default.createDirectory(at: nested, withIntermediateDirectories: true)
    _ = try await f.run(["init", "--initial-branch=main"], at: nested)
    try Data("Nested repository bytes\n".utf8).write(to: nested.appendingPathComponent("keep"))
    let nestedHead = try Data(contentsOf: nested.appendingPathComponent(".git/HEAD"))
    let service = f.service(), review = try await service.reviewRestore(target: target)
    _ = try await service.restore(review: review)
    #expect(!FileManager.default.fileExists(atPath: f.repository.appendingPathComponent("currently-ignored").path))
    #expect(try Data(contentsOf: f.repository.appendingPathComponent("target-ignored")) == Data("Will become ignored and preserved\n".utf8))
    #expect(try Data(contentsOf: nested.appendingPathComponent("keep")) == Data("Nested repository bytes\n".utf8))
    #expect(try Data(contentsOf: nested.appendingPathComponent(".git/HEAD")) == nestedHead)
}

@Test(.timeLimit(.minutes(1)), arguments: [false, true])
func gitCheckpointRestoreEmptyScopeKeepsDirectoryAndOutsideStaging(unborn: Bool) async throws {
    let f = try await CheckpointFixture.make(initialCommit: !unborn); defer { f.cleanup() }
    let scope = f.repository.appendingPathComponent("Scope")
    try FileManager.default.createDirectory(at: scope, withIntermediateDirectories: true)
    let service = f.service(at: scope), target = try await restoreSaved(f, at: scope)
    try f.write("outside", "Outside staged bytes\n")
    try f.write("Scope/staged", "Remove staged file\n")
    _ = try await f.run(["add", "--all"])
    try f.write("Scope/new-dir/extra", "Remove untracked bytes\n")
    let outsideIndex = try await f.run(["ls-files", "--stage", "-z", "--", "outside"]).output
    let current = try await f.state(), review = try await service.reviewRestore(target: target)
    #expect(try await f.state() == current)
    _ = try await service.restore(review: review)
    #expect(FileManager.default.fileExists(atPath: scope.path))
    #expect(try FileManager.default.contentsOfDirectory(atPath: scope.path).isEmpty)
    #expect(try await f.run(["ls-files", "--stage", "-z", "--", "outside"]).output == outsideIndex)
    #expect(try Data(contentsOf: f.repository.appendingPathComponent("outside")) == Data("Outside staged bytes\n".utf8))
    #expect(try await f.state().head == current.head)
}

@Test(.timeLimit(.minutes(1)))
func gitCheckpointRestorePreservesModesSymlinksNewlineNamesAndUnbornIndexSemantics() async throws {
    let f = try await CheckpointFixture.make(initialCommit: false); defer { f.cleanup() }
    let newline = "line\nfile", executable = f.repository.appendingPathComponent("run")
    try f.write("run", "#!/bin/sh\nexit 0\n"); #expect(chmod(executable.path, 0o755) == 0)
    try f.write(newline, "Exact newline path\n")
    try FileManager.default.createSymbolicLink(atPath: f.repository.appendingPathComponent("link").path, withDestinationPath: newline)
    let target = try await restoreSaved(f)
    try f.write("run", "Modified working bytes\n"); #expect(chmod(executable.path, 0o644) == 0)
    try FileManager.default.removeItem(at: f.repository.appendingPathComponent("link"))
    try f.write("link", "Replaced with regular file\n")
    try f.write(newline, "Other bytes\n")
    let service = f.service(), review = try await service.reviewRestore(target: target)
    _ = try await service.restore(review: review)
    #expect(try FileManager.default.destinationOfSymbolicLink(atPath: f.repository.appendingPathComponent("link").path) == newline)
    #expect(try Data(contentsOf: f.repository.appendingPathComponent(newline)) == Data("Exact newline path\n".utf8))
    var mode = stat(); #expect(lstat(executable.path, &mode) == 0); #expect(mode.st_mode & 0o111 != 0)
    #expect(try await f.run(["rev-parse", "--verify", "HEAD"], succeeds: false).status != 0)
    #expect(try await f.run(["ls-files", "--stage", "--", "run"]).text.hasPrefix("100755 "))
}

@Test(.timeLimit(.minutes(1)), arguments: ["bytes", "index", "head", "symbolic-head", "config", "untracked", "index-lock"])
func gitCheckpointRestoreRejectsStaleReviewedStateBeforeAnyWrite(change: String) async throws {
    let f = try await CheckpointFixture.make(); defer { f.cleanup() }
    let service = f.service(), target = try await restoreSaved(f)
    try f.write("tracked.txt", "Reviewed later bytes\n")
    let review = try await service.reviewRestore(target: target)
    switch change {
    case "bytes": try f.write("tracked.txt", "External writer after review\n")
    case "index": _ = try await f.run(["add", "--", "tracked.txt"])
    case "head": _ = try await f.run(["commit", "--allow-empty", "-m", "Later HEAD"])
    case "symbolic-head":
        _ = try await f.run(["update-ref", "refs/heads/alias", "HEAD"])
        _ = try await f.run(["symbolic-ref", "HEAD", "refs/heads/alias"])
    case "config": _ = try await f.run(["config", "core.filemode", "false"])
    case "index-lock": try Data("Foreign lock bytes\n".utf8).write(to: f.repository.appendingPathComponent(".git/index.lock"))
    default: try f.write("external-new-file", "External new file\n")
    }
    let before = try await f.state()
    let error = try await restoreFailure { _ = try await service.restore(review: review) }
    #expect(!error.mayHaveMutated)
    #expect(try await f.state() == before)
    #expect(!FileManager.default.fileExists(atPath: URL(fileURLWithPath: review.currentPlan.commonDirectoryPath).appendingPathComponent(".coincide-restore-" + review.id.uuidString + "/started.json").path))
}

@Test(.timeLimit(.minutes(1)), arguments: ["missing", "manifest", "receipt", "started"])
func gitCheckpointRestoreInspectionNeverGuessesFromMissingOrAlteredEvidence(change: String) async throws {
    let f = try await CheckpointFixture.make(); defer { f.cleanup() }
    let service = f.service(), target = try await restoreSaved(f)
    try f.write("tracked.txt", "Reviewed current bytes\n")
    let review = try await service.reviewRestore(target: target)
    let metadata = URL(fileURLWithPath: review.currentPlan.commonDirectoryPath).appendingPathComponent(".coincide-restore-" + review.id.uuidString)
    switch change {
    case "missing": try FileManager.default.moveItem(at: metadata, to: metadata.appendingPathExtension("preserved"))
    case "manifest": try Data("{}\n".utf8).write(to: metadata.appendingPathComponent("manifest.json"))
    case "receipt": try Data("{}\n".utf8).write(to: metadata.appendingPathComponent("complete.json"))
    default: try Data((review.manifestDigest + "\n").utf8).write(to: metadata.appendingPathComponent("started.json"))
    }
    let before = try await f.state()
    do { #expect(try await service.inspectRestore(review: review) == .interrupted) }
    catch { #expect(error is GitCheckpointRestoreError) }
    #expect(try await f.state() == before)
}

@Test(.timeLimit(.minutes(1)))
func gitCheckpointRestoreRejectsUsedSmudgeDriverAndNeverRunsHooksOrFilters() async throws {
    let f = try await CheckpointFixture.make(); defer { f.cleanup() }
    try f.write(".gitattributes", "tracked.txt filter=unsafe\n")
    let target = try await restoreSaved(f)
    let sentinel = f.root.appendingPathComponent("must-not-run")
    _ = try await f.run(["config", "filter.unsafe.smudge", "touch '" + sentinel.path + "'; cat"])
    let before = try await f.state()
    let error = try await restoreFailure { _ = try await f.service().reviewRestore(target: target) }
    #expect(error.kind == .unsupportedConfiguration); #expect(!error.mayHaveMutated)
    #expect(!FileManager.default.fileExists(atPath: sentinel.path))
    #expect(try await f.state() == before)
}

@Test(.timeLimit(.minutes(1)))
func gitCheckpointRestoreCancellationAfterFirstWriteIsInterruptedAndRetainsRecoveryBytes() async throws {
    let f = try await CheckpointFixture.make(); defer { f.cleanup() }
    let target = try await restoreSaved(f)
    try f.write("tracked.txt", "Original preimage retained for recovery\n")
    let review = try await f.service().reviewRestore(target: target)
    let started = URL(fileURLWithPath: review.currentPlan.commonDirectoryPath).appendingPathComponent(".coincide-restore-" + review.id.uuidString + "/started.json")
    let reached = f.root.appendingPathComponent("reached"), wrapper = f.root.appendingPathComponent("gated-git")
    try Data("""
    #!/bin/sh
    for argument in "$@"; do
      if [ "$argument" = 'HEAD^{commit}' ] && [ -f "$RESTORE_STARTED" ]; then
        : > "$RESTORE_REACHED"
        while :; do /bin/sleep 1; done
      fi
    done
    exec "$RESTORE_REAL_GIT" "$@"
    """.utf8).write(to: wrapper)
    #expect(chmod(wrapper.path, 0o755) == 0)
    var environment = f.environment
    environment["RESTORE_STARTED"] = started.path; environment["RESTORE_REACHED"] = reached.path; environment["RESTORE_REAL_GIT"] = f.git.path
    let service = GitCheckpointService(root: f.repository, environment: environment, gitExecutable: wrapper)
    let task = Task { try await service.restore(review: review) }
    do { try await restoreEventually { FileManager.default.fileExists(atPath: reached.path) } }
    catch { task.cancel(); _ = await task.result; throw error }
    task.cancel()
    let failure = try await restoreFailure { _ = try await task.value }
    #expect(failure.mayHaveMutated)
    #expect(try await f.service().inspectRestore(review: review) == .interrupted)
    #expect(try Data(contentsOf: f.repository.appendingPathComponent("tracked.txt")) == Data("Committed bytes\n".utf8))
    let recovery = f.repository.deletingLastPathComponent().appendingPathComponent(".coincide-restore-" + review.id.uuidString + "/recovery/tracked.txt")
    #expect(try Data(contentsOf: recovery) == Data("Original preimage retained for recovery\n".utf8))
    #expect(!FileManager.default.fileExists(atPath: f.repository.appendingPathComponent(".git/index.lock").path))
    let retry = try await restoreFailure { _ = try await f.service().restore(review: review) }
    #expect(retry.mayHaveMutated)
}


@Test(.timeLimit(.minutes(1)))
func gitCheckpointRestoreEmptyUnbornCheckpointDoesNotCreateARealIndex() async throws {
    let f = try await CheckpointFixture.make(initialCommit: false); defer { f.cleanup() }
    let target = try await restoreSaved(f)
    try f.write("later-untracked", "Reviewed later bytes\n")
    let service = f.service(), review = try await service.reviewRestore(target: target)
    #expect(review.currentPlan.indexRevision == nil)
    let receipt = try await service.restore(review: review)
    #expect(receipt.finalIndexRevision == nil)
    #expect(!FileManager.default.fileExists(atPath: f.repository.appendingPathComponent(".git/index").path))
    #expect(!FileManager.default.fileExists(atPath: f.repository.appendingPathComponent("later-untracked").path))
    #expect(try await service.inspectRestore(review: review) == .ready(receipt))
}

@Test(.timeLimit(.minutes(1)))
func gitCheckpointRestoreInspectionRequiresThePinnedIdleExecutionLock() async throws {
    let f = try await CheckpointFixture.make(); defer { f.cleanup() }
    let target = try await restoreSaved(f)
    try f.write("tracked.txt", "Later current bytes\n")
    let service = f.service(), review = try await service.reviewRestore(target: target)
    let lockPath = URL(fileURLWithPath: review.currentPlan.commonDirectoryPath).appendingPathComponent(".coincide-restore-" + review.id.uuidString + "/execution.lock")
    let fd = open(lockPath.path, O_RDONLY | O_NOFOLLOW | O_CLOEXEC)
    #expect(fd >= 0); defer { if fd >= 0 { close(fd) } }
    #expect(flock(fd, LOCK_EX | LOCK_NB) == 0)
    let before = try await f.state()
    #expect(try await service.inspectRestore(review: review) == .interrupted)
    let busy = try await restoreFailure { _ = try await service.restore(review: review) }
    #expect(busy.mayHaveMutated)
    #expect(try await f.state() == before)
    #expect(flock(fd, LOCK_UN) == 0)
    #expect(try await service.inspectRestore(review: review) == .notStarted)
    try FileManager.default.moveItem(at: lockPath, to: lockPath.appendingPathExtension("preserved"))
    try Data().write(to: lockPath)
    _ = try await restoreFailure { _ = try await service.inspectRestore(review: review) }
    #expect(try await f.state() == before)
}

@Test(.timeLimit(.minutes(1)))
func gitCheckpointRestoreRejectsAValidJSONCompletionForAnUnreviewedState() async throws {
    let f = try await CheckpointFixture.make(); defer { f.cleanup() }
    let target = try await restoreSaved(f)
    try f.write("tracked.txt", "Pre-restore bytes\n")
    let service = f.service(), review = try await service.reviewRestore(target: target)
    let receipt = try await service.restore(review: review)
    try f.write("tracked.txt", "Unreviewed later bytes\n")
    let directory = try GitWorktreeDirectory(path: review.currentPlan.repositoryPath)
    let nodes = try CheckpointRestoreFiles.scan(directory)
    let altered = try GitCheckpointRestoreReceipt(review: review, finalIndexRevision: receipt.finalIndexRevision, stateDigest: CheckpointRestoreFiles.digest(nodes))
    let record = CheckpointRestoreCompletion(receipt: altered, nodes: nodes)
    let metadata = URL(fileURLWithPath: review.currentPlan.commonDirectoryPath).appendingPathComponent(".coincide-restore-" + review.id.uuidString)
    try CheckpointRestoreFiles.encoded(record).write(to: metadata.appendingPathComponent("complete.json"))
    let before = try await f.state()
    let failure = try await restoreFailure { _ = try await service.inspectRestore(review: review) }
    #expect(failure.kind == .metadataInvalid); #expect(failure.mayHaveMutated)
    #expect(try await f.state() == before)
}

@Test(.timeLimit(.minutes(1)))
func gitCheckpointRestorePreviewUsesCurrentBytesAndListsOmittedLargeChanges() async throws {
    let f = try await CheckpointFixture.make(); defer { f.cleanup() }
    try f.write("tracked.txt", "Reviewed target line\n")
    try f.write("saved-untracked", "Saved target untracked line\n")
    let target = try await restoreSaved(f)
    try f.write("tracked.txt", "Current working line\n")
    try f.write("new-untracked", "Current new untracked line\n")
    try f.write("large", String(repeating: "x", count: 1_048_577))
    let before = try await f.state(), review = try await f.service().reviewRestore(target: target)
    #expect(review.previewPatch.contains("-Current working line"))
    #expect(review.previewPatch.contains("+Reviewed target line"))
    #expect(review.previewPatch.contains("-Current new untracked line"))
    #expect(review.previewPatch.contains("\"a/new-untracked\""))
    #expect(!review.previewPatch.contains(f.root.path))
    #expect(review.previewPatch.utf8.count <= 1_048_576)
    #expect(review.previewTruncated)
    #expect(review.affectedPaths.contains("large"))
    #expect(try await f.state() == before)
}

@Test(.timeLimit(.minutes(1)))
func gitCheckpointRestoreDiscardRemovesOnlyUnusedOwnedCopiesAndKeepsTheReviewAudit() async throws {
    let f = try await CheckpointFixture.make(); defer { f.cleanup() }
    let target = try await restoreSaved(f)
    try f.write("tracked.txt", "Current bytes\n")
    let service = f.service(), review = try await service.reviewRestore(target: target)
    // The user may edit actual files after cancelling review; cleanup still owns
    // only the separately sealed temporary copies, not the changed workspace.
    try f.write("tracked.txt", "External edit retained\n")
    let before = try await f.state()
    let data = f.repository.deletingLastPathComponent().appendingPathComponent(".coincide-restore-" + review.id.uuidString)
    let metadata = URL(fileURLWithPath: review.currentPlan.commonDirectoryPath).appendingPathComponent(".coincide-restore-" + review.id.uuidString)
    #expect(try await service.discardRestoreReview(review) == .removed)
    #expect(try await service.discardRestoreReview(review) == .alreadyRemoved)
    #expect(!FileManager.default.fileExists(atPath: data.path))
    #expect(FileManager.default.fileExists(atPath: metadata.appendingPathComponent("manifest.json").path))
    #expect(!FileManager.default.fileExists(atPath: metadata.appendingPathComponent("git").path))
    #expect(try await f.state() == before)
    let failure = try await restoreFailure { _ = try await service.restore(review: review) }
    #expect(!failure.mayHaveMutated)
}

@Test(.timeLimit(.minutes(1)), arguments: [false, true])
func gitCheckpointRestoreDiscardPreservesUnknownOrChangedScratchAndAllRecovery(afterRestore: Bool) async throws {
    let f = try await CheckpointFixture.make(); defer { f.cleanup() }
    let target = try await restoreSaved(f)
    try f.write("tracked.txt", "Preimage recovery bytes\n")
    let service = f.service(), review = try await service.reviewRestore(target: target)
    let data = f.repository.deletingLastPathComponent().appendingPathComponent(".coincide-restore-" + review.id.uuidString)
    if afterRestore { _ = try await service.restore(review: review) }
    else { try Data("Unknown file must be preserved\n".utf8).write(to: data.appendingPathComponent("unknown")) }
    let before = try await f.state()
    #expect(try await service.discardRestoreReview(review) == .preserved)
    #expect(FileManager.default.fileExists(atPath: data.path))
    if afterRestore { #expect(try Data(contentsOf: data.appendingPathComponent("recovery/tracked.txt")) == Data("Preimage recovery bytes\n".utf8)) }
    else { #expect(try Data(contentsOf: data.appendingPathComponent("unknown")) == Data("Unknown file must be preserved\n".utf8)) }
    #expect(try await f.state() == before)
}


@Test(.timeLimit(.minutes(1)), arguments: [false, true])
func gitCheckpointRestoreRetainsUncertaintyWhenStartedCompletionBecomesSpecialFile(directory: Bool) async throws {
    let f = try await CheckpointFixture.make(); defer { f.cleanup() }
    let target = try await restoreSaved(f)
    try f.write("tracked.txt", "Recovery preimage bytes\n")
    let service = f.service(), review = try await service.reviewRestore(target: target)
    _ = try await service.restore(review: review)
    let metadata = URL(fileURLWithPath: review.currentPlan.commonDirectoryPath).appendingPathComponent(".coincide-restore-" + review.id.uuidString)
    let complete = metadata.appendingPathComponent("complete.json")
    try FileManager.default.removeItem(at: complete)
    if directory { try FileManager.default.createDirectory(at: complete, withIntermediateDirectories: false) }
    else { #expect(mkfifo(complete.path, 0o600) == 0) }
    let before = try await f.state()
    let failure = try await restoreFailure { _ = try await service.restore(review: review) }
    #expect(failure.mayHaveMutated)
    #expect(try await f.state() == before)
    let recovery = f.repository.deletingLastPathComponent().appendingPathComponent(".coincide-restore-" + review.id.uuidString + "/recovery/tracked.txt")
    #expect(try Data(contentsOf: recovery) == Data("Recovery preimage bytes\n".utf8))
    #expect(try await service.discardRestoreReview(review) == .preserved)
}
