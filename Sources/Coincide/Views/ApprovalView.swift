import CoincideCore
import SwiftUI

struct ApprovalView: View {
    let request: ApprovalRequest
    var isResponding = false
    let onDecision: (Bool) -> Void
    let onAnswer: ([String: String]) -> Void
    var onOption: (String) -> Void = { _ in }
    var onSelections: ([String: [String]]) -> Void = { _ in }
    var onSelectionsWithNotes: ([String: [String]], [String: String]) -> Void = { _, _ in }
    @State private var answers: [String: String] = [:]
    private var questions: [JSONValue] { request.questions }
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            if request.method == AntigravityProtocol.permissionMethod || request.method == AntigravityProtocol.questionMethod {
                if let input = request.antigravityPermission {
                    AntigravityPermissionView(request: input, isResponding: isResponding,
                        onOption: onOption, onCancel: { onDecision(false) })
                } else {
                    Text("This Antigravity request cannot be displayed safely. Stop the conversation to dismiss it.")
                }
            } else if request.method == "muse/approval" {
                if let input = request.museApproval {
                    MuseApprovalView(request: input, isResponding: isResponding, onOption: onOption)
                } else { Text("This Muse approval cannot be displayed safely. Stop the conversation to dismiss it.") }
            } else if request.method == "muse/userInput" {
                if let input = request.museUserInput {
                    MuseUserInputView(request: input, isResponding: isResponding,
                        onAnswer: onSelectionsWithNotes, onCancel: { onDecision(false) })
                } else { Text("These Muse questions cannot be displayed safely. Stop the conversation to dismiss them.") }
            } else if request.method == "pi/extension" {
                if let input = request.piExtension {
                    PiExtensionApprovalView(request: input, isResponding: isResponding,
                        onDecision: onDecision, onAnswer: onAnswer, onOption: onOption)
                } else {
                    Text("This Pi request cannot be displayed safely.")
                    Button("Cancel Request") { onDecision(false) }
                }
            } else if request.method == "opencode/form" {
                if let form = request.openCodeForm {
                    OpenCodeFormApprovalView(form: form, isResponding: isResponding,
                        onSelections: onSelections, onCancel: { onDecision(false) })
                } else {
                    Text("This OpenCode form cannot be displayed safely.")
                    Button("Cancel Form") { onDecision(false) }
                }
            } else if request.method == "opencode/question" {
                if let question = request.openCodeQuestion {
                    OpenCodeQuestionApprovalView(request: question, isResponding: isResponding,
                        onSelections: onSelections, onCancel: { onDecision(false) })
                } else {
                    Text("These OpenCode questions cannot be displayed safely.")
                    Button("Cancel Questions") { onDecision(false) }
                }
            } else if request.isGrokQuestion {
                if let question = request.grokQuestion {
                    GrokQuestionApprovalView(request: question, isResponding: isResponding,
                        onSubmit: onSelectionsWithNotes, onCancel: { onDecision(false) })
                } else {
                    Text("These Grok questions cannot be displayed safely.")
                    Button("Cancel Questions") { onDecision(false) }
                }
            } else if let question = request.cursorQuestion {
                CursorQuestionApprovalView(request: question, isResponding: isResponding,
                    onSelections: onSelections, onSkip: { onDecision(false) })
            } else if let plan = request.cursorPlan {
                CursorPlanApprovalView(request: plan, isResponding: isResponding, onDecision: onDecision)
            } else if request.isQuestion {
                Text("Your agent needs input").font(.headline)
                ForEach(questions, id: \.self) { question in
                    if let id = question["id"].string {
                        Text(question["question"].string ?? "Question").font(.subheadline)
                        if let options = question["options"].array {
                            ForEach(options, id: \.self) { option in
                                if let label = option["label"].string { Button(label) { answers[id] = label }.buttonStyle(.bordered) }
                            }
                        }
                        TextField("Your answer", text: Binding(get: { answers[id] ?? "" }, set: { answers[id] = $0 }))
                    }
                }
                Button("Submit Answers") { onAnswer(answers) }.disabled(questions.contains { (answers[$0["id"].string ?? ""] ?? "").isEmpty })
            } else {
                Label(request.title, systemImage: "hand.raised").font(.headline)
                ScrollView { Text(request.detail).font(.system(.caption, design: .monospaced)).textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading) }.frame(maxHeight: 140)
                if request.method == "session/request_permission" || request.method == "opencode/permission" {
                    ViewThatFits(in: .horizontal) {
                        HStack { permissionOptions }
                        VStack(alignment: .leading) { permissionOptions }
                    }
                    Button("Cancel Request") { onDecision(false) }
                } else {
                    HStack { Spacer(); Button("Decline") { onDecision(false) }; Button("Approve Once") { onDecision(true) }.buttonStyle(.borderedProminent) }
                }
            }
            if isResponding { HStack { ProgressView().controlSize(.small); Text("Sending response…").font(.caption) } }
        }.padding().coincideSurface().disabled(isResponding)
    }
    private var permissionOptions: some View {
        ForEach(request.params["options"].array ?? [], id: \.self) { option in
            if let id = option["optionId"].string {
                Button(option["name"].string ?? id) { onOption(id) }.buttonStyle(.bordered)
            }
        }
    }
}
