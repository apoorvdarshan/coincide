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
    let openAgentSettings: (ProviderKind) -> Void
    @AppStorage(ModelPickerPreferences.key) private var hiddenModels = "[]"

    var body: some View {
        VStack(alignment: .leading, spacing: 22) {
            SettingsCard {
                SettingsRow(title: "Models in the composer", subtitle: "Choose what appears in the model picker. Hidden models remain available under All models.") {
                    Button(store.modelPickerLoading ? "Loading…" : "Refresh") {
                        Task { await store.refreshPickerModels(force: true) }
                    }
                    .buttonStyle(SettingsActionButtonStyle())
                    .disabled(store.modelPickerLoading)
                    .accessibilityIdentifier("models-refresh")
                }
                SettingsDivider()
                SettingsRow(title: "Show all models", subtitle: "Restore every available model to the main picker.") {
                    Button("Show all") { hiddenModels = "[]" }
                        .buttonStyle(SettingsActionButtonStyle())
                        .disabled(ModelPickerPreferences.hidden(hiddenModels).isEmpty)
                }
            }
            ForEach(ProviderKind.builtIn) { provider in
                providerCard(provider)
            }
        }
        .task { await store.refreshPickerModels() }
    }

    private func providerCard(_ provider: ProviderKind) -> some View {
        let models = store.models(for: provider)
        return SettingsCard {
            HStack(spacing: 10) {
                ProviderLogo(provider: provider, size: 22)
                Text(provider.name).font(.system(size: 13, weight: .medium))
                Spacer()
                if !models.isEmpty {
                    Text("\(models.count) models").font(.system(size: 12)).foregroundStyle(.secondary)
                }
            }.padding(.vertical, 14)
            SettingsDivider()
            if models.isEmpty && store.modelPickerLoading {
                SettingsRow(title: "Loading models…", subtitle: "Reading the available models from this CLI.") {
                    ProgressView().controlSize(.small)
                }
            } else if models.isEmpty {
                SettingsRow(title: store.pickerProviderAvailable(provider) ? "No models loaded" : "CLI not installed",
                            subtitle: store.pickerProviderAvailable(provider) ? "Refresh to load models from this agent." : "Install the agent CLI and sign in to use its models.") {
                    Button("Agent settings") { openAgentSettings(provider) }
                        .buttonStyle(SettingsActionButtonStyle())
                }
            } else {
                ForEach(models) { model in
                    if model.id != models.first?.id { SettingsDivider() }
                    SettingsRow(title: LocalizedStringKey(model.name)) {
                        Toggle(model.name, isOn: Binding(get: {
                            !ModelPickerPreferences.hidden(hiddenModels).contains(ModelPickerPreferences.id(provider, model.id))
                        }, set: { visible in
                            hiddenModels = ModelPickerPreferences.setting(hiddenModels, provider: provider, model: model.id, visible: visible)
                        }))
                        .labelsHidden().toggleStyle(.switch)
                        .accessibilityLabel(model.name)
                        .accessibilityIdentifier("model-visible-" + ModelPickerPreferences.id(provider, model.id))
                    }
                    .help(model.id)
                }
            }
            if let error = store.modelCatalogErrors[provider] {
                SettingsDivider()
                Text(error).font(.system(size: 12)).foregroundStyle(.secondary)
                    .textSelection(.enabled).fixedSize(horizontal: false, vertical: true)
                    .padding(.vertical, 14)
            }
        }
    }
}
