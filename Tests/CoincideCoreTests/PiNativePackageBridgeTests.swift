import Darwin
import Foundation
import Testing
@testable import CoincideCore

private let nativePiPackageBridgeEnabled = ProcessInfo.processInfo.environment["COINCIDE_NATIVE_PI_PACKAGE_ROOT"] != nil &&
    ProcessInfo.processInfo.environment["COINCIDE_NATIVE_PI_NODE"] != nil

/// Opt-in full-package protocol acceptance. The actual pinned Pi runtime owns
/// its hooks, expansion, agent loop and session entries; only the model
/// stream is synthetic. This proves neither installed account access nor a
/// model-service request. Every process is OS-denied all networking.
@Test(.enabled(if: nativePiPackageBridgeEnabled), .timeLimit(.minutes(1)))
func piNativePackageBridgeExpandsSkillsAndTemplatesProvesSteeringAndStoresOnlyDigestEvidence() async throws {
    let fixture = try NativePiPackageBridgeFixture()
    let engine = try WorkspaceEngine(url: fixture.database, providerFactory: { try makeLegacyNativeAdapterFixtureSession($0) }, identityResolver: { _ in nil })
    do {
        try await saveLegacyProviderFixture(project: fixture.project, threads: [fixture.thread], at: fixture.database)
        _ = try await engine.load()
        let openingText = "Native $alpha $alpha and $beta"
        let firstRun = UUID()
        try await engine.dispatch(.submit(threadID: fixture.thread.id, text: openingText), id: firstRun)
        try await nativePiBridgeEventually("held local model") {
            let current = try await fixture.current(engine)
            let availability = await engine.promptSteeringAvailability(threadID: fixture.thread.id)
            let frames = try fixture.frames()
            return current.activeRun?.id == firstRun && availability.canSteer &&
                frames.contains { $0["kind"] == .string("model-start") && $0["ordinal"] == .number(1) }
        }
        let active = try await fixture.current(engine)
        #expect(active.activeRun?.nativeTurnID == nil && active.activeRun?.configuration == fixture.threadConfiguration)
        let steeringText = "Steer $beta"
        _ = try await engine.steerPrompt(threadID: fixture.thread.id, text: steeringText, expectedRunID: firstRun)
        try await nativePiBridgeEventually("native steering admission") {
            let state = await engine.current().snapshot
            let frames = try fixture.frames()
            return (state.promptSteerings ?? []).contains { $0.threadID == fixture.thread.id && $0.runID == firstRun && $0.phase == .delivered } &&
                frames.filter { $0["kind"] == .string("input") }.count == 2
        }
        let beforeRelease = try await fixture.current(engine)
        #expect(beforeRelease.activeRun?.id == firstRun && beforeRelease.queuedTurns.isEmpty)
        #expect(beforeRelease.runHistory?.first { $0.id == firstRun }?.pi?.inputs.count == 2)
        try FileManager.default.removeItem(at: fixture.hold)
        let first = try await fixture.completed(engine, runID: firstRun)
        let firstProof = try #require(first.pi)
        #expect(firstProof.captureStatus == .proven && firstProof.inputs.count == 2 && first.turnIDs.isEmpty)
        #expect(firstProof.inputs.map(\.kind) == [.opening, .steering])
        #expect(firstProof.inputs.allSatisfy { $0.bridgeReservation != nil && $0.bridgeEvidence != nil })
        #expect(Set(firstProof.inputs.compactMap { $0.bridgeReservation?.nonce }).count == 2)
        let authoredDigests = try [PiHistoryInputEvidence.digest(.init(text: openingText)), PiHistoryInputEvidence.digest(.init(text: steeringText))]
        #expect(firstProof.inputs.map(\.inputDigest) == authoredDigests)
        let initialThread = try await fixture.current(engine)
        let nativeFile = try #require(initialThread.providerThreadID)
        let originalGraph = try fixture.graph(path: nativeFile, sessionID: firstProof.nativeSessionID)
        let firstUsers = originalGraph.entries.filter(\.isUserMessage)
        #expect(firstUsers.count == 2)
        let openingNative = nativePiBridgeText(firstUsers[0])
        #expect(openingNative.components(separatedBy: "COINCIDE_ALPHA_SYNTHETIC_BODY").count - 1 == 1)
        #expect(openingNative.components(separatedBy: "COINCIDE_BETA_SYNTHETIC_BODY").count - 1 == 1)
        #expect(nativePiBridgeText(firstUsers[1]).contains("COINCIDE_BETA_SYNTHETIC_BODY"))
        try fixture.assertMapping(firstProof, graph: originalGraph)

        // These transformations execute in the intact native prompt pipeline,
        // after the app's input hook. No test implementation expands them.
        let templateText = "/native-template argument $alpha"
        let templateRun = try await fixture.submit(engine, templateText)
        let nativeSkillText = "/skill:alpha native argument $alpha $beta"
        let nativeSkillRun = try await fixture.submit(engine, nativeSkillText)
        let final = try await fixture.current(engine)
        let fullGraph = try fixture.graph(path: nativeFile, sessionID: firstProof.nativeSessionID)
        let allUsers = fullGraph.entries.filter(\.isUserMessage)
        #expect(allUsers.count == 4)
        #expect(nativePiBridgeText(allUsers[2]).contains("COINCIDE_NATIVE_TEMPLATE_BODY"))
        #expect(!nativePiBridgeText(allUsers[2]).contains("$ARGUMENTS"))
        #expect(nativePiBridgeText(allUsers[2]).contains("COINCIDE_ALPHA_SYNTHETIC_BODY"))
        #expect(nativePiBridgeText(allUsers[3]).components(separatedBy: "COINCIDE_ALPHA_SYNTHETIC_BODY").count - 1 == 1)
        #expect(nativePiBridgeText(allUsers[3]).components(separatedBy: "COINCIDE_BETA_SYNTHETIC_BODY").count - 1 == 1)
        for id in [templateRun, nativeSkillRun] {
            let proof = try #require(final.runHistory?.first { $0.id == id }?.pi)
            try fixture.assertMapping(proof, graph: fullGraph)
            #expect(proof.inputs.first?.inputDigest != proof.inputs.first?.nativeInputDigest)
        }
        #expect(final.messages.filter { $0.role == .user }.map(\.text) == [openingText, steeringText, templateText, nativeSkillText])

        let database = try WorkspaceDatabase(url: fixture.database)
        let stored = try await database.load(), rebuilt = try await database.rebuildProjection().snapshot
        #expect(stored.threads.first { $0.id == fixture.thread.id }?.runHistory == final.runHistory)
        #expect(rebuilt.threads.first { $0.id == fixture.thread.id }?.runHistory == final.runHistory)
        let journal = try await database.journal(limit: 500)
        #expect(journal.count < 500)
        let journalText = String(decoding: try JSONEncoder().encode(journal), as: UTF8.self)
        for body in ["COINCIDE_ALPHA_SYNTHETIC_BODY", "COINCIDE_BETA_SYNTHETIC_BODY", "COINCIDE_NATIVE_TEMPLATE_BODY"] {
            #expect(!journalText.contains(body))
        }
        try WorkspaceJournal.validate(stored)
        await engine.shutdown()
        try fixture.assertStopped()
        let modelCount = try fixture.frames().filter { $0["kind"] == .string("model-start") }.count
        #expect(modelCount == 4)
        let reopened = try WorkspaceEngine(url: fixture.database, providerFactory: { try makeLegacyNativeAdapterFixtureSession($0) }, identityResolver: { _ in nil })
        _ = try await reopened.load(); await reopened.shutdown()
        let afterReopen = try fixture.frames()
        #expect(afterReopen.filter { $0["kind"] == .string("model-start") }.count == modelCount)
        try fixture.assertStopped()
        try FileManager.default.removeItem(at: fixture.root)
    } catch {
        await engine.shutdown()
        Issue.record("Private native Pi acceptance evidence retained at \(fixture.root.path)")
        throw error
    }
}

private struct NativePiPackageBridgeFixture {
    let root: URL
    let cwd: URL
    let database: URL
    let hold: URL
    let launches: URL
    let project: WorkspaceProject
    let thread: CodingThread
    var threadConfiguration: ProviderConfiguration { .init(thread: thread) }

    init() throws {
        let environment = ProcessInfo.processInfo.environment
        let packagePath = try #require(environment["COINCIDE_NATIVE_PI_PACKAGE_ROOT"])
        let nodePath = try #require(environment["COINCIDE_NATIVE_PI_NODE"])
        let package = URL(fileURLWithPath: packagePath), node = URL(fileURLWithPath: nodePath)
        let manifestData = try Data(contentsOf: package.appendingPathComponent("package.json"))
        guard manifestData.count <= 65_536 else { throw PiHistoryGraphError(.oversized) }
        let manifest = try JSONDecoder().decode(JSONValue.self, from: manifestData)
        guard manifest["name"] == .string("@earendil-works/pi-coding-agent"), manifest["version"] == .string("0.80.5"),
              FileManager.default.isExecutableFile(atPath: node.path), FileManager.default.isExecutableFile(atPath: "/usr/bin/sandbox-exec"),
              FileManager.default.fileExists(atPath: package.appendingPathComponent("dist/cli.js").path) else {
            throw CoincideError("The opt-in test requires the exact private Pi 0.80.5 package, Node and macOS network sandbox.")
        }
        let requested = FileManager.default.temporaryDirectory.appendingPathComponent("coincide-native-pi-bridge-\(UUID())")
        try FileManager.default.createDirectory(at: requested, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        root = URL(fileURLWithPath: try PiRuntimeConfiguration.physical(requested.path))
        cwd = root.appendingPathComponent("Cwd"); database = root.appendingPathComponent("workspace.sqlite")
        hold = root.appendingPathComponent("hold-first-model"); launches = root.appendingPathComponent("launches.jsonl")
        let home = root.appendingPathComponent("Home"), agent = root.appendingPathComponent("Agent")
        let sessions = root.appendingPathComponent("Sessions"), temporary = root.appendingPathComponent("Tmp")
        let resources = root.appendingPathComponent("Resources")
        for directory in [cwd, home, agent, sessions, temporary, resources] {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        }
        for (name, body) in [("alpha", "COINCIDE_ALPHA_SYNTHETIC_BODY"), ("beta", "COINCIDE_BETA_SYNTHETIC_BODY")] {
            let directory = resources.appendingPathComponent(name)
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
            try Data("---\nname: \(name)\ndescription: Private offline acceptance skill\n---\n\(body)\n".utf8)
                .write(to: directory.appendingPathComponent("SKILL.md"), options: .atomic)
        }
        let template = resources.appendingPathComponent("native-template.md")
        try Data("---\ndescription: Private offline acceptance template\n---\nCOINCIDE_NATIVE_TEMPLATE_BODY $ARGUMENTS\n".utf8).write(to: template, options: .atomic)
        let extensionResource = try #require(Bundle.module.url(forResource: "pi_local_model_extension", withExtension: "ts", subdirectory: "Fixtures"))
        let localExtension = root.appendingPathComponent("local-model.ts")
        try FileManager.default.copyItem(at: extensionResource, to: localExtension)
        try JSONEncoder().encode(JSONValue.object(["compaction": .object(["enabled": .bool(false)]), "retry": .object(["enabled": .bool(false)])]))
            .write(to: agent.appendingPathComponent("settings.json"), options: .atomic)
        try Data().write(to: hold)
        FileManager.default.createFile(atPath: launches.path, contents: nil, attributes: [.posixPermissions: 0o600])
        let executable = root.appendingPathComponent("pi-private-package")
        func quote(_ value: String) -> String { "'" + value.replacingOccurrences(of: "'", with: "'\\''") + "'" }
        let launcher = """
        #!/bin/sh
        set -eu
        printf '{"kind":"launch","pid":%s}\\n' "$$" >> \(quote(launches.path))
        fixture_session_dir=\(quote(sessions.path))
        fixture_expects_dir=0
        for fixture_argument do
          if [ "$fixture_expects_dir" = 1 ]; then
            fixture_session_dir="$fixture_argument"
            fixture_expects_dir=0
          elif [ "$fixture_argument" = --session-dir ]; then
            fixture_expects_dir=1
          fi
        done
        exec /usr/bin/env -i \(quote("HOME=" + home.path)) \(quote("TMPDIR=" + temporary.path)) \(quote("PI_CODING_AGENT_DIR=" + agent.path)) \(quote("PI_CODING_AGENT_SESSION_DIR=" + sessions.path)) \(quote("COINCIDE_PI_LOCAL_ROOT=" + root.path)) PATH=/usr/bin:/bin LANG=en_US.UTF-8 PI_OFFLINE=1 PI_SKIP_VERSION_CHECK=1 NO_COLOR=1 /usr/bin/sandbox-exec -p '(version 1) (allow default) (deny network*)' \(quote(node.path)) \(quote(package.appendingPathComponent("dist/cli.js").path)) "$@" --offline --no-tools --no-extensions --no-skills --no-prompt-templates --no-themes --no-context-files --extension \(quote(localExtension.path)) --skill \(quote(resources.appendingPathComponent("alpha/SKILL.md").path)) --skill \(quote(resources.appendingPathComponent("beta/SKILL.md").path)) --prompt-template \(quote(template.path)) --provider coincide-local-fixture --model local-stream --thinking off --session-dir "$fixture_session_dir"
        """
        try Data(launcher.utf8).write(to: executable, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: executable.path)
        project = WorkspaceProject(path: cwd.path)
        let id = UUID()
        let runtime = try PiRuntimeConfiguration.capture(workspacePath: project.path, executable: executable.path, instanceID: id,
            environment: ["HOME": home.path, "PI_CODING_AGENT_DIR": agent.path, "PI_CODING_AGENT_SESSION_DIR": sessions.path, "PATH": "/usr/bin:/bin"])
        let selection = PiModelSelection(provider: "coincide-local-fixture", modelID: "local-stream")
        var thread = CodingThread(project: project)
        thread.provider = .pi; thread.permission = .supervised; thread.checkpointPolicy = .disabled
        thread.piConfiguration = .init(instanceID: id, executable: executable.path, model: selection, thinkingLevel: "off", runtime: runtime)
        thread.model = selection.catalogID
        self.thread = thread
    }
    func current(_ engine: WorkspaceEngine) async throws -> CodingThread {
        let snapshot = await engine.current().snapshot
        return try #require(snapshot.threads.first { $0.id == thread.id })
    }
    func completed(_ engine: WorkspaceEngine, runID: UUID) async throws -> ThreadRunRecord {
        try await nativePiBridgeEventually("proven native terminal") {
            let state = try await current(engine)
            return state.activeRun == nil && state.runHistory?.contains { $0.id == runID && $0.status == .completed && $0.pi?.captureStatus == .proven } == true
        }
        let value = try await current(engine)
        return try #require(value.runHistory?.first { $0.id == runID })
    }
    func submit(_ engine: WorkspaceEngine, _ text: String) async throws -> UUID {
        let id = UUID()
        try await engine.dispatch(.submit(threadID: thread.id, text: text), id: id)
        _ = try await completed(engine, runID: id)
        return id
    }
    func graph(path: String, sessionID: String) throws -> PiHistoryGraph {
        try PiHistoryFileReader().read(filePath: path, expectedWorkspacePath: thread.piConfiguration!.runtime!.workspacePath, expectedSessionID: sessionID).graph
    }
    func assertMapping(_ proof: PiRunHistoryEvidence, graph: PiHistoryGraph) throws {
        let final = try #require(proof.finalObservation)
        let reservations = try proof.inputs.map { try #require($0.bridgeReservation) }
        let evidence = try proof.inputs.map { try #require($0.bridgeEvidence) }
        try PiInputBridge.validate(reservations: reservations, evidence: evidence, baseline: proof.preparation.baseline, finalObservation: final)
        for input in proof.inputs {
            let id = try #require(input.nativeUserEntryID), entry = try #require(graph.entry(id: id))
            let nativeDigest = try PiProtocol.inputDigest(entry)
            #expect(nativeDigest == input.nativeInputDigest)
            #expect(input.bridgeEvidence?.marker.id == entry.parentID)
        }
    }
    func frames() throws -> [JSONValue] { try records(root.appendingPathComponent("local-model.jsonl")) }
    func assertStopped() throws {
        let rows = try records(launches)
        for row in rows {
            guard case .number(let number) = row["pid"], let pid = Int32(exactly: number), pid > 0 else { throw PiHistoryGraphError(.invalidEntry) }
            guard kill(pid, 0) == -1 && errno == ESRCH else { throw CoincideError("An exact opt-in Pi package process has not drained.") }
        }
    }
    private func records(_ path: URL) throws -> [JSONValue] {
        guard FileManager.default.fileExists(atPath: path.path) else { return [] }
        let bytes = try Data(contentsOf: path)
        guard bytes.count <= 1_048_576 else { throw PiHistoryGraphError(.oversized) }
        guard let end = bytes.lastIndex(of: 10) else { return [] }
        return try bytes[...end].split(separator: 10).map { try JSONDecoder().decode(JSONValue.self, from: Data($0)) }
    }
}

private func nativePiBridgeText(_ entry: PiHistoryEntry) -> String {
    let content = entry.raw["message"]["content"]
    return content.string ?? content.array?.filter { $0["type"] == .string("text") }.compactMap { $0["text"].string }.joined() ?? ""
}
private func nativePiBridgeEventually(_ boundary: String, _ predicate: () async throws -> Bool) async throws {
    let deadline = ContinuousClock.now + .seconds(12)
    while !(try await predicate()) {
        guard ContinuousClock.now < deadline else { throw CoincideError("The opt-in native Pi package did not reach its " + boundary + " boundary.") }
        try await Task.sleep(for: .milliseconds(10))
    }
}
