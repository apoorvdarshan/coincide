import CoincideRemoteKit
import SwiftUI

@main
struct CoincideRemoteApp: App {
    @UIApplicationDelegateAdaptor(RemoteAppDelegate.self) private var appDelegate
    @State private var client = RemoteClient()
    @State private var appearance = AppearanceSettings()
    @State private var navigator = Navigator()
    @Environment(\.scenePhase) private var scenePhase

    var body: some Scene {
        WindowGroup {
            ThemedRoot(appearance: appearance, server: client.server) {
                RootView()
                    .modifier(AlertsCoordinator())
            }
            .environment(client)
            .environment(appearance)
            .environment(navigator)
            #if DEBUG
            .modifier(DebugWindowSizing())
            #endif
        }
        .onChange(of: scenePhase) { _, phase in
            if phase == .active { client.reconnectIfNeeded() }
        }
        .commands {
            CommandMenu("Thread") {
                Button("New Thread") { navigator.requestNewThread() }
                    .keyboardShortcut("n")
                    .disabled(!client.isConnected)
                Button("Search Threads") { navigator.focusSearch() }
                    .keyboardShortcut("f")
                Divider()
                Button("Reconnect") { client.reconnectIfNeeded() }
                    .keyboardShortcut("r")
            }
        }
    }
}

/// Becomes the notification delegate before launch finishes, so a tapped alert that launched the app opens its thread.
final class RemoteAppDelegate: NSObject, UIApplicationDelegate {
    func application(
        _ application: UIApplication, didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]? = nil
    ) -> Bool {
        PhoneAlerts.shared.start()
        return true
    }

    func application(_ application: UIApplication, didFailToRegisterForRemoteNotificationsWithError error: Error) {
        PhoneAlerts.shared.registrationFailed(error)
    }
}

/// The tabs along the bottom: what the Mac's sidebar holds, split the iPhone way, then Settings and Search.
enum AppTab: String, Hashable, CaseIterable {
    case bots, projects, chats, settings, search
}

/// A screen pushed inside a tab.
enum Route: Hashable {
    case thread(UUID)
    /// A bot's past conversations.
    case bot(UUID)

    var isThread: Bool {
        if case .thread = self { return true }
        return false
    }
}

/// Where the app is: the tab, what each tab has pushed, sheets, and requests from keyboard shortcuts. Lives above the
/// views, so a layout change (an iPad window resizing, a Duo folding) keeps it.
@MainActor
@Observable
final class Navigator {
    var tab: AppTab {
        didSet { UserDefaults.standard.set(tab.rawValue, forKey: "navigation.tab") }
    }
    /// Each tab's pushed screens.
    var paths: [AppTab: [Route]] = [:]
    var searchText = ""
    var showsConnect = false
    var newThreadRequests = 0
    var renaming: RemoteThreadSummary?
    var deleting: RemoteThreadSummary?
    var diff: DiffRequest?
    /// Threads opened lately, newest first. Their transcripts stay loaded so going back is instant.
    private(set) var recent: [UUID] = []
    /// Which tab and screen a thread belongs under, from the workspace. Set by the tab view.
    @ObservationIgnored var locate: (UUID) -> (tab: AppTab, parent: Route?) = { _ in (.chats, nil) }

    struct DiffRequest: Identifiable, Hashable {
        var threadID: UUID
        var turnID: UUID?
        var id: String { "\(threadID)/\(turnID?.uuidString ?? "thread")" }
    }

    init() {
        tab = AppTab(rawValue: UserDefaults.standard.string(forKey: "navigation.tab") ?? "") ?? .projects
        if tab == .search { tab = .projects }
        #if DEBUG
        if let index = ProcessInfo.processInfo.arguments.firstIndex(of: "-CoincideRemoteTab"),
            index + 1 < ProcessInfo.processInfo.arguments.count,
            let requested = AppTab(rawValue: ProcessInfo.processInfo.arguments[index + 1])
        {
            tab = requested
        }
        if DemoData.isEnabled, ProcessInfo.processInfo.arguments.contains("-CoincideRemoteDemoThread") {
            paths[tab] = [.thread(DemoData.threadID)]
        }
        #endif
    }

    /// Whether the window is wide enough to show the list and the open thread side by side (an iPad, an unfolded Duo).
    /// Set by the tab view from its size class. Each tab's path keeps its thread last, so the same path reads both ways.
    var isSplit = false

    func path(_ tab: AppTab) -> Binding<[Route]> {
        Binding(get: { self.paths[tab] ?? [] }, set: { self.paths[tab] = $0 })
    }

    /// Side by side: what the list column has pushed (a bot's past conversations), without the thread.
    func listPath(_ tab: AppTab) -> Binding<[Route]> {
        Binding(
            get: { (self.paths[tab] ?? []).filter { !$0.isThread } },
            set: { routes in
                let thread = self.paths[tab]?.last.flatMap { $0.isThread ? $0 : nil }
                self.paths[tab] = routes + (thread.map { [$0] } ?? [])
            })
    }

    /// Side by side: the thread the detail column shows.
    func detailThread(_ tab: AppTab) -> UUID? {
        if case .thread(let id)? = paths[tab]?.last { return id }
        return nil
    }

    /// The thread on screen in the current tab, if any. Setting a thread opens it where it belongs; nil goes back from
    /// the open thread.
    var selection: UUID? {
        get {
            if case .thread(let id)? = paths[tab]?.last { return id }
            return nil
        }
        set {
            if let newValue {
                open(newValue)
            } else if case .thread? = paths[tab]?.last {
                paths[tab]?.removeLast()
            }
        }
    }

    /// Shows a thread under its tab (its project, a bot's conversations or Chats), or in place within Search.
    func open(_ threadID: UUID) {
        if tab == .search {
            paths[.search, default: []].append(.thread(threadID))
            return
        }
        let place = locate(threadID)
        tab = place.tab
        paths[place.tab] = (place.parent.map { [$0] } ?? []) + [.thread(threadID)]
    }

    /// Pushes a screen on the current tab. Side by side, a thread takes the detail column's place instead of stacking.
    func push(_ route: Route) {
        if isSplit, case .thread? = paths[tab]?.last {
            paths[tab]?.removeLast()
        }
        if isSplit, !route.isThread {
            // A list screen goes under the open thread, which stays in the detail column.
            let thread = paths[tab]?.last.flatMap { $0.isThread ? $0 : nil }
            if thread != nil { paths[tab]?.removeLast() }
            paths[tab, default: []].append(route)
            if let thread { paths[tab, default: []].append(thread) }
            return
        }
        paths[tab, default: []].append(route)
    }

    /// Back to the tabs' first screens, as after pairing another Mac.
    func reset() {
        paths = [:]
    }

    func noteOpened(_ threadID: UUID) {
        recent.removeAll { $0 == threadID }
        recent.insert(threadID, at: 0)
    }

    func requestNewThread() { newThreadRequests += 1 }

    func focusSearch() { tab = .search }
}

struct RootView: View {
    @Environment(RemoteClient.self) private var client
    @Environment(Navigator.self) private var navigator

    var body: some View {
        @Bindable var navigator = navigator
        Group {
            if client.mac == nil {
                NavigationStack { ConnectView(isOnboarding: true) }
            } else {
                MainTabView()
            }
        }
        .sheet(isPresented: $navigator.showsConnect) {
            NavigationStack { ConnectView(isOnboarding: false) }
        }
        .sheet(item: $navigator.diff) { request in DiffView(request: request) }
        .overlay(alignment: .top) { NoticeBanner() }
    }
}

/// A short message at the top of the screen, such as an action the Mac refused.
struct NoticeBanner: View {
    @Environment(RemoteClient.self) private var client

    var body: some View {
        if let notice = client.notice {
            Text(notice)
                .font(.callout)
                .padding(.horizontal, 16)
                .padding(.vertical, 10)
                .glassEffect(.regular, in: .capsule)
                .padding(.top, 8)
                .padding(.horizontal)
                .transition(.move(edge: .top).combined(with: .opacity))
                .task(id: notice) {
                    UIAccessibility.post(notification: .announcement, argument: notice)
                    try? await Task.sleep(for: .seconds(3))
                    guard !Task.isCancelled else { return }
                    withAnimation { client.notice = nil }
                }
                .onTapGesture { withAnimation { client.notice = nil } }
                .accessibilityAddTraits(.isStaticText)
        }
    }
}
