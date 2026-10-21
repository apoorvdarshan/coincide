import CoincideCore
import SwiftUI
import UniformTypeIdentifiers

struct ComposerView: View {
    @Binding var text: String
    let provider: ProviderKind
    var providerName: String? = nil
    let permission: PermissionMode
    let busy: Bool
    let submitting: Bool
    let hasAttachments: Bool
    let attach: () -> Void
    let importProviders: ([NSItemProvider]) -> Void
    let setPermission: (PermissionMode) -> Void
    let send: () -> Void
    let stop: () -> Void
    @FocusState private var editorFocused: Bool
    @State private var dropTargeted = false
    private var canSend: Bool { !submitting && (hasAttachments || !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty) }
    private var height: CGFloat { min(150, max(40, CGFloat(text.split(separator: "\n", omittingEmptySubsequences: false).count) * 21 + 14)) }
    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            ZStack(alignment: .topLeading) {
                if text.isEmpty { Text("Message \(providerName ?? provider.name)…").foregroundStyle(.tertiary).padding(.horizontal, 5).padding(.top, 8).allowsHitTesting(false) }
                TextEditor(text: $text).font(.system(size: 15)).frame(height: height)
                    .accessibilityIdentifier("composer-input")
                    .focused($editorFocused)
                    .onAppear { editorFocused = true }
                    .scrollContentBackground(.hidden).accessibilityLabel("Message to \(providerName ?? provider.name)")
                    .onKeyPress(keys: [.return], phases: .down) { event in
                        guard !event.modifiers.contains(.shift), !event.modifiers.contains(.option) else { return .ignored }
                        guard canSend else { return .ignored }
                        send(); return .handled
                    }
                    .onPasteCommand(of: [UTType.fileURL, UTType.image]) { importProviders($0) }
            }
            HStack {
                Button(action: attach) { Image(systemName: "plus").frame(width: 24, height: 24) }
                    .buttonStyle(.plain).help("Attach files").accessibilityLabel("Attach files").disabled(submitting)
                if provider == .acp {
                    Label("Agent permissions", systemImage: "hand.raised").font(.caption).foregroundStyle(.secondary)
                        .help("The agent enforces its own sandbox. Coincide shows the permission requests it sends.")
                } else { Menu {
                    ForEach(PermissionMode.allCases) { mode in
                        Button { setPermission(mode) } label: {
                            if mode == permission { Label(mode.title, systemImage: "checkmark") } else { Text(mode.title) }
                        }
                    }
                } label: { Label(permission.title, systemImage: "slider.horizontal.3").font(.caption) }
                .menuStyle(.borderlessButton).fixedSize()
                }
                Spacer()
                Text("⇧ Return for a new line").font(.caption2).foregroundStyle(.tertiary)
                if busy {
                    Button(action: stop) { Image(systemName: "stop.fill").frame(width: 30, height: 30) }
                        .buttonStyle(.plain).help("Stop turn").accessibilityLabel("Stop turn")
                }
                Button(action: send) {
                    Image(systemName: "arrow.up").font(.system(size: 14, weight: .semibold))
                        .foregroundStyle(Color(nsColor: .controlBackgroundColor))
                        .frame(width: 30, height: 30).background(Color.primary, in: Circle())
                }
                .buttonStyle(.plain).keyboardShortcut(.return, modifiers: .command)
                .accessibilityLabel(busy ? "Queue message" : "Send message")
                .help(busy ? "Send after the current turn" : "Send message")
                .disabled(!canSend)
            }
        }
        .padding(14)
        .background(Color.primary.opacity(0.045), in: RoundedRectangle(cornerRadius: 23))
        .overlay { RoundedRectangle(cornerRadius: 23).strokeBorder(Color.primary.opacity(0.07), lineWidth: 1) }
        .onDrop(of: [UTType.fileURL, UTType.image], isTargeted: $dropTargeted) { providers in importProviders(providers); return true }
        .overlay { if dropTargeted { RoundedRectangle(cornerRadius: 23).strokeBorder(Color.accentColor, lineWidth: 2).allowsHitTesting(false) } }
    }
}
