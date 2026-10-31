#if DEBUG
import CoincideRemoteKit
import Foundation
import UIKit

/// Sample threads for screenshots and layout checks in the simulator, with no Mac: launch with `-CoincideRemoteDemo`.
/// Debug builds only.
enum DemoData {
    static var isEnabled: Bool { ProcessInfo.processInfo.arguments.contains("-CoincideRemoteDemo") }

    static let projectID = UUID(uuidString: "11111111-1111-1111-1111-111111111111")!
    static let otherProjectID = UUID(uuidString: "22222222-2222-2222-2222-222222222222")!
    static let chatsID = UUID(uuidString: "33333333-3333-3333-3333-333333333333")!
    static let threadID = UUID(uuidString: "44444444-4444-4444-4444-444444444444")!
    static let botsID = UUID(uuidString: "B0B5B0B5-C01C-4D1E-B075-000000000001")!
    static let bruleeThreadID = UUID(uuidString: "55555555-5555-5555-5555-555555555555")!

    /// `-CoincideRemoteDemoTheme <dark id> <light id>` follows other Mac themes than Carbon.
    static var server: RemoteServerInfo {
        let arguments = ProcessInfo.processInfo.arguments
        var theme = RemoteThemeInfo()
        if let index = arguments.firstIndex(of: "-CoincideRemoteDemoTheme"), index + 2 < arguments.count {
            theme = RemoteThemeInfo(darkThemeID: arguments[index + 1], lightThemeID: arguments[index + 2])
        }
        return RemoteServerInfo(serverID: "demo", name: "Apoorv’s MacBook Pro", appVersion: "0.1.0", theme: theme)
    }

    static var mac: SavedMac {
        SavedMac(
            serverID: "demo", name: "Apoorv’s MacBook Pro", hosts: [RemoteHostCandidate(host: "192.168.1.20", kind: .lan)],
            port: RemoteProtocol.defaultPort, fingerprint: String(repeating: "0", count: 64), deviceID: "demo", pairedAt: Date())
    }

    /// `-CoincideRemoteDemoOldMac` sends what a Mac from before bot characters, synced project expansion and turn
    /// timers sends.
    static var isOldMac: Bool { ProcessInfo.processInfo.arguments.contains("-CoincideRemoteDemoOldMac") }

    static func has(_ flag: String) -> Bool { ProcessInfo.processInfo.arguments.contains("-CoincideRemoteDemo" + flag) }

    /// The argument after `name`, such as `-CoincideRemoteSettingsPane general`.
    static func value(after name: String) -> String? {
        let arguments = ProcessInfo.processInfo.arguments
        guard let index = arguments.firstIndex(of: name), index + 1 < arguments.count else { return nil }
        return arguments[index + 1]
    }

    /// The connection's state: `-CoincideRemoteDemoOffline`, `…Connecting` or `…NeedsPairing` show those banners.
    static var phase: RemoteClient.Phase {
        if has("Offline") {
            return .offline("Apoorv’s MacBook Pro isn’t reachable. Make sure Coincide is open with Remote turned on.")
        }
        if has("Connecting") { return .connecting(server.name) }
        if has("NeedsPairing") { return .needsPairing("Apoorv’s MacBook Pro removed this device. Pair it again to connect.") }
        return .connected(server.name)
    }

    /// `-CoincideRemoteDemoEmpty`: a Mac with no projects, chats or bots yet. `-CoincideRemoteDemoConnecting` before the
    /// first workspace arrives looks the same.
    static var isEmpty: Bool { has("Empty") || has("Connecting") }

    static var workspace: RemoteWorkspace {
        if isEmpty {
            return RemoteWorkspace(
                projects: [RemoteProject(id: chatsID, name: "Chats", path: "~/Library/Application Support/Coincide", isChats: true)],
                threads: [], bots: [], providers: [], pinnedOrder: [])
        }
        return fullWorkspace
    }

    private static var fullWorkspace: RemoteWorkspace {
        let claude = RemoteSelection(provider: "claude", modelID: "opus", modelName: "Opus", effort: "high")
        let codex = RemoteSelection(provider: "codex", modelID: "gpt", modelName: "GPT-6.1-Sol", effort: "medium", speed: "priority")
        let grok = RemoteSelection(provider: "grok", modelID: "grok", modelName: "Grok 4.7")
        let antigravity = RemoteSelection(provider: "antigravity", modelID: "gemini", modelName: "Gemini 3.5 Pro")
        let old = isOldMac
        let pins = ProcessInfo.processInfo.arguments.contains("-CoincideRemoteDemoPinned")
        // `-CoincideRemoteDemoCollapsed`: every project folded up, as on a Mac whose sidebar shows only folders.
        let collapsed = has("Collapsed")
        let now = Date()
        func thread(_ title: String, _ project: UUID, _ selection: RemoteSelection, minutes: Double, id: UUID = UUID(),
                    pinned: Bool = false, running: Bool = false, approvals: Int = 0, unseen: String? = nil) -> RemoteThreadSummary {
            RemoteThreadSummary(
                id: id, projectID: project, title: title, updatedAt: now.addingTimeInterval(-minutes * 60), selection: selection,
                isPinned: pinned, branch: "main", isRunning: running, pendingApprovals: approvals, unseen: unseen, itemCount: 8,
                runningSince: running && !old ? now.addingTimeInterval(-41) : nil, hasBackgroundWork: old ? nil : false)
        }
        let versionsID = UUID(uuidString: "99999999-9999-9999-9999-999999999999")!
        return RemoteWorkspace(
            projects: [
                RemoteProject(
                    id: projectID, name: "coincide", path: "~/coincide",
                    scripts: [RemoteScript(id: UUID(), name: "Tests", command: "xcodebuild test", icon: "test")],
                    isExpanded: old ? nil : !collapsed),
                RemoteProject(id: otherProjectID, name: "fud-ai", path: "~/fud-ai", isExpanded: old ? nil : false),
                RemoteProject(id: versionsID, name: "verceltics", path: "~/verceltics", isExpanded: old ? nil : false),
                RemoteProject(id: chatsID, name: "Chats", path: "~/Library/Application Support/Coincide", isChats: true),
            ],
            threads: [
                thread("Release checklist", otherProjectID, codex, minutes: 300, pinned: pins),
                thread("iPhone image previews in threads", projectID, claude, minutes: 1, id: threadID, running: true),
                thread("Fix stale transcript row heights", projectID, codex, minutes: 25, unseen: "completed"),
                thread("Run git push for the remote branch", projectID, claude, minutes: 50, approvals: 1),
                thread("Paywall copy for annual plan", otherProjectID, codex, minutes: 60 * 26, unseen: "failed"),
                thread("Usage chart by project", versionsID, claude, minutes: 60 * 72),
                thread("New thread", chatsID, claude, minutes: 60 * 6),
                thread("Remove Agent Browser from profile", chatsID, codex, minutes: 60 * 7),
                thread("Generate a dog image", chatsID, codex, minutes: 60 * 7.2),
                thread("Diagnose Mac heat and resource use", chatsID, codex, minutes: 60 * 18),
                thread("Check the TetherShot connection", chatsID, codex, minutes: 60 * 19),
                thread("Clarify son reference", chatsID, codex, minutes: 60 * 21),
                thread("yo", chatsID, grok, minutes: 60 * 21.3),
                thread("New thread", chatsID, claude, minutes: 60 * 23),
                thread("Greeting and session start", chatsID, claude, minutes: 60 * 30),
                thread("Bajaj Finance loan details review", chatsID, claude, minutes: 60 * 36),
                thread("Greeting and session start", chatsID, claude, minutes: 60 * 50),
                thread("Restore Spotify to profile", chatsID, claude, minutes: 60 * 52),
                thread("Monthly AI token usage per provider", chatsID, claude, minutes: 60 * 54),
                thread("yo", chatsID, antigravity, minutes: 60 * 56),
                thread("Plan my Saturday", botsID, claude, minutes: 12, id: bruleeThreadID, unseen: "completed"),
            ],
            bots: [
                RemoteBot(
                    id: UUID(uuidString: "66666666-6666-6666-6666-666666666666")!, name: "Brulee", projectID: botsID,
                    threadIDs: [bruleeThreadID], avatar: old ? nil : RemoteBotAvatar(.brulee, .rose),
                    persona: old ? nil : "Friendly and brief.", selection: old ? nil : claude, accessMode: old ? nil : "approval",
                    interactionMode: old ? nil : "build"),
                RemoteBot(
                    id: UUID(uuidString: "77777777-7777-7777-7777-777777777777")!, name: old ? "Researcher" : "Teddy", projectID: botsID,
                    avatar: old ? nil : RemoteBotAvatar(.teddy, .caramel), selection: old ? nil : codex,
                    accessMode: old ? nil : "approval", interactionMode: old ? nil : "build"),
            ],
            providers: [
                RemoteProvider(
                    id: "claude", name: "Claude Code", state: "ready", accounts: [RemoteAccount(id: "default", name: "Default", isReady: true)],
                    models: [
                        RemoteModel(id: "opus", name: "Claude Opus", efforts: ["low", "medium", "high", "max"], defaultEffort: "high"),
                        RemoteModel(id: "sonnet", name: "Claude Sonnet", efforts: ["low", "medium", "high"]),
                    ]),
                RemoteProvider(
                    id: "codex", name: "Codex", state: "ready", accounts: [RemoteAccount(id: "default", name: "Default", isReady: true)],
                    models: [
                        RemoteModel(
                            id: "gpt", name: "GPT-5.5", efforts: ["low", "medium", "high"], defaultEffort: "medium",
                            speeds: [RemoteSpeed(id: "priority", name: "Fast")])
                    ]),
            ],
            pinnedOrder: [], sidebar: old ? nil : RemoteSidebarOptions(threadsPerProject: has("FewThreads") ? 2 : nil))
    }

    /// The Mac's Settings as its catalog (`RemoteSettingsCatalog`) describes them, abridged.
    static var macSettings: RemoteSettingsSnapshot {
        func toggle(_ id: String, _ title: String, _ on: Bool, detail: String? = nil) -> RemoteSettingsRow {
            RemoteSettingsRow(id: id, kind: .toggle, title: title, detail: detail, value: .bool(on))
        }
        func choice(_ id: String, _ title: String, _ value: String, _ options: [(String, String)]) -> RemoteSettingsRow {
            RemoteSettingsRow(
                id: id, kind: .choice, title: title, value: .string(value),
                options: options.map { RemoteSettingOption(id: $0.0, title: $0.1) })
        }
        func onMac(_ id: String, _ title: String) -> RemoteSettingsRow {
            RemoteSettingsRow(id: id, kind: .action, title: title, finishesOnMac: true)
        }
        let themes = RemotePalette.dark.map { ($0.id, $0.name) }
        let lightThemes = RemotePalette.light.map { ($0.id, $0.name) }
        let agents = [("claude", "Claude Code"), ("codex", "Codex"), ("cursor", "Cursor"), ("grok", "Grok Build"),
                      ("opencode", "OpenCode"), ("antigravity", "Antigravity")]
        var pages = [
            RemoteSettingsPage(id: "general", title: "General", symbol: "gearshape", color: "gray", sections: [
                RemoteSettingsSection(id: "appearance", title: "Appearance", rows: [
                    choice("general.appearance", "Appearance", "system", [("system", "System"), ("light", "Light"), ("dark", "Dark")]),
                    choice("general.darkTheme", "Dark theme", "carbon", themes),
                    choice("general.lightTheme", "Light theme", "carbon-light", lightThemes),
                    RemoteSettingsRow(
                        id: "general.fontSize", kind: .number, title: "Text size", value: .number(13), minimum: 10, maximum: 24,
                        step: 1, unit: "pt"),
                    choice("general.replyTypeface", "Reply typeface", "serif", [("serif", "New York"), ("system", "System")]),
                    choice("general.userMessageSide", "Your messages", "right", [("right", "On the right"), ("left", "On the left")]),
                ]),
                RemoteSettingsSection(id: "chat", title: "Chat", rows: [
                    toggle("general.sendOnReturn", "Send with Return", true),
                    choice("general.followUpBehavior", "While the agent works", "steer", [("steer", "Steer"), ("queue", "Queue")]),
                    toggle("general.showReasoning", "Show reasoning", true),
                    toggle("general.generatesThreadTitles", "Name threads with the agent", true),
                    toggle("general.notifyWhenInBackground", "Notify when a turn finishes", true),
                ]),
                RemoteSettingsSection(id: "agents", title: "Agents", rows: [
                    toggle("general.checkpointsEnabled", "Checkpoints before each turn", true),
                    RemoteSettingsRow(
                        id: "general.worktreeBranchPrefix", kind: .text, title: "Worktree branch prefix", value: .string("coincide/")),
                    RemoteSettingsRow(
                        id: "general.idleSessionTimeoutMinutes", kind: .number, title: "Stop idle agents after", value: .number(30),
                        minimum: 5, maximum: 240, step: 5, unit: "min"),
                ]),
                RemoteSettingsSection(
                    id: "keepAwake", title: "Keep Awake", footer: "Turning Keep Awake on or off asks for your Mac’s password, so finish it there.",
                    rows: [
                        RemoteSettingsRow(
                            id: "keepAwake.status", kind: .status, title: "Keep this Mac awake 24/7",
                            detail: "This Mac stays awake, lid closed too", state: "ok"),
                        onMac("keepAwake.open", "Turn On or Off on Your Mac"),
                        toggle("keepAwake.displayOffOnLidClose", "Turn the display off when the lid closes", true),
                    ]),
            ]),
            RemoteSettingsPage(id: "models", title: "Models", symbol: "cube", color: "purple", sections: [
                RemoteSettingsSection(id: "defaults", title: "New threads", rows: [
                    choice("models.defaultProvider", "Agent", "claude", Array(agents.prefix(2))),
                    choice("models.defaultModel", "Model", "opus", [("opus", "Claude Opus"), ("sonnet", "Claude Sonnet")]),
                    choice("models.defaultAccessMode", "Access", "fullAccess", [("fullAccess", "Full access"), ("approval", "Ask for approval")]),
                ]),
                RemoteSettingsSection(
                    id: "lists", title: "Model picker", footer: "Star the models you use most, or hide the ones you never pick.",
                    rows: [
                        RemoteSettingsRow(
                            id: "models.list.claude", kind: .page, title: "Claude Code", detail: "4 models · 1 starred",
                            target: "models.claude"),
                        RemoteSettingsRow(
                            id: "models.list.codex", kind: .page, title: "Codex", detail: "6 models · 2 hidden", target: "models.codex"),
                    ]),
            ]),
            RemoteSettingsPage(id: "models.claude", title: "Claude Code", symbol: "cube", color: "purple", group: .detail, sections: [
                RemoteSettingsSection(
                    id: "favorites", title: "Favorites", footer: "Starred models come first in the model picker.",
                    rows: [("opus", "Claude Opus", true), ("sonnet", "Claude Sonnet", false), ("haiku", "Claude Haiku", false)].map {
                        toggle("models.favorite.claude/\($0.0)", $0.1, $0.2)
                    }),
                RemoteSettingsSection(
                    id: "shown", title: "In the model picker",
                    footer: "Hidden models stay out of the model picker until you show them again.",
                    rows: [("opus", "Claude Opus", true), ("sonnet", "Claude Sonnet", true), ("haiku", "Claude Haiku", false)].map {
                        toggle("models.shown.claude/\($0.0)", $0.1, $0.2)
                    }),
            ]),
            RemoteSettingsPage(id: "usage", title: "Usage", symbol: "chart.bar.fill", color: "green", sections: [
                RemoteSettingsSection(id: "limits", rows: [RemoteSettingsRow(id: "usage.limits", kind: .usage, title: "Usage Limits")]),
                RemoteSettingsSection(id: "display", rows: [
                    choice("usage.displayMode", "Show", "used", [("used", "Used"), ("left", "Left")]),
                    toggle("usage.menuBar", "Show usage in the menu bar", true),
                ]),
            ]),
            RemoteSettingsPage(id: "instructions", title: "Instructions", symbol: "text.document", color: "teal", sections: [
                RemoteSettingsSection(
                    id: "files", title: "Files", footer: "The global instruction files every agent reads, in every project.",
                    rows: [
                        RemoteSettingsRow(
                            id: "instructions.file./Users/apoorv/.config/coincide/AGENTS.md", kind: .document,
                            title: "~/.config/coincide/AGENTS.md", detail: "Master · Claude Code, Codex, Cursor and OpenCode"),
                        RemoteSettingsRow(
                            id: "instructions.file./Users/apoorv/.gemini/GEMINI.md", kind: .document, title: "~/.gemini/GEMINI.md",
                            detail: "Antigravity · Not created yet"),
                    ]),
                RemoteSettingsSection(
                    id: "instructions", footer: "Linking files to a master and copying it to iCloud or a repository happen on your Mac.",
                    rows: [onMac("instructions.open", "Open Instructions on Your Mac")]),
            ]),
            RemoteSettingsPage(id: "archive", title: "Archive", symbol: "archivebox", color: "brown", sections: [
                RemoteSettingsSection(id: "threads", rows: [
                    RemoteSettingsRow(
                        id: "archive.restore.1", kind: .action, title: "Old onboarding copy", detail: "Oct 12, 2026 at 4:10 PM",
                        action: "Restore"),
                    RemoteSettingsRow(
                        id: "archive.restore.2", kind: .action, title: "Try the Linear MCP", detail: "Oct 3, 2026 at 11:42 AM",
                        action: "Restore"),
                ]),
            ]),
            RemoteSettingsPage(id: "keyboard", title: "Keyboard", symbol: "keyboard", color: "gray", sections: [
                RemoteSettingsSection(id: "shortcuts", footer: "Change shortcuts on your Mac.", rows: [
                    RemoteSettingsRow(id: "keyboard.newThread", kind: .info, title: "New Thread", detail: "⌘N"),
                    RemoteSettingsRow(id: "keyboard.search", kind: .info, title: "Search", detail: "⌘K"),
                ]),
            ]),
            RemoteSettingsPage(id: "browser", title: "Browser", symbol: "globe", color: "cyan", sections: [
                RemoteSettingsSection(
                    id: "profile", title: "Profile",
                    footer: "Cookies and site data include sign-ins in the shared browser profile; pages open in threads reload. Bookmarks are kept.",
                    rows: [
                        toggle(
                            "browser.privateSessions", "Use private sessions", false,
                            detail: "Each thread starts signed out, and forgets its cookies when it closes."),
                        choice("browser.searchEngine", "Search engine", "google", [("google", "Google"), ("duckduckgo", "DuckDuckGo"), ("bing", "Bing")]),
                        RemoteSettingsRow(id: "browser.history", kind: .info, title: "History items", detail: "1,284"),
                        RemoteSettingsRow(id: "browser.clearHistory", kind: .action, title: "Clear History", isDestructive: true),
                        RemoteSettingsRow(id: "browser.clearSiteData", kind: .action, title: "Clear Cookies and Site Data", isDestructive: true),
                    ]),
                RemoteSettingsSection(
                    id: "agents", title: "Agents",
                    footer: "Agents can’t read cookies, site storage or what’s typed in password fields, and ask you to take over for sign-ins, CAPTCHAs and two-factor codes.",
                    rows: [
                        toggle(
                            "browser.agentControl", "Agent Control in new threads", true,
                            detail: "Agents can use their thread’s browser in the background and open it when they need you.")
                    ]),
                RemoteSettingsSection(id: "bookmarks", title: "Bookmarks", rows: [
                    RemoteSettingsRow(
                        id: "browser.bookmark.remove.1", kind: .action, title: "App Store Connect", detail: "appstoreconnect.apple.com",
                        action: "Remove", isDestructive: true),
                    RemoteSettingsRow(
                        id: "browser.bookmark.remove.2", kind: .action, title: "Coincide on GitHub", detail: "github.com", action: "Remove",
                        isDestructive: true),
                ]),
                RemoteSettingsSection(
                    id: "browser", title: "Passwords and Imports", footer: "Password managers, saved logins and browser imports stay on your Mac.",
                    rows: [onMac("browser.open", "Open Browser Settings on Your Mac")]),
            ]),
            RemoteSettingsPage(id: "computerUse", title: "Computer Use", symbol: "desktopcomputer", color: "blue", sections: [
                RemoteSettingsSection(id: "computerUse", rows: [
                    toggle("computerUse.enabled", "Allow agents to use this Mac", false),
                    toggle("computerUse.cursor", "Show agent cursor", true),
                ]),
                RemoteSettingsSection(id: "permissions", title: "Permissions", footer: "macOS asks for these on the Mac itself.", rows: [
                    RemoteSettingsRow(id: "computerUse.accessibility", kind: .status, title: "Accessibility", detail: "Allowed", state: "ok"),
                    RemoteSettingsRow(
                        id: "computerUse.screenRecording", kind: .status, title: "Screen Recording", detail: "Not allowed", state: "warning"),
                    onMac("computerUse.open", "Grant on Your Mac"),
                ]),
            ]),
        ]
        let states = ["claude": "ready", "codex": "ready", "cursor": "attention", "grok": "off", "opencode": "ready", "antigravity": "off"]
        pages.append(
            RemoteSettingsPage(id: "providers", title: "Overview", symbol: "square.grid.2x2", color: "indigo", sections: [
                RemoteSettingsSection(id: "agents", rows: agents.map { id, name in
                    RemoteSettingsRow(
                        id: "providers.\(id)", kind: .page, title: name,
                        detail: states[id] == "ready" ? "Ready" : states[id] == "off" ? "Off" : "Needs setup", state: states[id],
                        target: "provider.\(id)")
                }),
            ]))
        for (id, name) in agents {
            let state = states[id] ?? "off"
            pages.append(
                RemoteSettingsPage(id: "provider.\(id)", title: name, symbol: "sparkles", color: "indigo", group: .provider, status: state, sections: [
                    RemoteSettingsSection(id: "state", rows: [
                        toggle("provider.\(id).enabled", "Use \(name)", state != "off"),
                        RemoteSettingsRow(
                            id: "provider.\(id).status", kind: .status, title: "Status",
                            detail: state == "ready" ? "Ready" : state == "off" ? "Off" : "Needs setup",
                            state: state == "ready" ? "ok" : state == "off" ? "off" : "warning"),
                    ]),
                    RemoteSettingsSection(id: "setup", footer: "Signing in and setup happen in the agent’s own window on your Mac.", rows: [
                        RemoteSettingsRow(id: "provider.\(id).open", kind: .action, title: "Set Up on Your Mac", finishesOnMac: true)
                    ]),
                ]))
        }
        pages.append(
            RemoteSettingsPage(id: "about", title: "About", symbol: "info.circle", color: "blue", group: .about, sections: [
                RemoteSettingsSection(id: "version", rows: [
                    RemoteSettingsRow(id: "about.version", kind: .info, title: "Coincide", detail: "0.1.0 (1)"),
                    RemoteSettingsRow(id: "about.macos", kind: .info, title: "macOS", detail: "27.2.0"),
                ]),
            ]))
        return RemoteSettingsSnapshot(pages: pages)
    }

    /// Settings › Usage as a Mac with Claude Code (two accounts) and Codex would describe it.
    static var usageDashboard: RemoteUsageDashboard {
        let calendar = Calendar.current
        let today = calendar.startOfDay(for: Date())
        var daily: [RemoteUsageDashboard.Day] = []
        for offset in 0..<30 {
            let day = calendar.date(byAdding: .day, value: -offset, to: today) ?? today
            let wave = Double((offset * 7) % 11 + 2)
            daily.append(.init(day: day, provider: "claude", tokens: wave * 1_400_000, cost: wave * 3.1))
            if offset % 3 != 0 { daily.append(.init(day: day, provider: "codex", tokens: wave * 600_000, cost: wave * 1.2)) }
        }
        typealias Row = RemoteUsageDashboard.Row
        return RemoteUsageDashboard(
            scopeTitle: "All Agents", periodName: "Last 30 days", days: 30,
            providers: [.init(id: "claude", title: "Claude Code"), .init(id: "codex", title: "Codex")],
            tiles: [
                .init(title: "Today", tokens: "18.2M", cost: "≈ $41.20", trend: "12% vs yesterday", trendIsUp: true),
                .init(title: "Last 7 days", tokens: "96.4M", cost: "≈ $212.80", trend: "4% vs the 7 days before", trendIsUp: false),
                .init(title: "Last 30 days", tokens: "402M", cost: "≈ $890.15", trend: "21% vs the 30 days before", trendIsUp: true),
            ],
            closestTitle: "Codex", closestProvider: "codex",
            closest: Row(title: "Weekly", value: "81% used", fill: 0.81, paceMark: 0.3, level: .near, details: ["Resets in 5 days", "Ahead of pace"]),
            daily: daily,
            topModels: [
                .init(title: "claude-opus-4-7", provider: "claude", share: 0.62, tokens: "249M", cost: "$612.40"),
                .init(title: "gpt-5.5", provider: "codex", share: 0.28, tokens: "113M", cost: "$201.10"),
                .init(title: "claude-sonnet-4-5", provider: "claude", share: 0.1, tokens: "40M", cost: "$76.65"),
            ],
            topProjects: [
                .init(title: "coincide", share: 0.71, tokens: "285M", cost: "$640.00"),
                .init(title: "fud-ai", share: 0.19, tokens: "76M", cost: "$170.30"),
            ],
            activity: [.init(title: "Turns", value: "1,284"), .init(title: "Active time", value: "61h 12m"), .init(title: "Threads", value: "96")],
            accounts: [
                .init(
                    id: "claude/default", provider: "claude", title: "Claude Code", plan: "Max 20×", checkedAt: Date().addingTimeInterval(-240),
                    rows: [
                        Row(title: "Session", value: "34% used", fill: 0.34, paceMark: 0.5, details: ["Resets in 2 hours"]),
                        Row(title: "Weekly", value: "20% used", fill: 0.2, paceMark: 0.45, details: ["Resets next week"]),
                        Row(title: "Weekly · Fable", value: "0% used", fill: 0, details: ["Resets next week"]),
                        Row(title: "Extra usage", value: "$12.40 of $50 used", fill: 0.25, details: ["Resets Nov 1"]),
                    ],
                    periodTokens: "289M", periodCost: "$689.05", periodSource: "From Claude Code’s logs on this Mac."),
                .init(
                    id: "claude/work", provider: "claude", title: "Claude Code · Work", plan: "Team", checkedAt: Date().addingTimeInterval(-600),
                    rows: [Row(title: "Weekly", value: "9% used", fill: 0.09, paceMark: 0.45, details: ["Resets in 3 days"])],
                    periodTokens: "12M", periodCost: "$31.20", periodSource: "From Claude Code’s logs on this Mac."),
                .init(
                    id: "codex/default", provider: "codex", title: "Codex", plan: "Pro", checkedAt: Date().addingTimeInterval(-120),
                    rows: [
                        Row(title: "Session", value: "0% used", fill: 0, details: ["Resets in 5 hours"]),
                        Row(title: "Weekly", value: "81% used", fill: 0.81, paceMark: 0.3, level: .near, details: ["Resets in 5 days", "Ahead of pace"]),
                        Row(title: "Credits", value: "412 left", fill: 0.62, details: ["Of the most Coincide has seen, 660"]),
                    ],
                    periodTokens: "113M", periodCost: "$201.10", periodSource: "From Codex’s logs on this Mac."),
            ],
            updatedAt: Date().addingTimeInterval(-90))
    }

    /// The demo thread's checkout: the project's folder on main, with branches to switch to.
    static var checkout: RemoteCheckout {
        RemoteCheckout(
            workspace: .local, branch: "main", canPickBranch: true, canCreateBranch: true,
            branches: [
                RemoteBranch(name: "main", isCurrent: true), RemoteBranch(name: "remote-duo-ipad-layout"),
                RemoteBranch(name: "remote-settings-polish", isCheckedOutElsewhere: true), RemoteBranch(name: "origin/main", isRemote: true),
            ])
    }

    /// `-CoincideRemoteDemoUsageWarning`: the composer's usage-limit banner, offering to resume at the reset.
    static var composerNotice: RemoteComposerNotice {
        guard has("UsageWarning") else { return RemoteComposerNotice() }
        return RemoteComposerNotice(
            usageWarning: RemoteUsageWarning(
                key: "demo", text: "Claude Code 5-hour limit reached. It resets in 1 hr 12 min.", fraction: 1, canResumeAtReset: true))
    }

    /// Two scheduled tasks in the demo project: one daily, one paused weekly that failed last time.
    static var scheduledTasks: RemoteScheduledTasks {
        let calendar = Calendar.current
        let tomorrow = calendar.date(bySettingHour: 9, minute: 0, second: 0, of: Date().addingTimeInterval(86_400)) ?? Date()
        return RemoteScheduledTasks(tasks: [
            RemoteScheduledTask(
                id: UUID(uuidString: "5C4ED01E-0000-4000-8000-000000000001")!, name: "Morning dependency check", projectID: projectID,
                prompt: "Check for outdated Swift packages and open a PR for safe updates.",
                recurrence: RemoteTaskRecurrence(kind: .daily, hour: 9, minute: 0), state: .scheduled, stateText: "Scheduled",
                scheduleText: "Daily", nextRunAt: tomorrow, lastRunAt: Date().addingTimeInterval(-15 * 3600), lastThreadID: threadID),
            RemoteScheduledTask(
                id: UUID(uuidString: "5C4ED01E-0000-4000-8000-000000000002")!, name: "Weekly release notes", projectID: otherProjectID,
                prompt: "Draft release notes from this week's merged pull requests.",
                recurrence: RemoteTaskRecurrence(kind: .weekly, hour: 17, minute: 30, weekday: 6), isPaused: true, state: .failed,
                stateText: "Failed · Paused", scheduleText: "Weekly", lastRunAt: Date().addingTimeInterval(-3 * 86_400),
                lastMessage: "Claude Code exited before replying."),
        ])
    }

    /// The demo thread's folder: two changes to commit on a feature branch with an open pull request.
    static var gitState: RemoteGitState {
        RemoteGitState(
            isRepository: true, branch: "remote-image-previews", upstream: "origin/remote-image-previews", ahead: 1,
            changedFiles: 2, hasRemote: true, canCommit: true, canPush: true, canPull: false,
            pullRequest: RemotePullRequest(
                number: 161, title: "Coincide Remote: bot characters in their own colors", url: "https://github.com/apoorvdarshan/coincide/pull/161",
                state: .open, checks: .pending))
    }

    static var pullRequests: RemotePullRequestList {
        RemotePullRequestList(items: [
            RemotePullRequest(
                number: 161, title: "Coincide Remote: bot characters in their own colors, pictures in bounds", url: "https://github.com",
                author: "apoorvdarshan", headBranch: "remote-bot-picker-media", baseBranch: "main", checks: .pending,
                review: .reviewRequired, updatedAt: Date().addingTimeInterval(-600)),
            RemotePullRequest(
                number: 158, title: "Settings › Models and Browser on the phone", url: "https://github.com", author: "apoorvdarshan",
                headBranch: "remote-settings-polish", baseBranch: "main", checks: .passing, review: .approved,
                updatedAt: Date().addingTimeInterval(-7200)),
            RemotePullRequest(
                number: 152, title: "Draft: terminal focus on click", url: "https://github.com", author: "brulee",
                headBranch: "terminal-focus", baseBranch: "main", isDraft: true, checks: .failing, updatedAt: Date().addingTimeInterval(-86_400)),
        ])
    }

    static var pullRequestDetail: RemotePullRequestDetail {
        RemotePullRequestDetail(
            pullRequest: pullRequests.items[1],
            body: "Brings **Settings › Models** and **Browser** to the phone.\n\n- Favorites and hidden models\n- Private sessions",
            checks: [
                .init(name: "Build and test", status: "success"), .init(name: "CodeQL", status: "success"),
                .init(name: "Dependency review", status: "skipped"),
            ],
            mergeability: "mergeable", additions: 812, deletions: 96, changedFiles: 14,
            reviews: [.init(author: "brulee", state: "APPROVED", body: "Looks great on the Duo.")], canMerge: true,
            mergeMethods: ["merge", "squash"])
    }

    /// An instruction file's text, for the document editor.
    static func document(_ key: String) -> RemoteSettingsDocument {
        RemoteSettingsDocument(
            key: key, title: String(key.split(separator: "/").last ?? "AGENTS.md"),
            text: """
                # Global instructions

                - Read the repository's AGENTS.md before changing anything.
                - Keep commits small and explain why, not what.
                - Run the tests that cover what you changed, headless.
                - Never put API keys in URLs; send them in headers.

                ## Mobile apps

                Rebuild and install on the iPhone after every change that runs there.
                """,
            version: "demo")
    }

    /// Two pictures waiting in the composer, for `-CoincideRemoteDemoAttachments`.
    static var draftImages: [ComposerDraft.Image] {
        (0..<2).compactMap { index in
            picture(index, full: false).jpegData(compressionQuality: 0.8).map { ComposerDraft.Image(name: "IMG_20\(41 + index).jpg", data: $0) }
        }
    }

    /// What the Mac would suggest for `@` and `/` words.
    static func completions(_ word: String) -> [RemoteCompletion] {
        if word.hasPrefix("/") {
            return [
                RemoteCompletion(kind: .command, insert: "/review ", title: "/review", detail: "Review the current changes"),
                RemoteCompletion(kind: .command, insert: "/compact ", title: "/compact", detail: "Summarize the conversation to save context"),
                RemoteCompletion(kind: .skill, insert: "/simplify ", title: "/simplify", detail: "Simplify the changed code"),
                RemoteCompletion(kind: .command, insert: "/init ", title: "/init", detail: "Write a CLAUDE.md for this project"),
            ]
        }
        return [
            RemoteCompletion(kind: .file, insert: "@CoincideRemote/UI/ComposerView.swift ", title: "ComposerView.swift", detail: "CoincideRemote/UI"),
            RemoteCompletion(kind: .file, insert: "@CoincideRemote/UI/ThreadView.swift ", title: "ThreadView.swift", detail: "CoincideRemote/UI"),
            RemoteCompletion(kind: .folder, insert: "@CoincideRemote/Connection ", title: "Connection", detail: "CoincideRemote"),
            RemoteCompletion(kind: .file, insert: "@Coincide/UI/Composer/ComposerViewController.swift ", title: "ComposerViewController.swift", detail: "Coincide/UI/Composer"),
        ]
    }

    /// A stand-in picture for media previews: a soft gradient with a symbol, wide or tall by index.
    static func picture(_ index: Int, full: Bool) -> UIImage {
        let size = index % 2 == 0 ? CGSize(width: 640, height: 400) : CGSize(width: 360, height: 520)
        return UIGraphicsImageRenderer(size: size).image { context in
            let colors = [UIColor.systemIndigo, .systemTeal, .systemOrange, .systemPink]
            let gradient = CGGradient(
                colorsSpace: nil, colors: [colors[index % 4].cgColor, colors[(index + 1) % 4].cgColor] as CFArray, locations: nil)!
            context.cgContext.drawLinearGradient(gradient, start: .zero, end: CGPoint(x: size.width, y: size.height), options: [])
            let symbol = UIImage(
                systemName: ["photo", "iphone", "play.rectangle", "paintpalette"][index % 4],
                withConfiguration: UIImage.SymbolConfiguration(pointSize: 96, weight: .light))?
                .withTintColor(.white.withAlphaComponent(0.85), renderingMode: .alwaysOriginal)
            symbol?.draw(at: CGPoint(x: (size.width - (symbol?.size.width ?? 0)) / 2, y: (size.height - (symbol?.size.height ?? 0)) / 2))
        }
    }

    static func transcript(_ summary: RemoteThreadSummary) -> RemoteTranscript {
        let user = UUID()
        let earlier = UUID()
        var items: [RemoteItem] = []
        func add(_ kind: RemoteItem.Kind, _ text: String = "", title: String? = nil, detail: String? = nil, category: String? = nil,
                 status: String? = nil, id: UUID = UUID(), approval: RemoteApproval? = nil, media: [RemoteMedia]? = nil) {
            items.append(
                RemoteItem(
                    id: id, index: items.count, kind: kind, text: text, title: title, detail: detail, category: category,
                    status: status, provider: "claude", approval: approval,
                    attachments: media?.filter { $0.kind == .image }.map(\.label), media: media))
        }
        add(.user, "Add a Remote section to Settings with a pairing QR code.", id: earlier)
        add(.tool, title: "Read GeneralSettingsView.swift", category: "read", status: "completed")
        add(.tool, title: "Edit RemoteSettingsView.swift", category: "fileChange", status: "completed")
        add(.assistant, """
            Added **Settings › General › Remote**:

            - A toggle that starts the server (off by default)
            - *Pair iPhone or iPad…* shows a one-time QR code
            - Paired devices with **Revoke**

            ```swift
            Section("Remote") {
                RemoteSettingsRows()
            }
            ```
            """)
        add(.user, "Now run the tests and fix anything that fails.", id: user)
        add(.tool, "Test Suite 'All tests' passed", title: "xcodebuild test -scheme Coincide", category: "command", status: "completed")
        add(.reasoning, "Checking the pairing tests for timing assumptions…")
        add(.assistant, "All **312** tests pass. One more step needs your approval:")
        add(
            .approval, title: "Run git push origin coincide-remote", detail: "git push origin coincide-remote", status: "waiting",
            approval: RemoteApproval(options: [
                .init(id: "allow", label: "Allow", kind: "allowOnce"), .init(id: "always", label: "Always Allow", kind: "allowAlways"),
                .init(id: "deny", label: "Deny", kind: "deny"),
            ]))
        // `-CoincideRemoteDemoMedia`: pictures the user attached and an agent's generated image, video and page.
        if ProcessInfo.processInfo.arguments.contains("-CoincideRemoteDemoMedia") {
            // A wide Mac screenshot alone, which must stay within the bubble.
            add(.user, "Why is this terminal not taking my typing?", media: [
                RemoteMedia(index: 4, kind: .image, label: "Screenshot 2026-10-31 at 9.31.12 PM.png")
            ])
            add(.assistant, "The terminal never becomes first responder when clicked. I'll fix the focus handling.")
            add(.user, "Make the settings screen match these.", media: [
                RemoteMedia(index: 0, kind: .image, label: "5025975E-88A1-4F2B-9C1D-2B7E5C3A9F10.png"),
                RemoteMedia(index: 1, kind: .image, label: "IMG_2041.jpg"),
            ])
            add(.assistant, "Here's the new screen, and a short recording of the pairing flow:\n\n![Settings › Remote](remote.png)", media: [
                RemoteMedia(index: 0, kind: .image, label: "Settings › Remote"),
                RemoteMedia(index: 1, kind: .video, label: "pairing.mov"),
                RemoteMedia(index: 2, kind: .interactive, label: "palette.html"),
            ])
        }
        // `-CoincideRemoteDemoBackground`: the turn ended, and a subagent and a command still run.
        let background = ProcessInfo.processInfo.arguments.contains("-CoincideRemoteDemoBackground")
        let turn =
            background
            ? RemoteTurnState(provider: "claude", backgroundTasks: [
                RemoteBackgroundTask(
                    id: "a", provider: "claude", title: "iOS live threads, media, composer", kind: .agent,
                    startedAt: Date().addingTimeInterval(-68), agentType: "general-purpose",
                    progress: "Running Read Formatting and RemoteProject"),
                RemoteBackgroundTask(
                    id: "b", provider: "claude", title: "xcodebuild test -scheme CoincideRemote", kind: .command,
                    startedAt: Date().addingTimeInterval(-412)),
            ])
            : RemoteTurnState(isRunning: true, startedAt: Date().addingTimeInterval(-95), provider: "claude")
        return RemoteTranscript(
            thread: summary, items: background ? items.filter { $0.kind != .approval } : items, turn: turn,
            turnChanges: [
                earlier.uuidString: [
                    RemoteChangedFile(path: "Coincide/Remote/RemoteSettingsView.swift", status: "added", additions: 212),
                    RemoteChangedFile(path: "Coincide/UI/Settings/GeneralSettingsView.swift", status: "modified", additions: 5, deletions: 0),
                ]
            ])
    }
}
#endif

#if DEBUG
import SwiftUI

/// Window sizes for layout checks in a headless simulator, which can't drag a window or unfold a Duo.
///
/// - `-CoincideRemoteWindow 375x1000` asks iPadOS for a window of that size (its windowing honors the scene's size
///   restrictions), as Split View or Slide Over would make it. The system picks the size class, as it would there.
/// - `-CoincideRemoteEmulate 669x951 regular` lays the app out in a frame of that size with that horizontal size class,
///   at the top left of the screen: the unfolded iPhone Duo, which the simulator can't switch to without its window.
struct DebugWindowSizing: ViewModifier {
    func body(content: Content) -> some View {
        if let emulated = Self.size(DemoData.value(after: "-CoincideRemoteEmulate")) {
            let arguments = ProcessInfo.processInfo.arguments
            let regular = arguments.firstIndex(of: "-CoincideRemoteEmulate").map { index in
                index + 2 < arguments.count && arguments[index + 2] == "regular"
            } ?? false
            ZStack(alignment: .topLeading) {
                Color.gray.opacity(0.25).ignoresSafeArea()
                content
                    .environment(\.horizontalSizeClass, regular ? .regular : .compact)
                    .frame(width: emulated.width, height: emulated.height)
                    .clipped()
            }
            .ignoresSafeArea(edges: [.leading, .bottom, .trailing])
        } else {
            content.onAppear {
                guard let size = Self.size(DemoData.value(after: "-CoincideRemoteWindow")) else { return }
                for case let scene as UIWindowScene in UIApplication.shared.connectedScenes {
                    scene.sizeRestrictions?.minimumSize = size
                    scene.sizeRestrictions?.maximumSize = size
                }
            }
        }
    }

    static func size(_ text: String?) -> CGSize? {
        guard let parts = text?.split(separator: "x"), parts.count == 2, let width = Double(parts[0]), let height = Double(parts[1])
        else { return nil }
        return CGSize(width: width, height: height)
    }
}
#endif
