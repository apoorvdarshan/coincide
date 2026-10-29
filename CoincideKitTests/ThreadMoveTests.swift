import Foundation
import Testing

@testable import CoincideKit

/// Moving a thread to another project (`AppStore.moveThread`) and back.
@MainActor
struct ThreadMoveTests {
    private let directory = FileManager.default.temporaryDirectory.appendingPathComponent("coincide-move-\(UUID().uuidString)")

    private func makeStore() -> (AppStore, Project, Project) {
        let store = AppStore(directory: directory)
        let source = store.addProject(at: URL(fileURLWithPath: "/tmp/source"))
        let destination = store.addProject(at: URL(fileURLWithPath: "/tmp/destination"))
        return (store, source, destination)
    }

    /// A thread that ran a Claude session in its project, on a branch.
    private func ranThread(in store: AppStore, _ project: Project) -> UUID {
        let id = store.createThread(in: project.id).id
        store.append(TranscriptItem(kind: .user, text: "hello"), to: id)
        store.append(TranscriptItem(kind: .assistant, text: "hi", provider: .claude), to: id)
        store.updateThread(id) { thread in
            thread.sessions[.claude] = ProviderSessionRef(sessionID: "c1", seenItemCount: 2)
            thread.accountSessions = ["codex/work": ProviderSessionRef(sessionID: "x1", seenItemCount: 1)]
            thread.branch = "main"
        }
        return id
    }

    @Test func aMovedThreadKeepsItsTranscriptAndStartsAfreshInItsNewFolder() throws {
        let (store, source, destination) = makeStore()
        let id = ranThread(in: store, source)
        var changes: [StoreChange] = []
        let token = store.observe { changes.append($0) }
        defer { _ = token }

        let move = try #require(store.moveThread(id, to: destination.id))
        #expect(move.from == source.id && move.to == destination.id)
        let thread = try #require(store.thread(id))
        #expect(thread.projectID == destination.id)
        #expect(thread.items.map(\.text) == ["hello", "hi"])
        // The old folder's sessions and branch are gone: the next turn starts a new session with a recap.
        #expect(thread.sessions.isEmpty && thread.accountSessions == nil && thread.branch == nil)
        #expect(Handoff.missedItems(in: thread, for: .claude).count == 2)
        #expect(store.workingDirectory(for: id) == destination.url)
        #expect(store.threads(in: source.id).isEmpty)
        #expect(store.threads(in: destination.id).map(\.id) == [id])
        #expect(changes.contains(.threadList) && changes.contains(.thread(id)))

        // The move is saved, index and file alike.
        store.flush()
        let reloaded = AppStore(directory: directory)
        #expect(reloaded.summary(id)?.projectID == destination.id)
        #expect(reloaded.thread(id)?.projectID == destination.id)
    }

    @Test func undoingAMoveRightAwayResumesTheOldSessions() throws {
        let (store, source, destination) = makeStore()
        let id = ranThread(in: store, source)
        let before = try #require(store.thread(id))
        let move = try #require(store.moveThread(id, to: destination.id))
        #expect(store.undoMove(move))
        let thread = try #require(store.thread(id))
        #expect(thread.projectID == source.id)
        #expect(thread.sessions == before.sessions && thread.accountSessions == before.accountSessions)
        #expect(thread.branch == "main")
        // Already back: a second undo changes nothing.
        #expect(!store.undoMove(move))
    }

    @Test func undoingAfterATurnInTheNewFolderStartsAfreshThereToo() throws {
        let (store, source, destination) = makeStore()
        let id = ranThread(in: store, source)
        let move = try #require(store.moveThread(id, to: destination.id))
        store.append(TranscriptItem(kind: .user, text: "in the new folder"), to: id)
        store.updateThread(id) { $0.sessions[.codex] = ProviderSessionRef(sessionID: "new", seenItemCount: 3) }
        #expect(store.undoMove(move))
        let thread = try #require(store.thread(id))
        #expect(thread.projectID == source.id)
        #expect(thread.sessions.isEmpty && thread.accountSessions == nil && thread.branch == nil)
        #expect(thread.items.count == 3)
    }

    @Test func worktreeThreadsAndPointlessMovesAreRefused() throws {
        let (store, source, destination) = makeStore()
        let worktree = store.createThread(in: source.id).id
        store.updateThread(worktree) { $0.worktreePath = "/tmp/source-worktree" }
        let plain = store.createThread(in: source.id).id
        #expect(!store.canMoveThread(worktree, to: destination.id))
        #expect(store.moveThread(worktree, to: destination.id) == nil)
        #expect(store.summary(worktree)?.projectID == source.id)
        // Into its own project, into one that doesn't exist, or a thread that doesn't.
        #expect(store.moveThread(plain, to: source.id) == nil)
        #expect(store.moveThread(plain, to: UUID()) == nil)
        #expect(store.moveThread(UUID(), to: destination.id) == nil)
        #expect(store.canMoveThread(plain, to: destination.id))
    }

    @Test func threadsMoveIntoAndOutOfChats() throws {
        let (store, source, _) = makeStore()
        let chats = store.ensureChatsProject()
        let chat = store.createThread(in: chats.id).id
        let thread = store.createThread(in: source.id).id
        #expect(store.moveThread(chat, to: source.id) != nil)
        #expect(store.moveThread(thread, to: chats.id) != nil)
        #expect(store.summary(chat)?.projectID == source.id)
        #expect(store.summary(thread)?.projectID == chats.id)
        #expect(store.workingDirectory(for: thread) == chats.url)
        // Moving threads leaves the projects, and Chats' place at the end, alone.
        #expect(store.projects.last?.isChats == true)
    }
}
