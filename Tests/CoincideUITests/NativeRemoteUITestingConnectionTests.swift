import Foundation
import Testing
@testable import Coincide
import CoincideCore

private struct NativeRemoteUIConnectionFixture {
    let root: URL
    var app: URL { root.appendingPathComponent("Guarded.app", isDirectory: true) }
    var helper: URL { app.appendingPathComponent("Contents/Helpers/CoincideEnvironment") }
    var data: URL { root.appendingPathComponent("coincide-ui-testing-remote-script-host", isDirectory: true) }
    var marker: URL { root.appendingPathComponent("unexpected-helper-launch") }
    var retained: URL { root.deletingLastPathComponent().appendingPathComponent(root.lastPathComponent + "-retained") }
    var environment: [String: String] {
        ["COINCIDE_UI_TESTING": "1", "COINCIDE_UI_TEST_REMOTE_SCRIPT": "1", "COINCIDE_UI_TEST_ROOT": root.path,
         "PATH": "/fixture/developer-git:/usr/bin:/bin", "GIT_CONFIG_GLOBAL": root.appendingPathComponent("gitconfig").path,
         "HOME": "/must-not-inherit", "SHELL": "/must-not-inherit", "GH_TOKEN": "synthetic-not-a-credential",
         "COINCIDE_UI_REMOTE_HELPER": "/must-not-run"]
    }
    static func make() throws -> Self {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("coincide-ui-testing-\(UUID())").resolvingSymlinksInPath()
        let value = Self(root: root)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        do {
            for directory in [value.data, root.appendingPathComponent("remote-script-home"), root.appendingPathComponent("remote-script-codex-home"),
                              root.appendingPathComponent("remote-script-claude-home"), value.helper.deletingLastPathComponent()] {
                try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
            }
            // This guard fixture must never execute. Native helper execution is
            // covered by the separate actual-binary and hosted GUI acceptance.
            try value.helperProgram.write(to: value.helper, atomically: false, encoding: .utf8)
            try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: value.helper.path)
            let configuration = root.appendingPathComponent("gitconfig")
            try Data("[user]\n name = Private guard fixture\n email = fixture@example.invalid\n".utf8).write(to: configuration)
            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: configuration.path)
            return value
        } catch { value.remove(); throw error }
    }
    var helperProgram: String { "#!/bin/sh\nprintf unexpected > '" + marker.path.replacingOccurrences(of: "'", with: "'\\''") + "'\nexit 78\n" }
    func remove() { try? FileManager.default.removeItem(at: root); try? FileManager.default.removeItem(at: retained) }
}

@Test @MainActor
func nativeRemoteUITestingConnectionRequiresDebugTestBundleAndBothFlagsWithoutTouchingOrdinaryLaunches() throws {
    let bundle = URL(fileURLWithPath: "/does-not-exist/Fixture.app")
    let enabled = ["COINCIDE_UI_TESTING": "1", "COINCIDE_UI_TEST_REMOTE_SCRIPT": "1"]
    for identifier in [nil, "com.apoorvdarshan.coincide", "com.apoorvdarshan.coincide.uitesting.other"] as [String?] {
        let factory = try NativeRemoteUITestingConnection.clientFactory(bundleIdentifier: identifier, bundleURL: bundle, environment: enabled)
        #expect(factory == nil)
    }
    for flags in [[:], ["COINCIDE_UI_TESTING": "1"], ["COINCIDE_UI_TEST_REMOTE_SCRIPT": "1"],
                  ["COINCIDE_UI_TESTING": "1", "COINCIDE_UI_TEST_REMOTE_SCRIPT": "true"]] {
        let factory = try NativeRemoteUITestingConnection.clientFactory(bundleIdentifier: AppLaunchConfiguration.uiTestingBundleIdentifier,
            bundleURL: bundle, environment: flags)
        #expect(factory == nil)
    }
}

#if DEBUG
@Test @MainActor
func nativeRemoteUITestingConnectionPinsBundledHelperAndFixedFixtureConfigurationWithoutPropagatingAuth() async throws {
    let f = try NativeRemoteUIConnectionFixture.make(); defer { f.remove() }
    let planned = try NativeRemoteUITestingConnection.launch(bundleIdentifier: AppLaunchConfiguration.uiTestingBundleIdentifier,
        bundleURL: f.app, environment: f.environment)
    let launch = try #require(planned)
    #expect(launch.helper == f.helper && launch.data == f.data)
    #expect(launch.environment["HOME"] == f.root.appendingPathComponent("remote-script-home").path)
    #expect(launch.environment["SHELL"] == "/bin/sh" && launch.environment["PATH"] == f.environment["PATH"])
    #expect(launch.environment["GH_TOKEN"] == nil && launch.environment["COINCIDE_UI_REMOTE_HELPER"] == nil)
    let expectedID = UUID(), arguments = launch.arguments(expected: expectedID)
    #expect(arguments.contains(expectedID.uuidString) && arguments.contains(f.data.path))
    #expect(arguments.filter { $0 == "/usr/bin/false" }.count == 3)
    let optional = try NativeRemoteUITestingConnection.clientFactory(bundleIdentifier: AppLaunchConfiguration.uiTestingBundleIdentifier,
        bundleURL: f.app, environment: f.environment)
    let factory = try #require(optional), configuration = NativeRemoteUITestingConnection.configuration
    let client = try factory(configuration, expectedID)
    #expect(await client.currentDescriptor() == nil)
    await client.close()
    var other = configuration; other.target = "ordinary-host"
    #expect(throws: (any Error).self) { _ = try factory(other, nil) }
    other = configuration; other.port = 22
    #expect(throws: (any Error).self) { _ = try factory(other, nil) }
    other = configuration; other.helperPath = f.helper.path
    #expect(throws: (any Error).self) { _ = try factory(other, nil) }
    other = configuration; other.dataDirectory = f.data.path
    #expect(throws: (any Error).self) { _ = try factory(other, nil) }
    #expect(!FileManager.default.fileExists(atPath: f.marker.path))
}

@Test @MainActor
func nativeRemoteUITestingConnectionRejectsUnsafePrivateRootsAndCapturedNodeReplacement() throws {
    for change in ["permissions", "rootLink", "dataLink", "helperLink", "foreignGitConfig", "rootReplacement", "helperReplacement"] {
        let f = try NativeRemoteUIConnectionFixture.make(); defer { f.remove() }
        let optional = try NativeRemoteUITestingConnection.clientFactory(bundleIdentifier: AppLaunchConfiguration.uiTestingBundleIdentifier,
            bundleURL: f.app, environment: f.environment)
        let factory = try #require(optional)
        var environment = f.environment
        switch change {
        case "permissions": try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: f.root.path)
        case "rootLink":
            try FileManager.default.moveItem(at: f.root, to: f.retained)
            try FileManager.default.createSymbolicLink(at: f.root, withDestinationURL: f.retained)
        case "dataLink":
            try FileManager.default.removeItem(at: f.data)
            try FileManager.default.createSymbolicLink(at: f.data, withDestinationURL: f.root.appendingPathComponent("remote-script-home"))
        case "helperLink":
            try FileManager.default.removeItem(at: f.helper)
            try FileManager.default.createSymbolicLink(at: f.helper, withDestinationURL: URL(fileURLWithPath: "/usr/bin/false"))
        case "foreignGitConfig": environment["GIT_CONFIG_GLOBAL"] = "/dev/null"
        case "rootReplacement":
            try FileManager.default.moveItem(at: f.root, to: f.retained)
            try FileManager.default.createDirectory(at: f.root, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        default:
            try f.helperProgram.write(to: f.helper, atomically: true, encoding: .utf8)
            try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: f.helper.path)
        }
        if change == "foreignGitConfig" {
            #expect(throws: (any Error).self) {
                _ = try NativeRemoteUITestingConnection.clientFactory(bundleIdentifier: AppLaunchConfiguration.uiTestingBundleIdentifier,
                    bundleURL: f.app, environment: environment)
            }
        } else {
            #expect(throws: (any Error).self) { _ = try factory(NativeRemoteUITestingConnection.configuration, nil) }
        }
        #expect(!FileManager.default.fileExists(atPath: f.marker.path))
    }
}

@Test @MainActor
func nativeRemoteUITestingConnectionRechecksCapturedHelperBeforeDeferredTransportLaunch() async throws {
    let f = try NativeRemoteUIConnectionFixture.make(); defer { f.remove() }
    let optional = try NativeRemoteUITestingConnection.clientFactory(bundleIdentifier: AppLaunchConfiguration.uiTestingBundleIdentifier,
        bundleURL: f.app, environment: f.environment)
    let factory = try #require(optional), client = try factory(NativeRemoteUITestingConnection.configuration, nil)
    try f.helperProgram.write(to: f.helper, atomically: true, encoding: .utf8)
    try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: f.helper.path)
    await #expect(throws: (any Error).self) { try await client.discover() }
    #expect(!FileManager.default.fileExists(atPath: f.marker.path))
    await client.close()
}
#endif
