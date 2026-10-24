import AppKit
import CoincideCore
import SwiftUI

struct ProviderLogo: View {
    let provider: ProviderKind
    var size: CGFloat = 20
    @Environment(\.colorScheme) private var colorScheme
    private var name: String { provider == .claude ? "Claude" : colorScheme == .dark ? "OpenAI-white" : "OpenAI-black" }
    var body: some View {
        Group {
            if let url = Self.url(name), let image = NSImage(contentsOf: url) {
                Image(nsImage: image).resizable().scaledToFit()
            } else { Image(systemName: "terminal") }
        }.frame(width: size, height: size).accessibilityHidden(true)
    }

    /// SwiftPM's generated `Bundle.module` only looks beside the app and in the
    /// local build folder, and traps when neither exists. The packaged app keeps
    /// the bundle in Contents/Resources; `swift run` keeps it beside the binary.
    static let resourceBundle: Bundle? = [Bundle.main.resourceURL, Bundle.main.bundleURL]
        .compactMap { $0?.appendingPathComponent("Coincide_Coincide.bundle") }
        .lazy.compactMap(Bundle.init(url:)).first

    static func url(_ name: String) -> URL? {
        resourceBundle?.url(forResource: name, withExtension: "png", subdirectory: "ProviderLogos")
    }
}
