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
