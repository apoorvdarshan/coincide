import AppKit
import CoincideCore
import Observation
import SwiftUI

/// Presentations that stay owned by ContentView's state.
struct MainWindowPresentations {
    var newProject: @MainActor () -> Void = {}
    var importAgentProjects: @MainActor () -> Void = {}
    var newWindow: @MainActor () -> Void = {}
    var openSettings: @MainActor () -> Void = {}
    var canInteract: @MainActor () -> Bool = { true }
}

/// Captured when a palette row is built; provider telemetry and transcript
/// deltas do not change this ownership, but selecting or rebinding does.
struct MainWindowActionCapture: Equatable {
    let projectID: UUID?
    let projectCreatedAt: Date?
    let projectPath: Data?
    let threadID: UUID?
    let threadCreatedAt: Date?
    let configuration: Data?
    let preparationID: UUID?
    let runID: UUID?
    let runtimeID: UUID?
    let settlementID: UUID?
}
struct MainWindowProjectCapture: Equatable {
    let id: UUID
    let createdAt: Date?
    let path: Data
}
struct MainWindowThreadCapture: Equatable {
    let id: UUID
    let createdAt: Date
    let project: MainWindowProjectCapture
    let configuration: Data
    let preparationID: UUID?
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
/// keyboard dispatcher can do in one chat window.
@MainActor @Observable
final class MainWindowController {
    let store: WorkspaceStore
    @ObservationIgnored weak var keybindings: KeybindingsStore?
    @ObservationIgnored var presentations = MainWindowPresentations()
    let undoOwnerID = UUID()
    @ObservationIgnored weak var window: NSWindow? {
        didSet {
            if oldValue !== window { store.threadActionUndo.unregister(undoOwnerID) }
            if let window { store.threadActionUndo.register(window, ownerID: undoOwnerID) }
        }
    }
    @ObservationIgnored var pasteboard: NSPasteboard = .general
    @ObservationIgnored var defaults: UserDefaults = .standard
    @ObservationIgnored var focusComposerAction: (@MainActor () -> Void)?
    private(set) var palette: CommandPaletteModel?
    private(set) var find: ThreadFindModel?
    private(set) var jumpHintsVisible = false
    private(set) var notice: String?
    private(set) var history = ThreadNavigationHistory()
    @ObservationIgnored private var noticeTask: Task<Void, Never>?
    @ObservationIgnored private var hintTask: Task<Void, Never>?
    @ObservationIgnored private var focusTask: Task<Void, Never>?
    @ObservationIgnored private var controls: [UUID: Task<Void, Never>] = [:]
    private(set) var isActive = true
    @ObservationIgnored private var lifetime = UUID()

    init(store: WorkspaceStore, keybindings: KeybindingsStore? = nil) {
        self.store = store; self.keybindings = keybindings
        history.visit(store.selectedThreadID)
    }

    func undoLatestThreadAction(expectedIDs: [UUID]? = nil) {
        guard canHandleInteraction else { return }
        store.undoLatestThreadAction(ownerID: undoOwnerID, expectedIDs: expectedIDs)
    }
    var selectedThread: CodingThread? { store.selectedThread }
    var canHandleInteraction: Bool {
        isActive && !store.isLoading && (window == nil || window?.isKeyWindow == true) &&
            window?.attachedSheet == nil && presentations.canInteract()
    }

    func activate() { isActive = true }
    func deactivate() {
        isActive = false; lifetime = UUID(); palette = nil; find = nil
        focusTask?.cancel(); focusTask = nil; noticeTask?.cancel(); hintTask?.cancel(); hintTask = nil
        jumpHintsVisible = false; window = nil
    }
    func drain() async {
        while !controls.isEmpty { for task in Array(controls.values) { await task.value }; await Task.yield() }
    }
    func captureAction() -> MainWindowActionCapture {
        let thread = store.selectedThread
        let project = (store.selectedProjectID ?? thread?.projectID).flatMap { id in store.snapshot.projects.first { $0.id == id } }
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
        return .init(projectID: project?.id, projectCreatedAt: project?.createdAt, projectPath: project.map { Data($0.path.utf8) },
            threadID: thread?.id, threadCreatedAt: thread?.createdAt,
            configuration: thread.flatMap { try? encoder.encode(ProviderConfiguration(thread: $0)) }, preparationID: thread?.workspacePreparation?.id,
            runID: thread?.activeRun?.id, runtimeID: thread?.runtimeID, settlementID: thread?.settlement?.id)
    }
    func actionStillCurrent(_ captured: MainWindowActionCapture) -> Bool { canHandleInteraction && captured == captureAction() }
    func captureProject(_ project: WorkspaceProject) -> MainWindowProjectCapture {
        .init(id: project.id, createdAt: project.createdAt, path: Data(project.path.utf8))
    }
    func projectStillCurrent(_ captured: MainWindowProjectCapture) -> Bool {
        guard canHandleInteraction, let current = store.snapshot.projects.first(where: { $0.id == captured.id }),
              current.clone?.isReady ?? true else { return false }
        return captured == captureProject(current)
    }
    func captureThread(_ thread: CodingThread) -> MainWindowThreadCapture? {
        guard let project = store.snapshot.projects.first(where: { $0.id == thread.projectID }) else { return nil }
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
        guard let data = try? encoder.encode(ProviderConfiguration(thread: thread)) else { return nil }
        return .init(id: thread.id, createdAt: thread.createdAt, project: captureProject(project), configuration: data,
            preparationID: thread.workspacePreparation?.id)
    }
    func threadStillCurrent(_ captured: MainWindowThreadCapture) -> Bool {
        guard canHandleInteraction, projectStillCurrent(captured.project), let current = store.thread(captured.id) else { return false }
        return captureThread(current) == captured
    }

    // MARK: Availability

    /// Legacy shortcut IDs remain readable in saved configuration, but only
    /// these chat commands have an executable route in the current app.
    nonisolated static func supports(_ command: KeybindingCommand) -> Bool {
        switch command {
        case .sidebarToggle, .commandPaletteToggle, .themeSelect, .appearanceCycle, .windowNew,
             .projectNew, .projectAdd, .projectImport, .chatNew, .chatNewLocal, .navigationBack,
             .navigationForward, .chatFind, .threadCopyReference, .threadPin, .threadStop,
             .threadUndo, .threadPrevious, .threadNext: return true
        default: return command.threadJumpNumber != nil
        }
    }

    func canPerform(_ command: KeybindingCommand) -> Bool {
        guard Self.supports(command), canHandleInteraction else { return false }
        let thread = store.selectedThread
        switch command {
        case .sidebarToggle, .commandPaletteToggle, .themeSelect, .appearanceCycle, .windowNew,
             .projectNew, .projectAdd, .projectImport: return !store.isLoading
        case .chatNew, .chatNewLocal: return !store.isLoading
        case .navigationBack: return history.canGoBack(isValid: store.canNavigate(to:))
        case .navigationForward: return history.canGoForward(isValid: store.canNavigate(to:))
        case .chatFind, .threadCopyReference, .threadPin: return thread != nil
        case .threadStop: return thread.map { store.isBusy($0.id) } ?? false
        case .threadUndo: return !store.threadActionUndo.group(ownerID: undoOwnerID).isEmpty
        case .threadPrevious: return store.adjacentThread(.previous) != nil
        case .threadNext: return store.adjacentThread(.next) != nil
        default:
            if let number = command.threadJumpNumber { return store.threadForJump(number) != nil }
            return false
        }
    }

    /// Runs a command; false when it does not apply in this window right now.
    @discardableResult func perform(_ command: KeybindingCommand, expected: MainWindowActionCapture? = nil) -> Bool {
        guard canPerform(command), expected.map(actionStillCurrent) ?? true else { return false }
        let captured = expected ?? captureAction()
        let thread = store.selectedThread
        switch command {
        case .sidebarToggle: return toggleSidebar()
        case .commandPaletteToggle: palette == nil ? openPalette() : closePalette()
        case .themeSelect: openPalette(); palette?.open(view: CommandPaletteItems.appearanceView(self))
        case .appearanceCycle:
            let mode = AppearanceMode.cycle(defaults)
            showNotice(String(localized: "Appearance: \(mode.title)"))
        case .navigationBack:
            guard let id = history.goBack(isValid: store.canNavigate(to:)) else { return false }
            store.selectThread(id)
        case .navigationForward:
            guard let id = history.goForward(isValid: store.canNavigate(to:)) else { return false }
            store.selectThread(id)
        case .chatNew: store.newThread()
        case .chatNewLocal: store.newThread()
        case .chatFind: openFind()
        case .threadStop:
            guard let id = thread?.id else { return false }
            ownedControl { [store] in
                await store.interrupt(id, expectedRunID: captured.runID, expectedRuntimeID: captured.runtimeID)
            }
        case .threadPin:
            guard let thread else { return false }
            store.togglePin(thread.id)
            showNotice(thread.isPinned ? String(localized: "Unpinned “\(thread.title)”") : String(localized: "Pinned “\(thread.title)”"))
        case .threadUndo: undoLatestThreadAction()
        case .threadCopyReference: return copyThreadReference()
        case .threadPrevious, .threadNext:
            guard let id = store.adjacentThread(command == .threadPrevious ? .previous : .next) else { return false }
            store.selectThread(id)
        case .projectNew: presentations.newProject()
        case .projectAdd: store.addProject()
        case .projectImport: presentations.importAgentProjects()
        case .windowNew: presentations.newWindow()
        default:
            guard let number = command.threadJumpNumber, let id = store.threadForJump(number) else { return false }
            store.selectThread(id)
        }
        return true
    }

    // MARK: Conversation history

    /// Records a selection change for back/forward; history-driven selections are already current.
    func selectionChanged(to id: UUID?) {
        history.visit(id)
        if let find, find.threadID != id { self.find = nil }
    }

    // MARK: Palette, find and focus

    func openPalette() {
        guard canHandleInteraction else { return }
        guard palette == nil else { palette?.reset(); return }
        palette = CommandPaletteModel(source: { [weak self] query in
            guard let self else { return .init() }
            return CommandPaletteItems.sources(for: self, query: query)
        }, dismiss: { [weak self] returnFocus in self?.closePalette(returnFocus: returnFocus) })
    }
    /// Closing returns focus to the composer.
    func closePalette(returnFocus: Bool = true) {
        guard palette != nil else { return }
        palette = nil
        if returnFocus { focusComposerSoon() }
    }

    func openFind() {
        guard canHandleInteraction, let thread = store.selectedThread else { return }
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
        focusTask?.cancel()
        let owner = lifetime
        focusTask = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .milliseconds(60))
            guard !Task.isCancelled, let self, self.lifetime == owner, self.canHandleInteraction,
                  self.palette == nil, let window = self.window, window.isKeyWindow,
                  KeyboardFocusKind.classify(window.firstResponder, composer: ComposerEditorRegistry.editor(in: window)) == .passive else { return }
            self.focusComposer()
        }
    }

    private func toggleSidebar() -> Bool {
        store.sidebarVisible.toggle()
        return true
    }
    @discardableResult func focusComposer() -> Bool {
        guard canHandleInteraction else { return false }
        if let focusComposerAction { focusComposerAction(); return true }
        guard let window, let editor = ComposerEditorRegistry.editor(in: window) else { return false }
        return window.makeFirstResponder(editor)
    }

    // MARK: Thread reference and notices

    /// Coincide conversations expose their stable local ID.
    @discardableResult func copyThreadReference() -> Bool {
        guard canHandleInteraction, let thread = store.selectedThread else { return false }
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

    /// Show jump hints after a short modifier hold, then hide them immediately on release.
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
    private func ownedControl(_ operation: @escaping @MainActor () async -> Void) {
        let id = UUID()
        controls[id] = Task { [weak self] in await operation(); self?.controls.removeValue(forKey: id) }
    }
}

private struct MainWindowControllerKey: FocusedValueKey { typealias Value = MainWindowController }
extension FocusedValues {
    var mainWindowController: MainWindowController? {
        get { self[MainWindowControllerKey.self] }
        set { self[MainWindowControllerKey.self] = newValue }
    }
}
