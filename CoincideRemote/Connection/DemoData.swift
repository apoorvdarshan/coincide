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

    static var workspace: RemoteWorkspace {
        let claude = RemoteSelection(provider: "claude", modelID: "opus", modelName: "Opus", effort: "high")
        let codex = RemoteSelection(provider: "codex", modelID: "gpt", modelName: "GPT-6.1-Sol", effort: "medium", speed: "priority")
        let grok = RemoteSelection(provider: "grok", modelID: "grok", modelName: "Grok 4.7")
        let antigravity = RemoteSelection(provider: "antigravity", modelID: "gemini", modelName: "Gemini 3.5 Pro")
        let old = isOldMac
        let pins = ProcessInfo.processInfo.arguments.contains("-CoincideRemoteDemoPinned")
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
                    isExpanded: old ? nil : true),
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
            pinnedOrder: [])
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
