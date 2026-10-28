import Foundation
import Testing

@testable import CoincideKit

/// Favorite and hidden models (T3 Code's model preferences) and the speed a selection runs at.
@MainActor
struct ModelPreferencesTests {
    private func decode<T: Decodable>(_ type: T.Type, _ json: String) throws -> T {
        try JSONDecoder().decode(type, from: Data(json.utf8))
    }

    private func option(_ provider: ProviderKind, _ id: String) -> ModelOption {
        ModelOption(provider: provider, modelID: id, displayName: id)
    }

    private func reference(_ provider: ProviderKind, _ id: String) -> ModelReference {
        ModelReference(provider: provider, modelID: id)
    }

    // MARK: Settings

    @Test func favoritesAndHiddenModelsSaveAndOlderFilesHaveNone() throws {
        #expect(try decode(AppSettings.self, #"{"fontSize": 15}"#).favoriteModels.isEmpty)
        #expect(try decode(AppSettings.self, #"{"fontSize": 15}"#).hiddenModels.isEmpty)
        var settings = AppSettings()
        settings.setFavorite(true, reference(.codex, "gpt-6-astra"))
        settings.setFavorite(true, reference(.claude, "opus"))
        settings.setHidden(true, reference(.claude, "claude-haiku-4-5"))
        let decoded = try JSONDecoder().decode(AppSettings.self, from: JSONEncoder().encode(settings))
        #expect(decoded == settings)
        // Kept in the order they were starred.
        #expect(decoded.favoriteModels == [reference(.codex, "gpt-6-astra"), reference(.claude, "opus")])
    }

    @Test func anUnreadableEntryIsSkippedAndTheRestKept() throws {
        let settings = try decode(
            AppSettings.self,
            #"""
            {"favoriteModels": [{"provider": "acp:dsh", "modelID": "x"}, {"provider": "claude", "modelID": "opus"}, 7],
             "hiddenModels": {"claude": "haiku"}, "fontSize": 15}
            """#)
        #expect(settings.favoriteModels == [reference(.claude, "opus")])
        #expect(settings.hiddenModels.isEmpty)
        #expect(settings.fontSize == 15)
    }

    @Test func starringShowsAHiddenModelAndHidingUnstarsIt() {
        var settings = AppSettings()
        let opus = reference(.claude, "opus")
        settings.setHidden(true, opus)
        settings.setFavorite(true, opus)
        #expect(settings.isFavorite(opus) && !settings.isHidden(opus))
        settings.setHidden(true, opus)
        #expect(!settings.isFavorite(opus) && settings.isHidden(opus))
        settings.setHidden(false, opus)
        #expect(!settings.isHidden(opus))
        // Starring twice keeps one entry.
        settings.setFavorite(true, opus)
        settings.setFavorite(true, opus)
        #expect(settings.favoriteModels == [opus])
        settings.setFavorite(false, opus)
        #expect(settings.favoriteModels.isEmpty)
    }

    @Test func thePickerListsFavoritesFirstAndLeavesHiddenOnesOut() {
        let models = ["default", "opus", "sonnet", "haiku", "claude-opus-4-6"].map { option(.claude, $0) }
        var settings = AppSettings()
        settings.setFavorite(true, reference(.claude, "haiku"))
        settings.setFavorite(true, reference(.claude, "opus"))
        settings.setHidden(true, reference(.claude, "claude-opus-4-6"))
        settings.setHidden(true, reference(.claude, "sonnet"))
        // Favorites keep the agent's order, not the order they were starred in.
        #expect(settings.pickerModels(models, current: nil).map(\.modelID) == ["opus", "haiku", "default"])
        // The current model shows even when hidden.
        let current = ModelSelection(provider: .claude, modelID: "sonnet")
        #expect(settings.pickerModels(models, current: current).map(\.modelID) == ["opus", "haiku", "default", "sonnet"])
        // The same model id of another agent is a different model.
        #expect(settings.pickerModels([option(.codex, "sonnet")], current: nil).map(\.modelID) == ["sonnet"])
    }

    @Test func theFavoritesTabGroupsEveryAgentsFavoritesInDisplayOrder() {
        let models = [option(.claude, "opus"), option(.claude, "haiku"), option(.codex, "gpt-6-astra"), option(.codex, "gpt-6-luna")]
        var settings = AppSettings()
        settings.setFavorite(true, reference(.codex, "gpt-6-luna"))
        settings.setFavorite(true, reference(.claude, "haiku"))
        settings.setFavorite(true, reference(.cursor, "composer-2"))
        #expect(settings.favorites(in: models).map(\.id) == ["claude/haiku", "codex/gpt-6-luna"])
    }

    @Test func favoritesPersistWithTheSettings() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("coincide-favorites-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = AppStore(directory: directory)
        store.updateSettings { settings in
            settings.setFavorite(true, reference(.claude, "opus"))
            settings.setHidden(true, reference(.codex, "gpt-6-luna"))
        }
        store.flush()
        let reopened = AppStore(directory: directory).settings
        #expect(reopened.favoriteModels == [reference(.claude, "opus")])
        #expect(reopened.hiddenModels == [reference(.codex, "gpt-6-luna")])
    }

    @Test func theRegistryListsReadyAgentsFavoritesAndHidesHiddenModels() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("coincide-favorites-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = AppStore(directory: directory)
        let claude = ProbedProvider(kind: .claude)
        let codex = ProbedProvider(kind: .codex)
        codex.states = [.notInstalled]
        let registry = ProviderRegistry(store: store, providers: [claude, codex])
        await registry.refresh()
        store.updateSettings { settings in
            settings.providers[.claude] = ProviderSettings(customModels: ["opus", "sonnet"])
            settings.setFavorite(true, reference(.claude, "sonnet"))
            settings.setFavorite(true, reference(.codex, "m1"))
            settings.setHidden(true, reference(.claude, "opus"))
        }
        #expect(registry.pickerModels(for: .claude, current: nil).map(\.modelID) == ["sonnet", "m1"])
        // Codex is not ready, so its favorite waits until it is.
        #expect(registry.favoriteModels.map(\.id) == ["claude/sonnet"])
    }

    // MARK: Speed

    @Test func aSelectionReadsItsSpeedLeniently() throws {
        let old = try decode(ModelSelection.self, #"{"provider": "codex", "modelID": "gpt-6-astra", "effort": "high"}"#)
        #expect(old == ModelSelection(provider: .codex, modelID: "gpt-6-astra", effort: "high"))
        #expect(old.speed == nil)
        let fast = ModelSelection(provider: .claude, modelID: "opus", effort: "high", speed: "fast")
        #expect(try JSONDecoder().decode(ModelSelection.self, from: JSONEncoder().encode(fast)) == fast)
        let odd = try decode(ModelSelection.self, #"{"provider": "claude", "modelID": "opus", "effort": 3, "speed": true}"#)
        #expect(odd == ModelSelection(provider: .claude, modelID: "opus"))
        // Standard speed writes nothing, so older versions read the selection as before.
        let data = try JSONEncoder().encode(ModelSelection(provider: .claude, modelID: "opus"))
        #expect(!String(decoding: data, as: UTF8.self).contains("speed"))
    }

    @Test func aCatalogFromBeforeSpeedControlsStillDecodes() throws {
        let model = try decode(ModelOption.self,
            #"{"provider":"claude","modelID":"opus","displayName":"Opus","efforts":["high"],"supportsImages":true}"#)
        #expect(model.speeds.isEmpty)
        #expect(model.modelID == "opus" && model.efforts == ["high"])
    }

    @Test func aModelFindsTheSpeedsItOffers() {
        let ultrafast = ModelSpeed(id: "ultrafast", name: "Ultrafast")
        let model = ModelOption(provider: .codex, modelID: "gpt-6-astra", displayName: "GPT-6 Astra", speeds: [.fast, ultrafast])
        #expect(model.speed("ultrafast") == ultrafast)
        #expect(model.speed("fast") == .fast)
        #expect(model.speed("flex") == nil)
        #expect(model.speed(nil) == nil)
        #expect(ModelOption(provider: .claude, modelID: "haiku", displayName: "Haiku").speeds.isEmpty)
    }
}
