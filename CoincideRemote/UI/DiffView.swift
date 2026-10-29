import CoincideRemoteKit
import SwiftUI

/// A turn's changes, or a thread's uncommitted ones, file by file.
struct DiffView: View {
    let request: Navigator.DiffRequest
    @Environment(RemoteClient.self) private var client
    @Environment(\.dismiss) private var dismiss
    @Environment(\.theme) private var theme
    @State private var diff: RemoteDiff?
    @State private var error: String?

    var body: some View {
        NavigationStack {
            Group {
                if let diff {
                    if diff.files.isEmpty {
                        ContentUnavailableView("No Changes", systemImage: "checkmark.circle")
                    } else {
                        List {
                            if diff.isTruncated {
                                Text("Some changes are too large to show here. They’re all on the Mac.")
                                    .font(.footnote).foregroundStyle(theme.secondaryInk)
                            }
                            ForEach(diff.files) { file in
                                NavigationLink {
                                    FileDiffView(file: file)
                                } label: {
                                    FileRow(file: file)
                                }
                            }
                        }
                        .scrollContentBackground(.hidden)
                    }
                } else if let error {
                    ContentUnavailableView("Can’t Show Changes", systemImage: "exclamationmark.triangle", description: Text(error))
                } else {
                    ProgressView()
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(theme.content)
            .navigationTitle(diff?.title ?? (request.turnID == nil ? String(localized: "Uncommitted Changes") : String(localized: "Turn Changes")))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
        }
        .task {
            do {
                if case .diff(let result) = try await client.request(.diff(threadID: request.threadID, turnID: request.turnID), timeout: .seconds(60)) {
                    diff = result
                }
            } catch {
                self.error = (error as? RemoteError)?.message ?? error.localizedDescription
            }
        }
    }
}

struct FileRow: View {
    let file: RemoteDiff.File
    @Environment(\.theme) private var theme

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: symbol).foregroundStyle(color).frame(width: 20).accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 2) {
                Text((file.path as NSString).lastPathComponent).font(.body)
                Text(file.path).font(.caption.monospaced()).foregroundStyle(theme.secondaryInk).lineLimit(1).truncationMode(.head)
            }
            Spacer()
            DiffCounts(additions: file.additions, deletions: file.deletions)
        }
        .accessibilityElement(children: .combine)
    }

    private var symbol: String {
        switch file.status {
        case "added", "untracked": "plus.square"
        case "deleted": "minus.square"
        case "renamed": "arrow.right.square"
        default: "pencil.line"
        }
    }

    private var color: Color {
        switch file.status {
        case "added", "untracked": .green
        case "deleted": .red
        default: theme.accent
        }
    }
}

struct FileDiffView: View {
    let file: RemoteDiff.File
    @Environment(\.theme) private var theme

    var body: some View {
        let lines = RemoteDiffParsing.lines(of: file.patch)
        ScrollView([.vertical, .horizontal]) {
            if file.isBinary {
                Text("Binary file").foregroundStyle(theme.secondaryInk).padding()
            } else if lines.isEmpty {
                Text("Too large to show here.").foregroundStyle(theme.secondaryInk).padding()
            } else {
                LazyVStack(alignment: .leading, spacing: 0) {
                    ForEach(lines) { line in
                        HStack(spacing: 0) {
                            Text(number(line.oldLine)).frame(width: 40, alignment: .trailing)
                            Text(number(line.newLine)).frame(width: 40, alignment: .trailing)
                            Text(prefix(line.kind)).frame(width: 18)
                            Text(line.text.isEmpty ? " " : line.text)
                                .fixedSize(horizontal: true, vertical: false)
                        }
                        .font(.caption.monospaced())
                        .foregroundStyle(line.kind == .hunk || line.kind == .note ? theme.secondaryInk : theme.ink)
                        .padding(.vertical, 1)
                        .padding(.trailing, 16)
                        .background(background(line.kind))
                        .accessibilityElement(children: .ignore)
                        .accessibilityLabel(Text(accessibility(line)))
                    }
                }
                .textSelection(.enabled)
            }
        }
        .background(theme.content)
        .navigationTitle((file.path as NSString).lastPathComponent)
        .navigationBarTitleDisplayMode(.inline)
    }

    private func number(_ value: Int?) -> String { value.map(String.init) ?? "" }

    private func prefix(_ kind: RemoteDiffParsing.Line.Kind) -> String {
        switch kind {
        case .addition: "+"
        case .deletion: "−"
        default: ""
        }
    }

    private func background(_ kind: RemoteDiffParsing.Line.Kind) -> Color {
        switch kind {
        case .addition: .green.opacity(0.16)
        case .deletion: .red.opacity(0.16)
        case .hunk: theme.card
        default: .clear
        }
    }

    private func accessibility(_ line: RemoteDiffParsing.Line) -> String {
        switch line.kind {
        case .addition: String(localized: "Added: \(line.text)")
        case .deletion: String(localized: "Removed: \(line.text)")
        default: line.text
        }
    }
}
