import CryptoKit
import Darwin
import Foundation
import Testing
@testable import CoincideCore

private actor AntigravityInstallGate {
    private(set) var entered = false, returned = false
    private var released = false
    private var waiters: [CheckedContinuation<Void, Never>] = []
    func hold() async { entered = true; if !released { await withCheckedContinuation { waiters.append($0) } } }
    func release() { released = true; for waiter in waiters { waiter.resume() }; waiters = [] }
    func didReturn() { returned = true }
}
private final class AntigravityInstallLog: @unchecked Sendable {
    private let lock = NSLock()
    private var values: [String] = []
    func add(_ value: String) { lock.withLock { values.append(value) } }
    func read() -> [String] { lock.withLock { values } }
}
private struct AntigravityInstallFixture: Sendable {
    let root: URL
    let archive: Data
    let server = Data("#!/usr/bin/python3\nimport sys\nprint('owned fixture ready',flush=True)\nfor line in sys.stdin: pass\n".utf8)
    let harness = Data("#!/bin/sh\nexit 0\n".utf8)
    var managed: URL { root.appendingPathComponent("managed", isDirectory: true) }
    var configuration: AntigravityConfiguration { .init(runtimeSelection: .managed) }
    init(archive: String = "owned-pinned-archive") throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("coincide-agy-install-\(UUID())", isDirectory: true).standardizedFileURL.resolvingSymlinksInPath()
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        self.archive = Data(archive.utf8)
    }
    func release(_ version: String = "fixture-one", archive: Data? = nil) throws -> AntigravityManagedRelease {
        let bytes = archive ?? self.archive
        return try .init(version: version, platform: "darwin", architecture: "arm64", url: URL(string: "https://fixture.invalid/pinned.zip")!,
                         archiveBytes: Int64(bytes.count), sha256: SHA256.hash(data: bytes).map { String(format: "%02x", $0) }.joined(),
                         serverName: "agy_acp_server.par", serverBytes: Int64(server.count), harnessName: "localharness_external", harnessBytes: Int64(harness.count))
    }
    func extract(to directory: URL) throws {
        for (name, bytes) in [("agy_acp_server.par", server), ("localharness_external", harness)] {
            let path = directory.appendingPathComponent(name)
            try bytes.write(to: path, options: .withoutOverwriting)
            try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: path.path)
        }
    }
    func service(release: AntigravityManagedRelease? = nil, data: Data? = nil,
                 log: AntigravityInstallLog = .init(), hold: AntigravityInstallGate? = nil,
                 stage: String? = nil, fail: String? = nil) throws -> AntigravityInstallation {
        let release = try release ?? self.release(), data = data ?? archive
        return .init(rootURL: managed, release: release, downloader: { _, destination, progress in
            log.add("download")
            try data.write(to: destination, options: .withoutOverwriting); progress(Int64(data.count))
            if stage == "download" { await hold?.hold() }
            if fail == "download" { throw CoincideError("Synthetic download fault") }
        }, extractor: { _, _, destination in
            log.add("extract"); try extract(to: destination)
            if stage == "extract" { await hold?.hold() }
            if fail == "extract" { throw CoincideError("Synthetic extraction fault") }
        }, verifier: { _, pair, scratch in
            log.add("verify")
            guard try Data(contentsOf: pair.executable) == server, try Data(contentsOf: pair.harness) == harness,
                  FileManager.default.fileExists(atPath: scratch.path) else { throw CoincideError("Synthetic pair differs") }
            if stage == "verify" { await hold?.hold() }
            if fail == "verify" { throw CoincideError("Synthetic verification fault") }
            if fail == "activate" { try FileManager.default.setAttributes([.posixPermissions: 0o500], ofItemAtPath: managed.path) }
        }, diskSpace: { _ in Int64.max })
    }
    func remove() throws {
        if FileManager.default.fileExists(atPath: managed.path) { try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: managed.path) }
        try FileManager.default.removeItem(at: root)
    }
}
private func antigravityInstallEventually(_ predicate: () async throws -> Bool) async throws {
    let end = ContinuousClock.now + .seconds(5)
    while !(try await predicate()) {
        guard ContinuousClock.now < end else { throw CoincideError("The offline installation boundary was not observed.") }
        try await Task.sleep(for: .milliseconds(5))
    }
}
private func antigravityInstallFinish(_ service: AntigravityInstallation, id: UUID) async throws -> AntigravityInstallationState {
    try await antigravityInstallEventually { !service.state().phase.isWorking }
    try await service.cancel(operationID: id) // Join terminal resource cleanup without replay.
    return service.state()
}

@Test func antigravityManagedManifestPinsExactSixPlatformPairsAndRejectsUnsafeReleaseIdentity() throws {
    let releases = AntigravityManagedRelease.pinned
    #expect(releases.count == 6 && Set(releases.map { $0.platform + "-" + $0.architecture }).count == 6)
    let mac = try #require(releases.first { $0.platform == "darwin" && $0.architecture == "arm64" })
    #expect(mac.version == "1.3.0" && mac.archiveBytes == 111_456_962 && mac.serverBytes == 278_535_456 && mac.harnessBytes == 118_611_392)
    #expect(mac.sha256 == "7cd97045f7b4fe81175a107cdf16f9c51484e3c78a5162cae415338bb6aa5b88")
    #expect(mac.url.absoluteString == "https://dl.google.com/agy-extensions/releases/macos/agy-acp-server-1.3.0-darwin-arm64.zip")
    for value in releases { try value.validate(); #expect(value.requiredFreeBytes > value.archiveBytes + value.serverBytes + value.harnessBytes) }
    #expect(throws: AntigravityInstallationError.self) {
        try AntigravityManagedRelease(version: "bad", platform: "darwin", architecture: "arm64", url: URL(string: "https://fixture.invalid/file?token=forbidden")!, archiveBytes: 1,
                                      sha256: String(repeating: "a", count: 64), serverName: "../server", serverBytes: 1, harnessName: "localharness_external", harnessBytes: 1)
    }
}

@Test func antigravityManagedInstallPublishesOnlyAfterVerificationAndReverificationDoesNotDownload() async throws {
    let fixture = try AntigravityInstallFixture(), log = AntigravityInstallLog(), gate = AntigravityInstallGate()
    let service = try fixture.service(log: log, hold: gate, stage: "verify")
    do {
        let id = try service.start(), coalesced = try service.start(); #expect(coalesced == id)
        try await antigravityInstallEventually { await gate.entered }
        #expect(service.state().phase == .verifying && !FileManager.default.fileExists(atPath: fixture.managed.appendingPathComponent("active.json").path))
        #expect(throws: (any Error).self) { try service.resolve(configuration: fixture.configuration) }
        await gate.release()
        let state = try await antigravityInstallFinish(service, id: id)
        #expect(state.phase == .succeeded && state.downloadedBytes == Int64(fixture.archive.count) && state.installedVersion == "fixture-one")
        let pair = try service.resolve(configuration: fixture.configuration)
        let installedBytes = try Data(contentsOf: pair.executable); #expect(installedBytes == fixture.server)
        let initial = log.read(); #expect(initial == ["download", "extract", "verify"])
        let second = try service.start(), verified = try await antigravityInstallFinish(service, id: second)
        #expect(second != id && verified.phase == .succeeded && log.read() == ["download", "extract", "verify", "verify"])
        let versions = try FileManager.default.contentsOfDirectory(atPath: fixture.managed.appendingPathComponent("versions").path)
        #expect(versions.count == 1 && !versions.contains { $0.hasPrefix(".install-") })
        await service.shutdown(); try fixture.remove()
    } catch { await gate.release(); await service.shutdown(); try? fixture.remove(); throw error }
}

@Test(arguments: ["short", "oversized", "digest", "extract", "verify", "activate"])
func antigravityManagedFailedUpdateKeepsPreviousExactRuntime(_ fault: String) async throws {
    let fixture = try AntigravityInstallFixture(), first = try fixture.service()
    var second: AntigravityInstallation?
    do {
        let id = try first.start(); let initial = try await antigravityInstallFinish(first, id: id); #expect(initial.phase == .succeeded)
        let old = try first.resolve(configuration: fixture.configuration)
        let nextArchive = Data("next-private-pinned-archive".utf8), next = try fixture.release("fixture-two", archive: nextArchive)
        var data = nextArchive
        if fault == "short" { data.removeLast() }
        else if fault == "oversized" { data.append(1) }
        else if fault == "digest" { data = Data(repeating: 42, count: nextArchive.count) }
        let updating = try fixture.service(release: next, data: data, fail: ["extract", "verify", "activate"].contains(fault) ? fault : nil); second = updating
        let update = try updating.start(), state = try await antigravityInstallFinish(updating, id: update)
        #expect(state.phase == .failed && state.installedVersion == "fixture-one")
        if fault == "activate" { try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: fixture.managed.path) }
        let selected = try updating.resolve(configuration: fixture.configuration)
        #expect(selected.executable == old.executable && selected.harness == old.harness)
        let oldBytes = try Data(contentsOf: old.executable); #expect(oldBytes == fixture.server)
        await updating.shutdown(); await first.shutdown(); try fixture.remove()
    } catch { await second?.shutdown(); await first.shutdown(); try? fixture.remove(); throw error }
}

@Test(arguments: ["download", "extract", "verify"])
func antigravityManagedCancellationJoinsOwnedStageAndKeepsPreviousPointer(_ stage: String) async throws {
    let fixture = try AntigravityInstallFixture(), first = try fixture.service(), gate = AntigravityInstallGate()
    var updating: AntigravityInstallation?
    do {
        let seeded = try first.start(); _ = try await antigravityInstallFinish(first, id: seeded)
        let old = try first.resolve(configuration: fixture.configuration), bytes = Data("new cancelled archive".utf8)
        let next = try fixture.service(release: fixture.release("fixture-two", archive: bytes), data: bytes, hold: gate, stage: stage); updating = next
        let id = try next.start(); try await antigravityInstallEventually { await gate.entered }
        let cancellation = Task { try await next.cancel(operationID: id); await gate.didReturn() }
        try await Task.sleep(for: .milliseconds(30))
        let returned = await gate.returned; #expect(!returned)
        await gate.release(); try await cancellation.value
        #expect(next.state().phase == .cancelled)
        let selected = try next.resolve(configuration: fixture.configuration); #expect(selected.executable == old.executable)
        let versions = try FileManager.default.contentsOfDirectory(atPath: fixture.managed.appendingPathComponent("versions").path)
        let originalReleaseID = try fixture.release().sha256
        #expect(versions == [originalReleaseID])
        do { try await next.cancel(operationID: UUID()); Issue.record("A stale operation cancelled the current installer.") }
        catch let error as AntigravityInstallationError { #expect(error.kind == .staleOperation) }
        await next.shutdown(); await first.shutdown(); try fixture.remove()
    } catch { await gate.release(); await updating?.shutdown(); await first.shutdown(); try? fixture.remove(); throw error }
}

@Test func antigravityManagedLeasesKeepRunningOldPairAcrossUpdateAndProtectRemovalAcrossServices() async throws {
    let fixture = try AntigravityInstallFixture(), first = try fixture.service()
    var second: AntigravityInstallation?, process: ProcessChannel?, lease: AntigravityInstallationLease?
    do {
        let seeded = try first.start(); _ = try await antigravityInstallFinish(first, id: seeded)
        let held = try first.acquire(configuration: fixture.configuration); lease = held
        let history = fixture.root.appendingPathComponent("native-account-history", isDirectory: true)
        try FileManager.default.createDirectory(at: history, withIntermediateDirectories: false)
        let historyFile = history.appendingPathComponent("retained-conversation.db")
        try Data("existing account and conversation bytes".utf8).write(to: historyFile)
        let child = try ProcessChannel(executable: held.pair.executable, arguments: [], cwd: fixture.root, eventBufferLimit: 8); process = child
        let pid = child.processIdentifier
        #expect(kill(pid, 0) == 0)
        let bytes = Data("new immutable archive".utf8), next = try fixture.service(release: fixture.release("fixture-two", archive: bytes), data: bytes); second = next
        let id = try next.start(); _ = try await antigravityInstallFinish(next, id: id)
        let current = try next.resolve(configuration: fixture.configuration)
        #expect(current.executable != held.pair.executable && kill(pid, 0) == 0)
        let oldBytes = try Data(contentsOf: held.pair.executable); #expect(oldBytes == fixture.server)
        #expect(throws: AntigravityInstallationError.self) { try next.remove() }
        _ = await child.stopAndDrain(); process = nil
        held.release(); held.release(); lease = nil
        #expect(kill(pid, 0) < 0 && errno == ESRCH)
        #expect(throws: AntigravityInstallationError.self) { try next.remove(protectedCustomPaths: [held.pair.executable.path]) }
        try next.remove()
        #expect(!FileManager.default.fileExists(atPath: fixture.managed.path) && next.state().phase == .idle)
        let retained = try String(contentsOf: historyFile, encoding: .utf8); #expect(retained == "existing account and conversation bytes")
        await next.shutdown(); await first.shutdown(); try fixture.remove()
    } catch { _ = await process?.stopAndDrain(); lease?.release(); await second?.shutdown(); await first.shutdown(); try? fixture.remove(); throw error }
}

@Test func antigravityManagedExternalAliasUsesExactCompletionLeaseAndCorruptActiveNeverFallsBack() async throws {
    let fixture = try AntigravityInstallFixture(), service = try fixture.service()
    do {
        let id = try service.start(); _ = try await antigravityInstallFinish(service, id: id)
        let pair = try service.resolve(configuration: fixture.configuration)
        let external = AntigravityConfiguration(executable: pair.executable.path, harnessPath: pair.harness.path)
        let lease = try service.acquire(configuration: external)
        let releaseID = try fixture.release().sha256; #expect(lease.releaseID == releaseID)
        #expect(throws: AntigravityInstallationError.self) { try service.remove() }; lease.release()
        try Data("invalid active metadata".utf8).write(to: fixture.managed.appendingPathComponent("active.json"))
        #expect(throws: (any Error).self) { try service.resolve(configuration: fixture.configuration) }
        let stillOwned = try service.resolve(configuration: external); #expect(stillOwned.executable == pair.executable)
        // Removing a missing member is explicit cleanup of a known owned
        // completion, never a fallback to another runtime on PATH.
        try FileManager.default.removeItem(at: pair.harness)
        #expect(throws: (any Error).self) { try service.resolve(configuration: external) }
        try service.remove(); await service.shutdown(); try fixture.remove()
    } catch { await service.shutdown(); try? fixture.remove(); throw error }
}

@Test func antigravityManagedUnknownFoldersAndChangedBinaryProofArePreserved() async throws {
    let fixture = try AntigravityInstallFixture(), service = try fixture.service()
    do {
        let id = try service.start(); _ = try await antigravityInstallFinish(service, id: id)
        let pair = try service.resolve(configuration: fixture.configuration)
        try fixture.server.write(to: pair.executable) // Same bytes, new write-era proof.
        try FileManager.default.setAttributes([.modificationDate: Date(timeIntervalSince1970: 1)], ofItemAtPath: pair.executable.path)
        #expect(throws: (any Error).self) { try service.resolve(configuration: fixture.configuration) }
        let unknown = fixture.managed.appendingPathComponent("versions/unknown-user-directory", isDirectory: true)
        try FileManager.default.createDirectory(at: unknown, withIntermediateDirectories: false)
        let sentinel = unknown.appendingPathComponent("preserve.txt"); try Data("unowned".utf8).write(to: sentinel)
        #expect(throws: (any Error).self) { try service.remove() }
        let preserved = try String(contentsOf: sentinel, encoding: .utf8); #expect(preserved == "unowned")
        #expect(FileManager.default.fileExists(atPath: pair.executable.path))
        await service.shutdown(); try fixture.remove()
    } catch { await service.shutdown(); try? fixture.remove(); throw error }
}

@Test func antigravityManagedLeaseDeinitReleasesAndUnownedRootIsNeverAdopted() async throws {
    let fixture = try AntigravityInstallFixture(), service = try fixture.service()
    do {
        let id = try service.start(); _ = try await antigravityInstallFinish(service, id: id)
        var lease: AntigravityInstallationLease? = try service.acquire(configuration: fixture.configuration)
        #expect(lease?.releaseID != nil)
        lease = nil
        try service.remove()
        try FileManager.default.createDirectory(at: fixture.managed, withIntermediateDirectories: false)
        let sentinel = fixture.managed.appendingPathComponent("not-owned.txt"); try Data("preserve".utf8).write(to: sentinel)
        #expect(throws: AntigravityInstallationError.self) { try service.start() }
        #expect(throws: AntigravityInstallationError.self) { try service.remove() }
        let retained = try String(contentsOf: sentinel, encoding: .utf8); #expect(retained == "preserve")
        #expect(!FileManager.default.fileExists(atPath: fixture.managed.appendingPathComponent("versions").path))
        await service.shutdown(); try fixture.remove()
    } catch { await service.shutdown(); try? fixture.remove(); throw error }
}

@Test(arguments: [false, true])
func antigravityManagedOwnerRecordReplacementDuringVerificationCannotPublish(_ changeOwner: Bool) async throws {
    let fixture = try AntigravityInstallFixture(), first = try fixture.service(), gate = AntigravityInstallGate()
    var second: AntigravityInstallation?
    do {
        let seeded = try first.start(); _ = try await antigravityInstallFinish(first, id: seeded)
        let originalPair = try first.resolve(configuration: fixture.configuration)
        let activePath = fixture.managed.appendingPathComponent("active.json"), active = try Data(contentsOf: activePath)
        let ownerPath = fixture.managed.appendingPathComponent(".coincide-antigravity-installation.json")
        let originalOwner = try Data(contentsOf: ownerPath)
        let replacement: Data
        if changeOwner {
            var fields = try JSONDecoder().decode(JSONValue.self, from: originalOwner).object ?? [:]
            fields["id"] = .string(UUID().uuidString)
            replacement = try JSONEncoder().encode(JSONValue.object(fields))
        } else { replacement = originalOwner }
        let archive = Data("next release blocked by replaced owner record".utf8)
        let next = try fixture.service(release: fixture.release("fixture-two", archive: archive), data: archive, hold: gate, stage: "verify"); second = next
        let operation = try next.start(); try await antigravityInstallEventually { await gate.entered }
        // Atomic replacement changes inode even when its content is identical.
        try replacement.write(to: ownerPath, options: .atomic)
        await gate.release()
        let state = try await antigravityInstallFinish(next, id: operation)
        #expect(state.phase == .failed && state.installedVersion == "fixture-one")
        let retainedOwner = try Data(contentsOf: ownerPath), retainedActive = try Data(contentsOf: activePath)
        let originalBytes = try Data(contentsOf: originalPair.executable)
        #expect(retainedOwner == replacement && retainedActive == active && originalBytes == fixture.server)
        let blockedRelease = try fixture.release("fixture-two", archive: archive)
        #expect(!FileManager.default.fileExists(atPath: fixture.managed.appendingPathComponent("versions/" + blockedRelease.sha256).path))
        if !changeOwner {
            let selected = try next.resolve(configuration: fixture.configuration); #expect(selected.executable == originalPair.executable)
        }
        await next.shutdown(); await first.shutdown(); try fixture.remove()
    } catch { await gate.release(); await second?.shutdown(); await first.shutdown(); try? fixture.remove(); throw error }
}

@Test func antigravityManagedInsufficientDiskSpaceNeverDownloadsAndExternalPairSurvivesRemoval() async throws {
    let fixture = try AntigravityInstallFixture(), log = AntigravityInstallLog()
    let release = try fixture.release()
    let service = AntigravityInstallation(rootURL: fixture.managed, release: release,
        downloader: { _, _, _ in log.add("unexpected download") }, extractor: { _, _, _ in }, verifier: { _, _, _ in }, diskSpace: { _ in 0 })
    do {
        let externalRoot = fixture.root.appendingPathComponent("external", isDirectory: true)
        try FileManager.default.createDirectory(at: externalRoot, withIntermediateDirectories: false); try fixture.extract(to: externalRoot)
        let external = AntigravityConfiguration(executable: externalRoot.appendingPathComponent("agy_acp_server.par").path)
        let id = try service.start(), state = try await antigravityInstallFinish(service, id: id)
        #expect(state.phase == .failed && log.read().isEmpty)
        let pair = try service.resolve(configuration: external)
        try service.remove(protectedCustomPaths: [pair.executable.path])
        let externalBytes = try Data(contentsOf: pair.executable); #expect(externalBytes == fixture.server)
        #expect(throws: AntigravityInstallationError.self) { try service.resolve(configuration: .init(executable: pair.executable.path, harnessPath: pair.executable.path)) }
        await service.shutdown(); try fixture.remove()
    } catch { await service.shutdown(); try? fixture.remove(); throw error }
}
