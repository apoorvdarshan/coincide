import CryptoKit
import Darwin
import Foundation
import Testing
@testable import CoincideCore

private actor CodexInstallGate {
    private(set) var entered = false, returned = false
    private var released = false
    private var pending: [CheckedContinuation<Void, Never>] = []
    func hold() async { entered = true; if !released { await withCheckedContinuation { pending.append($0) } } }
    func release() { released = true; for waiter in pending { waiter.resume() }; pending = [] }
    func didReturn() { returned = true }
}
private struct CodexInstallFixture: Sendable {
    let root: URL
    var managed: URL { root.appendingPathComponent("managed", isDirectory: true) }
    var configuration: CodexRuntimeConfiguration { .init(selection: .managed) }
    init() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("coincide-codex-install-\(UUID())", isDirectory: true).standardizedFileURL.resolvingSymlinksInPath()
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
    }
    func archive(_ version: String) -> Data { Data("task-owned synthetic pinned package \(version)".utf8) }
    func release(_ version: String = "0.156.1") throws -> CodexManagedRelease {
        let bytes = archive(version), target = "aarch64-apple-darwin"
        return try .init(version: version, target: target, url: URL(string: "https://github.com/openai/codex/releases/download/rust-v\(version)/codex-package-\(target).tar.gz")!,
                         archiveBytes: Int64(bytes.count), sha256: SHA256.hash(data: bytes).map { String(format: "%02x", $0) }.joined())
    }
    func package(_ directory: URL, version: String, missing: Bool = false) throws {
        for path in ["bin", "codex-path", "codex-resources/voice/plugins"] { try FileManager.default.createDirectory(at: directory.appendingPathComponent(path), withIntermediateDirectories: true) }
        let script = """
        #!/usr/bin/python3
        import json, os, sys
        with open(\(String(reflecting: root.appendingPathComponent("wire.jsonl").path)), "a") as file:
            file.write(json.dumps({"argv": sys.argv[1:], "invoked": sys.argv[0], "home": os.environ.get("CODEX_HOME"), "credentialPresent": bool(os.environ.get("OPENAI_API_KEY") or os.environ.get("ACCESS_TOKEN")), "pid": os.getpid()}) + "\\n")
        if sys.argv[1:] == ["--version"]:
            print("codex-cli \(version)", flush=True)
        elif sys.argv[1:] == ["app-server", "--help"]:
            print("Synthetic app-server help", flush=True)
        else:
            print("Owned synthetic process", flush=True)
            for line in sys.stdin: pass
        """
        try Data((script + "\n").utf8).write(to: directory.appendingPathComponent("bin/codex"))
        for path in ["bin/codex-code-mode-host", "codex-path/rg"] {
            if missing && path == "bin/codex-code-mode-host" { continue }
            try Data("#!/bin/sh\nexit 0\n".utf8).write(to: directory.appendingPathComponent(path))
        }
        for path in ["bin/codex", "bin/codex-code-mode-host", "codex-path/rg"] where FileManager.default.fileExists(atPath: directory.appendingPathComponent(path).path) {
            try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: directory.appendingPathComponent(path).path)
        }
        try Data("voice resource bytes".utf8).write(to: directory.appendingPathComponent("codex-resources/voice/plugins/helper.dylib"))
        try Data("retained package license".utf8).write(to: directory.appendingPathComponent("LICENSE"))
        let manifest = JSONValue.object(["layoutVersion": .number(1), "version": .string(version), "target": .string("aarch64-apple-darwin"), "entrypoint": .string("bin/codex")])
        try JSONEncoder().encode(manifest).write(to: directory.appendingPathComponent("codex-package.json"))
    }
    func service(_ version: String = "0.156.1", fault: String? = nil, gate: CodexInstallGate? = nil, hold: String? = nil) throws -> CodexInstallation {
        .init(rootURL: managed, release: try release(version), downloader: { _, path, progress in
            var bytes = archive(version)
            if fault == "short" { bytes.removeLast() }
            else if fault == "digest" { bytes = Data(repeating: 1, count: bytes.count) }
            try bytes.write(to: path, options: .withoutOverwriting); progress(Int64(bytes.count))
            if hold == "download" { await gate?.hold() }
        }, extractor: { _, _, path in
            try package(path, version: version, missing: fault == "missing-host")
            if hold == "extract" { await gate?.hold() }
        }, verifier: { release, executable, scratch in
            if hold == "verify" { await gate?.hold() }
            if fault == "verify" { throw CodexInstallationError(.verificationFailed) }
            try await CodexInstallationVerifier.verify(release: release, executable: executable, scratch: scratch)
        }, diskSpace: { _ in Int64.max })
    }
    func rows() throws -> [JSONValue] {
        let path = root.appendingPathComponent("wire.jsonl")
        guard FileManager.default.fileExists(atPath: path.path) else { return [] }
        let data = try Data(contentsOf: path); guard let last = data.lastIndex(of: 10) else { return [] }
        return try data[...last].split(separator: 10).map { try JSONDecoder().decode(JSONValue.self, from: Data($0)) }
    }
    func remove() throws { try FileManager.default.removeItem(at: root) }
}
private func codexInstallEventually(_ predicate: () async throws -> Bool) async throws {
    let deadline = ContinuousClock.now + .seconds(5)
    while !(try await predicate()) { guard ContinuousClock.now < deadline else { throw CoincideError("The offline Codex installation boundary was not observed.") }; try await Task.sleep(for: .milliseconds(5)) }
}
private func codexInstallFinish(_ service: CodexInstallation, _ id: UUID) async throws -> CodexInstallationState {
    try await codexInstallEventually { !service.state().phase.isWorking }; try await service.cancel(operationID: id); return service.state()
}

@Test func codexManagedManifestPinsCompletePackagesWithoutClaimingNewerProtocolSupport() throws {
    let pinned = CodexManagedRelease.pinned
    #expect(pinned.count == 6 && pinned.allSatisfy { $0.version == "0.156.1" })
    let mac = try #require(pinned.first { $0.target == "aarch64-apple-darwin" })
    #expect(mac.archiveBytes == 127_394_863 && mac.sha256 == "fea42f9625091f011e38f059da974d52e57ba31831648bb1c7f0b1a385fde547")
    #expect(mac.requiredExecutablePaths == ["bin/codex", "bin/codex-code-mode-host", "codex-path/rg"])
    for release in pinned { try release.validate() }
    #expect(throws: CodexInstallationError.self) { try CodexManagedRelease(version: "0.163.0", target: "aarch64-apple-darwin", url: mac.url, archiveBytes: mac.archiveBytes, sha256: mac.sha256) }
}

@Test func codexManagedInstallKeepsWholeResourceTreeAndChecksOnlyPrivateHomeVersionAndHelp() async throws {
    let fixture = try CodexInstallFixture(), service = try fixture.service()
    do {
        let id = try service.start(), state = try await codexInstallFinish(service, id)
        #expect(state.phase == .succeeded && state.source == .managed && state.installedVersion == "0.156.1")
        let selected = try service.resolve(configuration: fixture.configuration), directory = try #require(selected.managedDirectory)
        let resource = try String(contentsOf: directory.appendingPathComponent("codex-resources/voice/plugins/helper.dylib"), encoding: .utf8)
        #expect(resource == "voice resource bytes")
        let checked = try await service.inspect(configuration: fixture.configuration)
        #expect(checked.version == "0.156.1" && checked.executable == selected.executable)
        let rows = try fixture.rows()
        #expect(rows.count == 3 && rows.allSatisfy { $0["credentialPresent"] == .bool(false) })
        #expect(rows.map { $0["argv"] } == [.array([.string("--version")]), .array([.string("--version")]), .array([.string("app-server"), .string("--help")])])
        #expect(rows.allSatisfy { $0["home"].string?.contains("home-") == true && $0["home"].string != FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".codex").path })
        for row in rows { if let path = row["home"].string { #expect(!FileManager.default.fileExists(atPath: path)) } }
        let second = try service.start(); let verified = try await codexInstallFinish(service, second); #expect(verified.phase == .succeeded)
        await service.shutdown(); try fixture.remove()
    } catch { await service.shutdown(); try? fixture.remove(); throw error }
}

@Test(arguments: ["short", "digest", "missing-host", "verify"])
func codexManagedFailedUpdatePreservesPreviousCompletePackage(_ fault: String) async throws {
    let fixture = try CodexInstallFixture(), first = try fixture.service()
    var second: CodexInstallation?
    do {
        let id = try first.start(); _ = try await codexInstallFinish(first, id)
        let old = try first.resolve(configuration: fixture.configuration)
        let next = try fixture.service("0.156.2", fault: fault); second = next
        let update = try next.start(), state = try await codexInstallFinish(next, update)
        let selected = try next.resolve(configuration: fixture.configuration)
        #expect(state.phase == .failed && selected == old && state.installedVersion == "0.156.1")
        await next.shutdown(); await first.shutdown(); try fixture.remove()
    } catch { await second?.shutdown(); await first.shutdown(); try? fixture.remove(); throw error }
}

@Test(arguments: ["download", "extract", "verify"])
func codexManagedCancelCoalescesAndJoinsOnlyItsOwnedAttempt(_ stage: String) async throws {
    let fixture = try CodexInstallFixture(), gate = CodexInstallGate(), service = try fixture.service(gate: gate, hold: stage)
    do {
        let id = try service.start(), same = try service.start(); #expect(id == same)
        try await codexInstallEventually { await gate.entered }
        let cancelling = Task { try await service.cancel(operationID: id); await gate.didReturn() }
        try await Task.sleep(for: .milliseconds(30)); let returned = await gate.returned; #expect(!returned)
        await gate.release(); try await cancelling.value
        #expect(service.state().phase == .cancelled)
        let entries = try FileManager.default.contentsOfDirectory(atPath: fixture.managed.appendingPathComponent("versions").path); #expect(entries.isEmpty)
        await service.shutdown(); try fixture.remove()
    } catch { await gate.release(); await service.shutdown(); try? fixture.remove(); throw error }
}

@Test func codexManagedOldProcessAndCustomManagedAliasKeepBinaryLeasedAcrossUpdate() async throws {
    let fixture = try CodexInstallFixture(), first = try fixture.service()
    var next: CodexInstallation?, child: ProcessChannel?, lease: CodexInstallationLease?
    do {
        let seeded = try first.start(); _ = try await codexInstallFinish(first, seeded)
        let held = try first.acquire(configuration: fixture.configuration); lease = held
        let process = try ProcessChannel(executable: held.resolved.executable, arguments: ["--hold"], cwd: fixture.root, eventBufferLimit: 8); child = process
        let updating = try fixture.service("0.156.2"); next = updating
        let id = try updating.start(); _ = try await codexInstallFinish(updating, id)
        let selected = try updating.resolve(configuration: fixture.configuration)
        #expect(selected.executable != held.resolved.executable && kill(process.processIdentifier, 0) == 0)
        #expect(throws: CodexInstallationError.self) { try updating.remove() }
        _ = await process.stopAndDrain(); child = nil; held.release(); lease = nil
        let custom = CodexRuntimeConfiguration(selection: .custom, executable: selected.executable.path)
        var alias: CodexInstallationLease? = try updating.acquire(configuration: custom)
        #expect(alias?.resolved.source == .custom && alias?.releaseID != nil)
        #expect(throws: CodexInstallationError.self) { try updating.remove() }; alias = nil
        #expect(throws: CodexInstallationError.self) { try updating.remove(protectedCustomPaths: [selected.executable.path]) }
        try updating.remove(); await updating.shutdown(); await first.shutdown(); try fixture.remove()
    } catch { _ = await child?.stopAndDrain(); lease?.release(); await next?.shutdown(); await first.shutdown(); try? fixture.remove(); throw error }
}

@Test func codexExistingCLIInspectionPreservesLauncherNameAndRejectsMutationDuringInspection() async throws {
    let fixture = try CodexInstallFixture(), package = fixture.root.appendingPathComponent("local", isDirectory: true)
    try FileManager.default.createDirectory(at: package, withIntermediateDirectories: false); try fixture.package(package, version: "0.163.0")
    let alias = fixture.root.appendingPathComponent("codex-shim")
    try FileManager.default.createSymbolicLink(at: alias, withDestinationURL: package.appendingPathComponent("bin/codex"))
    let service = CodexInstallation(rootURL: fixture.managed, localResolver: { _ in alias }), gate = CodexInstallGate()
    var second: CodexInstallation?
    do {
        let selected = try service.resolve(configuration: .init()); #expect(selected.executable == alias && selected.source == .existingCLI)
        let observed = try await service.inspect(configuration: .init()); #expect(observed.version == "0.163.0" && observed.executable == alias)
        let rows = try fixture.rows(); #expect(rows.count == 2 && rows.allSatisfy { $0["invoked"] == .string(alias.path) })
        #expect(!FileManager.default.fileExists(atPath: fixture.managed.path))
        let held = CodexInstallation(rootURL: fixture.managed, inspector: { _, _ in await gate.hold(); return "0.163.0" }, localResolver: { _ in alias }); second = held
        let reading = Task { try await held.inspect(configuration: .init()) }
        try await codexInstallEventually { await gate.entered }
        let actual = package.appendingPathComponent("bin/codex")
        let original = try Data(contentsOf: actual); try (original + Data("# Changed while inspection was held\n".utf8)).write(to: actual)
        await gate.release()
        do { _ = try await reading.value; Issue.record("A changed executable passed its earlier runtime inspection.") }
        catch let error as CodexInstallationError { #expect(error.kind == .ownershipLost) }
        await held.shutdown(); await service.shutdown(); try fixture.remove()
    } catch { await gate.release(); await second?.shutdown(); await service.shutdown(); try? fixture.remove(); throw error }
}

@Test func codexManagedInventoryRejectsChangedResourcesAndUnknownContentWithoutDeletingIt() async throws {
    let fixture = try CodexInstallFixture(), service = try fixture.service()
    do {
        let id = try service.start(); _ = try await codexInstallFinish(service, id)
        let resolved = try service.resolve(configuration: fixture.configuration), package = try #require(resolved.managedDirectory)
        let resource = package.appendingPathComponent("codex-resources/voice/plugins/helper.dylib")
        try Data("changed resource bytes".utf8).write(to: resource)
        #expect(throws: CodexInstallationError.self) { try service.resolve(configuration: fixture.configuration) }
        let unknown = package.appendingPathComponent("unknown-user-file"); try Data("preserve me".utf8).write(to: unknown)
        #expect(throws: CodexInstallationError.self) { try service.remove() }
        let retained = try String(contentsOf: unknown, encoding: .utf8); #expect(retained == "preserve me")
        try FileManager.default.removeItem(at: unknown); try FileManager.default.removeItem(at: resource)
        try service.remove() // Explicitly remove an incomplete, still-owned tree.
        await service.shutdown(); try fixture.remove()
    } catch { await service.shutdown(); try? fixture.remove(); throw error }
}
