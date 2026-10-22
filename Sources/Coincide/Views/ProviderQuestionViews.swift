import CoincideCore
import SwiftUI

struct OpenCodeQuestionSelection {
    private(set) var values: [String: [String]] = [:]
    mutating func toggle(_ selected: Bool, value: String, question: OpenCodeV1Question.Question) {
        guard question.custom || question.options.contains(where: { $0.label == value }) else { return }
        if selected {
            if question.multiple {
                if values[question.key]?.contains(value) != true { values[question.key, default: []].append(value) }
            } else { values[question.key] = [value] }
        } else { values[question.key]?.removeAll { $0 == value } }
    }
    mutating func text(_ value: String, question: OpenCodeV1Question.Question) {
        guard question.custom, !question.multiple else { return }; values[question.key] = [value]
    }
    func answers(for request: OpenCodeV1Question) -> [String: [String]]? {
        guard (try? request.answerBody(selections: values)) != nil else { return nil }; return values
    }
}

struct OpenCodeQuestionApprovalView: View {
    let request: OpenCodeV1Question
    let isResponding: Bool
    let onSelections: ([String: [String]]) -> Void
    let onCancel: () -> Void
    @State private var selection = OpenCodeQuestionSelection()
    @State private var drafts: [String: String] = [:]
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Label("OpenCode needs your input", systemImage: "questionmark.bubble").font(.headline)
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    ForEach(request.questions, id: \.key) { question in
                        VStack(alignment: .leading, spacing: 8) {
                            if !question.header.isEmpty { Text(question.header).font(.subheadline.weight(.medium)) }
                            Text(question.question).fixedSize(horizontal: false, vertical: true).textSelection(.enabled)
                            Text(question.multiple ? "Choose one or more answers" : "Choose one answer").font(.caption).foregroundStyle(.secondary)
                            ForEach(question.options, id: \.label) { option in
                                choice(option.label, detail: option.description, question: question)
                            }
                            if question.custom {
                                if question.multiple {
                                    ForEach((selection.values[question.key] ?? []).filter { value in !question.options.contains { $0.label == value } }, id: \.self) { value in
                                        choice(value, detail: nil, question: question)
                                    }
                                    TextField("Another answer", text: Binding(get: { drafts[question.key] ?? "" }, set: { drafts[question.key] = $0 }))
                                        .accessibilityLabel(question.question)
                                    Button("Add Answer") {
                                        if let value = drafts[question.key], !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                                            selection.toggle(true, value: value, question: question); drafts.removeValue(forKey: question.key)
                                        }
                                    }.disabled((drafts[question.key] ?? "").trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                                } else {
                                    TextField("Your answer", text: Binding(get: { selection.values[question.key]?.first ?? "" },
                                        set: { selection.text($0, question: question) }), axis: .vertical).accessibilityLabel(question.question)
                                }
                            }
                        }
                    }
                }.frame(minWidth: 0, maxWidth: .infinity, alignment: .leading)
            }.frame(minHeight: 80, maxHeight: 280)
            ViewThatFits(in: .horizontal) {
                HStack { actions }.fixedSize(horizontal: true, vertical: false)
                VStack(alignment: .leading, spacing: 8) { actions }
            }
        }.disabled(isResponding).onChange(of: request) { _, _ in selection = .init(); drafts = [:] }
    }
    private func choice(_ value: String, detail: String?, question: OpenCodeV1Question.Question) -> some View {
        Toggle(isOn: Binding(get: { selection.values[question.key]?.contains(value) == true },
            set: { selection.toggle($0, value: value, question: question) })) {
                VStack(alignment: .leading) {
                    Text(value).fixedSize(horizontal: false, vertical: true)
                    if let detail, !detail.isEmpty { Text(detail).font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true) }
                }
            }.toggleStyle(.checkbox)
    }
    @ViewBuilder private var actions: some View {
        Button("Cancel Questions") { if !isResponding { onCancel() } }.accessibilityIdentifier("opencode-question-cancel")
        Button("Submit Answers") {
            if !isResponding, let answers = selection.answers(for: request) { onSelections(answers) }
        }.coincidePrimaryAction().disabled(selection.answers(for: request) == nil).accessibilityIdentifier("opencode-question-submit")
    }
}

struct GrokQuestionSelection {
    private(set) var choices: [String: [String]] = [:]
    var notes: [String: String] = [:]
    mutating func toggle(_ selected: Bool, option: GrokACPQuestionRequest.Option, question: GrokACPQuestionRequest.Question) {
        guard question.options.contains(where: { $0.id == option.id }) else { return }
        if selected {
            if question.multiSelect {
                if choices[question.id]?.contains(option.id) != true { choices[question.id, default: []].append(option.id) }
            } else { choices[question.id] = [option.id] }
        } else { choices[question.id]?.removeAll { $0 == option.id } }
    }
    func validated(for request: GrokACPQuestionRequest) -> (choices: [String: [String]], notes: [String: String])? {
        let entered = notes.filter { !$0.value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
        guard (try? request.response(selections: choices, notes: entered)) != nil else { return nil }
        return (choices, entered)
    }
}

struct GrokQuestionApprovalView: View {
    let request: GrokACPQuestionRequest
    let isResponding: Bool
    let onSubmit: ([String: [String]], [String: String]) -> Void
    let onCancel: () -> Void
    @State private var selection = GrokQuestionSelection()
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Label("Grok needs your input", systemImage: "questionmark.bubble").font(.headline)
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    ForEach(request.questions, id: \.id) { question in
                        VStack(alignment: .leading, spacing: 8) {
                            Text(question.question).fixedSize(horizontal: false, vertical: true).textSelection(.enabled)
                            Text(question.multiSelect ? "Choose one or more answers" : "Choose one answer").font(.caption).foregroundStyle(.secondary)
                            ForEach(question.options, id: \.id) { option in
                                Toggle(isOn: Binding(get: { selection.choices[question.id]?.contains(option.id) == true },
                                    set: { selection.toggle($0, option: option, question: question) })) {
                                        VStack(alignment: .leading) {
                                            Text(option.label).fixedSize(horizontal: false, vertical: true)
                                            if let description = option.description { Text(description).font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true) }
                                        }
                                    }.toggleStyle(.checkbox)
                                if let preview = option.preview {
                                    DisclosureGroup("Preview") { Text(preview).font(.caption).textSelection(.enabled).fixedSize(horizontal: false, vertical: true) }
                                }
                            }
                            TextField("Other answer or notes", text: Binding(get: { selection.notes[question.id] ?? "" },
                                set: { selection.notes[question.id] = $0 }), axis: .vertical).accessibilityLabel(question.question)
                            Text("Add notes to a selected option, or enter another answer.").font(.caption).foregroundStyle(.secondary)
                        }
                    }
                }.frame(minWidth: 0, maxWidth: .infinity, alignment: .leading)
            }.frame(minHeight: 80, maxHeight: 280)
            ViewThatFits(in: .horizontal) {
                HStack { actions }.fixedSize(horizontal: true, vertical: false)
                VStack(alignment: .leading, spacing: 8) { actions }
            }
        }.disabled(isResponding).onChange(of: request) { _, _ in selection = .init() }
    }
    @ViewBuilder private var actions: some View {
        Button("Cancel Questions") { if !isResponding { onCancel() } }.accessibilityIdentifier("grok-question-cancel")
        Button("Submit Answers") {
            if !isResponding, let result = selection.validated(for: request) { onSubmit(result.choices, result.notes) }
        }.coincidePrimaryAction().disabled(selection.validated(for: request) == nil).accessibilityIdentifier("grok-question-submit")
    }
}
