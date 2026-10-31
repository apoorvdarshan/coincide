import AppKit
import CoincideKit
import CoincideRemoteKit
import Foundation

/// Coincide's Settings for Coincide Remote: every pane described the way the phone draws it (`RemoteSettingsSnapshot`),
/// and the changes it may make. A change is checked against the rows just described, so the phone can only set what
/// the Mac offers, with values the Mac accepts. Nothing secret is described: API keys, tokens, password-vault contents
/// and credential-bearing provider settings (executable paths, environments) stay on the Mac. What can't finish on the
/// phone (macOS permission grants, Keep Awake's administrator password, provider sign-in, editing instructions) shows
/// its live state and a step that brings up the right pane on the Mac.
extension RemoteStoreAdapter {
    /// What the catalog needs from the running app, replaced in tests.
    struct SettingsServices {
        var computerUsePermissions: () -> (accessibility: Bool, screenRecording: Bool)
        var showOnMac: (String) -> Void
        /// The browser profile Settings › Browser describes; a scratch one in tests.
        var browser: () -> BrowserProfile = { .shared }

        static var live: SettingsServices {
            SettingsServices(
                computerUsePermissions: {
                    let controller = ComputerUseController.shared
                    controller.refresh()
                    return (controller.accessibilityGranted, controller.screenRecordingGranted)
                },
                showOnMac: { page in
                    NSApp.activate()
                    if page.hasPrefix("provider."), let kind = ProviderKind(rawValue: String(page.dropFirst("provider.".count))) {
                        SettingsWindowController.shared.show(provider: kind)
                    } else {
                        SettingsWindowController.shared.show(section: SettingsSection(rawValue: page))
                    }
                })
        }
    }

    func settingsSnapshot() -> RemoteSettingsSnapshot { settingsCatalog().snapshot }

    /// Changes one setting the snapshot offers, after checking the value.
    func changeSetting(_ key: String, to value: RemoteSettingValue) throws {
        let catalog = settingsCatalog()
        guard let row = catalog.rows[key], let apply = catalog.setters[key] else {
            throw RemoteError(.notAllowed, String(localized: "That setting can’t be changed from here."))
        }
        guard row.isEnabled != false else {
            throw RemoteError(.notAllowed, String(localized: "That setting can’t be changed from here."))
        }
        switch row.kind {
        case .toggle:
            guard value.bool != nil else { throw RemoteError(.badRequest, "Expected on or off.") }
        case .choice:
            guard let id = value.string, row.options?.contains(where: { $0.id == id }) == true else {
                throw RemoteError(.badRequest, "Unknown option.")
            }
        case .number:
            guard let number = value.number, number.isFinite, number >= (row.minimum ?? -.infinity),
                number <= (row.maximum ?? .infinity)
            else { throw RemoteError(.badRequest, "Out of range.") }
        case .text:
            guard let text = value.string, text.count <= 200 else { throw RemoteError(.badRequest, "Text too long.") }
        default:
            throw RemoteError(.notAllowed, String(localized: "That setting can’t be changed from here."))
        }
        try apply(value)
    }

    /// Runs a row's action: one that finishes on the Mac brings up its pane there.
    func performSettingsAction(_ key: String) throws {
        let catalog = settingsCatalog()
        guard let action = catalog.actions[key] else {
            throw RemoteError(.notAllowed, String(localized: "That can’t be done from here."))
        }
        try action()
    }

    // MARK: Building

    struct SettingsCatalog {
        var snapshot = RemoteSettingsSnapshot()
        var rows: [String: RemoteSettingsRow] = [:]
        var setters: [String: (RemoteSettingValue) throws -> Void] = [:]
        var actions: [String: () throws -> Void] = [:]
    }

    private func settingsCatalog() -> SettingsCatalog {
        var catalog = SettingsCatalog()
        let settings = store.settings
        let store = self.store
        let show = settingsServices.showOnMac

        func toggle(_ key: String, _ title: String, _ detail: String? = nil, _ path: WritableKeyPath<AppSettings, Bool>,
                    enabled: Bool = true) -> RemoteSettingsRow
        {
            catalog.setters[key] = { value in store.updateSettings { $0[keyPath: path] = value.bool ?? false } }
            return RemoteSettingsRow(
                id: key, kind: .toggle, title: title, detail: detail, value: .bool(settings[keyPath: path]),
                isEnabled: enabled ? nil : false)
        }
        func choice<E: RawRepresentable & CaseIterable>(
            _ key: String, _ title: String, _ path: WritableKeyPath<AppSettings, E>, _ name: (E) -> String
        ) -> RemoteSettingsRow where E.RawValue == String {
            catalog.setters[key] = { value in
                guard let raw = value.string, E(rawValue: raw) != nil else { return }
                store.updateSettings { settings in
                    if let option = E(rawValue: raw) { settings[keyPath: path] = option }
                }
            }
            return RemoteSettingsRow(
                id: key, kind: .choice, title: title, value: .string(settings[keyPath: path].rawValue),
                options: E.allCases.map { RemoteSettingOption(id: $0.rawValue, title: name($0)) })
        }
        func showAction(_ key: String, _ title: String, page: String) -> RemoteSettingsRow {
            catalog.actions[key] = { show(page) }
            return RemoteSettingsRow(id: key, kind: .action, title: title, finishesOnMac: true)
        }
        func page(_ id: String, _ title: String, _ symbol: String, _ color: String, group: RemoteSettingsPage.Group = .app,
                  status: String? = nil, _ sections: [RemoteSettingsSection])
        {
            catalog.snapshot.pages.append(
                RemoteSettingsPage(
                    id: id, title: title, symbol: symbol, color: color, group: group, status: status,
                    sections: sections.filter { !$0.rows.isEmpty }))
        }

        // General
        catalog.setters["general.darkTheme"] = { value in
            guard let id = value.string else { return }
            store.updateSettings { $0.darkTheme = id }
        }
        catalog.setters["general.lightTheme"] = { value in
            guard let id = value.string else { return }
            store.updateSettings { $0.lightTheme = id }
        }
        catalog.setters["general.fontSize"] = { value in
            guard let size = value.number else { return }
            store.updateSettings { $0.fontSize = size }
        }
        catalog.setters["general.worktreeBranchPrefix"] = { value in
            store.updateSettings { $0.worktreeBranchPrefix = (value.string ?? "").trimmingCharacters(in: .whitespaces) }
        }
        catalog.setters["general.idleSessionTimeoutMinutes"] = { value in
            guard let minutes = value.number else { return }
            store.updateSettings { $0.idleSessionTimeoutMinutes = Int(minutes) }
        }
        let alwaysOn = settings.alwaysOn
        for (key, path) in [
            ("keepAwake.displayOffOnLidClose", \AppSettings.alwaysOn.displayOffOnLidClose),
            ("keepAwake.keepDisplaysOff", \AppSettings.alwaysOn.keepDisplaysOff),
            ("keepAwake.muteWhileClosed", \AppSettings.alwaysOn.muteWhileClosed),
        ] {
            catalog.setters[key] = { value in store.updateSettings { $0[keyPath: path] = value.bool ?? false } }
        }
        page("general", String(localized: "General"), "gearshape", "gray", [
            RemoteSettingsSection(id: "appearance", title: String(localized: "Appearance"), rows: [
                choice("general.appearance", String(localized: "Appearance"), \.appearance) { $0.displayName },
                RemoteSettingsRow(
                    id: "general.darkTheme", kind: .choice, title: String(localized: "Dark theme"), value: .string(settings.darkTheme),
                    options: AppTheme.dark.map { RemoteSettingOption(id: $0.id, title: $0.name) }),
                RemoteSettingsRow(
                    id: "general.lightTheme", kind: .choice, title: String(localized: "Light theme"), value: .string(settings.lightTheme),
                    options: AppTheme.light.map { RemoteSettingOption(id: $0.id, title: $0.name) }),
                RemoteSettingsRow(
                    id: "general.fontSize", kind: .number, title: String(localized: "Text size"), value: .number(settings.fontSize),
                    minimum: 10, maximum: 24, step: 1, unit: "pt"),
                choice("general.replyTypeface", String(localized: "Reply typeface"), \.replyTypeface) { $0.displayName },
                choice("general.userMessageSide", String(localized: "Your messages"), \.userMessageSide) { $0.displayName },
                choice("general.numberFormat", String(localized: "Number format"), \.numberFormat) { $0.displayName },
            ]),
            RemoteSettingsSection(id: "chat", title: String(localized: "Chat"), rows: [
                toggle("general.sendOnReturn", String(localized: "Send with Return"), nil, \.sendOnReturn),
                choice("general.followUpBehavior", String(localized: "While the agent works"), \.followUpBehavior) { $0.displayName },
                toggle("general.showReasoning", String(localized: "Show reasoning"), nil, \.showReasoning),
                toggle("general.generatesThreadTitles", String(localized: "Name threads with the agent"), nil, \.generatesThreadTitles),
                toggle(
                    "general.updatesThreadTitles", String(localized: "Keep titles up to date"), nil, \.updatesThreadTitles,
                    enabled: settings.generatesThreadTitles),
                toggle("general.newThreadStartsChat", String(localized: "New Thread starts a chat"), nil, \.newThreadStartsChat),
                toggle("general.confirmBeforeArchivingThreads", String(localized: "Ask before archiving"), nil, \.confirmBeforeArchivingThreads),
                toggle("general.confirmBeforeDeletingThreads", String(localized: "Ask before deleting"), nil, \.confirmBeforeDeletingThreads),
                toggle("general.notifyWhenInBackground", String(localized: "Notify when a turn finishes"), nil, \.notifyWhenInBackground),
                toggle("general.resumesAfterUsageLimit", String(localized: "Resume after the usage limit resets"), nil, \.resumesAfterUsageLimit),
            ]),
            RemoteSettingsSection(id: "agents", title: String(localized: "Agents"), rows: [
                toggle("general.checkpointsEnabled", String(localized: "Checkpoints before each turn"), nil, \.checkpointsEnabled),
                RemoteSettingsRow(
                    id: "general.worktreeBranchPrefix", kind: .text, title: String(localized: "Worktree branch prefix"),
                    value: .string(settings.worktreeBranchPrefix)),
                RemoteSettingsRow(
                    id: "general.idleSessionTimeoutMinutes", kind: .number, title: String(localized: "Stop idle agents after"),
                    value: .number(Double(settings.idleSessionTimeoutMinutes)), minimum: 5, maximum: 240, step: 5,
                    unit: String(localized: "min")),
                toggle("general.commandLineControl", String(localized: "Command-line control"), nil, \.commandLineControl),
                toggle("general.opensLinksInDefaultBrowser", String(localized: "Open links in the default browser"), nil, \.opensLinksInDefaultBrowser),
                toggle("general.holdToQuit", String(localized: "Hold ⌘Q to quit"), nil, \.holdToQuit),
                toggle("general.checksForAppUpdates", String(localized: "Check for updates"), nil, \.checksForAppUpdates),
            ]),
            RemoteSettingsSection(id: "terminal", title: String(localized: "Terminal"), rows: [
                choice("general.terminalPlacement", String(localized: "Terminal"), \.terminalPlacement) { $0.displayName },
                toggle("general.terminalGPURendering", String(localized: "GPU rendering"), nil, \.terminalGPURendering),
                toggle("general.terminalTranslucentBackground", String(localized: "Translucent terminal"), nil, \.terminalTranslucentBackground),
            ]),
            RemoteSettingsSection(
                id: "keepAwake", title: String(localized: "Keep Awake"),
                footer: String(localized: "Turning Keep Awake on or off asks for your Mac’s password, so finish it there."),
                rows: [
                    RemoteSettingsRow(
                        id: "keepAwake.status", kind: .status, title: String(localized: "Keep this Mac awake 24/7"),
                        detail: alwaysOn.enabled ? String(localized: "This Mac stays awake, lid closed too") : String(localized: "Off"),
                        state: alwaysOn.enabled ? "ok" : "off"),
                    showAction("keepAwake.open", String(localized: "Turn On or Off on Your Mac"), page: "general"),
                    RemoteSettingsRow(
                        id: "keepAwake.displayOffOnLidClose", kind: .toggle, title: String(localized: "Turn the display off when the lid closes"),
                        value: .bool(alwaysOn.displayOffOnLidClose)),
                    RemoteSettingsRow(
                        id: "keepAwake.keepDisplaysOff", kind: .toggle, title: String(localized: "Keep displays off while the lid is closed"),
                        value: .bool(alwaysOn.keepDisplaysOff)),
                    RemoteSettingsRow(
                        id: "keepAwake.muteWhileClosed", kind: .toggle, title: String(localized: "Mute sound while the lid is closed"),
                        value: .bool(alwaysOn.muteWhileClosed)),
                ]),
        ])

        // Models
        let enabled = registry.orderedKinds.filter { settings.settings(for: $0).isEnabled }
        catalog.setters["models.defaultProvider"] = { [registry] value in
            guard let raw = value.string, let kind = ProviderKind(rawValue: raw) else { return }
            let model = registry.pickerModels(for: kind, current: nil).first?.modelID ?? "default"
            store.updateSettings { $0.defaultSelection = ModelSelection(provider: kind, modelID: model) }
        }
        catalog.setters["models.defaultModel"] = { value in
            guard let id = value.string else { return }
            store.updateSettings { $0.defaultSelection = ModelSelection(provider: $0.defaultSelection.provider, modelID: id) }
        }
        let models = registry.pickerModels(for: settings.defaultSelection.provider, current: nil)
        page("models", String(localized: "Models"), "cube", "purple", [
            RemoteSettingsSection(id: "defaults", title: String(localized: "New threads"), rows: [
                RemoteSettingsRow(
                    id: "models.defaultProvider", kind: .choice, title: String(localized: "Agent"),
                    value: .string(settings.defaultSelection.provider.rawValue),
                    options: enabled.map { RemoteSettingOption(id: $0.rawValue, title: $0.displayName) }),
                RemoteSettingsRow(
                    id: "models.defaultModel", kind: .choice, title: String(localized: "Model"),
                    value: .string(settings.defaultSelection.modelID),
                    options: models.map { RemoteSettingOption(id: $0.modelID, title: $0.displayName) }),
                choice("models.defaultAccessMode", String(localized: "Access"), \.defaultAccessMode) { $0.displayName },
            ]),
            RemoteSettingsSection(
                id: "lists", title: String(localized: "Model picker"),
                footer: String(localized: "Star the models you use most, or hide the ones you never pick."),
                rows: registry.orderedKinds.filter { !registry.models(for: $0).isEmpty }.map { kind in
                    let models = registry.models(for: kind)
                    let favorites = models.filter { settings.favoriteModels.contains($0.reference) }.count
                    let hidden = models.filter { settings.hiddenModels.contains($0.reference) }.count
                    var detail = [String(localized: "\(models.count) models")]
                    if favorites > 0 { detail.append(String(localized: "\(favorites) starred")) }
                    if hidden > 0 { detail.append(String(localized: "\(hidden) hidden")) }
                    return RemoteSettingsRow(
                        id: "models.list.\(kind.rawValue)", kind: .page, title: kind.displayName,
                        detail: detail.joined(separator: " · "), target: "models.\(kind.rawValue)")
                }),
        ])
        for kind in registry.orderedKinds {
            let models = Array(registry.models(for: kind).prefix(Self.maxListedModels))
            guard !models.isEmpty else { continue }
            var favoriteRows: [RemoteSettingsRow] = []
            var shownRows: [RemoteSettingsRow] = []
            for model in models {
                let reference = model.reference
                let key = "\(kind.rawValue)/\(model.modelID)"
                catalog.setters["models.favorite.\(key)"] = { value in
                    store.updateSettings { $0.setFavorite(value.bool ?? false, reference) }
                }
                catalog.setters["models.shown.\(key)"] = { value in
                    store.updateSettings { $0.setHidden(!(value.bool ?? true), reference) }
                }
                favoriteRows.append(
                    RemoteSettingsRow(
                        id: "models.favorite.\(key)", kind: .toggle, title: model.displayName,
                        value: .bool(settings.favoriteModels.contains(reference))))
                shownRows.append(
                    RemoteSettingsRow(
                        id: "models.shown.\(key)", kind: .toggle, title: model.displayName,
                        value: .bool(!settings.hiddenModels.contains(reference))))
            }
            page("models.\(kind.rawValue)", kind.displayName, "cube", "purple", group: .detail, [
                RemoteSettingsSection(
                    id: "favorites", title: String(localized: "Favorites"),
                    footer: String(localized: "Starred models come first in the model picker."), rows: favoriteRows),
                RemoteSettingsSection(
                    id: "shown", title: String(localized: "In the model picker"),
                    footer: String(localized: "Hidden models stay out of the model picker until you show them again."), rows: shownRows),
            ])
        }

        // Usage
        page("usage", String(localized: "Usage"), "chart.bar.fill", "green", [
            RemoteSettingsSection(id: "limits", rows: [RemoteSettingsRow(id: "usage.limits", kind: .usage, title: String(localized: "Usage Limits"))]),
            RemoteSettingsSection(id: "display", rows: [
                choice("usage.displayMode", String(localized: "Show"), \.usageDisplayMode) {
                    $0 == .used ? String(localized: "Used") : String(localized: "Left")
                },
                choice("usage.refresh", String(localized: "Refresh"), \.usageRefresh) { Self.refreshName($0) },
                toggle("usage.menuBar", String(localized: "Show usage in the menu bar"), nil, \.showsUsageInMenuBar),
                toggle("usage.otherSessions", String(localized: "Include sessions outside Coincide"), nil, \.usageIncludesOtherSessions),
            ]),
        ])

        // Instructions
        let instructionFiles = instructions.files
        page("instructions", String(localized: "Instructions"), "text.document", "teal", [
            RemoteSettingsSection(
                id: "files", title: String(localized: "Files"),
                footer: String(localized: "The global instruction files every agent reads, in every project."),
                rows: instructionFiles.map { file in
                    RemoteSettingsRow(id: file.key, kind: .document, title: file.title, detail: file.detail)
                }),
            RemoteSettingsSection(
                id: "instructions", footer: String(localized: "Linking files to a master and copying it to iCloud or a repository happen on your Mac."),
                rows: [showAction("instructions.open", String(localized: "Open Instructions on Your Mac"), page: "instructions")]),
        ])

        // Archive
        let archived = store.threadSummaries.values.filter(\.isArchived).sorted { $0.updatedAt > $1.updatedAt }.prefix(100)
        var archiveRows: [RemoteSettingsRow] = []
        for thread in archived {
            let key = "archive.restore.\(thread.id.uuidString)"
            catalog.actions[key] = { [weak self] in try self?.perform(.archive(false), on: thread.id) }
            archiveRows.append(
                RemoteSettingsRow(
                    id: key, kind: .action, title: thread.title,
                    detail: thread.updatedAt.formatted(date: .abbreviated, time: .shortened), action: String(localized: "Restore")))
        }
        if archiveRows.isEmpty {
            archiveRows = [RemoteSettingsRow(id: "archive.empty", kind: .info, title: String(localized: "No archived threads"))]
        }
        page("archive", String(localized: "Archive"), "archivebox", "brown", [RemoteSettingsSection(id: "threads", rows: archiveRows)])

        // Keyboard
        let bindings = KeyBindings(overrides: settings.shortcutOverrides)
        page("keyboard", String(localized: "Keyboard"), "keyboard", "gray", [
            RemoteSettingsSection(
                id: "shortcuts", footer: String(localized: "Change shortcuts on your Mac."),
                rows: KeyCommand.allCases.map { command in
                    RemoteSettingsRow(
                        id: "keyboard.\(command.rawValue)", kind: .info, title: command.title,
                        detail: bindings.shortcut(for: command)?.displayString ?? String(localized: "None"))
                }),
        ])

        // Browser
        let browser = settingsServices.browser()
        let browserSettings = browser.settings.settings
        catalog.setters["browser.privateSessions"] = { value in browser.settings.update { $0.usesPrivateSessions = value.bool ?? false } }
        catalog.setters["browser.agentControl"] = { value in browser.settings.update { $0.agentControlByDefault = value.bool ?? true } }
        catalog.setters["browser.searchEngine"] = { value in
            guard let engine = value.string.flatMap(SearchEngine.init(rawValue:)) else { return }
            browser.settings.update { $0.searchEngine = engine }
        }
        catalog.actions["browser.clearHistory"] = { Task { await browser.clear(siteData: false, history: true) } }
        catalog.actions["browser.clearSiteData"] = {
            Task {
                await browser.clear(siteData: true, history: false)
                PreviewSessions.shared.resetSessions()
            }
        }
        var bookmarkRows: [RemoteSettingsRow] = []
        for bookmark in browser.library.bookmarks.prefix(Self.maxListedBookmarks) {
            let key = "browser.bookmark.remove.\(bookmark.id.uuidString)"
            catalog.actions[key] = { browser.library.removeBookmarks { $0.id == bookmark.id } }
            // The host alone: a bookmark's path and query can carry what a page put there.
            bookmarkRows.append(
                RemoteSettingsRow(
                    id: key, kind: .action, title: bookmark.title.isEmpty ? (URL(string: bookmark.url)?.host() ?? bookmark.url) : bookmark.title,
                    detail: URL(string: bookmark.url)?.host(), action: String(localized: "Remove"), isDestructive: true))
        }
        if bookmarkRows.isEmpty {
            bookmarkRows = [
                RemoteSettingsRow(id: "browser.bookmarks.none", kind: .info, title: String(localized: "Bookmark a page with the star in the browser’s address bar."))
            ]
        }
        page("browser", String(localized: "Browser"), "globe", "cyan", [
            RemoteSettingsSection(
                id: "profile", title: String(localized: "Profile"),
                footer: String(localized: "Cookies and site data include sign-ins in the shared browser profile; pages open in threads reload. Bookmarks are kept."),
                rows: [
                    RemoteSettingsRow(
                        id: "browser.privateSessions", kind: .toggle, title: String(localized: "Use private sessions"),
                        detail: String(localized: "Each thread starts signed out, and forgets its cookies when it closes."),
                        value: .bool(browserSettings.usesPrivateSessions)),
                    RemoteSettingsRow(
                        id: "browser.searchEngine", kind: .choice, title: String(localized: "Search engine"),
                        value: .string(browserSettings.searchEngine.rawValue),
                        options: SearchEngine.allCases.map { RemoteSettingOption(id: $0.rawValue, title: $0.name) }),
                    RemoteSettingsRow(
                        id: "browser.history", kind: .info, title: String(localized: "History items"),
                        detail: browser.library.history.count.formatted()),
                    RemoteSettingsRow(
                        id: "browser.clearHistory", kind: .action, title: String(localized: "Clear History"), isDestructive: true),
                    RemoteSettingsRow(
                        id: "browser.clearSiteData", kind: .action, title: String(localized: "Clear Cookies and Site Data"), isDestructive: true),
                ]),
            RemoteSettingsSection(
                id: "agents", title: String(localized: "Agents"),
                footer: String(localized: "Agents can’t read cookies, site storage or what’s typed in password fields, and ask you to take over for sign-ins, CAPTCHAs and two-factor codes."),
                rows: [
                    RemoteSettingsRow(
                        id: "browser.agentControl", kind: .toggle, title: String(localized: "Agent Control in new threads"),
                        detail: String(localized: "Agents can use their thread’s browser in the background and open it when they need you."),
                        value: .bool(browserSettings.agentControlByDefault))
                ]),
            RemoteSettingsSection(id: "bookmarks", title: String(localized: "Bookmarks"), rows: bookmarkRows),
            RemoteSettingsSection(
                id: "browser", title: String(localized: "Passwords and Imports"),
                footer: String(localized: "Password managers, saved logins and browser imports stay on your Mac."),
                rows: [showAction("browser.open", String(localized: "Open Browser Settings on Your Mac"), page: "browser")]),
        ])

        // Computer Use
        let permissions = settingsServices.computerUsePermissions()
        page("computerUse", String(localized: "Computer Use"), "desktopcomputer", "blue", [
            RemoteSettingsSection(id: "computerUse", rows: [
                toggle("computerUse.enabled", String(localized: "Allow agents to use this Mac"), nil, \.computerUseEnabled),
                toggle("computerUse.cursor", String(localized: "Show agent cursor"), nil, \.computerUseShowsAgentCursor),
            ]),
            RemoteSettingsSection(
                id: "permissions", title: String(localized: "Permissions"),
                footer: String(localized: "macOS asks for these on the Mac itself."),
                rows: [
                    RemoteSettingsRow(
                        id: "computerUse.accessibility", kind: .status, title: String(localized: "Accessibility"),
                        detail: permissions.accessibility ? String(localized: "Allowed") : String(localized: "Not allowed"),
                        state: permissions.accessibility ? "ok" : "warning"),
                    RemoteSettingsRow(
                        id: "computerUse.screenRecording", kind: .status, title: String(localized: "Screen Recording"),
                        detail: permissions.screenRecording ? String(localized: "Allowed") : String(localized: "Not allowed"),
                        state: permissions.screenRecording ? "ok" : "warning"),
                    showAction("computerUse.open", String(localized: "Grant on Your Mac"), page: "computerUse"),
                ]),
        ])

        // Providers
        var overview: [RemoteSettingsRow] = []
        var providerPages: [(String, ProviderKind, String)] = []
        for kind in registry.orderedKinds {
            let isOn = settings.settings(for: kind).isEnabled
            let ready = registry.status(kind).state.rawValue == "ready"
            let status = !isOn ? "off" : ready ? "ready" : "attention"
            let id = "provider.\(kind.rawValue)"
            overview.append(
                RemoteSettingsRow(
                    id: "providers.\(kind.rawValue)", kind: .page, title: kind.displayName, detail: Self.statusName(status),
                    state: status, target: id))
            providerPages.append((id, kind, status))
        }
        page("providers", String(localized: "Overview"), "square.grid.2x2", "indigo", [RemoteSettingsSection(id: "agents", rows: overview)])
        for (id, kind, status) in providerPages {
            let key = "\(id).enabled"
            catalog.setters[key] = { value in
                store.updateSettings { settings in
                    var provider = settings.settings(for: kind)
                    provider.isEnabled = value.bool ?? false
                    settings.providers[kind] = provider
                }
            }
            catalog.actions["\(id).open"] = { show(id) }
            let accounts = registry.accounts(for: kind).map { account in
                RemoteSettingsRow(
                    id: "\(id).account.\(account.id)", kind: .info, title: account.name,
                    detail: registry.status(kind, account: account.id).state == .ready
                        ? String(localized: "Signed in") : String(localized: "Needs sign-in"))
            }
            page(id, kind.displayName, "sparkles", "indigo", group: .provider, status: status, [
                RemoteSettingsSection(id: "state", rows: [
                    RemoteSettingsRow(
                        id: key, kind: .toggle, title: String(localized: "Use \(kind.displayName)"),
                        value: .bool(settings.settings(for: kind).isEnabled)),
                    RemoteSettingsRow(
                        id: "\(id).status", kind: .status, title: String(localized: "Status"), detail: Self.statusName(status),
                        state: status == "ready" ? "ok" : status == "off" ? "off" : "warning"),
                ]),
                RemoteSettingsSection(id: "accounts", title: String(localized: "Accounts"), rows: accounts),
                RemoteSettingsSection(
                    id: "setup", footer: String(localized: "Signing in and setup happen in the agent’s own window on your Mac."),
                    rows: [RemoteSettingsRow(id: "\(id).open", kind: .action, title: String(localized: "Set Up on Your Mac"), finishesOnMac: true)]),
            ])
        }

        // About
        let info = Bundle.main.infoDictionary ?? [:]
        let os = ProcessInfo.processInfo.operatingSystemVersion
        page("about", String(localized: "About"), "info.circle", "blue", group: .about, [
            RemoteSettingsSection(id: "version", rows: [
                RemoteSettingsRow(
                    id: "about.version", kind: .info, title: "Coincide",
                    detail: "\(info["CFBundleShortVersionString"] as? String ?? "0") (\(info["CFBundleVersion"] as? String ?? "0"))"),
                RemoteSettingsRow(
                    id: "about.macos", kind: .info, title: "macOS", detail: "\(os.majorVersion).\(os.minorVersion).\(os.patchVersion)"),
            ]),
        ])

        catalog.rows = RemoteSettingsRow.index(catalog.snapshot)
        return catalog
    }

    /// Most models listed per agent, and bookmarks in Browser; the rest stay on the Mac's own panes.
    static let maxListedModels = 80
    static let maxListedBookmarks = 50

    nonisolated static func statusName(_ status: String) -> String {
        switch status {
        case "ready": String(localized: "Ready")
        case "off": String(localized: "Off")
        default: String(localized: "Needs setup")
        }
    }

    nonisolated static func refreshName(_ interval: UsageRefreshInterval) -> String {
        switch interval {
        case .automatic: String(localized: "Automatically")
        case .everyMinute: String(localized: "Every minute")
        case .every5Minutes: String(localized: "Every 5 minutes")
        case .every15Minutes: String(localized: "Every 15 minutes")
        case .every30Minutes: String(localized: "Every 30 minutes")
        case .everyHour: String(localized: "Every hour")
        case .manual: String(localized: "Manually")
        }
    }
}
