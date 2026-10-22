import CoincideCore
import SwiftUI

struct ProviderMenu: View {
    var store: WorkspaceStore
    let thread: CodingThread
    var body: some View {
        Menu {
            if thread.messages.isEmpty {
                ForEach(ProviderKind.builtIn) { provider in
                    Button { store.setProvider(provider, id: thread.id) } label: {
                        if provider == thread.provider { Label(provider.name, systemImage: "checkmark") } else { Text(provider.name) }
                    }
                }
                ForEach(store.snapshot.acpAgents) { agent in
                    Button { store.setACPAgent(agent, id: thread.id) } label: {
                        if thread.acpAgent == agent { Label(agent.name, systemImage: "checkmark") } else { Text(agent.name) }
                    }
                }
                Divider()
            }
            if thread.provider == .codex {
                Button { _ = store.useCodexDefaultModel(thread.id) } label: {
                    choice("CLI Default Model", selected: thread.codexModelSelectionSource == .cliDefault)
                }
                .disabled(store.isReadingCodexModelDefaults(thread.id) || !store.workspaceReady(for: thread))
                .accessibilityIdentifier("codex-model-default")
                .help("Read this checkout's CLI default model. Saved reasoning preferences for that model are kept.")
            } else {
                Button("Default Model") { store.setModel("", id: thread.id) }
            }
            ForEach(store.models(for: thread)) { model in
                Button { store.setModel(model.id, id: thread.id) } label: {
                    choice(model.name, selected: thread.model == model.id && thread.codexModelSelectionSource != .cliDefault)
                }.accessibilityIdentifier("provider-model-" + model.id)
            }
            if let model = store.codexReasoningModel(threadID: thread.id), !model.reasoningEfforts.isEmpty {
                Divider()
                reasoningMenu(model)
            }
            if thread.provider == .acp {
                Divider()
                Button("Reset Agent Options") { store.resetAgentOptions(thread.id) }
                if let options = thread.providerMetadata?["configOptions"].array {
                    ForEach(options, id: \.self) { option in
                        if option["type"].string == "select", option["category"].string != "model", let id = ACPConfigurationOptions.id(option) {
                            Menu(option["name"].string ?? id) {
                                Button("Agent Default") {
                                    if option["configId"].string != nil { store.setAgentConfiguration(id, value: nil, id: thread.id) }
                                    else { store.setAgentConfig(id, value: nil, id: thread.id) }
                                }
                                ForEach(ACPConfigurationOptions.values(option), id: \.self) { value in
                                    if let selected = value["value"].string {
                                        Button(value["name"].string ?? selected) {
                                            if option["configId"].string != nil { store.setAgentConfiguration(id, value: .string(selected), id: thread.id) }
                                            else { store.setAgentConfig(id, value: selected, id: thread.id) }
                                        }
                                    }
                                }
                            }
                        } else if option["type"].string == "boolean", let id = ACPConfigurationOptions.id(option) {
                            Toggle(option["name"].string ?? id, isOn: Binding(
                                get: { (thread.agentConfiguration?[id] ?? option["currentValue"]) == .bool(true) },
                                set: { store.setAgentConfiguration(id, value: .bool($0), id: thread.id) }))
                        }
                    }
                } else {
                    Button("Agent Default Mode") { store.setAgentMode(nil, id: thread.id) }
                    ForEach(thread.providerMetadata?["modes"]["availableModes"].array ?? [], id: \.self) { mode in
                        if let id = mode["id"].string { Button(mode["name"].string ?? id) { store.setAgentMode(id, id: thread.id) } }
                    }
                }
            }
            Divider()
            Button("Refresh Models") { Task { await store.refreshModels(provider: thread.provider) } }
                .disabled(thread.provider == .acp && !store.workspaceReady(for: thread))
        } label: {
            ProviderModelLabel(provider: thread.providerName,
                model: thread.model.isEmpty ? nil : store.models(for: thread).first(where: { $0.id == thread.model })?.name ?? thread.model,
                effort: thread.provider == .codex ? thread.reasoningEffort : nil)
        }
        .menuStyle(.borderlessButton).fixedSize(horizontal: false, vertical: true)
        .accessibilityLabel("Provider and model")
        .accessibilityIdentifier("provider-model-menu")
    }
    private func reasoningMenu(_ model: ProviderModel) -> some View {
        Menu("Reasoning") {
            if let effort = model.codexDefaultReasoningEffort {
                Button { _ = store.setCodexReasoningEffort(nil, model: model, threadID: thread.id) } label: {
                    choice(String(localized: "Model Default (\(ReasoningEffortPresentation.title(effort)))"),
                        selected: ReasoningEffortPresentation.isModelDefault(thread: thread, model: model))
                }
                .accessibilityIdentifier("codex-reasoning-default")
                .help("Use the model's default reasoning effort and remove its saved override.")
            }
            ForEach(model.reasoningEfforts) { option in
                Button { _ = store.setCodexReasoningEffort(option.id, model: model, threadID: thread.id) } label: {
                    choice(ReasoningEffortPresentation.title(option.id), selected: thread.reasoningEffort == option.id
                        && !ReasoningEffortPresentation.isModelDefault(thread: thread, model: model))
                }
                .accessibilityIdentifier("codex-reasoning-" + option.id)
                .help(option.description)
            }
        }
        .accessibilityIdentifier("codex-reasoning-menu")
        .help("Applies to future turns. Steering keeps the running turn's model and reasoning effort.")
    }
    @ViewBuilder private func choice(_ title: String, selected: Bool) -> some View {
        if selected { Label(title, systemImage: "checkmark") } else { Text(title) }
    }
}
