import CoincideCore
import SwiftUI

enum ProviderComposerSuggestion: Identifiable, Equatable {
    case command(ProviderCommand)
    case skill(ProviderSkill)
    case app(CoincideSlashCommand)
    var id: String { switch self { case .command(let value): "command-" + value.id; case .skill(let value): "skill-" + value.id; case .app(let value): "app-" + value.id } }
    var name: String { switch self { case .command(let value): value.name; case .skill(let value): value.name; case .app(let value): value.name } }
    var token: String { switch self { case .command(let value): "/" + value.name; case .skill(let value): "$" + value.name; case .app(let value): value.token } }
    var title: String { switch self { case .command(let value): "/" + value.name; case .skill(let value): value.displayName ?? value.name; case .app(let value): value.token } }
    var detail: String {
        switch self {
        case .command(let value): value.description.isEmpty ? value.hints.joined(separator: " · ") : value.description
        case .skill(let value): value.shortDescription ?? value.description
        case .app(let value): value.detail
        }
    }
    var source: String? { switch self { case .command(let value): value.source; case .skill(let value): value.scope.isEmpty ? nil : value.scope; case .app: "Coincide · Opens in this app" } }
}

struct ProviderCommandPicker: View {
    let model: ProviderSkillsStore?
    @Binding var query: String
    let searchField: Bool
    let selectedID: String?
    let choose: (ProviderComposerSuggestion) -> Void
    let move: (Int) -> Void
    let confirm: () -> Void
    let dismiss: () -> Void
    @Binding var showSkills: Bool
    var reportGeometry: ((String, CGRect) -> Void)? = nil
    var appCommands = false
    @ScaledMetric(relativeTo: .callout) private var suggestedRowHeight: CGFloat = 68

    static func matching(commands: [ProviderCommand], skills: [ProviderSkill], query: String, showSkills: Bool, appCommands: Bool = false) -> [ProviderComposerSuggestion] {
        let availableSkills = showSkills ? skills.filter(\.canInvokeFromComposer) : []
        let skillNames = Set(availableSkills.map { $0.name.lowercased() })
        let commandRows = commands.filter {
            $0.canInvokeFromComposer && !skillNames.contains($0.name.lowercased()) &&
                // The composer reserves this exact prefix for app navigation.
                // A provider/plugin row must never appear to invoke its own
                // command and then route to a different Coincide action.
                (!appCommands || !$0.name.hasPrefix("app:"))
        }
        let normalized = query.trimmingCharacters(in: .whitespacesAndNewlines)
        if normalized.lowercased().hasPrefix("skill:") {
            return SkillPicker.matching(availableSkills, query: String(normalized.dropFirst(6))).map(ProviderComposerSuggestion.skill)
        }
        let matchingCommands = commandRows.filter {
            normalized.isEmpty || [$0.name, $0.description, $0.hints.joined(separator: " ")]
                .contains(where: { $0.localizedStandardContains(normalized) })
        }.map(ProviderComposerSuggestion.command)
        let matchingSkills = normalized.lowercased() == "skill" ? availableSkills : SkillPicker.matching(availableSkills, query: normalized)
        let native = appCommands ? CoincideSlashCommand.allCases.filter {
            normalized.isEmpty || [$0.name, $0.detail].contains { $0.localizedStandardContains(normalized) }
        }.map(ProviderComposerSuggestion.app) : []
        let rows = matchingCommands + matchingSkills.map(ProviderComposerSuggestion.skill) + native
        guard !normalized.isEmpty else { return rows }
        return rows.sorted {
            let lhs = $0.name.lowercased().hasPrefix(normalized.lowercased()), rhs = $1.name.lowercased().hasPrefix(normalized.lowercased())
            if lhs != rhs { return lhs }
            return $0.name.localizedStandardCompare($1.name) == .orderedAscending
        }
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("Commands").font(.headline)
                if model?.isLoading == true { ProgressView().controlSize(.small).accessibilityLabel("Loading commands and skills") }
                Spacer(minLength: 8)
                Menu { Toggle("Show skills in command suggestions", isOn: $showSkills) } label: { Image(systemName: "ellipsis") }
                    .menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize().accessibilityLabel("Command suggestions settings")
                Button { Task { await model?.refresh(forceReload: true) } } label: { Image(systemName: "arrow.clockwise") }
                    .buttonStyle(.plain).help("Refresh workspace commands and skills").accessibilityLabel("Refresh workspace commands and skills")
                    .accessibilityIdentifier("composer-commands-refresh").disabled(model == nil || model?.isLoading == true || model?.isClosed == true)
                    .background { geometry("refresh") }
                Button(action: dismiss) { Image(systemName: "xmark") }.buttonStyle(.plain)
                    .accessibilityLabel("Close commands").help("Close commands").accessibilityIdentifier("composer-commands-close")
                    .background { geometry("close") }
            }
            if searchField {
                TextField("Search commands and skills", text: $query).textFieldStyle(.roundedBorder)
                    .accessibilityIdentifier("composer-commands-search").onSubmit(confirm)
                    .onKeyPress(.upArrow) { move(-1); return .handled }
                    .onKeyPress(.downArrow) { move(1); return .handled }
                    .onKeyPress(.escape) { dismiss(); return .handled }
            }
            if let error = model?.errorMessage {
                Text(error).font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                    .accessibilityIdentifier("composer-commands-error")
            }
            if model?.commandInventory?.isPartial == true {
                Text("Some commands or skills could not be loaded. Unavailable or ambiguous entries are not offered.")
                    .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                    .accessibilityIdentifier("composer-commands-partial")
            }
            let matches = Self.matching(commands: model?.commands ?? [], skills: model?.skills ?? [], query: query, showSkills: showSkills, appCommands: appCommands)
            if matches.isEmpty, model?.isLoading != true, model?.errorMessage == nil {
                Text(model?.commandInventory == nil ? "Choose Refresh to load this workspace's commands and skills." : query.isEmpty ? "No user-invocable commands or skills are available in this workspace." : "No matching commands or skills.")
                    .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 2) {
                        ForEach(matches) { row in
                            Button { choose(row) } label: {
                                VStack(alignment: .leading, spacing: 3) {
                                    Text(verbatim: row.title).font(.callout.weight(.medium)).fixedSize(horizontal: false, vertical: true)
                                    Text(verbatim: row.token).font(.caption.monospaced()).foregroundStyle(.secondary)
                                    if !row.detail.isEmpty { Text(verbatim: row.detail).font(.caption).foregroundStyle(.secondary).lineLimit(2) }
                                    if let source = row.source { Text(verbatim: source).font(.caption2).foregroundStyle(.secondary) }
                                }.frame(maxWidth: .infinity, alignment: .leading).padding(8)
                                    .background(selectedID == row.id ? Color.accentColor.opacity(0.12) : Color.clear, in: RoundedRectangle(cornerRadius: 7))
                                    .contentShape(Rectangle())
                            }.buttonStyle(.plain).id(row.id)
                                .accessibilityLabel("Insert \(row.token)").accessibilityValue(row.token)
                                .accessibilityIdentifier("composer-" + row.id)
                                .background { geometry("row-" + row.id) }
                        }
                    }
                }.frame(minHeight: min(210, suggestedRowHeight * CGFloat(min(matches.count, 3))), maxHeight: 210)
                    .background { geometry("viewport") }
                    .onChange(of: selectedID) { _, value in if let value { proxy.scrollTo(value) } }
            }
            Text("Inserts into your draft. Send explicitly to invoke. Return selects; Escape closes.")
                .font(.caption2).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                .background { geometry("instructions") }
            if appCommands {
                Text("The /app: prefix is reserved for Coincide commands.")
                    .font(.caption2).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
        }.background { geometry("bounds") }.coordinateSpace(name: "provider-command-layout")
    }
    private func geometry(_ region: String) -> some View {
        GeometryReader { proxy in
            let frame = proxy.frame(in: .named("provider-command-layout"))
            Color.clear.onAppear { reportGeometry?(region, frame) }.onChange(of: frame) { _, value in reportGeometry?(region, value) }
        }
    }
}
