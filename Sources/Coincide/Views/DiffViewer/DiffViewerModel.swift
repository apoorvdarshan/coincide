import AppKit
import CoincideCore
import CoincideMarkdown
import SwiftUI

enum DiffLayout: String, CaseIterable, Identifiable {
    case unified, split
    var id: String { rawValue }
}

/// Viewer preferences shared by every diff surface, stored like other native view preferences.
enum DiffViewerDefaults {
    static let layout = "diffViewer.layout"
    static let wrap = "diffViewer.wrapLines"
    static let ignoreWhitespace = "diffViewer.ignoreWhitespace"
    static let showTree = "diffViewer.showFileTree"
}

/// A folder-compressed file tree in T3's order: folders first, then files, by natural name.
struct DiffTreeNode: Identifiable, Equatable {
    let id: String
    let name: String
    let path: String
    let fileID: String?
    var children: [DiffTreeNode]
    var additions: Int
    var deletions: Int
    var status: UnifiedDiffFile.Status?
    var isFolder: Bool { fileID == nil }
    var optionalChildren: [DiffTreeNode]? { isFolder ? children : nil }
}

enum DiffFileTree {
    static func build(_ files: [UnifiedDiffFile]) -> [DiffTreeNode] {
        final class Folder {
            var folders: [String: Folder] = [:]
            var files: [UnifiedDiffFile] = []
        }
        let root = Folder()
        for file in files {
            let parts = file.path.split(separator: "/").map(String.init)
            var folder = root
            for part in parts.dropLast() {
                if let next = folder.folders[part] { folder = next } else { let next = Folder(); folder.folders[part] = next; folder = next }
            }
            folder.files.append(file)
        }
        func nodes(_ folder: Folder, prefix: String) -> [DiffTreeNode] {
            let folders = folder.folders.keys.sorted { $0.localizedStandardCompare($1) == .orderedAscending }.map { name -> DiffTreeNode in
                var displayName = name, path = prefix.isEmpty ? name : prefix + "/" + name, current = folder.folders[name]!
                // Chains of single-folder directories read as one row, as in T3's tree.
                while current.files.isEmpty, current.folders.count == 1, let (child, next) = current.folders.first {
                    displayName += "/" + child; path += "/" + child; current = next
                }
                let children = nodes(current, prefix: path)
                return .init(id: "folder:" + path, name: displayName, path: path, fileID: nil, children: children,
                             additions: children.reduce(0) { $0 + $1.additions }, deletions: children.reduce(0) { $0 + $1.deletions }, status: nil)
            }
            let leaves = folder.files.sorted { $0.path.localizedStandardCompare($1.path) == .orderedAscending }.map { file in
                DiffTreeNode(id: "file:" + file.id, name: String(file.path.split(separator: "/").last ?? Substring(file.path)), path: file.path, fileID: file.id,
                             children: [], additions: file.additions, deletions: file.deletions, status: file.status)
            }
            return folders + leaves
        }
        return nodes(root, prefix: "")
    }
}

/// Per-file collapse with T3's large-file default: big files start collapsed until expanded.
struct DiffCollapseState: Equatable {
    static let largeFileLineThreshold = 400
    var collapsed: Set<String> = []
    var expanded: Set<String> = []
    static func collapsedByDefault(_ file: UnifiedDiffFile) -> Bool { file.lineCount > largeFileLineThreshold }
    func isCollapsed(_ file: UnifiedDiffFile) -> Bool { collapsed.contains(file.id) || (Self.collapsedByDefault(file) && !expanded.contains(file.id)) }
    mutating func toggle(_ file: UnifiedDiffFile) { setCollapsed(!isCollapsed(file), file) }
    mutating func setCollapsed(_ value: Bool, _ file: UnifiedDiffFile) {
        if value { collapsed.insert(file.id); expanded.remove(file.id) } else { collapsed.remove(file.id); expanded.insert(file.id) }
    }
    mutating func collapseAll(_ files: [UnifiedDiffFile]) { for file in files { setCollapsed(true, file) } }
    mutating func expandAll(_ files: [UnifiedDiffFile]) { for file in files { setCollapsed(false, file) } }
}

/// Render rows for one file in either layout.
enum DiffRenderRow: Identifiable, Equatable {
    case hunk(id: String, header: String)
    case line(id: String, line: UnifiedDiffLine)
    case split(id: String, row: UnifiedDiffSplitRow)
    var id: String {
        switch self { case .hunk(let id, _), .line(let id, _), .split(let id, _): id }
    }
    static func rows(for file: UnifiedDiffFile, layout: DiffLayout) -> [DiffRenderRow] {
        var rows: [DiffRenderRow] = []
        for hunk in file.hunks {
            rows.append(.hunk(id: "\(hunk.id)", header: hunk.header))
            switch layout {
            case .unified: rows += hunk.lines.enumerated().map { .line(id: "\(hunk.id):\($0.offset)", line: $0.element) }
            case .split: rows += hunk.splitRows.enumerated().map { .split(id: "\(hunk.id):\($0.offset)", row: $0.element) }
            }
        }
        return rows
    }
}

enum DiffPresentation {
    static func statusLetter(_ status: UnifiedDiffFile.Status) -> String {
        switch status {
        case .added: "A"; case .deleted: "D"; case .renamed: "R"; case .copied: "C"; case .untracked: "U"; case .modified, .modeChanged: "M"
        }
    }
    static func statusName(_ status: UnifiedDiffFile.Status) -> String {
        switch status {
        case .added: String(localized: "Added"); case .deleted: String(localized: "Deleted"); case .renamed: String(localized: "Renamed")
        case .copied: String(localized: "Copied"); case .untracked: String(localized: "Untracked"); case .modified: String(localized: "Modified")
        case .modeChanged: String(localized: "Mode changed")
        }
    }
    static func statusColor(_ status: UnifiedDiffFile.Status) -> Color {
        switch status {
        case .added, .untracked: .green; case .deleted: .red; case .renamed, .copied: .blue; case .modified, .modeChanged: .orange
        }
    }
    /// Maps file extensions onto the lexical highlighter's language names.
    static func language(forExtension value: String) -> String {
        switch value {
        case "swift": "swift"; case "rs": "rust"; case "js", "mjs", "cjs": "javascript"; case "jsx": "jsx"; case "ts", "mts", "cts": "typescript"; case "tsx": "tsx"
        case "py": "python"; case "sh", "bash", "zsh": "bash"; case "rb": "ruby"; case "yaml", "yml": "yaml"; case "toml": "toml"; case "json": "json"; case "jsonc": "jsonc"
        case "c", "h": "c"; case "cc", "cpp", "cxx", "hpp", "hh": "cpp"; case "m", "mm": "objc"; case "java": "java"; case "kt", "kts": "kotlin"; case "go": "go"; case "css", "scss": "css"
        default: ""
        }
    }
}

/// Lexical token colors from the shared Markdown highlighter, cached per line.
@MainActor enum DiffHighlightCache {
    private static let cache: NSCache<NSString, NSAttributedString> = { let cache = NSCache<NSString, NSAttributedString>(); cache.countLimit = 4_000; return cache }()
    static func attributed(_ text: String, language: String) -> AttributedString {
        guard !language.isEmpty, !text.isEmpty, text.utf8.count <= 2_000 else { return AttributedString(text) }
        let key = (language + "\u{0}" + text) as NSString
        let source: NSAttributedString
        if let cached = cache.object(forKey: key) { source = cached } else { source = CodeHighlight.attributed(text, language: language); cache.setObject(source, forKey: key) }
        var result = AttributedString(text)
        source.enumerateAttribute(.foregroundColor, in: NSRange(location: 0, length: source.length)) { value, range, _ in
            guard let color = value as? NSColor, color != NSColor.labelColor, let target = Range<AttributedString.Index>(range, in: result) else { return }
            result[target].foregroundColor = Color(nsColor: color)
        }
        return result
    }
}
