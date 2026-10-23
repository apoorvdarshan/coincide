import AppKit
import CoincideCore
import SwiftUI

/// Inline unified diff for one changed file. Long diffs show the first 400
/// lines until the user asks for the rest.
struct TranscriptFileDiffView: View {
    let change: TranscriptFileChange
    var workspacePath: String?
    var openFile: (URL, Int?) -> Void = { _, _ in }
    var lineLimit = 400
    @State private var showAll = false
    @State private var collapsed = false

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 8) {
                Button { collapsed.toggle() } label: {
                    Image(systemName: "chevron.right").font(.caption2.weight(.semibold)).rotationEffect(.degrees(collapsed ? 0 : 90))
                }.buttonStyle(.plain).foregroundStyle(.tertiary)
                    .accessibilityLabel(collapsed ? String(localized: "Expand diff") : String(localized: "Collapse diff"))
                Button { openFile(TranscriptPaths.url(change.path, workspacePath: workspacePath), firstLine) } label: {
                    Text(displayPath).font(.caption.monospaced()).lineLimit(1).truncationMode(.middle)
                }.buttonStyle(.link).help(String(localized: "Open \(change.path)")).disabled(workspacePath == nil || change.kind == .deleted)
                if change.kind != .modified { Text(kindLabel).font(.caption2).foregroundStyle(.secondary).padding(.horizontal, 5).background(Color.primary.opacity(0.06), in: Capsule()) }
                Spacer(minLength: 4)
                if change.countsComplete { TranscriptDiffStatLabel(additions: change.additions, deletions: change.deletions) }
                else { Text("Partial preview").font(.caption2).foregroundStyle(.secondary) }
                Button {
                    NSPasteboard.general.clearContents(); NSPasteboard.general.setString(TranscriptDiffText.patch(change), forType: .string)
                } label: { Label("Copy Patch", systemImage: "doc.on.doc").labelStyle(.iconOnly) }
                .buttonStyle(.plain).foregroundStyle(.secondary)
                .help(TranscriptDiffText.canCopyPatch(change) ? String(localized: "Copy patch") : String(localized: "A complete patch with file line positions is unavailable for this preview."))
                .accessibilityLabel("Copy patch for \(displayPath)")
                .disabled(!TranscriptDiffText.canCopyPatch(change))
            }.padding(.horizontal, 10).padding(.vertical, 6).background(Color.primary.opacity(0.04))
            if !collapsed {
                Divider()
                if change.isBinary { Text("Binary file").font(.caption).foregroundStyle(.secondary).padding(10) }
                else if change.hunks.isEmpty {
                    Text(change.isTruncated || !change.countsComplete
                         ? String(localized: "Changes exceed the preview limit. The complete patch and line counts are unavailable here.")
                         : String(localized: "No line changes to show"))
                        .font(.caption).foregroundStyle(.secondary).padding(10)
                }
                else {
                    if change.isTruncated {
                        Text("This preview is incomplete. The complete patch is not available here.")
                            .font(.caption).foregroundStyle(.secondary).padding(8)
                    }
                    let lines = TranscriptDiffText.rows(change)
                    let visible = showAll ? lines : Array(lines.prefix(lineLimit))
                    VStack(alignment: .leading, spacing: 0) {
                        ForEach(Array(visible.enumerated()), id: \.offset) { _, row in line(row) }
                    }.textSelection(.enabled)
                    if lines.count > visible.count {
                        Button(String(localized: "Show \(lines.count - visible.count) more lines")) { showAll = true }
                            .buttonStyle(.link).font(.caption).padding(8)
                    }
                }
            }
        }
        .background(Color.primary.opacity(0.02), in: RoundedRectangle(cornerRadius: 8))
        .overlay { RoundedRectangle(cornerRadius: 8).strokeBorder(Color.primary.opacity(0.08)) }
        .clipShape(RoundedRectangle(cornerRadius: 8))
        .accessibilityElement(children: .contain)
        .accessibilityLabel(change.countsComplete
            ? String(localized: "\(kindLabel) \(displayPath), \(change.additions) added, \(change.deletions) removed")
            : String(localized: "\(kindLabel) \(displayPath), partial change preview"))
    }

    private var displayPath: String {
        let path = TranscriptToolPresentation.relative(change.path, to: workspacePath)
        guard let previous = change.previousPath else { return path }
        return TranscriptToolPresentation.relative(previous, to: workspacePath) + " → " + path
    }
    private var kindLabel: String {
        switch change.kind {
        case .added: String(localized: "Added")
        case .deleted: String(localized: "Deleted")
        case .renamed: String(localized: "Renamed")
        case .modified: String(localized: "Modified")
        }
    }
    private var firstLine: Int? { change.hunks.first?.lines.first(where: { $0.kind == .addition })?.newLine }

    @ViewBuilder private func line(_ row: TranscriptDiffText.Row) -> some View {
        switch row {
        case .header(let text):
            Text(text).font(.system(.caption2, design: .monospaced)).foregroundStyle(.secondary)
                .padding(.horizontal, 10).padding(.vertical, 3).frame(maxWidth: .infinity, alignment: .leading)
                .background(Color.accentColor.opacity(0.07))
        case .line(let line):
            HStack(alignment: .firstTextBaseline, spacing: 0) {
                if line.oldLine != nil || line.newLine != nil {
                    // A blank gutter keeps a text baseline; an empty Text has none.
                    Text(line.oldLine.map(String.init) ?? " ").frame(width: 34, alignment: .trailing)
                    Text(line.newLine.map(String.init) ?? " ").frame(width: 34, alignment: .trailing)
                }
                Text(sign(line.kind)).frame(width: 16, alignment: .center).accessibilityHidden(true)
                Text(line.text.isEmpty ? " " : line.text).fixedSize(horizontal: false, vertical: true).frame(maxWidth: .infinity, alignment: .leading)
                    .foregroundStyle(line.kind == .note ? AnyShapeStyle(.secondary) : AnyShapeStyle(.primary))
            }
            .font(.system(.caption, design: .monospaced)).foregroundStyle(.secondary)
            .padding(.trailing, 8).padding(.vertical, 0.5)
            .background(background(line.kind))
            .accessibilityElement(children: .combine)
            .accessibilityLabel(accessibility(line))
        }
    }
    private func sign(_ kind: TranscriptDiffLine.Kind) -> String {
        switch kind { case .addition: "+"; case .deletion: "−"; case .context: " "; case .note: "\\" }
    }
    private func background(_ kind: TranscriptDiffLine.Kind) -> Color {
        switch kind {
        case .addition: Color.green.opacity(0.13)
        case .deletion: Color.red.opacity(0.13)
        default: .clear
        }
    }
    private func accessibility(_ line: TranscriptDiffLine) -> String {
        switch line.kind {
        case .addition: String(localized: "Added: \(line.text)")
        case .deletion: String(localized: "Removed: \(line.text)")
        case .context: line.text
        case .note: line.text
        }
    }
}

enum TranscriptDiffText {
    enum Row { case header(String), line(TranscriptDiffLine) }
    static func canCopyPatch(_ change: TranscriptFileChange) -> Bool {
        !change.isBinary && !change.isTruncated && change.countsComplete && !change.hunks.isEmpty &&
        change.hunks.allSatisfy { $0.lines.allSatisfy { line in
            switch line.kind {
            case .addition: line.newLine != nil
            case .deletion: line.oldLine != nil
            case .context: line.oldLine != nil && line.newLine != nil
            case .note: true
            }
        } }
    }
    static func rows(_ change: TranscriptFileChange) -> [Row] {
        change.hunks.flatMap { [Row.header($0.header)] + $0.lines.map(Row.line) }
    }
    static func patch(_ change: TranscriptFileChange) -> String {
        var lines = ["--- " + (change.kind == .added ? "/dev/null" : "a/" + (change.previousPath ?? change.path)),
                     "+++ " + (change.kind == .deleted ? "/dev/null" : "b/" + change.path)]
        for hunk in change.hunks {
            lines.append(hunk.header)
            for line in hunk.lines {
                switch line.kind {
                case .addition: lines.append("+" + line.text)
                case .deletion: lines.append("-" + line.text)
                case .context: lines.append(" " + line.text)
                case .note: lines.append("\\ " + line.text)
                }
            }
        }
        return lines.joined(separator: "\n") + "\n"
    }
}

/// "3 files changed +12 −4" under a finished run. Checkpoint diffs load lazily
/// when the footer appears; runs without checkpoints summarize their edit cards.
struct TurnChangesFooter: View {
    let changes: TranscriptTurnChanges
    var workspacePath: String?
    var load: TranscriptChangesLoad?
    var fetch: () async -> Void = {}
    var viewChanges: (() -> Void)?
    var openFile: (URL, Int?) -> Void = { _, _ in }
    @State private var expanded = false

    var body: some View {
        let files = self.files
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                Image(systemName: "doc.badge.plus").foregroundStyle(.secondary).accessibilityHidden(true)
                if let files, !files.isEmpty {
                    Button { expanded.toggle() } label: {
                        HStack(spacing: 6) {
                            Text(files.count == 1 ? String(localized: "1 file changed") : String(localized: "\(files.count) files changed"))
                            if files.allSatisfy(\.countsComplete) {
                                let stat = TranscriptDiffStat(files)
                                TranscriptDiffStatLabel(additions: stat.additions, deletions: stat.deletions)
                            } else { Text("Partial preview").foregroundStyle(.tertiary) }
                            Image(systemName: "chevron.right").font(.caption2.weight(.semibold)).rotationEffect(.degrees(expanded ? 90 : 0)).accessibilityHidden(true)
                        }.contentShape(Rectangle())
                    }.buttonStyle(.plain)
                        .accessibilityValue(expanded ? String(localized: "Expanded") : String(localized: "Collapsed"))
                } else if load == .loading || (load == nil && changes.checkpointRevision != nil) {
                    ProgressView().controlSize(.mini); Text("Loading changes…")
                } else if files?.isEmpty == true {
                    Text("No file changes")
                } else {
                    Text("Changes unavailable")
                }
                if case .loaded(_, true)? = load { Text("Partial").foregroundStyle(.tertiary).help("The saved diff was larger than the preview limit.") }
                Spacer(minLength: 8)
                if let viewChanges {
                    Button("View Changes", action: viewChanges).buttonStyle(.link)
                        .accessibilityIdentifier("transcript-view-changes-\(changes.runID)")
                }
            }.font(.caption).foregroundStyle(.secondary)
            if expanded, let files {
                VStack(alignment: .leading, spacing: 3) {
                    ForEach(files) { file in
                        HStack(spacing: 8) {
                            Button { openFile(TranscriptPaths.url(file.path, workspacePath: workspacePath), nil) } label: {
                                Text(TranscriptToolPresentation.relative(file.path, to: workspacePath)).font(.caption.monospaced())
                                    .lineLimit(1).truncationMode(.middle)
                            }.buttonStyle(.link).disabled(file.kind == .deleted || workspacePath == nil)
                            Spacer(minLength: 8)
                            if file.countsComplete { TranscriptDiffStatLabel(additions: file.additions, deletions: file.deletions) }
                            else { Text("Partial preview").font(.caption2).foregroundStyle(.tertiary) }
                        }
                    }
                }.padding(.leading, 24)
            }
        }
        .padding(.horizontal, 12).padding(.vertical, 8)
        .background(Color.primary.opacity(0.03), in: RoundedRectangle(cornerRadius: 10))
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("transcript-changes-\(changes.runID)")
        .task(id: changes.checkpointRevision) { if changes.checkpointRevision != nil, load == nil { await fetch() } }
    }

    private var files: [TranscriptFileChange]? {
        if changes.checkpointRevision != nil {
            if case .loaded(let files, _)? = load { return files }
            return load == .unavailable && !changes.cardChanges.isEmpty ? changes.cardChanges : nil
        }
        return changes.cardChanges
    }
}
