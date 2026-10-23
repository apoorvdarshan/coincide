import CoincideCore
import SwiftUI

/// Installs one window's keyboard surface on ContentView: the command target for
/// menus and shortcuts, the palette overlay, history tracking and notices.
struct MainWindowKeyboardSupport: ViewModifier {
    let store: WorkspaceStore
    let keybindings: KeybindingsStore?
    let presentations: () -> MainWindowPresentations
    @State private var controller: MainWindowController?

    func body(content: Content) -> some View {
        content
            .environment(controller)
            .focusedSceneValue(\.mainWindowController, controller)
            .overlay { if let controller { CommandPaletteOverlay(controller: controller) } }
            .overlay(alignment: .bottom) {
                VStack(spacing: 8) {
                    if let keybindings, let warning = keybindings.warning { KeybindingsIssueBanner(message: warning, keybindings: keybindings) }
                    if let text = controller?.notice ?? keybindings?.reloadNotice { KeyboardNoticeHUD(text: text) }
                }.padding(.bottom, 18).padding(.horizontal, 24)
                    .animation(.easeOut(duration: 0.15), value: controller?.notice)
            }
            .background { if let controller { MainWindowKeyboardRegistration(controller: controller, dispatcher: keybindings?.dispatcher) } }
            .onAppear {
                guard controller == nil else { return }
                let created = MainWindowController(store: store, keybindings: keybindings)
                created.presentations = presentations()
                controller = created
            }
            .onChange(of: store.selectedThreadID) { _, id in controller?.selectionChanged(to: id) }
            .onChange(of: store.inspectorVisible) { old, new in if old, !new { controller?.inspectorWillHide() } }
    }
}

extension View {
    func mainWindowKeyboard(store: WorkspaceStore, keybindings: KeybindingsStore?, presentations: @escaping () -> MainWindowPresentations) -> some View {
        modifier(MainWindowKeyboardSupport(store: store, keybindings: keybindings, presentations: presentations))
    }
}

/// T3's non-blocking invalid-configuration warning with a path to the file.
struct KeybindingsIssueBanner: View {
    let message: String
    let keybindings: KeybindingsStore
    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: "exclamationmark.triangle").foregroundStyle(.orange).accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 6) {
                Text("Invalid keybindings configuration").font(.callout.weight(.semibold))
                Text(verbatim: message).font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                    .textSelection(.enabled)
                Text("Valid rules and defaults still apply.").font(.caption2).foregroundStyle(.secondary)
                HStack {
                    Button("Open keybindings.json") { keybindings.openFile() }.accessibilityIdentifier("keybindings-open-file")
                    Button("Show in Finder") { keybindings.revealFile() }
                }.controlSize(.small)
            }
            Spacer(minLength: 0)
            Button { keybindings.warning = nil } label: { Image(systemName: "xmark") }.buttonStyle(.borderless)
                .help("Dismiss").accessibilityLabel("Dismiss keybindings warning")
        }
        .padding(12)
        .frame(maxWidth: 520)
        .coincideSurface(cornerRadius: 12)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("keybindings-warning")
    }
}

struct KeyboardNoticeHUD: View {
    let text: String
    var body: some View {
        Text(verbatim: text).font(.callout).lineLimit(1)
            .padding(.horizontal, 14).padding(.vertical, 8)
            .coincideSurface(cornerRadius: 18)
            .accessibilityIdentifier("keyboard-notice")
            .accessibilityAddTraits(.updatesFrequently)
            .transition(.opacity)
    }
}

/// `⌘1`…`⌘9` beside the first nine sidebar rows while the jump modifier is held.
struct ThreadJumpHintBadge: View {
    let threadID: UUID
    @Environment(MainWindowController.self) private var controller: MainWindowController?
    var body: some View {
        if let hint = controller?.jumpHint(for: threadID) {
            Text(verbatim: hint).font(.caption2.monospaced().weight(.medium)).foregroundStyle(.secondary)
                .padding(.horizontal, 5).padding(.vertical, 1)
                .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 4))
                .accessibilityLabel(Text("Shortcut \(hint)"))
                .transition(.opacity)
        }
    }
}
