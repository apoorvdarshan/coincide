import CoincideCore
import SwiftUI

struct ComposerView: View {
    @Binding var text: String
    let provider: ProviderKind
    let permission: PermissionMode
    let busy: Bool
    let setPermission: (PermissionMode) -> Void
    let send: () -> Void
    let stop: () -> Void
    private var height: CGFloat { min(150, max(40, CGFloat(text.split(separator: "\n", omittingEmptySubsequences: false).count) * 21 + 14)) }
    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            ZStack(alignment: .topLeading) {
                if text.isEmpty { Text("Message \(provider.name)…").foregroundStyle(.tertiary).padding(.horizontal, 5).padding(.top, 8).allowsHitTesting(false) }
                TextEditor(text: $text).font(.system(size: 15)).frame(height: height)
                    .scrollContentBackground(.hidden).accessibilityLabel("Message to \(provider.name)")
                    .onKeyPress(keys: [.return], phases: .down) { event in
                        guard !event.modifiers.contains(.shift), !event.modifiers.contains(.option) else { return .ignored }
                        guard !busy, !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return .ignored }
                        send(); return .handled
                    }
            }
            HStack {
                Menu {
                    ForEach(PermissionMode.allCases) { mode in
                        Button { setPermission(mode) } label: {
                            if mode == permission { Label(mode.title, systemImage: "checkmark") } else { Text(mode.title) }
                        }
                    }
                } label: { Label(permission.title, systemImage: "slider.horizontal.3").font(.caption) }
                .menuStyle(.borderlessButton).fixedSize().disabled(busy)
                Spacer()
                Text("⇧ Return for a new line").font(.caption2).foregroundStyle(.tertiary)
                Button(action: busy ? stop : send) {
                    Image(systemName: busy ? "stop.fill" : "arrow.up").font(.system(size: 14, weight: .semibold))
                        .foregroundStyle(Color(nsColor: .controlBackgroundColor))
                        .frame(width: 30, height: 30).background(Color.primary, in: Circle())
                }
                .buttonStyle(.plain).keyboardShortcut(.return, modifiers: .command)
                .accessibilityLabel(busy ? "Stop turn" : "Send message")
                .help(busy ? "Stop turn" : "Send message")
                .disabled(!busy && text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        }
        .padding(14)
        .background(Color.primary.opacity(0.045), in: RoundedRectangle(cornerRadius: 23))
        .overlay { RoundedRectangle(cornerRadius: 23).strokeBorder(Color.primary.opacity(0.07), lineWidth: 1) }
    }
}
