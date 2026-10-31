import AppKit
import SwiftUI
import Testing

@testable import Coincide
@testable import CoincideKit

@MainActor
private final class RiskPickerProvider: AgentProvider {
    let kind: ProviderKind
    let executableNames = ["sh"]
    let setupHint = ""

    init(_ kind: ProviderKind) { self.kind = kind }

    func detect(executable: URL?, environment: [String: String]) async -> ProviderStatus { ProviderStatus(state: .ready) }
    func models(status: ProviderStatus, environment: [String: String]) async -> [ModelOption] {
        [ModelOption(provider: kind, modelID: "model", displayName: "Model")]
    }
    func makeSession(_ launch: AgentLaunch) -> AgentSession { fatalError("Risk tests never start a session") }
}

/// Antigravity's account-risk glyph and line in the model picker, and how the Settings notice and the acknowledgement
/// sheet look. Nothing here shows a window or opens Settings.
@MainActor
struct AntigravityRiskViewTests {
    /// The folders the stores use, kept until the test ends.
    private let directories = (0..<3).map { _ in TemporaryDirectory("antigravity-risk") }

    private func picker(current: ProviderKind, in directory: Int = 0) async -> (ModelPickerViewController, NSView) {
        let store = AppStore(directory: directories[directory].url)
        let registry = ProviderRegistry(store: store, providers: [RiskPickerProvider(.codex), RiskPickerProvider(.antigravity)])
        await registry.refresh()
        let picker = ModelPickerViewController(current: ModelSelection(provider: current, modelID: "model"), registry: registry, store: store)
        return (picker, picker.view)
    }

    @Test func theRiskLineShowsOnlyOnAntigravitysTab() async throws {
        let (_, view) = await picker(current: .antigravity)
        let row = try #require(descendants(view).compactMap { $0 as? PickerRiskRow }.first)
        #expect(!row.isHidden)

        let codex = try #require(descendants(view).compactMap { $0 as? PickerTabButton }.first { $0.accessibilityLabel() == "Codex" })
        #expect(codex.accessibilityPerformPress())
        #expect(row.isHidden)

        let (_, other) = await picker(current: .codex, in: 1)
        #expect(try #require(descendants(other).compactMap { $0 as? PickerRiskRow }.first).isHidden)
    }

    @Test func onlyAntigravitysTabCarriesTheGlyph() async throws {
        let (_, view) = await picker(current: .codex)
        let tabs = descendants(view).compactMap { $0 as? PickerTabButton }
        let antigravity = try #require(tabs.first { $0.accessibilityLabel() == "Antigravity" })
        let codex = try #require(tabs.first { $0.accessibilityLabel() == "Codex" })
        #expect(antigravity.toolTip?.contains(AntigravityRiskText.glyphHelp) == true)
        #expect(antigravity.accessibilityHelp() == AntigravityRiskText.glyphHelp)
        #expect(codex.toolTip == "Codex")
    }

    /// `TEST_RUNNER_COINCIDE_AGY_RISK_PNG_DIR=<folder>` writes the notice, the sheet and the picker in light and dark.
    @Test func rendersTheNoticeTheSheetAndThePicker() async throws {
        guard let folder = ProcessInfo.processInfo.environment["COINCIDE_AGY_RISK_PNG_DIR"], !folder.isEmpty else { return }
        try FileManager.default.createDirectory(atPath: folder, withIntermediateDirectories: true)
        let gate = AntigravityRiskGate(store: AppStore(directory: directories[2].url))
        let (picker, pickerView) = await picker(current: .antigravity)
        _ = picker
        for (suffix, name) in [("light", NSAppearance.Name.aqua), ("dark", .darkAqua)] {
            let notice = Form { Section { AntigravityRiskNotice() } }
                .formStyle(.grouped)
                .scrollContentBackground(.hidden)
                .background(Color(nsColor: Theme.contentBackground))
                .buttonStyle(ThemedButtonStyle())
                .tint(Color(nsColor: Theme.ink))
            try render(NSHostingView(rootView: notice), size: NSSize(width: 620, height: 230), appearance: name, to: folder, "notice-\(suffix)")
            let sheet = NSHostingView(rootView: AntigravityRiskSheet(gate: gate))
            try render(sheet, size: sheet.fittingSize, appearance: name, to: folder, "sheet-\(suffix)")
            pickerView.appearance = NSAppearance(named: name)
            try render(pickerView, size: pickerView.fittingSize, appearance: name, to: folder, "picker-\(suffix)")
        }
    }

    private func render(_ view: NSView, size: NSSize, appearance: NSAppearance.Name, to folder: String, _ name: String) throws {
        view.appearance = NSAppearance(named: appearance)
        view.frame = NSRect(origin: .zero, size: size)
        view.layoutSubtreeIfNeeded()
        let rep = try #require(view.bitmapImageRepForCachingDisplay(in: view.bounds))
        view.effectiveAppearance.performAsCurrentDrawingAppearance { view.cacheDisplay(in: view.bounds, to: rep) }
        try rep.representation(using: .png, properties: [:])?
            .write(to: URL(fileURLWithPath: folder).appendingPathComponent("\(name).png"))
    }

    private func descendants(_ root: NSView) -> [NSView] { [root] + root.subviews.flatMap(descendants) }
}
