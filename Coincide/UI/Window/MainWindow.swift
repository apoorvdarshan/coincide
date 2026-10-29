import AppKit

/// The main window. Edit › Undo (⌘Z) and Redo first undo what the focused view edited, as in any window (the composer's
/// text, a comment being written); with nothing there to undo, they undo the last thread deletion, archive, settle or
/// move (`ThreadInbox`) wherever the focus is, so these stay undoable without a button of their own. The thread list
/// routes ⌘Z to the inbox itself (`SidebarOutlineView`).
final class MainWindow: NSWindow {
    /// The inbox whose actions ⌘Z undoes; tests give their own.
    var inbox: () -> ThreadInbox = { .shared }

    /// The focused view's undo stack, unless that is the inbox's.
    private var focusedUndoManager: UndoManager? {
        let manager = (firstResponder ?? self).undoManager
        return manager === inbox().undoManager ? nil : manager
    }

    /// Where Undo goes now: the focused view's stack when it has something to undo, otherwise the inbox's.
    private func undoTarget() -> UndoManager? {
        if let focused = focusedUndoManager, focused.canUndo { return focused }
        return inbox().undoManager.canUndo ? inbox().undoManager : nil
    }

    private func redoTarget() -> UndoManager? {
        if let focused = focusedUndoManager, focused.canRedo { return focused }
        return inbox().undoManager.canRedo ? inbox().undoManager : nil
    }

    @objc func undo(_ sender: Any?) {
        guard let target = undoTarget() else { return NSSound.beep() }
        if target === inbox().undoManager { inbox().undo() } else { target.undo() }
    }

    @objc func redo(_ sender: Any?) {
        guard let target = redoTarget() else { return NSSound.beep() }
        if target === inbox().undoManager { inbox().redo() } else { target.redo() }
    }

    override func validateMenuItem(_ menuItem: NSMenuItem) -> Bool {
        switch menuItem.action {
        case Selector(("undo:"))?:
            let target = undoTarget()
            menuItem.title = (target ?? inbox().undoManager).undoMenuItemTitle
            return target != nil
        case Selector(("redo:"))?:
            let target = redoTarget()
            menuItem.title = (target ?? inbox().undoManager).redoMenuItemTitle
            return target != nil
        default:
            return super.validateMenuItem(menuItem)
        }
    }

    override func validateUserInterfaceItem(_ item: any NSValidatedUserInterfaceItem) -> Bool {
        switch item.action {
        case Selector(("undo:"))?: undoTarget() != nil
        case Selector(("redo:"))?: redoTarget() != nil
        default: super.validateUserInterfaceItem(item)
        }
    }
}
