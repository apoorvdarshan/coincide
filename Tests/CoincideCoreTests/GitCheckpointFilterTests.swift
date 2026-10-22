import Darwin
import Foundation
import Testing
@testable import CoincideCore

private func expectUsedFilterRejected(_ fixture: CheckpointFixture) async throws {
    let service = fixture.service(), plan = try await service.prepare(), before = try await fixture.state()
    do { _ = try await service.capture(plan); Issue.record("A capture requiring an executable filter unexpectedly succeeded") }
    catch let error as GitCheckpointError { #expect(error.kind == .unsupportedConfiguration) }
    #expect(try await fixture.state() == before)
    #expect(try await fixture.run(["rev-parse", "--verify", plan.reference], succeeds: false).status != 0)
}

@Test(.timeLimit(.minutes(1)))
func gitCheckpointUnusedGlobalLFSFiltersNeverRunAndDoNotBlockOrdinarySnapshots() async throws {
    var fixture = try await CheckpointFixture.make(); defer { fixture.cleanup() }
    let global = fixture.root.appendingPathComponent("global.gitconfig")
    let sentinel = fixture.root.appendingPathComponent("unused-lfs-must-not-run")
    for key in ["filter.lfs.clean", "filter.lfs.process"] {
        _ = try await fixture.run(["config", "--file", global.path, key, "touch '" + sentinel.path + "'"])
    }
    _ = try await fixture.run(["config", "--file", global.path, "filter.lfs.required", "true"])
    fixture.environment["GIT_CONFIG_GLOBAL"] = global.path
    try fixture.write(".gitattributes", "*.bin filter=lfs\n")
    try fixture.write("tracked.txt", "Ordinary text working bytes\n")
    try fixture.write("new.txt", "New text working bytes\n")
    let before = try await fixture.state(), service = fixture.service()
    let receipt = try await service.capture(service.prepare())
    #expect(try await fixture.blob(receipt, "tracked.txt") == Data("Ordinary text working bytes\n".utf8))
    #expect(try await fixture.blob(receipt, "new.txt") == Data("New text working bytes\n".utf8))
    #expect(!FileManager.default.fileExists(atPath: sentinel.path))
    #expect(try await fixture.state() == before)
    #expect(try await service.finalizeScratch(receipt) == .removed)
}

@Test(.timeLimit(.minutes(1)))
func gitCheckpointFilterClassificationUsesScratchHEADFallbackRatherThanDifferentStagedAttributes() async throws {
    let fixture = try await CheckpointFixture.make(); defer { fixture.cleanup() }
    try fixture.write(".gitattributes", "*.txt filter=fixture\n")
    try await fixture.commitAll()
    try fixture.write(".gitattributes", "*.txt -filter\n")
    _ = try await fixture.run(["add", "--", ".gitattributes"])
    try FileManager.default.removeItem(at: fixture.repository.appendingPathComponent(".gitattributes"))
    let sentinel = fixture.root.appendingPathComponent("fallback-filter-must-not-run")
    _ = try await fixture.run(["config", "filter.fixture.clean", "touch '" + sentinel.path + "'"])
    try await expectUsedFilterRejected(fixture)
    #expect(!FileManager.default.fileExists(atPath: sentinel.path))
}

@Test(.timeLimit(.minutes(1)), arguments: ["ignored-addition", "removed-from-real-index"])
func gitCheckpointFilterClassificationIncludesBothRealAndScratchIndexCandidates(scope: String) async throws {
    let fixture = try await CheckpointFixture.make(); defer { fixture.cleanup() }
    if scope == "ignored-addition" {
        try fixture.write(".gitignore", "ignored.bin\n")
        try await fixture.commitAll()
        try fixture.write("ignored.bin", "Tracked ignored working bytes\n")
        _ = try await fixture.run(["add", "--force", "--", "ignored.bin"])
        try fixture.write(".gitattributes", "*.bin filter=fixture\n")
    } else {
        try fixture.write(".gitignore", "tracked.txt\n")
        try await fixture.commitAll()
        _ = try await fixture.run(["rm", "--cached", "--", "tracked.txt"])
        try fixture.write(".gitattributes", "*.txt filter=fixture\n")
    }
    let sentinel = fixture.root.appendingPathComponent("candidate-filter-must-not-run")
    _ = try await fixture.run(["config", "filter.fixture.process", "touch '" + sentinel.path + "'"])
    try await expectUsedFilterRejected(fixture)
    #expect(!FileManager.default.fileExists(atPath: sentinel.path))
}

@Test(.timeLimit(.minutes(1)))
func gitCheckpointAttributeRaceCannotExecuteAnInitiallyUnusedFilterOrPublishItsRawCapture() async throws {
    var fixture = try await CheckpointFixture.make(); defer { fixture.cleanup() }
    let started = fixture.root.appendingPathComponent("add-started"), release = fixture.root.appendingPathComponent("add-release")
    let sentinel = fixture.root.appendingPathComponent("attribute-race-filter-must-not-run"), wrapper = fixture.root.appendingPathComponent("attribute-gated-git")
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
    _ = try await fixture.run(["config", "filter.fixture.clean", "touch '" + sentinel.path + "'"])
    fixture.environment["COINCIDE_CHECKPOINT_STARTED"] = started.path
    fixture.environment["COINCIDE_CHECKPOINT_RELEASE"] = release.path
    fixture.environment["COINCIDE_REAL_GIT"] = fixture.git.path
    let service = fixture.service(executable: wrapper), plan = try await service.prepare()
    let task = Task { try await service.capture(plan) }
    do {
        let deadline = ContinuousClock.now + .seconds(8)
        while !FileManager.default.fileExists(atPath: started.path) {
            guard ContinuousClock.now < deadline else { throw CoincideError("The attribute-race fixture did not reach add.") }
            try await Task.sleep(for: .milliseconds(10))
        }
        try fixture.write(".gitattributes", "*.txt filter=fixture\n")
        try fixture.write("tracked.txt", "Concurrent working bytes\n")
        let before = try await fixture.state()
        try Data().write(to: release)
        do { _ = try await task.value; Issue.record("A used filter appeared during capture but was not rejected") }
        catch let error as GitCheckpointError { #expect(error.kind == .unsupportedConfiguration) }
        #expect(!FileManager.default.fileExists(atPath: sentinel.path))
        #expect(try await fixture.state() == before)
        #expect(try await fixture.service().inspect(plan) == .incomplete)
        #expect(try await fixture.run(["rev-parse", "--verify", plan.reference], succeeds: false).status != 0)
    } catch {
        task.cancel(); try? Data().write(to: release); _ = await task.result; throw error
    }
}
