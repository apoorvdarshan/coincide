import AppKit
import CoincideKit

/// An app a project folder can be opened in: Finder, a terminal or an editor.
struct OpenTarget: Hashable {
    enum Kind {
        case editor
        case terminal
        case fileManager
    }

    let bundleID: String
    let name: String
    let kind: Kind
    let appURL: URL

    /// The app's own icon, sized for menus and toolbars.
    var icon: NSImage { OpenTargets.icon(for: self) }
}

/// The installed apps behind T3's "Open in" picker, in its order: editors first, then terminals, then Finder.
enum OpenTargets {
    private static let catalog: [(bundleID: String, name: String, kind: OpenTarget.Kind)] = [
        ("com.todesktop.230313mzl4w4u92", "Cursor", .editor),
        ("com.microsoft.VSCode", "VS Code", .editor),
        ("com.microsoft.VSCodeInsiders", "VS Code Insiders", .editor),
        ("com.vscodium", "VSCodium", .editor),
        ("com.exafunction.windsurf", "Windsurf", .editor),
        ("dev.zed.Zed", "Zed", .editor),
        ("dev.zed.Zed-Preview", "Zed Preview", .editor),
        ("com.google.antigravity", "Antigravity", .editor),
        ("com.trae.app", "Trae", .editor),
        ("dev.kiro.desktop", "Kiro", .editor),
        ("com.apple.dt.Xcode", "Xcode", .editor),
        ("com.sublimetext.4", "Sublime Text", .editor),
        ("com.panic.Nova", "Nova", .editor),
        ("com.barebones.bbedit", "BBEdit", .editor),
        ("com.jetbrains.intellij", "IntelliJ IDEA", .editor),
        ("com.jetbrains.intellij.ce", "IntelliJ IDEA CE", .editor),
        ("com.jetbrains.WebStorm", "WebStorm", .editor),
        ("com.jetbrains.pycharm", "PyCharm", .editor),
        ("com.jetbrains.pycharm.ce", "PyCharm CE", .editor),
        ("com.jetbrains.goland", "GoLand", .editor),
        ("com.jetbrains.CLion", "CLion", .editor),
        ("com.jetbrains.rustrover", "RustRover", .editor),
        ("com.jetbrains.PhpStorm", "PhpStorm", .editor),
        ("com.jetbrains.rider", "Rider", .editor),
        ("com.jetbrains.rubymine", "RubyMine", .editor),
        ("com.jetbrains.datagrip", "DataGrip", .editor),
        ("com.google.android.studio", "Android Studio", .editor),
        ("com.apple.Terminal", "Terminal", .terminal),
        ("com.googlecode.iterm2", "iTerm", .terminal),
        ("com.mitchellh.ghostty", "Ghostty", .terminal),
        ("dev.warp.Warp-Stable", "Warp", .terminal),
        ("com.github.wez.wezterm", "WezTerm", .terminal),
        ("net.kovidgoyal.kitty", "kitty", .terminal),
        ("org.alacritty", "Alacritty", .terminal),
        ("com.apple.finder", "Finder", .fileManager),
    ]

    private static var cached: [OpenTarget]?
    private static var icons: [URL: NSImage] = [:]

    fileprivate static func icon(for target: OpenTarget) -> NSImage {
        if let icon = icons[target.appURL] { return icon }
        let icon = NSWorkspace.shared.icon(forFile: target.appURL.path)
        icon.size = NSSize(width: 16, height: 16)
        icons[target.appURL] = icon
        return icon
    }

    /// Installed targets, looked up once and refreshed with `reload()`.
    static var installed: [OpenTarget] {
        if let cached { return cached }
        let workspace = NSWorkspace.shared
        let found = catalog.compactMap { entry -> OpenTarget? in
            guard let url = workspace.urlForApplication(withBundleIdentifier: entry.bundleID) else { return nil }
            return OpenTarget(bundleID: entry.bundleID, name: entry.name, kind: entry.kind, appURL: url)
        }
        cached = found
        return found
    }

    /// Looks for newly installed or removed apps, e.g. before showing the menu.
    static func reload() {
        cached = nil
    }

    /// The target the "Open in" button uses: the last one picked, else the first installed editor, else Finder.
    static var preferred: OpenTarget? {
        let targets = installed
        if let id = UIState.shared.values.preferredOpenTarget, let target = targets.first(where: { $0.bundleID == id }) {
            return target
        }
        return targets.first { $0.kind == .editor } ?? targets.first { $0.kind == .fileManager }
    }

    /// Posted when the app the "Open in" button uses changes.
    static let preferredDidChange = Notification.Name("coincide.openTargets.preferredDidChange")

    static func open(_ folder: URL, with target: OpenTarget) {
        if UIState.shared.values.preferredOpenTarget != target.bundleID {
            UIState.shared.update { $0.preferredOpenTarget = target.bundleID }
            NotificationCenter.default.post(name: preferredDidChange, object: nil)
        }
        switch target.kind {
        case .fileManager:
            NSWorkspace.shared.selectFile(nil, inFileViewerRootedAtPath: folder.path)
        case .editor, .terminal:
            let item = target.bundleID == "com.apple.dt.Xcode" ? xcodeDocument(in: folder) : folder
            let configuration = NSWorkspace.OpenConfiguration()
            configuration.activates = true
            Task {
                do {
                    _ = try await NSWorkspace.shared.open([item], withApplicationAt: target.appURL, configuration: configuration)
                } catch {
                    NSAlert(error: error).runModal()
                }
            }
        }
    }

    /// Xcode opens a workspace, project or package better than a bare folder.
    private static func xcodeDocument(in folder: URL) -> URL {
        let names = (try? FileManager.default.contentsOfDirectory(atPath: folder.path)) ?? []
        let pick =
            names.first { $0.hasSuffix(".xcworkspace") } ?? names.first { $0.hasSuffix(".xcodeproj") }
            ?? names.first { $0 == "Package.swift" }
        return pick.map { folder.appendingPathComponent($0) } ?? folder
    }

    /// Builds menu items for every installed target, grouped by kind. The preferred one is checked.
    static func menuItems(target: AnyObject?, action: Selector) -> [NSMenuItem] {
        let targets = installed
        let preferredID = preferred?.bundleID
        var items: [NSMenuItem] = []
        for kind in [OpenTarget.Kind.editor, .terminal, .fileManager] {
            let group = targets.filter { $0.kind == kind }
            guard !group.isEmpty else { continue }
            if !items.isEmpty { items.append(.separator()) }
            for app in group {
                let item = NSMenuItem(title: app.name, action: action, keyEquivalent: "")
                item.target = target
                item.image = app.icon
                item.representedObject = app.bundleID
                item.state = app.bundleID == preferredID ? .on : .off
                items.append(item)
            }
        }
        if items.isEmpty {
            let none = NSMenuItem(title: String(localized: "No apps found"), action: nil, keyEquivalent: "")
            none.isEnabled = false
            items.append(none)
        }
        return items
    }

    static func target(withBundleID id: String) -> OpenTarget? { installed.first { $0.bundleID == id } }
}
