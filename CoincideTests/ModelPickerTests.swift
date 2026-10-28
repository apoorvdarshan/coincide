import AppKit
import Testing

@testable import Coincide
@testable import CoincideKit

@MainActor
private final class PickerProvider: AgentProvider {
    let kind = ProviderKind.codex
    let executableNames = ["sh"]
    let setupHint = ""
    func detect(executable: URL?, environment: [String: String]) async -> ProviderStatus { ProviderStatus(state: .ready) }
    func models(status: ProviderStatus, environment: [String: String]) async -> [ModelOption] {
        [ModelOption(provider: .codex, modelID: "a", displayName: "A", speeds: [.fast]),
         ModelOption(provider: .codex, modelID: "b", displayName: "B")]
    }
    func makeSession(_ launch: AgentLaunch) -> AgentSession { fatalError("Picker tests never start a session") }
}

@MainActor
struct ModelPickerTests {
    @Test func favoriteAndHideMenusChangeThePickerWithoutSelectingAModel() async throws {
        let directory = TemporaryDirectory("model-picker")
        let store = AppStore(directory: directory.url)
        let registry = ProviderRegistry(store: store, providers: [PickerProvider()])
        await registry.refresh()
        let picker = ModelPickerViewController(current: ModelSelection(provider: .codex, modelID: "a"), registry: registry, store: store)
        var selections = 0
        picker.onSelect = { _ in selections += 1 }
        let table = try #require(descendants(picker.view).compactMap { $0 as? ThemedPopupTableView }.first)
        let menu = try #require(table.rowMenu?(1))
        menu.performActionForItem(at: 0)
        #expect(store.settings.isFavorite(ModelReference(provider: .codex, modelID: "b")))
        #expect(selections == 0)
        // The favorite moves to the first row; hiding it removes both its favorite and its row.
        let movedMenu = try #require(table.rowMenu?(0))
        movedMenu.performActionForItem(at: 1)
        #expect(store.settings.isHidden(ModelReference(provider: .codex, modelID: "b")))
        #expect(!store.settings.isFavorite(ModelReference(provider: .codex, modelID: "b")))
        #expect(table.numberOfRows == 1)
        #expect(selections == 0)
        #expect(table.rowMenu?(0)?.items[1].isEnabled == false) // Current model stays available.
    }

    @Test func speedChipsApplyFastAndReturnToStandardWithoutClosing() async throws {
        let directory = TemporaryDirectory("model-speed")
        let store = AppStore(directory: directory.url)
        let registry = ProviderRegistry(store: store, providers: [PickerProvider()])
        await registry.refresh()
        let picker = ModelPickerViewController(current: ModelSelection(provider: .codex, modelID: "a"), registry: registry, store: store)
        var speeds: [String?] = []
        var closed = false
        picker.onSpeed = { speeds.append($0) }
        picker.close = { closed = true }
        func chip(_ title: String) throws -> PickerChip {
            try #require(descendants(picker.view).compactMap { $0 as? PickerChip }.first { $0.accessibilityLabel() == title })
        }
        #expect(try chip("Fast").accessibilityPerformPress())
        #expect(try chip("Standard").accessibilityPerformPress())
        #expect(speeds == ["fast", nil])
        #expect(!closed)
    }

    private func descendants(_ root: NSView) -> [NSView] { [root] + root.subviews.flatMap(descendants) }
}
