import AppKit
import CoincideCore
import Foundation
import Testing
@testable import Coincide

@MainActor private final class UndoFixtureWindow: NSWindow {
    private static weak var owner: UndoFixtureWindow?
    override var isKeyWindow: Bool { Self.owner === self }
    override func makeKey() { Self.owner = self }
    override func resignKey() { if Self.owner === self { Self.owner = nil } }
    override func close() { resignKey(); super.close() }
    static func make() -> UndoFixtureWindow {
        let window = UndoFixtureWindow(contentRect: .init(x: -10_000, y: -10_000, width: 400, height: 300), styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false; window.contentView = NSView(frame: .init(x: 0, y: 0, width: 400, height: 300)); window.makeKey(); return window
    }
}
@MainActor private struct UndoUIFixture {
    let root: URL, engine: WorkspaceEngine, store: WorkspaceStore, keys: KeybindingsStore
    let window: UndoFixtureWindow, controller: MainWindowController
    let ids: [UUID]
    static func make() async throws -> Self {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("coincide-undo-ui-" + UUID().uuidString).resolvingSymlinksInPath()
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let project = WorkspaceProject(path: root.path)
        var snapshot = WorkspaceSnapshot(); snapshot.projects = [project]
        for index in 0..<3 {
            var thread = CodingThread(project: project); thread.checkpointPolicy = .disabled
            thread.title = "Conversation \(index)"; thread.draft = "Exact draft \(index) a\u{301}\u{327}"
            snapshot.threads.append(thread)
        }
        let url = root.appendingPathComponent("workspace.sqlite")
        try await WorkspaceDatabase(url: url).save(snapshot, event: "thread.undo.ui.fixture")
        let engine = try WorkspaceEngine(url: url, providerFactory: { _ in throw CoincideError("Undo must not launch a provider") }, identityResolver: { _ in nil })
        let store = WorkspaceStore(engine: engine); await store.load()
        let keys = KeybindingsStore(fileURL: root.appendingPathComponent("keybindings.json"), watch: false); await keys.start()
        let window = UndoFixtureWindow.make(), controller = MainWindowController(store: store, keybindings: keys)
        keys.dispatcher.register(controller, window: window)
        return .init(root: root, engine: engine, store: store, keys: keys, window: window, controller: controller, ids: snapshot.threads.map(\.id))
    }
    func close() async {
        controller.deactivate(); await keys.shutdown(); await store.shutdown(); window.close()
        try? FileManager.default.removeItem(at: root)
    }
}
@MainActor private func waitUndoUI(_ condition: () -> Bool) async throws {
    let deadline = ContinuousClock.now.advanced(by: .seconds(3))
    while !condition() {
        guard ContinuousClock.now < deadline else { throw CoincideError("Expected scoped Undo state") }
        try await Task.sleep(for: .milliseconds(5))
    }
}
@MainActor private func undoKey(_ window: NSWindow, _ code: UInt16 = 6, _ characters: String = "z", flags: NSEvent.ModifierFlags = [.command]) throws -> NSEvent {
    try #require(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: flags, timestamp: ProcessInfo.processInfo.systemUptime,
        windowNumber: window.windowNumber, context: nil, characters: characters, charactersIgnoringModifiers: characters, isARepeat: false, keyCode: code))
}

@Test @MainActor func threadActionUndoGroupsRealArchiveReceiptsConsumesBeforeAwaitAndKeepsOriginalWindow() async throws {
    let f = try await UndoUIFixture.make()
    do {
        f.store.toggleArchive(f.ids[0])
        try await waitUndoUI { f.store.threadActionUndo.group(ownerID: f.controller.undoOwnerID).count == 1 }
        let retainedNotice = f.store.threadActionUndo.group(ownerID: f.controller.undoOwnerID).map(\.id)
        f.store.toggleArchive(f.ids[1])
        try await waitUndoUI { f.store.threadActionUndo.group(ownerID: f.controller.undoOwnerID).count == 2 }
        f.controller.undoLatestThreadAction(expectedIDs: retainedNotice)
        #expect(f.store.threadActionUndo.group(ownerID: f.controller.undoOwnerID).count == 2)
        let group = f.store.threadActionUndo.group(ownerID: f.controller.undoOwnerID)
        #expect(Set(group.map(\.threadID)) == Set(f.ids.prefix(2)))
        let other = UndoFixtureWindow.make(), otherController = MainWindowController(store: f.store, keybindings: f.keys)
        f.keys.dispatcher.register(otherController, window: other)
        #expect(!otherController.canPerform(.threadUndo))
        #expect(!f.controller.perform(.threadUndo)) // the original window is no longer key
        let event = try undoKey(other)
        #expect(f.keys.dispatcher.handle(event) === event)
        f.window.makeKey()
        #expect(f.controller.perform(.threadUndo))
        #expect(f.store.threadActionUndo.group(ownerID: f.controller.undoOwnerID).isEmpty)
        #expect(!f.controller.perform(.threadUndo)) // no second grouped dispatch while admission is pending
        try await waitUndoUI { f.ids.prefix(2).allSatisfy { f.store.thread($0)?.isArchived == false } }
        #expect(f.ids.prefix(2).allSatisfy { f.store.thread($0)?.queuePaused == true && f.store.thread($0)?.activeRun == nil })
        otherController.deactivate(); other.close()
    } catch { await f.close(); throw error }
    await f.close()
}

@Test @MainActor func threadActionUndoShortcutYieldsToNativeTextAfterEditingAndRetainedBannerStillUsesExactClaim() async throws {
    let f = try await UndoUIFixture.make()
    do {
        let text = NSTextView(frame: .zero); text.isEditable = true
        f.window.contentView?.addSubview(text); f.window.makeFirstResponder(text)
        f.store.toggleArchive(f.ids[0])
        try await waitUndoUI { f.store.threadActionUndo.claimsShortcut(ownerID: f.controller.undoOwnerID) }
        #expect(f.keys.dispatcher.context(for: f.controller, focus: .editableText)["threadUndoAvailable"])
        // A mouse/menu text edit also relinquishes the notice's temporary Cmd+Z ownership.
        NotificationCenter.default.post(name: NSText.didChangeNotification, object: text)
        #expect(!f.store.threadActionUndo.claimsShortcut(ownerID: f.controller.undoOwnerID))
        #expect(f.controller.canPerform(.threadUndo)) // the visible explicit button remains available
        let nativeUndo = try undoKey(f.window)
        #expect(f.keys.dispatcher.handle(nativeUndo) === nativeUndo)
        #expect(f.store.thread(f.ids[0])?.isArchived == true)
        f.controller.undoLatestThreadAction()
        try await waitUndoUI { f.store.thread(f.ids[0])?.isArchived == false }
    } catch { await f.close(); throw error }
    await f.close()
}

@Test @MainActor func threadActionUndoLateReceiptCannotReclaimTextUndoOrMoveItsNoticeToAReplacementWindow() async throws {
    let f = try await UndoUIFixture.make()
    do {
        let editor = NSTextView(); editor.isEditable = true
        f.window.contentView?.addSubview(editor); f.window.makeFirstResponder(editor)
        let owner = try #require(f.store.threadActionUndo.actionOwner)
        let receipt = try await f.engine.dispatch(.editThread(f.ids[0], .archived(true)))
        let claim = try #require(await f.engine.takeThreadActionUndo(forwardCommandID: receipt.commandID, ownerID: owner.id))
        try await waitUndoUI { f.store.thread(f.ids[0])?.isArchived == true }
        // The real receipt has committed; its UI notice arrives after a text edit.
        NotificationCenter.default.post(name: NSText.didChangeNotification, object: editor)
        f.store.threadActionUndo.record(claim, owner: owner)
        #expect(f.store.threadActionUndo.group(ownerID: owner.id).map(\.id) == [claim.id])
        #expect(!f.store.threadActionUndo.claimsShortcut(ownerID: owner.id))
        let event = try undoKey(f.window)
        #expect(f.keys.dispatcher.handle(event) === event)
        #expect(f.store.thread(f.ids[0])?.isArchived == true)
        // Reusing a controller ID for another window cannot transfer a late notice.
        f.store.threadActionUndo.unregister(owner.id)
        let replacement = UndoFixtureWindow.make(); defer { replacement.close() }
        f.store.threadActionUndo.register(replacement, ownerID: owner.id)
        f.store.threadActionUndo.record(claim, owner: owner)
        #expect(f.store.threadActionUndo.group(ownerID: owner.id).isEmpty)
    } catch { await f.close(); throw error }
    await f.close()
}

@Test @MainActor func threadActionUndoExplicitDiscardRestoresExactDraftButNeverOverwritesLaterLocalInput() async throws {
    let f = try await UndoUIFixture.make()
    do {
        let original = try #require(f.store.thread(f.ids[0])?.draft)
        let attachmentBytes = Data("Exact private attachment — a\u{301}\u{327}\n".utf8)
        let attachment = try await f.engine.attachments.importData(attachmentBytes, name: "undo-context.txt")
        _ = try await f.engine.dispatch(.addAttachments(threadID: f.ids[0], attachments: [attachment]))
        try await waitUndoUI { f.store.thread(f.ids[0])?.draftAttachments == [attachment] }
        f.store.discardComposerDraft(f.ids[0])
        try await waitUndoUI { f.store.threadActionUndo.group(ownerID: f.controller.undoOwnerID).first?.kind == .discard }
        f.controller.undoLatestThreadAction()
        try await waitUndoUI { f.store.thread(f.ids[0])?.draft.utf8.elementsEqual(original.utf8) == true }
        #expect(f.store.thread(f.ids[0])?.draftAttachments == [attachment])
        #expect(try await f.engine.attachments.data(for: attachment) == attachmentBytes)
        f.store.discardComposerDraft(f.ids[0])
        try await waitUndoUI { f.store.threadActionUndo.group(ownerID: f.controller.undoOwnerID).first?.kind == .discard }
        f.store.setDraft("New local text must survive", id: f.ids[0])
        f.controller.undoLatestThreadAction()
        try await waitUndoUI { f.store.errorMessage != nil }
        #expect(f.store.thread(f.ids[0])?.draft == "New local text must survive")
        #expect(f.store.threadActionUndo.group(ownerID: f.controller.undoOwnerID).isEmpty)
        // Independent claims in one group still run if an earlier draft CAS refuses.
        f.store.errorMessage = nil
        let otherOriginal = try #require(f.store.thread(f.ids[1])?.draft)
        f.store.discardComposerDraft(f.ids[0]); f.store.discardComposerDraft(f.ids[1])
        try await waitUndoUI { f.store.threadActionUndo.group(ownerID: f.controller.undoOwnerID).count == 2 }
        f.store.setDraft("Keep the first conversation's newer text", id: f.ids[0])
        f.controller.undoLatestThreadAction()
        try await waitUndoUI { f.store.thread(f.ids[1])?.draft == otherOriginal }
        #expect(f.store.thread(f.ids[0])?.draft == "Keep the first conversation's newer text")
    } catch { await f.close(); throw error }
    await f.close()
}

@Test @MainActor func threadActionUndoOtherKeyReleasesShortcutAndSheetOrRetiredWindowCannotConsumeIt() async throws {
    let f = try await UndoUIFixture.make()
    do {
        f.store.toggleArchive(f.ids[0]); try await waitUndoUI { f.controller.canPerform(.threadUndo) }
        let typing = try undoKey(f.window, 0, "a", flags: [])
        _ = f.keys.dispatcher.handle(typing)
        #expect(!f.store.threadActionUndo.claimsShortcut(ownerID: f.controller.undoOwnerID))
        let sheet = NSWindow(contentRect: .init(x: 0, y: 0, width: 100, height: 100), styleMask: [.titled], backing: .buffered, defer: false)
        sheet.isReleasedWhenClosed = false
        f.window.beginSheet(sheet, completionHandler: { _ in })
        #expect(!f.controller.perform(.threadUndo))
        f.window.endSheet(sheet); sheet.close()
        f.controller.deactivate()
        #expect(!f.controller.canPerform(.threadUndo))
        #expect(f.store.threadActionUndo.group(ownerID: f.controller.undoOwnerID).isEmpty)
        #expect(f.store.thread(f.ids[0])?.isArchived == true)
    } catch { await f.close(); throw error }
    await f.close()
}
