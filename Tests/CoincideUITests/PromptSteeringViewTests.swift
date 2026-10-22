import AppKit
import SwiftUI
import Testing
@testable import Coincide
@testable import CoincideCore

@MainActor @Test
func nativeComposerDeliveryActionsKeepQueueDefaultAndAlternateWithoutLosingInputGuards() {
    var actions: [String] = []
    var composer = ComposerView(text: .constant("Follow up"), provider: .codex, permission: .supervised,
        busy: true, submitting: false, hasAttachments: false,
        steeringAvailable: true, steer: { actions.append("steer") },
        attach: {}, importProviders: { _ in }, setPermission: { _ in },
        send: { actions.append("queue") }, stop: {})
    composer.activate(alternate: false)
    composer.activate(alternate: true)
    composer.followUpBehavior = .steer
    composer.activate(alternate: false)
    composer.activate(alternate: true)
    #expect(actions == ["queue", "steer", "steer", "queue"])
    composer.steeringAvailable = false
    composer.activate(alternate: false)
    composer.activate(alternate: true)
    #expect(actions.suffix(2) == ["queue", "queue"])

    let guarded = ComposerView(text: .constant("Keep this unsent"), provider: .codex, permission: .supervised,
        busy: true, submitting: true, hasAttachments: false, followUpBehavior: .steer,
        steeringAvailable: true, steer: { actions.append("unexpected-steer") },
        attach: {}, importProviders: { _ in }, setPermission: { _ in },
        send: { actions.append("unexpected-send") }, stop: {})
    guarded.activate(alternate: false); guarded.activate(alternate: true)
    #expect(actions.count == 6)
}

@MainActor private final class NativeComposerGeometry {
    var frames: [String: CGRect] = [:]
}

@MainActor @Test(.timeLimit(.minutes(1)))
func nativeSteeringComposerAndUnconfirmedRecoveryFitNarrowAndWideWindowsInBothAppearances() async throws {
    _ = NSApplication.shared
    for scheme in [ColorScheme.light, .dark] {
        for width in [CGFloat(320), 680] {
            for scenario in ["queue", "steer", "unavailable"] {
                let geometry = NativeComposerGeometry()
                let content = ComposerView(text: .constant("Keep the complete follow-up input 😀\nDo not start another provider turn."),
                    provider: .claude, permission: .autoAcceptEdits, busy: true, submitting: false,
                    hasAttachments: true, followUpBehavior: scenario == "steer" ? .steer : .queue,
                    steeringAvailable: scenario != "unavailable",
                    steeringExplanation: scenario == "unavailable"
                        ? "Keep this message queued until the active foreground agent releases its work."
                        : "Steer sends to the running model and interrupts its current tools. Future-turn settings stay separate.",
                    steer: {}, attach: {}, referenceFile: {}, importProviders: { _ in }, setPermission: { _ in },
                    send: {}, stop: {}, reportGeometry: { geometry.frames[$0] = $1 })
                    .environment(\.colorScheme, scheme)
                try await captureNativeSteering(content, name: "composer-" + scenario, width: width, scheme: scheme, geometry: geometry)
            }
            for working in [false, true] {
                let content = PromptSteeringStatusContent(working: working, acting: false, message: nil, acknowledge: {})
                    .environment(\.colorScheme, scheme)
                try await captureNativeSteering(content, name: working ? "sending" : "unconfirmed", width: width, scheme: scheme)
            }
        }
    }
}

@MainActor private func captureNativeSteering<Content: View>(_ content: Content, name: String, width: CGFloat,
    scheme: ColorScheme, geometry: NativeComposerGeometry? = nil) async throws {
    let controller = NSHostingController(rootView: content)
    let size = controller.sizeThatFits(in: CGSize(width: width, height: 500))
    #expect(size.width <= width + 1 && size.height <= 500)
    let hosting = NSHostingView(rootView: content.background(Color(nsColor: .windowBackgroundColor)).frame(width: width, height: size.height))
    let window = NSWindow(contentRect: .init(x: -10_000, y: -10_000, width: width, height: size.height),
        styleMask: .borderless, backing: .buffered, defer: false)
    let appearance = try #require(NSAppearance(named: scheme == .light ? .aqua : .darkAqua))
    window.appearance = appearance; hosting.appearance = appearance; window.isReleasedWhenClosed = false; window.contentView = hosting
    defer { window.close() }
    hosting.layoutSubtreeIfNeeded(); try await Task.sleep(for: .milliseconds(100)); hosting.layoutSubtreeIfNeeded()
    if let geometry {
        let bounds = try #require(geometry.frames["bounds"]), send = try #require(geometry.frames["send"])
        #expect(bounds.width <= width + 1 && send.width > 0 && send.height > 0)
        #expect(bounds.insetBy(dx: -1, dy: -1).contains(send), "The send/steer action must remain inside the native composer.")
    }
    guard ProcessInfo.processInfo.environment["COINCIDE_RENDER_STEERING"] == "1" else { return }
    let bitmap = try #require(hosting.bitmapImageRepForCachingDisplay(in: hosting.bounds))
    appearance.performAsCurrentDrawingAppearance { hosting.cacheDisplay(in: hosting.bounds, to: bitmap) }
    let data = try #require(bitmap.representation(using: .png, properties: [:]))
    let url = FileManager.default.temporaryDirectory.appendingPathComponent("coincide-steering-\(name)-\(Int(width))-\(scheme == .light ? "light" : "dark").png")
    try data.write(to: url)
    print("Native steering preview: \(url.path)")
}
