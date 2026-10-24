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
    var meta = TranscriptMessageMeta()
    var actions = TranscriptMessageActions(timestamps: .init())
    var userExpanded: Binding<Bool> = .constant(false)
    @State private var hovering = false
    @State private var toolExpanded = false
    var body: some View {
        Group {
            if message.role == .user {
                VStack(alignment: .trailing, spacing: 4) {
                    HStack {
                        Spacer(minLength: 80)
                        VStack(alignment: .leading, spacing: 10) {
                            if let attachments = message.attachments, !attachments.isEmpty { AttachmentShelf(store: store, attachments: attachments) }
                            if !message.text.isEmpty {
                                UserMessageBody(text: message.text, workspace: URL(fileURLWithPath: workspacePath), openFile: openFile, expanded: userExpanded)
                            }
                            if let error = message.submissionError { Label(error, systemImage: "exclamationmark.circle").font(.caption).foregroundStyle(.red).textSelection(.enabled) }
                        }.padding(.horizontal, 18).padding(.vertical, 12)
                            .background(ChatChrome.composer, in: RoundedRectangle(cornerRadius: 20))
                    }
                    MessageActionsBar(message: message, role: .user, actions: actions, steered: message.promptSteeringID != nil, visible: hovering)
                }
            } else if message.role == .tool || message.role == .reasoning {
                // Rows normally arrive through TranscriptRowsView; this keeps a
                // standalone message renderable with the same card views.
                if message.role == .reasoning {
                    ReasoningRowView(text: message.text, live: meta.streaming, duration: nil, expanded: $toolExpanded,
                                     workspace: URL(fileURLWithPath: workspacePath), openFile: openFile)
                } else {
                    ToolCardView(card: TranscriptToolPresentation.card(for: message, context: .init(workspacePath: workspacePath)), entity: message.providerEntity,
                                 workspacePath: workspacePath, expanded: $toolExpanded, openFile: openFile)
                }
            } else {
                VStack(alignment: .leading, spacing: 12) {
                    if message.role == .system { Label("Notice", systemImage: "info.circle").font(.caption).foregroundStyle(.secondary) }
                    MarkdownView(message.text, workspace: URL(fileURLWithPath: workspacePath), mathEnabled: renderMathInMarkdown, openFile: openFile)
                    if message.role == .assistant {
                        MessageActionsBar(message: message, role: .assistant, actions: actions, streaming: meta.streaming,
                                          providerName: providerName, visible: hovering || meta.terminalResponse)
                    } else {
                        Button {
                            NSPasteboard.general.clearContents(); NSPasteboard.general.setString(message.text, forType: .string)
                        } label: { Image(systemName: "doc.on.doc").font(.caption).foregroundStyle(.secondary) }
                        .buttonStyle(ChatIconButtonStyle(size: 28)).help("Copy notice").accessibilityLabel("Copy notice")
                    }
                }
            }
        }
        .onHover { hovering = $0 }
        .accessibilityElement(children: .contain)
    }
}
