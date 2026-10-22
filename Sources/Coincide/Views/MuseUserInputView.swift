import CoincideCore
import SwiftUI

/// Options use the provider's exact labels, in its offered order. Notes remain
/// separate so choosing an option never discards an accompanying written answer.
struct MuseUserInputSelection {
    private(set) var choices: [String: Set<String>] = [:]
    private(set) var notes: [String: String] = [:]

    func contains(_ label: String, question: MuseUserInputRequest.Question) -> Bool {
        choices[question.id]?.contains(label) == true
    }

    mutating func set(_ selected: Bool, label: String, question: MuseUserInputRequest.Question) {
        guard question.options.contains(where: { $0.label == label }) else { return }
        if selected {
            if question.multiple { choices[question.id, default: []].insert(label) }
            else { choices[question.id] = [label] }
        } else {
            choices[question.id]?.remove(label)
        }
    }

    mutating func clear(question: MuseUserInputRequest.Question) { choices.removeValue(forKey: question.id) }
    mutating func setNote(_ text: String, question: MuseUserInputRequest.Question) { notes[question.id] = text }

    func validated(for request: MuseUserInputRequest) -> (choices: [String: [String]], notes: [String: String])? {
        var ordered = choices.mapValues { Array($0) }
        for question in request.questions where choices[question.id] != nil {
            ordered[question.id] = question.options.map(\.label).filter { choices[question.id]?.contains($0) == true }
        }
        let entered = notes.filter { !$0.value.isEmpty }
        guard (try? request.answerBody(selections: ordered, notes: entered)) != nil else { return nil }
        return (ordered, entered)
    }
}

struct MuseUserInputView: View {
    let request: MuseUserInputRequest
    let isResponding: Bool
    let onAnswer: ([String: [String]], [String: String]) -> Void
    let onCancel: () -> Void
    var reportGeometry: ((String, CGRect) -> Void)? = nil
    @State private var selection = MuseUserInputSelection()

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Label("Muse needs your input", systemImage: "questionmark.bubble")
                .font(.headline).background { geometry("header") }
            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    ForEach(request.questions) { question in
                        questionView(question)
                    }
                }.frame(minWidth: 0, maxWidth: .infinity, alignment: .leading).padding(.trailing, 4)
            }.frame(minHeight: 80, maxHeight: 300).background { geometry("questions") }
            ViewThatFits(in: .horizontal) {
                HStack { actions }.fixedSize(horizontal: true, vertical: false)
                VStack(alignment: .leading, spacing: 8) { actions }
            }.background { geometry("actions") }
        }
        .frame(minWidth: 0, maxWidth: .infinity, alignment: .leading)
        .disabled(isResponding)
        .onChange(of: request) { _, _ in selection = .init() }
        .background { geometry("bounds") }
        .coordinateSpace(name: "muse-user-input-layout")
    }

    private func questionView(_ question: MuseUserInputRequest.Question) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            if !question.header.isEmpty {
                Text(question.header).font(.subheadline.weight(.semibold))
                    .fixedSize(horizontal: false, vertical: true).textSelection(.enabled)
            }
            Text(question.question).fixedSize(horizontal: false, vertical: true).textSelection(.enabled)
            if !question.options.isEmpty {
                Text(Self.selectionGuidance(question)).font(.caption).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                if question.multiple {
                    ForEach(question.options, id: \.label) { option in
                        Toggle(isOn: Binding(get: { selection.contains(option.label, question: question) }, set: { selected in
                            guard !isResponding else { return }
                            selection.set(selected, label: option.label, question: question)
                        })) { optionLabel(option) }
                        .toggleStyle(.checkbox)
                        .accessibilityIdentifier("muse-question-option-" + question.id + "-" + option.label)
                        preview(option)
                    }
                } else {
                    Picker("Answer", selection: Binding<String?>(get: { selection.choices[question.id]?.first }, set: { label in
                        guard !isResponding else { return }
                        if let label { selection.set(true, label: label, question: question) }
                        else { selection.clear(question: question) }
                    })) {
                        Text("Choose an option").tag(String?.none)
                        ForEach(question.options, id: \.label) { option in Text(option.label).tag(Optional(option.label)) }
                    }.accessibilityIdentifier("muse-question-choice-" + question.id)
                    if let option = question.options.first(where: { selection.contains($0.label, question: question) }) {
                        optionLabel(option)
                        preview(option)
                    }
                }
            }
            TextField("Written answer or notes", text: Binding(get: { selection.notes[question.id] ?? "" }, set: { text in
                guard !isResponding else { return }; selection.setNote(text, question: question)
            }), axis: .vertical)
                .lineLimit(2...6).accessibilityLabel("Written answer or notes: \(question.question)")
                .accessibilityIdentifier("muse-question-notes-" + question.id)
            Group {
                if question.options.isEmpty { Text("Enter an answer. Up to 500 characters.") }
                else { Text("Add notes to your choices, or write another answer. Up to 500 characters.") }
            }.font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            if (selection.notes[question.id] ?? "").utf16.count > 500 {
                Text("This text is too long. Shorten it before submitting.")
                    .font(.caption).foregroundStyle(.red).fixedSize(horizontal: false, vertical: true)
                    .accessibilityIdentifier("muse-question-length-error-" + question.id)
            }
        }.accessibilityElement(children: .contain)
    }

    private func optionLabel(_ option: MuseUserInputRequest.Option) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(option.label).fixedSize(horizontal: false, vertical: true)
            if let description = option.description, !description.isEmpty {
                Text(description).font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    @ViewBuilder private func preview(_ option: MuseUserInputRequest.Option) -> some View {
        if let preview = option.preview, !preview.isEmpty {
            DisclosureGroup("Preview") {
                Text(preview).font(.caption).fixedSize(horizontal: false, vertical: true).textSelection(.enabled)
            }
        }
    }

    @ViewBuilder private var actions: some View {
        Button("Cancel Questions") { cancel() }.accessibilityIdentifier("muse-question-cancel")
        Button("Submit Answers") { submit(selection) }
            .coincidePrimaryAction().disabled(selection.validated(for: request) == nil)
            .accessibilityIdentifier("muse-question-submit")
    }

    func submit(_ answers: MuseUserInputSelection) {
        guard !isResponding, let result = answers.validated(for: request) else { return }
        onAnswer(result.choices, result.notes)
    }

    func cancel() { if !isResponding { onCancel() } }

    static func selectionGuidance(_ question: MuseUserInputRequest.Question) -> String {
        guard question.multiple else { return String(localized: "Choose one option, or write an answer below.") }
        let minimum = question.minimumSelections ?? 0, maximum = question.maximumSelections
        if let maximum, minimum == maximum { return String(localized: "Choose \(minimum) options, or write an answer below.") }
        if let maximum, minimum > 0 { return String(localized: "Choose \(minimum)–\(maximum) options, or write an answer below.") }
        if let maximum { return String(localized: "Choose up to \(maximum) options, or write an answer below.") }
        if minimum > 0 { return String(localized: "Choose at least \(minimum) options, or write an answer below.") }
        return String(localized: "Choose one or more options, or write an answer below.")
    }

    private func geometry(_ name: String) -> some View {
        GeometryReader { proxy in
            let frame = proxy.frame(in: .named("muse-user-input-layout"))
            Color.clear.onAppear { reportGeometry?(name, frame) }
                .onChange(of: frame) { _, value in reportGeometry?(name, value) }
        }
    }
}
