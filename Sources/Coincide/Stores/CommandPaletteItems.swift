import AppKit
import CoincideCore
import Foundation

/// Builds palette items from the current workspace without mutating it.
@MainActor
enum CommandPaletteItems {
    static func sources(for controller: MainWindowController, query: String) -> CommandPaletteSources {
        let searching = !CommandPaletteSearch.normalize(query.hasPrefix(">") ? String(query.dropFirst()) : query).isEmpty
        var root: [PaletteGroup] = [.init(id: "actions", title: String(localized: "Actions"), items: actions(controller))]
        let recent = threadItems(controller, query: "", limit: CommandPaletteSearch.recentThreadLimit)
        if !recent.isEmpty { root.append(.init(id: "recent-threads", title: String(localized: "Recent Chats"), items: recent)) }
        guard searching, !query.hasPrefix(">") else { return .init(root: root) }
        return .init(root: root, projects: projectItems(controller), settings: settingsItems(controller),
                     threads: threadItems(controller, query: query, limit: 200))
    }

    private static func action(_ id: String, _ title: String, symbol: String, terms: [String], command: KeybindingCommand? = nil,
                               subtitle: String? = nil, secondary: Bool = false, _ controller: MainWindowController,
                               run: @escaping @MainActor () -> Void) -> PaletteItem {
        let capture = controller.captureAction()
        return PaletteItem(id: "action:" + id, title: title, subtitle: subtitle, symbol: symbol, searchTerms: [title] + terms, shortcut: command,
                    isSecondary: secondary, kind: .action { [weak controller] in
                        guard controller?.actionStillCurrent(capture) == true else { return }
                        run()
                    })
    }
    private static func command(_ id: String, _ title: String, symbol: String, terms: [String], _ command: KeybindingCommand,
                                subtitle: String? = nil, secondary: Bool = false, _ controller: MainWindowController) -> PaletteItem? {
        guard controller.canPerform(command) else { return nil }
        let capture = controller.captureAction()
        return action(id, title, symbol: symbol, terms: terms, command: command, subtitle: subtitle, secondary: secondary, controller) { [weak controller] in
            controller?.perform(command, expected: capture)
        }
    }

    static func actions(_ controller: MainWindowController) -> [PaletteItem] {
        let store = controller.store, thread = store.selectedThread
        var items: [PaletteItem] = []
        if let project = currentProject(store) {
            items.append(action("new-thread", String(localized: "New Chat in \(project.name)"), symbol: "square.and.pencil",
                                terms: ["new thread", "chat", "create", "draft"], command: .chatNewLocal, controller) { [weak store] in store?.newThread() })
        }
        if !store.snapshot.projects.isEmpty {
            items.append(.init(id: "action:new-thread-in", title: String(localized: "New Chat In…"), symbol: "square.and.pencil",
                               searchTerms: ["New Chat In…", "new thread", "project", "pick", "choose", "select"], kind: .submenu(newThreadInView(controller))))
        }
        items += [
            command("find-thread", String(localized: "Find in Current Chat"), symbol: "text.magnifyingglass", terms: ["find", "search", "messages"], .chatFind, controller),
            command("copy-thread-reference", String(localized: "Copy Chat ID"), symbol: "link", terms: ["copy", "thread id", "reference"], .threadCopyReference,
                    subtitle: thread?.id.uuidString.lowercased(), controller),
            thread.flatMap { thread in command("pin", thread.isPinned ? String(localized: "Unpin Chat") : String(localized: "Pin Chat"), symbol: thread.isPinned ? "pin.slash" : "pin",
                                               terms: ["pin", "unpin", "favorite"], .threadPin, controller) },
            command("stop", String(localized: "Stop Reply"), symbol: "stop.circle", terms: ["stop", "interrupt", "cancel"], .threadStop, controller),
            command("toggle-sidebar", String(localized: "Toggle Sidebar"), symbol: "sidebar.left", terms: ["sidebar", "threads", "projects"], .sidebarToggle, controller),
            command("back", String(localized: "Go Back"), symbol: "chevron.left", terms: ["back", "previous", "history"], .navigationBack, secondary: true, controller),
            command("forward", String(localized: "Go Forward"), symbol: "chevron.right", terms: ["forward", "next", "history"], .navigationForward, secondary: true, controller),
            command("new-project", String(localized: "New Project…"), symbol: "folder.badge.plus", terms: ["new project", "create project", "repository", "git init"], .projectNew, controller),
            command("add-project", String(localized: "Add Project…"), symbol: "folder", terms: ["add project", "open folder", "directory", "browse"], .projectAdd, controller),
            command("import", String(localized: "Import Conversations…"), symbol: "square.and.arrow.down", terms: ["import", "sessions", "codex", "claude", "history"], .projectImport, controller),
        ].compactMap { $0 }
        items.append(.init(id: "action:change-appearance", title: String(localized: "Change Appearance"), symbol: "circle.lefthalf.filled",
                           searchTerms: ["Change Appearance", "appearance", "theme", "dark", "light", "system", "colors"], shortcut: .themeSelect,
                           kind: .submenu(appearanceView(controller))))
        items += [
            command("cycle-appearance", String(localized: "Cycle Appearance"), symbol: "circle.lefthalf.filled", terms: ["appearance", "theme", "dark mode"], .appearanceCycle, secondary: true, controller),
            command("new-window", String(localized: "New Window"), symbol: "macwindow.badge.plus", terms: ["window", "new window"], .windowNew, secondary: true, controller),
        ].compactMap { $0 }
        items.append(action("settings", String(localized: "Open Settings"), symbol: "gearshape", terms: ["settings", "preferences", "configuration", "keybindings"], controller) { [weak controller] in
            controller?.presentations.openSettings() })
        if let keybindings = controller.keybindings {
            items.append(action("keybindings-file", String(localized: "Open keybindings.json"), symbol: "keyboard", terms: ["keybindings", "shortcuts", "keyboard", "json"],
                                secondary: true, controller) { keybindings.openFile() })
        }
        return items
    }

    static func newThreadInView(_ controller: MainWindowController) -> PaletteView {
        let store = controller.store
        let items = store.orderedProjectGroups.flatMap { group -> [PaletteItem] in
            group.members.map { project in
                let capture = controller.captureProject(project)
                return PaletteItem(id: "new-thread-in:\(project.id.uuidString)", title: group.members.count > 1 ? "\(group.displayName) — \(project.name)" : group.displayName,
                            subtitle: project.path, symbol: "folder", searchTerms: [group.displayName, project.name, project.path],
                            isDisabled: project.clone.map { !$0.isReady } ?? false,
                            kind: .action { [weak controller] in
                                guard let controller, controller.projectStillCurrent(capture) else { return }
                                controller.store.newThread(projectID: capture.id)
                            })
            }
        }
        return .init(id: "new-thread-in", title: String(localized: "New Chat In…"), groups: [.init(id: "projects", title: String(localized: "Projects"), items: items)])
    }

    static func appearanceView(_ controller: MainWindowController) -> PaletteView {
        let current = AppearanceMode.current(controller.defaults)
        let items = AppearanceMode.allCases.map { mode in
            PaletteItem(id: "appearance:\(mode.rawValue)", title: mode.title, symbol: mode.symbol, searchTerms: [mode.title, "appearance", "theme"],
                        isChecked: mode == current, kind: .action { [weak controller] in
                            guard let controller, controller.canHandleInteraction else { return }
                            controller.defaults.set(mode.rawValue, forKey: AppearanceMode.defaultsKey)
                        })
        }
        return .init(id: "appearance", title: String(localized: "Change Appearance"), groups: [.init(id: "appearance", title: String(localized: "Appearance"), items: items)])
    }

    /// Projects open their most recent thread, or start one when none exists.
    static func projectItems(_ controller: MainWindowController) -> [PaletteItem] {
        let store = controller.store
        return store.orderedProjectGroups.map { group in
            let members = Set(group.memberProjectIDs)
            let latest = store.snapshot.threads.filter { members.contains($0.projectID) && !$0.isArchived }.max { $0.updatedAt < $1.updatedAt }
            let target = store.preferredProject(in: group)?.id ?? group.representative.id
            let project = store.snapshot.projects.first { $0.id == target } ?? group.representative
            let projectCapture = controller.captureProject(project), threadCapture = latest.flatMap(controller.captureThread)
            return PaletteItem(id: "project:\(group.key)", title: group.displayName, subtitle: group.members.map(\.path).joined(separator: " · "),
                               symbol: "folder", searchTerms: [group.displayName] + group.members.flatMap { [$0.name, $0.path] },
                               kind: .action { [weak controller] in
                                   guard let controller, controller.projectStillCurrent(projectCapture) else { return }
                                   if let threadCapture {
                                       guard controller.threadStillCurrent(threadCapture) else { return }
                                       controller.store.selectThread(threadCapture.id)
                                   } else if latest == nil { controller.store.newThread(projectID: target) }
                               })
        }
    }

    static func settingsItems(_ controller: MainWindowController) -> [PaletteItem] {
        var items = [PaletteItem(id: "setting:keyboard", title: String(localized: "Keyboard Shortcuts"), subtitle: String(localized: "Settings · Keyboard"),
                                 symbol: "keyboard", searchTerms: ["Keyboard Shortcuts", "keybindings", "shortcuts", "hotkeys", "keys"],
                                 kind: .action { [weak controller] in if controller?.canHandleInteraction == true { controller?.presentations.openSettings() } })]
        items += [("setting:follow-up", String(localized: "Messages During a Running Turn"), ["queue", "steer", "follow up", "running"]),
                  ("setting:notifications", String(localized: "Notifications"), ["notifications", "sounds", "badge"])].map { id, title, terms in
            PaletteItem(id: id, title: title, subtitle: String(localized: "Settings · General"), symbol: "gearshape", searchTerms: [title] + terms,
                        isSecondary: true, kind: .action { [weak controller] in if controller?.canHandleInteraction == true { controller?.presentations.openSettings() } })
        }
        return items
    }

    /// Non-archived threads by recent activity. A query of two or more characters
    /// also matches message text and shows a bounded snippet.
    static func threadItems(_ controller: MainWindowController, query: String, limit: Int) -> [PaletteItem] {
        let store = controller.store
        let projects = Dictionary(store.snapshot.projects.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        let groups = Dictionary(store.orderedProjectGroups.flatMap { group in group.memberProjectIDs.map { ($0, group.displayName) } }, uniquingKeysWith: { first, _ in first })
        let needle = query.trimmingCharacters(in: .whitespacesAndNewlines)
        let formatter = RelativeDateTimeFormatter(); formatter.unitsStyle = .short
        let threads = store.snapshot.threads.filter { !$0.isArchived && projects[$0.projectID] != nil }.sorted { $0.updatedAt > $1.updatedAt }
        let tokens = CommandPaletteSearch.normalize(needle).split(separator: " ").map(String.init)
        return Array(threads.lazy.compactMap { thread -> PaletteItem? in
            guard let capture = controller.captureThread(thread) else { return nil }
            let projectName = groups[thread.projectID] ?? projects[thread.projectID]?.name ?? ""
            var description = [projectName]
            if thread.id == store.selectedThreadID { description.append(String(localized: "Current chat")) }
            var snippet: String?
            if needle.count >= CommandPaletteSearch.messageSearchMinimum,
               CommandPaletteSearch.normalize(thread.title).contains(CommandPaletteSearch.normalize(needle)) == false {
                for message in thread.visibleMessages.reversed() where message.role == .user || message.role == .assistant {
                    if let found = CommandPaletteSearch.snippet(in: message.text, query: needle) { snippet = found; break }
                }
            }
            let terms = [thread.title, projectName, snippet ?? "", thread.workspacePath, thread.id.uuidString.lowercased()]
            if !tokens.isEmpty {
                let haystack = CommandPaletteSearch.normalize(terms.joined(separator: " "))
                guard tokens.allSatisfy(haystack.contains) else { return nil }
            }
            return PaletteItem(id: "thread:\(thread.id.uuidString)", title: thread.title, subtitle: description.filter { !$0.isEmpty }.joined(separator: " · "),
                               detail: formatter.localizedString(for: thread.updatedAt, relativeTo: Date()),
                               symbol: thread.isPinned ? "pin" : "bubble.left",
                               searchTerms: terms,
                               searchRecency: thread.updatedAt.timeIntervalSince1970, snippet: snippet,
                               kind: .action { [weak controller] in
                                   guard let controller, controller.threadStillCurrent(capture) else { return }
                                   controller.store.selectThread(capture.id)
                               })
        }.prefix(max(0, limit)))
    }

    private static func currentProject(_ store: WorkspaceStore) -> WorkspaceProject? {
        guard let id = store.selectedProjectID ?? store.selectedThread?.projectID, let group = store.projectGroup(containing: id) else { return nil }
        return store.preferredProject(in: group)
    }
}
