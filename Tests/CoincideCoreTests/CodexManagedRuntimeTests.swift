import CryptoKit
import Darwin
import Foundation
import Testing
@testable import CoincideCore

private struct NativeCodexPackageFixture: Sendable {
    let root: URL
    var home: URL { root.appendingPathComponent("chosen-home", isDirectory: true) }
    var log: URL { root.appendingPathComponent("wire.jsonl") }
    init() throws {
        root = try temporaryWorkspace().standardizedFileURL.resolvingSymlinksInPath()
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: false)
    }
    func installer() throws -> CodexInstallation {
        let python = try #require(ProcessChannel.findExecutable("python3")), encoded = Data(root.path.utf8).base64EncodedString()
        let peer = "#!" + python.path + "\n" + """
        import base64, json, os, sys, time
        root = base64.b64decode("\(encoded)").decode()
        log = os.path.join(root, "wire.jsonl")
        def record(method, params=None):
            with open(log,"a") as file:
                file.write(json.dumps({"method":method,"params":params or {},"pid":os.getpid(),"home":os.environ.get("CODEX_HOME")})+"\\n")
        def send(frame): print(json.dumps(frame),flush=True)
        def note(method, params): send({"method":method,"params":{"threadId":"native-configured-thread",**params}})
        if "--version" in sys.argv:
            record("--version"); print("codex-cli 0.156.1"); sys.exit(0)
        if "--help" in sys.argv:
            record("--help"); print("app-server fixture help"); sys.exit(0)
        for line in sys.stdin:
            frame=json.loads(line); method=frame.get("method"); params=frame.get("params",{}); record(method,params)
            value={}
            if method=="initialize": value={"userAgent":"coincide/0.156.1"}
            elif method in ("thread/start","thread/resume"): value={"thread":{"id":"native-configured-thread"}}
            elif method=="turn/start":
                with open(log) as file: number=sum(json.loads(row)["method"]=="turn/start" for row in file)
                turn="native-turn-"+str(number)
                send({"id":frame["id"],"result":{"turn":{"id":turn}}})
                note("turn/started",{"turn":{"id":turn}})
                if number==1:
                    while not os.path.exists(os.path.join(root,"release-first")): time.sleep(.005)
                text=params.get("input",[{}])[0].get("text","")
                note("item/agentMessage/delta",{"turnId":turn,"itemId":"answer-"+turn,"delta":"Native configured reply "+text})
                note("turn/completed",{"turn":{"id":turn,"status":"completed"}})
                continue
            if "id" in frame: send({"id":frame["id"],"result":value})
        """
        let archive = Data("owned synthetic complete Codex package".utf8)
        let release = try CodexManagedRelease(version: "0.156.1", target: "aarch64-apple-darwin",
            url: URL(string: "https://github.com/openai/codex/releases/download/rust-v0.156.1/codex-package-aarch64-apple-darwin.tar.gz")!,
            archiveBytes: Int64(archive.count), sha256: SHA256.hash(data: archive).map { String(format: "%02x", $0) }.joined())
        return .init(rootURL: root.appendingPathComponent("managed", isDirectory: true), release: release,
            downloader: { _, destination, progress in try archive.write(to: destination, options: .withoutOverwriting); progress(Int64(archive.count)) },
            extractor: { release, _, destination in
                for directory in ["bin", "codex-path", "codex-resources"] {
                    try FileManager.default.createDirectory(at: destination.appendingPathComponent(directory), withIntermediateDirectories: false)
                }
                let manifest: JSONValue = .object(["layoutVersion": .number(1), "version": .string(release.version), "target": .string(release.target), "entrypoint": .string("bin/codex")])
                try JSONEncoder().encode(manifest).write(to: destination.appendingPathComponent("codex-package.json"))
                for (name, contents) in [("bin/codex", peer), ("bin/codex-code-mode-host", "#!/bin/sh\nexit 0\n"), ("codex-path/rg", "#!/bin/sh\nexit 0\n")] {
                    let file = destination.appendingPathComponent(name)
                    try Data(contents.utf8).write(to: file)
                    try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: file.path)
                }
                try Data("Complete bundled resource".utf8).write(to: destination.appendingPathComponent("codex-resources/fixture.txt"))
            }, diskSpace: { _ in Int64.max })
    }
    func rows() throws -> [JSONValue] {
        guard FileManager.default.fileExists(atPath: log.path) else { return [] }
        return try Data(contentsOf: log).split(separator: 10).map { try JSONDecoder().decode(JSONValue.self, from: Data($0)) }
    }
    func releaseFirst() throws { try Data().write(to: root.appendingPathComponent("release-first")) }
    func remove() throws {
        for row in try rows() {
            guard case .number(let value) = row["pid"], let pid = Int32(exactly: value), kill(pid, 0) == -1, errno == ESRCH else {
                throw CoincideError("An owned native Codex fixture is still running; its files were preserved.")
            }
        }
        try FileManager.default.removeItem(at: root)
    }
}
private func installNativeCodexFixture(_ service: CodexInstallation) async throws {
    let operation = try service.start()
    try await nativeCodexRuntimeEventually { !service.state().phase.isWorking }
    try await service.cancel(operationID: operation)
    #expect(service.state().phase == .succeeded)
    guard service.state().phase == .succeeded else { throw CoincideError("The synthetic Codex package did not verify.") }
}

@Test func managedCodexProductionFactoryPreservesHomeFIFOAndNativeResumeWithoutPromptReplay() async throws {
    let fixture = try NativeCodexPackageFixture(), installation = try fixture.installer()
    let database = fixture.root.appendingPathComponent("workspace.sqlite")
    let configuration = CodexRuntimeConfiguration(selection: .managed, homeDirectory: fixture.home.path)
    let engine = try WorkspaceEngine(url: database, providerFactory: { try ProviderSessions.make(for: $0, codexInstallation: installation) }, identityResolver: { _ in nil })
    var reopened: WorkspaceEngine?
    do {
        try await installNativeCodexFixture(installation)
        let resolved = try installation.resolve(configuration: configuration)
        let package = try #require(resolved.managedDirectory)
        #expect(try String(contentsOf: package.appendingPathComponent("codex-resources/fixture.txt"), encoding: .utf8) == "Complete bundled resource")
        _ = try await engine.load()
        let project = WorkspaceProject(path: fixture.root.path)
        var thread = CodingThread(project: project, model: "fixture-model"); thread.codexRuntimeConfiguration = configuration
        thread.reasoningEffort = "high"; thread.checkpointPolicy = .disabled
        try await engine.dispatch(.addProject(project)); try await engine.dispatch(.createThread(thread))
        try await engine.dispatch(.submit(threadID: thread.id, text: "first"))
        try await nativeCodexRuntimeEventually { await engine.current().snapshot.threads.first?.activeRun?.nativeTurnID != nil }
        #expect(throws: CodexInstallationError.self) { try installation.remove() }
        try await engine.dispatch(.editThread(thread.id, .permission(.fullAccess)))
        try await engine.dispatch(.submit(threadID: thread.id, text: "second"))
        #expect(await engine.current().snapshot.threads.first?.queuedTurns.first?.configuration.codexRuntimeConfiguration == configuration)
        try fixture.releaseFirst()
        try await nativeCodexRuntimeEventually {
            let state = await engine.current().snapshot.threads.first
            return state?.activeRun == nil && state?.messages.contains { $0.text == "Native configured reply second" } == true
        }
        await engine.shutdown()
        let before = try fixture.rows().filter { $0["method"] == .string("turn/start") }; #expect(before.count == 2)
        #expect(before.allSatisfy { $0["home"] == .string(fixture.home.path) && $0["params"]["effort"] == .string("high") })
        let resumed = try WorkspaceEngine(url: database, providerFactory: { try ProviderSessions.make(for: $0, codexInstallation: installation) }, identityResolver: { _ in nil }); reopened = resumed
        let loaded = try await resumed.load(); #expect(loaded.threads.first?.codexRuntimeConfiguration == configuration)
        #expect(try fixture.rows().filter { $0["method"] == .string("turn/start") }.count == 2)
        try await resumed.dispatch(.submit(threadID: thread.id, text: "third"))
        try await nativeCodexRuntimeEventually {
            let state = await resumed.current().snapshot.threads.first
            return state?.activeRun == nil && state?.messages.contains { $0.text == "Native configured reply third" } == true
        }
        await resumed.shutdown()
        #expect(try fixture.rows().filter { $0["method"] == .string("thread/resume") }.count == 1)
        try installation.remove(); await installation.shutdown(); try fixture.remove()
    } catch {
        try? fixture.releaseFirst(); await reopened?.shutdown(); await engine.shutdown(); await installation.shutdown(); try? fixture.remove(); throw error
    }
}

@Test func managedCodexOldProfileKeepsAdvancedHistoryUnavailableAndRejectsAnotherHomeBeforeSending() async throws {
    let fixture = try NativeCodexPackageFixture(), installation = try fixture.installer()
    var session: (any ProviderSession)?
    do {
        try await installNativeCodexFixture(installation)
        var thread = CodingThread(project: .init(path: fixture.root.path))
        thread.codexRuntimeConfiguration = .init(selection: .managed, homeDirectory: fixture.home.path)
        let native = try #require(ProviderSessions.make(for: thread, codexInstallation: installation) as? CodexSession); session = native
        try await native.connect()
        let capabilities = try await native.historyCapabilities(threadID: "native-configured-thread")
        #expect(!capabilities.canRead && !capabilities.canForkHead && !capabilities.canRevertBeforeTurn)
        thread.codexRuntimeConfiguration = .init(selection: .managed, homeDirectory: fixture.root.appendingPathComponent("another-home").path)
        await #expect(throws: (any Error).self) { try await native.send(text: "Must not reach another home", thread: thread) }
        await native.close()
        let rows = try fixture.rows()
        #expect(!rows.contains { ["turn/start", "thread/read", "thread/fork", "thread/revert"].contains($0["method"].string ?? "") })
        #expect(rows.filter { $0["method"] == .string("--version") }.allSatisfy { $0["home"] != .string(fixture.home.path) })
        try installation.remove(); await installation.shutdown(); try fixture.remove()
    } catch { await session?.close(); await installation.shutdown(); try? fixture.remove(); throw error }
}
