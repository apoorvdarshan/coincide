import AppKit
import CoincideKit
import SwiftUI

/// Every model the providers offer, with custom model ids and the default for new threads.
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
                Text("Models your providers offer, plus custom model IDs you add. Right-click a model to use it for new threads.")
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
            .background(.background)
            .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous).strokeBorder(.separator))
            bottomBar(rows)
        }
        .padding(20)
    }

    // MARK: Rows

    private var allRows: [CatalogRow] {
        let selection = model.settings.defaultSelection
        return model.kinds.enumerated().flatMap { index, kind -> [CatalogRow] in
            guard model.isEnabled(kind) else { return [] }
            let custom = Set(model.providerSettings(kind).customModels)
            return (model.models[kind] ?? []).map { option in
                CatalogRow(
                    option: option, providerIndex: index, isCustom: custom.contains(option.modelID),
                    isDefault: selection.provider == kind && selection.modelID == option.modelID)
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
            Picker("Provider", selection: $provider) {
                Text("All Providers").tag(ProviderKind?.none)
                Divider()
                ForEach(model.kinds.filter { model.isEnabled($0) }, id: \.self) { kind in
                    Text(kind.displayName).tag(Optional(kind))
                }
            }
            .labelsHidden()
            .fixedSize()
            TextField("Filter", text: $filter, prompt: Text("Filter models"))
                .textFieldStyle(.roundedBorder)
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
                    if row.isDefault { SettingsTag(text: String(localized: "Default"), tint: .accentColor) }
                    if row.isCustom { SettingsTag(text: String(localized: "Custom"), tint: .secondary) }
                }
                .help(Text("Model ID: \(row.modelID)"))
            }
            .width(min: 160, ideal: 230)
            TableColumn("Provider", value: \.providerIndex) { row in
                HStack(spacing: 6) {
                    SettingsProviderIcon(kind: row.option.provider, size: 16)
                    Text(row.option.provider.displayName)
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
        }
        .tableStyle(.inset(alternatesRowBackgrounds: true))
        .contextMenu(forSelectionType: CatalogRow.ID.self) { ids in
            if ids.count == 1, let id = ids.first, let row = row(id) {
                Button("Use for New Threads") { model.setDefaultModel(row.option) }
                    .disabled(row.isDefault)
                Button("Copy Model ID") {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(row.modelID, forType: .string)
                }
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
            ControlGroup {
                Button {
                    isAdding = true
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
            .popover(isPresented: $isAdding, arrowEdge: .bottom) {
                AddCustomModelForm(model: model, provider: provider ?? model.kinds.first { model.isEnabled($0) } ?? .claude) {
                    isAdding = false
                }
            }
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
            Picker("Provider", selection: $provider) {
                ForEach(model.kinds, id: \.self) { kind in
                    Text(kind.displayName).tag(kind)
                }
            }
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
        .frame(width: 340)
    }

    private func add() {
        error = model.addCustomModel(modelID, to: provider)
        if error == nil { onDone() }
    }
}
