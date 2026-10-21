import CoincideCore
import CoincideMarkdown
import SwiftUI

struct MessageView: View {
    let message: ChatMessage
    let providerName: String
    let workspacePath: String
    let openFile: (URL, Int?) -> Void
    var body: some View {
        Group {
            if message.role == .user {
                HStack {
                    Spacer(minLength: 80)
                    Text(message.text).textSelection(.enabled).padding(.horizontal, 18).padding(.vertical, 12)
                        .background(Color.primary.opacity(0.065), in: RoundedRectangle(cornerRadius: 22))
                }
            } else if message.role == .tool || message.role == .reasoning {
                DisclosureGroup {
                    Text(message.text).font(.system(.caption, design: .monospaced)).textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading).padding(.top, 8)
                } label: { Label(message.role == .tool ? "Tool activity" : "Reasoning", systemImage: message.role == .tool ? "terminal" : "brain").font(.caption).foregroundStyle(.secondary) }
            } else {
                VStack(alignment: .leading, spacing: 12) {
                    if message.role == .system { Label("Notice", systemImage: "info.circle").font(.caption).foregroundStyle(.secondary) }
                    MarkdownView(message.text, workspace: URL(fileURLWithPath: workspacePath), openFile: openFile)
                    Button {
                        NSPasteboard.general.clearContents(); NSPasteboard.general.setString(message.text, forType: .string)
                    } label: { Image(systemName: "doc.on.doc").font(.caption).foregroundStyle(.secondary) }
                    .buttonStyle(.plain).help("Copy response").accessibilityLabel("Copy \(providerName) response")
                }
            }
        }
        .accessibilityElement(children: .contain)
    }
}
