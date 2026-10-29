import AppKit
import CoincideKit

/// Bot commands shared by the sidebar, the main menu and the command palette (see `Bot`).
enum BotActions {
    private static var store: AppStore { .shared }

    /// Opens a bot: its latest conversation, or a new one when it has none.
    static func open(_ botID: UUID) {
        if let latest = store.latestConversation(of: botID) {
            AppEvents.openThread(latest.id)
        } else {
            newConversation(with: botID)
        }
    }

    /// Starts a fresh conversation with a bot, keeping its earlier ones under Past Conversations. An untouched one
    /// already waiting is reused rather than adding another.
    @discardableResult
    static func newConversation(with botID: UUID) -> UUID? {
        guard let bot = store.bot(botID) else { return nil }
        let id: UUID
        if let empty = store.conversations(of: botID).first(where: { $0.itemCount == 0 && !$0.hasDraft }) {
            id = empty.id
        } else {
            let selection = ProviderRegistry.shared.usableSelection(preferring: bot.selection)
            guard let thread = store.startConversation(with: botID, selection: selection) else { return nil }
            id = thread.id
        }
        AppEvents.openThread(id)
        DispatchQueue.main.async { AppEvents.post(.coincideFocusComposer) }
        return id
    }

    /// Adds the starter bots the first time Coincide runs with bots, on the user's default agent, or the first that
    /// is set up when that one is not.
    static func addStartersIfNeeded() {
        let selection = ProviderRegistry.shared.usableSelection(preferring: store.settings.defaultSelection)
        store.addStarterBotsIfNeeded(selection: selection)
    }

    static func newBot(in window: NSWindow?) {
        let editor = BotEditor(bot: nil)
        editor.onSave = { bot in
            store.addBot(bot)
            newConversation(with: bot.id)
        }
        present(editor, in: window)
    }

    static func edit(_ botID: UUID, in window: NSWindow?) {
        guard let bot = store.bot(botID) else { return }
        let editor = BotEditor(bot: bot)
        editor.onSave = { edited in save(edited, replacing: bot) }
        present(editor, in: window)
    }

    /// Saves an edited bot. Its conversations' live sessions end (after a running turn) when the folder or the
    /// instructions changed, so the next message starts the agent in the new folder with the new instructions; the
    /// native sessions resume. Agent, model and modes apply to new conversations and to an untouched one.
    static func save(_ edited: Bot, replacing original: Bot) {
        store.updateBot(original.id) { $0 = edited }
        let conversations = store.conversations(of: original.id, includeArchived: true)
        if edited.folder != original.folder || edited.instructions != original.instructions {
            RelocatedSessions.end(threads: conversations.map(\.id))
        }
        if edited.selection != original.selection || edited.accessMode != original.accessMode
            || edited.interactionMode != original.interactionMode
        {
            for thread in conversations where thread.itemCount == 0 && !ThreadRunner.shared.isRunning(thread.id) {
                store.updateThread(thread.id) { thread in
                    thread.selection = edited.selection
                    thread.accessMode = edited.accessMode
                    thread.interactionMode = edited.interactionMode
                }
            }
        }
    }

    /// Asks before deleting a bot, and whether its conversations go with it or stay as chats.
    static func delete(_ botID: UUID, in window: NSWindow?) {
        guard let bot = store.bot(botID) else { return }
        let conversations = store.conversations(of: botID, includeArchived: true).map(\.id)
        let running = conversations.contains { ThreadRunner.shared.isRunning($0) }
        let alert = ThemedAlert()
        alert.alertStyle = .warning
        alert.messageText = String(localized: "Delete “\(bot.displayName)”?")
        var text: String
        if conversations.isEmpty {
            text = String(localized: "The bot and its instructions will be removed. Files on your Mac are not changed.")
            alert.addButton(withTitle: String(localized: "Delete Bot")).hasDestructiveAction = true
        } else {
            text = String(
                localized: "Keep its conversations as chats, or delete them with the bot. Deleted conversations can be restored with Undo until Coincide quits. Files on your Mac are not changed.")
            alert.addButton(withTitle: String(localized: "Keep Conversations"))
            alert.addButton(withTitle: String(localized: "Delete Conversations")).hasDestructiveAction = true
        }
        if running {
            text += "\n\n" + String(localized: "Agents working in its conversations will stop.")
        }
        alert.informativeText = text
        alert.addButton(withTitle: String(localized: "Cancel"))
        let finish: (NSApplication.ModalResponse) -> Void = { response in
            let deletes: Bool
            switch response {
            case .alertFirstButtonReturn: deletes = false
            case .alertSecondButtonReturn where !conversations.isEmpty: deletes = true
            default: return
            }
            for id in conversations { ThreadRunner.shared.shutdown(threadID: id) }
            if deletes {
                do { try ThreadInbox.shared.delete(conversations) } catch { NSApp.presentError(error) }
            }
            // Whatever is left (all of them when kept) becomes chats.
            store.deleteBot(botID, deletingConversations: false)
        }
        if let window, window.isVisible {
            alert.beginSheetModal(for: window, completionHandler: finish)
        } else {
            finish(alert.runModal())
        }
    }

    /// A submenu of a bot's conversations, the latest first, each opening its thread.
    static func pastConversationsMenu(for botID: UUID, target: AnyObject, action: Selector) -> NSMenu {
        let menu = NSMenu()
        let conversations = store.conversations(of: botID)
        for thread in conversations.prefix(30) {
            let item = NSMenuItem(title: thread.title, action: action, keyEquivalent: "")
            item.target = target
            item.representedObject = thread.id
            item.toolTip = thread.preview
            item.badge = NSMenuItemBadge(string: thread.updatedAt.formatted(.relative(presentation: .numeric, unitsStyle: .abbreviated)))
            menu.addItem(item)
        }
        if conversations.isEmpty {
            let none = NSMenuItem(title: String(localized: "No conversations yet"), action: nil, keyEquivalent: "")
            none.isEnabled = false
            menu.addItem(none)
        }
        return menu
    }

    private static func present(_ editor: BotEditor, in window: NSWindow?) {
        if let controller = window?.contentViewController {
            controller.presentAsSheet(editor)
        } else {
            let window = NSWindow(contentViewController: editor)
            window.title = String(localized: "Bot")
            window.makeKeyAndOrderFront(nil)
        }
    }
}
