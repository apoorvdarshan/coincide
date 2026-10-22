import CoincideCore
import CoincideMarkdown
import SwiftUI

/// Selection is keyed by protocol IDs; repeated or punctuation-bearing labels are presentation only.
struct CursorQuestionSelection {
    private(set) var values: [String: Set<String>] = [:]

    func contains(optionID: String, questionID: String) -> Bool {
        values[questionID]?.contains(optionID) == true
    }
    mutating func set(_ selected: Bool, optionID: String, question: CursorACPQuestion) {
        guard question.options.contains(where: { $0.id == optionID }) else { return }
        if selected {
            if question.allowMultiple { values[question.id, default: []].insert(optionID) }
            else { values[question.id] = [optionID] }
        } else {
            values[question.id]?.remove(optionID)
            if values[question.id]?.isEmpty == true { values.removeValue(forKey: question.id) }
        }
    }
    func answers(for request: CursorACPQuestionRequest) -> [String: [String]]? {
        var answer: [String: [String]] = [:]
        for question in request.questions {
            guard answer[question.id] == nil else { return nil }
            answer[question.id] = question.options.filter { contains(optionID: $0.id, questionID: question.id) }.map(\.id)
        }
        guard (try? request.response(for: answer)) != nil else { return nil }
        return answer
    }
}

struct CursorQuestionApprovalView: View {
    let request: CursorACPQuestionRequest
    let isResponding: Bool
    let onSelections: ([String: [String]]) -> Void
    let onSkip: () -> Void
    var reportGeometry: ((String, CGRect) -> Void)? = nil
    @State private var selection = CursorQuestionSelection()

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Label("Cursor needs your input", systemImage: "questionmark.bubble").font(.headline)
                .background { geometry("header") }
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    if let title = request.title { Text(title).font(.subheadline).textSelection(.enabled) }
                    ForEach(request.questions, id: \.id) { question in
                        VStack(alignment: .leading, spacing: 8) {
                            Text(question.prompt).font(.subheadline.weight(.medium)).textSelection(.enabled)
                                .fixedSize(horizontal: false, vertical: true)
                            Text(question.allowMultiple ? "Select one or more options." : "Select one option.")
                                .font(.caption).foregroundStyle(.secondary)
                            ForEach(question.options, id: \.id) { option in
                                Toggle(isOn: Binding(get: {
                                    selection.contains(optionID: option.id, questionID: question.id)
                                }, set: { selected in
                                    guard !isResponding else { return }
                                    selection.set(selected, optionID: option.id, question: question)
                                })) {
                                    Text(option.label).fixedSize(horizontal: false, vertical: true)
                                }
                                .toggleStyle(.checkbox)
                                .accessibilityIdentifier("cursor-question-option-" + question.id + "-" + option.id)
                            }
                        }.accessibilityElement(children: .contain)
                    }
                }.frame(minWidth: 0, maxWidth: .infinity, alignment: .leading).padding(.trailing, 4)
            }.frame(minHeight: 80, maxHeight: 280)
            ViewThatFits(in: .horizontal) {
                HStack { actions }.fixedSize(horizontal: true, vertical: false)
                VStack(alignment: .leading, spacing: 8) { actions }
            }.background { geometry("actions") }
        }
        .frame(minWidth: 0, maxWidth: .infinity, alignment: .leading)
        .disabled(isResponding)
        .onChange(of: request) { _, _ in selection = CursorQuestionSelection() }
        .background { geometry("bounds") }
        .coordinateSpace(name: "cursor-question-layout")
    }
    @ViewBuilder private var actions: some View {
        Button("Skip Questions") { skip() }
            .accessibilityIdentifier("cursor-question-skip")
        Button("Submit Answers") { submit() }
            .coincidePrimaryAction().disabled(selection.answers(for: request) == nil)
            .accessibilityIdentifier("cursor-question-submit")
    }
    func submit() {
        guard !isResponding, let answers = selection.answers(for: request) else { return }
        onSelections(answers)
    }
    func skip() {
        guard !isResponding else { return }
        onSkip()
    }
    private func geometry(_ name: String) -> some View {
        GeometryReader { proxy in
            let frame = proxy.frame(in: .named("cursor-question-layout"))
            Color.clear.onAppear { reportGeometry?(name, frame) }
                .onChange(of: frame) { _, value in reportGeometry?(name, value) }
        }
    }
}

struct CursorPlanApprovalView: View {
    let request: CursorACPPlanRequest
    let isResponding: Bool
    let onDecision: (Bool) -> Void
    var reportGeometry: ((String, CGRect) -> Void)? = nil

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Label("Review Cursor plan", systemImage: "list.bullet.clipboard").font(.headline)
                .background { geometry("header") }
            ScrollView {
                VStack(alignment: .leading, spacing: 12) {
                    if let name = request.name { Text(name).font(.title3).textSelection(.enabled) }
                    if let overview = request.overview { Text(overview).foregroundStyle(.secondary).textSelection(.enabled) }
                    if request.isProject == true { Label("Project plan", systemImage: "folder").font(.caption).foregroundStyle(.secondary) }
                    MarkdownView(request.plan)
                    if !request.todos.isEmpty {
                        Text("Tasks").font(.subheadline.weight(.semibold))
                        ForEach(request.todos, id: \.id) { CursorPlanTodoView(todo: $0) }
                    }
                    // Phases have no protocol ID and may repeat names. Their
                    // positions are stable within this immutable reviewed request.
                    ForEach(request.phases.indices, id: \.self) { index in
                        let phase = request.phases[index]
                        VStack(alignment: .leading, spacing: 8) {
                            Text(phase.name).font(.subheadline.weight(.semibold)).textSelection(.enabled)
                            ForEach(phase.todos, id: \.id) { CursorPlanTodoView(todo: $0) }
                        }
                    }
                }.frame(minWidth: 0, maxWidth: .infinity, alignment: .leading).padding(.trailing, 4)
            }.frame(minHeight: 100, maxHeight: 320)
            ViewThatFits(in: .horizontal) {
                HStack { actions }.fixedSize(horizontal: true, vertical: false)
                VStack(alignment: .leading, spacing: 8) { actions }
            }.background { geometry("actions") }
        }
        .frame(minWidth: 0, maxWidth: .infinity, alignment: .leading)
        .disabled(isResponding)
        .background { geometry("bounds") }
        .coordinateSpace(name: "cursor-plan-layout")
    }
    @ViewBuilder private var actions: some View {
        Button("Decline") { decide(false) }.accessibilityIdentifier("cursor-plan-decline")
        Button("Accept Plan") { decide(true) }.coincidePrimaryAction()
            .accessibilityIdentifier("cursor-plan-accept")
    }
    func decide(_ accept: Bool) {
        guard !isResponding else { return }
        onDecision(accept)
    }
    private func geometry(_ name: String) -> some View {
        GeometryReader { proxy in
            let frame = proxy.frame(in: .named("cursor-plan-layout"))
            Color.clear.onAppear { reportGeometry?(name, frame) }
                .onChange(of: frame) { _, value in reportGeometry?(name, value) }
        }
    }
}

private struct CursorPlanTodoView: View {
    let todo: CursorACPTodo
    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: symbol).accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 3) {
                Text(todo.content).textSelection(.enabled).fixedSize(horizontal: false, vertical: true)
                Text(status).font(.caption).foregroundStyle(.secondary)
            }
        }.accessibilityElement(children: .combine)
    }
    private var symbol: String {
        switch todo.status {
        case .pending: "circle"
        case .inProgress: "circle.dotted"
        case .completed: "checkmark.circle"
        case .cancelled: "xmark.circle"
        }
    }
    private var status: String {
        switch todo.status {
        case .pending: String(localized: "Pending")
        case .inProgress: String(localized: "In progress")
        case .completed: String(localized: "Completed")
        case .cancelled: String(localized: "Cancelled")
        }
    }
}
