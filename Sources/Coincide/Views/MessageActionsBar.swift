import AppKit
import CoincideCore
import CoincideMarkdown
import SwiftUI

/// Actions offered under a transcript message. Edit and Fork route to the
/// existing reviewed Run History flows; nil closures hide the action.
struct TranscriptMessageActions {
    var timestamps: TranscriptTimestamp
    var editFromHere: (() -> Void)?
    var editUnavailableReason: String?
    var forkFromHere: (() -> Void)?
    var forkUnavailableReason: String?
    var viewChanges: (() -> Void)?
}

/// Shown on hover or keyboard focus, and always while VoiceOver is running.
struct MessageActionsBar: View {
    let message: ChatMessage
    let role: MessageRole
    let actions: TranscriptMessageActions
    var steered = false
    var streaming = false
    var providerName = ""
    var visible: Bool
    var copyAvailable = true
    var copyUnavailableReason: String? = nil
    @State private var copied = false
    @State private var copyReset: Task<Void, Never>?
    @FocusState private var focused: String?
    @Environment(\.accessibilityVoiceOverEnabled) private var voiceOver
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        HStack(spacing: 4) {
            if role == .user {
                timestamp
                if steered {
                    Label("Steered", systemImage: "arrow.turn.down.right").labelStyle(.titleAndIcon)
                        .help("Sent into the running turn").accessibilityIdentifier("message-steered-\(message.id)")
                }
                copyButton
                if let edit = actions.editFromHere {
                    button("edit", title: String(localized: "Edit from Here"), symbol: "arrow.uturn.backward", action: edit,
                           reason: actions.editUnavailableReason,
                           help: String(localized: "Rewind the conversation to before this message and edit it. Workspace files stay unchanged unless you choose to restore them in the review."))
                }
            } else {
                if !streaming { copyButton }
                if let fork = actions.forkFromHere {
                    button("fork", title: String(localized: "Fork from Here"), symbol: "arrow.triangle.branch", action: fork,
                           reason: actions.forkUnavailableReason, help: String(localized: "Create a separate conversation through this response."))
                }
                if let changes = actions.viewChanges {
                    button("changes", title: String(localized: "View Changes"), symbol: "plus.forwardslash.minus", action: changes, reason: nil,
                           help: String(localized: "Show workspace changes saved for this run."))
                }
                timestamp
            }
        }
        .font(.system(size: 12)).foregroundStyle(.secondary)
        .buttonStyle(ChatIconButtonStyle(size: 28)).labelStyle(.iconOnly)
        .opacity(visible || voiceOver || focused != nil ? 1 : 0)
        .animation(reduceMotion ? nil : .easeOut(duration: 0.12), value: visible)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("message-actions-\(message.id)")
        .onDisappear { copyReset?.cancel(); copyReset = nil; copied = false }
    }

    private var timestamp: some View {
        Text(actions.timestamps.dayAware(message.createdAt)).font(.system(size: 11)).monospacedDigit().foregroundStyle(.tertiary)
            .padding(.horizontal, 5)
            .help(actions.timestamps.tooltip(message.createdAt))
            .accessibilityLabel(String(localized: "Sent \(actions.timestamps.tooltip(message.createdAt))"))
            .accessibilityIdentifier("message-timestamp-\(message.id)")
    }

    private var copyButton: some View {
        Button {
            NSPasteboard.general.clearContents(); NSPasteboard.general.setString(message.text, forType: .string)
            copied = true
            copyReset?.cancel()
            copyReset = Task {
                try? await Task.sleep(for: .seconds(1.5))
                guard !Task.isCancelled else { return }
                copied = false
            }
        } label: { Label(copied ? String(localized: "Copied") : String(localized: "Copy"), systemImage: copied ? "checkmark" : "doc.on.doc") }
        .help(copyUnavailableReason ?? (role == .user ? String(localized: "Copy message") : String(localized: "Copy response")))
        .accessibilityLabel(role == .user ? String(localized: "Copy message") : String(localized: "Copy \(providerName) response"))
        .accessibilityIdentifier("message-copy-\(message.id)")
        .focused($focused, equals: "copy")
        .disabled(message.text.isEmpty || !copyAvailable)
    }

    private func button(_ id: String, title: String, symbol: String, action: @escaping () -> Void, reason: String?, help: String) -> some View {
        Button(action: action) { Label(title, systemImage: symbol) }
            .disabled(reason != nil).help(reason ?? help)
            .accessibilityLabel(title).accessibilityHint(reason ?? help)
            .accessibilityIdentifier("message-\(id)-\(message.id)")
            .focused($focused, equals: id)
    }
}

/// Markdown for user prompts, so inserted file references are clickable, with
/// T3's long-message collapse (8 lines or 600 visible characters).
struct UserMessageBody: View {
    @AppStorage("renderMathInMarkdown") private var renderMathInMarkdown = false
    let text: String
    var workspace: URL?
    var openFile: (URL, Int?) -> Void = { _, _ in }
    @Binding var expanded: Bool
    static let collapsedHeight: CGFloat = 8 * 24

    var body: some View {
        let collapsible = TranscriptUserMessageCollapse.shouldCollapse(text)
        VStack(alignment: .leading, spacing: 8) {
            MarkdownView(text, workspace: workspace, mathEnabled: renderMathInMarkdown, openFile: openFile)
                .frame(maxHeight: collapsible && !expanded ? Self.collapsedHeight : nil, alignment: .top)
                .clipped()
                .mask {
                    if collapsible && !expanded {
                        LinearGradient(stops: [.init(color: .black, location: 0), .init(color: .black, location: 0.8), .init(color: .clear, location: 1)],
                                       startPoint: .top, endPoint: .bottom)
                    } else { Rectangle() }
                }
            if collapsible {
                Button(expanded ? String(localized: "Show less") : String(localized: "Show full message")) { expanded.toggle() }
                    .buttonStyle(.link).font(.caption)
                    .accessibilityHint(expanded ? String(localized: "Collapses this long message") : String(localized: "Shows the rest of this long message"))
                    .accessibilityIdentifier("user-message-collapse")
            }
        }
    }
}
