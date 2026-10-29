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

/// Where the app is: the open thread, sheets, and requests from keyboard shortcuts. Lives above the views, so a
/// layout change (an iPad window resizing, a Duo folding) keeps it.
@MainActor
@Observable
final class Navigator {
    var selection: UUID? {
        didSet { if selection != oldValue, let selection { recent.removeAll { $0 == selection }; recent.insert(selection, at: 0) } }
    }
    var columnVisibility = NavigationSplitViewVisibility.all
    var searchText = ""
    var isSearching = false
    var showsSettings = false
    var showsConnect = false
    var newThreadRequests = 0
    var renaming: RemoteThreadSummary?
    var deleting: RemoteThreadSummary?
    var diff: DiffRequest?
    /// Threads opened lately, newest first. Their transcripts stay loaded so going back is instant.
    private(set) var recent: [UUID] = []

    struct DiffRequest: Identifiable, Hashable {
        var threadID: UUID
        var turnID: UUID?
        var id: String { "\(threadID)/\(turnID?.uuidString ?? "thread")" }
    }

    init() {
        #if DEBUG
        if DemoData.isEnabled, ProcessInfo.processInfo.arguments.contains("-CoincideRemoteDemoThread") {
            selection = DemoData.threadID
        }
        #endif
    }

    func requestNewThread() { newThreadRequests += 1 }

    func focusSearch() {
        columnVisibility = .all
        isSearching = true
    }
}

struct RootView: View {
    @Environment(RemoteClient.self) private var client
    @Environment(Navigator.self) private var navigator
    @Environment(\.theme) private var theme

    var body: some View {
        @Bindable var navigator = navigator
        Group {
            if client.mac == nil {
                NavigationStack { ConnectView(isOnboarding: true) }
            } else {
                MainSplitView()
            }
        }
        .sheet(isPresented: $navigator.showsSettings) { SettingsView() }
        .sheet(isPresented: $navigator.showsConnect) {
            NavigationStack { ConnectView(isOnboarding: false) }
        }
        .sheet(item: $navigator.diff) { request in DiffView(request: request) }
        .overlay(alignment: .top) { NoticeBanner() }
    }
}

struct MainSplitView: View {
    @Environment(RemoteClient.self) private var client
    @Environment(Navigator.self) private var navigator
    @Environment(\.theme) private var theme

    var body: some View {
        @Bindable var navigator = navigator
        NavigationSplitView(columnVisibility: $navigator.columnVisibility) {
            SidebarView()
                .navigationSplitViewColumnWidth(min: 280, ideal: 320, max: 420)
        } detail: {
            NavigationStack {
                if let id = navigator.selection {
                    ThreadContainer(threadID: id)
                        .id(id)
                } else {
                    EmptyDetailView()
                }
            }
        }
        .navigationSplitViewStyle(.balanced)
        .onChange(of: navigator.recent) { _, recent in
            // Keep the last few threads following the Mac; stop the rest.
            for id in client.threads.keys where !recent.prefix(4).contains(id) { client.close(id) }
        }
        .modifier(ThreadActionDialogs())
        #if DEBUG
        // Testing in the simulator without taps: open the first thread once the sidebar arrives.
        .onChange(of: client.workspace.threads.first?.id) { _, id in
            if ProcessInfo.processInfo.arguments.contains("-CoincideRemoteOpenFirstThread"), navigator.selection == nil {
                navigator.selection = id
            }
        }
        #endif
    }
}

struct EmptyDetailView: View {
    @Environment(RemoteClient.self) private var client
    @Environment(\.theme) private var theme

    var body: some View {
        ContentUnavailableView {
            Label(client.mac?.name ?? "Coincide", systemImage: "macbook.and.iphone")
        } description: {
            Text("Pick a thread, or start a new one.")
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(theme.content)
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
