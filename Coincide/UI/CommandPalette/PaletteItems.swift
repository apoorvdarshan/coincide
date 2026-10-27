import AppKit
import CoincideKit

/// One palette row: an action, a thread, a project or a setting.
struct PaletteItem {
    enum Kind {
        case action
        case thread(title: String, branch: String?, project: String?, updatedAt: Date)
        case project
    }

    enum Behavior {
        case run(() -> Void)
        /// Opens a nested list, like T3's "New thread in…".
        case submenu(PaletteMenu)
    }

    var id: String
    var title: String
    var subtitle: String?
    var icon: NSImage?
    var iconTint: NSColor?
    /// A shortcut ("⌘N") or an age ("5m").
    var trailing: String?
    var keywords: [String] = []
    var kind: Kind = .action
    /// Listed last in its group and never decides where the group sits (the open thread).
    var isSecondary = false
    /// What Tab puts in the search field: a folder's path, to browse into it.
    var completion: String?
    var behavior: Behavior

    func score(_ query: PaletteSearch.Query, typos: Bool) -> PaletteSearch.Match? {
        var match: PaletteSearch.Match?
        switch kind {
        case .thread(let title, let branch, let project, let updatedAt):
            match = PaletteSearch.scoreThread(
                query, title: title, branch: branch, project: project, updatedAt: updatedAt, typos: typos,
                branchPrefix: AppStore.shared.settings.worktreeBranchPrefix)
        case .action, .project:
            match = PaletteSearch.scoreTerms(query, name: title, keywords: keywords, typos: typos)
        }
        if isSecondary { match?.groupQuality = 0 }
        return match
    }
}

struct PaletteGroup {
    var id: String
    var title: String
    var items: [PaletteItem]
}

/// A nested list pushed onto the palette.
struct PaletteMenu {
    var title: String
    var placeholder: String
    var groups: () -> [PaletteGroup]
}

/// Builds the palette's contents from the store and the main window's state.
struct PaletteCatalog {
    let windowController: MainWindowController?
    private let store = AppStore.shared

    static let recentThreadLimit = 12
    static let threadLimit = 20
    static let secondaryLimit = 3

    private var thread: ChatThread? { windowController?.selectedThread }

    // MARK: Actions

    /// Every command: the core ones first, listed above the recent threads, then the rest.
    func actions() -> (core: [PaletteItem], more: [PaletteItem]) {
        let window = windowController
        var items: [PaletteItem] = []
        if let projectID = window?.currentProjectID, let project = store.project(projectID) {
            items.append(
                PaletteItem(
                    id: "action:new-thread", title: String(localized: "New Thread in \(project.name)"),
                    icon: symbol("square.and.pencil"), trailing: "⌘N", keywords: ["new thread", "chat", "create", "draft"],
                    behavior: .run { window?.newThread(in: projectID) }))
        }
        if !store.projects.isEmpty {
            items.append(
                PaletteItem(
                    id: "action:new-thread-in", title: String(localized: "New Thread in…"), icon: symbol("square.and.pencil"),
                    keywords: ["new thread", "project", "pick", "choose", "select"], behavior: .submenu(newThreadMenu())))
        }
        items.append(
            PaletteItem(
                id: "action:add-project", title: String(localized: "Add Project…"), icon: symbol("folder.badge.plus"),
                trailing: "⇧⌘O", keywords: ["add project", "open folder", "folder", "repository", "workspace"],
                behavior: .run { window?.addProject(nil) }))
        if let target = OpenTargets.preferred, window?.openFolder != nil {
            items.append(
                PaletteItem(
                    id: "action:open-in", title: String(localized: "Open in \(target.name)"), icon: target.icon, trailing: "⌘O",
                    keywords: ["open", "editor", "finder", "terminal", "reveal"], behavior: .run { window?.openInPreferred(nil) }))
        }
        if let split = window?.splitController {
            items.append(
                PaletteItem(
                    id: "action:terminal",
                    title: split.content.isTerminalOpen ? String(localized: "Hide Terminal") : String(localized: "Show Terminal"),
                    icon: symbol("terminal"), trailing: "⌘J", keywords: ["terminal", "shell", "console", "toggle"],
                    behavior: .run { window?.toggleTerminalPanel(nil) }))
            items.append(
                PaletteItem(
                    id: "action:diff", title: split.isDiffOpen ? String(localized: "Hide Diff") : String(localized: "Show Diff"),
                    icon: symbol("plus.forwardslash.minus"), trailing: "⌘D",
                    keywords: ["diff", "changes", "review", "git", "toggle"], behavior: .run { window?.toggleDiffPanel(nil) }))
        }
        if let thread, ThreadRunner.shared.isRunning(thread.id) {
            items.append(
                PaletteItem(
                    id: "action:stop", title: String(localized: "Stop Agent"), icon: symbol("stop.circle"), trailing: "⌘.",
                    keywords: ["stop", "interrupt", "cancel", "abort"], behavior: .run { window?.stopTurn(nil) }))
        }
        let core = items
        items = []
        if let split = window?.splitController {
            items.append(
                PaletteItem(
                    id: "action:sidebar",
                    title: split.isSidebarOpen ? String(localized: "Hide Sidebar") : String(localized: "Show Sidebar"),
                    icon: symbol("sidebar.left"), trailing: "⌘B", keywords: ["sidebar", "projects", "threads", "toggle"],
                    behavior: .run { window?.toggleSidebarPanel(nil) }))
        }
        if let thread {
            items.append(
                PaletteItem(
                    id: "action:pin", title: thread.isPinned ? String(localized: "Unpin Thread") : String(localized: "Pin Thread"),
                    icon: symbol(thread.isPinned ? "pin.slash" : "pin"), trailing: "⇧⌘P", keywords: ["pin", "unpin", "favorite"],
                    behavior: .run { ThreadActions.togglePin(thread.id) }))
            items.append(
                PaletteItem(
                    id: "action:rename", title: String(localized: "Rename Thread…"), icon: symbol("pencil"),
                    keywords: ["rename", "title"], behavior: .run { window?.renameThread(nil) }))
            if ThreadActions.canArchive(thread.id) {
                items.append(
                    PaletteItem(
                        id: "action:archive",
                        title: thread.isArchived ? String(localized: "Unarchive Thread") : String(localized: "Archive Thread"),
                        icon: symbol("archivebox"), keywords: ["archive", "hide", "done"],
                        behavior: .run { ThreadActions.toggleArchived(thread.id) }))
            }
        }
        items.append(
            PaletteItem(
                id: "action:appearance", title: String(localized: "Change Appearance…"), icon: symbol("circle.lefthalf.filled"),
                keywords: ["appearance", "theme", "dark", "light", "mode"], behavior: .submenu(appearanceMenu())))
        items.append(
            PaletteItem(
                id: "action:refresh-agents", title: String(localized: "Refresh Agents"), icon: symbol("arrow.clockwise"),
                keywords: ["refresh", "providers", "agents", "detect", "login", "models"],
                behavior: .run { Task { await ProviderRegistry.shared.refresh() } }))
        items.append(
            PaletteItem(
                id: "action:settings", title: String(localized: "Open Settings"), icon: symbol("gearshape"), trailing: "⌘,",
                keywords: ["settings", "preferences", "configuration"], behavior: .run { SettingsWindowController.shared.show() }))
        return (core, items)
    }

    // MARK: Threads and projects

    func recentThreads() -> [PaletteItem] {
        let current = thread?.id
        let recent = store.recentThreads.prefix(Self.recentThreadLimit).map { threadItem($0, isCurrent: $0.id == current) }
        // Picking the thread that is already open does nothing, so it goes last.
        return recent.filter { !$0.isSecondary } + recent.filter(\.isSecondary)
    }

    func allThreads() -> [PaletteItem] {
        let current = thread?.id
        return store.recentThreads.map { threadItem($0, isCurrent: $0.id == current) }
    }

    private func threadItem(_ thread: ChatThread, isCurrent: Bool) -> PaletteItem {
        let project = store.project(thread.projectID)?.name
        var parts = [project].compactMap(\.self)
        if let branch = thread.branch, !branch.isEmpty { parts.append("#\(branch)") }
        if isCurrent { parts.append(String(localized: "Current thread")) }
        let id = thread.id
        return PaletteItem(
            id: "thread:\(id)", title: thread.title, subtitle: parts.joined(separator: " · "),
            icon: symbol(thread.selection.provider.symbolName), iconTint: Theme.color(for: thread.selection.provider),
            trailing: Formatting.compactAge(of: thread.updatedAt),
            kind: .thread(title: thread.title, branch: thread.branch, project: project, updatedAt: thread.updatedAt),
            isSecondary: isCurrent, behavior: .run { AppEvents.openThread(id) })
    }

    func projects() -> [PaletteItem] {
        store.projects.map { project in
            let id = project.id
            return PaletteItem(
                id: "project:\(id)", title: project.name, subtitle: Formatting.abbreviatedPath(project.path),
                icon: symbol("folder"), iconTint: .controlAccentColor, keywords: [project.path], kind: .project,
                behavior: .run { ThreadActions.addProjects([project.url]) })
        }
    }

    func settings() -> [PaletteItem] {
        let sections: [(SettingsSection, String, String, [String])] = [
            (.general, String(localized: "General Settings"), "gearshape", ["appearance", "notifications", "font", "confirm"]),
            (.providers, String(localized: "Agent Settings"), "person.2", ["providers", "claude", "codex", "cursor", "cli", "login"]),
            (.models, String(localized: "Model Settings"), "cpu", ["models", "effort", "custom", "default"]),
            (.keyboard, String(localized: "Keyboard Shortcuts"), "keyboard", ["shortcuts", "keybindings", "keys"]),
            (.about, String(localized: "About Coincide"), "info.circle", ["version", "license", "credits"]),
        ]
        return sections.map { section, title, icon, keywords in
            PaletteItem(
                id: "setting:\(section.rawValue)", title: title, subtitle: String(localized: "Settings"), icon: symbol(icon),
                keywords: keywords, behavior: .run { SettingsWindowController.shared.show(section: section) })
        }
    }

    // MARK: Submenus

    private func newThreadMenu() -> PaletteMenu {
        let window = windowController
        return PaletteMenu(title: String(localized: "New Thread in…"), placeholder: String(localized: "Search projects…")) {
            let store = AppStore.shared
            let items = store.projects.map { project in
                let id = project.id
                return PaletteItem(
                    id: "new-thread-in:\(id)", title: project.name, subtitle: Formatting.abbreviatedPath(project.path),
                    icon: Theme.symbol("folder", size: 15), iconTint: .controlAccentColor, keywords: [project.path],
                    kind: .project, behavior: .run { window?.newThread(in: id) })
            }
            return [PaletteGroup(id: "projects", title: String(localized: "Projects"), items: items)]
        }
    }

    private func appearanceMenu() -> PaletteMenu {
        PaletteMenu(title: String(localized: "Change Appearance…"), placeholder: String(localized: "Search appearances…")) {
            let current = AppStore.shared.settings.appearance
            let items = AppearanceMode.allCases.map { mode in
                let icon = mode == .system ? "circle.lefthalf.filled" : mode == .light ? "sun.max" : "moon"
                return PaletteItem(
                    id: "appearance:\(mode.rawValue)", title: mode.displayName, icon: Theme.symbol(icon, size: 15),
                    trailing: mode == current ? String(localized: "Current") : nil,
                    behavior: .run { AppStore.shared.updateSettings { $0.appearance = mode } })
            }
            return [PaletteGroup(id: "appearance", title: String(localized: "Appearance"), items: items)]
        }
    }

    // MARK: Folder paths

    /// T3's add-project browsing: a query starting with "/" or "~" lists folders to add as projects.
    static func isPathQuery(_ query: String) -> Bool { query.hasPrefix("/") || query.hasPrefix("~") }

    func folderItems(for query: String) -> [PaletteGroup] {
        let expanded = (query as NSString).expandingTildeInPath
        let usesTilde = query.hasPrefix("~")
        let fileManager = FileManager.default
        var items: [PaletteItem] = []
        var isDirectory: ObjCBool = false
        if fileManager.fileExists(atPath: expanded, isDirectory: &isDirectory), isDirectory.boolValue {
            let url = URL(fileURLWithPath: expanded)
            items.append(
                folderItem(url, title: String(localized: "Add “\(url.lastPathComponent)” as a Project"), usesTilde: usesTilde))
        }
        let parent = query.hasSuffix("/") ? expanded : (expanded as NSString).deletingLastPathComponent
        let prefix = query.hasSuffix("/") ? "" : (expanded as NSString).lastPathComponent.lowercased()
        let names = (try? fileManager.contentsOfDirectory(atPath: parent)) ?? []
        let matches = names.filter { name in
            guard !name.hasPrefix(".") || prefix.hasPrefix("."), name.lowercased().hasPrefix(prefix) else { return false }
            var isFolder: ObjCBool = false
            return fileManager.fileExists(atPath: (parent as NSString).appendingPathComponent(name), isDirectory: &isFolder)
                && isFolder.boolValue
        }
        for name in matches.sorted(by: { $0.localizedStandardCompare($1) == .orderedAscending }).prefix(40) {
            let url = URL(fileURLWithPath: (parent as NSString).appendingPathComponent(name))
            if url.path == expanded { continue }
            items.append(folderItem(url, title: name, usesTilde: usesTilde))
        }
        return items.isEmpty ? [] : [PaletteGroup(id: "folders", title: String(localized: "Folders"), items: items)]
    }

    private func folderItem(_ url: URL, title: String, usesTilde: Bool) -> PaletteItem {
        let path = usesTilde ? Formatting.abbreviatedPath(url.path) : url.path
        return PaletteItem(
            id: "folder:\(url.path)", title: title, subtitle: Formatting.abbreviatedPath(url.path),
            icon: Theme.symbol("folder.badge.plus", size: 15), iconTint: .controlAccentColor, kind: .project,
            completion: path.hasSuffix("/") ? path : path + "/", behavior: .run { ThreadActions.addProjects([url]) })
    }

    // MARK: Helpers

    private func symbol(_ name: String) -> NSImage? { Theme.symbol(name, size: 15) }
}
