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
            if let url = Bundle.module.url(forResource: name, withExtension: "png", subdirectory: "ProviderLogos"),
               let image = NSImage(contentsOf: url) {
                Image(nsImage: image).resizable().scaledToFit()
            } else { Image(systemName: "terminal") }
        }.frame(width: size, height: size).accessibilityHidden(true)
    }
}
