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

/// Chooses how the master syncs between Macs: off, iCloud Drive, or a Git repository.
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
            Text("Sync: \(model.syncDescription)").font(.callout.weight(.medium))
            switch model.config.sync {
            case .off: options
            case .iCloud: iCloudOn
            case .git(_, let pushOnSave): gitOn(pushOnSave: pushOnSave)
            }
            if model.isSyncing { ProgressView().controlSize(.small) }
            HStack {
                Spacer()
                Button("Done") { dismiss() }.keyboardShortcut(.defaultAction)
            }
        }
        .padding(20)
        .frame(width: 520)
        .background(Color(nsColor: Theme.contentBackground))
    }

    @ViewBuilder private var options: some View {
        VStack(alignment: .leading, spacing: 6) {
            Button("Use iCloud Drive") { model.startICloudSync() }
            Text("Moves the master to iCloud Drive › Coincide › Instructions › \(InstructionCloud.safeName(model.syncName)).md and links every agent to it, so Coincide on your other Macs can use the same file. A backup of the current file stays here.")
                .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
        }
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Button("Choose Git Repository…") { chooseRepository() }
                Button("Create Private GitHub Repository…") { creatingRepository = true }
            }
            .disabled(model.isSyncing)
            Text("The master moves into the repository's folder. Coincide commits it when you save, pulls and pushes when you ask, never force-pushes, and never pushes other files.")
                .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
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

    @ViewBuilder private var iCloudOn: some View {
        Text("The master is \(InstructionPaths.abbreviated(model.masterURL)).").font(.caption).foregroundStyle(.secondary)
        Button("Turn Off Sync") { model.stopSync() }
        Text("Copies the master back to this Mac and links the agents to the copy. The file in iCloud Drive stays.")
            .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
    }

    @ViewBuilder private func gitOn(pushOnSave: Bool) -> some View {
        Toggle("Push when you save", isOn: Binding(get: { pushOnSave }, set: { model.setPushOnSave($0) }))
        HStack {
            Button("Sync Now") { model.syncNow() }.disabled(model.isSyncing)
            Button("Turn Off Sync") { model.stopSync() }
        }
        Text("Turning sync off copies the master back to this Mac and links the agents to the copy. The repository stays as it is.")
            .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
    }

    private func chooseRepository() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        panel.message = String(localized: "Choose the folder of a Git repository for your instructions.")
        guard panel.runModal() == .OK, let url = panel.url else { return }
        model.startGitSync(repository: url)
    }
}
