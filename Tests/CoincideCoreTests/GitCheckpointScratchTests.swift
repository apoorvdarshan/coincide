import Foundation
import Testing
@testable import CoincideCore

private func scratchIndex(_ plan: GitCheckpointPlan) -> URL {
    URL(fileURLWithPath: plan.gitDirectoryPath).appendingPathComponent(CheckpointFiles.indexName(plan.id))
}

@Test(.timeLimit(.minutes(1)))
func gitCheckpointScratchCleanupRetainsSnapshotsDiffsAndAllUserState() async throws {
    let fixture = try await CheckpointFixture.make(); defer { fixture.cleanup() }
    try fixture.write("tracked.txt", "Unstaged baseline\n")
    try fixture.write("new.txt", "Original untracked\n")
    let userState = try await fixture.state(), service = fixture.service()
    let before = try await service.capture(service.prepare())
    #expect(before.scratchManifestDigest != nil)
    #expect(FileManager.default.fileExists(atPath: scratchIndex(before.plan).path))
    #expect(try await service.finalizeScratch(before) == .removed)
    #expect(try await service.finalizeScratch(before) == .alreadyRemoved)
    #expect(try await fixture.state() == userState)
    #expect(try await service.capture(before.plan) == before)
    #expect(try await service.inspect(before.plan) == .ready(before))
    #expect(!FileManager.default.fileExists(atPath: scratchIndex(before.plan).path))
    #expect(!FileManager.default.fileExists(atPath: fixture.attempt(before.plan).appendingPathComponent("git").path))
    #expect(FileManager.default.fileExists(atPath: fixture.attempt(before.plan).appendingPathComponent("plan.json").path))
    #expect(FileManager.default.fileExists(atPath: fixture.attempt(before.plan).appendingPathComponent("complete.json").path))

    try fixture.write("tracked.txt", "Post-run bytes\n")
    let after = try await service.capture(service.prepare())
    #expect(try await service.finalizeScratch(after) == .removed)
    let diff = try await service.diff(from: before, to: after)
    #expect(diff.patch.contains("-Unstaged baseline"))
    #expect(diff.patch.contains("+Post-run bytes"))
    #expect(try await fixture.blob(before, "new.txt") == Data("Original untracked\n".utf8))
}

@Test(.timeLimit(.minutes(1)), arguments: ["index", "config", "unknown", "symlink", "directory", "lock", "manifest", "missing"])
func gitCheckpointScratchCleanupPreservesChangedOrUnprovenFiles(change: String) async throws {
    let fixture = try await CheckpointFixture.make(); defer { fixture.cleanup() }
    let service = fixture.service(), receipt = try await service.capture(service.prepare())
    let metadata = fixture.attempt(receipt.plan), git = metadata.appendingPathComponent("git"), index = scratchIndex(receipt.plan)
    let foreign = fixture.root.appendingPathComponent("Foreign.txt")
    try Data("Do not modify this file\n".utf8).write(to: foreign)
    let originalIndex = try Data(contentsOf: index)
    switch change {
    case "index": try Data("Foreign index bytes".utf8).write(to: index)
    case "config": try Data("[core]\n\tbare = true\n".utf8).write(to: git.appendingPathComponent("config"))
    case "unknown": try Data("Unknown private file".utf8).write(to: git.appendingPathComponent("unrecognized"))
    case "symlink":
        try FileManager.default.removeItem(at: git.appendingPathComponent("config"))
        try FileManager.default.createSymbolicLink(at: git.appendingPathComponent("config"), withDestinationURL: foreign)
    case "directory":
        let original = metadata.appendingPathComponent("preserved-original")
        try FileManager.default.moveItem(at: git, to: original)
        try FileManager.default.copyItem(at: original, to: git)
    case "lock": try Data().write(to: URL(fileURLWithPath: index.path + ".lock"))
    case "manifest":
        let file = metadata.appendingPathComponent(CheckpointScratch.manifestName)
        var object = try #require(JSONSerialization.jsonObject(with: Data(contentsOf: file)) as? [String: Any])
        object["commit"] = String(repeating: "a", count: 40)
        try JSONSerialization.data(withJSONObject: object).write(to: file)
    case "missing": try FileManager.default.removeItem(at: git.appendingPathComponent("HEAD"))
    default: Issue.record("Unexpected test fixture mutation")
    }
    #expect(try await service.finalizeScratch(receipt) == .preserved)
    #expect(try await service.inspect(receipt.plan) == .ready(receipt))
    #expect(FileManager.default.fileExists(atPath: index.path))
    #expect(FileManager.default.fileExists(atPath: git.path))
    #expect(!FileManager.default.fileExists(atPath: metadata.appendingPathComponent(CheckpointScratch.startedName).path))
    #expect(try Data(contentsOf: foreign) == Data("Do not modify this file\n".utf8))
    if change == "index" { #expect(try Data(contentsOf: index) == Data("Foreign index bytes".utf8)) }
    else { #expect(try Data(contentsOf: index) == originalIndex) }
    if change == "unknown" { #expect(try Data(contentsOf: git.appendingPathComponent("unrecognized")) == Data("Unknown private file".utf8)) }
    if change == "symlink" { #expect(try FileManager.default.destinationOfSymbolicLink(atPath: git.appendingPathComponent("config").path) == foreign.path) }
}

@Test(.timeLimit(.minutes(1)), arguments: ["file", "directory", "index", "everything"])
func gitCheckpointScratchCleanupResumesOnlySealedPartialRemoval(after: String) async throws {
    let fixture = try await CheckpointFixture.make(); defer { fixture.cleanup() }
    let service = fixture.service(), receipt = try await service.capture(service.prepare())
    let metadata = fixture.attempt(receipt.plan), git = metadata.appendingPathComponent("git")
    let digest = try #require(receipt.scratchManifestDigest)
    let marker = CheckpointScratch.Marker(planID: receipt.plan.id, commit: receipt.commit, manifestDigest: digest)
    try JSONEncoder().encode(marker).write(to: metadata.appendingPathComponent(CheckpointScratch.startedName))
    switch after {
    case "file": try FileManager.default.removeItem(at: git.appendingPathComponent("config"))
    case "directory": try FileManager.default.removeItem(at: git.appendingPathComponent("objects"))
    case "index": try FileManager.default.removeItem(at: scratchIndex(receipt.plan))
    case "everything":
        try FileManager.default.removeItem(at: git)
        try FileManager.default.removeItem(at: scratchIndex(receipt.plan))
    default: Issue.record("Unexpected test fixture interruption")
    }
    #expect(try await service.finalizeScratch(receipt) == .removed)
    #expect(try await service.finalizeScratch(receipt) == .alreadyRemoved)
    #expect(try await service.inspect(receipt.plan) == .ready(receipt))
}

@Test(.timeLimit(.minutes(1)))
func gitCheckpointScratchCleanupDoesNotClaimLegacyOrRecreatedScratch() async throws {
    let fixture = try await CheckpointFixture.make(); defer { fixture.cleanup() }
    let service = fixture.service(), receipt = try await service.capture(service.prepare())
    let legacy = try GitCheckpointReceipt(plan: receipt.plan, commit: receipt.commit, tree: receipt.tree, capturedAt: receipt.capturedAt)
    let complete = fixture.attempt(receipt.plan).appendingPathComponent("complete.json")
    try JSONEncoder().encode(legacy).write(to: complete)
    #expect(try JSONDecoder().decode(GitCheckpointReceipt.self, from: Data(contentsOf: complete)) == legacy)
    #expect(try await service.inspect(legacy.plan) == .ready(legacy))
    #expect(try await service.finalizeScratch(legacy) == .preserved)
    #expect(FileManager.default.fileExists(atPath: scratchIndex(legacy.plan).path))
    try JSONEncoder().encode(receipt).write(to: complete)
    #expect(try await service.finalizeScratch(receipt) == .removed)
    try Data("New unrelated file".utf8).write(to: scratchIndex(receipt.plan))
    #expect(try await service.finalizeScratch(receipt) == .preserved)
    #expect(try Data(contentsOf: scratchIndex(receipt.plan)) == Data("New unrelated file".utf8))
}

@Test(.timeLimit(.minutes(1)))
func gitCheckpointScratchCleanupSerializesConcurrentCallersAndHonorsCancellation() async throws {
    let fixture = try await CheckpointFixture.make(); defer { fixture.cleanup() }
    let service = fixture.service(), receipt = try await service.capture(service.prepare())
    let cancelled = Task {
        withUnsafeCurrentTask { $0?.cancel() }
        return try await service.finalizeScratch(receipt)
    }
    do { _ = try await cancelled.value; Issue.record("Cancelled cleanup unexpectedly ran") }
    catch is CancellationError { }
    #expect(FileManager.default.fileExists(atPath: scratchIndex(receipt.plan).path))
    async let first = service.finalizeScratch(receipt)
    async let second = service.finalizeScratch(receipt)
    let results = try await [first, second]
    #expect(results.filter { $0 == .removed }.count == 1)
    #expect(results.filter { $0 == .alreadyRemoved }.count == 1)
}

@Test(.timeLimit(.minutes(1)), arguments: ["changed-file", "new-file", "wrong-marker"])
func gitCheckpointScratchCleanupDoesNotTrustAnInterruptedAttemptWithChangedEvidence(change: String) async throws {
    let fixture = try await CheckpointFixture.make(); defer { fixture.cleanup() }
    let service = fixture.service(), receipt = try await service.capture(service.prepare())
    let metadata = fixture.attempt(receipt.plan), git = metadata.appendingPathComponent("git")
    let marker = CheckpointScratch.Marker(planID: change == "wrong-marker" ? UUID() : receipt.plan.id,
        commit: receipt.commit, manifestDigest: try #require(receipt.scratchManifestDigest))
    try JSONEncoder().encode(marker).write(to: metadata.appendingPathComponent(CheckpointScratch.startedName))
    try FileManager.default.removeItem(at: git.appendingPathComponent("HEAD"))
    let changedFile = git.appendingPathComponent(change == "changed-file" ? "config" : "foreign")
    if change != "wrong-marker" { try Data("Preserve changed evidence".utf8).write(to: changedFile) }
    #expect(try await service.finalizeScratch(receipt) == .preserved)
    #expect(FileManager.default.fileExists(atPath: scratchIndex(receipt.plan).path))
    #expect(FileManager.default.fileExists(atPath: git.appendingPathComponent("global-attributes").path))
    if change != "wrong-marker" { #expect(try Data(contentsOf: changedFile) == Data("Preserve changed evidence".utf8)) }
}

@Test(.timeLimit(.minutes(1)))
func gitCheckpointScratchCleanupRejectsARehashedManifestWithoutTheMatchingDurableReceipt() async throws {
    let fixture = try await CheckpointFixture.make(); defer { fixture.cleanup() }
    let service = fixture.service(), receipt = try await service.capture(service.prepare())
    let metadata = fixture.attempt(receipt.plan), file = metadata.appendingPathComponent(CheckpointScratch.manifestName)
    var object = try #require(JSONSerialization.jsonObject(with: Data(contentsOf: file)) as? [String: Any])
    object["version"] = 2
    let bytes = try JSONSerialization.data(withJSONObject: object)
    try bytes.write(to: file)
    let forged = try GitCheckpointReceipt(plan: receipt.plan, commit: receipt.commit, tree: receipt.tree,
        capturedAt: receipt.capturedAt, scratchManifestDigest: CheckpointFiles.digest(bytes))
    #expect(try await service.finalizeScratch(forged) == .preserved)
    #expect(try await service.inspect(receipt.plan) == .ready(receipt))
    #expect(FileManager.default.fileExists(atPath: scratchIndex(receipt.plan).path))
    #expect(!FileManager.default.fileExists(atPath: metadata.appendingPathComponent(CheckpointScratch.startedName).path))
}

@Test(.timeLimit(.minutes(1)))
func gitCheckpointScratchCleanupIsScopedToTheCapturedLinkedWorktree() async throws {
    let fixture = try await CheckpointFixture.make(); defer { fixture.cleanup() }
    let linked = fixture.root.appendingPathComponent("Linked")
    _ = try await fixture.run(["worktree", "add", "-b", "linked", linked.path])
    let mainService = fixture.service(), linkedService = fixture.service(at: linked)
    let main = try await mainService.capture(mainService.prepare())
    let other = try await linkedService.capture(linkedService.prepare())
    let mainState = try await fixture.state(), linkedState = try await fixture.state(at: linked)
    #expect(try await mainService.finalizeScratch(other) == .preserved)
    #expect(FileManager.default.fileExists(atPath: scratchIndex(other.plan).path))
    #expect(try await linkedService.finalizeScratch(other) == .removed)
    #expect(FileManager.default.fileExists(atPath: scratchIndex(main.plan).path))
    #expect(try await mainService.inspect(main.plan) == .ready(main))
    #expect(try await fixture.state() == mainState)
    #expect(try await fixture.state(at: linked) == linkedState)
    #expect(try await mainService.finalizeScratch(main) == .removed)
}
