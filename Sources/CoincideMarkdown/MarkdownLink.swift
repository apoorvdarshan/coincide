import Foundation

public enum MarkdownLinkTarget: Sendable, Equatable {
    case external(URL)
    case file(URL, line: Int?)

    /// Provider text cannot launch arbitrary URL handlers or escape the workspace.
    public static func resolve(_ destination: String, workspace: URL?) -> Self? {
        guard !destination.isEmpty, !destination.hasPrefix("#"),
              !destination.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) }) else { return nil }
        var lookup = destination, suffixLine: Int?
        if !lookup.contains("://"), !lookup.contains("#") {
            let pieces = lookup.split(separator: ":", omittingEmptySubsequences: false)
            if pieces.count >= 2, Int(pieces.last ?? "") != nil {
                let suffixCount = pieces.count >= 3 && Int(pieces[pieces.count - 2]) != nil ? 2 : 1
                suffixLine = Int(pieces[pieces.count - suffixCount]); lookup = pieces.dropLast(suffixCount).joined(separator: ":")
            }
        }
        if let url = URL(string: lookup), let scheme = url.scheme?.lowercased() {
            if ["https", "http"].contains(scheme) {
                guard let host = url.host, !host.isEmpty, url.user == nil, url.password == nil else { return nil }
                return .external(url)
            }
            if scheme == "mailto" { return .external(url) }
            if scheme != "file" { return nil }
            guard url.host == nil || url.host == "" || url.host == "localhost" else { return nil }
        }
        guard let workspace else { return nil }
        let root = workspace.standardizedFileURL.resolvingSymlinksInPath()
        var path = lookup, line = suffixLine
        if let hash = path.lastIndex(of: "#") {
            let fragment = String(path[path.index(after: hash)...])
            if fragment.hasPrefix("L") { line = Int(fragment.dropFirst().prefix(while: \.isNumber)) }
            path = String(path[..<hash])
        }
        if path.lowercased().hasPrefix("file:") {
            guard let url = URL(string: path), url.isFileURL else { return nil }; path = url.path
        } else {
            path = path.removingPercentEncoding ?? path
            // Common coding-agent links use path:line[:column].
            let pieces = path.split(separator: ":", omittingEmptySubsequences: false)
            if pieces.count >= 2, Int(pieces.last ?? "") != nil {
                let suffixCount = pieces.count >= 3 && Int(pieces[pieces.count - 2]) != nil ? 2 : 1
                line = Int(pieces[pieces.count - suffixCount])
                path = pieces.dropLast(suffixCount).joined(separator: ":")
            }
        }
        guard !path.isEmpty, !path.hasPrefix("//") else { return nil }
        let target = (path.hasPrefix("/") ? URL(fileURLWithPath: path) : root.appendingPathComponent(path)).standardizedFileURL
        guard target.path.hasPrefix(root.path + "/") else { return nil }
        // Resolve existing parents individually, including links to a missing final file.
        var resolved = root
        for component in target.path.dropFirst(root.path.count + 1).split(separator: "/") {
            resolved = resolved.appendingPathComponent(String(component)).resolvingSymlinksInPath()
            guard resolved.path.hasPrefix(root.path + "/") else { return nil }
        }
        return .file(resolved, line: line.flatMap { $0 > 0 ? $0 : nil })
    }
}
