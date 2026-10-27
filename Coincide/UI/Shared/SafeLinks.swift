import AppKit

/// Opens links from agent output and terminal programs without running anything they point at.
///
/// Web and mail links open directly, as T3 Code's `parseSafeExternalUrl` allows. Any other scheme asks
/// first, naming the app that would handle it and showing the whole URL, since handlers such as `ssh:`
/// or an editor's own scheme act on what the link says. Files never go to their default app, which
/// launches apps and runs scripts (`.command`, `.tool`, `.terminal`) and executables: they open in an
/// installed editor, never a terminal, and folders, packages, or anything at all when no editor is
/// installed, are shown in Finder instead.
enum SafeLinks {
    private static let directSchemes: Set<String> = ["http", "https", "mailto"]
    /// Longer URLs are cut short in the confirmation, which would otherwise grow past the screen.
    private static let shownLength = 1000

    /// Opens a URL that is not a file: web and mail links at once, anything else once the user agrees.
    static func openExternal(_ url: URL, from window: NSWindow?) {
        if url.isFileURL { return openFile(url, from: window) }
        if directSchemes.contains(url.scheme?.lowercased() ?? "") {
            NSWorkspace.shared.open(url)
            return
        }
        guard let app = NSWorkspace.shared.urlForApplication(toOpen: url) else {
            NSSound.beep()
            return
        }
        let name = FileManager.default.displayName(atPath: app.path)
        confirm(
            title: String(localized: "Open this link in \(name)?"), detail: shortened(url.absoluteString),
            action: String(localized: "Open Link"), window: window
        ) {
            NSWorkspace.shared.open([url], withApplicationAt: app, configuration: NSWorkspace.OpenConfiguration())
        }
    }

    /// Shows a file named in a thread's output. Files outside `folder` (the thread's folder), or any
    /// file when there is no folder, are shown only once the user agrees.
    static func openFile(_ url: URL, inside folder: URL?, from window: NSWindow?) {
        let target = url.standardizedFileURL.resolvingSymlinksInPath()
        guard FileManager.default.fileExists(atPath: target.path) else {
            NSSound.beep()
            return
        }
        if let folder, contains(folder, target) { return show(target) }
        confirm(
            title: String(localized: "Open a file outside this thread’s folder?"), detail: shortened(target.path),
            action: String(localized: "Open File"), window: window
        ) {
            show(target)
        }
    }

    /// Shows a file without asking, for paths the user Command-clicks in their own terminal.
    static func openFile(_ url: URL, from window: NSWindow?) {
        let target = url.standardizedFileURL.resolvingSymlinksInPath()
        guard FileManager.default.fileExists(atPath: target.path) else {
            NSSound.beep()
            return
        }
        show(target)
    }

    /// Whether `url` (with its links resolved) lies inside `folder`.
    static func contains(_ folder: URL, _ url: URL) -> Bool {
        let base = folder.standardizedFileURL.resolvingSymlinksInPath().path
        let path = url.standardizedFileURL.resolvingSymlinksInPath().path
        return path == base || path.hasPrefix(base.hasSuffix("/") ? base : base + "/")
    }

    /// Opens a file in an editor, or selects it in Finder; never with its default app.
    private static func show(_ url: URL) {
        let values = try? url.resourceValues(forKeys: [.isDirectoryKey, .isPackageKey])
        guard values?.isDirectory == false, values?.isPackage != true, let editor else {
            NSWorkspace.shared.activateFileViewerSelecting([url])
            return
        }
        NSWorkspace.shared.open([url], withApplicationAt: editor.appURL, configuration: NSWorkspace.OpenConfiguration())
    }

    /// The editor files open in: the one "Open in" uses when that is an editor, else the first installed.
    /// `OpenTargets.open` is not used, since it changes that choice and opens Xcode on a project instead.
    private static var editor: OpenTarget? {
        if let preferred = OpenTargets.preferred, preferred.kind == .editor { return preferred }
        return OpenTargets.installed.first { $0.kind == .editor }
    }

    private static func shortened(_ text: String) -> String {
        text.count > shownLength ? String(text.prefix(shownLength)) + "…" : text
    }

    /// Asks before opening. Cancel is the default button, so pressing Return never opens anything.
    private static func confirm(title: String, detail: String, action: String, window: NSWindow?, then perform: @escaping () -> Void) {
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = detail
        alert.addButton(withTitle: String(localized: "Cancel"))
        alert.addButton(withTitle: action)
        guard let window, window.isVisible else {
            if alert.runModal() == .alertSecondButtonReturn { perform() }
            return
        }
        alert.beginSheetModal(for: window) { response in
            if response == .alertSecondButtonReturn { perform() }
        }
    }
}
