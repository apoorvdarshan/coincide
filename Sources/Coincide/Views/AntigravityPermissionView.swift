import CoincideCore
import SwiftUI

/// The shared approval surface owns response dispatch and its surrounding glass.
struct AntigravityPermissionView: View {
    let request: AntigravityPermissionRequest
    let isResponding: Bool
    let onOption: (String) -> Void
    let onCancel: () -> Void
    @State private var selection: String?
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Label(request.isQuestion ? "Antigravity has a question" : "Antigravity needs permission", systemImage: request.isQuestion ? "questionmark.bubble" : "hand.raised")
                .font(.headline)
            ScrollView {
                VStack(alignment: .leading, spacing: 12) {
                    Text(request.title).fixedSize(horizontal: false, vertical: true).textSelection(.enabled)
                    ForEach(request.options) { option in
                        VStack(alignment: .leading, spacing: 6) {
                            Text(option.name).font(.subheadline.weight(.medium))
                                .fixedSize(horizontal: false, vertical: true).textSelection(.enabled)
                            if !request.isQuestion {
                                Text(Self.scope(option.kind)).font(.caption).foregroundStyle(.secondary)
                                    .fixedSize(horizontal: false, vertical: true)
                            }
                            if let warning = option.securityWarning {
                                Label { Text(warning).fixedSize(horizontal: false, vertical: true).textSelection(.enabled) }
                                    icon: { Image(systemName: "exclamationmark.shield") }
                                    .font(.caption).accessibilityIdentifier("antigravity-security-" + option.id)
                            }
                            if !request.isQuestion {
                                Button("Choose") { choose(option.id) }
                                    .accessibilityLabel("\(option.name), \(Self.scope(option.kind))")
                                    .help("\(option.name)\n\(Self.scope(option.kind))")
                                    .accessibilityIdentifier("antigravity-option-" + option.id)
                            }
                        }.frame(maxWidth: .infinity, alignment: .leading)
                    }
                }.frame(minWidth: 0, maxWidth: .infinity, alignment: .leading)
            }.frame(minHeight: 50, maxHeight: 260)
            if request.isQuestion {
                Picker("Your answer", selection: $selection) {
                    Text("Choose an answer").tag(String?.none)
                    ForEach(request.options) { option in Text(option.name).tag(Optional(option.id)) }
                }.accessibilityIdentifier("antigravity-question-selection")
                HStack {
                    Button("Cancel", action: cancel).keyboardShortcut(.cancelAction)
                    Spacer(minLength: 8)
                    Button("Submit Answer") { if let selection { choose(selection) } }
                        .disabled(selection == nil).accessibilityIdentifier("antigravity-submit-answer")
                }
            } else {
                Button("Cancel", action: cancel).keyboardShortcut(.cancelAction)
            }
        }.disabled(isResponding)
            .onChange(of: request) { _, _ in selection = nil }
    }
    func choose(_ id: String) {
        guard !isResponding, (try? request.response(optionID: id)) != nil else { return }
        onOption(id)
    }
    func cancel() { guard !isResponding else { return }; onCancel() }
    static func scope(_ kind: String) -> String {
        switch kind {
        case "allow_once": String(localized: "Allow once")
        case "allow_always": String(localized: "Always allow")
        case "reject_once": String(localized: "Decline once")
        case "reject_always": String(localized: "Always decline")
        default: String(localized: "Scope: \(kind)")
        }
    }
}
