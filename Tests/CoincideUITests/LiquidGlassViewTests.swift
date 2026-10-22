import AppKit
import SwiftUI
import Testing
@testable import Coincide

@MainActor @Test(.timeLimit(.minutes(1)))
func nativeGlassAndOpaqueAccessibilitySurfacesKeepLongContentAndActionsWithinNarrowPanels() async throws {
    _ = NSApplication.shared
    for scheme in [ColorScheme.light, .dark] {
        for width in [CGFloat(320), 680] {
            for opaque in [false, true] {
                for increasedContrast in [false, true] {
                    let content = CoincideGlassGroup {
                        VStack(alignment: .leading, spacing: 10) {
                            VStack(alignment: .leading, spacing: 8) {
                                Label("A provider action is awaiting your review", systemImage: "hand.raised")
                                    .font(.headline)
                                Text("Keep the complete requested action readable in a narrow window. Existing conversations, queued inputs and unsent drafts retain their settings.")
                                    .font(.callout).fixedSize(horizontal: false, vertical: true)
                                HStack { Button("Cancel") {}; Spacer(); Button("Review Action") {} }
                            }
                            .padding(14).modifier(CoincideSurfaceTreatment(cornerRadius: 12,
                                reduceTransparency: opaque, contrast: increasedContrast ? .increased : .standard))
                            Text("Your native workspace").font(.caption).padding(12)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .modifier(CoincideSurfaceTreatment(cornerRadius: 12,
                                    reduceTransparency: opaque, contrast: increasedContrast ? .increased : .standard))
                        }
                    }.environment(\.colorScheme, scheme)
                    let controller = NSHostingController(rootView: content)
                    let size = controller.sizeThatFits(in: .init(width: width, height: 600))
                    #expect(size.width <= width + 1 && size.height > 0 && size.height <= 600)
                    // WindowServer composites real glass and vibrant text;
                    // cacheDisplay is meaningful only for the opaque variant.
                    // The running app's glass is captured separately with Cua.
                    guard opaque, ProcessInfo.processInfo.environment["COINCIDE_RENDER_GLASS"] == "1" else { continue }
                    let appearance = try #require(NSAppearance(named: increasedContrast
                        ? (scheme == .light ? .accessibilityHighContrastAqua : .accessibilityHighContrastDarkAqua)
                        : (scheme == .light ? .aqua : .darkAqua)))
                    let hosting = NSHostingView(rootView: content.padding(12)
                        .frame(width: width + 24, height: size.height + 24))
                    let window = NSWindow(contentRect: .init(x: -10_000, y: -10_000, width: width + 24, height: size.height + 24),
                        styleMask: .borderless, backing: .buffered, defer: false)
                    window.isReleasedWhenClosed = false; window.appearance = appearance; hosting.appearance = appearance
                    window.contentView = hosting; defer { window.close() }
                    hosting.layoutSubtreeIfNeeded(); try await Task.sleep(for: .milliseconds(100)); hosting.layoutSubtreeIfNeeded()
                    let bitmap = try #require(hosting.bitmapImageRepForCachingDisplay(in: hosting.bounds))
                    appearance.performAsCurrentDrawingAppearance { hosting.cacheDisplay(in: hosting.bounds, to: bitmap) }
                    let data = try #require(bitmap.representation(using: .png, properties: [:]))
                    let path = FileManager.default.temporaryDirectory.appendingPathComponent(
                        "coincide-glass-\(opaque ? "opaque" : "glass")-\(increasedContrast ? "contrast" : "standard")-\(Int(width))-\(scheme == .light ? "light" : "dark").png")
                    try data.write(to: path); print("Native glass preview: \(path.path)")
                }
            }
        }
    }
}
