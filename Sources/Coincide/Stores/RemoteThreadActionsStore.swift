import AppKit
import CoincideCore
import Foundation
import Observation

struct RemoteThreadActionsTransport: Sendable {
    let read: @Sendable (RemoteThreadActionsReadRequest) async throws -> RemoteThreadActionsReadResult
    let release: @Sendable (RemoteThreadActionsReleaseRequest) async throws -> RemoteThreadActionsReleaseResult
    static func live(_ client: RemoteEnvironmentClient) -> Self { .init(read: { try await client.readThreadActions($0) }, release: { try await client.releaseThreadActions($0) }) }
}
private final class RemoteThreadActionTextObservation: @unchecked Sendable {
    let token: any NSObjectProtocol
    init(_ token: any NSObjectProtocol) { self.token = token }
    deinit { NotificationCenter.default.removeObserver(token) }
}
@MainActor @Observable
final class RemoteThreadActionsStore {
    struct ForwardOwner { let binding: RemoteThreadActionBinding; let windowEpoch: UUID, shortcutEpoch: UUID }
    private(set) var binding: RemoteThreadActionBinding?
    private(set) var capture: RemoteThreadActionCapture?
    private(set) var group: RemoteThreadUndoGroup?
    private(set) var isLoading = false
    var errorMessage: String?
    @ObservationIgnored private weak var window: NSWindow?
    @ObservationIgnored private var windowEpoch = UUID()
    @ObservationIgnored private var shortcutEpoch = UUID()
    private var ownsShortcut = false
    private(set) var windowRevision = UUID()
    @ObservationIgnored private var pendingGrant: (ForwardOwner, UUID, Int64)?
    @ObservationIgnored private var observer: RemoteThreadActionTextObservation?
    @ObservationIgnored private var transport: RemoteThreadActionsTransport?
    @ObservationIgnored private var target: RemoteWorkspaceTarget?
    @ObservationIgnored private var environmentID: UUID?
    @ObservationIgnored private var connectionKey: Data?
    @ObservationIgnored private var current: (@MainActor () -> Bool)?
    @ObservationIgnored private var perform: (@MainActor (RemoteEnvironmentCommand) async -> Bool)?
    @ObservationIgnored private var read: Task<Void, Never>?
    @ObservationIgnored private var expiry: Task<Void, Never>?
    @ObservationIgnored private var drains: [UUID: Task<Void, Never>] = [:]
    @ObservationIgnored private var writes: [UUID: Task<Void, Never>] = [:]
    @ObservationIgnored private var forwardOwners: [UUID: ForwardOwner] = [:]
    @ObservationIgnored private var accepting: [UUID: RemoteThreadAction] = [:]
    @ObservationIgnored private var generation = UUID()
    @ObservationIgnored private var readVersion = UUID()
    @ObservationIgnored private var expiryVersion = UUID()
    @ObservationIgnored private var stopped = false
    func bind(window: NSWindow) {
        guard !stopped, self.window !== window else { return }
        unbind(); self.window = window; windowEpoch = UUID(); shortcutEpoch = UUID(); windowRevision = UUID()
        observer = RemoteThreadActionTextObservation(NotificationCenter.default.addObserver(forName: NSText.didChangeNotification, object: nil, queue: .main) { [weak self] note in
            guard let text = note.object as? NSTextView else { return }
            MainActor.assumeIsolated { if text.window === self?.window { self?.releaseShortcut() } }
        })
    }
    func unbind(window: NSWindow? = nil) {
        if let window, self.window !== window { return }
        observer = nil
        self.window = nil; windowEpoch = UUID(); windowRevision = UUID(); releaseShortcut(); disconnect()
    }
    func releaseShortcut() { ownsShortcut = false; shortcutEpoch = UUID() }
    var canUndo: Bool { group != nil && binding != nil && !stopped && current?() == true }
    func forwardOwner(for command: RemoteEnvironmentCommand) -> ForwardOwner? {
        let ownsAction: Bool
        if case .threadAction(let action) = command { switch action { case .setPinned, .setArchived: ownsAction = true; case .undo: ownsAction = false } }
        else { ownsAction = Self.canCreateUndo(command) }
        guard ownsAction, current?() == true, let binding,
              let window, window.isKeyWindow || window.attachedSheet?.isKeyWindow == true else { return nil }
        return .init(binding: binding, windowEpoch: windowEpoch, shortcutEpoch: shortcutEpoch)
    }
    static func canCreateUndo(_ command: RemoteEnvironmentCommand) -> Bool {
        switch command {
        case .threadAction(.setPinned(_, false)), .threadAction(.setArchived(_, true)): true
        case .lifecycle(_, .snooze), .lifecycle(_, .settleWithoutScript), .lifecycle(_, .settleReviewingScript): true
        default: false
        }
    }
    func track(_ id: UUID, owner: ForwardOwner?) { if let owner { if forwardOwners.count >= 32 { forwardOwners.removeAll() }; forwardOwners[id] = owner } }
    func update(environmentID: UUID?, connectionKey: Data, target: RemoteWorkspaceTarget?, transport: RemoteThreadActionsTransport?, supported: Bool,
                current: @escaping @MainActor () -> Bool, perform: @escaping @MainActor (RemoteEnvironmentCommand) async -> Bool) async {
        guard !stopped else { return }
        self.current = current; self.perform = perform
        guard supported, let environmentID, let transport else { disconnect(); return }
        if self.connectionKey != connectionKey { disconnect(); self.connectionKey = connectionKey }
        self.environmentID = environmentID; self.transport = transport; self.target = target
        await refresh()
    }
    func refresh(after owner: ForwardOwner? = nil, forwardID: UUID? = nil) async {
        guard !stopped, current?() == true, let environmentID, let transport else { return }
        read?.cancel(); let previous = read; let version = UUID(), generation = generation
        readVersion = version; isLoading = true
        let request = RemoteThreadActionsReadRequest(environmentID: environmentID, binding: binding, target: target)
        let started = ContinuousClock.now
        let task = Task { [weak self] in
            await previous?.value
            guard let self else { return }
            defer { if self.readVersion == version { self.isLoading = false } }
            do {
                try Task.checkCancellation()
                let value = try await transport.read(request)
                guard !Task.isCancelled, self.generation == generation, self.readVersion == version, self.current?() == true else {
                    if request.binding == nil { _ = try? await transport.release(.init(binding: value.binding)) }; return
                }
                self.binding = value.binding; self.capture = value.capture; self.group = value.undo; self.errorMessage = nil
                if let grant = self.pendingGrant, value.sequence >= grant.2 {
                    let owner = grant.0
                    if value.undo?.forwardCommandIDs.contains(grant.1) == true, owner.binding == value.binding, owner.windowEpoch == self.windowEpoch, owner.shortcutEpoch == self.shortcutEpoch { self.ownsShortcut = true }
                    self.pendingGrant = nil
                }
                if value.undo == nil { self.ownsShortcut = false }
                self.expiry?.cancel(); self.expiryVersion = UUID(); let expiryVersion = self.expiryVersion
                if let group = value.undo {
                    let elapsed = started.duration(to: .now).components
                    let ms = elapsed.seconds * 1_000 + elapsed.attoseconds / 1_000_000_000_000_000
                    let remaining = max(Int64(0), Int64(group.remainingMilliseconds) - ms)
                    self.expiry = Task { [weak self] in
                        do { try await Task.sleep(for: .milliseconds(remaining)) } catch { return }
                        guard let self, self.generation == generation, self.expiryVersion == expiryVersion else { return }
                        self.group = nil; self.ownsShortcut = false
                    }
                }
            } catch { if !(error is CancellationError), self.generation == generation, self.readVersion == version { self.errorMessage = "The remote conversation actions could not be refreshed." } }
        }
        read = task; await task.value
    }
    func recovered(_ pending: RemoteEnvironmentPendingCommand, receipt: WorkspaceCommandReceipt) async {
        if let owner = forwardOwners.removeValue(forKey: pending.id) { pendingGrant = (owner, pending.id, receipt.sequence) }
        await refresh()
    }
    func commandStillAllowed(_ command: RemoteEnvironmentCommand) -> Bool {
        guard case .threadAction(let action) = command else { return true }
        guard current?() == true, action.binding == binding else { return false }
        switch action {
        case .setPinned(let original, _), .setArchived(let original, _): return capture.map { RemoteLifecycleProtocol.same($0, original) } == true && target.map { RemoteLifecycleProtocol.same($0, original.target) } == true
        case .undo(_, let id, _, _): return accepting[id] == action
        }
    }
    @discardableResult func undo(_ expected: RemoteThreadUndoGroup) -> Bool {
        guard canUndo, let window, window.isKeyWindow, window.attachedSheet == nil, let actual = group, actual.id == expected.id, actual.digest == expected.digest, actual.claimIDs == expected.claimIDs,
              let binding, let perform else { return false }
        let action = RemoteThreadAction.undo(binding: binding, groupID: actual.id, digest: actual.digest, claimIDs: actual.claimIDs)
        group = nil; ownsShortcut = false; expiry?.cancel(); accepting[actual.id] = action
        let id = UUID()
        writes[id] = Task { [weak self] in
            _ = await perform(.threadAction(action))
            self?.accepting.removeValue(forKey: actual.id); self?.writes.removeValue(forKey: id)
            await self?.refresh()
        }
        return true
    }
    func route(_ event: NSEvent, keybindings: KeybindingsStore) -> Bool {
        guard event.type == .keyDown, let window, event.window === window, window.isKeyWindow, window.attachedSheet == nil,
              canUndo, ownsShortcut else { return false }
        if let text = window.firstResponder as? NSTextView, text.hasMarkedText() { releaseShortcut(); return false }
        let focus = KeyboardFocusKind.classify(window.firstResponder, composer: ComposerEditorRegistry.editor(in: window))
        guard focus != .terminal else { return false }
        let flags = event.modifierFlags
        let stroke = KeyStroke(keyCode: event.keyCode, characters: event.charactersIgnoringModifiers, command: flags.contains(.command), control: flags.contains(.control), option: flags.contains(.option), shift: flags.contains(.shift))
        let command = keybindings.resolve(stroke, context: .init(["isDesktop": true, "isWeb": false, "threadUndoAvailable": ownsShortcut, "editableFocus": focus.isEditable,
            "composerFocus": focus == .composer, "fileEditorFocus": focus == .fileEditor, "terminalFocus": false]))
        guard command == .threadUndo, let group else { return false }; return undo(group)
    }
    func disconnect() {
        generation = UUID(); readVersion = UUID(); expiryVersion = UUID(); let task = read, timer = expiry
        read = nil; expiry = nil; task?.cancel(); timer?.cancel()
        let transport = transport, binding = binding
        self.transport = nil; self.binding = nil; pendingGrant = nil; capture = nil; group = nil; connectionKey = nil; ownsShortcut = false; accepting.removeAll(); forwardOwners.removeAll(); isLoading = false
        let id = UUID()
        drains[id] = Task { [weak self] in await task?.value; await timer?.value; if let transport, let binding { _ = try? await transport.release(.init(binding: binding)) }; self?.drains.removeValue(forKey: id) }
    }
    func drainReads() async { for task in Array(drains.values) { await task.value } }
    func shutdown() async { stopped = true; unbind(); for task in Array(writes.values) { await task.value }; await drainReads() }
    func cancelShutdown() { stopped = false }
}
