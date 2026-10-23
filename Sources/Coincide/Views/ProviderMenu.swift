import CoincideCore
import SwiftUI

struct ProviderMenu: View {
    var store: WorkspaceStore
    let thread: CodingThread
    private var controls: ProviderModelControlsPresentation {
        .init(thread: thread, models: store.models(for: thread))
    }
    var body: some View {
        ViewThatFits(in: .horizontal) {
            menu.frame(maxWidth: 280, alignment: .leading).fixedSize()
            menu.frame(maxWidth: 280, alignment: .leading)
        }
    }
    private var summary: String {
        var parts = [thread.providerName]
        if !thread.model.isEmpty {
            let piName = thread.piConfiguration?.model.map { $0.provider + " / " + $0.modelID }
            let museName = thread.museConfiguration?.model?.modelID
            parts.append(store.models(for: thread).first(where: { $0.id == thread.model })?.name ?? museName ?? piName ?? thread.openCodeConfiguration?.model?.id ?? thread.model)
        }
        if thread.provider == .codex, let effort = thread.reasoningEffort {
            parts.append(String(localized: "Reasoning: \(ReasoningEffortPresentation.title(effort))"))
        }
        if thread.provider == .opencode {
            if let variant = thread.openCodeConfiguration?.model?.variant { parts.append(variant) }
            if let agent = thread.openCodeConfiguration?.agentID { parts.append(agent) }
        }
        if thread.provider == .pi, let level = thread.piConfiguration?.thinkingLevel { parts.append("Thinking: \(level)") }
        if thread.provider == .muse, let effort = thread.museConfiguration?.reasoningEffort { parts.append("Reasoning: \(effort)") }
        if thread.provider == .codex, let mode = thread.agentModeID {
            parts.append(mode == "plan" ? String(localized: "Mode: Plan") : mode == "default" ? String(localized: "Mode: Default") : String(localized: "Mode needs attention"))
        }
        parts += controls.summaryComponents
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
            if thread.provider == .claude { claudeOptions }
            if thread.provider == .codex { codexInteractionOptions; codexServiceTierOptions }
            if thread.provider == .opencode {
                openCodeOptions
            }
            if thread.provider == .muse, let model = store.models(for: thread).first(where: { $0.id == thread.model }), !model.reasoningEfforts.isEmpty {
                Menu("Reasoning") {
                    Button { _ = store.setMuseReasoning(nil, model: model, threadID: thread.id) } label: {
                        choice("Muse Default", selected: thread.museConfiguration?.reasoningEffort == nil)
                    }
                    ForEach(model.reasoningEfforts) { effort in
                        Button { _ = store.setMuseReasoning(effort.id, model: model, threadID: thread.id) } label: {
                            choice(ReasoningEffortPresentation.title(effort.id), selected: thread.museConfiguration?.reasoningEffort == effort.id)
                        }.help(effort.description)
                    }
                    if model.museReasoningEfforts == nil {
                        Text("Compatibility choices; Muse did not advertise reasoning options.")
                    }
                }.accessibilityIdentifier("muse-reasoning-menu")
            }
            if thread.provider == .pi, let model = store.models(for: thread).first(where: { $0.id == thread.model }),
               let levels = model.piThinkingLevels, !levels.isEmpty {
                Divider()
                Menu("Thinking") {
                    Button { _ = store.setPiThinking(nil, model: model, threadID: thread.id) } label: {
                        choice("Pi Default", selected: thread.piConfiguration?.thinkingLevel == nil)
                    }
                    ForEach(levels, id: \.self) { level in
                        Button { _ = store.setPiThinking(level, model: model, threadID: thread.id) } label: {
                            choice(level.capitalized, selected: thread.piConfiguration?.thinkingLevel == level)
                        }
                    }
                }.accessibilityIdentifier("pi-thinking-menu")
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
                .disabled(((thread.provider == .acp || thread.provider == .opencode || thread.provider == .pi || thread.provider == .muse || thread.provider == .antigravity) && !store.workspaceReady(for: thread)) || (thread.provider == .antigravity && store.antigravityAccount.isWorking))
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
    @ViewBuilder private var codexInteractionOptions: some View {
        let model = store.models(for: thread).first { $0.id.utf8.elementsEqual(thread.model.utf8) }
        if CodexModeSelection.isAvailable(for: thread, model: model) {
            Divider()
            Menu("Interaction Mode") {
                if thread.agentModeID == nil { Text("CLI default (not overridden)") }
                Button { store.setCodexInteractionMode(.init(thread: thread, mode: .default, model: model)) } label: {
                    choice("Default", selected: thread.agentModeID == "default")
                }
                Button { store.setCodexInteractionMode(.init(thread: thread, mode: .plan, model: model)) } label: {
                    choice("Plan", selected: thread.agentModeID == "plan")
                }
            }
            .disabled(!store.workspaceReady(for: thread))
            .accessibilityIdentifier("codex-interaction-mode-menu")
            .help("Applies to future turns. Steering keeps the active turn's captured mode. Permissions stay unchanged.")
        } else if thread.agentModeID != nil {
            Text("Refresh a supported Codex model to change its interaction mode.")
        }
    }
    @ViewBuilder private var claudeOptions: some View {
        if let model = controls.model, controls.claudeOptions != nil {
            if !model.reasoningEfforts.isEmpty {
                Divider()
                Menu("Effort") {
                    Button { updateClaude(model) { $0.effort = nil } } label: { choice("CLI Default", selected: controls.claudeOptions?.effort == nil) }
                    ForEach(model.reasoningEfforts) { effort in
                        Button { updateClaude(model) { $0.effort = effort.id } } label: {
                            choice(ReasoningEffortPresentation.title(effort.id), selected: controls.claudeOptions?.effort == effort.id)
                        }.help(effort.description)
                    }
                }
                .accessibilityIdentifier("claude-effort-menu")
                .help("Applies to future turns. Steering keeps the active turn's captured effort.")
            }
            if controls.supportsClaudeFastMode {
                claudeBooleanMenu("Fast Mode", model: model, keyPath: \.fastMode, identifier: "claude-fast-menu")
            }
            if controls.supportsClaudeThinking {
                claudeBooleanMenu("Thinking", model: model, keyPath: \.thinking, identifier: "claude-thinking-menu")
            }
            if !controls.claudeContextWindows.isEmpty {
                Menu("Context Window") {
                    Button { updateClaude(model) { $0.contextWindow = nil } } label: {
                        choice("CLI Default", selected: controls.claudeOptions?.contextWindow == nil)
                    }
                    ForEach(controls.claudeContextWindows, id: \.self) { value in
                        Button { updateClaude(model) { $0.contextWindow = value } } label: {
                            choice(ProviderModelControlsPresentation.contextTitle(value), selected: controls.claudeOptions?.contextWindow == value)
                        }
                    }
                }.accessibilityIdentifier("claude-context-window-menu")
                .help("Applies to future turns; the active turn keeps its captured context window.")
            }
        }
        if let effective = controls.claudeEffectiveFastSummary { Text(effective) }
        if let warning = controls.claudeWarning {
            Text(warning)
            Button("Reset Claude Controls to CLI Defaults") { store.resetClaudeModelOptions(threadID: thread.id, expected: .init(thread: thread)) }
                .accessibilityIdentifier("claude-controls-reset")
        }
    }
    private func claudeBooleanMenu(_ title: String, model: ProviderModel, keyPath: WritableKeyPath<ClaudeModelOptions, Bool?>, identifier: String) -> some View {
        Menu(title) {
            Button { updateClaude(model) { $0[keyPath: keyPath] = nil } } label: {
                choice("CLI Default", selected: controls.claudeOptions?[keyPath: keyPath] == nil)
            }
            Button { updateClaude(model) { $0[keyPath: keyPath] = true } } label: {
                choice("On", selected: controls.claudeOptions?[keyPath: keyPath] == true)
            }
            Button { updateClaude(model) { $0[keyPath: keyPath] = false } } label: {
                choice("Off", selected: controls.claudeOptions?[keyPath: keyPath] == false)
            }
        }
        .accessibilityIdentifier(identifier)
        .help("Applies to future turns. CLI Default reads native settings; a thinking change opens a fresh connection to the same conversation.")
    }
    private func updateClaude(_ model: ProviderModel, _ change: (inout ClaudeModelOptions) -> Void) {
        guard var options = controls.claudeOptions else { return }
        change(&options); store.setClaudeModelOptions(options, model: model, threadID: thread.id, expected: .init(thread: thread))
    }
    @ViewBuilder private var codexServiceTierOptions: some View {
        if !controls.codexTiers.isEmpty, let model = controls.model {
            Divider()
            Menu("Service Tier") {
                Button { store.setCodexServiceTier(nil, model: model, threadID: thread.id, expected: .init(thread: thread)) } label: {
                    choice("CLI Default", selected: controls.codexSelectedTier == nil && !controls.codexOptionsInvalid)
                }
                Button { store.setCodexServiceTier("default", model: model, threadID: thread.id, expected: .init(thread: thread)) } label: {
                    choice("Standard", selected: controls.codexSelectedTier == "default")
                }
                ForEach(controls.codexTiers.filter { $0.id != "default" }) { tier in
                    Button { store.setCodexServiceTier(tier.id, model: model, threadID: thread.id, expected: .init(thread: thread)) } label: {
                        choice(tier.name, selected: controls.codexSelectedTier == tier.id || (controls.codexSelectedTier == "fast" && tier.id == "priority"))
                    }.help(tier.description)
                }
            }.accessibilityIdentifier("codex-service-tier-menu")
            .help("Requests this service tier for future inputs. Steering keeps the running turn's captured tier.")
        }
        if controls.codexNeedsReset {
            Text("Saved service-tier controls are unavailable for this model or connection.")
            Button("Reset Service Tier to CLI Default") { store.resetCodexServiceTier(threadID: thread.id, expected: .init(thread: thread)) }
                .accessibilityIdentifier("codex-service-tier-reset")
        }
    }
    @ViewBuilder private var openCodeOptions: some View {
        if thread.messages.isEmpty {
            Menu("Server Generation") {
                ForEach([OpenCodeGeneration.v1, .v2], id: \.self) { generation in
                    Button { store.setOpenCodeGeneration(generation, threadID: thread.id) } label: {
                        choice(generation == .v1 ? "OpenCode 1" : "OpenCode 2", selected: thread.openCodeConfiguration?.generation == generation)
                    }
                }
            }.accessibilityIdentifier("opencode-generation-menu")
        }
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

/// Presentation uses only the current native row. It never changes a captured
/// run or treats the requested fast flag as proof of effective native speed.
struct ProviderModelControlsPresentation {
    let thread: CodingThread
    let model: ProviderModel?
    init(thread: CodingThread, models: [ProviderModel]) {
        self.thread = thread
        model = models.first { row in
            row.id.utf8.elementsEqual(thread.model.utf8) ||
                (thread.provider == .claude && row.claudeCapabilities?.resolvedModel?.utf8.elementsEqual(thread.model.utf8) == true)
        }
    }
    var claudeOptions: ClaudeModelOptions? {
        guard thread.provider == .claude else { return nil }
        return try? ClaudeModelControl.options(in: .init(thread: thread))
    }
    var supportsClaudeFastMode: Bool { thread.provider == .claude && model?.claudeCapabilities?.supportsFastMode == true }
    var supportsClaudeThinking: Bool { thread.provider == .claude && model?.claudeCapabilities?.supportsThinking == true }
    var claudeContextWindows: [String] { thread.provider == .claude ? model?.claudeCapabilities?.contextWindows ?? [] : [] }
    var claudeWarning: String? {
        guard thread.provider == .claude, thread.agentConfiguration?[ClaudeModelControl.configurationKey] != nil else { return nil }
        guard let options = claudeOptions else { return "Saved Claude controls are invalid. Reset them before choosing new settings." }
        guard !options.isEmpty else { return nil }
        guard let model, (try? ClaudeModelControl.validate(options, model: model)) != nil else {
            return "Saved Claude controls are unavailable in the current native model catalog."
        }
        return nil
    }
    var claudeEffectiveFastSummary: String? {
        guard thread.provider == .claude, let state = thread.providerMetadata?["claudeModelControl"]["fastModeState"].string,
              ["on", "off", "cooldown"].contains(state) else { return nil }
        var text = "Fast effective: " + (state == "cooldown" ? "Cooldown" : state.capitalized)
        if let reason = thread.providerMetadata?["claudeModelControl"]["fastModeDisabledReason"].string {
            let description: String? = switch reason {
            case "free": "Unavailable for this account"
            case "preference": "Disabled by preferences"
            case "extra_usage_disabled": "Extra usage is disabled"
            case "network_error": "Network error"
            case "unknown": "Unavailable"
            case "not_first_party": "Unavailable for this API provider"
            case "disabled_by_env": "Disabled by environment"
            case "model_not_allowed": "Model is not eligible"
            case "sdk_opt_in_required": "Native SDK opt-in required"
            case "pending": "Eligibility pending"
            default: nil
            }
            if let description { text += " (" + description + ")" }
        }
        return text
    }
    var codexIsOwned: Bool { ProviderConfiguration(thread: thread).codexRuntimeBinding?.authenticationMode == .ownedChatGPT }
    var codexTiers: [CodexModelServiceTier] { thread.provider == .codex && !codexIsOwned ? model?.codexServiceTiers ?? [] : [] }
    var codexSelectedTier: String? {
        guard thread.provider == .codex else { return nil }
        return try? CodexServiceTier.selected(in: .init(thread: thread))
    }
    var codexOptionsInvalid: Bool {
        guard thread.provider == .codex else { return false }
        do { _ = try CodexServiceTier.selected(in: .init(thread: thread)); return false } catch { return true }
    }
    var codexNeedsReset: Bool {
        guard thread.provider == .codex, thread.agentConfiguration?[CodexServiceTier.configurationKey] != nil else { return false }
        guard !codexOptionsInvalid else { return true }
        guard let selected = codexSelectedTier else { return false }
        guard let model else { return true }
        return (try? CodexServiceTier.validate(selected, model: model)) == nil
    }
    var summaryComponents: [String] {
        if thread.provider == .claude {
            var parts: [String] = []
            if let options = claudeOptions {
                if let effort = options.effort { parts.append("Effort requested: " + ReasoningEffortPresentation.title(effort)) }
                if let fast = options.fastMode { parts.append("Fast requested: " + (fast ? "On" : "Off")) }
                if let thinking = options.thinking { parts.append("Thinking requested: " + (thinking ? "On" : "Off")) }
                if let context = options.contextWindow { parts.append("Context requested: " + Self.contextTitle(context)) }
            } else if thread.agentConfiguration?[ClaudeModelControl.configurationKey] != nil { parts.append("Saved Claude controls unavailable") }
            if let effective = claudeEffectiveFastSummary { parts.append(effective) }
            return parts
        }
        if thread.provider == .codex {
            if codexOptionsInvalid { return ["Saved service tier unavailable"] }
            guard let selected = codexSelectedTier else { return [] }
            let name = selected == "default" ? "Standard" : codexTiers.first(where: { $0.id == selected || (selected == "fast" && $0.id == "priority") })?.name ?? selected
            return ["Service tier requested: " + name]
        }
        return []
    }
    static func contextTitle(_ value: String) -> String { value == "1m" ? "1M" : value }
}
