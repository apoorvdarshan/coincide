import AppKit
import CoincideKit
import SwiftUI

/// Every model the providers offer, with custom model ids, the default for new threads, and the favorites and hidden
/// models of the composer's model picker.
struct ModelsSettingsView: View {
    let model: SettingsModel
    @State private var filter = ""
    @State private var provider: ProviderKind?
    @State private var selection: Set<CatalogRow.ID> = []
    @State private var sortOrder = [KeyPathComparator(\CatalogRow.providerIndex)]
    @State private var isAdding = false

    nonisolated struct CatalogRow: Identifiable {
        let option: ModelOption
        let providerIndex: Int
        let isCustom: Bool
        let isDefault: Bool
        let isFavorite: Bool
        let isHidden: Bool

        var id: String { option.id }
        var name: String { option.displayName }
        var modelID: String { option.modelID }
        var context: Int { option.contextWindow ?? 0 }
    }

    var body: some View {
        let rows = visibleRows
        VStack(alignment: .leading, spacing: 12) {
            SettingsPaneHeader(title: String(localized: "Models")) {
                SettingsIconTile(symbol: SettingsSection.models.symbolName, color: SettingsSection.models.tint, size: 44)
            } subtitle: {
                Text(
                    "Models your providers offer, plus custom model IDs you add. Right-click a model to use it for new threads, star it, or hide it from the model picker."
                )
            }
            filterBar
            Group {
                if rows.isEmpty {
                    emptyState
                } else {
                    table(rows)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .scrollContentBackground(.hidden)
            .background(Color(nsColor: Theme.raisedFill))
            .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 8, style: .continuous).strokeBorder(Color(nsColor: Theme.surfaceBorder)))
            if isAdding {
                AddCustomModelForm(model: model, provider: provider ?? model.kinds.first { model.isEnabled($0) } ?? .claude) {
                    isAdding = false
                }
                .background(
                    RoundedRectangle(cornerRadius: 10, style: .continuous).fill(Color(nsColor: Theme.raisedFill)))
                .overlay(
                    RoundedRectangle(cornerRadius: 10, style: .continuous)
                        .strokeBorder(Color(nsColor: Theme.surfaceBorder)))
                .transition(.opacity)
            }
            bottomBar(rows)
        }
        .padding(20)
    }

    // MARK: Rows

    private var allRows: [CatalogRow] {
        let settings = model.settings
        let selection = settings.defaultSelection
        return model.kinds.enumerated().flatMap { index, kind -> [CatalogRow] in
            guard model.isEnabled(kind) else { return [] }
            let custom = Set(model.providerSettings(kind).customModels)
            return (model.models[kind] ?? []).map { option in
                CatalogRow(
                    option: option, providerIndex: index, isCustom: custom.contains(option.modelID),
                    isDefault: selection.provider == kind && selection.modelID == option.modelID,
                    isFavorite: settings.isFavorite(option.reference), isHidden: settings.isHidden(option.reference))
            }
        }
    }

    private var visibleRows: [CatalogRow] {
        let query = filter.trimmingCharacters(in: .whitespaces)
        return allRows.filter { row in
            (provider == nil || row.option.provider == provider)
                && (query.isEmpty || row.name.localizedStandardContains(query) || row.modelID.localizedStandardContains(query))
        }
        .sorted(using: sortOrder)
    }

    private func row(_ id: CatalogRow.ID) -> CatalogRow? { allRows.first { $0.id == id } }

    // MARK: Views

    private var filterBar: some View {
        HStack(spacing: 8) {
            ThemedPicker(
                selection: $provider,
                options: [.init(ProviderKind?.none, String(localized: "All Providers"))]
                    + model.kinds.filter { model.isEnabled($0) }.map {
                        .init(Optional($0), $0.displayName, image: Theme.logo(for: $0, size: 14))
                    }
            ) { EmptyView() }
            .labelsHidden()
            .fixedSize()
            TextField("Filter", text: $filter, prompt: Text("Filter models"))
                .frame(maxWidth: 260)
            Spacer()
            Button {
                model.checkAll()
            } label: {
                Label("Reload Models", systemImage: "arrow.clockwise")
            }
            .disabled(model.isCheckingAll)
            .help(Text("Ask every provider for its models again"))
        }
    }

    private func table(_ rows: [CatalogRow]) -> some View {
        Table(rows, selection: $selection, sortOrder: $sortOrder) {
            TableColumn("Model", value: \.name) { row in
                HStack(spacing: 6) {
                    Text(row.name)
                        .foregroundStyle(row.isHidden ? .secondary : .primary)
                    if row.isFavorite {
                        Image(systemName: "star.fill")
                            .font(.caption)
                            .foregroundStyle(Color(nsColor: Theme.accent))
                            .accessibilityLabel(Text("Favorite"))
                    }
                    if row.isDefault { SettingsTag(text: String(localized: "Default"), tint: Color(nsColor: Theme.ink)) }
                    if row.isCustom { SettingsTag(text: String(localized: "Custom"), tint: .secondary) }
                    if row.isHidden { SettingsTag(text: String(localized: "Hidden"), tint: .secondary) }
                }
                .help(Text("Model ID: \(row.modelID)"))
            }
            .width(min: 160, ideal: 230)
            TableColumn("Provider", value: \.providerIndex) { row in
                HStack(spacing: 6) {
                    SettingsProviderIcon(kind: row.option.provider, size: 16)
                    Text(row.option.provider.displayName)
                    if row.option.provider == .antigravity { AntigravityRiskGlyph(size: 10) }
                }
            }
            .width(min: 110, ideal: 130)
            TableColumn("Context", value: \.context) { row in
                Text(SettingsFormat.contextWindow(row.option.contextWindow) ?? "–")
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
            }
            .width(min: 60, ideal: 70)
            TableColumn("Reasoning") { row in
                // Efforts are listed in increasing order, so the range reads well in a narrow column.
                let efforts = row.option.efforts.map(SettingsFormat.effort)
                Text(efforts.count > 1 ? "\(efforts[0]) – \(efforts[efforts.count - 1])" : efforts.first ?? "–")
                    .foregroundStyle(.secondary)
                    .help(efforts.joined(separator: ", "))
            }
            .width(min: 90, ideal: 140)
            TableColumn("Speed") { row in
                // The faster speeds the model offers besides standard, such as Fast.
                Text(row.option.speeds.isEmpty ? "–" : row.option.speeds.map(\.name).joined(separator: ", "))
                    .foregroundStyle(.secondary)
            }
            .width(min: 60, ideal: 90)
        }
        .tableStyle(.inset(alternatesRowBackgrounds: false))
        .contextMenu(forSelectionType: CatalogRow.ID.self) { ids in
            if ids.count == 1, let id = ids.first, let row = row(id) {
                Button("Use for New Threads") { model.setDefaultModel(row.option) }
                    .disabled(row.isDefault)
                Button("Copy Model ID") {
                    NSPasteboard.general.setText(row.modelID)
                }
                Divider()
                pickerButtons([row])
                Divider()
                Button("Show \(row.option.provider.displayName) Settings") {
                    model.navigate(to: .provider(row.option.provider))
                }
                if row.isCustom {
                    Divider()
                    Button("Remove Custom Model", role: .destructive) {
                        model.removeCustomModel(row.modelID, from: row.option.provider)
                    }
                }
            } else if !ids.isEmpty {
                pickerButtons(ids.compactMap { row($0) })
            }
        }
    }

    /// Stars the models, or hides them from the model picker (T3 Code's hidden models), or undoes either for all of them.
    @ViewBuilder
    private func pickerButtons(_ rows: [CatalogRow]) -> some View {
        let favorites = rows.allSatisfy(\.isFavorite)
        let hidden = rows.allSatisfy(\.isHidden)
        Button(favorites ? String(localized: "Remove from Favorites") : String(localized: "Add to Favorites")) {
            model.update { settings in
                for row in rows { settings.setFavorite(!favorites, row.option.reference) }
            }
        }
        Button(hidden ? String(localized: "Show in Model Picker") : String(localized: "Hide from Model Picker")) {
            model.update { settings in
                for row in rows { settings.setHidden(!hidden, row.option.reference) }
            }
        }
    }

    private var emptyState: some View {
        ContentUnavailableView {
            Label(
                filter.isEmpty ? String(localized: "No Models Yet") : String(localized: "No Matching Models"),
                systemImage: "cube.transparent")
        } description: {
            Text(
                filter.isEmpty
                    ? String(localized: "Providers list their models once they’re installed and signed in.")
                    : String(localized: "Try a different filter or provider."))
        } actions: {
            if filter.isEmpty {
                Button("Set Up Providers") { model.navigate(to: .section(.providers)) }
            }
        }
    }

    private func bottomBar(_ rows: [CatalogRow]) -> some View {
        let selected = selection.compactMap { row($0) }
        let removable = !selected.isEmpty && selected.allSatisfy(\.isCustom)
        return HStack(spacing: 8) {
            HStack(spacing: 4) {
                Button {
                    withAnimation(.easeOut(duration: 0.15)) { isAdding = true }
                } label: {
                    Image(systemName: "plus")
                }
                .help(Text("Add a custom model"))
                .accessibilityLabel(Text("Add Custom Model"))
                Button {
                    for row in selected { model.removeCustomModel(row.modelID, from: row.option.provider) }
                    selection = []
                } label: {
                    Image(systemName: "minus")
                }
                .disabled(!removable)
                .help(Text("Remove the selected custom models"))
                .accessibilityLabel(Text("Remove Custom Model"))
            }
            .fixedSize()
            .disabled(isAdding)
            Text("^[\(rows.count) model](inflect: true)")
                .font(.callout)
                .foregroundStyle(.secondary)
            Spacer()
            Button("Use for New Threads") {
                if let row = selected.first { model.setDefaultModel(row.option) }
            }
            .disabled(selected.count != 1 || selected.first?.isDefault == true)
        }
    }
}

private struct AddCustomModelForm: View {
    let model: SettingsModel
    @State var provider: ProviderKind
    let onDone: () -> Void
    @State private var modelID = ""
    @State private var error: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Add Custom Model")
                .font(.headline)
            Text("Use the ID the provider’s CLI accepts. It appears in the model picker even if the CLI doesn’t list it.")
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            ThemedPicker(
                selection: $provider,
                options: model.kinds.map { .init($0, $0.displayName, image: Theme.logo(for: $0, size: 14)) }
            ) { Text("Provider") }
            TextField("Model ID", text: $modelID, prompt: Text("model-id"))
                .font(.body.monospaced())
                .onSubmit(add)
                .onChange(of: modelID) { error = nil }
            if let error {
                Text(error).font(.caption).foregroundStyle(.red)
            }
            HStack {
                Spacer()
                Button("Cancel", role: .cancel, action: onDone)
                    .keyboardShortcut(.cancelAction)
                Button("Add", action: add)
                    .keyboardShortcut(.defaultAction)
                    .disabled(modelID.trimmingCharacters(in: .whitespaces).isEmpty)
            }
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func add() {
        error = model.addCustomModel(modelID, to: provider)
        if error == nil { onDone() }
    }
}
