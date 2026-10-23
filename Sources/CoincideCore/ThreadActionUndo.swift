import Foundation
import CryptoKit

public enum ThreadActionUndoKind: String, Codable, Sendable {
    case archive, unpin, settle, snooze, discard
    public var title: String {
        switch self { case .archive: "Archived"; case .unpin: "Unpinned"; case .settle: "Settled"; case .snooze: "Snoozed"; case .discard: "Discarded" }
    }
}

/// Explicit discard is distinct from stashing and is bound to the original
/// conversation incarnation as well as its exact draft/reference bytes.
public struct ThreadDraftDiscard: Codable, Sendable, Equatable {
    private struct Payload: Codable, Sendable { let expected: ComposerDraftSnapshot; let threadCreatedAt: Date }
    private let storage: [Payload]
    public var expected: ComposerDraftSnapshot { storage[0].expected }
    public var threadCreatedAt: Date { storage[0].threadCreatedAt }
    public init(thread: CodingThread) {
        storage = [.init(expected: .init(threadID: thread.id, projectID: thread.projectID, workspacePath: thread.workspacePath,
                                        text: thread.draft, attachments: thread.draftAttachments), threadCreatedAt: thread.createdAt)]
    }
    public static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.threadCreatedAt == rhs.threadCreatedAt && lhs.expected.matches(rhs.expected)
    }
    public init(from decoder: any Decoder) throws { storage = [try Payload(from: decoder)] }
    public func encode(to encoder: any Encoder) throws { try storage[0].encode(to: encoder) }
}

/// Ephemeral, immutable inverse data. Encoding stays flat; native authority is
/// the Engine's bounded registry, never possession of a decoded CAS payload.
public struct ThreadActionUndoClaim: Codable, Sendable, Equatable, Identifiable {
    struct State: Codable, Sendable {
        let threadID: UUID, projectID: UUID
        let birth: Date
        let projectBirth: Date?
        let workspacePath: String, projectPath: String
        let preparationID: UUID?
        let configurationDigest: Data
        let archived: Bool, pinned: Bool, queuePaused: Bool
        let settlementID: UUID?
        let settlementPhase: ThreadSettlementPhase?
        let scriptID: UUID?
        let lifecycle: ThreadWorkspaceLifecycle?
        let draft: ComposerDraftSnapshot?
        init(thread: CodingThread, project: WorkspaceProject, draft: Bool) {
            threadID = thread.id; projectID = project.id; birth = thread.createdAt; projectBirth = project.createdAt
            workspacePath = thread.workspacePath; projectPath = project.path; preparationID = thread.workspacePreparation?.id
            let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
            configurationDigest = (try? encoder.encode(ProviderConfiguration(thread: thread))).map { Data(SHA256.hash(data: $0)) } ?? Data()
            archived = thread.isArchived; pinned = thread.isPinned; queuePaused = thread.queuePaused
            settlementID = thread.settlement?.id; settlementPhase = thread.settlement?.phase; scriptID = thread.settlement?.script?.id
            lifecycle = thread.workspaceLifecycle
            self.draft = draft ? .init(threadID: thread.id, projectID: thread.projectID, workspacePath: thread.workspacePath,
                                      text: thread.draft, attachments: thread.draftAttachments) : nil
        }
    }
    private struct Payload: Codable, Sendable {
        let id: UUID, forwardCommandID: UUID
        let ownerID: UUID?
        let kind: ThreadActionUndoKind
        let before: State, after: State
    }
    private let storage: [Payload]
    public var id: UUID { storage[0].id }
    public var forwardCommandID: UUID { storage[0].forwardCommandID }
    public var ownerID: UUID? { storage[0].ownerID }
    public var kind: ThreadActionUndoKind { storage[0].kind }
    public var threadID: UUID { storage[0].after.threadID }
    public var projectID: UUID { storage[0].after.projectID }
    public var threadCreatedAt: Date { storage[0].after.birth }
    public var workspacePath: String { storage[0].after.workspacePath }
    var before: State { storage[0].before }
    var after: State { storage[0].after }
    private init(id: UUID = UUID(), forwardCommandID: UUID, ownerID: UUID? = nil, kind: ThreadActionUndoKind, before: State, after: State) {
        storage = [.init(id: id, forwardCommandID: forwardCommandID, ownerID: ownerID, kind: kind, before: before, after: after)]
    }
    func owned(by id: UUID) -> Self { .init(id: self.id, forwardCommandID: forwardCommandID, ownerID: id, kind: kind, before: before, after: after) }
    public init(from decoder: any Decoder) throws { storage = [try Payload(from: decoder)] }
    public func encode(to encoder: any Encoder) throws { try storage[0].encode(to: encoder) }
    public static func == (lhs: Self, rhs: Self) -> Bool { exact(lhs, rhs) }
    static func exact<T: Encodable>(_ lhs: T, _ rhs: T) -> Bool {
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
        guard let a = try? encoder.encode(lhs), let b = try? encoder.encode(rhs) else { return false }
        return a == b
    }
    static func capture(_ command: EngineCommand, id: UUID, previous: WorkspaceSnapshot, next: WorkspaceSnapshot) -> Self? {
        let kind: ThreadActionUndoKind, threadID: UUID
        switch command {
        case .client(.editThread(let id, .archived(true))): kind = .archive; threadID = id
        case .client(.editThread(let id, .pinned(false))): kind = .unpin; threadID = id
        case .client(.settleThread(let id, _, _)): kind = .settle; threadID = id
        case .client(.workspaceLifecycle(.snooze(let id, _))): kind = .snooze; threadID = id
        case .client(.discardComposerDraft(let discard)): kind = .discard; threadID = discard.expected.threadID
        case .remoteEnvironment(let request, _):
            switch request.command {
            case .threadAction(.setPinned(let capture, false)): kind = .unpin; threadID = capture.target.threadID
            case .threadAction(.setArchived(let capture, true)): kind = .archive; threadID = capture.target.threadID
            case .lifecycle(let capture, .snooze): kind = .snooze; threadID = capture.target.threadID
            case .lifecycle(let capture, .settleWithoutScript), .lifecycle(let capture, .settleReviewingScript): kind = .settle; threadID = capture.target.threadID
            default: return nil
            }
        default: return nil
        }
        guard let old = previous.threads.first(where: { $0.id == threadID }), let current = next.threads.first(where: { $0.id == threadID }),
              let project = previous.projects.first(where: { $0.id == old.projectID }),
              let newProject = next.projects.first(where: { $0.id == current.projectID }), old.id == current.id,
              old.createdAt == current.createdAt, old.projectID == current.projectID,
              old.workspacePath.utf8.elementsEqual(current.workspacePath.utf8),
              project.createdAt == newProject.createdAt, project.path.utf8.elementsEqual(newProject.path.utf8) else { return nil }
        switch kind {
        case .archive: guard !old.isArchived, current.isArchived else { return nil }
        case .unpin: guard old.isPinned, !current.isPinned else { return nil }
        case .settle: guard old.settlement == nil, current.settlement?.id == id, current.settlement?.phase == .settled else { return nil }
        case .snooze: guard current.workspaceLifecycle?.snoozedUntil != nil,
            old.workspaceLifecycle?.snoozedUntil != current.workspaceLifecycle?.snoozedUntil || old.workspaceLifecycle?.snoozedAt != current.workspaceLifecycle?.snoozedAt else { return nil }
        case .discard: guard (!old.draft.isEmpty || !old.draftAttachments.isEmpty), current.draft.isEmpty, current.draftAttachments.isEmpty else { return nil }
        }
        let before = State(thread: old, project: project, draft: kind == .discard)
        let after = State(thread: current, project: newProject, draft: kind == .discard)
        guard before.configurationDigest.count == 32, after.configurationDigest.count == 32 else { return nil }
        return .init(forwardCommandID: id, kind: kind, before: before, after: after)
    }
    public func isApplicable(to snapshot: WorkspaceSnapshot) -> Bool {
        guard after.configurationDigest.count == 32, let thread = snapshot.threads.first(where: { $0.id == threadID }),
              let project = snapshot.projects.first(where: { $0.id == projectID }) else { return false }
        return Self.exact(after, State(thread: thread, project: project, draft: kind == .discard))
    }
}

/// Both retrieval and final acceptance enforce the lifetime. New actions in
/// one window extend its whole grouped notice, matching T3's five-second timer.
final class ThreadActionUndoRegistry {
    private struct Record { var claim: ThreadActionUndoClaim; var deadline: Date; let bytes: Int }
    private var records: [UUID: Record] = [:]
    private var forwards: [UUID: UUID] = [:]
    private var order: [UUID] = []
    private var byteCount = 0
    static let lifetime: TimeInterval = 5
    static let maximumBytes = 64 * 1_024 * 1_024
    func record(_ claim: ThreadActionUndoClaim, now: Date) {
        prune(now: now)
        guard records[claim.id] == nil else { return }
        guard let encoded = try? JSONEncoder().encode(claim).count else { return }
        let bytes = encoded + 256 // Reserve the bounded owner-ID assignment before take().
        guard bytes <= Self.maximumBytes else { return }
        while byteCount + bytes > Self.maximumBytes || records.count >= 128 {
            guard let id = order.first else { return }; remove(id)
        }
        records[claim.id] = .init(claim: claim, deadline: now.addingTimeInterval(Self.lifetime), bytes: bytes)
        forwards[claim.forwardCommandID] = claim.id; order.append(claim.id); byteCount += bytes
    }
    func take(forwardID: UUID, ownerID: UUID, now: Date) -> ThreadActionUndoClaim? {
        prune(now: now)
        guard let id = forwards.removeValue(forKey: forwardID), var record = records[id], record.claim.ownerID == nil else { return nil }
        record.claim = record.claim.owned(by: ownerID); records[id] = record
        for key in Array(records.keys) where records[key]?.claim.ownerID == ownerID {
            records[key]?.deadline = now.addingTimeInterval(Self.lifetime)
        }
        return record.claim
    }
    func validate(_ claim: ThreadActionUndoClaim, commandID: UUID, now: Date) throws {
        prune(now: now)
        guard commandID == claim.id, claim.ownerID != nil, let record = records[claim.id],
              record.deadline > now, record.claim == claim else { throw WorkspaceCommandError("This Undo action expired or belongs to another window.") }
    }
    func reconcile(snapshot: WorkspaceSnapshot, now: Date) {
        prune(now: now)
        for id in Array(order) where records[id].map({ !$0.claim.isApplicable(to: snapshot) }) ?? true { remove(id) }
    }
    func owned(by ownerID: UUID, now: Date) -> (claims: [ThreadActionUndoClaim], deadline: Date?) {
        prune(now: now)
        let result = order.compactMap { records[$0] }.filter { $0.claim.ownerID == ownerID }
        return (result.map(\.claim), result.map(\.deadline).min())
    }
    func remove(ownerID: UUID) { for id in Array(order) where records[id]?.claim.ownerID == ownerID { remove(id) } }
    func consume(_ id: UUID) { remove(id) }
    func removeAll() { records.removeAll(); forwards.removeAll(); order.removeAll(); byteCount = 0 }
    private func prune(now: Date) { for id in Array(order) where records[id].map({ $0.deadline <= now }) ?? true { remove(id) } }
    private func remove(_ id: UUID) {
        if let removed = records.removeValue(forKey: id) { byteCount -= removed.bytes; forwards.removeValue(forKey: removed.claim.forwardCommandID) }
        order.removeAll { $0 == id }
    }
}

extension WorkspaceDecision {
    @inline(never)
    mutating func applyThreadActionUndo(_ claim: ThreadActionUndoClaim, id: UUID, now: Date) throws {
        guard id == claim.id, claim.isApplicable(to: snapshot), let index = snapshot.threads.firstIndex(where: { $0.id == claim.threadID }) else {
            throw WorkspaceCommandError("The conversation changed after this action. Its newer state was preserved.")
        }
        let previous = snapshot
        switch claim.kind {
        case .archive:
            try prepareClientCommand(.editThread(claim.threadID, .archived(false)), commandID: id, now: now)
            snapshot.threads[index].isArchived = false
            // Archiving drains runtimes. Undo restores visibility, never input.
            snapshot.threads[index].queuePaused = true
        case .unpin:
            try prepareClientCommand(.editThread(claim.threadID, .pinned(true)), commandID: id, now: now)
            snapshot.threads[index].isPinned = true
            reconcileWorkspaceLifecycle(previous: previous, command: .editThread(claim.threadID, .pinned(true)), now: now)
            restoreSnooze(claim.before.lifecycle, index: index, now: now)
        case .snooze:
            try prepareClientCommand(.workspaceLifecycle(.wake(threadID: claim.threadID)), commandID: id, now: now)
            try applyWorkspaceLifecycle(.wake(threadID: claim.threadID), commandID: id, now: now, policy: snapshot.workspaceLifecyclePolicy ?? .init())
        case .settle:
            guard let generation = claim.after.settlementID, snapshot.threads[index].settlement?.phase == .settled,
                  !snapshot.threads[index].isArchived, snapshot.threads[index].activeRun == nil,
                  snapshot.threads[index].queuedTurns.isEmpty, snapshot.threads[index].runtimeRequests.isEmpty else {
                throw WorkspaceCommandError("This settlement changed. Resume it explicitly in its current state.")
            }
            try prepareClientCommand(.resumeThread(threadID: claim.threadID, generationID: generation), commandID: id, now: now)
            snapshot.threads[index].requestSettlementResume(now: now)
            reconcileWorkspaceLifecycle(previous: previous, command: .resumeThread(threadID: claim.threadID, generationID: generation), now: now)
            snapshot.threads[index].isPinned = claim.before.pinned
            restoreSnooze(claim.before.lifecycle, index: index, now: now)
        case .discard:
            guard let expected = claim.after.draft, let original = claim.before.draft else { throw WorkspaceCommandError("This draft cannot be restored.") }
            let replacement = ComposerDraftReplacement(expected: expected, text: original.text, attachments: original.attachments)
            try prepareClientCommand(.replaceComposerDraft(replacement), commandID: id, now: now)
            try replaceComposerDraft(replacement)
        }
        snapshot.threads[index].updatedAt = now
    }
    private mutating func restoreSnooze(_ original: ThreadWorkspaceLifecycle?, index: Int, now: Date) {
        guard let until = original?.snoozedUntil, until > now else { return }
        var value = snapshot.threads[index].workspaceLifecycle ?? .init()
        value.snoozedUntil = until; value.snoozedAt = original?.snoozedAt ?? now
        snapshot.threads[index].workspaceLifecycle = value
    }
}
