import CoincideCore
import CoincideMarkdown
import SwiftUI

struct MessageView: View {
    @AppStorage("renderMathInMarkdown") private var renderMathInMarkdown = false
    var store: WorkspaceStore
    let message: ChatMessage
    let providerName: String
    let workspacePath: String
    let openFile: (URL, Int?) -> Void
    var body: some View {
        Group {
            if message.role == .user {
                HStack {
                    Spacer(minLength: 80)
                    VStack(alignment: .leading, spacing: 10) {
                        if let attachments = message.attachments, !attachments.isEmpty { AttachmentShelf(store: store, attachments: attachments) }
                        if !message.text.isEmpty { Text(message.text).textSelection(.enabled) }
                        if let error = message.submissionError { Label(error, systemImage: "exclamationmark.circle").font(.caption).foregroundStyle(.red).textSelection(.enabled) }
                    }.padding(.horizontal, 18).padding(.vertical, 12)
                        .background(Color.primary.opacity(0.065), in: RoundedRectangle(cornerRadius: 22))
                }.coincideGlassGroup()
            } else if message.role == .tool || message.role == .reasoning {
                DisclosureGroup {
                    Text(message.text).font(.system(.caption, design: .monospaced)).textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading).padding(.top, 8)
                    if let entity = message.providerEntity {
                        if entity.fields.object?["rawInput"] != nil { entityDetail("Input", value: entity.fields["rawInput"]) }
                        if entity.fields.object?["rawOutput"] != nil { entityDetail("Output", value: entity.fields["rawOutput"]) }
                        if entity.fields.object?["locations"] != nil { entityDetail("Files", value: entity.fields["locations"]) }
                        DisclosureGroup("Details") { Text(entity.fields.pretty).font(.system(.caption, design: .monospaced)).textSelection(.enabled) }
                    }
                } label: {
                    HStack {
                        Label(message.providerEntity?.fields["title"].string ?? (message.role == .tool ? "Tool activity" : "Reasoning"), systemImage: message.role == .tool ? "terminal" : "brain")
                        if let title = copilotTaskTitle { Text("Copilot task · \(title)").lineLimit(2) }
                        if let status = message.providerEntity?.fields["status"].string { Text(status.replacingOccurrences(of: "_", with: " ")).foregroundStyle(.tertiary) }
                    }.font(.caption).foregroundStyle(.secondary)
                }
            } else {
                VStack(alignment: .leading, spacing: 12) {
                    if let title = copilotTaskTitle { Label("Copilot task · \(title)", systemImage: "person.crop.square.badge.ellipsis").font(.caption).foregroundStyle(.secondary) }
                    if message.role == .system { Label("Notice", systemImage: "info.circle").font(.caption).foregroundStyle(.secondary) }
                    MarkdownView(message.text, workspace: URL(fileURLWithPath: workspacePath), mathEnabled: renderMathInMarkdown, openFile: openFile)
                    Button {
                        NSPasteboard.general.clearContents(); NSPasteboard.general.setString(message.text, forType: .string)
                    } label: { Image(systemName: "doc.on.doc").font(.caption).foregroundStyle(.secondary) }
                    .buttonStyle(.plain).help("Copy response").accessibilityLabel("Copy \(providerName) response")
                }
            }
        }
        .accessibilityElement(children: .contain)
    }
    private var copilotTaskTitle: String? {
        guard let owner = message.runReference, let metadata = message.providerEntity?.fields["_meta"]["github.com/copilot"],
              metadata["parentRunID"].string == owner.runID.uuidString,
              metadata["parentToolCallId"].string != nil else { return nil }
        return metadata["taskTitle"].string ?? "Background task"
    }
    private func entityDetail(_ title: String, value: JSONValue) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title).font(.caption).foregroundStyle(.secondary)
            Text(value.string ?? value.pretty).font(.system(.caption, design: .monospaced)).textSelection(.enabled)
        }.frame(maxWidth: .infinity, alignment: .leading).padding(.top, 6)
    }
}
