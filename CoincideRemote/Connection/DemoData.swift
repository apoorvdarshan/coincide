#if DEBUG
import CoincideRemoteKit
import Foundation

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

    static var server: RemoteServerInfo {
        RemoteServerInfo(serverID: "demo", name: "Apoorv’s MacBook Pro", appVersion: "0.1.0")
    }

    static var mac: SavedMac {
        SavedMac(
            serverID: "demo", name: "Apoorv’s MacBook Pro", hosts: [RemoteHostCandidate(host: "192.168.1.20", kind: .lan)],
            port: RemoteProtocol.defaultPort, fingerprint: String(repeating: "0", count: 64), deviceID: "demo", pairedAt: Date())
    }

    static var workspace: RemoteWorkspace {
        let claude = RemoteSelection(provider: "claude", modelID: "opus", modelName: "Claude Opus", effort: "high")
        let codex = RemoteSelection(provider: "codex", modelID: "gpt", modelName: "GPT-5.5", effort: "medium", speed: "priority")
        let now = Date()
        func thread(_ title: String, _ project: UUID, _ selection: RemoteSelection, minutes: Double, id: UUID = UUID(),
                    pinned: Bool = false, running: Bool = false, approvals: Int = 0, unseen: String? = nil) -> RemoteThreadSummary {
            RemoteThreadSummary(
                id: id, projectID: project, title: title, updatedAt: now.addingTimeInterval(-minutes * 60), selection: selection,
                isPinned: pinned, branch: "main", isRunning: running, pendingApprovals: approvals, unseen: unseen, itemCount: 8)
        }
        return RemoteWorkspace(
            projects: [
                RemoteProject(
                    id: projectID, name: "coincide", path: "~/coincide",
                    scripts: [RemoteScript(id: UUID(), name: "Tests", command: "xcodebuild test", icon: "test")]),
                RemoteProject(id: otherProjectID, name: "fud-ai", path: "~/fud-ai"),
                RemoteProject(id: chatsID, name: "Chats", path: "~/Library/Application Support/Coincide", isChats: true),
            ],
            threads: [
                thread("Release checklist", otherProjectID, codex, minutes: 300, pinned: true),
                thread("Coincide Remote: iPhone companion", projectID, claude, minutes: 1, id: threadID, running: true, approvals: 1),
                thread("Fix stale transcript row heights", projectID, codex, minutes: 25, unseen: "completed"),
                thread("Sidebar sorting and pinned section", projectID, claude, minutes: 90),
                thread("Paywall copy for annual plan", otherProjectID, codex, minutes: 60 * 26, unseen: "failed"),
                thread("What’s a good name for a cat?", chatsID, claude, minutes: 60 * 4),
                thread("Plan my Saturday", botsID, claude, minutes: 12, id: bruleeThreadID, unseen: "completed"),
            ],
            bots: [
                RemoteBot(
                    id: UUID(uuidString: "66666666-6666-6666-6666-666666666666")!, name: "Brulee", projectID: botsID,
                    threadIDs: [bruleeThreadID], avatar: RemoteBotAvatar(.brulee, .rose), persona: "Friendly and brief.",
                    selection: claude, accessMode: "approval", interactionMode: "build"),
                RemoteBot(
                    id: UUID(uuidString: "77777777-7777-7777-7777-777777777777")!, name: "Teddy", projectID: botsID,
                    avatar: RemoteBotAvatar(.teddy, .caramel), selection: codex, accessMode: "approval", interactionMode: "build"),
                RemoteBot(
                    id: UUID(uuidString: "88888888-8888-8888-8888-888888888888")!, name: "Alien", projectID: botsID,
                    avatar: RemoteBotAvatar(.alien, .leaf), selection: claude, accessMode: "fullAccess", interactionMode: "build"),
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

    static func transcript(_ summary: RemoteThreadSummary) -> RemoteTranscript {
        let user = UUID()
        let earlier = UUID()
        var items: [RemoteItem] = []
        func add(_ kind: RemoteItem.Kind, _ text: String = "", title: String? = nil, detail: String? = nil, category: String? = nil,
                 status: String? = nil, id: UUID = UUID(), approval: RemoteApproval? = nil) {
            items.append(
                RemoteItem(
                    id: id, index: items.count, kind: kind, text: text, title: title, detail: detail, category: category,
                    status: status, provider: "claude", approval: approval))
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
        return RemoteTranscript(
            thread: summary, items: items, turn: RemoteTurnState(isRunning: true, startedAt: Date().addingTimeInterval(-95), provider: "claude"),
            turnChanges: [
                earlier.uuidString: [
                    RemoteChangedFile(path: "Coincide/Remote/RemoteSettingsView.swift", status: "added", additions: 212),
                    RemoteChangedFile(path: "Coincide/UI/Settings/GeneralSettingsView.swift", status: "modified", additions: 5, deletions: 0),
                ]
            ])
    }
}
#endif
