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
    var skills: ProviderSkillsStore? = nil
    @FocusState private var editorFocused: Bool
    @State private var dropTargeted = false
    @AppStorage("showSkillsInSlashMenu") private var showSkillsInSlashMenu = true
    @State private var selectedRange = NSRange(location: NSNotFound, length: 0)
    @State private var observedEditorText = ""
    @State private var selectionRequest: ComposerSelectionRequest?
    @State private var manualSkillAnchor: ComposerSkillMention?
    @State private var manualSkillQuery = ""
    @State private var dismissedSkillTrigger: ComposerSkillMention?
    @State private var highlightedSkillID: String?
    @State private var manualCommandAnchor: ComposerCommandMention?
    @State private var manualCommandQuery = ""
    @State private var dismissedCommandTrigger: ComposerCommandMention?
    @State private var highlightedCommandID: String?
    @State private var insertionError: String?
    private var canSend: Bool { !historyLocked && !submitting && (hasAttachments || !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty) }
    private var canSteer: Bool { steeringAvailable && steer != nil }
    private var delivery: ComposerDelivery {
        .resolve(running: busy, preference: followUpBehavior, alternate: false, canSteer: canSteer)
    }
    private var height: CGFloat { min(150, max(40, CGFloat(text.split(separator: "\n", omittingEmptySubsequences: false).count) * 21 + 14)) }
    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            if let skills, commandAnchor != nil {
                ProviderCommandPicker(model: skills, query: Binding(get: { commandQuery }, set: { manualCommandQuery = $0 }),
                    searchField: manualCommandAnchor != nil, selectedID: selectedCommand?.id,
                    choose: insertCommandSuggestion, move: moveCommandSelection, confirm: confirmCommand, dismiss: dismissCommands,
                    showSkills: $showSkillsInSlashMenu)
            } else if let skills, skillAnchor != nil {
                SkillPicker(model: skills, query: Binding(get: { skillQuery }, set: { manualSkillQuery = $0 }),
                            searchField: manualSkillAnchor != nil, selectedID: selectedSkill?.id,
                            choose: insertSkill, move: moveSkillSelection, confirm: confirmSkill, dismiss: dismissSkills,
                            showSkillsInSlashMenu: $showSkillsInSlashMenu)
            }
            if let insertionError {
                Text(insertionError).font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
            ZStack(alignment: .topLeading) {
                if text.isEmpty { Text("Message \(providerName ?? provider.name)…").foregroundStyle(.tertiary).padding(.horizontal, 5).padding(.top, 8).allowsHitTesting(false) }
                TextEditor(text: $text).font(.system(size: 15)).frame(height: height)
                    .accessibilityIdentifier("composer-input")
                    .focused($editorFocused)
                    .onAppear { editorFocused = true }
                    .scrollContentBackground(.hidden).accessibilityLabel("Message to \(providerName ?? provider.name)")
                    .background(ComposerSelectionBridge(request: selectionRequest, selectionChanged: observeSelection, keyDown: handleSkillKey))
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
        .task(id: skillReadKey) { if skillAnchor != nil || commandAnchor != nil { await skills?.refresh() } }
        .onChange(of: skills?.id) { _, _ in
            manualSkillAnchor = nil; dismissedSkillTrigger = nil; highlightedSkillID = nil
            manualCommandAnchor = nil; dismissedCommandTrigger = nil; highlightedCommandID = nil
        }
    }
    @ViewBuilder private var attachmentControls: some View {
        Button(action: attach) { Image(systemName: "plus").frame(width: 24, height: 24) }
            .buttonStyle(.plain).help("Attach files").accessibilityLabel("Attach files").disabled(submitting)
        if let referenceFile {
            Button(action: referenceFile) { Image(systemName: "at").frame(width: 24, height: 24) }
                .buttonStyle(.plain).help("Reference a workspace file or folder").accessibilityLabel("Reference workspace file")
                .accessibilityIdentifier("composer-reference-file").disabled(submitting)
        }
        if skills?.supportsSkills == true {
            Button(action: openSkills) { Image(systemName: "dollarsign").frame(width: 24, height: 24) }
                .buttonStyle(.plain).help("Choose a workspace skill, or type $ to search")
                .accessibilityLabel("Choose a skill").accessibilityIdentifier("composer-skills")
                .disabled(submitting || historyLocked || skills?.isClosed == true)
        }
        if skills?.supportsCommands == true {
            Button(action: openCommands) { Text("/").font(.system(.body, design: .monospaced)).frame(width: 24, height: 24) }
                .buttonStyle(.plain).help("Choose a provider command at the start of your message")
                .accessibilityLabel("Choose a command").accessibilityIdentifier("composer-commands")
                .disabled(submitting || historyLocked || skills?.isClosed == true)
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
        .accessibilityLabel(commandAnchor != nil ? String(localized: "Insert selected command or skill") : skillAnchor == nil ? delivery.label : String(localized: "Insert selected skill"))
        .accessibilityIdentifier("composer-send")
        .help(delivery == .steer ? "Send into the running turn using its current settings" : busy ? "Send after the current turn" : "Send message")
        .disabled(!canSend)
        .background { geometry("send") }
    }
    func activate(alternate: Bool) {
        if commandAnchor != nil { confirmCommand(); return }
        if skillAnchor != nil { confirmSkill(); return }
        guard canSend else { return }
        if ComposerDelivery.resolve(running: busy, preference: followUpBehavior, alternate: alternate, canSteer: canSteer) == .steer {
            steer?()
        } else { send() }
    }
    private var effectiveSelection: NSRange {
        if selectedRange.location == NSNotFound { return .init(location: text.utf16.count, length: 0) }
        return selectedRange
    }
    private var typedSkillTrigger: ComposerSkillMention? {
        guard skills?.supportsSkills == true else { return nil }
        return ComposerSkillMention.trigger(in: text, selection: effectiveSelection, showSlash: showSkillsInSlashMenu)
    }
    private var skillAnchor: ComposerSkillMention? {
        guard skills?.supportsSkills == true, skills?.isClosed == false, !historyLocked, !submitting, manualCommandAnchor == nil else { return nil }
        if let manualSkillAnchor { return manualSkillAnchor }
        let trigger = typedSkillTrigger
        return trigger == dismissedSkillTrigger ? nil : trigger
    }
    private var skillQuery: String { manualSkillAnchor == nil ? skillAnchor?.query ?? "" : manualSkillQuery }
    private var matchingSkills: [ProviderSkill] { SkillPicker.matching(skills?.skills ?? [], query: skillQuery) }
    private var selectedSkill: ProviderSkill? { matchingSkills.first(where: { $0.id == highlightedSkillID }) ?? matchingSkills.first }
    private var skillReadKey: String? {
        guard skillAnchor != nil || commandAnchor != nil, let skills else { return nil }
        return skills.id.uuidString
    }
    private var typedCommandTrigger: ComposerCommandMention? {
        ComposerCommandMention.trigger(in: text, selection: effectiveSelection)
    }
    private var commandAnchor: ComposerCommandMention? {
        guard skills?.supportsCommands == true, skills?.isClosed == false, !historyLocked, !submitting else { return nil }
        if let manualCommandAnchor { return manualCommandAnchor }
        guard manualSkillAnchor == nil, typedSkillTrigger == nil else { return nil }
        let trigger = typedCommandTrigger
        return trigger == dismissedCommandTrigger ? nil : trigger
    }
    private var commandQuery: String { manualCommandAnchor == nil ? commandAnchor?.query ?? "" : manualCommandQuery }
    private var matchingCommands: [ProviderComposerSuggestion] {
        ProviderCommandPicker.matching(commands: skills?.commands ?? [], skills: skills?.skills ?? [], query: commandQuery,
                                       showSkills: showSkillsInSlashMenu)
    }
    private var selectedCommand: ProviderComposerSuggestion? {
        matchingCommands.first(where: { $0.id == highlightedCommandID }) ?? matchingCommands.first
    }
    private func observeSelection(_ value: String, _ range: NSRange) {
        guard value != observedEditorText || selectedRange != range else { return }
        observedEditorText = value; selectedRange = range
    }
    private func openSkills() {
        manualCommandAnchor = nil; dismissedCommandTrigger = typedCommandTrigger; highlightedCommandID = nil
        insertionError = nil; manualSkillQuery = ""; highlightedSkillID = nil
        manualSkillAnchor = typedSkillTrigger ?? ComposerSkillMention.selection(in: text, range: effectiveSelection)
    }
    private func dismissSkills() {
        dismissedSkillTrigger = typedSkillTrigger; manualSkillAnchor = nil; highlightedSkillID = nil; editorFocused = true
    }
    private func moveSkillSelection(_ offset: Int) {
        let values = matchingSkills; guard !values.isEmpty else { return }
        let current = values.firstIndex { $0.id == selectedSkill?.id } ?? 0
        highlightedSkillID = values[(current + offset + values.count) % values.count].id
    }
    private func confirmSkill() {
        if let selectedSkill { insertSkill(selectedSkill) } else { dismissSkills() }
    }
    private func insertSkill(_ skill: ProviderSkill) {
        guard let anchor = skillAnchor, skills?.skills.contains(where: { $0.id == skill.id }) == true,
              let token = skill.promptToken,
              let replacement = anchor.inserting(token: token, into: text, selection: effectiveSelection) else {
            insertionError = String(localized: "The draft or selection changed. Choose the skill again."); dismissSkills(); return
        }
        text = replacement.text; selectedRange = replacement.selection; observedEditorText = replacement.text
        selectionRequest = .init(text: replacement.text, range: replacement.selection)
        manualSkillAnchor = nil; highlightedSkillID = nil; dismissedSkillTrigger = nil; insertionError = nil; editorFocused = true
    }
    private func openCommands() {
        manualSkillAnchor = nil; dismissedSkillTrigger = typedSkillTrigger; highlightedSkillID = nil
        manualCommandQuery = ""; highlightedCommandID = nil
        manualCommandAnchor = typedCommandTrigger ?? ComposerCommandMention.selection(in: text, range: effectiveSelection)
        insertionError = manualCommandAnchor == nil ? String(localized: "Provider commands start the message. Move the cursor to the beginning and choose the command again.") : nil
    }
    private func dismissCommands() {
        dismissedCommandTrigger = typedCommandTrigger; manualCommandAnchor = nil; highlightedCommandID = nil; editorFocused = true
    }
    private func moveCommandSelection(_ offset: Int) {
        let values = matchingCommands; guard !values.isEmpty else { return }
        let current = values.firstIndex { $0.id == selectedCommand?.id } ?? 0
        highlightedCommandID = values[(current + offset + values.count) % values.count].id
    }
    private func confirmCommand() {
        if let selectedCommand { insertCommandSuggestion(selectedCommand) } else { dismissCommands() }
    }
    private func insertCommandSuggestion(_ suggestion: ProviderComposerSuggestion) {
        guard let anchor = commandAnchor, matchingCommands.contains(suggestion) else { return }
        let replacement: (text: String, selection: NSRange)?
        switch suggestion {
        case .command(let command): replacement = anchor.inserting(command: command.name, into: text, selection: effectiveSelection)
        case .skill(let skill):
            replacement = skill.promptToken.flatMap { anchor.anchor.inserting(token: $0, into: text, selection: effectiveSelection) }
        }
        guard let replacement else {
            insertionError = String(localized: "The draft or selection changed. Choose the command or skill again."); dismissCommands(); return
        }
        text = replacement.text; selectedRange = replacement.selection; observedEditorText = replacement.text
        selectionRequest = .init(text: replacement.text, range: replacement.selection)
        manualCommandAnchor = nil; highlightedCommandID = nil; dismissedCommandTrigger = nil; insertionError = nil; editorFocused = true
    }
    private func handleSkillKey(_ event: NSEvent) -> Bool {
        let commands = commandAnchor != nil
        guard commands || skillAnchor != nil else { return false }
        switch event.keyCode {
        case 53: if commands { dismissCommands() } else { dismissSkills() }; return true
        case 125 where event.modifierFlags.intersection([.command, .control, .option, .shift]).isEmpty:
            if commands { moveCommandSelection(1) } else { moveSkillSelection(1) }; return true
        case 126 where event.modifierFlags.intersection([.command, .control, .option, .shift]).isEmpty:
            if commands { moveCommandSelection(-1) } else { moveSkillSelection(-1) }; return true
        case 48 where !event.modifierFlags.contains(.shift): if commands { confirmCommand() } else { confirmSkill() }; return true
        case 36, 76:
            guard event.modifierFlags.intersection([.shift, .option]).isEmpty else { return false }
            if commands { confirmCommand() } else { confirmSkill() }; return true
        default: return false
        }
    }
    private func geometry(_ region: String) -> some View {
        GeometryReader { proxy in
            let frame = proxy.frame(in: .named("composer-layout"))
            Color.clear.onAppear { reportGeometry?(region, frame) }
                .onChange(of: frame) { _, value in reportGeometry?(region, value) }
        }
    }
}
