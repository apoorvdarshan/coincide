import CoincideCore
import SwiftUI

struct ProviderMenu: View {
    @Bindable var store: WorkspaceStore
    let thread: CodingThread
    @State private var query = ""
    @State private var showAll = false
    @FocusState private var searchFocused: Bool
    @AppStorage(ModelPickerPreferences.key) private var hiddenModels = "[]"
    private var search: String { query.trimmingCharacters(in: .whitespacesAndNewlines) }
    private var availableProviders: [ProviderKind] { ProviderKind.builtIn.filter { store.pickerProviderAvailable($0) } }
    private var matchingProviders: [ProviderKind] {
        availableProviders.filter { provider in
            search.isEmpty || !visibleModels(provider).isEmpty ||
                (store.models(for: provider).isEmpty &&
                    (provider.name.localizedCaseInsensitiveContains(search) || "CLI default".localizedCaseInsensitiveContains(search)))
        }
    }
    private var controls: ProviderModelControlsPresentation { .init(thread: thread, models: store.models(for: thread)) }
    var summary: String {
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
            ProviderMenuLabelLayout {
                HStack(spacing: 5) {
                    ProviderLogo(provider: thread.provider, size: 14)
                    Text(summary).lineLimit(1).truncationMode(.middle)
                    Image(systemName: "chevron.down").font(.system(size: 9, weight: .medium))
                }.font(.system(size: 13))
            }.frame(height: 30).padding(.horizontal, 6)
        }
        .buttonStyle(.plain).modifier(ChatControlHover(selected: store.modelPickerPresented))
        .accessibilityLabel("Choose model").accessibilityValue(summary)
        .accessibilityIdentifier("provider-model-menu").help(([summary] + controls.summaryComponents).joined(separator: " · "))
        .popover(isPresented: $store.modelPickerPresented, arrowEdge: .bottom) { picker }
    }
    private var picker: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                Text("Models").font(.system(size: 14, weight: .medium))
                Spacer(minLength: 8)
                if store.modelPickerLoading { ProgressView().controlSize(.small) }
                Button { Task { await store.refreshPickerModels(force: true) } } label: {
                    Image(systemName: "arrow.clockwise").font(.system(size: 13))
                }
                .buttonStyle(.plain)
                .modifier(ProviderPickerIconAppearance())
                .disabled(store.modelPickerLoading)
                .help("Refresh models").accessibilityLabel("Refresh models")
            }
            searchField
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 2) {
                    ForEach(matchingProviders) { provider in
                        providerSection(provider)
                    }
                    if availableProviders.isEmpty {
                        VStack(alignment: .leading, spacing: 6) {
                            Text("No agents available").font(.system(size: 13))
                            Text("Connect Codex or Claude in Settings to load models.")
                                .font(.system(size: 12)).foregroundStyle(.secondary)
                        }
                        .fixedSize(horizontal: false, vertical: true)
                        .padding(.horizontal, 10).padding(.vertical, 18)
                    } else if matchingProviders.isEmpty {
                        VStack(alignment: .leading, spacing: 6) {
                            Text("No matching models").font(.system(size: 13))
                            Text("Try another model or agent name.")
                                .font(.system(size: 12)).foregroundStyle(.secondary)
                        }
                        .fixedSize(horizontal: false, vertical: true)
                        .padding(.horizontal, 10).padding(.vertical, 18)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .scrollIndicators(.hidden)
            .frame(height: 270)
            if !ModelPickerPreferences.hidden(hiddenModels).isEmpty {
                Toggle("All models", isOn: $showAll)
                    .font(.system(size: 12)).toggleStyle(.switch).controlSize(.mini)
                    .padding(.horizontal, 2)
            }
            if !thread.messages.isEmpty {
                Text("Switch models and agents in this conversation. Saved history goes with you.")
                    .font(.system(size: 12)).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.horizontal, 2)
            }
            Rectangle().fill(ChatChrome.separator).frame(height: 1)
            HStack(spacing: 8) {
                ProviderLogo(provider: thread.provider, size: 12)
                Text(thread.provider.name).font(.system(size: 12)).foregroundStyle(.secondary)
                Spacer(minLength: 6)
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
                }
                .font(.system(size: 12))
                .menuStyle(.borderlessButton).fixedSize()
                Button { store.showSettings(.models) } label: {
                    Image(systemName: "slider.horizontal.3").font(.system(size: 13))
                }
                .buttonStyle(.plain)
                .modifier(ProviderPickerIconAppearance())
                .help("Choose models to show").accessibilityLabel("Model picker settings")
            }
        }
        .padding(12).frame(width: 330).background(ChatChrome.sidebar)
        .onAppear { searchFocused = true }
        .task { await store.refreshPickerModels() }
    }

    private var searchField: some View {
        HStack(spacing: 8) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 12)).foregroundStyle(.secondary)
                .frame(width: 14)
            TextField("Search models", text: $query)
                .textFieldStyle(.plain)
                .font(.system(size: 13))
                .focused($searchFocused)
                .accessibilityLabel("Search models")
            Button { query = ""; searchFocused = true } label: {
                Image(systemName: "xmark.circle.fill")
                    .font(.system(size: 12)).foregroundStyle(.secondary)
                    .frame(width: 22, height: 24)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .opacity(query.isEmpty ? 0 : 1)
            .disabled(query.isEmpty)
            .accessibilityHidden(query.isEmpty)
            .help("Clear search").accessibilityLabel("Clear model search")
        }
        .padding(.leading, 10).padding(.trailing, 4)
        .frame(height: 34)
        .background(Color.primary.opacity(0.045), in: RoundedRectangle(cornerRadius: 8))
        .overlay { RoundedRectangle(cornerRadius: 8).strokeBorder(Color.primary.opacity(searchFocused ? 0.16 : 0.06)) }
    }

    @ViewBuilder private func providerSection(_ provider: ProviderKind) -> some View {
        let models = visibleModels(provider)
        HStack(spacing: 7) {
            ProviderLogo(provider: provider, size: 12)
            Text(provider.name).font(.system(size: 12))
        }
        .foregroundStyle(.secondary)
        .padding(.horizontal, 10).padding(.top, 10).padding(.bottom, 5)
        ForEach(models) { model in modelRow(provider, model: model) }
        if store.models(for: provider).isEmpty {
            modelChoice(provider, title: "Use \(provider.name) CLI default", modelID: "")
            if store.modelPickerLoading {
                pickerMessage("Loading available models…")
            } else if store.modelCatalogErrors[provider] != nil {
                pickerMessage("Models unavailable. Refresh or review agent setup in Settings.")
            } else {
                pickerMessage("The CLI did not report any models. You can use its default.")
            }
        } else if models.isEmpty {
            pickerMessage(query.isEmpty ? "No models shown. Use All models or change Settings." : "No matching models")
        }
    }

    private func pickerMessage(_ text: LocalizedStringKey) -> some View {
        Text(text).font(.system(size: 12)).foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 10).padding(.vertical, 8)
    }
    private func visibleModels(_ provider: ProviderKind) -> [ProviderModel] {
        return store.models(for: provider).filter { model in
            (showAll || !ModelPickerPreferences.hidden(hiddenModels).contains(ModelPickerPreferences.id(provider, model.id))) &&
                (search.isEmpty || provider.name.localizedCaseInsensitiveContains(search) ||
                 model.name.localizedCaseInsensitiveContains(search) || model.id.localizedCaseInsensitiveContains(search))
        }
    }
    private func canChoose(_ provider: ProviderKind) -> Bool {
        !store.choosingModelThreads.contains(thread.id) &&
        (provider == thread.provider || (!thread.isBusy && thread.queuedTurns.isEmpty && thread.runtimeRequests.isEmpty))
    }
    private func modelRow(_ provider: ProviderKind, model: ProviderModel) -> some View {
        modelChoice(provider, title: model.name, modelID: model.id)
            .accessibilityIdentifier("provider-model-" + ModelPickerPreferences.id(provider, model.id))
    }
    private func modelChoice(_ provider: ProviderKind, title: String, modelID: String) -> some View {
        let selected = provider == thread.provider && modelID == thread.model
        return Button { choose(provider, modelID: modelID) } label: {
            HStack(alignment: .center, spacing: 10) {
                Text(verbatim: title).font(.system(size: 13))
                    .lineLimit(2).multilineTextAlignment(.leading)
                    .frame(maxWidth: .infinity, alignment: .leading)
                Image(systemName: "checkmark")
                    .font(.system(size: 11, weight: .medium))
                    .frame(width: 16, height: 16)
                    .opacity(selected ? 1 : 0)
                    .accessibilityHidden(true)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .modifier(ProviderPickerRowAppearance(selected: selected))
        .disabled(!canChoose(provider))
        .accessibilityAddTraits(selected ? .isSelected : [])
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

/// A fixedSize label ignores a narrow parent proposal, while maxWidth alone
/// expands short labels and their hover targets. Measure the intrinsic label,
/// cap long names, then honor the actual space offered by the composer/header.
private struct ProviderMenuLabelLayout: Layout {
    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        guard let label = subviews.first else { return .zero }
        let ideal = label.sizeThatFits(.unspecified)
        let width = min(270, ideal.width, max(0, proposal.width ?? .infinity))
        let fitting = label.sizeThatFits(.init(width: width, height: proposal.height))
        return .init(width: width, height: fitting.height)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        subviews.first?.place(at: bounds.origin, anchor: .topLeading,
            proposal: .init(width: bounds.width, height: bounds.height))
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

private struct ProviderPickerRowAppearance: ViewModifier {
    let selected: Bool
    @State private var hovered = false
    @Environment(\.isEnabled) private var enabled

    func body(content: Content) -> some View {
        content
            .padding(.horizontal, 10).padding(.vertical, 8)
            .frame(maxWidth: .infinity, minHeight: 36, alignment: .leading)
            .background(Color.primary.opacity(selected ? 0.08 : hovered && enabled ? 0.045 : 0), in: RoundedRectangle(cornerRadius: 7))
            .opacity(enabled ? 1 : 0.45)
            .onHover { hovered = $0 }
    }
}

private struct ProviderPickerIconAppearance: ViewModifier {
    @State private var hovered = false
    @Environment(\.isEnabled) private var enabled

    func body(content: Content) -> some View {
        content
            .foregroundStyle(.secondary)
            .frame(width: 28, height: 28)
            .contentShape(RoundedRectangle(cornerRadius: 6))
            .background(Color.primary.opacity(hovered && enabled ? 0.06 : 0), in: RoundedRectangle(cornerRadius: 6))
            .opacity(enabled ? 1 : 0.4)
            .onHover { hovered = $0 }
    }
}
