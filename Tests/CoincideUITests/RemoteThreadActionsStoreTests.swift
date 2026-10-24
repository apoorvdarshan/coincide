import AppKit
import Darwin
import Foundation
import Testing
@testable import Coincide
@testable import CoincideCore

@MainActor private final class RemoteUndoPolicyWindow: NSWindow {
    private static weak var keyOwner: RemoteUndoPolicyWindow?
    override var isKeyWindow: Bool { Self.keyOwner === self }
    override func makeKey() { Self.keyOwner = self }
    override func resignKey() { if Self.keyOwner === self { Self.keyOwner = nil } }
    override func close() { resignKey(); super.close() }
}
private actor RemoteUndoUIPeer {
    let binding: RemoteThreadActionBinding
    let target: RemoteWorkspaceTarget
    let birth: Date, projectBirth: Date?
    var group: RemoteThreadUndoGroup?
    private(set) var releases = 0
    init() {
        let project = WorkspaceProject(path: "/private/REMOTE-ONLY-undo-ui"), thread = CodingThread(project: project)
        let environment = UUID()
        binding = .init(environmentID: environment, hostID: UUID(), leaseID: UUID(), digest: String(repeating: "a", count: 64))
        target = .init(environmentID: environment, projectID: project.id, threadID: thread.id, configuration: .init(thread: thread))
        birth = thread.createdAt; projectBirth = project.createdAt
    }
    func read(_ request: RemoteThreadActionsReadRequest) -> RemoteThreadActionsReadResult {
        let capture = RemoteThreadActionCapture(id: UUID(), binding: binding, target: target, threadCreatedAt: birth, projectCreatedAt: projectBirth,
            runID: nil, runtimeID: nil, expectedPinned: true, expectedArchived: false, digest: String(repeating: "b", count: 64))
        return .init(binding: binding, sequence: 10, capture: capture, undo: group)
    }
    func publish(_ forwardID: UUID) -> RemoteThreadUndoGroup {
        let value = RemoteThreadUndoGroup(id: UUID(), digest: String(repeating: "c", count: 64), kind: .unpin, claimIDs: [UUID()], threadIDs: [target.threadID],
            forwardCommandIDs: [forwardID], expiresAt: Date().addingTimeInterval(5), remainingMilliseconds: 5_000)
        group = value; return value
    }
    func clear() { group = nil }
    func release(_ request: RemoteThreadActionsReleaseRequest) -> RemoteThreadActionsReleaseResult { releases += 1; return .init(binding: request.binding, released: true) }
}
@MainActor private final class RemoteUndoUIFixture {
    let root: URL
    let store = RemoteThreadActionsStore(), peer = RemoteUndoUIPeer()
    let keys: KeybindingsStore
    let window = RemoteUndoPolicyWindow(contentRect: .init(x: 0, y: 0, width: 600, height: 400), styleMask: [.titled], backing: .buffered, defer: false)
    var commands: [RemoteEnvironmentCommand] = []
    var current = true
    init() throws {
        let candidate = FileManager.default.temporaryDirectory.appendingPathComponent("coincide-remote-undo-ui-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: candidate, withIntermediateDirectories: true)
        guard let path = realpath(candidate.path, nil) else { throw CancellationError() }; defer { free(path) }
        root = URL(fileURLWithPath: String(cString: path))
        keys = .init(fileURL: root.appendingPathComponent("keybindings.json"), watch: false)
        window.isReleasedWhenClosed = false
    }
    func start() async {
        await keys.start(); window.makeKey(); keys.dispatcher.registerRemoteUndo(store, window: window)
        let binding = peer.binding, target = peer.target
        await store.update(environmentID: binding.environmentID, connectionKey: Data([1]), target: target,
            transport: .init(read: { [peer] in await peer.read($0) }, release: { [peer] in await peer.release($0) }), supported: true,
            current: { [weak self] in self?.current == true }, perform: { [weak self, peer] command in
                guard let self else { return false }
                #expect(self.store.commandStillAllowed(command)); self.commands.append(command); await peer.clear(); return true
            })
    }
    func publish() async throws -> RemoteThreadUndoGroup {
        let capture = try #require(store.capture), forward = UUID()
        let command = RemoteEnvironmentCommand.threadAction(.setPinned(capture: capture, value: false))
        let owner = try #require(store.forwardOwner(for: command)); store.track(forward, owner: owner)
        let group = await peer.publish(forward)
        let pending = RemoteEnvironmentPendingCommand(connectionID: UUID(), environmentID: owner.binding.environmentID, id: forward, command: command, undoOwner: owner.binding)
        await store.recovered(pending, receipt: .init(commandID: forward, sequence: 10, eventCount: 1, acceptedAt: .now, rejection: nil))
        return group
    }
    func event(in window: NSWindow? = nil) throws -> NSEvent {
        try #require(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [.command], timestamp: ProcessInfo.processInfo.systemUptime,
            windowNumber: (window ?? self.window).windowNumber, context: nil, characters: "z", charactersIgnoringModifiers: "z", isARepeat: false, keyCode: 6))
    }
    func close() async { current = false; await store.shutdown(); await keys.shutdown(); window.close(); try? FileManager.default.removeItem(at: root) }
}

@Test @MainActor func remoteThreadUndoUsesTheOriginalWindowAndSharedEventMemoExactlyOnce() async throws {
    let f = try RemoteUndoUIFixture(); await f.start()
    do {
        _ = try await f.publish()
        let foreign = RemoteUndoPolicyWindow(contentRect: .zero, styleMask: [.titled], backing: .buffered, defer: false)
        foreign.isReleasedWhenClosed = false
        foreign.makeKey()
        let wrong = try f.event(in: foreign)
        #expect(f.keys.dispatcher.handle(wrong) === wrong)
        #expect(f.commands.isEmpty)
        foreign.close(); f.window.makeKey()
        let event = try f.event()
        #expect(f.keys.dispatcher.handle(event) == nil)
        #expect(f.keys.dispatcher.handle(event) == nil)
        try await remoteUndoUIWait { f.commands.count == 1 }
        await f.store.shutdown()
        #expect(f.commands.count == 1)
        #expect(await f.peer.releases == 1)
        guard case .threadAction(.undo(_, _, _, let ids)) = f.commands[0] else { throw CancellationError() }
        #expect(ids.count == 1)
    } catch { await f.close(); throw error }
    await f.close()
}

@Test @MainActor func remoteUndoStaleGroupButtonsKeepTheNewGroupAndInterveningTextEditsKeepNativeUndoPriority() async throws {
    let f = try RemoteUndoUIFixture(); await f.start()
    do {
        let old = try await f.publish(), latest = try await f.publish()
        #expect(!f.store.undo(old) && f.store.group?.id == latest.id && f.commands.isEmpty)
        let text = NSTextView(frame: .init(x: 0, y: 0, width: 400, height: 100))
        f.window.contentView?.addSubview(text); _ = f.window.makeFirstResponder(text)
        NotificationCenter.default.post(name: NSText.didChangeNotification, object: text)
        let event = try f.event()
        #expect(f.keys.dispatcher.handle(event) === event)
        #expect(f.commands.isEmpty && f.store.group?.id == latest.id)
        #expect(f.store.undo(latest)) // Explicit notice remains available.
        try await remoteUndoUIWait { f.commands.count == 1 }
        await f.store.shutdown(); #expect(f.commands.count == 1)
    } catch { await f.close(); throw error }
    await f.close()
}

@MainActor private func remoteUndoUIWait(_ condition: () -> Bool) async throws {
    let until = ContinuousClock.now + .seconds(5)
    while !condition() { guard ContinuousClock.now < until else { throw CancellationError() }; try await Task.sleep(for: .milliseconds(5)) }
}

@Test(arguments: ["sheet", "ime", "lease"]) @MainActor
func remoteThreadUndoNeverCrossesASheetMarkedTextOrReleasedHostLease(scope: String) async throws {
    let f = try RemoteUndoUIFixture(); await f.start()
    let sheet = NSWindow(contentRect: .zero, styleMask: [.titled], backing: .buffered, defer: false)
    sheet.isReleasedWhenClosed = false
    do {
        let group = try await f.publish()
        switch scope {
        case "sheet":
            f.window.beginSheet(sheet, completionHandler: { _ in })
            #expect(f.window.attachedSheet === sheet)
        case "ime":
            let text = NSTextView(frame: .init(x: 0, y: 0, width: 400, height: 100))
            f.window.contentView?.addSubview(text); _ = f.window.makeFirstResponder(text)
            text.setMarkedText("composing", selectedRange: .init(location: 0, length: 0), replacementRange: .init(location: NSNotFound, length: 0))
            #expect(text.hasMarkedText())
        default: f.current = false; f.store.disconnect(); await f.store.drainReads(); #expect(!f.store.undo(group))
        }
        let event = try f.event()
        #expect(f.keys.dispatcher.handle(event) === event)
        #expect(f.commands.isEmpty)
        if f.window.attachedSheet === sheet { f.window.endSheet(sheet) }
    } catch { if f.window.attachedSheet === sheet { f.window.endSheet(sheet) }; sheet.close(); await f.close(); throw error }
    sheet.close(); await f.close()
}
