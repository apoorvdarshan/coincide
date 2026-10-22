import CoincideCore
import SwiftUI
import UniformTypeIdentifiers
import AppKit

struct ComposerView: View {
    @Binding var text: String
    let provider: ProviderKind
    var providerName: String? = nil
    let permission: PermissionMode
    let busy: Bool
    let submitting: Bool
    let hasAttachments: Bool
    var historyLocked = false
    var followUpBehavior = ComposerFollowUpBehavior.queue
    var steeringAvailable = false
    var steeringExplanation: String? = nil
    var steer: (() -> Void)? = nil
    let attach: () -> Void
    var referenceFile: (() -> Void)? = nil
    let importProviders: ([NSItemProvider]) -> Void
    let setPermission: (PermissionMode) -> Void
    let send: () -> Void
    let stop: () -> Void
    var reportGeometry: ((String, CGRect) -> Void)? = nil
    var grokRuntimeMode: GrokACPRuntimeMode? = nil
    var setGrokRuntimeMode: (GrokACPRuntimeMode) -> Void = { _ in }
    @FocusState private var editorFocused: Bool
    @State private var dropTargeted = false
    private var canSend: Bool { !historyLocked && !submitting && (hasAttachments || !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty) }
    private var canSteer: Bool { steeringAvailable && steer != nil }
    private var delivery: ComposerDelivery {
        .resolve(running: busy, preference: followUpBehavior, alternate: false, canSteer: canSteer)
    }
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
                        activate(alternate: event.modifiers.contains(.command) || event.modifiers.contains(.control))
                        return .handled
                    }
                    .onPasteCommand(of: [UTType.fileURL, UTType.image]) { importProviders($0) }
            }
            ViewThatFits(in: .horizontal) {
                HStack {
                    attachmentControls
                    permissionControl
                    Spacer(minLength: 8)
                    if !busy { newlineHint }
                    deliveryControls
                }
                VStack(alignment: .leading, spacing: 8) {
                    HStack { attachmentControls; permissionControl; Spacer(minLength: 0) }
                    HStack { newlineHint; Spacer(minLength: 8); deliveryControls }
                }
            }
            if busy, let steeringExplanation {
                Text(steeringExplanation).font(.caption2).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .accessibilityIdentifier("composer-steering-explanation")
            }
        }
        .padding(14)
        .coincideSurface(cornerRadius: 23)
        .onDrop(of: [UTType.fileURL, UTType.image], isTargeted: $dropTargeted) { providers in importProviders(providers); return true }
        .overlay { if dropTargeted { RoundedRectangle(cornerRadius: 23).strokeBorder(Color.accentColor, lineWidth: 2).allowsHitTesting(false) } }
        .background { geometry("bounds") }
        .coordinateSpace(name: "composer-layout")
    }
    @ViewBuilder private var attachmentControls: some View {
        Button(action: attach) { Image(systemName: "plus").frame(width: 24, height: 24) }
            .buttonStyle(.plain).help("Attach files").accessibilityLabel("Attach files").disabled(submitting)
        if let referenceFile {
            Button(action: referenceFile) { Image(systemName: "at").frame(width: 24, height: 24) }
                .buttonStyle(.plain).help("Reference a workspace file or folder").accessibilityLabel("Reference workspace file")
                .accessibilityIdentifier("composer-reference-file").disabled(submitting)
        }
    }
    @ViewBuilder private var permissionControl: some View {
        if let grokRuntimeMode {
            Menu {
                ForEach(GrokACPRuntimeMode.allCases) { mode in
                    Button { setGrokRuntimeMode(mode) } label: {
                        if mode == grokRuntimeMode { Label(mode.name, systemImage: "checkmark") } else { Text(mode.name) }
                    }
                }
            } label: { Label(grokRuntimeMode.name, systemImage: "slider.horizontal.3").font(.caption) }
                .menuStyle(.borderlessButton).fixedSize().disabled(historyLocked)
                .accessibilityIdentifier("grok-runtime-mode-menu")
                .help("Grok's native launch policy applies to future inputs. Active and queued inputs retain their captured policy.")
        } else if provider == .antigravity {
            Menu {
                ForEach(PermissionMode.allCases) { mode in
                    Button { setPermission(mode) } label: {
                        if mode == permission { Label(mode.antigravityTitle, systemImage: "checkmark") } else { Text(mode.antigravityTitle) }
                    }
                }
            } label: { Label(permission.antigravityTitle, systemImage: "slider.horizontal.3").font(.caption) }
                .menuStyle(.borderlessButton).fixedSize().disabled(historyLocked)
                .accessibilityIdentifier("antigravity-permission-menu")
                .help("Applies to future inputs. Antigravity verifies its native mode before sending; active and queued inputs keep their captured policy.")
        } else if provider == .muse {
            Menu {
                ForEach([PermissionMode.supervised, .fullAccess]) { mode in
                    Button { setPermission(mode) } label: {
                        if mode == permission { Label(mode.museTitle, systemImage: "checkmark") } else { Text(mode.museTitle) }
                    }
                }
            } label: { Label(permission.museTitle, systemImage: "slider.horizontal.3").font(.caption) }
                .menuStyle(.borderlessButton).fixedSize().disabled(historyLocked)
                .accessibilityIdentifier("muse-permission-menu")
                .help("Muse verifies the selected permission profile before sending. Active and queued inputs retain their captured policy.")
        } else if provider == .pi {
            Menu {
                ForEach([PermissionMode.supervised, .autoAcceptEdits, .fullAccess]) { mode in
                    Button { setPermission(mode) } label: {
                        if mode.piTitle == permission.piTitle { Label(mode.piTitle, systemImage: "checkmark") } else { Text(mode.piTitle) }
                    }
                }
            } label: { Label(permission.piTitle, systemImage: "slider.horizontal.3").font(.caption) }
                .menuStyle(.borderlessButton).fixedSize().disabled(historyLocked)
                .accessibilityIdentifier("pi-permission-menu")
                .help("Pi tool approvals apply to future inputs. Active and queued inputs keep their captured policy. This does not sandbox the process.")
        } else if provider == .acp {
            Label("Agent permissions", systemImage: "hand.raised").font(.caption).foregroundStyle(.secondary)
                .help("The agent enforces its own sandbox. Coincide shows the permission requests it sends.")
        } else {
            Menu {
                ForEach(PermissionMode.allCases) { mode in
                    Button { setPermission(mode) } label: {
                        if mode == permission { Label(mode.title, systemImage: "checkmark") } else { Text(mode.title) }
                    }
                }
            } label: { Label(permission.title, systemImage: "slider.horizontal.3").font(.caption) }
            .menuStyle(.borderlessButton).fixedSize()
            .disabled(historyLocked)
        }
    }
    private var newlineHint: some View {
        Text("⇧ Return for a new line").font(.caption2).foregroundStyle(.tertiary)
    }
    @ViewBuilder private var deliveryControls: some View {
        if busy {
            Menu {
                Button("Queue Message", action: send).disabled(!canSend)
                Button("Steer Current Turn") { steer?() }.disabled(!canSend || !canSteer)
                if let steeringExplanation { Text(steeringExplanation) }
            } label: { Image(systemName: "chevron.down") }
            .menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize()
            .accessibilityLabel("Message delivery").accessibilityIdentifier("composer-delivery")
            .help("Choose Queue or Steer. Command-Return uses the alternate delivery when steering is available.")
            Button(action: stop) { Image(systemName: "stop.fill").frame(width: 30, height: 30) }
                .buttonStyle(.plain).help("Stop turn").accessibilityLabel("Stop turn")
        }
        Button {
            activate(alternate: NSEvent.modifierFlags.contains(.command) || NSEvent.modifierFlags.contains(.control))
        } label: {
            Image(systemName: delivery == .steer ? "arrow.turn.up.right" : "arrow.up").font(.system(size: 14, weight: .semibold))
                .frame(width: 18, height: 18)
        }
        .coincidePrimaryAction().controlSize(.small).buttonBorderShape(.circle)
        .keyboardShortcut(.return, modifiers: .command)
        .accessibilityLabel(delivery.label)
        .accessibilityIdentifier("composer-send")
        .help(delivery == .steer ? "Send into the running turn using its current settings" : busy ? "Send after the current turn" : "Send message")
        .disabled(!canSend)
        .background { geometry("send") }
    }
    func activate(alternate: Bool) {
        guard canSend else { return }
        if ComposerDelivery.resolve(running: busy, preference: followUpBehavior, alternate: alternate, canSteer: canSteer) == .steer {
            steer?()
        } else { send() }
    }
    private func geometry(_ region: String) -> some View {
        GeometryReader { proxy in
            let frame = proxy.frame(in: .named("composer-layout"))
            Color.clear.onAppear { reportGeometry?(region, frame) }
                .onChange(of: frame) { _, value in reportGeometry?(region, value) }
        }
    }
}
