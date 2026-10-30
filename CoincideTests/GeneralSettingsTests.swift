import CoincideKit
import Foundation
import Testing
@testable import Coincide

@MainActor
struct GeneralSettingsTests {
    @Test func numberFormatBindingAndRestoreDefaultsWriteThroughWithoutResettingProviderChoices() {
        let folder = TemporaryDirectory("general-number-format")
        let store = AppStore(directory: folder.url)
        let registry = ProviderRegistry(store: store, providers: [])
        let model = SettingsModel(store: store, registry: registry)
        let selection = ModelSelection(provider: .codex, modelID: "custom", effort: "high", accountID: "work")
        store.updateSettings {
            $0.defaultSelection = selection
            $0.providers[.codex] = ProviderSettings(customModels: ["custom"])
        }
        let choice = model.binding(\.numberFormat)
        #expect(choice.wrappedValue == .system)
        choice.wrappedValue = .international
        #expect(store.settings.numberFormat == .international)
        #expect(model.settings.numberFormat == .international)
        store.flush()
        #expect(AppStore(directory: folder.url).settings.numberFormat == .international)

        model.update { GeneralSettingsView.restoreDefaults(in: &$0) }
        #expect(choice.wrappedValue == .system)
        #expect(store.settings.defaultSelection == selection)
        #expect(store.settings.settings(for: .codex).customModels == ["custom"])
        store.flush()
        #expect(AppStore(directory: folder.url).settings.numberFormat == .system)
    }

    @Test func numberFormatSearchFindsAndRevealsTheGeneralRow() throws {
        let entries = SettingsSearchResults.entries(kinds: [])
        for query in ["number", "number format", "grouping", "locale", "comma", "commas", "international"] {
            #expect(entries.contains { $0.setting == .numberFormat && $0.matches(query) }, "Missing search alias: \(query)")
        }
        let entry = try #require(entries.first { $0.setting == .numberFormat })
        #expect(entry.pane == .section(.general))
        let folder = TemporaryDirectory("general-number-format-search")
        let store = AppStore(directory: folder.url)
        let model = SettingsModel(store: store, registry: ProviderRegistry(store: store, providers: []))
        model.pane = .section(.about)
        model.navigate(to: entry.pane, reveal: entry.setting)
        #expect(model.pane == .section(.general))
        #expect(model.reveal?.setting == .numberFormat)
    }
}
