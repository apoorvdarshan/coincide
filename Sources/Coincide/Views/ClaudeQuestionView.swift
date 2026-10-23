import CoincideCore
import SwiftUI

struct ClaudeQuestionSelection {
    private(set) var choices: [String: [String]] = [:]
    var custom: [String: String] = [:]
    var notes: [String: String] = [:]

    mutating func toggle(_ selected: Bool, option: ClaudeQuestionRequest.Option, question: ClaudeQuestionRequest.Question) {
        guard question.options.contains(option) else { return }
        if selected {
            if question.multiSelect {
                if choices[question.question]?.contains(option.label) != true { choices[question.question, default: []].append(option.label) }
            } else { choices[question.question] = [option.label]; custom.removeValue(forKey: question.question) }
        } else { choices[question.question]?.removeAll { $0 == option.label } }
    }
    mutating func setCustom(_ value: String, question: ClaudeQuestionRequest.Question) {
        custom[question.question] = value
        if !question.multiSelect, !value.isEmpty { choices.removeValue(forKey: question.question) }
    }
    func validated(for request: ClaudeQuestionRequest) -> (selections: [String: [String]], notes: [String: String])? {
        var selections: [String: [String]] = [:]
        for question in request.questions {
            // Stable provider order keeps answers independent of checkbox click order.
            var values = question.options.map(\.label).filter { choices[question.question]?.contains($0) == true }
            if let value = custom[question.question], !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                if question.multiSelect { if !values.contains(value) { values.append(value) } }
                else { values = [value] }
            }
            selections[question.question] = values
        }
        let enteredNotes = notes.filter { !$0.value.isEmpty }
        guard (try? request.response(selections: selections, notes: enteredNotes)) != nil else { return nil }
        return (selections, enteredNotes)
    }
}

struct ClaudeQuestionApprovalView: View {
    let request: ClaudeQuestionRequest
    let isResponding: Bool
    let onSubmit: ([String: [String]], [String: String]) -> Void
    let onCancel: () -> Void
    @State private var selection = ClaudeQuestionSelection()

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Label("Claude needs your input", systemImage: "questionmark.bubble").font(.headline)
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    ForEach(request.questions, id: \.question) { question in
                        questionControls(question)
                    }
                }.frame(minWidth: 0, maxWidth: .infinity, alignment: .leading)
            }.frame(minHeight: 80, maxHeight: 280)
            ViewThatFits(in: .horizontal) {
                HStack { actions }.fixedSize(horizontal: true, vertical: false)
                VStack(alignment: .leading, spacing: 8) { actions }
            }
        }.disabled(isResponding).onChange(of: request) { _, _ in selection = .init() }
    }
    private func questionControls(_ question: ClaudeQuestionRequest.Question) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(question.header).font(.subheadline.weight(.medium))
            Text(question.question).fixedSize(horizontal: false, vertical: true).textSelection(.enabled)
            Text(question.multiSelect ? "Choose one or more answers" : "Choose one answer").font(.caption).foregroundStyle(.secondary)
            ForEach(question.options, id: \.label) { option in
                Toggle(isOn: Binding(get: { selection.choices[question.question]?.contains(option.label) == true },
                    set: { selection.toggle($0, option: option, question: question) })) {
                        VStack(alignment: .leading, spacing: 3) {
                            Text(option.label).fixedSize(horizontal: false, vertical: true)
                            if !option.description.isEmpty {
                                Text(option.description).font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                            }
                        }
                    }.toggleStyle(.checkbox).accessibilityLabel(option.label)
                if let preview = option.preview, !preview.isEmpty {
                    DisclosureGroup("Preview \(option.label)") {
                        Text(preview).font(.system(.caption, design: .monospaced)).textSelection(.enabled).fixedSize(horizontal: false, vertical: true)
                    }
                }
            }
            TextField("Other answer", text: Binding(get: { selection.custom[question.question] ?? "" },
                set: { selection.setCustom($0, question: question) }), axis: .vertical)
                .accessibilityLabel("Other answer for \(question.header)")
            TextField("Notes (optional)", text: Binding(get: { selection.notes[question.question] ?? "" },
                set: { selection.notes[question.question] = $0 }), axis: .vertical)
                .accessibilityLabel("Notes for \(question.header)")
        }
    }
    @ViewBuilder private var actions: some View {
        Button("Cancel Questions", action: cancel).accessibilityIdentifier("claude-question-cancel")
        Button("Submit Answers") {
            if !isResponding, let result = selection.validated(for: request) { onSubmit(result.selections, result.notes) }
        }.coincidePrimaryAction().disabled(selection.validated(for: request) == nil).accessibilityIdentifier("claude-question-submit")
    }
    func cancel() { if !isResponding { onCancel() } }
}
