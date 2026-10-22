import CoincideCore
import SwiftUI

struct PiExtensionApprovalView: View {
    let request: PiExtensionRequest
    let isResponding: Bool
    let onDecision: (Bool) -> Void
    let onAnswer: ([String: String]) -> Void
    let onOption: (String) -> Void
    @State private var value: String
    @State private var selected: String?
    init(request: PiExtensionRequest, isResponding: Bool, onDecision: @escaping (Bool) -> Void,
         onAnswer: @escaping ([String: String]) -> Void, onOption: @escaping (String) -> Void) {
        self.request = request; self.isResponding = isResponding; self.onDecision = onDecision
        self.onAnswer = onAnswer; self.onOption = onOption
        _value = State(initialValue: request.prefill ?? "")
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Label("Pi needs your input", systemImage: request.method == .confirm ? "hand.raised" : "questionmark.bubble").font(.headline)
            ScrollView {
                VStack(alignment: .leading, spacing: 10) {
                    Text(request.title).font(.subheadline.weight(.medium)).textSelection(.enabled)
                        .fixedSize(horizontal: false, vertical: true)
                    if let message = request.message { Text(message).textSelection(.enabled).fixedSize(horizontal: false, vertical: true) }
                    switch request.method {
                    case .confirm: EmptyView()
                    case .select:
                        Picker("Answer", selection: $selected) {
                            Text("Select an answer").tag(String?.none)
                            ForEach(request.options, id: \.self) { Text($0).tag(Optional($0)) }
                        }.accessibilityIdentifier("pi-extension-choice")
                        if let selected { Text(selected).textSelection(.enabled).fixedSize(horizontal: false, vertical: true) }
                    case .input:
                        TextField(request.placeholder ?? "Your answer", text: $value, axis: .vertical)
                            .lineLimit(1...6).accessibilityLabel(request.title).accessibilityIdentifier("pi-extension-input")
                    case .editor:
                        TextEditor(text: $value).font(.system(.body, design: .monospaced)).frame(height: 160)
                            .accessibilityLabel(request.title).accessibilityIdentifier("pi-extension-editor")
                    }
                }.frame(minWidth: 0, maxWidth: .infinity, alignment: .leading)
            }.frame(minHeight: 60, maxHeight: 280)
            ViewThatFits(in: .horizontal) {
                HStack { actions }.fixedSize(horizontal: true, vertical: false)
                VStack(alignment: .leading, spacing: 8) { actions }
            }
        }.disabled(isResponding).onChange(of: request) { _, next in value = next.prefill ?? ""; selected = nil }
    }
    @ViewBuilder private var actions: some View {
        Button(request.method == .confirm ? "No" : "Cancel") { if !isResponding { onDecision(false) } }
            .accessibilityIdentifier("pi-extension-cancel")
        if request.method == .confirm {
            Button("Yes") { if !isResponding { onDecision(true) } }.coincidePrimaryAction()
                .accessibilityIdentifier("pi-extension-confirm")
        } else {
            Button("Submit") {
                guard !isResponding else { return }
                if request.method == .select { if let selected, request.options.contains(selected) { onOption(selected) } }
                else if validText { onAnswer(["value": value]) }
            }.coincidePrimaryAction().disabled(request.method == .select ? selected == nil : !validText)
                .accessibilityIdentifier("pi-extension-submit")
        }
    }
    private var validText: Bool { value.utf8.count <= 1_048_576 && !value.contains("\u{0}") }
}
