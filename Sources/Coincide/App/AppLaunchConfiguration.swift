import Foundation

/// The UI-test copy has a different identity and must never fall back to the user's workspace.
enum AppLaunchConfiguration {
    static let uiTestingBundleIdentifier = "com.apoorvdarshan.coincide.uitesting"

    static func databaseURL(bundleIdentifier: String?, environment: [String: String]) throws -> URL? {
        guard bundleIdentifier == uiTestingBundleIdentifier else { return nil }
        #if DEBUG
        guard environment["COINCIDE_UI_TESTING"] == "1",
              let path = environment["COINCIDE_UI_TEST_ROOT"], path.hasPrefix("/"),
              URL(fileURLWithPath: path).lastPathComponent.hasPrefix("coincide-ui-testing-") else {
            throw CocoaError(.fileReadInvalidFileName)
        }
        let root = URL(fileURLWithPath: path, isDirectory: true).standardizedFileURL
        let values = try root.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
        guard values.isDirectory == true, values.isSymbolicLink != true else { throw CocoaError(.fileReadInvalidFileName) }
        return root.appendingPathComponent("workspace.sqlite")
        #else
        throw CocoaError(.featureUnsupported)
        #endif
    }
}
