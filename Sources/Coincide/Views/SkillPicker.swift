import CoincideCore
import SwiftUI

struct SkillPicker: View {
    let model: ProviderSkillsStore
    @Binding var query: String
    let searchField: Bool
    let selectedID: String?
    let choose: (ProviderSkill) -> Void
    let move: (Int) -> Void
    let confirm: () -> Void
    let dismiss: () -> Void
    var showSkillsInSlashMenu: Binding<Bool> = .constant(true)
    var reportGeometry: ((String, CGRect) -> Void)? = nil
    static func matching(_ skills: [ProviderSkill], query: String) -> [ProviderSkill] {
        let query = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else { return skills }
        return skills.filter { skill in
            [skill.name, skill.displayName ?? "", skill.shortDescription ?? "", skill.description, skill.scope]
                .contains { $0.localizedStandardContains(query) }
        }.sorted { lhs, rhs in
            let a = lhs.name.lowercased().hasPrefix(query.lowercased()), b = rhs.name.lowercased().hasPrefix(query.lowercased())
            if a != b { return a }
            return lhs.name.localizedStandardCompare(rhs.name) == .orderedAscending
        }
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("Skills").font(.headline)
                if model.isLoading { ProgressView().controlSize(.small).accessibilityLabel("Loading skills") }
                Spacer(minLength: 8)
                Menu {
                    Toggle("Show skills for /skill:", isOn: showSkillsInSlashMenu)
                } label: { Image(systemName: "ellipsis") }
                    .menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize()
                    .accessibilityLabel("Skill suggestions settings")
                Button { Task { await model.refresh(forceReload: true) } } label: { Image(systemName: "arrow.clockwise") }
                    .buttonStyle(.plain).help("Refresh workspace skills").accessibilityLabel("Refresh workspace skills")
                    .accessibilityIdentifier("composer-skills-refresh").disabled(model.isLoading || model.isClosed)
                    .background { geometry("refresh") }
                Button(action: dismiss) { Image(systemName: "xmark") }.buttonStyle(.plain)
                    .help("Close skills").accessibilityLabel("Close skills").accessibilityIdentifier("composer-skills-close")
                    .background { geometry("close") }
            }
            if searchField {
                TextField("Search skills", text: $query).textFieldStyle(.roundedBorder)
                    .accessibilityIdentifier("composer-skills-search")
                    .onSubmit(confirm)
                    .onKeyPress(.upArrow) { move(-1); return .handled }
                    .onKeyPress(.downArrow) { move(1); return .handled }
                    .onKeyPress(.escape) { dismiss(); return .handled }
            }
            if let error = model.errorMessage {
                Text(error).font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                    .accessibilityIdentifier("composer-skills-error")
            }
            if model.inventory?.isPartial == true {
                Text("Some skills could not be loaded.").font(.caption).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true).accessibilityIdentifier("composer-skills-partial")
            }
            let matches = Self.matching(model.skills, query: query)
            if matches.isEmpty && !model.isLoading && model.errorMessage == nil {
                Text(model.inventory == nil ? "Choose Refresh to load this workspace's skills." : query.isEmpty ? "No user-invocable skills are available in this workspace." : "No matching skills.")
                    .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 2) {
                        ForEach(matches) { skill in
                            Button { choose(skill) } label: {
                                VStack(alignment: .leading, spacing: 3) {
                                    HStack(alignment: .firstTextBaseline) {
                                        Text(verbatim: skill.displayName ?? skill.name).font(.callout.weight(.medium))
                                        Spacer(minLength: 4)
                                        if !skill.scope.isEmpty { Text(verbatim: skill.scope).font(.caption2).foregroundStyle(.secondary) }
                                    }
                                    Text(verbatim: "$" + skill.name).font(.caption.monospaced()).foregroundStyle(.secondary)
                                    if let detail = skill.shortDescription ?? (skill.description.isEmpty ? nil : skill.description) {
                                        Text(verbatim: detail).font(.caption).foregroundStyle(.secondary).lineLimit(2)
                                    }
                                }.frame(maxWidth: .infinity, alignment: .leading).padding(8)
                                    .background(selectedID == skill.id ? Color.accentColor.opacity(0.12) : Color.clear, in: RoundedRectangle(cornerRadius: 7))
                                    .contentShape(Rectangle())
                            }.buttonStyle(.plain).id(skill.id)
                                .accessibilityLabel("Insert skill \(skill.displayName ?? skill.name)")
                                .accessibilityValue("$\(skill.name)")
                                .accessibilityIdentifier("composer-skill-\(skill.name)")
                                .help(skill.path)
                                .background { geometry("skill-" + skill.id) }
                        }
                    }
                }.frame(maxHeight: 210)
                    .onChange(of: selectedID) { _, value in if let value { proxy.scrollTo(value) } }
            }
            Text("Inserts a skill mention into your draft. Return selects; Escape closes.")
                .font(.caption2).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
        }.padding(12).coincideSurface(cornerRadius: 14)
            .background { geometry("bounds") }
            .coordinateSpace(name: "skill-picker-layout")
    }
    private func geometry(_ key: String) -> some View {
        GeometryReader { proxy in
            let frame = proxy.frame(in: .named("skill-picker-layout"))
            Color.clear.onAppear { reportGeometry?(key, frame) }
                .onChange(of: frame) { _, value in reportGeometry?(key, value) }
        }
    }
}
