import AppKit
import CoincideKit
import SwiftUI

extension View {
    /// The settings window's themed controls, for views and sheets shown outside it.
    func instructionsTheme() -> some View {
        toggleStyle(ThemedSwitchToggleStyle())
            .buttonStyle(ThemedButtonStyle())
            .textFieldStyle(ThemedTextFieldStyle())
            .tint(Color(nsColor: Theme.ink))
    }
}

/// The agents' names as a list: "Claude Code, Codex and Grok Build".
func agentNames(_ kinds: [ProviderKind]) -> String {
    ListFormatter.localizedString(byJoining: kinds.map(\.displayName))
}

/// The instruction files of a project or of the global configuration: a list on the left, the open file on the right.
struct InstructionsView: View {
    @Bindable var model: InstructionsModel

    var body: some View {
        HStack(spacing: 0) {
            InstructionsSidebar(model: model)
                .frame(width: 270)
                .background(Color(nsColor: Theme.sidebarBackground))
            Rectangle().fill(Color(nsColor: Theme.surfaceBorder)).frame(width: 1)
            InstructionsDetail(model: model)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background(Color(nsColor: Theme.contentBackground))
        }
        .instructionsTheme()
        .task { await model.reload() }
        .task {
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(2))
                model.checkDisk()
            }
        }
        .sheet(isPresented: Binding(get: { model.plan != nil }, set: { if !$0 { model.plan = nil } })) {
            MasterPlanSheet(model: model).instructionsTheme()
        }
        .sheet(isPresented: Binding(get: { model.comparison != nil }, set: { if !$0 { model.comparison = nil } })) {
            if let comparison = model.comparison { ComparisonSheet(model: model, divergence: comparison).instructionsTheme() }
        }
        .sheet(isPresented: $model.showingSync) {
            SyncSheet(model: model).instructionsTheme()
        }
        .onChange(of: model.syncer.revision) {
            // A sync brought a change from a copy into the master, or moved an older setup's master back.
            model.checkDisk()
            Task { await model.reload() }
        }
    }
}

// MARK: Sidebar

private struct InstructionsSidebar: View {
    @Bindable var model: InstructionsModel

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                MasterCard(model: model)
                ForEach(model.divergences, id: \.self) { divergence in
                    DivergenceCard(model: model, divergence: divergence)
                }
                if model.isMasterMode {
                    MasterRow(model: model)
                }
                let files = model.listedFiles
                if !files.isEmpty {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(model.isMasterMode ? "Other Files" : "Files")
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(.secondary)
                            .padding(.horizontal, 8)
                            .padding(.bottom, 2)
                        ForEach(files) { file in
                            FileRow(model: model, file: file)
                        }
                    }
                } else if model.isLoading {
                    ProgressView().controlSize(.small).frame(maxWidth: .infinity)
                }
                Helpers(model: model)
            }
            .padding(12)
        }
    }
}

/// "Use one file for all agents", the master's link health and sync.
private struct MasterCard: View {
    @Bindable var model: InstructionsModel

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Toggle(isOn: Binding(get: { model.isMasterMode }, set: { $0 ? model.reviewLinks() : confirmDisable() })) {
                Text("Use one file for all agents").font(.system(size: 13, weight: .medium))
            }
            if model.isMasterMode {
                health
                SyncSummary(model: model)
            } else {
                Text(explanation).font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                HStack(spacing: 6) {
                    Text("Master: \(model.masterDisplayName)").font(.caption).lineLimit(1).truncationMode(.middle)
                    Spacer(minLength: 4)
                    Button("Change…") { chooseMaster() }.controlSize(.small)
                }
            }
        }
        .padding(10)
        .background(Color(nsColor: Theme.raisedFill), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous).strokeBorder(Color(nsColor: Theme.surfaceBorder)))
    }

    private var explanation: String {
        if model.projectRoot != nil {
            return String(localized: "Links CLAUDE.md, GEMINI.md and the other agents' files to one master file. Files that differ are backed up first.")
        }
        return String(localized: "Links each agent's global file to one master. The default, ~/.config/coincide/AGENTS.md, belongs to no agent, so removing one keeps it. Files that differ are backed up first.")
    }

    @ViewBuilder private var health: some View {
        let problems = model.unhealthyTargets
        if problems.isEmpty {
            Label("All links are healthy", systemImage: "checkmark.circle").font(.caption).foregroundStyle(.secondary)
        } else {
            VStack(alignment: .leading, spacing: 4) {
                ForEach(problems) { status in
                    Label {
                        Text(verbatim: "\(status.target.displayName): \(status.state.summary)").font(.caption).lineLimit(2)
                    } icon: {
                        Image(systemName: "exclamationmark.triangle").foregroundStyle(Color(nsColor: Theme.warning))
                    }
                }
                Button("Fix Links…") { model.reviewLinks() }.controlSize(.small)
            }
        }
    }

    private func confirmDisable() {
        let alert = ThemedAlert()
        alert.messageText = String(localized: "Turn off one file for all agents?")
        alert.informativeText = String(localized: "Coincide can replace each link with a copy of the master, so every agent keeps its instructions, or leave the links as they are.")
        alert.addButton(withTitle: String(localized: "Replace Links with Copies"))
        alert.addButton(withTitle: String(localized: "Leave Links"))
        alert.addButton(withTitle: String(localized: "Cancel"))
        switch alert.runModal() {
        case .alertFirstButtonReturn: model.disableMasterMode(replaceWithCopies: true)
        case .alertSecondButtonReturn: model.disableMasterMode(replaceWithCopies: false)
        default: break
        }
    }

    private func chooseMaster() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        panel.directoryURL = model.masterURL.deletingLastPathComponent()
        panel.message = String(localized: "Choose the file every agent should read.")
        guard panel.runModal() == .OK, let url = panel.url else { return }
        model.setMasterPath(url)
    }
}

/// Where the master is synced to: a row for each copy with how it stands, or "Sync: Off".
struct SyncSummary: View {
    let model: InstructionsModel

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            if model.config.iCloud == nil, model.config.git == nil {
                HStack(spacing: 6) {
                    Text("Sync: Off").font(.caption).foregroundStyle(.secondary)
                    Spacer(minLength: 4)
                    Button("Sync…") { model.showingSync = true }
                }
            } else {
                Text("Synced to").font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                if model.config.iCloud != nil {
                    SyncRow(title: String(localized: "iCloud Drive"), systemImage: "icloud", status: model.iCloudStatus)
                }
                if let repository = model.repositoryTitle {
                    SyncRow(title: repository, systemImage: "arrow.triangle.branch", status: model.gitStatus)
                }
                HStack(spacing: 6) {
                    Spacer(minLength: 4)
                    Button("Sync Now") { model.syncNow() }.disabled(model.syncer.isRunning)
                    Button("Sync…") { model.showingSync = true }
                }
            }
        }
        .controlSize(.small)
    }
}

/// One place the master is synced to, with a check when it is in step and the problem when it isn't.
struct SyncRow: View {
    let title: String
    let systemImage: String
    let status: InstructionCopySyncer.Status?

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack(spacing: 6) {
                Image(systemName: systemImage).frame(width: 14).foregroundStyle(.secondary)
                Text(verbatim: title).lineLimit(1).truncationMode(.middle)
                Spacer(minLength: 4)
                switch status {
                case .inStep: Image(systemName: "checkmark.circle").foregroundStyle(.secondary).help(String(localized: "In step with the master"))
                case nil: ProgressView().controlSize(.mini)
                default: Image(systemName: "exclamationmark.triangle").foregroundStyle(Color(nsColor: Theme.warning))
                }
            }
            .font(.caption)
            if let problem = status?.problem {
                Text(verbatim: problem).font(.caption).foregroundStyle(.secondary).lineLimit(3).padding(.leading, 20)
            }
        }
    }
}

extension InstructionCopySyncer.Status {
    /// What is wrong, for a copy that isn't in step.
    var problem: String? {
        switch self {
        case .inStep: nil
        case .conflict: String(localized: "This copy and the master both changed. Open Sync… to choose which to keep.")
        case .downloading: String(localized: "Waiting for iCloud Drive to download the copy.")
        case .failed(let message): message
        }
    }
}

extension InstructionsModel {
    var masterDisplayName: String {
        if let root = projectRoot { return InstructionDiscovery.relative(masterURL, to: root) }
        return InstructionPaths.abbreviated(masterURL)
    }
}

extension InstructionFile {
    /// Where the path links to, with the home folder shown as `~`.
    var linkTarget: String? {
        guard let destination = link?.destination else { return nil }
        return destination.hasPrefix("/") ? InstructionPaths.abbreviated(URL(fileURLWithPath: destination)) : destination
    }
}

extension MasterTargetState {
    var summary: String {
        switch self {
        case .linked: String(localized: "Linked")
        case .missing: String(localized: "Not linked yet")
        case .identical: String(localized: "Separate copy with the same text")
        case .differs: String(localized: "Separate file with different text")
        case .foreignLink(let destination): String(localized: "Links to \(destination) instead")
        case .brokenLink(let destination): String(localized: "Broken link to \(destination)")
        case .folderMissing: String(localized: "Folder missing; the agent isn't set up")
        case .unreadable: String(localized: "Can't be read")
        }
    }
}

/// The master in master mode, with the files that link to it beneath.
private struct MasterRow: View {
    let model: InstructionsModel

    var body: some View {
        let id = model.masterURL.path
        let selected = model.selectedID == id
        Button {
            InstructionsSelection.select(id, in: model)
        } label: {
            VStack(alignment: .leading, spacing: 5) {
                HStack(spacing: 6) {
                    Image(systemName: "star.square").foregroundStyle(Color(nsColor: Theme.accent))
                    Text(model.masterDisplayName).font(.system(size: 13, weight: .semibold)).lineLimit(1).truncationMode(.middle)
                }
                AgentBadges(kinds: model.masterReaders)
                if !model.masterReaders.isEmpty {
                    Text("Used by: \(agentNames(model.masterReaders))").font(.caption).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                ForEach(model.linkedTargets) { status in
                    HStack(spacing: 4) {
                        Image(systemName: "arrow.turn.down.right").font(.caption2)
                        Text(status.target.displayName).lineLimit(1).truncationMode(.middle)
                        if let note = status.target.note { Text(verbatim: "(\(note))").foregroundStyle(.tertiary) }
                    }
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .padding(.leading, 6)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(8)
            .background(
                RoundedRectangle(cornerRadius: 7, style: .continuous)
                    .fill(Color(nsColor: selected ? Theme.sidebarSelection : .clear)))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .pointerCursor()
        .accessibilityAddTraits(selected ? .isSelected : [])
    }
}

private struct FileRow: View {
    let model: InstructionsModel
    let file: InstructionFile

    var body: some View {
        let selected = model.selectedID == file.id
        let readers = model.usedBy(file)
        Button {
            InstructionsSelection.select(file.id, in: model)
        } label: {
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 6) {
                    Image(systemName: file.link == nil ? "doc.text" : "link")
                        .foregroundStyle(.secondary)
                        .frame(width: 14)
                    Text(file.displayName)
                        .font(.system(size: 13, weight: .medium))
                        .foregroundStyle(Color(nsColor: Theme.ink))
                        .lineLimit(1)
                        .truncationMode(.middle)
                    Spacer(minLength: 4)
                    if file.link?.isBroken == true {
                        Tag(text: String(localized: "Broken link"), warning: true)
                    } else if !file.exists {
                        Tag(text: String(localized: "New"), warning: false)
                    }
                }
                if let destination = file.linkTarget {
                    Text(verbatim: "→ \(destination)")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                        .padding(.leading, 20)
                }
                HStack(spacing: 6) {
                    AgentBadges(kinds: readers)
                    if let note = file.note { Text(note).font(.caption).foregroundStyle(.tertiary).lineLimit(1) }
                }
                .padding(.leading, 20)
                Text("Used by: \(agentNames(readers))")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.leading, 20)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(8)
            .background(
                RoundedRectangle(cornerRadius: 7, style: .continuous)
                    .fill(Color(nsColor: selected ? Theme.sidebarSelection : .clear)))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .pointerCursor()
        .accessibilityAddTraits(selected ? .isSelected : [])
    }
}

/// The agents' logos, small.
struct AgentBadges: View {
    let kinds: [ProviderKind]

    var body: some View {
        HStack(spacing: 3) {
            ForEach(kinds, id: \.self) { kind in
                SettingsProviderIcon(kind: kind, size: 16).help(kind.displayName)
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(agentNames(kinds))
    }
}

private struct Tag: View {
    let text: String
    let warning: Bool

    var body: some View {
        Text(text)
            .font(.caption2.weight(.medium))
            .foregroundStyle(warning ? Color(nsColor: Theme.warning) : .secondary)
            .padding(.horizontal, 5)
            .padding(.vertical, 1)
            .background(Capsule().fill(Color(nsColor: Theme.raisedFill)))
            .overlay(Capsule().strokeBorder(Color(nsColor: Theme.surfaceBorder)))
    }
}

private struct DivergenceCard: View {
    let model: InstructionsModel
    let divergence: InstructionDivergence

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Label {
                Text("\(divergence.first.lastPathComponent) and \(divergence.second.lastPathComponent) are separate files with different text.")
                    .font(.caption)
                    .fixedSize(horizontal: false, vertical: true)
            } icon: {
                Image(systemName: "arrow.triangle.branch").foregroundStyle(Color(nsColor: Theme.warning))
            }
            Button("Compare…") { model.comparison = divergence }.controlSize(.small)
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color(nsColor: Theme.raisedFill), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
    }
}

/// Create AGENTS.md and the link helpers.
private struct Helpers: View {
    let model: InstructionsModel

    var body: some View {
        if model.projectRoot != nil {
            VStack(alignment: .leading, spacing: 6) {
                if model.canCreateAgentsFile {
                    Button("Create AGENTS.md") { model.createAgentsFile() }
                }
                if model.canLink("CLAUDE.md") {
                    Button("Link CLAUDE.md to AGENTS.md") { model.link("CLAUDE.md") }
                        .help(Text("Creates CLAUDE.md as a link to AGENTS.md, so Claude Code reads the same instructions."))
                }
                if model.canLink("GEMINI.md") {
                    Button("Link GEMINI.md to AGENTS.md") { model.link("GEMINI.md") }
                        .help(Text("Optional: Antigravity already reads AGENTS.md."))
                }
            }
            .controlSize(.small)
        }
    }
}

/// Switching files asks about unsaved edits first.
enum InstructionsSelection {
    static func select(_ id: String, in model: InstructionsModel) {
        guard id != model.selectedID else { return }
        guard model.isDirty, let current = model.selected else {
            model.select(id)
            return
        }
        let alert = ThemedAlert()
        alert.messageText = String(localized: "Save changes to \(current.displayName)?")
        alert.informativeText = String(localized: "Your changes are lost if you don't save them.")
        alert.addButton(withTitle: String(localized: "Save"))
        alert.addButton(withTitle: String(localized: "Don't Save"))
        alert.addButton(withTitle: String(localized: "Cancel"))
        switch alert.runModal() {
        case .alertFirstButtonReturn:
            model.save()
            if !model.isDirty { model.select(id) }
        case .alertSecondButtonReturn:
            model.select(id)
        default:
            break
        }
    }
}

// MARK: Detail

private struct InstructionsDetail: View {
    @Bindable var model: InstructionsModel

    var body: some View {
        if let file = model.selected {
            VStack(spacing: 0) {
                header(file)
                Rectangle().fill(Color(nsColor: Theme.surfaceBorder)).frame(height: 1)
                if model.changedOnDisk { changedBanner }
                if let notice = model.notice { NoticeBanner(notice: notice) { model.notice = nil } }
                InstructionsEditor(text: $model.text)
            }
        } else {
            VStack(spacing: 8) {
                Image(systemName: "doc.text").font(.system(size: 28)).foregroundStyle(.tertiary)
                Text(model.isLoading ? "Looking for instruction files…" : "No instruction files yet")
                    .foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    private func header(_ file: InstructionFile) -> some View {
        HStack(alignment: .center, spacing: 8) {
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(file.displayName).font(.headline).lineLimit(1).truncationMode(.middle)
                        .layoutPriority(1)
                    if model.isDirty {
                        Circle().fill(Color(nsColor: Theme.ink)).frame(width: 6, height: 6)
                            .accessibilityLabel(Text("Edited"))
                    }
                }
                Text(file.link == nil ? InstructionPaths.abbreviated(file.resolvedURL) : "→ \(InstructionPaths.abbreviated(file.resolvedURL))")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .textSelection(.enabled)
            }
            Spacer(minLength: 8)
            Button {
                model.reveal(file)
            } label: {
                Image(systemName: "folder")
            }
            .help(Text("Reveal in Finder"))
            .accessibilityLabel(Text("Reveal in Finder"))
            Button {
                model.openInEditor(file)
            } label: {
                Image(systemName: "arrow.up.forward.app")
            }
            .help(Text("Open in Editor"))
            .accessibilityLabel(Text("Open in Editor"))
            .disabled(!file.exists)
            Button("Revert") { model.revert() }
                .fixedSize()
                .disabled(!model.isDirty)
            Button("Save") { model.save() }
                .fixedSize()
                .keyboardShortcut("s", modifiers: .command)
                .disabled(!model.isDirty && file.exists)
        }
        .fixedSize(horizontal: false, vertical: true)
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
    }

    private var changedBanner: some View {
        let dirty = model.isDirty
        return NoticeBanner(
            notice: InstructionsNotice(
                kind: .warning,
                text: dirty
                    ? String(localized: "This file changed on disk, and you have unsaved edits.")
                    : String(localized: "This file changed on disk.")),
            dismiss: nil
        ) {
            Button(dirty ? "Reload and Discard Mine" : "Reload") { model.revert() }
            if dirty {
                Button("Keep Mine") { model.saveOverExternalChanges() }
            }
        }
    }
}

struct NoticeBanner<Actions: View>: View {
    let notice: InstructionsNotice
    var dismiss: (() -> Void)?
    @ViewBuilder var actions: Actions

    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: icon).foregroundStyle(color)
            Text(notice.text).font(.callout).textSelection(.enabled).fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 8)
            actions.controlSize(.small)
            if let dismiss {
                Button {
                    dismiss()
                } label: {
                    Image(systemName: "xmark")
                }
                .buttonStyle(.plain)
                .pointerCursor()
                .foregroundStyle(.secondary)
                .accessibilityLabel(Text("Dismiss"))
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
        .background(Color(nsColor: Theme.raisedFill))
        .overlay(alignment: .bottom) { Rectangle().fill(Color(nsColor: Theme.surfaceBorder)).frame(height: 1) }
    }

    private var icon: String {
        switch notice.kind {
        case .info: "info.circle"
        case .warning: "exclamationmark.triangle"
        case .error: "xmark.octagon"
        }
    }

    private var color: Color {
        switch notice.kind {
        case .info: .secondary
        case .warning: Color(nsColor: Theme.warning)
        case .error: Color(nsColor: Theme.failure)
        }
    }
}

extension NoticeBanner where Actions == EmptyView {
    init(notice: InstructionsNotice, dismiss: (() -> Void)?) {
        self.init(notice: notice, dismiss: dismiss) { EmptyView() }
    }
}
