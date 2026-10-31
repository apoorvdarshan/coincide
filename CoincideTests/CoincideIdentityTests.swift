@testable import CoincideKit
import Foundation
import Testing
@testable import Coincide

/// Debug builds (which these tests run in) are a separate app from the installed Coincide: macOS must never take one
/// for the other, and neither may reach the other's data, launchd jobs or Keychain items (`CoincideIdentity`).
struct CoincideIdentityTests {
    private static let repository = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
    private let app = Bundle.main.bundleURL

    @Test func debugBuildsHaveTheirOwnBundleIDs() {
        #expect(CoincideIdentity.isDebug)
        #expect(CoincideIdentity.debugBundleID != CoincideIdentity.releaseBundleID)
        #expect(CoincideIdentity.bundleID == CoincideIdentity.debugBundleID)
        // What project.yml's Debug configuration built.
        #expect(Bundle.main.bundleIdentifier == CoincideIdentity.debugBundleID)
        let host = Bundle(url: app.appendingPathComponent("Contents/Helpers/CoincideAgentHost.app"))
        #expect(host?.bundleIdentifier == AgentHostIdentity.bundleID)
        #expect(AgentHostIdentity.bundleID == "\(CoincideIdentity.debugBundleID).agent-host")
        #expect(AgentHostIdentity.appBundleID == CoincideIdentity.debugBundleID)
        // Updates are always the Release app, whatever build checks for them.
        #expect(AppUpdateSecurity.bundleID == CoincideIdentity.releaseBundleID)
    }

    @Test func theProjectBuildsTheSameIDs() throws {
        let spec = try String(contentsOf: Self.repository.appendingPathComponent("project.yml"), encoding: .utf8)
        let values = spec.split(separator: "\n").compactMap { line -> String? in
            let parts = line.split(separator: ":", maxSplits: 1).map { $0.trimmingCharacters(in: .whitespaces) }
            return parts.count == 2 && parts[0] == "COINCIDE_BUNDLE_ID" ? parts[1] : nil
        }
        #expect(values == [CoincideIdentity.releaseBundleID, CoincideIdentity.debugBundleID])
    }

    @Test func nothingIsSharedWithTheInstalledApp() {
        let names = [
            AgentHostIdentity.bundleID, AgentHostIdentity.machServiceName, AgentHostIdentity.plistName,
            AlwaysOnIdentity.label, AlwaysOnIdentity.plistName, AlwaysOnIdentity.batteryHelperLabel,
            AlwaysOnIdentity.batteryHelperPlistName, ProviderAccountSecrets.standard.keychain.service,
            CoincideLoginProvider.keychainService, KeychainSecretStore().service, KeychainRemoteDeviceStorage().keychain.service,
            SecondInstance.openThread.rawValue,
        ]
        // The launchd labels, Mach service, Keychain services and notification all build on the Debug bundle ID.
        for name in names { #expect(name.hasPrefix("\(CoincideIdentity.debugBundleID)."), "\(name)") }
        #expect(RemoteIdentity.label == "Coincide Debug Remote")
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        #expect(CoincideIdentity.dataDirectory == support.appendingPathComponent("Coincide Debug", isDirectory: true))
        #expect(AlwaysOnIdentity.dataDirectory == CoincideIdentity.dataDirectory)
        #expect(AntigravityPaths.coincideDataDirectory == AppStore.defaultDirectory)
        // The command-line tool built with this app talks to this app.
        #expect(ControlPaths.defaultSocket == CoincideIdentity.dataDirectory.appendingPathComponent("control.sock").path)
    }

    /// The jobs SMAppService registers name this build, so registering them never replaces the installed app's.
    @Test func theBundledLaunchdJobsNameThisBuild() throws {
        let jobs: [(folder: String, plist: String, label: String)] = [
            ("LaunchAgents", AgentHostIdentity.plistName, AgentHostIdentity.bundleID),
            ("LaunchAgents", AlwaysOnIdentity.plistName, AlwaysOnIdentity.label),
            ("LaunchDaemons", AlwaysOnIdentity.batteryHelperPlistName, AlwaysOnIdentity.batteryHelperLabel),
        ]
        for job in jobs {
            let url = app.appendingPathComponent("Contents/Library/\(job.folder)/\(job.plist)")
            let plist = try #require(NSDictionary(contentsOf: url) as? [String: Any], "\(job.plist) is missing")
            #expect(plist["Label"] as? String == job.label)
            #expect(plist["AssociatedBundleIdentifiers"] as? [String] == [CoincideIdentity.bundleID])
            let program = try #require(plist["BundleProgram"] as? String)
            #expect(FileManager.default.isExecutableFile(atPath: app.appendingPathComponent(program).path), "\(program)")
        }
        let host = try #require(NSDictionary(
            contentsOf: app.appendingPathComponent("Contents/Library/LaunchAgents/\(AgentHostIdentity.plistName)")) as? [String: Any])
        #expect(host["MachServices"] as? [String: Bool] == [AgentHostIdentity.machServiceName: true])
    }

    /// CFBundleVersion is the build number scripts/build-number.sh wrote when the project was generated, the same for the
    /// app and its agent host, which compares builds to replace an older host.
    @Test func theBuildNumberIsTheGeneratedOne() throws {
        let build = try #require(Bundle.main.infoDictionary?["CFBundleVersion"] as? String)
        #expect(Int(build).map { $0 >= 1 } == true)
        let host = Bundle(url: app.appendingPathComponent("Contents/Helpers/CoincideAgentHost.app"))
        #expect(host?.infoDictionary?["CFBundleVersion"] as? String == build)
        let file = Self.repository.appendingPathComponent("BuildNumber.xcconfig")
        let generated = try String(contentsOf: file, encoding: .utf8).split(separator: "\n")
            .first { $0.hasPrefix("CURRENT_PROJECT_VERSION") }?.split(separator: "=").last?.trimmingCharacters(in: .whitespaces)
        #expect(generated == build)
    }
}
