import AppKit
import Testing

@testable import Coincide
@testable import CoincideKit

/// Thread and project commands of the sidebar, menu bar and palette, run against the shared store, which
/// the test environment points at a scratch folder. Each test removes the projects it added.
@Suite(.serialized)
struct ThreadActionsTests {
    private var store: AppStore { .shared }

    /// A project in its own scratch folder, removed with its threads when `body` returns.
    private func withProject(_ body: (Project, TemporaryDirectory) throws -> Void) rethrows {
        let folder = TemporaryDirectory("project")
        let project = store.addProject(at: folder.url)
        defer { store.removeProject(project.id) }
        try body(project, folder)
    }

    /// The threads `body` asked the window to open, in order.
    private func openedThreads(_ body: () throws -> Void) rethrows -> [UUID] {
        let opened = ThreadIDRecorder(.coincideOpenThread)
        try body()
        return opened.ids
    }

    @Test func aNewThreadReusesAnUntouchedOneInsteadOfPilingUpEmptyThreads() throws {
        try withProject { project, _ in
            var first: UUID?
            var second: UUID?
            let opened = openedThreads {
                first = ThreadActions.newThread(in: project.id)
                second = ThreadActions.newThread(in: project.id)
            }
            let id = try #require(first)
            #expect(second == id)
            #expect(opened == [id, id])
            #expect(store.threads(in: project.id).count == 1)

            store.append(TranscriptItem(kind: .user, text: "Hello"), to: id)
            let third = try #require(ThreadActions.newThread(in: project.id))
            #expect(third != id)
            #expect(store.threads(in: project.id).count == 2)
        }
    }

    @Test func listingAndThreadCommandsReadNoTranscript() async throws {
        let folder = TemporaryDirectory("project")
        let project = store.addProject(at: folder.url)
        let limit = store.transcriptCacheLimit
        defer {
            store.transcriptCacheLimit = limit
            store.removeProject(project.id)
        }
        let ids = (0..<4).map { number in
            let id = store.createThread(in: project.id).id
            store.append(TranscriptItem(kind: .user, text: "Message \(number)"), to: id)
            store.updateThread(id) { $0.title = "Listed \(number)" }
            return id
        }
        store.flush()
        // Once saved, no transcript needs to stay in memory.
        store.transcriptCacheLimit = 0
        let deadline = Date().addingTimeInterval(10)
        while ids.contains(where: store.isTranscriptLoaded), Date() < deadline {
            try await Task.sleep(for: .milliseconds(20))
        }
        #expect(!ids.contains(where: store.isTranscriptLoaded))
        let reads = store.transcriptReads

        // The palette lists and searches threads by their summaries.
        let catalog = PaletteCatalog(windowController: nil)
        #expect(Set(ids.map { "thread:\($0)" }).isSubset(of: catalog.allThreads().map(\.id)))
        #expect(catalog.recentThreads().contains { $0.title == "Listed 3" })
        // So do the sidebar row's commands and the thread actions.
        #expect(ThreadForking.canFork(ids[0]))
        #expect(ThreadActions.canArchive(ids[0]))
        #expect(ThreadForking.forkedFromDescription(ids[0]) == nil)
        ThreadActions.rename(ids[1], to: " Listed 1 ")
        let fresh = try #require(ThreadActions.newThread(in: project.id))
        #expect(!ids.contains(fresh))
        #expect(ThreadActions.newThread(in: project.id) == fresh)
        #expect(store.transcriptReads == reads)
        // Opening a thread reads just that one.
        #expect(store.thread(ids[2])?.items.map(\.text) == ["Message 2"])
        #expect(store.transcriptReads == reads + 1)
    }

    @Test func aDraftOrArchivingMakesAThreadTouched() throws {
        try withProject { project, _ in
            let drafted = store.createThread(in: project.id)
            store.updateThread(drafted.id) { $0.draft = "half a thought" }
            let archived = store.createThread(in: project.id)
            store.updateThread(archived.id) { $0.isArchived = true }
            let fresh = try #require(ThreadActions.newThread(in: project.id))
            #expect(fresh != drafted.id && fresh != archived.id)
        }
    }

    @Test func aThreadBasedOnAnotherStartsInItsWorktreeAndBranch() throws {
        try withProject { project, _ in
            let plain = try #require(ThreadActions.newThread(in: project.id))
            var source = try #require(store.summary(plain))
            source.worktreePath = "/tmp/coincide-worktree"
            source.branch = "coincide/feature"
            store.append(TranscriptItem(kind: .user, text: "Work"), to: plain)
            store.updateThread(plain) { thread in
                thread.worktreePath = source.worktreePath
                thread.branch = source.branch
            }
            let empty = store.createThread(in: project.id)

            let based = try #require(ThreadActions.newThread(in: project.id, basedOn: source))
            // An untouched thread in the project folder is not the one a worktree thread continues in.
            #expect(based != empty.id)
            #expect(store.thread(based)?.worktreePath == "/tmp/coincide-worktree")
            #expect(store.thread(based)?.branch == "coincide/feature")
            #expect(store.workingDirectory(for: based)?.path == "/tmp/coincide-worktree")
            #expect(ThreadActions.folder(for: based)?.path == "/tmp/coincide-worktree")
            // Asking again reuses it.
            #expect(ThreadActions.newThread(in: project.id, basedOn: source) == based)
            // Without a source, the untouched project-folder thread is reused.
            #expect(ThreadActions.newThread(in: project.id) == empty.id)
        }
    }

    @Test func aNewThreadExpandsItsCollapsedProject() {
        withProject { project, _ in
            store.updateProject(project.id) { $0.isExpanded = false }
            #expect(ThreadActions.newThread(in: project.id) != nil)
            #expect(store.project(project.id)?.isExpanded == true)
        }
    }

    @Test func noThreadIsMadeForAProjectThatIsGone() {
        #expect(ThreadActions.newThread(in: UUID()) == nil)
    }

    @Test func renamingTrimsAndIgnoresBlankNames() throws {
        try withProject { project, folder in
            let id = try #require(ThreadActions.newThread(in: project.id))
            ThreadActions.rename(id, to: "  Fix the sidebar \n")
            #expect(store.thread(id)?.title == "Fix the sidebar")
            ThreadActions.rename(id, to: "   ")
            #expect(store.thread(id)?.title == "Fix the sidebar")

            #expect(project.name == folder.url.lastPathComponent)
            ThreadActions.rename(project: project.id, to: " App ")
            #expect(store.project(project.id)?.name == "App")
            ThreadActions.rename(project: project.id, to: "")
            #expect(store.project(project.id)?.name == "App")
        }
    }

    @Test func pinningAndArchivingToggle() throws {
        try withProject { project, _ in
            let id = try #require(ThreadActions.newThread(in: project.id))
            ThreadActions.togglePin(id)
            #expect(store.thread(id)?.isPinned == true)
            ThreadActions.togglePin(id)
            #expect(store.thread(id)?.isPinned == false)

            // A thread that is not running can be archived and brought back.
            #expect(ThreadActions.canArchive(id))
            ThreadActions.toggleArchived(id)
            #expect(store.thread(id)?.isArchived == true)
            #expect(!store.threads(in: project.id).contains { $0.id == id })
            #expect(ThreadActions.canArchive(id))
            ThreadActions.toggleArchived(id)
            #expect(store.thread(id)?.isArchived == false)
        }
    }

    @Test func deletingWithoutConfirmationRemovesTheThreadAtOnce() throws {
        let confirm = store.settings.confirmBeforeDeletingThreads
        store.updateSettings { $0.confirmBeforeDeletingThreads = false }
        defer { store.updateSettings { $0.confirmBeforeDeletingThreads = confirm } }
        try withProject { project, _ in
            let id = try #require(ThreadActions.newThread(in: project.id))
            ThreadActions.delete(id, in: nil)
            #expect(store.thread(id) == nil)
            // Deleting what is already gone does nothing.
            ThreadActions.delete(id, in: nil)
        }
    }

    @Test func addingFoldersSkipsFilesAndOpensANewThreadInTheFirst() throws {
        let scratch = TemporaryDirectory("projects")
        let first = try scratch.folder("first")
        let second = try scratch.folder("second")
        let file = try scratch.file("notes.txt")
        let missing = scratch.url.appendingPathComponent("missing")
        let before = Set(store.projects.map(\.id))
        defer {
            for project in store.projects where !before.contains(project.id) { store.removeProject(project.id) }
        }
        let opened = openedThreads { ThreadActions.addProjects([file, missing, first, second]) }
        let added = store.projects.filter { !before.contains($0.id) }
        #expect(added.map(\.path) == [first.path, second.path])
        #expect(added.map(\.name) == ["first", "second"])
        let firstProject = try #require(added.first)
        #expect(opened.count == 1)
        #expect(store.thread(try #require(opened.first))?.projectID == firstProject.id)
        // Only files: nothing to add.
        #expect(openedThreads { ThreadActions.addProjects([file]) }.isEmpty)
    }

    @Test func addingAKnownFolderOpensItsLatestThread() {
        withProject { project, folder in
            let older = store.createThread(in: project.id)
            store.append(TranscriptItem(kind: .user, text: "Old"), to: older.id)
            let newer = store.createThread(in: project.id)
            store.append(TranscriptItem(kind: .user, text: "New"), to: newer.id)
            store.updateProject(project.id) { $0.isExpanded = false }
            let opened = openedThreads { ThreadActions.addProjects([folder.url]) }
            #expect(opened == [newer.id])
            #expect(store.project(project.id)?.isExpanded == true)
            #expect(store.projects.filter { $0.path == project.path }.count == 1)
        }
    }
}

/// Which approvals wait and which results are unseen, as the sidebar badges and Dock badge show them.
@Suite(.serialized)
struct ThreadActivityTests {
    @Test func waitingApprovalsAreCountedUntilAnswered() throws {
        let folder = TemporaryDirectory("activity")
        let store = AppStore(directory: folder.url)
        let activity = ThreadActivity(store: store)
        activity.start()
        let project = store.addProject(at: folder.url)
        let thread = store.createThread(in: project.id)
        let changes = ThreadIDRecorder(.coincideThreadActivityChanged)
        defer { store.removeProject(project.id) }

        let first = store.append(TranscriptItem(kind: .approval, status: .waiting), to: thread.id)
        store.append(TranscriptItem(kind: .approval, status: .completed), to: thread.id)
        let second = store.append(TranscriptItem(kind: .approval, status: .waiting), to: thread.id)
        #expect(activity.pendingApprovalCount(thread.id) == 2)
        #expect(changes.ids == [thread.id, thread.id])

        store.updateItem(first, in: thread.id) { $0.status = .completed }
        #expect(activity.pendingApprovalCount(thread.id) == 1)
        // Rewinding the transcript counts again from what is left.
        store.truncate(thread.id, from: second)
        #expect(activity.pendingApprovalCount(thread.id) == 0)
        #expect(activity.totalPendingApprovals == 0)
        NSApp.dockTile.badgeLabel = nil
    }
}

/// Records the `threadID` of every notification of one name posted on the main thread while it lives.
final class ThreadIDRecorder {
    private(set) var ids: [UUID] = []
    private var observer: NSObjectProtocol?

    init(_ name: Notification.Name) {
        observer = NotificationCenter.default.addObserver(forName: name, object: nil, queue: nil) { [weak self] note in
            let id = note.userInfo?["threadID"] as? UUID
            MainActor.assumeIsolated {
                if let id { self?.ids.append(id) }
            }
        }
    }

    isolated deinit {
        if let observer { NotificationCenter.default.removeObserver(observer) }
    }
}
