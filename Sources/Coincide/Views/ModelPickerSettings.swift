import CoincideCore
import SwiftUI

/// Preferences affect discovery only, never a conversation's captured model.
enum ModelPickerPreferences {
    static let key = "modelPickerHiddenModels"
    static func id(_ provider: ProviderKind, _ model: String) -> String { provider.rawValue + ":" + model }
    static func hidden(_ value: String) -> Set<String> {
        Set((try? JSONDecoder().decode([String].self, from: Data(value.utf8))) ?? [])
    }
    static func setting(_ value: String, provider: ProviderKind, model: String, visible: Bool) -> String {
        var ids = hidden(value)
        if visible { ids.remove(id(provider, model)) } else { ids.insert(id(provider, model)) }
        return (try? String(decoding: JSONEncoder().encode(ids.sorted()), as: UTF8.self)) ?? value
    }
}

extension PermissionMode {
    func nativeTitle(for provider: ProviderKind) -> String {
        if provider == .claude {
            switch self {
            case .supervised: "Default"
            case .autoAcceptEdits: "Accept edits"
            case .auto: "Auto"
            case .fullAccess: "Bypass permissions"
            }
        } else {
            switch self {
            case .supervised: "Read-only"
            case .autoAcceptEdits: "Workspace write"
            case .auto: "Approve for me"
            case .fullAccess: "Full access"
            }
        }
    }
}

struct ModelPickerSettings: View {
    @Bindable var store: WorkspaceStore
    @AppStorage(ModelPickerPreferences.key) private var hiddenModels = "[]"
    var body: some View {
        Section("Models in the composer") {
            Text("Choose the models shown in the main picker. Hidden models remain available under All models.")
                .font(.callout).foregroundStyle(.secondary)
            ForEach(ProviderKind.builtIn) { provider in
                let models = store.models(for: provider)
                if !models.isEmpty {
                    HStack(spacing: 8) { ProviderLogo(provider: provider); Text(provider.name).font(.headline) }
                    ForEach(models) { model in
                        Toggle(model.name, isOn: Binding(get: {
                            !ModelPickerPreferences.hidden(hiddenModels).contains(ModelPickerPreferences.id(provider, model.id))
                        }, set: { visible in
                            hiddenModels = ModelPickerPreferences.setting(hiddenModels, provider: provider, model: model.id, visible: visible)
                        }))
                        .accessibilityIdentifier("model-visible-" + ModelPickerPreferences.id(provider, model.id))
                    }
                } else {
                    LabeledContent(provider.name, value: store.pickerProviderAvailable(provider) ? "Load models to choose" : "CLI not installed")
                }
                if let error = store.modelCatalogErrors[provider] {
                    Text(error).font(.caption).foregroundStyle(.secondary).textSelection(.enabled)
                }
            }
            HStack {
                Button(store.modelPickerLoading ? "Loading…" : "Refresh models") { Task { await store.refreshPickerModels(force: true) } }
                    .disabled(store.modelPickerLoading)
                Button("Show all models") { hiddenModels = "[]" }
                    .disabled(ModelPickerPreferences.hidden(hiddenModels).isEmpty)
            }
        }
        .task { await store.refreshPickerModels() }
    }
}
