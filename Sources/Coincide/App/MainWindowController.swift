import AppKit
import CoincideCore
import Observation
import SwiftUI

/// Presentations that stay owned by ContentView's state.
struct MainWindowPresentations {
    var newProject: @MainActor () -> Void = {}
    var cloneRepository: @MainActor () -> Void = {}
    var importAgentProjects: @MainActor () -> Void = {}
    var settle: @MainActor (CodingThread) -> Void = { _ in }
    var runScript: @MainActor (CodingThread) -> Void = { _ in }
    var toggleTerminal: @MainActor () -> Void = {}
    var terminalVisible: @MainActor () -> Bool = { false }
    var newWindow: @MainActor () -> Void = {}
    var openRemote: @MainActor () -> Void = {}
    var openSettings: @MainActor () -> Void = {}
}

/// Saved appearance values, shared with Settings through `@AppStorage("appearance")`.
enum AppearanceMode: String, CaseIterable, Identifiable, Sendable {
    case system, light, dark
    static let defaultsKey = "appearance"
    var id: String { rawValue }
    var title: String {
        switch self {
        case .system: String(localized: "System")
        case .light: String(localized: "Light")
        case .dark: String(localized: "Dark")
        }
    }
    var symbol: String {
        switch self {
        case .system: "circle.lefthalf.filled"
        case .light: "sun.max"
        case .dark: "moon"
        }
    }
    /// System → Light → Dark → System; unknown stored values count as System.
    static func next(after raw: String?) -> AppearanceMode {
        switch AppearanceMode(rawValue: raw ?? "") ?? .system {
        case .system: .light
        case .light: .dark
        case .dark: .system
        }
    }
    static func current(_ defaults: UserDefaults = .standard) -> AppearanceMode {
        AppearanceMode(rawValue: defaults.string(forKey: defaultsKey) ?? "") ?? .system
    }
    @discardableResult static func cycle(_ defaults: UserDefaults = .standard) -> AppearanceMode {
        let next = next(after: defaults.string(forKey: defaultsKey))
        defaults.set(next.rawValue, forKey: defaultsKey); return next
    }
}

/// Per-window command target: everything the menus, the command palette and the
/// keyboard dispatcher can do in one main window. The remote window has none,
/// so these commands disable there.
@MainActor @Observable
final class MainWindowController {
    let store: WorkspaceStore
    @ObservationIgnored weak var keybindings: KeybindingsStore?
    @ObservationIgnored var presentations = MainWindowPresentations()
    @ObservationIgnored weak var window: NSWindow?
    @ObservationIgnored var pasteboard: NSPasteboard = .general
    @ObservationIgnored var defaults: UserDefaults = .standard
    @ObservationIgnored var focusComposerAction: (@MainActor () -> Void)?
    private(set) var palette: CommandPaletteModel?
    private(set) var find: ThreadFindModel?
    private(set) var inspectorRequest: InspectorRequest?
    /// The inspector's visible tab, reported by WorkspaceInspector.
    var inspectorTab = InspectorTab.changes
    private(set) var jumpHintsVisible = false
    private(set) var notice: String?
    private(set) var history = ThreadNavigationHistory()
    private(set) var closedViews = ClosedViewHistory()
    @ObservationIgnored private var noticeTask: Task<Void, Never>?
    @ObservationIgnored private var hintTask: Task<Void, Never>?

    init(store: WorkspaceStore, keybindings: KeybindingsStore? = nil) {
        self.store = store; self.keybindings = keybindings
        history.visit(store.selectedThreadID)
    }

    var selectedThread: CodingThread? { store.selectedThread }

    // MARK: Availability

    func canPerform(_ command: KeybindingCommand) -> Bool {
        let thread = store.selectedThread
        switch command {
        case .sidebarToggle, .commandPaletteToggle, .themeSelect, .appearanceCycle, .rightPanelToggle, .windowNew, .remoteOpen,
             .projectNew, .projectAdd, .projectClone, .projectImport: return !store.isLoading
        case .chatNew, .chatNewLocal: return !store.isLoading && !store.snapshot.projects.isEmpty
        case .navigationBack: return history.canGoBack(isValid: store.canNavigate(to:))
        case .navigationForward: return history.canGoForward(isValid: store.canNavigate(to:))
        case .terminalToggle: return thread.map(store.workspaceReady(for:)) ?? false
        case .viewReopenClosed: return !closedViews.isEmpty
        case .diffToggle: return thread.map(store.canPresentWorkspaceInspector(for:)) ?? false
        case .filePickerToggle, .projectSearchToggle, .editorOpenFavorite:
            return thread.map { store.canAccessWorkspaceFiles($0.workspacePath) } ?? false
        case .chatFind, .threadCopyReference: return thread != nil
        case .threadPin: return thread != nil
        case .threadStop: return thread.map { store.isBusy($0.id) } ?? false
        case .threadSettle:
            guard let thread else { return false }
            if let settlement = thread.settlement { return settlement.phase != .resuming }
            return store.canSettle(thread)
        case .threadPrevious: return store.adjacentThread(.previous) != nil
        case .threadNext: return store.adjacentThread(.next) != nil
        default:
            if let number = command.threadJumpNumber { return store.threadForJump(number) != nil }
            return false
        }
    }

    /// Runs a command; false when it does not apply in this window right now.
    @discardableResult func perform(_ command: KeybindingCommand) -> Bool {
        guard canPerform(command) else { return false }
        let thread = store.selectedThread
        switch command {
        case .sidebarToggle: return toggleSidebar()
        case .commandPaletteToggle: palette == nil ? openPalette() : closePalette()
        case .themeSelect: openPalette(); palette?.open(view: CommandPaletteItems.appearanceView(self))
        case .appearanceCycle:
            let mode = AppearanceMode.cycle(defaults)
            showNotice(String(localized: "Appearance: \(mode.title)"))
        case .rightPanelToggle: store.inspectorVisible.toggle()
        case .diffToggle:
            if store.inspectorVisible, inspectorTab == .changes { store.inspectorVisible = false }
            else { store.inspectorVisible = true; inspectorRequest = .init(tab: .changes) }
        case .filePickerToggle: store.inspectorVisible = true; inspectorRequest = .init(tab: .files, searchMode: .paths, focusSearch: true)
        case .projectSearchToggle: store.inspectorVisible = true; inspectorRequest = .init(tab: .files, searchMode: .contents, focusSearch: true)
        case .viewReopenClosed: return reopenClosedView()
        case .navigationBack:
            guard let id = history.goBack(isValid: store.canNavigate(to:)) else { return false }
            store.selectThread(id)
        case .navigationForward:
            guard let id = history.goForward(isValid: store.canNavigate(to:)) else { return false }
            store.selectThread(id)
        case .terminalToggle: presentations.toggleTerminal()
        case .chatNew, .chatNewLocal: store.newThread()
        case .chatFind: openFind()
        case .editorOpenFavorite:
            guard let path = thread?.workspacePath else { return false }
            Task { [store] in
                do { try await store.externalEditors().open(ExternalEditorTarget(workspaceRoot: URL(fileURLWithPath: path))) }
                catch is CancellationError { }
                catch { store.errorMessage = error.localizedDescription }
            }
        case .threadStop:
            guard let id = thread?.id else { return false }
            Task { [store] in await store.interrupt(id) }
        case .threadPin:
            guard let thread else { return false }
            store.togglePin(thread.id)
            showNotice(thread.isPinned ? String(localized: "Unpinned “\(thread.title)”") : String(localized: "Pinned “\(thread.title)”"))
        case .threadSettle:
            guard let thread else { return false }
            if let settlement = thread.settlement { store.requestResume(thread.id, generationID: settlement.id) }
            else { presentations.settle(thread) }
        case .threadCopyReference: return copyThreadReference()
        case .threadPrevious, .threadNext:
            guard let id = store.adjacentThread(command == .threadPrevious ? .previous : .next) else { return false }
            store.selectThread(id)
        case .projectNew: presentations.newProject()
        case .projectAdd: store.addProject()
        case .projectClone: presentations.cloneRepository()
        case .projectImport: presentations.importAgentProjects()
        case .windowNew: presentations.newWindow()
        case .remoteOpen: presentations.openRemote()
        default:
            guard let number = command.threadJumpNumber, let id = store.threadForJump(number) else { return false }
            store.selectThread(id)
        }
        return true
    }

    // MARK: History and closed views

    /// Records a selection change for back/forward; history-driven selections are already current.
    func selectionChanged(to id: UUID?) {
        history.visit(id)
        if let find, find.threadID != id { self.find = nil }
    }

    /// Records the inspector view that was just hidden so ⇧⌘T can reopen it.
    func inspectorWillHide() {
        guard let thread = store.selectedThread, store.canPresentWorkspaceInspector(for: thread) else { return }
        var entry = ClosedViewEntry(threadID: thread.id, workspacePath: thread.workspacePath, tab: inspectorTab)
        if inspectorTab == .files, store.canAccessWorkspaceFiles(thread.workspacePath),
           let document = (try? store.fileBrowser(path: thread.workspacePath))?.document {
            entry.filePath = document.relativePath
        }
        closedViews.record(entry)
    }

    @discardableResult func reopenClosedView() -> Bool {
        let restore = closedViews.takeNext { entry in
            guard let thread = store.thread(entry.threadID), store.canNavigate(to: entry.threadID),
                  thread.workspacePath == entry.workspacePath else { return .missing }
            guard store.canPresentWorkspaceInspector(for: thread),
                  entry.filePath == nil || store.canAccessWorkspaceFiles(entry.workspacePath) else { return .notReady }
            return .ready(alreadyOpen: store.inspectorVisible && store.selectedThreadID == entry.threadID && inspectorTab == entry.tab && entry.filePath == nil)
        }
        guard let restore else {
            showNotice(String(localized: "Nothing to reopen")); return false
        }
        if store.selectedThreadID != restore.threadID { store.selectThread(restore.threadID) }
        store.inspectorVisible = true
        inspectorRequest = .init(tab: restore.tab)
        if let path = restore.filePath {
            store.openFile(URL(fileURLWithPath: restore.workspacePath).appendingPathComponent(path), line: restore.line, workspacePath: restore.workspacePath)
        }
        return true
    }

    func consumeInspectorRequest(_ id: UUID) { if inspectorRequest?.id == id { inspectorRequest = nil } }

    // MARK: Palette, find and focus

    func openPalette() {
        guard palette == nil else { palette?.reset(); return }
        palette = CommandPaletteModel(source: { [weak self] query in
            guard let self else { return .init() }
            return CommandPaletteItems.sources(for: self, query: query)
        }, dismiss: { [weak self] returnFocus in self?.closePalette(returnFocus: returnFocus) })
    }
    /// Closing returns focus to the composer, as in T3.
    func closePalette(returnFocus: Bool = true) {
        guard palette != nil else { return }
        palette = nil
        if returnFocus { focusComposerSoon() }
    }

    func openFind() {
        guard let thread = store.selectedThread else { return }
        if let find, find.threadID == thread.id { find.focus(); return }
        find = ThreadFindModel(threadID: thread.id, messages: thread.visibleMessages)
    }
    func closeFind() {
        guard find != nil else { return }
        find = nil; focusComposerSoon()
    }

    /// Runs after the closing overlay leaves the view tree. An action that focused
    /// another field meanwhile (thread find, file search) keeps its focus.
    func focusComposerSoon() {
        Task { @MainActor [weak self] in
            try? await Task.sleep(for: .milliseconds(60))
            guard let self, self.palette == nil, let window = self.window,
                  KeyboardFocusKind.classify(window.firstResponder, composer: ComposerEditorRegistry.editor(in: window)) == .passive else { return }
            self.focusComposer()
        }
    }

    /// NavigationSplitView is backed by an NSSplitViewController whose sidebar item
    /// toggles natively; the responder chain alone misses it when nothing has focus.
    private func toggleSidebar() -> Bool {
        if let content = window?.contentView, let split = Self.sidebarSplitController(in: content) { split.toggleSidebar(nil); return true }
        return NSApp.sendAction(#selector(NSSplitViewController.toggleSidebar(_:)), to: nil, from: window)
    }
    private static func sidebarSplitController(in view: NSView) -> NSSplitViewController? {
        if let split = view as? NSSplitView, let controller = split.delegate as? NSSplitViewController,
           controller.splitViewItems.contains(where: { $0.behavior == .sidebar }) { return controller }
        for subview in view.subviews { if let found = sidebarSplitController(in: subview) { return found } }
        return nil
    }
    @discardableResult func focusComposer() -> Bool {
        if let focusComposerAction { focusComposerAction(); return true }
        guard let window, let editor = ComposerEditorRegistry.editor(in: window) else { return false }
        return window.makeFirstResponder(editor)
    }

    // MARK: Thread reference and notices

    /// T3 copies a PR link when the thread has one; Coincide threads copy their stable ID.
    @discardableResult func copyThreadReference() -> Bool {
        guard let thread = store.selectedThread else { return false }
        pasteboard.clearContents()
        guard pasteboard.setString(thread.id.uuidString.lowercased(), forType: .string) else { return false }
        showNotice(String(localized: "Copied thread ID"))
        return true
    }

    func showNotice(_ text: String) {
        notice = text
        noticeTask?.cancel()
        noticeTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(1.6))
            guard !Task.isCancelled else { return }
            self?.notice = nil
        }
    }

    /// T3 shows jump hints after the modifiers are held for 200 ms and hides them at once.
    func syncJumpHints(_ show: Bool) {
        guard show else { hintTask?.cancel(); hintTask = nil; if jumpHintsVisible { jumpHintsVisible = false }; return }
        guard !jumpHintsVisible, hintTask == nil else { return }
        hintTask = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(200))
            guard !Task.isCancelled, let self else { return }
            self.hintTask = nil; self.jumpHintsVisible = true
        }
    }
    /// The one-based jump slot shown next to a sidebar row while hints are visible.
    func jumpHint(for threadID: UUID) -> String? {
        guard jumpHintsVisible, let index = store.visibleThreadOrder.prefix(9).firstIndex(of: threadID) else { return nil }
        return keybindings?.label(for: KeybindingCommand.threadJumps[index]) ?? "⌘\(index + 1)"
    }

    func label(for command: KeybindingCommand) -> String? { keybindings?.label(for: command) ?? KeybindingResolver.shortcut(for: command, in: KeybindingDefaults.resolved)?.label }
}

private struct MainWindowControllerKey: FocusedValueKey { typealias Value = MainWindowController }
extension FocusedValues {
    var mainWindowController: MainWindowController? {
        get { self[MainWindowControllerKey.self] }
        set { self[MainWindowControllerKey.self] = newValue }
    }
}
