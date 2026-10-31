import CoincideKit
import Testing
@testable import Coincide

@MainActor
struct ComputerUseSettingsSearchTests {
    @Test func computerUseSearchFindsItsOwnPane() throws {
        let entries = SettingsSearchResults.entries(kinds: [])
        for query in ["computer use", "accessibility", "screen recording", "desktop", "automation", "TryCua"] {
            #expect(entries.contains { $0.pane == .section(.computerUse) && $0.matches(query) }, "Missing search alias: \(query)")
        }
        let entry = try #require(entries.first { $0.pane == .section(.computerUse) })
        let folder = TemporaryDirectory("computer-use-settings-search")
        let store = AppStore(directory: folder.url)
        let model = SettingsModel(store: store, registry: ProviderRegistry(store: store, providers: []))
        model.navigate(to: entry.pane)
        #expect(model.pane == .section(.computerUse))
        #expect(model.reveal == nil)
        #expect(SettingsSection(rawValue: "computerUse") == .computerUse)
    }
}
