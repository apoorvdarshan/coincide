import AppKit
import SwiftUI
import Testing
@testable import Coincide
@testable import CoincideCore

@Test func reasoningDefaultCheckmarkDistinguishesCLIEffortAndExplicitPerModelPreference() {
    let model = ProviderModel(id: "gpt-6-astra", name: "Astra", reasoningEfforts: [
        .init(id: "medium", description: "Balanced"), .init(id: "high", description: "More reasoning"),
        .init(id: "future-effort", description: "An advertised future setting")], defaultReasoningEffort: "high")
    var thread = CodingThread(project: .init(path: "/tmp/coincide-reasoning-view"), model: model.id)
    thread.reasoningEffort = "high"; thread.codexModelSelectionSource = .cliDefault
    #expect(!ReasoningEffortPresentation.isModelDefault(thread: thread, model: model))
    thread.reasoningEffort = "medium"
    #expect(ReasoningEffortPresentation.isModelDefault(thread: thread, model: model))
    thread.codexReasoningPreferences = [model.id: "medium"]
    #expect(!ReasoningEffortPresentation.isModelDefault(thread: thread, model: model))
    #expect(ReasoningEffortPresentation.title("future-effort") == "future-effort")
    #expect(ReasoningEffortPresentation.title("xhigh") == "Extra High")
}

@MainActor @Test(.timeLimit(.minutes(1)))
func nativeProviderReasoningLabelFitsNarrowAndWideHeadersInBothAppearances() async throws {
    _ = NSApplication.shared
    for scheme in [ColorScheme.light, .dark] {
        for width in [CGFloat(160), 480] {
            for extended in [false, true] {
                let content = ProviderModelLabel(provider: "Codex", model: extended
                    ? "An advertised model with a deliberately long descriptive name" : "GPT-6 Astra",
                    effort: extended ? "future-reasoning-option-with-an-opaque-identifier" : "medium")
                    .environment(\.colorScheme, scheme)
                let controller = NSHostingController(rootView: content)
                let size = controller.sizeThatFits(in: .init(width: width, height: 150))
                #expect(size.width <= width + 1 && size.height <= 100 && size.height > 0)
                guard ProcessInfo.processInfo.environment["COINCIDE_RENDER_REASONING"] == "1" else { continue }
                let appearance = try #require(NSAppearance(named: scheme == .light ? .aqua : .darkAqua))
                let hosting = NSHostingView(rootView: content.padding(10).frame(width: width + 20, height: size.height + 20)
                    .background(Color(nsColor: .windowBackgroundColor)))
                let window = NSWindow(contentRect: .init(x: -10_000, y: -10_000, width: width + 20, height: size.height + 20),
                    styleMask: .borderless, backing: .buffered, defer: false)
                window.appearance = appearance; hosting.appearance = appearance
                window.isReleasedWhenClosed = false; window.contentView = hosting
                defer { window.close() }
                hosting.layoutSubtreeIfNeeded(); try await Task.sleep(for: .milliseconds(100)); hosting.layoutSubtreeIfNeeded()
                let bitmap = try #require(hosting.bitmapImageRepForCachingDisplay(in: hosting.bounds))
                appearance.performAsCurrentDrawingAppearance { hosting.cacheDisplay(in: hosting.bounds, to: bitmap) }
                let data = try #require(bitmap.representation(using: .png, properties: [:]))
                let path = FileManager.default.temporaryDirectory.appendingPathComponent(
                    "coincide-reasoning-\(extended ? "long" : "normal")-\(Int(width))-\(scheme == .light ? "light" : "dark").png")
                try data.write(to: path)
                print("Native reasoning preview: \(path.path)")
            }
        }
    }
}
