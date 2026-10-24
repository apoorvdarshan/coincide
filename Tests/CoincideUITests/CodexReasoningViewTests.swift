import AppKit
import SwiftUI
import Testing
@testable import Coincide
@testable import CoincideCore

@MainActor @Test(.timeLimit(.minutes(1)))
func nativeProviderMenuHugsShortLabelsAndBoundsLongModelsInNarrowHeaders() async throws {
    _ = NSApplication.shared
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("coincide-provider-menu-" + UUID().uuidString)
    let store = WorkspaceStore(databaseURL: root.appendingPathComponent("workspace.sqlite"))
    defer { try? FileManager.default.removeItem(at: root) }
    for model in ["", "GPT", "GPT-6 Astra", String(repeating: "An advertised long model name ", count: 12)] {
        var thread = CodingThread(project: .init(path: root.path), model: model)
        if !model.isEmpty && model != "GPT" { thread.reasoningEffort = "medium" }
        let host = NSHostingController(rootView: ProviderMenu(store: store, thread: thread))
        let wide = host.sizeThatFits(in: .init(width: 1_000, height: 100))
        #expect(wide.width <= 282 && wide.height <= 100)
        if model.isEmpty {
            // The current caption is "Codex default", not the former "Codex".
            // Compare its actual intrinsic content, so a widened hover area fails
            // without imposing an obsolete fixed bound on the longer caption.
            let caption = NSHostingController(rootView: HStack(spacing: 5) {
                ProviderLogo(provider: .codex, size: 14)
                Text("Codex default").lineLimit(1)
                Image(systemName: "chevron.down").font(.system(size: 9, weight: .medium))
            }.font(.system(size: 13)).fixedSize())
            let intrinsic = caption.sizeThatFits(in: .init(width: 1_000, height: 100))
            #expect(abs(wide.width - (intrinsic.width + 12)) <= 1,
                "Only the label and its twelve points of horizontal hit padding may widen the hover target.")
        }
        if model == "GPT" { #expect(wide.width < 120, "Short model labels must keep an intrinsic hover target.") }
        let narrow = host.sizeThatFits(in: .init(width: 160, height: 100))
        #expect(narrow.width <= 161 && narrow.height <= 100)
    }
    await store.shutdown()
}

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
