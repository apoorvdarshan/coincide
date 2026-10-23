import AppKit
import CoincideCore
import Observation
import SwiftUI

/// App-level desktop integration owned by AppDelegate: login-shell environment, quit
/// protection, power assertions, in-app banners, deep links, the welcome flow and
/// auxiliary windows. Hub files only forward lifecycle events here.
@MainActor
final class DesktopShell {
    static let shared = DesktopShell()
    static let productBundleIdentifier = "com.apoorvdarshan.coincide"

    let isProductApp: Bool
    let isUITesting: Bool
    let environment: ShellEnvironmentController
    let banners = InAppBannerCenter.shared
    let windows = AuxiliaryWindows()
    let commandLineTool = CommandLineToolController()
    private(set) var quitShortcut: QuitShortcutMonitor?
    private(set) var activity: AgentActivityAssertion?
    private(set) var deepLinks: DeepLinkRouter?
    private weak var store: WorkspaceStore?
    private weak var remoteStore: RemoteWorkspaceStore?
    private weak var mainWindows: MainWindowCoordinator?
    private var pendingLinks: [URL] = []
    private var loaded = false
    private var linkTail: Task<Void, Never>?

    /// Process-wide side effects (login-shell capture, the ⌘Q monitor, power assertions and the
    /// automatic welcome window) run only in the packaged app. SwiftPM tests and the synthetic
    /// UI-test copy keep their exact environment and a single-press ⌘Q.
    init(bundleIdentifier: String? = Bundle.main.bundleIdentifier, processEnvironment: [String: String] = ProcessInfo.processInfo.environment) {
        isProductApp = bundleIdentifier == Self.productBundleIdentifier
        isUITesting = bundleIdentifier == AppLaunchConfiguration.uiTestingBundleIdentifier
        environment = ShellEnvironmentController(available: isProductApp && processEnvironment["COINCIDE_LOGIN_SHELL_ENV"] != "0")
    }

    func attach(store: WorkspaceStore, remoteStore: RemoteWorkspaceStore?, mainWindows: MainWindowCoordinator) {
        guard self.store == nil else { return }
        self.store = store; self.remoteStore = remoteStore; self.mainWindows = mainWindows
        environment.start()
        store.notifications.banners = ThreadBannerCoordinator(center: banners, selectedThreadID: { [weak store] in store?.selectedThreadID }) { [weak self, weak store] id in
            guard let store, let thread = store.thread(id), store.snapshot.projects.contains(where: { $0.id == thread.projectID }) else { return }
            store.selectedProjectID = thread.projectID; store.showArchived = thread.isArchived; store.selectedThreadID = id
            self?.mainWindows?.presentIfNeeded()
        }
        deepLinks = DeepLinkRouter(store: store, banners: banners)
        guard isProductApp else { return }
        quitShortcut = QuitShortcutMonitor(defaultMode: .hold) { NSApp.terminate(nil) }
        quitShortcut?.install()
        activity = AgentActivityAssertion { [weak store, weak remoteStore] in
            (store?.snapshot.threads.filter(\.isBusy).count ?? 0) + (remoteStore?.activeRunCount ?? 0)
        }
        activity?.start()
    }

    /// Bounded: launch continues after `budget` even if the shell is still starting.
    func prepareEnvironment(budget: Duration = .seconds(3)) async { await environment.waitForCapture(budget: budget) }

    func didLoad() {
        loaded = true
        let links = pendingLinks; pendingLinks.removeAll()
        for url in links { route(url) }
        presentWelcomeIfNeeded()
    }

    // MARK: Links

    /// Returns true when the URL is a `coincide://` link handled here.
    func handle(_ url: URL) -> Bool {
        guard DeepLinkRouter.isDeepLink(url) else { return false }
        if loaded { route(url) } else { pendingLinks.append(url) }
        return true
    }

    private func route(_ url: URL) {
        guard let deepLinks else { return }
        mainWindows?.presentIfNeeded()
        NSApp?.activate(ignoringOtherApps: true)
        let previous = linkTail
        linkTail = Task { await previous?.value; await deepLinks.open(url) }
    }

    // MARK: Quit

    static let runningQuitPreference = "confirmQuitWithRunningConversations"
    var runningWork: QuitRunningWork {
        QuitRunningWork(snapshot: store?.snapshot ?? .init(), remoteConversations: remoteStore?.activeRunCount ?? 0)
    }

    /// Asked first in applicationShouldTerminate, before the unsaved-work guards.
    func confirmQuitWithRunningWork(defaults: UserDefaults = .standard) -> Bool {
        let work = runningWork
        guard !work.isEmpty, defaults.object(forKey: Self.runningQuitPreference) as? Bool ?? isProductApp else { return true }
        let alert = NSAlert()
        alert.messageText = work.title
        alert.informativeText = work.detail
        alert.alertStyle = .warning
        alert.addButton(withTitle: String(localized: "Cancel"))
        alert.addButton(withTitle: String(localized: "Quit"))
        alert.showsSuppressionButton = true
        alert.suppressionButton?.title = String(localized: "Don't ask again")
        let quit = alert.runModal() == .alertSecondButtonReturn
        if quit, alert.suppressionButton?.state == .on { defaults.set(false, forKey: Self.runningQuitPreference) }
        return quit
    }

    func willTerminate() {
        quitShortcut?.uninstall()
        activity?.shutdown()
    }

    // MARK: Welcome and auxiliary windows

    static let welcomeCompletedPreference = "welcomeCompletedAt"
    func presentWelcomeIfNeeded(defaults: UserDefaults = .standard) {
        guard let store else { return }
        let decision = FirstRunDecision.decide(loaded: store.hasLoadedWorkspace, completed: defaults.object(forKey: Self.welcomeCompletedPreference) != nil,
                                               projectCount: store.snapshot.projects.count, threadCount: store.snapshot.threads.count, enabled: isProductApp)
        switch decision {
        case .wizard: showWelcome()
        case .app:
            // An existing workspace counts as set up, so setup never appears later on its own.
            if isProductApp, store.hasLoadedWorkspace, defaults.object(forKey: Self.welcomeCompletedPreference) == nil { markWelcomeCompleted(defaults: defaults) }
        case .pending: break
        }
    }

    func markWelcomeCompleted(defaults: UserDefaults = .standard) {
        defaults.set(Date().timeIntervalSince1970, forKey: Self.welcomeCompletedPreference)
    }

    func showWelcome() {
        guard let store else { return }
        windows.show(id: "welcome", title: String(localized: "Welcome to Coincide"), size: .init(width: 640, height: 560), onClose: { [weak self] in
            self?.markWelcomeCompleted()
        }) {
            WelcomeWizardView(store: store, environment: self.environment) { [weak self] in
                self?.markWelcomeCompleted(); self?.windows.close(id: "welcome"); self?.mainWindows?.presentIfNeeded()
            }
        }
    }

    func showLicenses() {
        windows.show(id: "licenses", title: String(localized: "Open-Source Licenses"), size: .init(width: 760, height: 520)) {
            OpenSourceLicensesView(directory: Bundle.main.resourceURL?.appendingPathComponent("Notices", isDirectory: true))
        }
    }

    // MARK: Prompt links

    func copyPromptLink(includeContext: Bool) {
        guard let store, let thread = store.selectedThread else { return }
        let draft = thread.draft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !draft.isEmpty else { return }
        guard draft.utf16.count <= PromptLink.maximumPromptLength else {
            banners.post(.warning, title: String(localized: "Draft too long for a link"), detail: String(localized: "Prompt links hold up to 8,000 characters."), key: "prompt-link")
            return
        }
        var repository: PromptLink.Repository?
        if includeContext, let identity = store.snapshot.projects.first(where: { $0.id == thread.projectID })?.repositoryIdentity,
           identity.provider == "github", identity.canonicalKey.hasPrefix("github.com/"), let owner = identity.owner {
            repository = PromptLink.repository("\(owner)/\(identity.name)")
        }
        let provider = includeContext && thread.provider != .acp ? thread.provider.rawValue : nil
        let model = includeContext && !thread.model.isEmpty ? thread.model : nil
        guard let url = PromptLink.newThreadURL(prompt: draft, repository: repository, provider: provider, model: model) else { return }
        NSPasteboard.general.clearContents(); NSPasteboard.general.setString(url.absoluteString, forType: .string)
        banners.post(.success, title: String(localized: "Prompt link copied"),
                     detail: String(localized: "Opening it puts this prompt in a new draft. Nothing is sent automatically."), key: "prompt-link")
    }

    func copyConversationLink() {
        guard let id = store?.selectedThreadID, let url = PromptLink.threadURL(id: id) else { return }
        NSPasteboard.general.clearContents(); NSPasteboard.general.setString(url.absoluteString, forType: .string)
        banners.post(.success, title: String(localized: "Conversation link copied"), key: "prompt-link")
    }
}

extension RemoteWorkspaceStore {
    /// Conversations with active work on the connected remote host; disconnecting stops them.
    var activeRunCount: Int {
        guard isConnected else { return 0 }
        if usesProjection {
            var ids = Set(projection.threads.filter { $0.state == .running || $0.state == .awaitingApproval }.map(\.id))
            if let detail = projection.control?.detail, detail.activeRun != nil || detail.isBusy { ids.insert(detail.summary.id) }
            return ids.count
        }
        return snapshot?.workspace.threads.filter(\.isBusy).count ?? 0
    }
}

/// Login-shell environment status and refresh for Settings.
@MainActor @Observable
final class ShellEnvironmentController {
    static let preference = "loginShellEnvironmentEnabled"
    let available: Bool
    private(set) var snapshot: LoginShellEnvironment.Snapshot?
    private(set) var isCapturing = false
    @ObservationIgnored private var capture: Task<Void, Never>?
    @ObservationIgnored private var generation = 0
    @ObservationIgnored private let defaults: UserDefaults
    @ObservationIgnored private let configuration: @Sendable () -> LoginShellEnvironment.Configuration

    init(available: Bool, defaults: UserDefaults = .standard,
         configuration: @escaping @Sendable () -> LoginShellEnvironment.Configuration = { .system() }) {
        self.available = available; self.defaults = defaults; self.configuration = configuration
    }

    var isEnabled: Bool { available && (defaults.object(forKey: Self.preference) as? Bool ?? true) }

    func start() {
        guard capture == nil, isEnabled else { return }
        isCapturing = true; generation += 1
        let configuration = self.configuration, owner = generation
        capture = Task { [weak self] in
            let snapshot = await LoginShellEnvironment.capture(configuration())
            guard let self, self.generation == owner, self.isEnabled else { return }
            LoginShellEnvironment.publish(snapshot)
            self.snapshot = snapshot; self.isCapturing = false
        }
    }

    func waitForCapture(budget: Duration) async {
        guard let capture else { return }
        await withTaskGroup(of: Void.self) { group in
            group.addTask { await capture.value }
            group.addTask { try? await Task.sleep(for: budget) }
            await group.next(); group.cancelAll()
        }
    }

    /// New provider, terminal and Git launches use the result; running sessions keep theirs.
    func refresh() async {
        capture?.cancel(); capture = nil
        guard isEnabled else { return }
        start()
        await capture?.value
    }

    func setEnabled(_ enabled: Bool) async {
        defaults.set(enabled, forKey: Self.preference)
        if enabled { await refresh() } else {
            capture?.cancel(); capture = nil; isCapturing = false; generation += 1
            LoginShellEnvironment.publish(nil); snapshot = nil
        }
    }

    var summary: String {
        guard available else { return String(localized: "Not used in this build") }
        guard isEnabled else { return String(localized: "Off — new launches use the inherited environment") }
        if isCapturing && snapshot == nil { return String(localized: "Reading your login shell…") }
        guard let snapshot else { return String(localized: "Not captured yet") }
        switch snapshot.source {
        case .loginShell(let shell):
            return String(localized: "\(URL(fileURLWithPath: shell).lastPathComponent): \(snapshot.pathEntryCount) PATH entries")
        case .launchctl: return String(localized: "launchd PATH: \(snapshot.pathEntryCount) entries")
        case .none: return String(localized: "Unavailable — using the inherited environment")
        }
    }
}

/// Installs or removes the `coincide` command for Settings.
@MainActor @Observable
final class CommandLineToolController {
    private(set) var state: CLIShimInstaller.State = .notInstalled
    private(set) var message: String?
    private(set) var isWorking = false

    private func installer() -> CLIShimInstaller {
        let path = LoginShellEnvironment.current?.applied(to: ProcessInfo.processInfo.environment, extraPaths: [])["PATH"] ?? ProcessInfo.processInfo.environment["PATH"] ?? ""
        return CLIShimInstaller(pathEntries: path.split(separator: ":").map(String.init))
    }

    func refresh() {
        let installer = installer()
        state = installer.state(); message = nil
        if case .installed = state, let foreign = installer.foreignCommandOnPath() {
            message = String(localized: "Another coincide command at \(foreign.path) runs first on PATH.")
        }
    }

    func install() {
        isWorking = true; defer { isWorking = false }
        let script = CLIShim.script(appPath: Bundle.main.bundleURL.path, bundleIdentifier: Bundle.main.bundleIdentifier ?? DesktopShell.productBundleIdentifier)
        do {
            let result = try installer().install(script: script)
            state = .installed(result.url)
            if let shadow = result.shadowedBy { message = String(localized: "Installed, but another coincide command at \(shadow.path) runs first on PATH.") }
            else if !result.onPath { message = String(localized: "Installed at \(result.url.path). Add \(result.url.deletingLastPathComponent().path) to PATH to run it as coincide.") }
            else { message = String(localized: "Run coincide in Terminal to open the current folder.") }
        } catch { message = error.localizedDescription }
    }

    func remove() {
        isWorking = true; defer { isWorking = false }
        do { try installer().remove(); state = .notInstalled; message = nil }
        catch { message = error.localizedDescription }
    }
}

/// Single-instance AppKit windows for Welcome and licenses, outside the main scene.
@MainActor
final class AuxiliaryWindows {
    private var windows: [String: NSWindow] = [:]
    private var closeObservers: [String: any NSObjectProtocol] = [:]

    func show<Content: View>(id: String, title: String, size: CGSize, onClose: (@MainActor () -> Void)? = nil, @ViewBuilder content: () -> Content) {
        if let window = windows[id] { window.makeKeyAndOrderFront(nil); NSApp.activate(ignoringOtherApps: true); return }
        let window = NSWindow(contentViewController: NSHostingController(rootView: content()))
        window.title = title; window.identifier = .init("coincide-" + id)
        window.styleMask = [.titled, .closable, .miniaturizable, .resizable]
        window.isReleasedWhenClosed = false; window.setContentSize(size); window.center()
        windows[id] = window
        closeObservers[id] = NotificationCenter.default.addObserver(forName: NSWindow.willCloseNotification, object: window, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                if let observer = self.closeObservers.removeValue(forKey: id) { NotificationCenter.default.removeObserver(observer) }
                self.windows.removeValue(forKey: id)
                onClose?()
            }
        }
        window.makeKeyAndOrderFront(nil); NSApp.activate(ignoringOtherApps: true)
    }

    func close(id: String) { windows[id]?.close() }
    func isOpen(_ id: String) -> Bool { windows[id] != nil }
}
