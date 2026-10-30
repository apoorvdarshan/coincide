import Foundation
import Testing

@testable import CoincideKit

/// Desired choices belong to a provider account, while the active selection always obeys its model's catalog.
@MainActor
struct ThreadModelPreferencesTests {
    private func model(_ provider: ProviderKind, _ id: String = "capable") -> ModelOption {
        let speeds: [ModelSpeed] = switch provider {
        case .claude: [.fast]
        case .codex: [ModelSpeed(id: "priority", name: "Fast")]
        default: []
        }
        return ModelOption(
            provider: provider, modelID: id, displayName: id, efforts: ["low", "high"], defaultEffort: "low", speeds: speeds)
    }

    private func pick(_ option: ModelOption, account: String? = nil, effort: String? = nil, speed: String? = nil) -> ModelSelection {
        ModelSelection(provider: option.provider, modelID: option.modelID, effort: effort, speed: speed, accountID: account)
    }

    @Test func allSixProvidersRestoreTheirOwnChoicesWithoutBorrowingAnotherProvidersValues() throws {
        let claude = model(.claude)
        var thread = ChatThread(projectID: UUID(), selection: pick(claude, effort: "high", speed: "fast"))
        for provider in ProviderKind.allCases {
            let option = model(provider)
            thread.selectModel(pick(option), option: option)
            // First visits get this model's default, even though the outgoing provider used the same effort names.
            #expect(thread.selection.effort == (provider == .claude ? "high" : "low"))
            #expect(thread.selection.speed == (provider == .claude ? "fast" : nil))
            thread.selectModel(
                pick(option, effort: "high", speed: option.speeds.first?.id), option: option,
                rememberingEffort: true, rememberingSpeed: true)
        }
        // A round trip preserves the desired settings for every provider, including those without speed controls.
        thread = try JSONDecoder().decode(ChatThread.self, from: JSONEncoder().encode(thread))
        for provider in ProviderKind.allCases.reversed() {
            let option = model(provider)
            thread.selectModel(pick(option), option: option)
            #expect(thread.selection.effort == "high")
            #expect(thread.selection.speed == option.speeds.first?.id)
        }
        #expect(thread.modelPreferences?.count == ProviderKind.allCases.count)
    }

    @Test func unsupportedModelsUseDefaultsWithoutErasingDesiredReasoningOrSpeed() {
        let capable = model(.claude)
        let limited = ModelOption(provider: .claude, modelID: "limited", displayName: "Limited", efforts: ["low"], defaultEffort: "low")
        var thread = ChatThread(projectID: UUID(), selection: pick(capable, effort: "high", speed: "fast"))
        thread.selectModel(pick(limited), option: limited)
        #expect(thread.selection == pick(limited, effort: "low"))
        #expect(thread.modelPreferences?["claude/default"] == ProviderModelPreferences(effort: "high", speed: "fast"))
        // Leaving from a temporary fallback must not replace the desired values with that fallback.
        let other = model(.codex)
        thread.selectModel(pick(other), option: other)
        #expect(thread.selection == pick(other, effort: "low"))
        thread.selectModel(pick(capable), option: capable)
        #expect(thread.selection == pick(capable, effort: "high", speed: "fast"))
        // Even a missing catalog must not destroy the user's desired values.
        thread.selectModel(pick(capable), option: nil)
        #expect(thread.selection.effort == nil && thread.selection.speed == nil)
        thread.selectModel(pick(capable), option: capable)
        #expect(thread.selection == pick(capable, effort: "high", speed: "fast"))
    }

    @Test func explicitFallbackChoicesReplaceDesiredValuesEvenWhenTheActiveSelectionDoesNotChange() {
        let capable = model(.codex)
        let limited = ModelOption(provider: .codex, modelID: "limited", displayName: "Limited", efforts: ["low"], defaultEffort: "low")
        var thread = ChatThread(projectID: UUID(), selection: pick(capable, effort: "high", speed: "priority"))
        thread.selectModel(pick(limited), option: limited)
        let fallback = thread.selection
        thread.selectModel(fallback, option: limited, rememberingEffort: true, rememberingSpeed: true)
        #expect(thread.selection == fallback)
        #expect(thread.modelPreferences?["codex/default"] == ProviderModelPreferences(effort: "low", speed: nil))
        thread.selectModel(pick(capable), option: capable)
        #expect(thread.selection == pick(capable, effort: "low", speed: nil))
    }

    @Test func accountsHaveIndependentPreferencesAndDefaultAccountIDsNormalize() {
        let option = model(.codex)
        var thread = ChatThread(projectID: UUID(), selection: pick(option, effort: "high", speed: "priority"))
        thread.selectModel(pick(option, account: "work"), option: option)
        #expect(thread.selection == pick(option, account: "work", effort: "low"))
        thread.selectModel(pick(option, account: "work", effort: "high"), option: option, rememberingEffort: true)
        // Explicit Standard on the work account stays Standard after the default account runs Fast again.
        thread.selectModel(pick(option, account: "default"), option: option)
        #expect(thread.selection == pick(option, effort: "high", speed: "priority"))
        thread.selectModel(pick(option, account: "work"), option: option)
        #expect(thread.selection == pick(option, account: "work", effort: "high"))
        #expect(Set(thread.modelPreferences?.keys.map { $0 } ?? []) == ["codex/default", "codex/work"])
    }

    @Test func providerSpecificEffortsAreNeverSentToAnIncompatibleModel() {
        let claude = ModelOption(
            provider: .claude, modelID: "opus", displayName: "Opus", efforts: ["high", "ultrathink"], defaultEffort: "high", speeds: [.fast])
        let agy = ModelOption(provider: .antigravity, modelID: "gemini-high", displayName: "Gemini High")
        var thread = ChatThread(projectID: UUID(), selection: pick(claude, effort: "ultrathink", speed: "fast"))
        thread.selectModel(pick(agy), option: agy)
        #expect(thread.selection.effort == nil && thread.selection.speed == nil)
        thread.selectModel(pick(claude), option: claude)
        #expect(thread.selection == pick(claude, effort: "ultrathink", speed: "fast"))
    }

    @Test func oldThreadsSeedTheirCurrentChoicesAndNewThreadsKeepExistingDefaults() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("coincide-model-choices-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: folder) }
        let store = AppStore(directory: folder)
        let project = store.addProject(at: folder)
        let option = model(.claude)
        let initial = pick(option, effort: "high", speed: "fast")
        let thread = store.createThread(in: project.id, selection: initial)
        #expect(thread.modelPreferences == nil)
        let defaults = store.settings.defaultSelection
        let limited = ModelOption(provider: .claude, modelID: "limited", displayName: "Limited")
        store.selectModel(thread.id, selection: pick(limited), option: limited)
        store.flush()
        // Reads the summary index first, then lazily loads the full thread and its bank after a restart.
        let reopened = AppStore(directory: folder)
        #expect(reopened.summary(thread.id)?.selection.modelID == "limited")
        reopened.selectModel(thread.id, selection: pick(option), option: option)
        #expect(reopened.thread(thread.id)?.selection == initial)
        #expect(reopened.settings.defaultSelection == defaults)
        #expect(reopened.createThread(in: project.id).selection == defaults)
        let explicit = ProjectThreadDefaults(selection: pick(option, effort: "low"), accessMode: .approval)
        reopened.updateProject(project.id) { $0.threadDefaults = explicit }
        #expect(reopened.createThread(in: project.id).selection == explicit.selection)
        reopened.flush()
    }
}
