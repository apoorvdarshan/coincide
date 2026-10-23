import Darwin
import Foundation
import Testing
@testable import CoincideCore

private struct ClaudeProfileFixture {
    let root: URL
    let executable: URL
    let directory: URL
    init(scenario: String = "normal") throws {
        let created = FileManager.default.temporaryDirectory.appendingPathComponent("coincide-claude-profile-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: created, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        root = URL(fileURLWithPath: try ClaudeRuntimeValidation.physical(created.path, allowMissing: false))
        executable = root.appendingPathComponent("claude-peer.py"); directory = root.appendingPathComponent("native-config")
        let source = try #require(Bundle.module.url(forResource: "claude_runtime_settings", withExtension: "py", subdirectory: "Fixtures"))
        try FileManager.default.copyItem(at: source, to: executable)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: executable.path)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        try Data(scenario.utf8).write(to: root.appendingPathComponent("scenario"))
    }
    func profile(threshold: Int? = nil) -> ClaudeRuntimeProfile {
        .init(executable: executable.path, configurationDirectory: directory.path, autoCompactWindow: threshold)
    }
    func thread(threshold: Int? = nil) throws -> CodingThread {
        var value = CodingThread(project: .init(path: root.path)); value.provider = .claude
        // WorkspaceProject registers Foundation's canonical path spelling,
        // which can differ from realpath's /private temporary-directory alias.
        value.claudeRuntimeConfiguration = try profile(threshold: threshold).capture(workspacePath: value.workspacePath)
        value.activeRun = .init(id: UUID(), configuration: .init(thread: value), startedAt: .now)
        return value
    }
    func frames() throws -> [JSONValue] {
        let url = root.appendingPathComponent("wire.jsonl")
        guard FileManager.default.fileExists(atPath: url.path) else { return [] }
        return try Data(contentsOf: url).split(separator: 10).map { try JSONDecoder().decode(JSONValue.self, from: Data($0)) }
    }
}
private actor ClaudeProfileEvents {
    var completed = 0
    var metadata: [JSONValue] = []
    func record(_ value: ProviderEvent) {
        if case .context(_, let child) = value { record(child); return }
        if case .completed = value { completed += 1 }
        if case .configuration(let value) = value { metadata.append(value) }
    }
}
private func claudeProfileEventually(_ check: () async throws -> Bool) async throws {
    let deadline = ContinuousClock.now + .seconds(8)
    while !(try await check()) {
        guard ContinuousClock.now < deadline else { throw CoincideError("The offline runtime peer did not reach its expected boundary.") }
        try await Task.sleep(for: .milliseconds(5))
    }
}

@Test func claudeRuntimeProfileDefaultNamespaceAndBoundedThresholdRemainFlatAndLegacyCompatible() throws {
    let profile = ClaudeRuntimeProfile(executable: "", configurationDirectory: "")
    #expect(profile.executable == "claude" && profile.configurationDirectory == nil && profile.launchSettings == nil)
    let threshold = try profile.editing(executable: "claude", configurationDirectory: nil, autoCompactWindow: 100_000)
    #expect(threshold.instanceID == profile.instanceID)
    let namespace = try profile.editing(executable: "/private/other-cli", configurationDirectory: nil, autoCompactWindow: nil)
    #expect(namespace.instanceID != profile.instanceID)
    let encoding = try JSONSerialization.jsonObject(with: JSONEncoder().encode(threshold)) as? [String: Any]
    #expect(encoding?["storage"] == nil && encoding?["autoCompactWindow"] as? Int == 100_000)
    for value in [99_999, 1_000_001, -1] {
        #expect(throws: CoincideError.self) { try ClaudeRuntimeProfile(autoCompactWindow: value).validate() }
    }
    for value in ["--settings", "claude --login", "https://private.invalid/cli", "../claude", "/private/../cli", "cli\n"] {
        #expect(throws: CoincideError.self) { try ClaudeRuntimeProfile(executable: value).validate() }
    }
    let settings = ClaudeLaunchSettings(autoCompactWindow: 1_000_000)
    #expect(try settings.arguments() == ["--settings", "{\"autoCompactWindow\":1000000}"])
    #expect(try ClaudeLaunchSettings().arguments().isEmpty)
    let f = try ClaudeProfileFixture(); defer { try? FileManager.default.removeItem(at: f.root) }
    let runtime = try f.profile(threshold: 200_000).capture(workspacePath: f.root.path)
    #expect(runtime.launchSettings?.autoCompactWindow == 200_000 && runtime.runtimeIdentity.launchSettings == runtime.launchSettings)
    let replacement = try runtime.replacingWorkspace(f.root.path)
    #expect(replacement.instanceID == runtime.instanceID && replacement.launchSettings == runtime.launchSettings)
    let encodedRuntime = try JSONEncoder().encode(runtime)
    let object = try JSONSerialization.jsonObject(with: encodedRuntime) as? [String: Any]
    var legacy = try #require(object)
    legacy.removeValue(forKey: "launchSettings")
    let decoded = try JSONDecoder().decode(ClaudeRuntimeConfiguration.self, from: JSONSerialization.data(withJSONObject: legacy))
    #expect(decoded.launchSettings == nil)
    let oldIdentity = try JSONDecoder().decode(ClaudeRuntimeIdentity.self, from: JSONSerialization.data(withJSONObject: legacy))
    #expect(oldIdentity.launchSettings == nil)
}

@Test func claudeRuntimeProfileCapturePreservesNativeHomePresenceAndNoNativeSettingsWrites() throws {
    let f = try ClaudeProfileFixture(); defer { try? FileManager.default.removeItem(at: f.root) }
    let profile = ClaudeRuntimeProfile(executable: f.executable.path, autoCompactWindow: 250_000)
    let inherited = try profile.capture(workspacePath: f.root.path, environment: ["HOME": f.root.path])
    #expect(inherited.configurationDirectorySelection == .defaultHome(homeDirectory: f.root.path))
    #expect(!FileManager.default.fileExists(atPath: f.root.appendingPathComponent(".claude").path))
    let explicit = try profile.capture(workspacePath: f.root.path, environment: ["HOME": f.root.path, "CLAUDE_CONFIG_DIR": f.directory.path])
    #expect(explicit.configurationDirectorySelection == .explicitDirectory(environmentPath: f.directory.path))
    #expect(explicit.launchSettings?.autoCompactWindow == 250_000)
    #expect(try FileManager.default.contentsOfDirectory(atPath: f.directory.path).isEmpty)
}

@Test func claudeRuntimeProfilePreferencesPreserveCASConflictsCorruptionAndPrivateFiles() async throws {
    let f = try ClaudeProfileFixture(); defer { try? FileManager.default.removeItem(at: f.root) }
    let folder = f.root.appendingPathComponent("preferences"), first = ClaudeRuntimeProfilePreferences(root: f.root.appendingPathComponent("preferences"))
    let second = ClaudeRuntimeProfilePreferences(root: folder)
    let original = try await first.load(); _ = try await second.load()
    let saved = try original.editing(executable: f.executable.path, configurationDirectory: f.directory.path, autoCompactWindow: 150_000)
    try await first.save(saved)
    await #expect(throws: RemoteEnvironmentStorageError.self) { try await second.save(.init(autoCompactWindow: 400_000)) }
    let file = folder.appendingPathComponent("profile.json"), bytes = try Data(contentsOf: file)
    #expect(try await second.load() == saved)
    let attributes = try FileManager.default.attributesOfItem(atPath: file.path)
    #expect((attributes[.posixPermissions] as? NSNumber)?.intValue == 0o600)
    let foreign = Data("{\"version\":1,\"profile\":{\"instanceID\":\"\(UUID())\",\"executable\":\"claude\",\"token\":\"not-a-credential\"}}".utf8)
    try foreign.write(to: file)
    await #expect(throws: (any Error).self) { _ = try await first.load() }
    #expect(try Data(contentsOf: file) == foreign && bytes != foreign)
    await #expect(throws: RemoteEnvironmentStorageError.self) { try await first.save(saved) }
    #expect(try Data(contentsOf: file) == foreign)
}

@Test(.timeLimit(.minutes(1)), arguments: [false, true])
func claudeRuntimeProfileStdioUsesCapturedLaunchAndSafeMergedSettingsBeforeInput(explicit: Bool) async throws {
    let f = try ClaudeProfileFixture(); defer { try? FileManager.default.removeItem(at: f.root) }
    var thread = try f.thread(threshold: explicit ? 200_000 : nil)
    let captured = try #require(thread.activeRun?.configuration.claudeRuntimeConfiguration)
    #expect(captured.registeredWorkspacePath.utf8.elementsEqual(thread.workspacePath.utf8))
    // The factory must launch the accepted capture, even after future defaults
    // or the thread header point at a different executable and namespace.
    thread.claudeRuntimeConfiguration = .init(executable: "/private/nonexistent-cli", configurationDirectory: "/private/future-profile",
        workspacePath: f.root.path, launchSettings: .init(autoCompactWindow: 900_000))
    thread.draft = "  newer literal draft e\u{301}\n "
    let session = try ProviderSessions.make(for: thread), observed = ClaudeProfileEvents()
    let reading = Task { for await value in session.events { await observed.record(value) } }
    do {
        try await session.send(text: "  explicit authored input e\u{301}\n ", thread: thread)
        try await claudeProfileEventually { await observed.completed == 1 }
        let frames = try f.frames(), methods = frames.compactMap { $0["request"]["subtype"].string }
        #expect(methods.filter { $0 == "get_settings" }.count == (explicit ? 1 : 0))
        let launch = try JSONDecoder().decode(JSONValue.self, from: Data(contentsOf: f.root.appendingPathComponent("launch.json")))
        #expect(launch["directory"].string == captured.configurationDirectory)
        #expect(launch["argv"].array?.contains(.string("--settings")) == explicit)
        #expect(frames.last?["message"]["content"] == .string("  explicit authored input e\u{301}\n "))
        let metadata = await observed.metadata
        #expect(metadata.contains { $0["claudeLaunchSettings"]["effectiveAutoCompactWindow"] == .number(200_000) } == explicit)
        let encoded = try JSONEncoder().encode(metadata)
        #expect(!String(decoding: encoded, as: UTF8.self).contains("PRIVATE-NATIVE-SETTINGS"))
        #expect(thread.draft.utf8.elementsEqual("  newer literal draft e\u{301}\n ".utf8))
        await session.close(); await reading.value
    } catch { await session.close(); await reading.value; throw error }
}

@Test(.timeLimit(.minutes(1)), arguments: ["missing", "mismatch", "string", "error", "drop"])
func claudeRuntimeProfileUnconfirmedSettingIsUnsentAndPrivateNativeErrorsStayHidden(scenario: String) async throws {
    let f = try ClaudeProfileFixture(scenario: scenario); defer { try? FileManager.default.removeItem(at: f.root) }
    let thread = try f.thread(threshold: 200_000), runtime = try #require(thread.claudeRuntimeConfiguration)
    let session = try ClaudeSession(executable: f.executable, cwd: f.root, configuration: runtime)
    do {
        try await session.send(text: "Must stay unsent", thread: thread)
        Issue.record("Unconfirmed native setting admitted a user input")
    } catch {
        #expect(error.localizedDescription.contains("No user input was submitted"))
        #expect(!error.localizedDescription.contains("PRIVATE-NATIVE-SETTINGS"))
    }
    await session.close()
    let frames = try f.frames()
    #expect(!frames.contains { $0["type"] == .string("user") })
}

@Test(.timeLimit(.minutes(1))) func claudeRuntimeProfileCloseDrainsAnUnconfirmedSettingsReadWithoutInput() async throws {
    let f = try ClaudeProfileFixture(scenario: "held"); defer { try? FileManager.default.removeItem(at: f.root) }
    let thread = try f.thread(threshold: 200_000), runtime = try #require(thread.claudeRuntimeConfiguration)
    let session = try ClaudeSession(executable: f.executable, cwd: f.root, configuration: runtime)
    let sending = Task { try await session.send(text: "Must stay unsent", thread: thread) }
    try await claudeProfileEventually { FileManager.default.fileExists(atPath: f.root.appendingPathComponent("settings-entered").path) }
    await session.close(); _ = await sending.result
    let frames = try f.frames()
    #expect(!frames.contains { $0["type"] == .string("user") })
}
