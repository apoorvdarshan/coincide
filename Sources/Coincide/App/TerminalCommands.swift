import CoincideCore
import CoincideTerminal
import SwiftUI

/// The focused main window's terminals and selected conversation.
struct TerminalCommandTarget {
    let terminals: TerminalWorkspaceStore
    let thread: CodingThread?
    let workspaceReady: Bool
    let canOpen: Bool
    let toggle: () -> Void
    let report: (String) -> Void

    @MainActor var selected: LocalTerminalSession? { thread.flatMap { terminals.selected(in: $0.id) } }
    @MainActor var isVisible: Bool { thread.map { terminals.isVisible($0.id) } ?? false }
    func perform(_ action: (CodingThread) throws -> Void) {
        guard let thread else { return }
        do { try action(thread) } catch { report(error.localizedDescription) }
    }
}

private struct TerminalCommandTargetKey: FocusedValueKey {
    typealias Value = TerminalCommandTarget
}

extension FocusedValues {
    var terminalCommands: TerminalCommandTarget? {
        get { self[TerminalCommandTargetKey.self] }
        set { self[TerminalCommandTargetKey.self] = newValue }
    }
}

/// The Terminal menu. ⌘J toggles the drawer (T3 `terminal.toggle`). The
/// other T3 terminal shortcuts (⌘D, ⇧⌘D, ⌘N, ⌘W, ⌘K) apply only while a
/// terminal has keyboard focus, so they are handled by the terminal itself and
/// shown in its context menu rather than claimed here for the whole window.
struct TerminalCommands: Commands {
    var keybindings: KeybindingsStore? = nil
    @FocusedValue(\.terminalCommands) private var target: TerminalCommandTarget?

    var body: some Commands {
        CommandMenu("Terminal") {
            Button("Toggle Terminal") {
                guard keybindings?.dispatcher.declinedCurrentEvent() != true else { return }
                target?.toggle()
            }
                .keyboardShortcut(keybindings == nil ? KeyboardShortcut("j") : keybindings?.menuShortcut(.terminalToggle))
                .disabled(target?.thread == nil || target?.workspaceReady != true)
            Divider()
            Button("New Terminal") { target?.perform { try target?.terminals.add(for: $0) } }
                .disabled(target?.canOpen != true || target?.terminals.isRestoring == true)
            Button("Split Right") { target?.perform { try target?.terminals.split(for: $0, axis: .horizontal) } }
                .disabled(!canSplit)
            Button("Split Down") { target?.perform { try target?.terminals.split(for: $0, axis: .vertical) } }
                .disabled(!canSplit)
            Divider()
            Button("Clear Terminal") { target?.selected?.clear() }
                .disabled(target?.isVisible != true || target?.selected?.lifecycle != .running)
            Button("Jump to Latest Output") { target?.selected?.jumpToLatest() }
                .disabled(target?.isVisible != true || target?.selected == nil)
            Button("Find in Terminal…") { target?.selected?.showFind() }
                .disabled(target?.isVisible != true || target?.selected == nil)
            Divider()
            Button("Close Terminal") {
                if let target, let thread = target.thread, let selected = target.selected {
                    target.terminals.requestClose(selected, threadID: thread.id)
                }
            }.disabled(target?.isVisible != true || target?.selected == nil)
        }
    }

    private var canSplit: Bool {
        guard let target, let thread = target.thread, target.canOpen, target.isVisible, !target.terminals.isRestoring else { return false }
        return target.terminals.canSplit(in: thread.id)
    }
}
