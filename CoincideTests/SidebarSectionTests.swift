import AppKit
import Testing

@testable import Coincide
@testable import CoincideKit

@MainActor
@Suite(.serialized)
struct SidebarSectionTests {
    @Test func chatsAreAnExpandedSectionBesideProjectsEvenWithAnOldCollapsedSetting() throws {
        let folder = TemporaryDirectory("sidebar-sections")
        let store = AppStore.shared
        let project = store.addProject(at: folder.url)
        let hadChats = store.chatsProject != nil
        let chats = store.ensureChatsProject()
        let wasExpanded = chats.isExpanded
        let chatID = store.createThread(in: chats.id).id
        defer {
            store.deleteThread(chatID)
            store.removeProject(project.id)
            if hadChats {
                store.updateProject(chats.id) { $0.isExpanded = wasExpanded }
            } else {
                store.removeProject(chats.id)
            }
        }
        store.updateProject(chats.id) { $0.isExpanded = false }

        let sidebar = SidebarViewController()
        let outline = try #require(firstView(of: NSOutlineView.self, in: sidebar.view))
        sidebar.select(threadID: chatID)
        let roots = rootSections(sidebar, outline)
        #expect(roots.map(\.kind) == [.header, .chats(chats.id)])
        let projectsSection = try #require(roots.first { $0.kind == .header })
        let chatsSection = try #require(roots.first { $0.kind == .chats(chats.id) })
        #expect(projectsSection.children.contains { $0.kind == .project(project.id) })
        #expect(!projectsSection.children.contains { $0.projectID == chats.id })
        let chat = try #require(chatsSection.children.first { $0.threadID == chatID })
        #expect(outline.parent(forItem: projectsSection) == nil)
        #expect(outline.parent(forItem: chatsSection) == nil)
        #expect((outline.parent(forItem: chat) as? SidebarNode) === chatsSection)

        #expect(sidebar.outlineView(outline, isGroupItem: chatsSection))
        #expect(!sidebar.outlineView(outline, shouldShowOutlineCellForItem: chatsSection))
        #expect(!sidebar.outlineView(outline, shouldSelectItem: chatsSection))
        #expect(!sidebar.outlineView(outline, shouldCollapseItem: chatsSection))
        #expect(outline.isItemExpanded(chatsSection))
        outline.collapseItem(chatsSection)
        #expect(outline.isItemExpanded(chatsSection))
        #expect(sidebar.visibleThreadIDs.contains(chatID))
        #expect(outline.row(forItem: chat) >= 0)
        #expect(store.project(chats.id)?.isExpanded == false)
    }

    @Test func aChatOnlySearchKeepsItsSectionAndConversationVisible() throws {
        let folder = TemporaryDirectory("sidebar-chat-search")
        let store = AppStore.shared
        let project = store.addProject(at: folder.url)
        let hadChats = store.chatsProject != nil
        let chats = store.ensureChatsProject()
        let projectThreadID = store.createThread(in: project.id).id
        let chatID = store.createThread(in: chats.id).id
        let query = "chatneedle" + UUID().uuidString.replacingOccurrences(of: "-", with: "")
        store.updateThread(chatID) { $0.title = query }
        defer {
            store.deleteThread(chatID)
            store.removeProject(project.id)
            if !hadChats { store.removeProject(chats.id) }
        }

        let sidebar = SidebarViewController()
        let outline = try #require(firstView(of: NSOutlineView.self, in: sidebar.view))
        let search = try #require(firstView(of: NSSearchField.self, in: sidebar.view))
        let empty = try #require(firstView(of: SidebarEmptyView.self, in: sidebar.view))
        let scroll = try #require(outline.enclosingScrollView)
        defer {
            search.stringValue = ""
            search.sendAction(search.action, to: search.target)
        }
        search.stringValue = query
        #expect(search.sendAction(search.action, to: search.target))

        let roots = rootSections(sidebar, outline)
        #expect(roots.map(\.kind) == [.chats(chats.id)])
        let chatsSection = try #require(roots.first)
        let chat = try #require(chatsSection.children.first { $0.threadID == chatID })
        #expect(sidebar.visibleThreadIDs == [chatID])
        #expect(outline.isItemExpanded(chatsSection))
        #expect(outline.row(forItem: chat) >= 0)
        #expect(empty.isHidden)
        #expect(!scroll.isHidden)

        search.stringValue = ""
        #expect(search.sendAction(search.action, to: search.target))
        #expect(rootSections(sidebar, outline).map(\.kind) == [.header, .chats(chats.id)])
        #expect(sidebar.visibleThreadIDs.contains(projectThreadID))
    }

    @Test func pinnedThreadsOfEveryProjectAreListedUnderPinnedAndReturnWhenUnpinned() throws {
        let folder = TemporaryDirectory("sidebar-pinned")
        let store = AppStore.shared
        let project = store.addProject(at: folder.url)
        let hadChats = store.chatsProject != nil
        let chats = store.ensureChatsProject()
        let threads = (0..<3).map { _ in store.createThread(in: project.id).id }
        let chatIDs = (0..<2).map { _ in store.createThread(in: chats.id).id }
        let savedOrder = UIState.shared.values.pinnedThreads
        defer {
            for id in chatIDs { store.deleteThread(id) }
            store.removeProject(project.id)
            if !hadChats { store.removeProject(chats.id) }
            UIState.shared.update { $0.pinnedThreads = savedOrder }
        }
        // Other tests' threads may be pinned in the shared store; these assertions look at this test's threads.
        let mine = Set(threads + chatIDs)
        let sidebar = SidebarViewController()
        let outline = try #require(firstView(of: NSOutlineView.self, in: sidebar.view))
        let pinnedSection = { self.rootSections(sidebar, outline).first { $0.kind == .pinned } }
        let listed = { (node: SidebarNode?) in (node?.children ?? []).compactMap(\.threadID).filter(mine.contains) }
        let projectNode = { self.rootSections(sidebar, outline).first { $0.kind == .header }?.children.first { $0.kind == .project(project.id) } }
        let chatsNode = { self.rootSections(sidebar, outline).first { $0.kind == .chats(chats.id) } }
        #expect(listed(pinnedSection()).isEmpty)

        store.updateThread(threads[1]) { $0.isPinned = true }
        store.updateThread(chatIDs[0]) { $0.isPinned = true }
        let pinned = try #require(pinnedSection())
        #expect(rootSections(sidebar, outline).first === pinned)
        // Pinned last, so on top.
        #expect(listed(pinned) == [chatIDs[0], threads[1]])
        #expect(!listed(projectNode()).contains(threads[1]) && listed(projectNode()).count == 2)
        #expect(listed(chatsNode()) == [chatIDs[1]])
        #expect(sidebar.visibleThreadIDs.filter(mine.contains).prefix(2) == [chatIDs[0], threads[1]])
        // The thread stays in its project for everything else.
        #expect(store.summary(threads[1])?.projectID == project.id)
        #expect(outline.row(forItem: try #require(pinned.children.first { $0.threadID == threads[1] })) >= 0)
        // A collapsed project still shows its pinned thread under Pinned.
        store.updateProject(project.id) { $0.isExpanded = false }
        #expect(listed(pinnedSection()).contains(threads[1]))
        store.updateProject(project.id) { $0.isExpanded = true }

        store.updateThread(threads[1]) { $0.isPinned = false }
        store.updateThread(chatIDs[0]) { $0.isPinned = false }
        #expect(listed(pinnedSection()).isEmpty)
        #expect(Set(listed(projectNode())) == Set(threads))
        #expect(Set(listed(chatsNode())) == Set(chatIDs))
        if store.threadSummaries.values.allSatisfy({ !$0.isPinned }) {
            // With nothing pinned, the section goes.
            #expect(pinnedSection() == nil)
        }
    }

    @Test func movingAThreadListsItInItsNewProjectAndUndoPutsItBack() throws {
        let folder = TemporaryDirectory("sidebar-move")
        let other = TemporaryDirectory("sidebar-move-to")
        let store = AppStore.shared
        let source = store.addProject(at: folder.url)
        let destination = store.addProject(at: other.url)
        defer {
            store.removeProject(source.id)
            store.removeProject(destination.id)
        }
        let id = store.createThread(in: source.id).id
        let sidebar = SidebarViewController()
        let outline = try #require(firstView(of: NSOutlineView.self, in: sidebar.view))
        let children = { (projectID: UUID) in
            self.rootSections(sidebar, outline).first { $0.kind == .header }?.children
                .first { $0.kind == .project(projectID) }?.children.compactMap(\.threadID) ?? []
        }
        #expect(children(source.id) == [id])
        #expect(ThreadActions.canMove([id], to: destination.id))
        #expect(!ThreadActions.canMove([id], to: source.id))

        ThreadActions.move([id], to: destination.id)
        #expect(store.summary(id)?.projectID == destination.id)
        #expect(children(destination.id) == [id] && children(source.id).isEmpty)
        let moved = try #require(rootSections(sidebar, outline).first { $0.kind == .header }?.children
            .first { $0.kind == .project(destination.id) }?.children.first)
        #expect(moved.threadID == id && outline.row(forItem: moved) >= 0)
        #expect(ThreadInbox.shared.undoManager.undoActionName == String(localized: "Move Threads"))

        ThreadInbox.shared.undo()
        #expect(store.summary(id)?.projectID == source.id)
        #expect(children(source.id) == [id] && children(destination.id).isEmpty)
        ThreadInbox.shared.redo()
        #expect(store.summary(id)?.projectID == destination.id)
        ThreadInbox.shared.undoManager.removeAllActions()

        // A worktree thread stays.
        store.updateThread(id) { $0.worktreePath = other.url.appendingPathComponent("tree").path }
        #expect(ThreadActions.moveBlocker(id) != nil)
        #expect(!ThreadActions.canMove([id], to: source.id))
        ThreadActions.move([id], to: source.id)
        #expect(store.summary(id)?.projectID == destination.id)
    }

    @Test func droppingThreadsOnAProjectMovesThemAndDroppingInPinnedReordersIt() throws {
        let folder = TemporaryDirectory("sidebar-drop")
        let other = TemporaryDirectory("sidebar-drop-to")
        let store = AppStore.shared
        let source = store.addProject(at: folder.url)
        let destination = store.addProject(at: other.url)
        let savedOrder = UIState.shared.values.pinnedThreads
        let savedSort = UIState.shared.values.projectSort
        defer {
            store.removeProject(source.id)
            store.removeProject(destination.id)
            UIState.shared.update { values in
                values.pinnedThreads = savedOrder
                values.projectSort = savedSort
            }
            ThreadInbox.shared.undoManager.removeAllActions()
        }
        let ids = (0..<3).map { _ in store.createThread(in: source.id).id }
        let sidebar = SidebarViewController()
        let outline = try #require(firstView(of: NSOutlineView.self, in: sidebar.view))
        let projects = { self.rootSections(sidebar, outline).first { $0.kind == .header }?.children ?? [] }
        let sourceNode = try #require(projects().first { $0.kind == .project(source.id) })
        let destinationNode = try #require(projects().first { $0.kind == .project(destination.id) })
        let dragged = try #require(sourceNode.children.first { $0.threadID == ids[0] })

        // Dragging a thread writes its id, which a drop on another project's row (or among its rows) accepts.
        let writer = try #require(sidebar.outlineView(outline, pasteboardWriterForItem: dragged) as? NSPasteboardItem)
        #expect(writer.string(forType: .coincideThread) == ids[0].uuidString)
        let drag = FakeDrag(source: outline, ids: [ids[0]])
        #expect(sidebar.outlineView(outline, validateDrop: drag, proposedItem: destinationNode, proposedChildIndex: 0) == .move)
        // Onto its own project there's nothing to do; between projects is no project at all.
        #expect(sidebar.outlineView(outline, validateDrop: drag, proposedItem: sourceNode, proposedChildIndex: -1) == [])
        let projectsSection = try #require(rootSections(sidebar, outline).first { $0.kind == .header })
        #expect(sidebar.outlineView(outline, validateDrop: drag, proposedItem: projectsSection, proposedChildIndex: 1) == [])
        #expect(sidebar.outlineView(outline, acceptDrop: drag, item: destinationNode, childIndex: -1))
        #expect(store.summary(ids[0])?.projectID == destination.id)

        // Projects sorted by name can't be dragged into another order.
        let projectDrag = FakeDrag(source: outline, ids: [], project: source.id)
        #expect(sidebar.outlineView(outline, validateDrop: projectDrag, proposedItem: projectsSection, proposedChildIndex: 0) == .move)
        UIState.shared.update { $0.projectSort = .name }
        #expect(sidebar.outlineView(outline, validateDrop: projectDrag, proposedItem: projectsSection, proposedChildIndex: 0) == [])

        // Pinned threads dropped in Pinned change its order; a pinned thread dropped on a project moves and stays pinned.
        store.updateThread(ids[1]) { $0.isPinned = true }
        store.updateThread(ids[2]) { $0.isPinned = true }
        let pinned = try #require(rootSections(sidebar, outline).first { $0.kind == .pinned })
        let mine = { pinned.children.compactMap(\.threadID).filter { ids.contains($0) } }
        #expect(mine() == [ids[2], ids[1]])
        let pinnedDrag = FakeDrag(source: outline, ids: [ids[1]])
        let first = try #require(pinned.children.firstIndex { $0.threadID == ids[2] })
        #expect(sidebar.outlineView(outline, validateDrop: pinnedDrag, proposedItem: pinned, proposedChildIndex: first) == .move)
        #expect(sidebar.outlineView(outline, acceptDrop: pinnedDrag, item: pinned, childIndex: first))
        #expect(mine() == [ids[1], ids[2]])
        // An unpinned thread can't be dropped into Pinned.
        #expect(sidebar.outlineView(outline, validateDrop: drag, proposedItem: pinned, proposedChildIndex: 0) == [])
        #expect(sidebar.outlineView(outline, acceptDrop: pinnedDrag, item: destinationNode, childIndex: -1))
        #expect(store.summary(ids[1])?.projectID == destination.id && store.summary(ids[1])?.isPinned == true)
        #expect(mine() == [ids[1], ids[2]])
    }

    @Test func sectionsFollowTheSavedOrderAndDraggingAHeaderReordersThem() throws {
        let folder = TemporaryDirectory("sidebar-section-order")
        let store = AppStore.shared
        let project = store.addProject(at: folder.url)
        let hadChats = store.chatsProject != nil
        let chats = store.ensureChatsProject()
        let pinnedID = store.createThread(in: project.id).id
        store.updateThread(pinnedID) { $0.isPinned = true }
        let saved = UIState.shared.values.sidebarSections
        defer {
            store.removeProject(project.id)
            if !hadChats { store.removeProject(chats.id) }
            UIState.shared.update { $0.sidebarSections = saved }
        }
        UIState.shared.update { $0.sidebarSections = [] }
        let sidebar = SidebarViewController()
        let outline = try #require(firstView(of: NSOutlineView.self, in: sidebar.view))
        let kinds = { self.rootSections(sidebar, outline).map(\.kind) }
        #expect(kinds() == [.pinned, .header, .chats(chats.id)])

        // Drag Chats onto the Pinned header: it goes above it.
        let pinnedNode = try #require(rootSections(sidebar, outline).first)
        let chatsNode = try #require(rootSections(sidebar, outline).last)
        let writer = try #require(sidebar.outlineView(outline, pasteboardWriterForItem: chatsNode) as? NSPasteboardItem)
        #expect(writer.string(forType: .coincideSection) == "chats")
        let drag = FakeDrag(source: outline, ids: [], section: .chats)
        #expect(sidebar.outlineView(outline, validateDrop: drag, proposedItem: pinnedNode, proposedChildIndex: -1) == .move)
        #expect(sidebar.outlineView(outline, acceptDrop: drag, item: nil, childIndex: 0))
        #expect(kinds() == [.chats(chats.id), .pinned, .header])
        // Bots, hidden without any bots, keeps its place too.
        #expect(UIState.shared.values.sidebarSections == ["bots", "chats", "pinned", "projects"])

        // With nothing pinned, Pinned goes but keeps its place for later.
        store.updateThread(pinnedID) { $0.isPinned = false }
        #expect(kinds() == [.chats(chats.id), .header])
        store.updateThread(pinnedID) { $0.isPinned = true }
        #expect(kinds() == [.chats(chats.id), .pinned, .header])

        // Dropped among a section's rows, a section goes below that section.
        let projectsNode = try #require(rootSections(sidebar, outline).last)
        let projectDrag = FakeDrag(source: outline, ids: [], section: .chats)
        let projectRow = try #require(projectsNode.children.first)
        #expect(sidebar.outlineView(outline, validateDrop: projectDrag, proposedItem: projectRow, proposedChildIndex: 0) == .move)
        #expect(sidebar.outlineView(outline, acceptDrop: projectDrag, item: nil, childIndex: 3))
        #expect(kinds() == [.pinned, .header, .chats(chats.id)])
    }

    @Test func botsAreTheFirstSectionWithOneRowPerBotThatHighlightsForItsConversations() throws {
        let store = AppStore.shared
        let saved = UIState.shared.values.sidebarSections
        UIState.shared.update { $0.sidebarSections = [] }
        let bot = store.addBot(
            Bot(name: "Pebbles", avatar: BotAvatar(shape: .pebble, tint: .sage), persona: "Be brief.",
                selection: ModelSelection(provider: .claude, modelID: "default")))
        let first = try #require(store.startConversation(with: bot.id))
        let second = try #require(store.startConversation(with: bot.id))
        store.append(TranscriptItem(kind: .assistant, text: "Hello there"), to: second.id)
        defer {
            store.deleteBot(bot.id, deletingConversations: true)
            UIState.shared.update { $0.sidebarSections = saved }
        }

        let sidebar = SidebarViewController()
        let outline = try #require(firstView(of: NSOutlineView.self, in: sidebar.view))
        sidebar.select(threadID: first.id)
        let roots = rootSections(sidebar, outline)
        let botsSection = try #require(roots.first)
        #expect(botsSection.kind == .bots)
        #expect(sidebar.outlineView(outline, isGroupItem: botsSection))
        // One row for the bot, however many conversations it has; they are not listed as threads.
        let row = try #require(botsSection.children.first { $0.kind == .bot(bot.id) })
        #expect(botsSection.children.filter { $0.kind == .bot(bot.id) }.count == 1)
        #expect(!roots.flatMap(\.children).contains { $0.threadID == first.id || $0.threadID == second.id })
        #expect(sidebar.outlineView(outline, shouldSelectItem: row))
        #expect(outline.selectedRow == outline.row(forItem: row))
        let cell = try #require(sidebar.outlineView(outline, viewFor: nil, item: row) as? BotCell)
        #expect(cell.accessibilityLabel()?.contains("Pebbles") == true)
        #expect(cell.accessibilityLabel()?.contains("Hello there") == true)
        // Conversations of bots stay put when dragged elsewhere.
        #expect(!store.canMoveThread(second.id, to: store.ensureChatsProject().id))
    }

    @Test func collapsedSectionsKeepTheirHeaderHideTheirRowsAndShowWhatTheyHide() throws {
        let folder = TemporaryDirectory("sidebar-collapse")
        let store = AppStore.shared
        let project = store.addProject(at: folder.url)
        let hadChats = store.chatsProject != nil
        let chats = store.ensureChatsProject()
        let threadID = store.createThread(in: project.id).id
        let otherID = store.createThread(in: project.id).id
        let chatID = store.createThread(in: chats.id).id
        let query = "collapseneedle" + UUID().uuidString.replacingOccurrences(of: "-", with: "")
        store.updateThread(chatID) { $0.title = query }
        let saved = (UIState.shared.values.collapsedSections, UIState.shared.values.sidebarSections)
        defer {
            ThreadActivity.shared.markSeen(otherID)
            store.deleteThread(chatID)
            store.removeProject(project.id)
            if !hadChats { store.removeProject(chats.id) }
            UIState.shared.update { values in
                values.collapsedSections = saved.0
                values.sidebarSections = saved.1
            }
        }
        UIState.shared.update { values in
            values.collapsedSections = []
            values.sidebarSections = []
        }
        let sidebar = SidebarViewController()
        let outline = try #require(firstView(of: NSOutlineView.self, in: sidebar.view))
        sidebar.select(threadID: threadID)
        let section = { (kind: SidebarNode.Kind) in self.rootSections(sidebar, outline).first { $0.kind == kind } }
        let projectsNode = try #require(section(.header))
        let projectNode = try #require(projectsNode.children.first { $0.kind == .project(project.id) })
        #expect(outline.row(forItem: projectNode) >= 0)
        let headerCell = { (node: SidebarNode) in sidebar.outlineView(outline, viewFor: nil, item: node) as? SidebarHeaderCell }
        let projectsHeader = try #require(headerCell(projectsNode))
        #expect(projectsHeader.toggleActionName == String(localized: "Collapse Projects"))

        // Collapsing Projects (VoiceOver's action, as a click on the header) keeps its header and drops its rows.
        let collapse = try #require(projectsHeader.accessibilityCustomActions()?.first?.handler)
        #expect(collapse())
        #expect(UIState.shared.values.collapsedSections == ["projects"])
        #expect(section(.header) === projectsNode)
        #expect(projectsNode.children.isEmpty)
        #expect(outline.row(forItem: projectsNode) >= 0)
        #expect(outline.row(forItem: projectNode) < 0)
        #expect(!sidebar.visibleThreadIDs.contains(threadID) && sidebar.visibleThreadIDs.contains(chatID))
        // The project's own expansion is left as it was.
        #expect(store.project(project.id)?.isExpanded == true)
        let collapsedHeader = try #require(headerCell(projectsNode))
        #expect(collapsedHeader.toggleActionName == String(localized: "Expand Projects"))
        // An unread thread inside shows on the collapsed header (unless other tests' threads already show something
        // more pressing in the shared store).
        let before = collapsedHeader.accessibilityLabel()
        ThreadActivity.shared.markUnread(otherID)
        let after = try #require(headerCell(projectsNode)).accessibilityLabel()
        if before == String(localized: "Projects") {
            #expect(after == String(localized: "Projects") + ", " + String(localized: "Completed"))
        } else {
            #expect(after != String(localized: "Projects"))
        }

        // The state is kept for the next launch.
        let relaunched = SidebarViewController()
        let relaunchedOutline = try #require(firstView(of: NSOutlineView.self, in: relaunched.view))
        #expect(rootSections(relaunched, relaunchedOutline).first { $0.kind == .header }?.children.isEmpty == true)

        // A search lists every match, collapsed or not, and its headers don't collapse.
        let search = try #require(firstView(of: NSSearchField.self, in: sidebar.view))
        UIState.shared.update { $0.collapsedSections = ["projects", "chats"] }
        search.stringValue = query
        #expect(search.sendAction(search.action, to: search.target))
        let chatsNode = try #require(section(.chats(chats.id)))
        #expect(chatsNode.children.contains { $0.threadID == chatID })
        #expect(try #require(headerCell(chatsNode)).toggleActionName == nil)
        search.stringValue = ""
        #expect(search.sendAction(search.action, to: search.target))
        #expect(section(.chats(chats.id))?.children.isEmpty == true)

        // Opening a thread of a collapsed section expands it.
        sidebar.select(threadID: chatID)
        #expect(UIState.shared.values.collapsedSections == ["projects"])
        #expect(section(.chats(chats.id))?.children.contains { $0.threadID == chatID } == true)
        #expect(outline.row(forItem: try #require(section(.chats(chats.id))?.children.first { $0.threadID == chatID })) >= 0)
        let expand = try #require(headerCell(projectsNode)?.accessibilityCustomActions()?.first?.handler)
        #expect(expand())
        #expect(UIState.shared.values.collapsedSections.isEmpty)
        #expect(projectsNode.children.contains(projectNode) && outline.row(forItem: projectNode) >= 0)
        #expect(sidebar.visibleThreadIDs.contains(threadID))
    }

    @Test func botsFollowTheChosenSortAndDragIntoANewManualOrder() throws {
        let store = AppStore.shared
        let saved = (UIState.shared.values.botSort, UIState.shared.values.collapsedSections)
        let selection = ModelSelection(provider: .claude, modelID: "default")
        let made = ["Zeta", "Alpha", "Mid"].map { name in
            store.addBot(Bot(name: name, avatar: BotAvatar(shape: .pebble, tint: .sage), persona: "", selection: selection))
        }
        let ids = made.map(\.id)
        let conversation = try #require(store.startConversation(with: ids[2]))
        store.append(TranscriptItem(kind: .assistant, text: "Latest"), to: conversation.id)
        defer {
            for id in ids { store.deleteBot(id, deletingConversations: true) }
            UIState.shared.update { values in
                values.botSort = saved.0
                values.collapsedSections = saved.1
            }
        }
        UIState.shared.update { $0.collapsedSections = [] }
        func listed(_ sort: BotSort) throws -> (SidebarViewController, NSOutlineView, SidebarNode, [UUID]) {
            UIState.shared.update { $0.botSort = sort }
            let sidebar = SidebarViewController()
            let outline = try #require(firstView(of: NSOutlineView.self, in: sidebar.view))
            let bots = try #require(rootSections(sidebar, outline).first { $0.kind == .bots })
            return (sidebar, outline, bots, bots.children.compactMap(\.botID).filter(ids.contains))
        }
        #expect(try listed(.manual).3 == ids)
        #expect(try listed(.name).3 == [ids[1], ids[2], ids[0]])
        #expect(try listed(.recentActivity).3.first == ids[2])

        // Sorted by name, there's no order of the user's to drag into.
        let (named, namedOutline, namedBots, _) = try listed(.name)
        let row = try #require(namedBots.children.first { $0.botID == ids[1] })
        let writer = try #require(named.outlineView(namedOutline, pasteboardWriterForItem: row) as? NSPasteboardItem)
        #expect(writer.string(forType: .coincideBot) == ids[1].uuidString)
        let namedDrag = FakeDrag(source: namedOutline, ids: [], bot: ids[1])
        #expect(named.outlineView(namedOutline, validateDrop: namedDrag, proposedItem: namedBots, proposedChildIndex: 0) == [])

        // By hand, dropping Mid before Zeta moves it there, in bots.json's order too.
        let (sidebar, outline, bots, _) = try listed(.manual)
        let drag = FakeDrag(source: outline, ids: [], bot: ids[2])
        let zeta = try #require(bots.children.firstIndex { $0.botID == ids[0] })
        #expect(sidebar.outlineView(outline, validateDrop: drag, proposedItem: bots, proposedChildIndex: zeta) == .move)
        // Dropped on Zeta's row, it goes before Zeta too; elsewhere, nowhere.
        #expect(sidebar.outlineView(outline, validateDrop: drag, proposedItem: bots.children[zeta], proposedChildIndex: -1) == .move)
        #expect(sidebar.outlineView(outline, validateDrop: drag, proposedItem: nil, proposedChildIndex: 0) == [])
        #expect(sidebar.outlineView(outline, acceptDrop: drag, item: bots, childIndex: zeta))
        #expect(store.bots.map(\.id).filter(ids.contains) == [ids[2], ids[0], ids[1]])
        #expect(bots.children.compactMap(\.botID).filter(ids.contains) == [ids[2], ids[0], ids[1]])
        // To the end.
        #expect(sidebar.outlineView(outline, acceptDrop: drag, item: bots, childIndex: bots.children.count))
        #expect(store.bots.map(\.id).filter(ids.contains) == [ids[0], ids[1], ids[2]])
    }

    private func rootSections(_ sidebar: SidebarViewController, _ outline: NSOutlineView) -> [SidebarNode] {
        (0..<sidebar.outlineView(outline, numberOfChildrenOfItem: nil)).compactMap {
            sidebar.outlineView(outline, child: $0, ofItem: nil) as? SidebarNode
        }
    }

    private func firstView<View: NSView>(of type: View.Type, in root: NSView) -> View? {
        if let match = root as? View { return match }
        for child in root.subviews {
            if let match = firstView(of: type, in: child) { return match }
        }
        return nil
    }
}

/// A drag from the sidebar itself, carrying threads, a project, a section or a bot, for its drop validation.
private final class FakeDrag: NSObject, NSDraggingInfo {
    let draggingSource: Any?
    let draggingPasteboard = NSPasteboard(name: NSPasteboard.Name("coincide-tests-\(UUID().uuidString)"))

    init(source: NSOutlineView, ids: [UUID], project: UUID? = nil, section: SidebarSection? = nil, bot: UUID? = nil) {
        draggingSource = source
        super.init()
        draggingPasteboard.clearContents()
        var items = ids.map { id in
            let item = NSPasteboardItem()
            item.setString(id.uuidString, forType: .coincideThread)
            return item
        }
        if let project {
            let item = NSPasteboardItem()
            item.setString(project.uuidString, forType: .coincideProject)
            items.append(item)
        }
        if let section {
            let item = NSPasteboardItem()
            item.setString(section.rawValue, forType: .coincideSection)
            items.append(item)
        }
        if let bot {
            let item = NSPasteboardItem()
            item.setString(bot.uuidString, forType: .coincideBot)
            items.append(item)
        }
        draggingPasteboard.writeObjects(items)
    }

    isolated deinit { draggingPasteboard.releaseGlobally() }

    var draggingDestinationWindow: NSWindow? { nil }
    var draggingSourceOperationMask: NSDragOperation { .move }
    var draggingLocation: NSPoint { .zero }
    var draggedImageLocation: NSPoint { .zero }
    var draggedImage: NSImage? { nil }
    var draggingSequenceNumber: Int { 1 }
    func slideDraggedImage(to screenPoint: NSPoint) {}
    var draggingFormation: NSDraggingFormation = .default
    var animatesToDestination = false
    var numberOfValidItemsForDrop = 1
    func enumerateDraggingItems(
        options enumOpts: NSDraggingItemEnumerationOptions = [], for view: NSView?, classes classArray: [AnyClass],
        searchOptions: [NSPasteboard.ReadingOptionKey: Any] = [:],
        using block: (NSDraggingItem, Int, UnsafeMutablePointer<ObjCBool>) -> Void
    ) {}
    var springLoadingHighlight: NSSpringLoadingHighlight { .none }
    func resetSpringLoading() {}
}
