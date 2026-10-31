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
    /// A shortcut ("⌘N", the user's for a menu command) or an age ("5m").
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
    /// Finds the list for each query itself, such as files or text in a project, instead of the palette filtering
    /// `groups`. Its results are shown as they are.
    var search: ((String) async -> [PaletteGroup])?
}

/// Builds the palette's contents from the store and the main window's state.
struct PaletteCatalog {
    let windowController: MainWindowController?
    private let store = AppStore.shared

    static let recentThreadLimit = 12
    static let threadLimit = 20
    static let secondaryLimit = 3

    private var thread: ThreadSummary? { windowController?.selectedThread }

    /// The menu command's current shortcut, nil when it has none.
    private func keys(_ command: KeyCommand) -> String? {
        KeyBindingsController.shared.displayString(for: command)
    }

    // MARK: Actions

    /// Every command: the core ones first, listed above the recent threads, then the rest.
    func actions() -> (core: [PaletteItem], more: [PaletteItem]) {
        let window = windowController
        var items: [PaletteItem] = []
        if let projectID = window?.currentProjectID, let project = store.project(projectID) {
            items.append(
                PaletteItem(
                    id: "action:new-thread", title: String(localized: "New Thread in \(project.name)"),
                    icon: symbol("square.and.pencil"), trailing: keys(.newThread),
                    keywords: ["new thread", "chat", "create", "draft"],
                    behavior: .run { window?.newThread(in: projectID) }))
        }
        items.append(
            PaletteItem(
                id: "action:new-chat", title: String(localized: "New Chat"), icon: symbol("bubble.left.and.bubble.right"),
                keywords: ["new chat", "chat", "no project", "without project", "conversation"],
                behavior: .run { ThreadActions.newChat() }))
        items.append(
            PaletteItem(
                id: "action:new-bot", title: String(localized: "New Bot…"), icon: symbol("face.smiling"),
                keywords: ["new bot", "bot", "assistant", "persona", "create"], behavior: .run { window?.newBot(nil) }))
        for bot in store.bots {
            let id = bot.id
            items.append(
                PaletteItem(
                    id: "bot:\(id)", title: String(localized: "Talk to \(bot.displayName)"), subtitle: String(localized: "Bot"),
                    icon: BotAvatarArt.image(bot.avatar, size: 16), keywords: ["bot", bot.displayName],
                    behavior: .run { BotActions.open(id) }))
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
                trailing: keys(.addProject), keywords: ["add project", "open folder", "folder", "repository", "workspace"],
                behavior: .run { window?.addProject(nil) }))
        if let target = OpenTargets.preferred, window?.openFolder != nil {
            items.append(
                PaletteItem(
                    id: "action:open-in", title: String(localized: "Open in \(target.name)"), icon: target.icon,
                    trailing: keys(.openInEditor),
                    keywords: ["open", "editor", "finder", "terminal", "reveal"], behavior: .run { window?.openInPreferred(nil) }))
        }
        items.append(
            PaletteItem(
                id: "action:scheduled-tasks",
                title: window?.splitController.isSchedulesOpen == true
                    ? String(localized: "Hide Scheduled Tasks") : String(localized: "Show Scheduled Tasks"),
                icon: symbol("clock"), trailing: keys(.showSchedules),
                keywords: ["schedule", "scheduled", "tasks", "automation", "cron", "recurring", "daily", "weekly", "reminder"],
                behavior: .run { window?.toggleSchedulesPanel(nil) }))
        if let thread {
            items.append(
                PaletteItem(
                    id: "action:schedule-in-thread", title: String(localized: "Schedule a Message in This Thread…"),
                    icon: symbol("clock.badge.plus"),
                    keywords: ["schedule", "later", "remind", "recurring", "every", "cron", "timer"],
                    behavior: .run { ScheduleActions.newSchedule(inThread: thread.id, in: window?.window) }))
        }
        items.append(
            PaletteItem(
                id: "action:edit-instructions", title: String(localized: "Edit Instructions"), icon: symbol("text.book.closed"),
                keywords: ["instructions", "agents.md", "claude.md", "gemini.md", "rules", "memory", "prompt"],
                behavior: .run { window?.editInstructions(nil) }))
        if store.settings.voice.isEnabled, let chat = window?.splitController.content.chat, chat.canDictate || chat.isDictating {
            let voice = store.settings.voice
            items.append(
                PaletteItem(
                    id: "action:dictate", title: chat.isDictating ? String(localized: "Stop Dictating") : String(localized: "Dictate"),
                    icon: symbol(chat.isDictating ? "mic.fill" : "mic"),
                    trailing: voice.shortcutEnabled ? voice.shortcut.displayString : nil,
                    keywords: ["dictate", "dictation", "voice", "speech", "microphone", "talk", "speak", "transcribe"],
                    behavior: .run { [weak chat] in chat?.toggleDictation() }))
        }
        if let split = window?.splitController {
            items.append(
                PaletteItem(
                    id: "action:terminal",
                    title: split.isTerminalOpen ? String(localized: "Hide Terminal") : String(localized: "Show Terminal"),
                    icon: symbol("terminal"), trailing: keys(.toggleTerminal), keywords: ["terminal", "shell", "console", "toggle"],
                    behavior: .run { window?.toggleTerminalPanel(nil) }))
            items.append(
                PaletteItem(
                    id: "action:diff", title: split.isDiffOpen ? String(localized: "Hide Diff") : String(localized: "Show Diff"),
                    icon: symbol("plus.forwardslash.minus"), trailing: keys(.toggleDiff),
                    keywords: ["diff", "changes", "review", "git", "toggle"], behavior: .run { window?.toggleDiffPanel(nil) }))
            items.append(
                PaletteItem(
                    id: "action:pull-requests",
                    title: split.isPullRequestsOpen
                        ? String(localized: "Hide Pull Requests") : String(localized: "Show Pull Requests"),
                    icon: symbol("arrow.triangle.pull"),
                    keywords: ["pull request", "pr", "github", "review", "checks", "merge", "toggle"],
                    behavior: .run { window?.togglePullRequestsPanel(nil) }))
            items.append(PaletteItem(
                id: "action:preview", title: split.isPreviewOpen ? String(localized: "Hide Browser Preview") : String(localized: "Show Browser Preview"),
                icon: symbol("globe"), keywords: ["preview", "browser", "web", "localhost"],
                behavior: .run { window?.togglePreviewPanel(nil) }))
        }
        if let thread, ThreadRunner.shared.isRunning(thread.id) {
            items.append(
                PaletteItem(
                    id: "action:stop", title: String(localized: "Stop Agent"), icon: symbol("stop.circle"), trailing: keys(.stopTurn),
                    keywords: ["stop", "interrupt", "cancel", "abort"], behavior: .run { window?.stopTurn(nil) }))
        }
        if thread != nil {
            items.append(
                PaletteItem(
                    id: "action:find", title: String(localized: "Find in Thread…"), icon: symbol("magnifyingglass"), trailing: "⌘F",
                    keywords: ["find", "search", "thread", "conversation", "text", "match", "current"],
                    behavior: .run { window?.findInThread() }))
        }
        let core = items
        items = []
        if let thread { items += composerActions(for: thread) + searchActions(for: thread) }
        items.append(
            PaletteItem(
                id: "action:scheduled-tasks",
                title: window?.splitController.isSchedulesOpen == true
                    ? String(localized: "Hide Scheduled Tasks") : String(localized: "Show Scheduled Tasks"),
                icon: symbol("clock"), trailing: keys(.showSchedules),
                keywords: ["schedule", "scheduled", "tasks", "automation", "cron", "recurring", "daily", "weekly", "reminder"],
                behavior: .run { window?.toggleSchedulesPanel(nil) }))
        if let split = window?.splitController {
            items.append(
                PaletteItem(
                    id: "action:sidebar",
                    title: split.isSidebarOpen ? String(localized: "Hide Sidebar") : String(localized: "Show Sidebar"),
                    icon: symbol("sidebar.left"), trailing: keys(.toggleSidebar), keywords: ["sidebar", "projects", "threads", "toggle"],
                    behavior: .run { window?.toggleSidebarPanel(nil) }))
        }
        if let thread {
            items.append(
                PaletteItem(
                    id: "action:pin", title: thread.isPinned ? String(localized: "Unpin Thread") : String(localized: "Pin Thread"),
                    icon: symbol(thread.isPinned ? "pin.slash" : "pin"), trailing: keys(.pinThread),
                    keywords: ["pin", "unpin", "favorite"],
                    behavior: .run { ThreadActions.togglePin(thread.id) }))
            items.append(
                PaletteItem(
                    id: "action:rename", title: String(localized: "Rename Thread…"), icon: symbol("pencil"),
                    trailing: keys(.renameThread), keywords: ["rename", "title"], behavior: .run { window?.renameThread(nil) }))
            if ThreadActions.canArchive(thread.id) {
                items.append(
                    PaletteItem(
                        id: "action:archive",
                        title: thread.isArchived ? String(localized: "Unarchive Thread") : String(localized: "Archive Thread"),
                        icon: symbol("archivebox"), trailing: keys(.archiveThread), keywords: ["archive", "hide", "done"],
                        behavior: .run { [weak window = windowController?.window] in ThreadActions.toggleArchived(thread.id, in: window) }))
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

    private func threadItem(_ thread: ThreadSummary, isCurrent: Bool) -> PaletteItem {
        let project = store.project(thread.projectID)?.name
        var parts = [project].compactMap(\.self)
        if let branch = thread.branch, !branch.isEmpty { parts.append("#\(branch)") }
        if isCurrent { parts.append(String(localized: "Current thread")) }
        let id = thread.id
        return PaletteItem(
            id: "thread:\(id)", title: thread.title, subtitle: parts.joined(separator: " · "),
            icon: Theme.logo(for: thread.selection.provider, size: 15),
            trailing: Formatting.compactAge(of: thread.updatedAt),
            kind: .thread(title: thread.title, branch: thread.branch, project: project, updatedAt: thread.updatedAt),
            isSecondary: isCurrent, behavior: .run { AppEvents.openThread(id) })
    }

    func projects() -> [PaletteItem] {
        store.projects.map { project in
            let id = project.id
            return PaletteItem(
                id: "project:\(id)", title: project.name, subtitle: Formatting.abbreviatedPath(project.path),
                icon: symbol("folder"), iconTint: .secondaryLabelColor, keywords: [project.path], kind: .project,
                behavior: .run { ThreadActions.addProjects([project.url]) })
        }
    }

    func settings() -> [PaletteItem] {
        let sections: [(SettingsSection, String, String, [String])] = [
            (.general, String(localized: "General Settings"), "gearshape", ["appearance", "notifications", "font", "confirm"]),
            (.providers, String(localized: "Agent Settings"), "person.2", ["providers", "claude", "codex", "cursor", "cli", "login"]),
            (.models, String(localized: "Model Settings"), "cpu", ["models", "effort", "custom", "default"]),
            (.instructions, String(localized: "Global Instructions"), "text.book.closed", ["agents.md", "claude.md", "rules", "memory"]),
            (.keyboard, String(localized: "Keyboard Shortcuts"), "keyboard", ["shortcuts", "keybindings", "keys"]),
            (.voice, String(localized: "Voice Settings"), "mic", ["dictation", "voice", "speech", "microphone", "whisper", "transcription"]),
            (.about, String(localized: "About Coincide"), "info.circle", ["version", "license", "credits"]),
        ]
        return sections.map { section, title, icon, keywords in
            PaletteItem(
                id: "setting:\(section.rawValue)", title: title, subtitle: String(localized: "Settings"), icon: symbol(icon),
                keywords: keywords, behavior: .run { SettingsWindowController.shared.show(section: section) })
        }
    }

    // MARK: Project search

    /// Go to File and Search in Project over the thread's folder.
    private func searchActions(for thread: ThreadSummary) -> [PaletteItem] {
        guard let root = AppStore.shared.workingDirectory(for: thread.id) else { return [] }
        return [
            PaletteItem(
                id: "action:go-to-file", title: String(localized: "Go to File…"), icon: symbol("doc.text.magnifyingglass"),
                keywords: ["file", "open", "find", "quick open"], behavior: .submenu(ProjectSearch.goToFileMenu(root: root))),
            PaletteItem(
                id: "action:search-project", title: String(localized: "Search in Project…"), icon: symbol("text.magnifyingglass"),
                keywords: ["search", "grep", "find", "text", "content"], behavior: .submenu(ProjectSearch.searchMenu(root: root))),
        ]
    }

    // MARK: Composer

    /// The composer's pickers (agent and model, reasoning effort, access, plan or build) and a switch to each
    /// other ready agent, as `/codex` and the like do in the composer.
    private func composerActions(for thread: ThreadSummary) -> [PaletteItem] {
        let window = windowController
        let registry = ProviderRegistry.shared
        var items: [PaletteItem] = [
            PaletteItem(
                id: "action:model", title: String(localized: "Choose Agent and Model…"), icon: symbol("cpu"),
                trailing: keys(.chooseModel),
                keywords: ["model", "agent", "provider", "switch", "change", "picker"], behavior: .submenu(modelMenu(thread)))
        ]
        if let model = registry.model(for: thread.selection), !model.efforts.isEmpty {
            items.append(
                PaletteItem(
                    id: "action:effort", title: String(localized: "Choose Reasoning Effort…"), icon: symbol("brain"),
                    trailing: keys(.reasoningEffort), keywords: ["reasoning", "effort", "thinking", "think", "level"],
                    behavior: .submenu(effortMenu(thread, model: model))))
        }
        items.append(
            PaletteItem(
                id: "action:access", title: String(localized: "Choose Access…"),
                icon: symbol(ComposerMenus.symbolName(for: thread.accessMode)), trailing: keys(.accessMode),
                keywords: ["access", "permissions", "approval", "approve", "full access", "ask", "mode"],
                behavior: .submenu(accessMenu(thread))))
        let planning = thread.interactionMode == .plan
        let mode: InteractionMode = planning ? .build : .plan
        items.append(
            PaletteItem(
                id: "action:interaction-mode",
                title: planning ? String(localized: "Switch to Build Mode") : String(localized: "Switch to Plan Mode"),
                icon: symbol(planning ? "hammer" : "pencil.and.ruler"), trailing: keys(.planMode),
                keywords: ["plan", "build", "mode", "toggle"],
                behavior: .run { window?.splitController.content.chat.chooseInteractionMode(mode) }))
        for kind in registry.readyKinds where kind != thread.selection.provider {
            items.append(
                PaletteItem(
                    id: "action:agent:\(kind.rawValue)", title: String(localized: "Switch to \(kind.displayName)"),
                    icon: Theme.logo(for: kind, size: 15),
                    keywords: ["switch", "agent", "provider", "continue", "handoff", kind.rawValue],
                    behavior: .run { window?.splitController.content.chat.switchAgent(to: kind) }))
        }
        return items
    }

    /// Every model of the ready agents, grouped by agent, as in the composer's picker: favorites first, hidden ones left out.
    private func modelMenu(_ thread: ThreadSummary) -> PaletteMenu {
        let window = windowController
        let threadID = thread.id
        return PaletteMenu(title: String(localized: "Choose Agent and Model…"), placeholder: String(localized: "Search models…")) {
            let registry = ProviderRegistry.shared
            let current = AppStore.shared.summary(threadID)?.selection ?? thread.selection
            // One group per ready account; an agent with several accounts names each.
            let accounts = registry.readyKinds.flatMap { kind in
                let all = registry.accounts(for: kind)
                return all.filter { registry.status(kind, account: $0.id).state == .ready }.map { (kind, $0, all.count > 1) }
            }
            return accounts.map { kind, account, named in
                let isCurrentAccount = kind == current.provider && account.id == current.account
                var models = registry.pickerModels(for: kind, account: account.id, current: isCurrentAccount ? current : nil)
                if isCurrentAccount, !models.contains(where: { $0.modelID == current.modelID }) {
                    models.insert(ModelOption(provider: kind, modelID: current.modelID, displayName: current.modelID), at: 0)
                }
                let title = named ? "\(kind.displayName) · \(account.name)" : kind.displayName
                let items = models.map { model in
                    let selection = ModelSelection(
                        provider: model.provider, modelID: model.modelID, effort: model.defaultEffort, accountID: account.storedID)
                    let isCurrent = isCurrentAccount && model.modelID == current.modelID
                    return PaletteItem(
                        id: "model:\(account.id):\(model.id)", title: model.displayName,
                        subtitle: model.displayName != model.modelID && model.modelID != "default" ? model.modelID : nil,
                        icon: Theme.logo(for: kind, size: 15),
                        trailing: isCurrent ? String(localized: "Current") : nil,
                        keywords: [kind.displayName, kind.rawValue, model.modelID] + (named ? [account.name] : []),
                        behavior: .run { window?.splitController.content.chat.chooseModel(selection) })
                }
                return PaletteGroup(id: "models:\(kind.rawValue):\(account.id)", title: title, items: items)
            }
        }
    }

    private func effortMenu(_ thread: ThreadSummary, model: ModelOption) -> PaletteMenu {
        let window = windowController
        let selected = thread.selection.effort ?? model.defaultEffort
        return PaletteMenu(
            title: String(localized: "Choose Reasoning Effort…"), placeholder: String(localized: "Search reasoning efforts…")
        ) {
            let items = model.efforts.map { effort in
                PaletteItem(
                    id: "effort:\(effort)", title: ComposerMenus.effortTitle(effort),
                    subtitle: effort == model.defaultEffort ? String(localized: "Default") : nil,
                    icon: Theme.symbol("brain", size: 15), trailing: effort == selected ? String(localized: "Current") : nil,
                    keywords: [effort], behavior: .run { window?.splitController.content.chat.chooseEffort(effort) })
            }
            return [PaletteGroup(id: "efforts", title: String(localized: "Reasoning Effort"), items: items)]
        }
    }

    private func accessMenu(_ thread: ThreadSummary) -> PaletteMenu {
        let window = windowController
        let selected = thread.accessMode
        return PaletteMenu(title: String(localized: "Choose Access…"), placeholder: String(localized: "Search access modes…")) {
            let items = AccessMode.allCases.map { mode in
                PaletteItem(
                    id: "access:\(mode.rawValue)", title: mode.displayName, subtitle: ComposerMenus.summary(for: mode),
                    icon: Theme.symbol(ComposerMenus.symbolName(for: mode), size: 15),
                    trailing: mode == selected ? String(localized: "Current") : nil,
                    behavior: .run { window?.splitController.content.chat.chooseAccessMode(mode) })
            }
            return [PaletteGroup(id: "access", title: String(localized: "Access"), items: items)]
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
                    icon: Theme.symbol("folder", size: 15), iconTint: .secondaryLabelColor, keywords: [project.path],
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
            icon: Theme.symbol("folder.badge.plus", size: 15), iconTint: .secondaryLabelColor, kind: .project,
            completion: path.hasSuffix("/") ? path : path + "/", behavior: .run { ThreadActions.addProjects([url]) })
    }

    // MARK: Helpers

    private func symbol(_ name: String) -> NSImage? { Theme.symbol(name, size: 15) }
}
