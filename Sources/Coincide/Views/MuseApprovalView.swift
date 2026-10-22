import CoincideCore
import SwiftUI

/// The surrounding ApprovalView owns the glass surface and response lifetime.
struct MuseApprovalView: View {
    let request: MuseApprovalRequest
    let isResponding: Bool
    let onOption: (String) -> Void
    var reportGeometry: ((String, CGRect) -> Void)? = nil
    @State private var collapsedRules: Set<String> = []

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Label("Muse needs permission", systemImage: "hand.raised")
                .font(.headline).background { geometry("header") }
            ScrollView {
                VStack(alignment: .leading, spacing: 8) {
                    Text(request.title).font(.subheadline.weight(.medium))
                        .fixedSize(horizontal: false, vertical: true).textSelection(.enabled)
                    if !request.detail.isEmpty {
                        Text(request.detail).font(.system(.body, design: .monospaced))
                            .fixedSize(horizontal: false, vertical: true).textSelection(.enabled)
                    }
                }.frame(minWidth: 0, maxWidth: .infinity, alignment: .leading)
            }.frame(minHeight: 40, maxHeight: 160).background { geometry("details") }
            ScrollView {
                VStack(alignment: .leading, spacing: 8) {
                    ForEach(request.choices) { choice in
                        VStack(alignment: .leading, spacing: 4) {
                            Text(choice.label).font(.subheadline.weight(.medium))
                                .fixedSize(horizontal: false, vertical: true).textSelection(.enabled)
                                .background { geometry("choice-label-" + choice.id) }
                            HStack(alignment: .firstTextBaseline) {
                                Text(Self.scopeDescription(choice.scope)).font(.caption).foregroundStyle(.secondary)
                                    .fixedSize(horizontal: false, vertical: true)
                                Spacer(minLength: 8)
                                Button("Choose") { choose(choice.id) }
                                    .buttonStyle(.bordered)
                                    .accessibilityLabel("\(choice.label), \(Self.scopeDescription(choice.scope))")
                                    .help("\(choice.label)\n\(Self.scopeDescription(choice.scope))")
                                    .accessibilityIdentifier("muse-approval-choice-" + choice.id)
                            }
                            if let preview = choice.rulePreview, !preview.isEmpty {
                                DisclosureGroup("Rule preview", isExpanded: Binding(get: { !collapsedRules.contains(choice.id) }, set: { expanded in
                                    guard !isResponding else { return }
                                    if expanded { collapsedRules.remove(choice.id) } else { collapsedRules.insert(choice.id) }
                                })) {
                                    Text(preview).font(.system(.caption, design: .monospaced))
                                        .fixedSize(horizontal: false, vertical: true).textSelection(.enabled)
                                }.accessibilityIdentifier("muse-approval-rule-" + choice.id)
                            }
                        }
                    }
                }.frame(minWidth: 0, maxWidth: .infinity, alignment: .leading).padding(.trailing, 4)
            }.frame(minHeight: 50, maxHeight: 220).background { geometry("choices") }
        }
        .frame(minWidth: 0, maxWidth: .infinity, alignment: .leading)
        .disabled(isResponding)
        .onChange(of: request) { _, _ in collapsedRules = [] }
        .background { geometry("bounds") }
        .coordinateSpace(name: "muse-approval-layout")
    }

    func choose(_ choiceID: String) {
        guard !isResponding, (try? request.decisionBody(choiceID: choiceID)) != nil else { return }
        onOption(choiceID)
    }

    static func scopeDescription(_ scope: String) -> String {
        switch scope {
        case "once": String(localized: "Once")
        case "session": String(localized: "This session")
        case "localPersistent": String(localized: "Persistent rule")
        default: String(localized: "Scope: \(scope)")
        }
    }

    private func geometry(_ name: String) -> some View {
        GeometryReader { proxy in
            let frame = proxy.frame(in: .named("muse-approval-layout"))
            Color.clear.onAppear { reportGeometry?(name, frame) }
                .onChange(of: frame) { _, value in reportGeometry?(name, value) }
        }
    }
}
