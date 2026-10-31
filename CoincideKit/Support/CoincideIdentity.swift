import Foundation

/// Which Coincide this build is. A Debug build (tests, agents' builds, runs from Xcode) is a separate app with its own
/// bundle IDs, so it never stands in for the installed Coincide: macOS can't take its icon for the installed app's
/// notifications or launch it to open their clicks, and it keeps its own data folder, launchd jobs and Keychain items,
/// so it never reads or changes the installed app's threads, background agents or secrets.
///
/// project.yml sets the same IDs (`COINCIDE_BUNDLE_ID`), and the launchd plists build on them; tests check they agree.
public enum CoincideIdentity {
    public nonisolated static let releaseBundleID = "com.apoorvdarshan.coincide"
    public nonisolated static let debugBundleID = "com.apoorvdarshan.coincide.debug"

    #if DEBUG
    public nonisolated static let isDebug = true
    #else
    public nonisolated static let isDebug = false
    #endif

    /// The app's bundle ID. Its helpers, launchd jobs and Keychain services are named after it (`scoped`).
    public nonisolated static var bundleID: String { isDebug ? debugBundleID : releaseBundleID }

    /// `bundleID.suffix`, such as the agent host's `com.apoorvdarshan.coincide.agent-host`.
    public nonisolated static func scoped(_ suffix: String) -> String { "\(bundleID).\(suffix)" }

    /// What the app is called in Keychain items and other names people see: "Coincide", or "Coincide Debug".
    public nonisolated static var displayName: String { isDebug ? "Coincide Debug" : "Coincide" }

    /// `~/Library/Application Support/Coincide` (`Coincide Debug` for a Debug build), whatever `COINCIDE_DATA_DIR`
    /// says: what launchd's jobs use, since they start without the app's environment.
    public nonisolated static var dataDirectory: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        return base.appendingPathComponent(displayName, isDirectory: true)
    }
}
