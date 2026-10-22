import CoincideCore
import SwiftUI

/// Choices retain the native values and order; display labels are never answers.
struct OpenCodeFormSelection {
    private(set) var values: [String: [String]] = [:]
    init(form: OpenCodeV2Form? = nil) {
        for field in form?.fields ?? [] {
            if let value = field.defaultValue {
                values[field.key] = field.type == "multiselect" ? value.array?.compactMap(\.string) : value.string.map { [$0] }
            }
        }
    }
    func contains(_ value: String, field: OpenCodeV2Form.Field) -> Bool { values[field.key]?.contains(value) == true }
    mutating func select(_ selected: Bool, value: String, field: OpenCodeV2Form.Field) {
        guard field.options.contains(where: { $0.value == value }) || field.allowCustom else { return }
        if selected {
            if field.type == "multiselect" {
                if !contains(value, field: field) { values[field.key, default: []].append(value) }
            } else { values[field.key] = [value] }
        } else {
            // An omitted answer reapplies the native default. Preserve an
            // explicit empty multiselection when the user clears that default.
            if field.type == "string", field.defaultValue != nil {
                if field.allowCustom { values[field.key] = [""] }
                return
            }
            values[field.key]?.removeAll { $0 == value }
            if field.type == "multiselect" { values[field.key] = values[field.key] ?? [] }
            else if values[field.key]?.isEmpty == true { values.removeValue(forKey: field.key) }
        }
    }
    mutating func text(_ value: String, field: OpenCodeV2Form.Field) {
        guard field.type == "string", field.allowCustom else { return }
        values[field.key] = [value]
    }
    func answers(for form: OpenCodeV2Form) -> [String: [String]]? {
        guard (try? form.answerBody(selections: values)) != nil else { return nil }
        return values
    }
}

struct OpenCodeFormApprovalView: View {
    let form: OpenCodeV2Form
    let isResponding: Bool
    let onSelections: ([String: [String]]) -> Void
    let onCancel: () -> Void
    @State private var selection: OpenCodeFormSelection
    @State private var custom: [String: String] = [:]
    init(form: OpenCodeV2Form, isResponding: Bool, onSelections: @escaping ([String: [String]]) -> Void,
         onCancel: @escaping () -> Void) {
        self.form = form; self.isResponding = isResponding; self.onSelections = onSelections; self.onCancel = onCancel
        _selection = State(initialValue: OpenCodeFormSelection(form: form))
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Label("OpenCode needs your input", systemImage: "questionmark.bubble").font(.headline)
                .fixedSize(horizontal: false, vertical: true)
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    if !form.title.isEmpty { Text(form.title).font(.subheadline).fixedSize(horizontal: false, vertical: true).textSelection(.enabled) }
                    if let reason = form.unsupportedReason {
                        Text(reason).foregroundStyle(.secondary)
                        Text("Cancel this form to return control to the agent.").font(.caption)
                    } else {
                        ForEach(form.fields, id: \.key) { field in
                            VStack(alignment: .leading, spacing: 8) {
                                Text(field.title).font(.subheadline.weight(.medium)).fixedSize(horizontal: false, vertical: true)
                                if let description = field.description { Text(description).font(.caption).textSelection(.enabled) }
                                if field.required { Text("Required").font(.caption).foregroundStyle(.secondary) }
                                ForEach(field.options, id: \.value) { option in
                                    Toggle(isOn: Binding(get: { selection.contains(option.value, field: field) },
                                        set: { selection.select($0, value: option.value, field: field) })) {
                                        VStack(alignment: .leading) {
                                            Text(option.label).fixedSize(horizontal: false, vertical: true)
                                            if let detail = option.description, detail != option.label { Text(detail).font(.caption).foregroundStyle(.secondary) }
                                        }
                                    }.toggleStyle(.checkbox)
                                }
                                if field.allowCustom {
                                    if field.type == "string" {
                                        TextField("Your answer", text: Binding(get: { selection.values[field.key]?.first ?? "" },
                                            set: { selection.text($0, field: field) }), axis: .vertical)
                                            .accessibilityLabel(field.title)
                                    } else {
                                        ForEach((selection.values[field.key] ?? []).filter { value in !field.options.contains { $0.value == value } }, id: \.self) { value in
                                            Toggle(value, isOn: Binding(get: { selection.contains(value, field: field) },
                                                set: { selection.select($0, value: value, field: field) })).toggleStyle(.checkbox)
                                        }
                                        TextField("Another answer", text: Binding(get: { custom[field.key] ?? "" }, set: { custom[field.key] = $0 }))
                                            .accessibilityLabel(field.title)
                                        Button("Add Answer") {
                                            if let value = custom[field.key], !value.isEmpty {
                                                selection.select(true, value: value, field: field); custom.removeValue(forKey: field.key)
                                            }
                                        }.disabled((custom[field.key] ?? "").isEmpty)
                                    }
                                }
                            }.accessibilityElement(children: .contain)
                        }
                    }
                }.frame(minWidth: 0, maxWidth: .infinity, alignment: .leading).padding(.trailing, 4)
            }.frame(minHeight: 80, maxHeight: 280)
            ViewThatFits(in: .horizontal) {
                HStack { actions }.fixedSize(horizontal: true, vertical: false)
                VStack(alignment: .leading, spacing: 8) { actions }
            }
        }.frame(minWidth: 0, maxWidth: .infinity, alignment: .leading).disabled(isResponding)
            .onChange(of: form) { _, newValue in selection = .init(form: newValue); custom = [:] }
    }
    @ViewBuilder private var actions: some View {
        Button("Cancel Form") { if !isResponding { onCancel() } }.accessibilityIdentifier("opencode-form-cancel")
        if form.unsupportedReason == nil {
            Button("Submit Answers") {
                if !isResponding, let answers = selection.answers(for: form) { onSelections(answers) }
            }.coincidePrimaryAction().disabled(selection.answers(for: form) == nil)
                .accessibilityIdentifier("opencode-form-submit")
        }
    }
}
