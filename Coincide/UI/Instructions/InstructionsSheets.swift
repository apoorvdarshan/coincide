import AppKit
import CoincideKit
import SwiftUI

/// Reviews linking every agent's file to the master: each file's state, what to do with it, and its differences.
struct MasterPlanSheet: View {
    @Bindable var model: InstructionsModel
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Link Files to the Master").font(.title3.weight(.semibold))
            if let plan = model.plan {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Master: \(model.masterDisplayName)").font(.callout.weight(.medium))
                    if let seed = plan.seed {
                        Text("The master doesn't exist yet. It starts with the text of \(InstructionPaths.abbreviated(seed)).")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                }
                ScrollView {
                    VStack(alignment: .leading, spacing: 10) {
                        ForEach(plan.statuses) { status in
                            PlanRow(model: model, status: status, masterText: plan.masterText)
                        }
                    }
                }
                .frame(minHeight: 200, maxHeight: 420)
                Text("Coincide moves each file it replaces to a backup named like CLAUDE.md.coincide-backup-<date> beside it, and never deletes text. Links to other files are left alone unless you choose to replace them.")
                    .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
            HStack {
                Spacer()
                Button("Cancel") {
                    model.plan = nil
                    dismiss()
                }
                .keyboardShortcut(.cancelAction)
                Button("Link Files") { model.applyPlan() }
                    .keyboardShortcut(.defaultAction)
            }
        }
        .padding(20)
        .frame(width: 600)
        .background(Color(nsColor: Theme.contentBackground))
    }
}

private struct PlanRow: View {
    @Bindable var model: InstructionsModel
    let status: MasterTargetStatus
    let masterText: String
    @State private var showsDifferences = false

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                Image(systemName: icon).foregroundStyle(color).frame(width: 16)
                VStack(alignment: .leading, spacing: 1) {
                    HStack(spacing: 4) {
                        Text(status.target.displayName).font(.system(size: 13, weight: .medium)).lineLimit(1).truncationMode(.middle)
                        if let note = status.target.note { Text(verbatim: "(\(note))").font(.caption).foregroundStyle(.tertiary) }
                    }
                    Text(status.state.summary).font(.caption).foregroundStyle(.secondary)
                }
                Spacer(minLength: 8)
                AgentBadges(kinds: status.target.readers)
            }
            controls.padding(.leading, 24)
            if showsDifferences, case .differs(let text) = status.state {
                DiffView(lines: InstructionDiff.lines(from: masterText, to: text))
                    .frame(maxHeight: 180)
                    .padding(.leading, 24)
            }
        }
        .padding(10)
        .background(Color(nsColor: Theme.raisedFill), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
    }

    @ViewBuilder private var controls: some View {
        switch status.state {
        case .differs:
            HStack(spacing: 10) {
                ThemedPicker(
                    selection: choice,
                    options: [
                        .init(MasterChoice.merge, String(localized: "Merge into master")),
                        .init(MasterChoice.useMaster, String(localized: "Keep master only")),
                        .init(MasterChoice.skip, String(localized: "Skip this file")),
                    ]
                ) { EmptyView() }
                Button(showsDifferences ? "Hide Differences" : "Show Differences") { showsDifferences.toggle() }
                    .controlSize(.small)
            }
        case .identical, .missing:
            Toggle("Link this file", isOn: Binding(get: { choice.wrappedValue != .skip }, set: { choice.wrappedValue = $0 ? .useMaster : .skip }))
                .toggleStyle(ThemedCheckboxToggleStyle())
                .font(.caption)
        case .foreignLink, .brokenLink:
            Toggle("Replace this link", isOn: Binding(get: { choice.wrappedValue == .useMaster }, set: { choice.wrappedValue = $0 ? .useMaster : .skip }))
                .toggleStyle(ThemedCheckboxToggleStyle())
                .font(.caption)
        case .linked, .folderMissing, .unreadable:
            EmptyView()
        }
    }

    private var choice: Binding<MasterChoice> {
        Binding(get: { model.choices[status.id] ?? .skip }, set: { model.choices[status.id] = $0 })
    }

    private var icon: String {
        switch status.state {
        case .linked: "checkmark.circle"
        case .missing: "plus.circle"
        case .identical: "equal.circle"
        case .differs: "arrow.triangle.branch"
        case .foreignLink, .brokenLink: "link.badge.plus"
        case .folderMissing: "folder.badge.questionmark"
        case .unreadable: "exclamationmark.triangle"
        }
    }

    private var color: Color {
        switch status.state {
        case .differs, .foreignLink, .brokenLink, .unreadable: Color(nsColor: Theme.warning)
        default: .secondary
        }
    }
}

/// Lines of a comparison, added and removed ones tinted.
struct DiffView: View {
    let lines: [InstructionDiff.Line]

    var body: some View {
        ScrollView([.vertical, .horizontal]) {
            VStack(alignment: .leading, spacing: 0) {
                ForEach(Array(lines.enumerated()), id: \.offset) { _, line in
                    row(line)
                }
            }
            .padding(6)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .background(Color(nsColor: Theme.contentBackground), in: RoundedRectangle(cornerRadius: 6))
        .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(Color(nsColor: Theme.surfaceBorder)))
    }

    private func row(_ line: InstructionDiff.Line) -> some View {
        let (marker, text, fill): (String, String, NSColor?) = switch line {
        case .same(let text): (" ", text, nil)
        case .removed(let text): ("−", text, Theme.deletion)
        case .added(let text): ("+", text, Theme.addition)
        }
        return Text(verbatim: "\(marker) \(text)")
            .font(.system(size: 11, design: .monospaced))
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(fill.map { Color(nsColor: $0) })
    }
}

/// Shows how two drifted files differ. Coincide doesn't merge them on its own.
struct ComparisonSheet: View {
    let model: InstructionsModel
    let divergence: InstructionDivergence
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        let first = (try? InstructionFileStore.read(divergence.first).text) ?? ""
        let second = (try? InstructionFileStore.read(divergence.second).text) ?? ""
        VStack(alignment: .leading, spacing: 12) {
            Text("Compare \(divergence.first.lastPathComponent) and \(divergence.second.lastPathComponent)")
                .font(.title3.weight(.semibold))
            Text("Lines marked − are only in \(divergence.second.lastPathComponent); lines marked + are only in \(divergence.first.lastPathComponent). Coincide won't merge them for you: copy what you need into one file, or turn on one file for all agents to merge them with backups.")
                .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            DiffView(lines: InstructionDiff.lines(from: second, to: first)).frame(minHeight: 260, maxHeight: 460)
            HStack {
                Button("Edit \(divergence.first.lastPathComponent)") { open(divergence.first) }
                Button("Edit \(divergence.second.lastPathComponent)") { open(divergence.second) }
                Spacer()
                Button("Done") {
                    model.comparison = nil
                    dismiss()
                }
                .keyboardShortcut(.defaultAction)
            }
        }
        .padding(20)
        .frame(width: 640)
        .background(Color(nsColor: Theme.contentBackground))
    }

    private func open(_ url: URL) {
        model.comparison = nil
        dismiss()
        InstructionsSelection.select(url.path, in: model)
    }
}

/// Turns on and off the master's copies in iCloud Drive and in a Git repository. The master itself never moves; each
/// copy is kept in step with it.
struct SyncSheet: View {
    @Bindable var model: InstructionsModel
    @Environment(\.dismiss) private var dismiss
    @State private var repositoryName = InstructionGitRepository.defaultGitHubName
    @State private var creatingRepository = false

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Sync the Master File").font(.title3.weight(.semibold))
            Label {
                Text("Synced instructions leave this Mac, so keep keys, tokens and passwords out of them.")
                    .font(.caption).fixedSize(horizontal: false, vertical: true)
            } icon: {
                Image(systemName: "lock.shield").foregroundStyle(Color(nsColor: Theme.warning))
            }
            Text("The master stays at \(model.masterDisplayName). Each place you turn on below keeps a copy in step with it: changes made here go there, and changes made there, on your other Macs, come back here.")
                .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            section { iCloud }
            section { git }
            HStack {
                if model.isSyncing || model.syncer.isRunning { ProgressView().controlSize(.small) }
                Spacer()
                Button("Done") { dismiss() }.keyboardShortcut(.defaultAction)
            }
        }
        .padding(20)
        .frame(width: 540)
        .background(Color(nsColor: Theme.contentBackground))
    }

    private func section(@ViewBuilder _ content: () -> some View) -> some View {
        VStack(alignment: .leading, spacing: 8) { content() }
            .padding(10)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Color(nsColor: Theme.raisedFill), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous).strokeBorder(Color(nsColor: Theme.surfaceBorder)))
    }

    @ViewBuilder private var iCloud: some View {
        Toggle(isOn: Binding(get: { model.config.iCloud != nil }, set: { $0 ? model.turnOnICloud() : model.turnOffICloud() })) {
            Label("iCloud Drive", systemImage: "icloud").font(.callout.weight(.medium))
        }
        Text("Keeps a copy at iCloud Drive › Coincide › Instructions › \(InstructionCloud.safeName(model.syncName)).md, so Coincide on your other Macs uses the same instructions. Turning it off leaves the copy there.")
            .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
        if model.config.iCloud != nil {
            CopyStatusView(model: model, copy: .iCloud, place: String(localized: "iCloud Drive"))
        }
    }

    @ViewBuilder private var git: some View {
        if let gitCopy = model.config.git {
            HStack {
                Label(model.repositoryTitle ?? "", systemImage: "arrow.triangle.branch").font(.callout.weight(.medium))
                Spacer()
                Button("Unlink") { model.unlinkRepository() }
            }
            Text("Keeps a copy as \(gitCopy.url.lastPathComponent) in \(InstructionPaths.abbreviated(gitCopy.repositoryURL)) and commits it when the instructions change. Coincide never force-pushes and never pushes other files. Unlinking leaves the repository as it is.")
                .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            Toggle("Push changes right away", isOn: Binding(get: { gitCopy.pushesAutomatically }, set: { model.setPushesAutomatically($0) }))
                .font(.caption)
            CopyStatusView(model: model, copy: .git, place: model.repositoryTitle ?? "")
        } else {
            Label("GitHub or Git Repository", systemImage: "arrow.triangle.branch").font(.callout.weight(.medium))
            Text("Keeps a copy as \(InstructionCloud.safeName(model.syncName)).md in a repository, commits it when the instructions change and pushes it. Coincide never force-pushes and never pushes other files.")
                .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            HStack {
                Button("Choose Git Repository…") { chooseRepository() }
                Button("Create Private GitHub Repository…") { creatingRepository = true }
            }
            .disabled(model.isSyncing)
            if creatingRepository {
                HStack {
                    TextField("Repository name", text: $repositoryName).frame(width: 220)
                    Button("Create") { model.createGitHubRepository(named: repositoryName) }
                        .disabled(repositoryName.trimmingCharacters(in: .whitespaces).isEmpty || model.isSyncing)
                }
                Text("Coincide will run: gh repo create \(repositoryName) --private")
                    .font(.system(size: 11, design: .monospaced)).foregroundStyle(.secondary).textSelection(.enabled)
            }
        }
    }

    private func chooseRepository() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        panel.message = String(localized: "Choose the folder of a Git repository for your instructions.")
        guard panel.runModal() == .OK, let url = panel.url else { return }
        model.linkRepository(url)
    }
}

/// How a copy stands, and when it and the master both changed, the choice of which to keep.
private struct CopyStatusView: View {
    let model: InstructionsModel
    let copy: InstructionCopySyncer.Key.Copy
    /// The copy's place, as the user knows it: "iCloud Drive" or the repository.
    let place: String
    @State private var comparing = false

    var body: some View {
        let status = model.syncer.status(model.scope, copy)
        switch status {
        case .inStep:
            Label("In step with the master", systemImage: "checkmark.circle").font(.caption).foregroundStyle(.secondary)
        case .conflict:
            VStack(alignment: .leading, spacing: 6) {
                Label {
                    Text("The master and the copy in \(place) both changed. Choose which to keep; the other is backed up.")
                        .font(.caption).fixedSize(horizontal: false, vertical: true)
                } icon: {
                    Image(systemName: "exclamationmark.triangle").foregroundStyle(Color(nsColor: Theme.warning))
                }
                HStack {
                    Button("Keep This Mac's") { model.resolve(copy, keeping: .master) }
                    Button("Keep the Copy") { model.resolve(copy, keeping: .copy) }
                    Button(comparing ? "Hide Differences" : "Show Differences") { comparing.toggle() }
                }
                if comparing {
                    let texts = model.conflictTexts(copy)
                    Text("Lines marked − are only in the copy; lines marked + are only in the master.")
                        .font(.caption).foregroundStyle(.secondary)
                    DiffView(lines: InstructionDiff.lines(from: texts.copy, to: texts.master)).frame(minHeight: 160, maxHeight: 260)
                }
            }
        case nil:
            Label("Syncing…", systemImage: "arrow.triangle.2.circlepath").font(.caption).foregroundStyle(.secondary)
        case .some(let other):
            Label {
                Text(verbatim: other.problem ?? "").font(.caption).fixedSize(horizontal: false, vertical: true)
            } icon: {
                Image(systemName: "exclamationmark.triangle").foregroundStyle(Color(nsColor: Theme.warning))
            }
        }
    }
}
