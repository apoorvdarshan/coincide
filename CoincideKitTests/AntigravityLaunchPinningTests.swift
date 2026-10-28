import Foundation
import Testing

@testable import CoincideKit

@MainActor
struct AntigravityLaunchPinningTests {
    @Test func sessionUsesTheLeasedPairAfterAnotherReleaseActivates() async throws {
        let fixture = try LaunchFixture()
        defer { fixture.cleanUp() }
        var launch = acpLaunch(.antigravity)
        launch.executable = fixture.paths.managedExecutable
        let flavor = AntigravityFlavor(paths: fixture.paths, profile: fixture.profile, runtime: fixture.runtime)
        let session = ACPSession(launch: launch, flavor: flavor, transport: fixture.switchingFactory)
        try await session.start()
        #expect(fixture.launches == 1)
        fixture.agent.transport.exit(status: 0, stderr: "")
        await fixture.expectReleased()
        session.shutdown()
    }

    @Test func signInUsesTheLeasedPairAfterAnotherReleaseActivates() async throws {
        let fixture = try LaunchFixture()
        defer { fixture.cleanUp() }
        let signIn = AntigravitySignIn(
            profile: fixture.profile, runtime: fixture.runtime, transport: fixture.switchingFactory)
        signIn.start(executable: fixture.paths.managedExecutable, environment: [:])
        await acpWaitUntil("sign-in completed") { !signIn.isActive }
        #expect(signIn.phase == .succeeded, "\(signIn.message ?? "")")
        #expect(fixture.launches == 1)
        fixture.agent.transport.exit(status: 0, stderr: "")
        await fixture.expectReleased()
    }

    @Test func logoutUsesTheLeasedPairAfterAnotherReleaseActivates() async throws {
        let fixture = try LaunchFixture()
        defer { fixture.cleanUp() }
        let signIn = AntigravitySignIn(
            profile: fixture.profile, runtime: fixture.runtime, transport: fixture.switchingFactory)
        try await signIn.signOut(executable: fixture.paths.managedExecutable, environment: [:])
        #expect(fixture.agent.requests.map(\.method) == ["initialize", "logout"])
        #expect(fixture.launches == 1)
        fixture.agent.transport.exit(status: 0, stderr: "")
        await fixture.expectReleased()
    }
}

/// Switches the installed release after selection but before the transport starts, without using
/// the actual Google runtime, the user's profile, or any network service.
@MainActor
private final class LaunchFixture {
    let root: URL
    let paths: AntigravityPaths
    let profile: AntigravityProfile
    let runtime: AntigravityRuntime
    let installer: AntigravityInstaller
    let agent = ACPFakeAgent()
    let oldID = String(repeating: "a", count: 64)
    let newID = String(repeating: "b", count: 64)
    private(set) var launches = 0

    var oldDirectory: URL {
        URL(fileURLWithPath: AntigravityPaths.canonicalPath(paths.versionsDirectory.appendingPathComponent(oldID)))
    }

    init() throws {
        root = try acpTemporaryDirectory()
        paths = AntigravityPaths(dataDirectory: root, architecture: "arm64")
        profile = AntigravityProfile(geminiHome: paths.profileDirectory, userHome: root.appendingPathComponent("home"))
        installer = AntigravityInstaller(paths: paths)
        for id in [oldID, newID] {
            let directory = paths.versionsDirectory.appendingPathComponent(id)
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            for name in [AntigravityRelease.executableName, AntigravityRelease.harnessName] {
                try Data(id.utf8).write(to: directory.appendingPathComponent(name))
            }
        }
        try installer.activate(oldID)
        runtime = AntigravityRuntime(paths: paths, asset: nil)
        agent.initializeResult = [
            "protocolVersion": 1,
            "agentCapabilities": ["loadSession": true, "auth": ["logout": [:]]],
            "authMethods": [["id": "oauth-personal", "name": "Google"]],
        ]
    }

    var switchingFactory: ACPTransportFactory {
        { [self] executable, arguments, directory, environment in
            launches += 1
            do {
                try installer.activate(newID)
                installer.pruneReleases(keeping: newID, inUse: [])
                let expectedExecutable = oldDirectory.appendingPathComponent(AntigravityRelease.executableName)
                let expectedHarness = oldDirectory.appendingPathComponent(AntigravityRelease.harnessName)
                #expect(executable.path == expectedExecutable.path)
                #expect(environment["ANTIGRAVITY_HARNESS_PATH"] == expectedHarness.path)
                #expect(runtime.leaseCount == 1)
                // Reading both supplied paths proves they still exist and select the same old release.
                #expect(try Data(contentsOf: executable) == Data(oldID.utf8))
                #expect(try Data(contentsOf: URL(fileURLWithPath: environment["ANTIGRAVITY_HARNESS_PATH"]!)) == Data(oldID.utf8))
            } catch { Issue.record(error) }
            return agent.factory(executable, arguments, directory, environment)
        }
    }

    func expectReleased() async {
        await acpWaitUntil("launch lease released") { runtime.leaseCount == 0 }
        installer.pruneReleases(keeping: newID, inUse: [])
        #expect(!FileManager.default.fileExists(atPath: oldDirectory.path))
    }

    func cleanUp() {
        AntigravityFlavor.knownModels[profile.geminiHome.path] = nil
        try? FileManager.default.removeItem(at: root)
    }
}
