import CoincideCore
import SwiftUI

struct ProviderMenu: View {
    @Bindable var store: WorkspaceStore
    let thread: CodingThread
    @State private var query = ""
    @State private var showAll = false
    @AppStorage(ModelPickerPreferences.key) private var hiddenModels = "[]"
    private var controls: ProviderModelControlsPresentation { .init(thread: thread, models: store.models(for: thread)) }
    private var summary: String {
        guard !thread.model.isEmpty else { return "\(thread.provider.name) default" }
        var parts = [store.models(for: thread).first(where: { $0.id == thread.model })?.name ?? thread.model]
        if thread.provider == .codex, let effort = thread.reasoningEffort { parts.append(ReasoningEffortPresentation.title(effort)) }
        if thread.provider == .claude, let effort = controls.claudeOptions?.effort {
            parts.append(ReasoningEffortPresentation.title(effort))
        }
        return parts.joined(separator: " ")
    }
    var body: some View {
        Button { store.modelPickerPresented.toggle() } label: {
            HStack(spacing: 5) {
                ProviderLogo(provider: thread.provider, size: 14)
                Text(summary).lineLimit(1).truncationMode(.middle)
                Image(systemName: "chevron.down").font(.system(size: 9, weight: .medium))
            }.font(.system(size: 13)).frame(maxWidth: 270, alignment: .trailing).fixedSize(horizontal: false, vertical: true)
        }
        .buttonStyle(.plain).accessibilityLabel("Choose model").accessibilityValue(summary)
        .accessibilityIdentifier("provider-model-menu").help(([summary] + controls.summaryComponents).joined(separator: " · "))
        .popover(isPresented: $store.modelPickerPresented, arrowEdge: .bottom) { picker }
    }
    private var picker: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("Models").font(.system(size: 14, weight: .medium))
                Spacer()
                if store.modelPickerLoading { ProgressView().controlSize(.small) }
                Button { Task { await store.refreshPickerModels(force: true) } } label: { Image(systemName: "arrow.clockwise") }
                    .buttonStyle(.plain).disabled(store.modelPickerLoading).help("Refresh models")
                Button { store.showSettings(.models) } label: { Image(systemName: "slider.horizontal.3") }
                    .buttonStyle(.plain).help("Choose models to show").accessibilityLabel("Model picker settings")
            }
            TextField("Search models", text: $query).textFieldStyle(.roundedBorder)
            ScrollView {
                VStack(alignment: .leading, spacing: 6) {
                    ForEach(ProviderKind.builtIn.filter { store.pickerProviderAvailable($0) }) { provider in
                        HStack(spacing: 8) { ProviderLogo(provider: provider); Text(provider.name) }
                            .font(.system(size: 12)).foregroundStyle(.secondary).padding(.top, 6)
                        let models = visibleModels(provider)
                        ForEach(models) { model in modelRow(provider, model: model) }
                        if store.models(for: provider).isEmpty {
                            Button("Use \(provider.name) CLI default") { choose(provider, modelID: "") }
                                .buttonStyle(.plain).padding(.vertical, 7).disabled(!canChoose(provider))
                            Text(store.modelCatalogErrors[provider] == nil ? "Loading available models…" : "Models unavailable. Check agent setup or refresh.")
                                .font(.caption).foregroundStyle(.secondary)
                        } else if models.isEmpty {
                            Text(query.isEmpty ? "No models shown. Use All models or change Settings." : "No matching models")
                                .font(.caption).foregroundStyle(.secondary).padding(.vertical, 7)
                        }
                    }
                    if !ProviderKind.builtIn.contains(where: store.pickerProviderAvailable) {
                        Text("Connect Codex or Claude in Settings to load models.").foregroundStyle(.secondary)
                    }
                }.frame(maxWidth: .infinity, alignment: .leading)
            }.frame(height: 270)
            if !ModelPickerPreferences.hidden(hiddenModels).isEmpty {
                Toggle("All models", isOn: $showAll).toggleStyle(.switch).controlSize(.small)
            }
            if !thread.messages.isEmpty {
                Text("Switch models and agents in this conversation. Saved history goes with you.").font(.caption).foregroundStyle(.secondary)
            }
            Divider()
            HStack {
                Text(thread.provider.name).font(.caption).foregroundStyle(.secondary)
                Spacer()
                Menu("Model options") {
                    if thread.provider == .codex {
                        Button("CLI default model") { _ = store.useCodexDefaultModel(thread.id) }
                            .disabled(store.isReadingCodexModelDefaults(thread.id) || !store.workspaceReady(for: thread))
                        if let model = store.codexReasoningModel(threadID: thread.id), !model.reasoningEfforts.isEmpty { reasoningMenu(model) }
                        codexInteractionOptions
                        codexServiceTierOptions
                    } else if thread.provider == .claude {
                        Button("CLI default model") { store.setModel("", id: thread.id) }
                        claudeOptions
                    }
                }.menuStyle(.borderlessButton).fixedSize()
            }
        }
        .padding(12).frame(width: 310).background(ChatChrome.sidebar)
        .task { await store.refreshPickerModels() }
    }
    private func visibleModels(_ provider: ProviderKind) -> [ProviderModel] {
        store.models(for: provider).filter { model in
            (showAll || !ModelPickerPreferences.hidden(hiddenModels).contains(ModelPickerPreferences.id(provider, model.id))) &&
                (query.isEmpty || model.name.localizedCaseInsensitiveContains(query) || model.id.localizedCaseInsensitiveContains(query))
        }
    }
    private func canChoose(_ provider: ProviderKind) -> Bool {
        !store.choosingModelThreads.contains(thread.id) &&
        (provider == thread.provider || (!thread.isBusy && thread.queuedTurns.isEmpty && thread.runtimeRequests.isEmpty))
    }
    private func modelRow(_ provider: ProviderKind, model: ProviderModel) -> some View {
        Button { choose(provider, modelID: model.id) } label: {
            HStack(spacing: 10) {
                Text(model.name).lineLimit(2).multilineTextAlignment(.leading)
                Spacer(minLength: 8)
                if provider == thread.provider && model.id == thread.model { Image(systemName: "checkmark") }
            }.font(.system(size: 13)).padding(.horizontal, 10).padding(.vertical, 8).contentShape(Rectangle())
                .background(provider == thread.provider && model.id == thread.model ? Color.primary.opacity(0.08) : .clear, in: RoundedRectangle(cornerRadius: 8))
        }.buttonStyle(.plain).disabled(!canChoose(provider))
            .accessibilityIdentifier("provider-model-" + ModelPickerPreferences.id(provider, model.id))
    }
    private func choose(_ provider: ProviderKind, modelID: String) {
        Task {
            if await store.choosePickerModel(provider: provider, modelID: modelID, threadID: thread.id) { store.modelPickerPresented = false }
        }
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
