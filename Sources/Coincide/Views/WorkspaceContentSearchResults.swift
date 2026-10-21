import CoincideCore
import SwiftUI

struct WorkspaceContentSearchResults: View {
    let store: WorkspaceStore?
    let workspacePath: String
    let matches: [WorkspaceContentMatch]
    let select: (WorkspaceContentMatch) -> Void
    private var paths: [String] {
        var seen = Set<String>()
        return matches.compactMap { seen.insert($0.path).inserted ? $0.path : nil }
    }
    var body: some View {
        List {
            ForEach(paths, id: \.self) { path in
                Section {
                    let lines = matches.filter { $0.path == path }
                    ForEach(lines.indices, id: \.self) { index in
                        let match = lines[index]
                        Button { select(match) } label: {
                            HStack(alignment: .firstTextBaseline, spacing: 8) {
                                Text(match.lineNumber.formatted()).foregroundStyle(.secondary).monospacedDigit()
                                Text(highlighted(match)).lineLimit(2).frame(maxWidth: .infinity, alignment: .leading)
                            }.font(.system(.caption, design: .monospaced))
                        }.buttonStyle(.plain)
                            .accessibilityIdentifier("workspace-match-\(path)-\(match.lineNumber)")
                            .contextMenu { if let store { ExternalEditorMenu(store: store, workspacePath: workspacePath, relativePath: path, line: match.lineNumber) } }
                    }
                } header: { Text(path).lineLimit(1).truncationMode(.middle) }
            }
        }
    }
    private func highlighted(_ match: WorkspaceContentMatch) -> AttributedString {
        var result = AttributedString(match.lineContent)
        for range in match.matchRanges {
            guard range.start >= 0, range.end >= range.start, range.end <= match.lineContent.utf16.count,
                  let source = Range(NSRange(location: range.start, length: range.end - range.start), in: match.lineContent),
                  let start = AttributedString.Index(source.lowerBound, within: result),
                  let end = AttributedString.Index(source.upperBound, within: result) else { continue }
            result[start..<end].backgroundColor = Color.accentColor.opacity(0.2)
        }
        return result
    }
}
