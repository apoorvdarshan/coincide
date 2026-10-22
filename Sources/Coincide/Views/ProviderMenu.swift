import CoincideCore
import SwiftUI

struct ProviderMenu: View {
    var store: WorkspaceStore
    let thread: CodingThread
    var body: some View {
        ViewThatFits(in: .horizontal) {
            menu.frame(maxWidth: 280, alignment: .leading).fixedSize()
            menu.frame(maxWidth: 280, alignment: .leading)
        }
    }
    private var summary: String {
        var parts = [thread.providerName]
        if !thread.model.isEmpty {
            parts.append(store.models(for: thread).first(where: { $0.id == thread.model })?.name ?? thread.openCodeConfiguration?.model?.id ?? thread.model)
        }
        if thread.provider == .codex, let effort = thread.reasoningEffort {
            parts.append(String(localized: "Reasoning: \(ReasoningEffortPresentation.title(effort))"))
        }
        if thread.provider == .opencode {
            if let variant = thread.openCodeConfiguration?.model?.variant { parts.append(variant) }
            if let agent = thread.openCodeConfiguration?.agentID { parts.append(agent) }
        }
        return parts.joined(separator: " · ")
    }
    private var menu: some View {
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
            if thread.provider == .opencode {
                openCodeOptions
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
                .disabled((thread.provider == .acp || thread.provider == .opencode) && !store.workspaceReady(for: thread))
        } label: {
            // AppKit's native menu button derives its title from a single Text.
            // Nested label stacks otherwise lose the selected model and effort.
            Text(summary).font(.system(size: 13, weight: .medium)).lineLimit(1).truncationMode(.middle)
        }
        .menuStyle(.borderlessButton).fixedSize(horizontal: false, vertical: true)
        .accessibilityLabel("Provider and model")
        .accessibilityValue(summary)
        .accessibilityIdentifier("provider-model-menu")
        .help(summary)
    }
    @ViewBuilder private var openCodeOptions: some View {
        if let selected = thread.openCodeConfiguration?.model,
           let model = store.models(for: thread).first(where: { $0.id == selected.catalogID }),
           let variants = model.openCodeVariants, !variants.isEmpty {
            Divider()
            Menu("Variant") {
                Button { store.setOpenCodeVariant(nil, model: model, threadID: thread.id) } label: {
                    choice("Model Default", selected: selected.variant == nil)
                }
                ForEach(variants, id: \.self) { variant in
                    Button { store.setOpenCodeVariant(variant, model: model, threadID: thread.id) } label: {
                        choice(variant, selected: selected.variant == variant)
                    }
                }
            }.accessibilityIdentifier("opencode-variant-menu")
        }
        if let catalog = store.openCodeCatalogs[thread.id] {
            Menu("Agent") {
                ForEach(catalog.agents.filter { !$0.hidden && $0.mode != .subagent }, id: \.id) { agent in
                    Button { store.setOpenCodeAgent(agent.id, threadID: thread.id) } label: {
                        choice(agent.name, selected: thread.openCodeConfiguration?.agentID == agent.id)
                    }
                }
            }.accessibilityIdentifier("opencode-agent-menu")
        }
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
