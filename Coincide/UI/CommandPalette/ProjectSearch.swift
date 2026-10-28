import AppKit
import CoincideKit

/// T3 Code's Go to File and project-wide search, as nested palette lists over the open thread's folder (its worktree
/// or the project). Files open in the editor the "Open in" button uses, at the matching line where it can.
@MainActor
enum ProjectSearch {
    static func goToFileMenu(root: URL) -> PaletteMenu {
        var menu = PaletteMenu(title: String(localized: "Go to File…"), placeholder: String(localized: "Search files…")) { [] }
        menu.search = { query in
            let entries = await ComposerFileIndex.shared.search(query, in: root, limit: 60).filter { !$0.isDirectory }
            let items = entries.map { entry in
                PaletteItem(
                    id: "file:" + entry.path, title: entry.name, subtitle: entry.parent.isEmpty ? nil : entry.parent,
                    icon: NSWorkspace.shared.icon(forFile: root.appendingPathComponent(entry.path).path).sized(16),
                    behavior: .run { FileOpener.open(root.appendingPathComponent(entry.path), line: nil) })
            }
            return [PaletteGroup(id: "files", title: String(localized: "Files"), items: items)]
        }
        return menu
    }

    static func searchMenu(root: URL) -> PaletteMenu {
        var menu = PaletteMenu(
            title: String(localized: "Search in Project…"), placeholder: String(localized: "Search text in files…")
        ) { [] }
        menu.search = { query in
            guard query.trimmingCharacters(in: .whitespaces).count >= 2 else { return [] }
            let matches = await TextSearch.run(query, in: root)
            return Dictionary(grouping: matches, by: \.path).sorted { $0.key < $1.key }.prefix(40).map { path, lines in
                PaletteGroup(
                    id: "search:" + path, title: path,
                    items: lines.prefix(6).map { match in
                        PaletteItem(
                            id: "search:\(path):\(match.line)", title: match.text, subtitle: "\(path):\(match.line)",
                            icon: Theme.symbol("text.magnifyingglass", size: 14),
                            behavior: .run { FileOpener.open(root.appendingPathComponent(path), line: match.line) })
                    })
            }
        }
        return menu
    }
}

/// Lines of a folder's files that contain some text, with ripgrep when it is installed and grep otherwise.
nonisolated enum TextSearch {
    struct Match: Hashable, Sendable {
        var path: String
        var line: Int
        var text: String
    }

    static func run(_ query: String, in root: URL, limit: Int = 300) async -> [Match] {
        let ripgrep = ["/opt/homebrew/bin/rg", "/usr/local/bin/rg"].first { FileManager.default.isExecutableFile(atPath: $0) }
        let (executable, arguments): (String, [String]) =
            if let ripgrep {
                (ripgrep, ["--line-number", "--no-heading", "--fixed-strings", "--smart-case", "--max-count", "6",
                    "--max-filesize", "1M", "--color", "never", "--", query, "."])
            } else {
                ("/usr/bin/grep", ["-rnIF", "--exclude-dir=.git", "--exclude-dir=node_modules", "-m", "6", "--", query, "."])
            }
        let output = await Task.detached(priority: .userInitiated) {
            let process = Process()
            process.executableURL = URL(fileURLWithPath: executable)
            process.arguments = arguments
            process.currentDirectoryURL = root
            let pipe = Pipe()
            process.standardOutput = pipe
            process.standardError = FileHandle.nullDevice
            guard (try? process.run()) != nil else { return "" }
            // Enough for a screen of results; the rest is left unread and the search stopped.
            let data = pipe.fileHandleForReading.readData(ofLength: 1_000_000)
            if process.isRunning { process.terminate() }
            return String(decoding: data, as: UTF8.self)
        }.value
        return Array(parse(output).prefix(limit))
    }

    /// `path:line:text` lines, as ripgrep and grep print them.
    static func parse(_ output: String) -> [Match] {
        output.split(whereSeparator: \.isNewline).compactMap { raw in
            let parts = raw.split(separator: ":", maxSplits: 2, omittingEmptySubsequences: false)
            guard parts.count == 3, let line = Int(parts[1]) else { return nil }
            var path = String(parts[0])
            if path.hasPrefix("./") { path.removeFirst(2) }
            let text = parts[2].trimmingCharacters(in: .whitespaces)
            return Match(path: path, line: line, text: String(text.prefix(160)))
        }
    }
}

/// Opens a file in the editor the "Open in" button uses, at a line when the editor takes one.
@MainActor
enum FileOpener {
    /// URL schemes of editors that open `scheme://file/path:line`.
    private static let lineSchemes = [
        "com.microsoft.VSCode": "vscode", "com.microsoft.VSCodeInsiders": "vscode-insiders", "com.vscodium": "vscodium",
        "com.todesktop.230313mzl4w4u92": "cursor", "com.exafunction.windsurf": "windsurf", "dev.zed.Zed": "zed",
    ]

    static func open(_ file: URL, line: Int?) {
        guard let editor = OpenTargets.preferred, editor.kind == .editor else {
            NSWorkspace.shared.open(file)
            return
        }
        if let line, let scheme = lineSchemes[editor.bundleID],
            let url = URL(string: "\(scheme)://file\(file.path.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? file.path):\(line)")
        {
            NSWorkspace.shared.open(url)
            return
        }
        if let line, editor.bundleID == "com.apple.dt.Xcode" {
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/usr/bin/xed")
            process.arguments = ["--line", String(line), file.path]
            if (try? process.run()) != nil { return }
        }
        let configuration = NSWorkspace.OpenConfiguration()
        NSWorkspace.shared.open([file], withApplicationAt: editor.appURL, configuration: configuration)
    }
}

extension NSImage {
    fileprivate func sized(_ side: CGFloat) -> NSImage {
        let image = copy() as? NSImage ?? self
        image.size = NSSize(width: side, height: side)
        return image
    }
}
