import Darwin
import Foundation
import Testing
@testable import CoincideCore

private struct ClaudeRuntimeHistoryFixture: Sendable {
    let root: URL, workspace: URL, configurationDirectory: URL, executable: URL
    var runtime: ClaudeRuntimeConfiguration {
        .init(executable: executable.path, configurationDirectory: configurationDirectory.path, workspacePath: workspace.path)
    }
    var trace: URL { root.appendingPathComponent("capture-wire.jsonl") }
    init() throws {
        let requested = FileManager.default.temporaryDirectory.appendingPathComponent("coincide-claude-runtime-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: requested, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        guard let pointer = requested.path.withCString({ realpath($0, nil) }) else { throw CoincideError("The private Claude runtime fixture is unavailable.") }
        root = URL(fileURLWithPath: String(cString: pointer)); free(pointer)
        workspace = root.appendingPathComponent("Workspace 工作 😀")
        configurationDirectory = root.appendingPathComponent("Private Claude")
        executable = root.appendingPathComponent("synthetic-claude")
        try FileManager.default.createDirectory(at: workspace, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        try FileManager.default.createDirectory(at: configurationDirectory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        guard let source = Bundle.module.url(forResource: "claude_history_capture", withExtension: "py", subdirectory: "Fixtures") else {
            throw CoincideError("The synthetic Claude peer is unavailable.")
        }
        try FileManager.default.copyItem(at: source, to: executable)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: executable.path)
    }
    func thread(model: String = "captured-model", permission: PermissionMode = .supervised) -> CodingThread {
        var result = CodingThread(project: .init(path: workspace.path), model: model)
        result.workspacePath = workspace.path
        result.provider = .claude; result.permission = permission; result.claudeRuntimeConfiguration = runtime
        return result
    }
    func frames() throws -> [JSONValue] {
        guard let data = try? Data(contentsOf: trace) else { return [] }
        // A writer may be between bytes; never treat an incomplete tail as a frame.
        return try data.split(separator: 10, omittingEmptySubsequences: false).dropLast().filter { !$0.isEmpty }.map {
            try JSONDecoder().decode(JSONValue.self, from: Data($0))
        }
    }
    func sourceURL(sessionID: String, runtime: ClaudeRuntimeConfiguration? = nil) throws -> URL {
        let project = configurationDirectory.appendingPathComponent("projects").appendingPathComponent((runtime ?? self.runtime).projectKey)
        try FileManager.default.createDirectory(at: project, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        return project.appendingPathComponent(sessionID + ".jsonl")
    }
    func write(_ records: [JSONValue], to url: URL) throws {
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        var data = Data()
        for record in records { data.append(try encoder.encode(record)); data.append(10) }
        try data.write(to: url); try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
    }
    func row(_ id: String, session: String, parent: String?, role: String = "user", text: String = "Synthetic input") -> JSONValue {
        .object(["type": .string(role), "uuid": .string(id), "sessionId": .string(session),
            "parentUuid": parent.map(JSONValue.string) ?? .null, "cwd": .string(workspace.path), "isSidechain": .bool(false),
            "timestamp": .string("2026-10-23T00:00:00.000Z"),
            "message": .object(["role": .string(role), "content": .string(text)])])
    }
    func cleanup() { try? FileManager.default.removeItem(at: root) }
}

private actor ClaudeRuntimeEventLog {
    var events: [ProviderEvent] = []
    func append(_ event: ProviderEvent) {
        var value = event
        while case .context(_, let inner) = value { value = inner }
        events.append(value)
    }
    func values() -> [ProviderEvent] { events }
    func evidence() -> [ClaudeRunHistoryEvidence] {
        events.compactMap { if case .claudeHistoryEvidence(let value) = $0 { value } else { nil } }
    }
    func completed() -> Bool { events.contains { if case .completed = $0 { true } else { false } } }
}

private func waitForClaudeRuntime(_ predicate: @escaping @Sendable () async throws -> Bool) async throws {
    let deadline = ContinuousClock.now + .seconds(8)
    while !(try await predicate()) {
        guard ContinuousClock.now < deadline else { throw CoincideError("The synthetic Claude runtime did not reach its exact ownership boundary.") }
        try await Task.sleep(for: .milliseconds(5))
    }
}

@Test func claudeRuntimeCapturePreservesRegisteredAliasAndStableNativeNamespaceWithoutLaunching() throws {
    let fixture = try ClaudeRuntimeHistoryFixture(); defer { fixture.cleanup() }
    let alias = fixture.root.appendingPathComponent("Registered Alias")
    try FileManager.default.createSymbolicLink(at: alias, withDestinationURL: fixture.workspace)
    let environment = ["CLAUDE_CONFIG_DIR": fixture.configurationDirectory.path, "CLAUDE_CODE_PROJECT_DIR_NAME": "explicit-native-project"]
    let first = try ClaudeRuntimeConfiguration.capture(workspacePath: alias.path, executable: fixture.executable.path, environment: environment)
    let second = try ClaudeRuntimeConfiguration.capture(workspacePath: alias.path, executable: fixture.executable.path, environment: environment)
    #expect(first == second)
    #expect(first.instanceID == ClaudeRuntimeConfiguration.defaultInstanceID)
    #expect(first.workspacePath == fixture.workspace.path && first.registeredWorkspacePath == alias.path)
    #expect(first.projectDirectoryName == "explicit-native-project")
    #expect(first.projectDirectoryNames.count == 2)
    #expect(!FileManager.default.fileExists(atPath: fixture.trace.path))
    let unavailableDestination = fixture.root.appendingPathComponent("Not Created").path
    let moved = try first.replacingWorkspace(unavailableDestination)
    #expect(moved.workspacePath == unavailableDestination && moved.registeredWorkspacePath == unavailableDestination)
    #expect(moved.executable == first.executable && moved.configurationDirectory == first.configurationDirectory)
    #expect(!FileManager.default.fileExists(atPath: unavailableDestination))
    #expect(throws: CoincideError.self) {
        _ = try ClaudeRuntimeConfiguration.capture(workspacePath: alias.path, executable: fixture.executable.path,
            environment: ["CLAUDE_CONFIG_DIR": fixture.configurationDirectory.path, "CLAUDE_CODE_DISABLE_PRECOMPACT_SKIP": "0"])
    }
    let longPath = "/" + String(repeating: "long-native-component/", count: 14) + "workspace"
    let long = ClaudeRuntimeConfiguration(executable: fixture.executable.path, configurationDirectory: fixture.configurationDirectory.path, workspacePath: longPath)
    try long.validate()
    #expect(long.projectDirectoryName == nil && long.projectKey.count > 200 && long.projectKey.count <= 208)
    let nativeKey = try ClaudeTranscriptStore.projectDirectoryName(forPhysicalWorkspacePath: longPath)
    #expect(nativeKey == long.projectKey)
}

@Test func claudeProspectiveRunInputsMergeOnlyRegisteredMonotonicRootEvidenceAndLeaveLegacyNil() throws {
    let fixture = try ClaudeRuntimeHistoryFixture(); defer { fixture.cleanup() }
    let runID = UUID(), messageID = "user-" + UUID().uuidString, sessionID = UUID().uuidString.lowercased(), assistant = UUID().uuidString.lowercased()
    var registered = try ClaudeRunHistoryEvidence(runID: runID, runtimeIdentity: fixture.runtime.runtimeIdentity)
    let opening = ClaudeInputIdentity.opening(runID: runID), steer = try ClaudeInputIdentity.steering(messageID: messageID)
    #expect(opening == runID.uuidString.lowercased())
    let repeated = try ClaudeInputIdentity.steering(messageID: messageID), other = try ClaudeInputIdentity.steering(messageID: messageID + "-other")
    #expect(steer == repeated && steer != other)
    try registered.registerSteering(messageID: messageID)
    var observed = registered
    try observed.observe(nativeSessionID: sessionID, inputIDs: [opening, steer], rootAssistantMessageID: assistant)
    try observed.finish(.completed)
    let merged = try registered.merging(observed)
    #expect(merged.finalRootAssistantMessageID == assistant && merged.observedInputIDs == [opening, steer])
    #expect(merged.terminalStatus == .completed)
    #expect(throws: CoincideError.self) { _ = try merged.merging(registered) }
    var forged = registered; try forged.registerSteering(messageID: "not-authored")
    #expect(throws: CoincideError.self) { _ = try registered.merging(forged) }
    var unknown = registered
    #expect(throws: CoincideError.self) { try unknown.observe(nativeSessionID: sessionID, inputIDs: [UUID().uuidString]) }
    let legacy = CodingThread(project: .init(path: fixture.workspace.path))
    let old = ThreadRunRecord(run: .init(id: UUID(), configuration: .init(thread: legacy), startedAt: Date()), origin: .user, userMessageID: "legacy-user")
    let encoded = try JSONEncoder().encode(old)
    let rawObject = try JSONSerialization.jsonObject(with: encoded) as? [String: Any]
    let object = try #require(rawObject)
    #expect(old.claude == nil && object["claude"] == nil)
    let captured = fixture.thread()
    let prospective = ThreadRunRecord(run: .init(id: runID, configuration: .init(thread: captured), startedAt: Date()), origin: .user, userMessageID: "new-user")
    #expect(prospective.claude?.openingInputID == opening && prospective.claude?.nativeSessionID == nil)
}

@Test func claudeQueuedCaptureNeverConsumesSelectionAndExplicitProjectOverrideAcceptsProvenLegacyFallback() throws {
    let fixture = try ClaudeRuntimeHistoryFixture(); defer { fixture.cleanup() }
    let runtime = ClaudeRuntimeConfiguration(executable: fixture.executable.path, configurationDirectory: fixture.configurationDirectory.path,
        projectDirectoryName: "explicit-project", workspacePath: fixture.workspace.path)
    let native = UUID().uuidString.lowercased(), input = UUID().uuidString.lowercased(), cursor = UUID().uuidString.lowercased()
    let legacyURL = try fixture.sourceURL(sessionID: native)
    try fixture.write([fixture.row(input, session: native, parent: nil), fixture.row(cursor, session: native, parent: input, role: "assistant")], to: legacyURL)
    let store = try ClaudeTranscriptStore(configurationDirectory: fixture.configurationDirectory, workspace: fixture.workspace, projectDirectoryName: runtime.projectDirectoryName)
    let reviewed = try store.read(sessionID: native)
    let selection = try ClaudeResumeSelection(nativeSessionID: native, cursor: cursor, kind: .resumeAt,
        reviewedLocation: reviewed.location, reviewedRevision: reviewed.revision)
    try selection.validate(runtime: runtime)
    #expect(reviewed.location.projectDirectoryName != runtime.projectKey)
    var thread = fixture.thread(); thread.claudeRuntimeConfiguration = runtime; thread.claudeResumeSelection = selection
    let queuedConfiguration = ProviderConfiguration(thread: thread)
    #expect(queuedConfiguration.claudeRuntimeConfiguration == runtime && queuedConfiguration.claudeLaunchSelection == nil)
    #expect(thread.claudeResumeSelection == selection && thread.claudeResumeConsumerRunID == nil)
}

@Test(.timeLimit(.minutes(1)))
func claudeNativeRuntimeUsesCapturedSettingsAndOuterRootUUIDsForOriginalAndSteeredInputs() async throws {
    let fixture = try ClaudeRuntimeHistoryFixture(); defer { fixture.cleanup() }
    let session = try ClaudeSession(executable: fixture.executable, cwd: fixture.workspace, configuration: fixture.runtime)
    let log = ClaudeRuntimeEventLog(), reader = Task { for await event in session.events { await log.append(event) } }
    do {
        let models = try await session.models()
        #expect(models == [ProviderModel(id: "capture-model", name: "Capture model")])
        let metadataFrames = try fixture.frames(); #expect(!metadataFrames.contains { $0["kind"].string == "input" })
        var thread = fixture.thread(), captured = ProviderConfiguration(thread: fixture.thread())
        captured.model = "captured-old-model"; captured.permission = .supervised
        let runID = UUID(), opening = ClaudeInputIdentity.opening(runID: runID)
        thread.activeRun = .init(id: runID, configuration: captured, startedAt: Date())
        thread.model = "future-header-model"; thread.permission = .fullAccess
        try await session.send(text: "Original 工作 😀", thread: thread)
        try await waitForClaudeRuntime { await log.evidence().last?.rootAssistantMessageIDs == ["eeeeeeee-eeee-4eee-8eee-eeeeeeeeeeee"] }
        #expect(await log.completed() == false)
        // Engine supplies the original run facade; future header edits cannot
        // change direct steering's model/permission or trigger config setters.
        thread.model = captured.model; thread.permission = captured.permission
        thread.providerThreadID = "aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa"; thread.activeRun?.nativeTurnID = opening
        let messageID = "user-" + UUID().uuidString
        let receipt = try await session.steer(input: .init(text: "Exact steer Ω 😀"), thread: thread, expectedTurnID: opening, clientMessageID: messageID)
        #expect(receipt.turnID == opening && [.submitted, .acknowledged].contains(receipt.delivery))
        try await waitForClaudeRuntime { await log.completed() }
        await session.close(); await reader.value
        let finalEvidence = await log.evidence().last, nativeSteer = try ClaudeInputIdentity.steering(messageID: messageID)
        let evidence = try #require(finalEvidence)
        #expect(evidence.runID == runID && evidence.nativeSessionID == thread.providerThreadID)
        #expect(evidence.observedInputIDs == [opening, nativeSteer])
        #expect(evidence.rootAssistantMessageIDs == ["eeeeeeee-eeee-4eee-8eee-eeeeeeeeeeee", "11111111-2222-4333-8444-555555555555"])
        #expect(evidence.terminalStatus == .completed)
        let events = await log.values()
        let proofIndex = try #require(events.firstIndex { if case .claudeHistoryEvidence(let value) = $0 { value.terminalStatus != nil } else { false } })
        let completeIndex = try #require(events.firstIndex { if case .completed = $0 { true } else { false } })
        #expect(proofIndex < completeIndex)
        let frames = try fixture.frames(), inputs = frames.filter { $0["kind"].string == "input" }
        try #require(inputs.count == 2)
        #expect(inputs[0]["uuid"].string == opening)
        #expect(inputs[1]["uuid"].string == nativeSteer && inputs[1]["priority"].string == "now")
        #expect(frames.filter { $0["method"].string == "set_model" }.map { $0["model"].string } == ["captured-old-model"])
        #expect(frames.filter { $0["method"].string == "set_permission_mode" }.map { $0["mode"].string } == ["default"])
        #expect(frames.first?["configRoot"].string == fixture.configurationDirectory.path && frames.first?["precompactDisabled"] == .bool(false))
        #expect(frames.last?["kind"].string == "closed")
        #expect(["sigterm", "eof"].contains(frames.last?["reason"].string ?? ""))
        if case .number(let pid)? = frames.first?["pid"] { #expect(kill(pid_t(pid), 0) == -1 && errno == ESRCH) }
        else { Issue.record("The owned peer did not publish its exact PID.") }
    } catch { await session.close(); await reader.value; throw error }
}

@Test(.timeLimit(.minutes(1)), arguments: [ClaudeResumeSelection.Kind.resumeAt, .freshSession])
func claudeDeferredLaunchUsesExactReviewedSelectionAndRefusesStaleSourceBeforeSpawn(kind: ClaudeResumeSelection.Kind) async throws {
    let fixture = try ClaudeRuntimeHistoryFixture(); defer { fixture.cleanup() }
    let native = UUID().uuidString.lowercased(), opening = UUID().uuidString.lowercased(), cursor = UUID().uuidString.lowercased()
    let store = try ClaudeTranscriptStore(configurationDirectory: fixture.configurationDirectory, workspace: fixture.workspace)
    let sourceURL = try fixture.sourceURL(sessionID: native)
    var rows = [fixture.row(opening, session: native, parent: nil), fixture.row(cursor, session: native, parent: opening, role: "assistant")]
    let selection: ClaudeResumeSelection
    if kind == .resumeAt {
        try fixture.write(rows, to: sourceURL); let source = try store.read(sessionID: native)
        selection = try .init(nativeSessionID: native, cursor: cursor, kind: .resumeAt, reviewedLocation: source.location, reviewedRevision: source.revision)
    } else { selection = try .init(nativeSessionID: native, kind: .freshSession) }
    let session = try ClaudeSession(executable: fixture.executable, cwd: fixture.workspace, configuration: fixture.runtime, launchSelection: selection)
    do { _ = try await session.models(); await session.close() } catch { await session.close(); throw error }
    let frames = try fixture.frames(), arguments = frames.first?["arguments"].array?.compactMap(\.string) ?? []
    #expect(!frames.contains { $0["kind"].string == "input" })
    #expect(!arguments.contains { $0.hasPrefix("--resume-drops-turn") })
    if kind == .resumeAt { #expect(arguments.contains("--resume") && arguments.contains("--resume-session-at=" + cursor) && !arguments.contains("--session-id")) }
    else { #expect(arguments.contains("--session-id") && !arguments.contains("--resume")) }
    rows.append(fixture.row(UUID().uuidString.lowercased(), session: native, parent: cursor))
    try fixture.write(rows, to: sourceURL)
    let before = try Data(contentsOf: fixture.trace)
    #expect(throws: ClaudeTranscriptStoreError.self) {
        _ = try ClaudeSession(executable: fixture.executable, cwd: fixture.workspace, configuration: fixture.runtime, launchSelection: selection)
    }
    let after = try Data(contentsOf: fixture.trace)
    #expect(after == before)
}

@Test(arguments: [false, true])
func claudeDeferredResumeInspectionRequiresExactProspectiveInputAndLiteralSelectedAncestry(fresh: Bool) throws {
    let fixture = try ClaudeRuntimeHistoryFixture(); defer { fixture.cleanup() }
    let native = UUID().uuidString.lowercased(), oldUser = UUID().uuidString.lowercased(), cursor = UUID().uuidString.lowercased()
    let sourceURL = try fixture.sourceURL(sessionID: native), store = try ClaudeTranscriptStore(configurationDirectory: fixture.configurationDirectory, workspace: fixture.workspace)
    let old = [fixture.row(oldUser, session: native, parent: nil), fixture.row(cursor, session: native, parent: oldUser, role: "assistant")]
    let selection: ClaudeResumeSelection
    if fresh { selection = try .init(nativeSessionID: native, kind: .freshSession) }
    else {
        try fixture.write(old, to: sourceURL); let source = try store.read(sessionID: native)
        selection = try .init(nativeSessionID: native, cursor: cursor, kind: .resumeAt, reviewedLocation: source.location, reviewedRevision: source.revision)
    }
    var configuration = ProviderConfiguration(thread: fixture.thread()); configuration.nativeThreadID = native; configuration.claudeLaunchSelection = selection
    let runID = UUID(), input = ClaudeInputIdentity.opening(runID: runID)
    let run = ThreadRunRecord(run: .init(id: runID, configuration: configuration, startedAt: Date()), origin: .user, userMessageID: "user-" + runID.uuidString)
    let untouched = try ClaudeResumeInspection.inspect(configuration: fixture.runtime, selection: selection, run: run)
    #expect(untouched == .notConsumed)
    let inputRow = fixture.row(input, session: native, parent: fresh ? nil : cursor)
    let reply = fixture.row(UUID().uuidString.lowercased(), session: native, parent: input, role: "assistant")
    try fixture.write((fresh ? [] : old) + [inputRow, reply], to: sourceURL)
    let consumed = try ClaudeResumeInspection.inspect(configuration: fixture.runtime, selection: selection, run: run)
    #expect(consumed == .consumed)
    let unrelated = UUID().uuidString.lowercased()
    let bad = fixture.row(input, session: native, parent: unrelated)
    try fixture.write((fresh ? [] : old) + [fixture.row(unrelated, session: native, parent: fresh ? nil : cursor), bad, reply], to: sourceURL)
    #expect(throws: CoincideError.self) { _ = try ClaudeResumeInspection.inspect(configuration: fixture.runtime, selection: selection, run: run) }
}

@Test(.timeLimit(.minutes(1)), arguments: [false, true])
func claudeConfigurationSelectionPreservesDefaultAuthNamespaceAndExactExplicitOverride(explicit: Bool) async throws {
    let fixture = try ClaudeRuntimeHistoryFixture(); defer { fixture.cleanup() }
    let home = fixture.root.appendingPathComponent("Captured HOME"), alias = fixture.root.appendingPathComponent("Explicit Native Alias")
    try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
    try FileManager.default.createSymbolicLink(at: home.appendingPathComponent(".claude"), withDestinationURL: fixture.configurationDirectory)
    try FileManager.default.createSymbolicLink(at: alias, withDestinationURL: fixture.configurationDirectory)
    let rawOverride = alias.path + "/"
    var environment = ["HOME": home.path, "CLAUDE_CODE_PROJECT_DIR_NAME": "explicit-project-only"]
    if explicit { environment["CLAUDE_CONFIG_DIR"] = rawOverride }
    let capture = try ClaudeRuntimeConfiguration.capture(workspacePath: fixture.workspace.path, executable: fixture.executable.path, environment: environment)
    #expect(capture.configurationDirectory == fixture.configurationDirectory.path)
    let expected: ClaudeConfigurationDirectorySelection = explicit ? .explicitDirectory(environmentPath: rawOverride) : .defaultHome(homeDirectory: home.path)
    #expect(capture.configurationDirectorySelection == expected && capture.runtimeIdentity.configurationDirectorySelection == expected)
    #expect(capture.projectDirectoryName == (explicit ? "explicit-project-only" : nil))
    let rebound = try capture.replacingWorkspace(fixture.root.appendingPathComponent("Future Workspace").path)
    #expect(rebound.configurationDirectorySelection == expected)
    let configBytes = try JSONEncoder().encode(capture), identityBytes = try JSONEncoder().encode(capture.runtimeIdentity)
    let reopened = try JSONDecoder().decode(ClaudeRuntimeConfiguration.self, from: configBytes)
    let identity = try JSONDecoder().decode(ClaudeRuntimeIdentity.self, from: identityBytes)
    #expect(reopened == capture && identity == capture.runtimeIdentity)
    let session = try ClaudeSession(executable: fixture.executable, cwd: fixture.workspace, configuration: capture)
    do { _ = try await session.models(); await session.close() } catch { await session.close(); throw error }
    let frames = try fixture.frames(), launch = try #require(frames.first)
    #expect(launch["configPresent"] == .bool(explicit))
    if explicit { #expect(launch["configRoot"].string == rawOverride && launch["projectOverride"].string == "explicit-project-only") }
    else { #expect(launch["configRoot"] == .null && launch["home"].string == home.path && launch["projectOverride"] == .null) }
    #expect(!frames.contains { $0["kind"].string == "input" })
    let trace = try Data(contentsOf: fixture.trace)
    let redirect = fixture.root.appendingPathComponent("Different Native Root")
    try FileManager.default.createDirectory(at: redirect, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
    let selectedLink = explicit ? alias : home.appendingPathComponent(".claude")
    try FileManager.default.removeItem(at: selectedLink)
    try FileManager.default.createSymbolicLink(at: selectedLink, withDestinationURL: redirect)
    #expect(throws: CoincideError.self) { _ = try ClaudeSession(executable: fixture.executable, cwd: fixture.workspace, configuration: capture) }
    let unchangedTrace = try Data(contentsOf: fixture.trace)
    #expect(unchangedTrace == trace)
}

@Test func claudeConfigurationSelectionDistinguishesEqualPhysicalRootsAndDecodesLegacyExplicitCapture() throws {
    let fixture = try ClaudeRuntimeHistoryFixture(); defer { fixture.cleanup() }
    let home = fixture.root.appendingPathComponent("Captured HOME")
    try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
    try FileManager.default.createSymbolicLink(at: home.appendingPathComponent(".claude"), withDestinationURL: fixture.configurationDirectory)
    let defaultCapture = try ClaudeRuntimeConfiguration.capture(workspacePath: fixture.workspace.path, executable: fixture.executable.path,
        environment: ["HOME": home.path])
    let explicitCapture = try ClaudeRuntimeConfiguration.capture(workspacePath: fixture.workspace.path, executable: fixture.executable.path,
        environment: ["HOME": home.path, "CLAUDE_CONFIG_DIR": fixture.configurationDirectory.path])
    #expect(defaultCapture.configurationDirectory == explicitCapture.configurationDirectory)
    #expect(defaultCapture != explicitCapture && defaultCapture.runtimeIdentity != explicitCapture.runtimeIdentity)
    let configEncoded = try JSONEncoder().encode(explicitCapture), identityEncoded = try JSONEncoder().encode(explicitCapture.runtimeIdentity)
    let configObject = try JSONSerialization.jsonObject(with: configEncoded) as? [String: Any]
    let identityObject = try JSONSerialization.jsonObject(with: identityEncoded) as? [String: Any]
    var oldConfig = try #require(configObject), oldIdentity = try #require(identityObject)
    oldConfig.removeValue(forKey: "configurationDirectorySelection"); oldIdentity.removeValue(forKey: "configurationDirectorySelection")
    let oldConfigBytes = try JSONSerialization.data(withJSONObject: oldConfig), oldIdentityBytes = try JSONSerialization.data(withJSONObject: oldIdentity)
    let legacyConfig = try JSONDecoder().decode(ClaudeRuntimeConfiguration.self, from: oldConfigBytes)
    let legacyIdentity = try JSONDecoder().decode(ClaudeRuntimeIdentity.self, from: oldIdentityBytes)
    #expect(legacyConfig.configurationDirectorySelection == .explicitDirectory(environmentPath: explicitCapture.configurationDirectory))
    #expect(legacyIdentity == explicitCapture.runtimeIdentity && legacyConfig == explicitCapture)
}

@Test func claudeDeferredResumeInspectionRejectsMalformedTeamAndChildOrSyntheticOpeningOwners() throws {
    let fixture = try ClaudeRuntimeHistoryFixture(); defer { fixture.cleanup() }
    let native = UUID().uuidString.lowercased(), runID = UUID(), input = ClaudeInputIdentity.opening(runID: runID)
    let selection = try ClaudeResumeSelection(nativeSessionID: native, kind: .freshSession)
    var configuration = ProviderConfiguration(thread: fixture.thread()); configuration.nativeThreadID = native; configuration.claudeLaunchSelection = selection
    let run = ThreadRunRecord(run: .init(id: runID, configuration: configuration, startedAt: Date()), origin: .user, userMessageID: "user-" + runID.uuidString)
    let file = try fixture.sourceURL(sessionID: native)
    let reply = fixture.row(UUID().uuidString.lowercased(), session: native, parent: input, role: "assistant")
    let malformed: [(String, JSONValue)] = [
        ("teamName", .bool(true)), ("teamName", .number(7)), ("teamName", .string("another-owner")),
        ("parent_tool_use_id", .string("a-native-child-tool")), ("parent_agent_id", .string(UUID().uuidString.lowercased())),
        ("is_meta", .bool(true)), ("is_meta", .string("false")), ("isCompletedLocalCommand", .bool(true)),
        ("isCompactSummary", .bool(true)), ("isSidechain", .bool(true))
    ]
    for (key, value) in malformed {
        var opening = try #require(fixture.row(input, session: native, parent: nil).object)
        opening[key] = value
        try fixture.write([.object(opening), reply], to: file)
        #expect(throws: CoincideError.self) {
            _ = try ClaudeResumeInspection.inspect(configuration: fixture.runtime, selection: selection, run: run)
        }
    }
}
