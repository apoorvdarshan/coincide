import AppKit
import CoincideCore
import Observation
import SwiftUI

/// T3 `KeybindingsUpdateToast.logic`: an issue reports its message; a clean reload
/// reports success at most once every two seconds.
struct KeybindingsNoticeController {
    static let successCooldown: TimeInterval = 2
    enum Decision: Equatable { case success, invalid(String) }
    private var lastSuccess: Date?
    mutating func handle(_ state: KeybindingsConfigState, now: Date) -> Decision? {
        if let issue = state.issues.first(where: { $0.kind.rawValue.hasPrefix("keybindings.") }) { return .invalid(issue.summary) }
        if let lastSuccess, now.timeIntervalSince(lastSuccess) < Self.successCooldown { return nil }
        lastSuccess = now
        return .success
    }
}

/// App-wide keybindings: the live configuration, menu shortcuts and the key dispatcher.
@MainActor @Observable
final class KeybindingsStore {
    nonisolated let fileURL: URL
    private(set) var keybindings: [ResolvedKeybinding] = KeybindingDefaults.resolved
    private(set) var issues: [KeybindingsConfigIssue] = []
    private(set) var fileRules: [KeybindingRule] = []
    private(set) var isLoaded = false
    /// The non-blocking configuration warning. Dismissing it hides it until the next change.
    var warning: String?
    /// A transient "Keybindings updated" confirmation after a reload from disk.
    private(set) var reloadNotice: String?
    @ObservationIgnored let dispatcher: KeyboardCommandDispatcher
    @ObservationIgnored private let config: KeybindingsConfigStore
    @ObservationIgnored private let watches: Bool
    @ObservationIgnored private let now: () -> Date
    @ObservationIgnored private var watcher: KeybindingsFileWatcher?
    @ObservationIgnored private var watchTask: Task<Void, Never>?
    @ObservationIgnored private var starting: Task<Void, Never>?
    @ObservationIgnored private var notices = KeybindingsNoticeController()
    @ObservationIgnored private var noticeDismissal: Task<Void, Never>?

    init(fileURL: URL, defaults: [KeybindingRule] = KeybindingDefaults.rules, watch: Bool = true, now: @escaping () -> Date = Date.init) {
        self.fileURL = fileURL; self.watches = watch; self.now = now
        config = KeybindingsConfigStore(fileURL: fileURL, defaults: defaults)
        dispatcher = KeyboardCommandDispatcher()
        dispatcher.keybindings = self
    }

    /// Writes or backfills defaults, loads the file and starts watching it. Idempotent.
    func start() async {
        if let starting { await starting.value; return }
        let task = Task { [weak self, config] in
            let state = await config.start()
            guard let self else { return }
            apply(state, announce: false)
            isLoaded = true
            if let issue = state.issues.first { warning = issue.summary }
            guard watches else { return }
            let watcher = KeybindingsFileWatcher(fileURL: fileURL)
            self.watcher = watcher
            watchTask = Task { [weak self] in
                for await _ in watcher.events {
                    guard let self else { return }
                    await self.reload()
                }
            }
        }
        starting = task
        await task.value
    }

    func stop() { watchTask?.cancel(); watchTask = nil; watcher?.stop(); watcher = nil; noticeDismissal?.cancel() }

    /// Re-reads the file after an external edit and reports the result like T3's toast.
    func reload() async {
        apply(await config.load(), announce: true)
    }

    func save(_ rule: KeybindingRule, replacing: KeybindingRule? = nil) async throws {
        apply(try await config.upsert(rule, replacing: replacing), announce: false)
    }
    func remove(_ rule: KeybindingRule) async throws {
        apply(try await config.remove(rule), announce: false)
    }

    private func apply(_ state: KeybindingsConfigState, announce: Bool) {
        if keybindings != state.keybindings { keybindings = state.keybindings }
        if issues != state.issues { issues = state.issues }
        if fileRules != state.fileRules { fileRules = state.fileRules }
        if state.issues.isEmpty { warning = nil }
        guard announce, let decision = notices.handle(state, now: now()) else { return }
        switch decision {
        case .invalid(let message): warning = message
        case .success:
            reloadNotice = String(localized: "Keybindings updated")
            noticeDismissal?.cancel()
            noticeDismissal = Task { [weak self] in
                try? await Task.sleep(for: .seconds(2.5))
                guard !Task.isCancelled else { return }
                self?.reloadNotice = nil
            }
        }
    }

    func resolve(_ stroke: KeyStroke, context: KeybindingContext) -> KeybindingCommand? {
        KeybindingResolver.resolve(stroke, in: keybindings, context: context)
    }
    func isBound(_ stroke: KeyStroke) -> Bool { KeybindingResolver.isBound(stroke, in: keybindings) }
    func shortcut(for command: KeybindingCommand, context: KeybindingContext = .menu) -> KeybindingShortcut? {
        KeybindingResolver.shortcut(for: command, in: keybindings, context: context)
    }
    /// The native menu equivalent, from the newest rule that applies in the menu context.
    func menuShortcut(_ command: KeybindingCommand) -> KeyboardShortcut? {
        shortcut(for: command).flatMap(Self.keyboardShortcut)
    }
    func label(for command: KeybindingCommand) -> String? { shortcut(for: command)?.label }

    func openFile() {
        NSWorkspace.shared.open(fileURL)
    }
    func revealFile() { NSWorkspace.shared.activateFileViewerSelecting([fileURL]) }

    static func keyboardShortcut(_ shortcut: KeybindingShortcut) -> KeyboardShortcut? {
        var modifiers: EventModifiers = []
        if shortcut.usesCommand { modifiers.insert(.command) }
        if shortcut.control { modifiers.insert(.control) }
        if shortcut.option { modifiers.insert(.option) }
        if shortcut.shift { modifiers.insert(.shift) }
        guard let key = keyEquivalent(shortcut.key) else { return nil }
        return KeyboardShortcut(key, modifiers: modifiers)
    }
    static func keyEquivalent(_ key: String) -> KeyEquivalent? {
        switch key {
        case "enter": return .return
        case "tab": return .tab
        case " ": return .space
        case "backspace": return .delete
        case "delete": return .deleteForward
        case "escape": return .escape
        case "arrowup": return .upArrow
        case "arrowdown": return .downArrow
        case "arrowleft": return .leftArrow
        case "arrowright": return .rightArrow
        case "home": return .home
        case "end": return .end
        case "pageup": return .pageUp
        case "pagedown": return .pageDown
        default:
            if key.count == 1, let character = key.first { return KeyEquivalent(character) }
            if key.hasPrefix("f"), let number = Int(key.dropFirst()), (1...20).contains(number),
               let scalar = Unicode.Scalar(NSF1FunctionKey + number - 1) { return KeyEquivalent(Character(scalar)) }
            return nil
        }
    }
}
