import Foundation
import Testing

@testable import CoincideKit

@MainActor
struct ACPProviderTests {
    /// What `grok models` prints (from T3 Code's Grok provider tests).
    private static let loggedIn = """
        You are logged in with grok.com.

        Default model: grok-4.6

        Available models:
          * grok-4.6 (default)
          - grok-4.5

        """
    private static let loggedOut = loggedIn.replacingOccurrences(of: "You are logged in with grok.com.", with: "You are not authenticated.")

    /// A stand-in `grok` that answers `--version` and `models` the way the real CLI does.
    private func fakeGrok(in directory: URL, version: String = "grok 1.0.67", models: String = loggedIn, versionStatus: Int = 0) throws
        -> URL
    {
        let script = directory.appendingPathComponent("grok")
        try """
            #!/bin/sh
            case "$1" in
              --version) printf '%s\\n' '\(version)'; exit \(versionStatus) ;;
              models) cat <<'EOF'
            \(models)
            EOF
              exit 0 ;;
            esac
            exit 3
            """.write(to: script, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: script.path)
        return script
    }

    // MARK: Grok CLI output

    @Test func parsesGrokModelsOutput() {
        let parsed = GrokCLI.parseModels(Self.loggedIn)
        #expect(parsed.authenticated == true)
        #expect(parsed.models == [GrokCLI.ListedModel(id: "grok-4.6", isDefault: true), GrokCLI.ListedModel(id: "grok-4.5", isDefault: false)])
        #expect(GrokCLI.parseModels(Self.loggedOut).authenticated == false)
        #expect(GrokCLI.parseModels("Something else").authenticated == nil)
    }

    @Test func parsesVersions() {
        #expect(GrokCLI.version(from: "grok 1.0.67\n") == "1.0.67")
        #expect(GrokCLI.version(from: "v2.3.4-beta") == "2.3.4")
        #expect(GrokCLI.version(from: "unknown") == nil)
    }

    @Test func readsTheModelsCache() throws {
        let cache = Data(
            """
            {"grok_version":"1.0.67","models":{
            "grok-4.7":{"info":{"id":"grok-4.7","name":"Grok 4.7","context_window":256000,"reasoning_effort":"high","supports_reasoning_effort":true,
             "reasoning_efforts":[{"id":"xhigh","value":"xhigh","label":"Extra High","default":false},{"id":"high","value":"high","label":"High","default":true},
             {"id":"medium","value":"medium","label":"Medium","default":false},{"id":"low","value":"low","label":"Low","default":false}]}},
            "grok-4.7-build-fast":{"info":{"name":"Grok 4.7 Fast","context_window":256000,"supports_reasoning_effort":true,
             "reasoning_efforts":[{"value":"high","default":true},{"value":"low"}]}},
            "grok-4.5":{"info":{"name":"Grok 4.5","supports_reasoning_effort":false,"reasoning_efforts":[{"value":"high"}]}},
            "grok-internal":{"info":{"name":"Internal","hidden":true}}}}
            """.utf8)
        let parsed = GrokCLI.parseModelsCache(cache)
        #expect(parsed["grok-internal"] == nil)
        #expect(parsed["grok-4.7"] == GrokCLI.CachedModel(
            id: "grok-4.7", name: "Grok 4.7", efforts: ["low", "medium", "high", "xhigh"], defaultEffort: "high", contextWindow: 256_000))
        #expect(parsed["grok-4.7-build-fast"]?.defaultEffort == "high")
        #expect(parsed["grok-4.5"]?.efforts == [])

        // Without a CLI listing, cached models are offered newest first.
        let options = GrokCLI.modelOptions(listed: [], cache: parsed)
        #expect(options.map(\.modelID) == ["grok-build", "grok-4.7", "grok-4.7-build-fast", "grok-4.5"])
        #expect(options[1].contextWindow == 256_000)

        // A listing decides which models exist; the cache only adds detail.
        let listed = GrokCLI.modelOptions(listed: [GrokCLI.ListedModel(id: "grok-4.6", isDefault: true)], cache: parsed)
        #expect(listed.map(\.modelID) == ["grok-build", "grok-4.6"])
        #expect(listed[0].displayName == "Grok Build (Grok 4.6)")
        #expect(listed[1].displayName == "Grok 4.6")
    }

    @Test func readsOnlyTheAccountEmail() {
        let auth = Data(
            #"{"https://auth.x.ai::b1a00492-073a-47ea-816f-4c329264a828":{"key":"secret-token","auth_mode":"session","email":"me@example.com"}}"#
                .utf8)
        #expect(GrokCLI.accountEmail(authJSON: auth) == "me@example.com")
        let apiKey = Data(#"{"https://accounts.x.ai/sign-in":{"key":"k","auth_mode":"api_key","email":"me@example.com"}}"#.utf8)
        #expect(GrokCLI.accountEmail(authJSON: apiKey) == nil)
        #expect(GrokCLI.accountEmail(authJSON: Data("{}".utf8)) == nil)
    }

    @Test func grokHomeHonorsGrokHome() {
        #expect(GrokCLI.home(["GROK_HOME": "/opt/grok"]).path == "/opt/grok")
        #expect(GrokCLI.home(["HOME": "/Users/me"]).path == "/Users/me/.grok")
    }

    // MARK: Detection

    @Test func detectsASignedInGrok() async throws {
        let directory = try acpTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let grok = try fakeGrok(in: directory)
        let home = directory.appendingPathComponent("home/.grok")
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
        try Data(#"{"https://accounts.x.ai/sign-in":{"auth_mode":"session","email":"me@example.com"}}"#.utf8)
            .write(to: home.appendingPathComponent("auth.json"))
        let environment = ["PATH": "/usr/bin:/bin", "HOME": directory.appendingPathComponent("home").path]

        let provider = ACPProvider(profile: .grok)
        let status = await provider.detect(executable: grok, environment: environment)
        #expect(status.state == .ready)
        #expect(status.version == "1.0.67")
        #expect(status.account == "me@example.com")

        let models = await provider.models(status: status, environment: environment)
        #expect(models.map(\.modelID) == ["grok-build", "grok-4.6", "grok-4.5"])
    }

    @Test func detectsASignedOutGrok() async throws {
        let directory = try acpTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let grok = try fakeGrok(in: directory, models: Self.loggedOut)
        let status = await ACPProvider(profile: .grok).detect(executable: grok, environment: ["PATH": "/usr/bin:/bin", "HOME": directory.path])
        #expect(status.state == .notAuthenticated)
        #expect(status.message?.contains("grok login") == true)

        let withKey = await ACPProvider(profile: .grok).detect(
            executable: grok, environment: ["PATH": "/usr/bin:/bin", "HOME": directory.path, "XAI_API_KEY": "xai-key"])
        #expect(withKey.state == .ready)
        #expect(withKey.account == "xAI API key")
    }

    @Test func reportsABrokenGrok() async throws {
        let directory = try acpTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let grok = try fakeGrok(in: directory, versionStatus: 2)
        let status = await ACPProvider(profile: .grok).detect(executable: grok, environment: ["PATH": "/usr/bin:/bin"])
        #expect(status.state == .error)
        #expect(status.message == "Grok CLI is installed but failed to run.")

        let missing = await ACPProvider(profile: .grok).detect(executable: nil, environment: [:])
        #expect(missing.state == .notInstalled)
        let fallback = await ACPProvider(profile: .grok).models(status: missing, environment: ["HOME": directory.path])
        #expect(fallback.map(\.modelID) == ["grok-build"])
    }

    @Test func antigravityNeedsItsHarness() async throws {
        let directory = try acpTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let server = directory.appendingPathComponent("agy_acp_server.par")
        try Data("#!/bin/sh\n".utf8).write(to: server)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: server.path)
        let provider = ACPProvider(profile: .antigravity)
        // A downloaded runtime, when there is one, comes before the names looked up on PATH.
        #expect(provider.executableNames.suffix(2) == ["agy_acp_server.par", "agy_acp_server"])
        #expect(provider.executableNames.count <= 3)

        let missing = await provider.detect(executable: server, environment: [:])
        #expect(missing.state == .error)
        #expect(missing.message?.contains("localharness_external") == true)

        let harness = directory.appendingPathComponent("localharness_external")
        try Data("#!/bin/sh\n".utf8).write(to: harness)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: harness.path)
        // Signed in or not is decided by the private profile, never by starting the agent.
        let flavor = try acpAntigravityFlavor()
        let signedOut = await flavor.probe(executable: server, environment: [:])
        #expect(signedOut.status.state == .notAuthenticated)
        #expect(signedOut.status.message?.contains("Settings") == true)
        #expect(signedOut.models.map(\.modelID) == ["antigravity-default"])

        try FileManager.default.createDirectory(at: flavor.profile.acpDirectory, withIntermediateDirectories: true)
        try Data("{}".utf8).write(to: flavor.profile.tokenFile)
        let ready = await flavor.probe(executable: server, environment: [:])
        #expect(ready.status.state == .ready)
        #expect(ready.status.version == nil)
        #expect(provider.makeSession(acpLaunch(.antigravity)).provider == .antigravity)
    }

    @Test func antigravityReportsTheDownloadedReleaseVersion() async throws {
        let flavor = try acpAntigravityFlavor()
        let installer = AntigravityInstaller(paths: flavor.paths)
        let releaseID = String(repeating: "b", count: 64)
        let release = flavor.paths.versionsDirectory.appendingPathComponent(releaseID, isDirectory: true)
        try FileManager.default.createDirectory(at: release, withIntermediateDirectories: true)
        for name in ["agy_acp_server.par", "localharness_external"] {
            try Data("#!/bin/sh\n".utf8).write(to: release.appendingPathComponent(name))
            try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: release.appendingPathComponent(name).path)
        }
        try FileManager.default.createSymbolicLink(atPath: flavor.paths.currentLink.path, withDestinationPath: "versions/" + releaseID)
        #expect(ACPProfile.managedAntigravityExecutable(paths: flavor.paths) == flavor.paths.managedExecutable)

        // Without its record the release is incomplete, and never offered as ready.
        let incomplete = await flavor.probe(executable: flavor.paths.managedExecutable, environment: [:])
        #expect(incomplete.status.state == .error)
        #expect(throws: AntigravityInstallError.self) { try installer.activeRelease() }

        let record = AntigravityInstaller.Record(
            releaseId: releaseID, version: "1.3.0", executable: .init(name: "agy_acp_server.par", bytes: 10, sha256: ""),
            harness: .init(name: "localharness_external", bytes: 10, sha256: ""))
        try JSONEncoder().encode(record).write(to: release.appendingPathComponent(AntigravityInstaller.recordName))
        let installed = await flavor.probe(executable: flavor.paths.managedExecutable, environment: [:])
        #expect(installed.status.state == .notAuthenticated)
        #expect(installed.status.version == "1.3.0")
        #expect(try installer.activeRelease()?.harness == release.appendingPathComponent("localharness_external"))
    }

    // MARK: Client file system

    @Test func fileSystemReadsLinesAndWritesInsideTheWorkspace() throws {
        let directory = try acpTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let files = ACPFileSystem(roots: [directory])
        let path = directory.path + "/a/b/c.txt"
        _ = try files.writeTextFile(["path": .string(path), "content": "one\ntwo\nthree\n"])
        #expect(try files.readTextFile(["path": .string(path)])["content"] == "one\ntwo\nthree\n")
        #expect(try files.readTextFile(["path": .string(path), "line": 2])["content"] == "two\nthree\n")
        #expect(try files.readTextFile(["path": .string(path), "line": 1, "limit": 2])["content"] == "one\ntwo")

        #expect(throws: ACPError.self) { try files.readTextFile(["path": .string(directory.path + "/missing.txt")]) }
        #expect(throws: ACPError.self) { try files.readTextFile(["path": "relative.txt"]) }
        #expect(throws: ACPError.self) { try files.writeTextFile(["path": .string(directory.path + "/x/../../escape.txt"), "content": "x"]) }
    }

    @Test func fileSystemRejectsSymlinksOutOfTheWorkspace() throws {
        let workspace = try acpTemporaryDirectory()
        let outside = try acpTemporaryDirectory()
        defer {
            try? FileManager.default.removeItem(at: workspace)
            try? FileManager.default.removeItem(at: outside)
        }
        try "secret".write(to: outside.appendingPathComponent("secret.txt"), atomically: true, encoding: .utf8)
        try FileManager.default.createSymbolicLink(at: workspace.appendingPathComponent("link"), withDestinationURL: outside)
        let files = ACPFileSystem(roots: [workspace])
        #expect(throws: ACPError.self) { try files.readTextFile(["path": .string(workspace.path + "/link/secret.txt")]) }
        #expect(throws: ACPError.self) {
            try files.writeTextFile(["path": .string(workspace.path + "/link/new.txt"), "content": "x"])
        }
        #expect(!FileManager.default.fileExists(atPath: outside.path + "/new.txt"))
    }

    // MARK: Client terminals

    @Test func terminalsRunCommandsAndReportExitStatus() async throws {
        let terminals = ACPTerminals(workingDirectory: URL(fileURLWithPath: "/tmp"), environment: ["PATH": "/usr/bin:/bin"])
        let created = try terminals.create(["sessionId": "s", "command": "/bin/sh", "args": ["-c", "printf 'hello\\n'; exit 3"]])
        let id = try #require(created["terminalId"])
        let status = try await terminals.waitForExit(["sessionId": "s", "terminalId": id])
        #expect(status == ["exitCode": 3, "signal": nil])
        let output = try terminals.output(["sessionId": "s", "terminalId": id])
        #expect(output["output"] == "hello\n")
        #expect(output["truncated"] == false)
        #expect(output["exitStatus"] == ["exitCode": 3, "signal": nil])

        _ = try terminals.release(["sessionId": "s", "terminalId": id])
        #expect(throws: ACPError.self) { try terminals.output(["sessionId": "s", "terminalId": id]) }
        // Output stays readable for tool calls that embedded the terminal.
        #expect(terminals.snapshot(id.string ?? "") == "hello\n")
        #expect(throws: ACPError.self) { try terminals.output(["sessionId": "other", "terminalId": "nope"]) }
    }

    @Test func terminalsTruncateFromTheStartAndCanBeKilled() async throws {
        let terminals = ACPTerminals(workingDirectory: URL(fileURLWithPath: "/tmp"), environment: ["PATH": "/usr/bin:/bin"])
        let noisy = try terminals.create(["sessionId": "s", "command": "printf", "args": ["abcdefghij"], "outputByteLimit": 4])
        _ = try await terminals.waitForExit(["sessionId": "s", "terminalId": noisy["terminalId"] ?? .null])
        let output = try terminals.output(["sessionId": "s", "terminalId": noisy["terminalId"] ?? .null])
        #expect(output["output"] == "ghij")
        #expect(output["truncated"] == true)

        let sleeper = try terminals.create(["sessionId": "s", "command": "sleep", "args": ["30"]])
        let id = sleeper["terminalId"] ?? .null
        _ = try terminals.kill(["sessionId": "s", "terminalId": id])
        let status = try await terminals.waitForExit(["sessionId": "s", "terminalId": id])
        #expect(status["signal"] == "SIGTERM")
        terminals.disposeAll()
    }
}
