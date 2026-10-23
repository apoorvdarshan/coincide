import AppKit
import CoincideCore
import Observation

private final class ThreadActionUndoTextObservation: @unchecked Sendable {
    private let token: any NSObjectProtocol
    init(_ token: any NSObjectProtocol) { self.token = token }
    deinit { NotificationCenter.default.removeObserver(token) }
}

/// A notice belongs to the window that initiated the action, including after
/// selection moves. Claims are consumed synchronously before native admission.
@MainActor @Observable
final class ThreadActionUndoStore {
    struct ActionOwner: Sendable {
        let id: UUID
        let windowEpoch: UUID
        let shortcutEpoch: UUID
    }
    private struct Entry { let claim: ThreadActionUndoClaim; let bytes: Int }
    private final class Window { weak var value: NSWindow?; init(_ value: NSWindow) { self.value = value } }
    @ObservationIgnored private var windows: [UUID: Window] = [:]
    @ObservationIgnored private var windowEpochs: [UUID: UUID] = [:]
    @ObservationIgnored private var shortcutEpochs: [UUID: UUID] = [:]
    @ObservationIgnored private var expiries: [UUID: Task<Void, Never>] = [:]
    private var entries: [Entry] = []
    private var shortcutOwners: Set<UUID> = []
    private var deadlines: [UUID: Date] = [:]
    @ObservationIgnored private var generations: [UUID: UUID] = [:]
    @ObservationIgnored private var stopping = false
    @ObservationIgnored private var edits: ThreadActionUndoTextObservation?
    init() {
        let token = NotificationCenter.default.addObserver(forName: NSText.didChangeNotification, object: nil, queue: .main) { [weak self] note in
            guard let editor = note.object as? NSTextView else { return }
            MainActor.assumeIsolated {
                guard let self, let window = editor.window else { return }
                for (owner, holder) in self.windows where holder.value === window { self.releaseShortcut(ownerID: owner) }
            }
        }
        edits = ThreadActionUndoTextObservation(token)
    }

    func register(_ window: NSWindow, ownerID: UUID) {
        guard !stopping, windows[ownerID]?.value !== window else { return }
        windows[ownerID] = Window(window); windowEpochs[ownerID] = UUID(); shortcutEpochs[ownerID] = UUID()
    }
    func unregister(_ ownerID: UUID) {
        windows.removeValue(forKey: ownerID); if let timer = generations.removeValue(forKey: ownerID) { expiries[timer]?.cancel() }; deadlines.removeValue(forKey: ownerID); entries.removeAll { $0.claim.ownerID == ownerID }; shortcutOwners.remove(ownerID)
        windowEpochs.removeValue(forKey: ownerID); shortcutEpochs.removeValue(forKey: ownerID)
    }
    var actionOwner: ActionOwner? {
        let owners = windows.compactMap { id, holder in holder.value.map { $0.isKeyWindow || $0.attachedSheet?.isKeyWindow == true ? id : nil } ?? nil }
        guard owners.count == 1, let id = owners.first, let windowEpoch = windowEpochs[id], let shortcutEpoch = shortcutEpochs[id] else { return nil }
        return .init(id: id, windowEpoch: windowEpoch, shortcutEpoch: shortcutEpoch)
    }
    func record(_ claim: ThreadActionUndoClaim, owner: ActionOwner, now: Date = Date()) {
        let ownerID = owner.id
        guard !stopping, claim.ownerID == ownerID, windows[ownerID]?.value != nil,
              windowEpochs[ownerID] == owner.windowEpoch else { return }
        // A later same-kind action for the same conversation supersedes its inverse.
        entries.removeAll { $0.claim.threadID == claim.threadID && $0.claim.kind == claim.kind }
        guard let bytes = try? JSONEncoder().encode(claim).count, bytes <= 64 * 1_024 * 1_024 else { return }
        while entries.count >= 128 || entries.reduce(0, { $0 + $1.bytes }) + bytes > 64 * 1_024 * 1_024 { entries.removeFirst() }
        entries.append(.init(claim: claim, bytes: bytes))
        if shortcutEpochs[ownerID] == owner.shortcutEpoch { shortcutOwners.insert(ownerID) }
        deadlines[ownerID] = now.addingTimeInterval(5)
        if let previous = generations[ownerID] { expiries[previous]?.cancel() }
        let captured = UUID(); generations[ownerID] = captured
        expiries[captured] = Task { [weak self] in
            do { try await Task.sleep(for: .seconds(5)) } catch {
                self?.expiries.removeValue(forKey: captured); return
            }
            guard let self else { return }
            defer { self.expiries.removeValue(forKey: captured) }
            guard self.generations[ownerID] == captured else { return }
            self.entries.removeAll { $0.claim.ownerID == ownerID }; self.shortcutOwners.remove(ownerID)
            self.deadlines.removeValue(forKey: ownerID); self.generations.removeValue(forKey: ownerID)
        }
    }
    func group(ownerID: UUID, now: Date = Date()) -> [ThreadActionUndoClaim] {
        guard !stopping, deadlines[ownerID].map({ $0 > now }) == true else { return [] }
        let owned = entries.filter { $0.claim.ownerID == ownerID }
        guard let latest = owned.last else { return [] }
        return owned.reversed().prefix { $0.claim.kind == latest.claim.kind }.reversed().map(\.claim)
    }
    func claimsShortcut(ownerID: UUID) -> Bool { shortcutOwners.contains(ownerID) && !group(ownerID: ownerID).isEmpty }
    func releaseShortcut(ownerID: UUID) {
        shortcutOwners.remove(ownerID)
        if windows[ownerID] != nil { shortcutEpochs[ownerID] = UUID() }
    }
    func releaseCurrentShortcut() { if let owner = actionOwner { releaseShortcut(ownerID: owner.id) } }
    func consume(ownerID: UUID, expectedIDs: [UUID]? = nil) -> [ThreadActionUndoClaim] {
        let claims = group(ownerID: ownerID)
        guard expectedIDs.map({ $0 == claims.map(\.id) }) ?? true else { return [] }
        let ids = Set(claims.map(\.id))
        entries.removeAll { ids.contains($0.claim.id) }
        if group(ownerID: ownerID).isEmpty { shortcutOwners.remove(ownerID) }
        return claims
    }
    func invalidate(snapshot: WorkspaceSnapshot) { entries.removeAll { !$0.claim.isApplicable(to: snapshot) } }
    func shutdown() async {
        stopping = true
        edits = nil
        let tasks = Array(expiries.values); expiries.removeAll(); for task in tasks { task.cancel() }
        entries.removeAll(); windows.removeAll(); windowEpochs.removeAll(); shortcutEpochs.removeAll(); shortcutOwners.removeAll(); for task in tasks { await task.value }
    }
}
