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
    private(set) var revision = KeybindingsConfigRevision()
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
    @ObservationIgnored private var reads: [UUID: Task<KeybindingsConfigState, Never>] = [:]
    @ObservationIgnored private var writes: [UUID: Task<KeybindingsConfigState, any Error>] = [:]
    @ObservationIgnored private var generation = 0
    @ObservationIgnored private var stopped = false

    init(fileURL: URL, defaults: [KeybindingRule] = KeybindingDefaults.rules, watch: Bool = true, now: @escaping () -> Date = Date.init) {
        self.fileURL = fileURL; self.watches = watch; self.now = now
        config = KeybindingsConfigStore(fileURL: fileURL, defaults: defaults)
        dispatcher = KeyboardCommandDispatcher()
        dispatcher.keybindings = self
    }

    /// Writes or backfills defaults, loads the file and starts watching it. Idempotent.
    func start() async {
        if let starting { await starting.value; return }
        if isLoaded && !stopped { return }
        stopped = false
        let owner = generation
        let task = Task { [weak self, config] in
            let state = await config.start()
            guard !Task.isCancelled, let self, self.generation == owner, !self.stopped else { return }
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
        if generation == owner { starting = nil }
    }

    func stop() {
        stopped = true; generation += 1; starting?.cancel()
        watchTask?.cancel(); watcher?.stop(); watcher = nil; noticeDismissal?.cancel()
        for read in reads.values { read.cancel() }
    }
    func shutdown() async {
        stop()
        await starting?.value; starting = nil
        await watchTask?.value; watchTask = nil
        while !reads.isEmpty || !writes.isEmpty {
            for read in Array(reads.values) { _ = await read.value }
            for write in Array(writes.values) { _ = await write.result }
            await Task.yield()
        }
        await dispatcher.shutdown()
    }

    /// Re-reads the file after an external edit and reports the result like T3's toast.
    func reload() async {
        guard !stopped else { return }
        let id = UUID(), owner = generation, config = config
        let task = Task { await config.load() }; reads[id] = task
        defer { reads.removeValue(forKey: id) }
        let state = await task.value
        guard !Task.isCancelled, generation == owner, !stopped else { return }
        apply(state, announce: true)
    }

    func save(_ rule: KeybindingRule, replacing: KeybindingRule? = nil, expectedRevision: KeybindingsConfigRevision? = nil) async throws {
        let config = config
        try await write { try await config.upsert(rule, replacing: replacing, expectedRevision: expectedRevision) }
    }
    func remove(_ rule: KeybindingRule, expectedRevision: KeybindingsConfigRevision? = nil) async throws {
        let config = config
        try await write { try await config.remove(rule, expectedRevision: expectedRevision) }
    }
    private func write(_ operation: @escaping @Sendable () async throws -> KeybindingsConfigState) async throws {
        guard !stopped else { throw CocoaError(.userCancelled) }
        let owner = generation, id = UUID(), task = Task { try await operation() }; writes[id] = task
        defer { writes.removeValue(forKey: id) }
        let state = try await task.value // Accepted atomic writes finish if their sheet closes.
        guard generation == owner, !stopped else { return }
        apply(state, announce: false)
    }

    private func apply(_ state: KeybindingsConfigState, announce: Bool) {
        revision = state.revision
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
