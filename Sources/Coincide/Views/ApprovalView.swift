import CoincideCore
import SwiftUI

struct ApprovalView: View {
    let request: ApprovalRequest
    var isResponding = false
    let onDecision: (Bool) -> Void
    let onAnswer: ([String: String]) -> Void
    var onOption: (String) -> Void = { _ in }
    @State private var answers: [String: String] = [:]
    private var questions: [JSONValue] { request.questions }
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            if request.isQuestion {
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
                if request.method == "session/request_permission" {
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
