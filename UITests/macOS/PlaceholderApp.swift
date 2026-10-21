// Xcode needs an associated application target to generate its UI test runner.
// CI replaces UITargetAppPath with a signed copy of the SwiftPM-built app.
// This executable must never be the application exercised by a test.
@main enum PlaceholderApp {
    static func main() {
        fatalError("Use script/test_macos_ui.sh to stage the real Coincide app before UI testing.")
    }
}
