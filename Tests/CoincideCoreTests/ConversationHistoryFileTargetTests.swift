import Foundation
import Testing
@testable import CoincideCore

private struct HistoryFileTargetFixture {
    var thread: CodingThread
    var runs: [UUID] = []
    private var objectNumber = 1
    let now = Date(timeIntervalSince1970: 1_700_300_000)

    init(count: Int = 2) throws {
        let project = WorkspaceProject(path: "/tmp/coincide-history-file-target")
        thread = .init(project: project, model: "captured-model")
        thread.providerThreadID = "native-file-target"
        for _ in 0..<count { try appendRun() }
    }

    mutating func appendRun(origin: ThreadRunOrigin = .user) throws {
        let runID = UUID(), userID = "user-\(runID.uuidString)"
        var configuration = ProviderConfiguration(thread: thread)
        if runs.isEmpty { configuration.nativeThreadID = nil }
        let start = now.addingTimeInterval(Double(runs.count * 10))
        let active = ActiveRun(id: runID, configuration: configuration, startedAt: start,
                               nativeTurnID: "native-turn-\(runs.count)")
        var record = ThreadRunRecord(run: active, origin: origin, userMessageID: origin == .user ? userID : nil)
        record.providerThreadID = thread.providerThreadID
        record.status = .completed; record.endedAt = start.addingTimeInterval(2)
        record.endReason = .providerCompleted; record.messageAttributionVersion = 1
        record.checkpoints = .init(baseline: try readyAttempt(), providerReleased: true)
        record.checkpoints?.postRun = try readyAttempt()
        var opening = ChatMessage(id: userID, role: origin == .user ? .user : .assistant, text: "Local input \(runs.count)")
        opening.runReference = .init(threadID: thread.id, runID: runID)
        var answer = ChatMessage(id: "answer-\(runID.uuidString)", role: .assistant, text: "Local reply")
        answer.runReference = opening.runReference
        thread.messages += [opening, answer]
        if thread.runHistory == nil { thread.runHistory = [] }
        thread.runHistory!.append(record); runs.append(runID)
    }

    mutating func readyAttempt(later: Bool = false, date: Date? = nil) throws -> ThreadRunCheckpointAttempt {
        let id = UUID(), path = thread.workspacePath
        let identity = GitWorktreeNodeIdentity(device: 1, inode: 42)
        let plan = try GitCheckpointPlan(id: id, workspacePath: path, repositoryPath: path,
            gitDirectoryPath: path + "/.git", commonDirectoryPath: path + "/.git",
            workspaceIdentity: identity, repositoryIdentity: identity, gitDirectoryIdentity: identity,
            commonDirectoryIdentity: identity, objectDirectoryIdentity: identity,
            headCommit: String(repeating: "a", count: 40), configurationDigest: String(repeating: "b", count: 64), indexRevision: nil)
        let object = String(objectNumber, radix: 16)
        objectNumber += 1
        var attempt = ThreadRunCheckpointAttempt(id: id, workspacePath: path, phase: .ready,
            now: date ?? now, isLaterObservation: later)
        attempt.plan = plan
        attempt.receipt = try .init(plan: plan, commit: String(repeating: "0", count: 40 - object.count) + object,
            tree: String(repeating: "0", count: 40 - object.count) + object, capturedAt: date ?? now)
        return attempt
    }

    func target(at index: Int, including operationID: UUID? = nil) throws -> ConversationHistoryFileTarget {
        let resolution = thread.conversationHistoryFileTarget(beforeRunID: runs[index], includingRemovedByHistoryOperationID: operationID)
        guard case .available(let target) = resolution else { throw CoincideError("Expected a proven file target; received \(resolution).") }
        return target
    }

    mutating func hideRun(at index: Int, by operationID: UUID) {
        thread.runHistory?[index].removedByHistoryOperationID = operationID
        let reference = TranscriptRunReference(threadID: thread.id, runID: runs[index])
        for i in thread.messages.indices where thread.messages[i].runReference == reference {
            thread.messages[i].removedByHistoryOperationID = operationID
        }
    }
}

@Test func conversationHistoryFileTargetUsesPreviousPostInsteadOfSelectedBaseline() throws {
    let fixture = try HistoryFileTargetFixture(), target = try fixture.target(at: 1)
    let previous = try #require(fixture.thread.runHistory?[0].checkpoints?.postRun)
    let selectedBaseline = try #require(fixture.thread.runHistory?[1].checkpoints?.baseline)
    #expect(target.selectedRunID == fixture.runs[1] && target.checkpointRunID == fixture.runs[0])
    #expect(target.stage == .postRun && target.attemptID == previous.id && target.receipt == previous.receipt)
    #expect(target.receipt != selectedBaseline.receipt)
    #expect(target.workspacePath == fixture.thread.workspacePath)
    try target.validate()
}

@Test func conversationHistoryFileTargetUsesLastReadyObservationInRecordedOrder() throws {
    var fixture = try HistoryFileTargetFixture()
    let old = try #require(fixture.thread.runHistory?[0].checkpoints?.postRun)
    let newest = try fixture.readyAttempt(later: true, date: fixture.now.addingTimeInterval(-100))
    fixture.thread.runHistory?[0].checkpoints?.previousPostRunAttempts = [old, newest]
    let skipped = ThreadRunCheckpointAttempt(workspacePath: fixture.thread.workspacePath, phase: .skipped, now: fixture.now)
    fixture.thread.runHistory?[0].checkpoints?.postRun = skipped
    #expect(try fixture.target(at: 1).attemptID == newest.id)
    let latest = try fixture.readyAttempt(later: true, date: fixture.now.addingTimeInterval(-200))
    fixture.thread.runHistory?[0].checkpoints?.postRun = latest
    #expect(try fixture.target(at: 1).receipt == latest.receipt)
}

@Test(arguments: ["missing", "unavailable", "failed", "capturing"])
func conversationHistoryFileTargetNeverFallsBackToSelectedBaselineWhenPreviousPostIsUnavailable(change: String) throws {
    var fixture = try HistoryFileTargetFixture()
    switch change {
    case "missing": fixture.thread.runHistory?[0].checkpoints?.postRun = nil
    case "unavailable":
        let unavailable = ThreadRunCheckpointAttempt(workspacePath: fixture.thread.workspacePath,
            phase: .unavailable, now: fixture.now, unavailableReason: .notRepository)
        fixture.thread.runHistory?[0].checkpoints?.postRun = unavailable
    case "failed":
        let old = try #require(fixture.thread.runHistory?[0].checkpoints?.postRun)
        fixture.thread.runHistory?[0].checkpoints?.previousPostRunAttempts = [old]
        var failed = ThreadRunCheckpointAttempt(workspacePath: fixture.thread.workspacePath, phase: .failed, now: fixture.now)
        failed.error = ThreadRunCheckpointAttempt.failureMessage
        fixture.thread.runHistory?[0].checkpoints?.postRun = failed
    default:
        var pending = try fixture.readyAttempt(later: true)
        pending.phase = .capturing; pending.receipt = nil
        fixture.thread.runHistory?[0].checkpoints?.postRun = pending
    }
    let reason: ConversationHistoryFileTargetUnavailableReason = change == "failed" || change == "capturing" ? .unsettledWorkspace : .previousPostUnavailable
    #expect(fixture.thread.conversationHistoryFileTarget(beforeRunID: fixture.runs[1]) == .unavailable(reason))
}

@Test func conversationHistoryFileTargetFirstLocalInputUsesOriginalPreProviderBaseline() throws {
    let fixture = try HistoryFileTargetFixture(), target = try fixture.target(at: 0)
    let original = try #require(fixture.thread.runHistory?.first?.checkpoints?.baseline)
    #expect(target.stage == .baseline && target.checkpointRunID == fixture.runs[0])
    #expect(target.attemptID == original.id && target.receipt == original.receipt)
    #expect(fixture.thread.runHistory?.first?.configuration.nativeThreadID == nil)
}

@Test func conversationHistoryFileTargetRetainsScopeZeroAfterRewindingEveryOriginalRun() throws {
    var fixture = try HistoryFileTargetFixture()
    let original = try fixture.target(at: 0), priorRewind = UUID()
    fixture.hideRun(at: 0, by: priorRewind); fixture.hideRun(at: 1, by: priorRewind)
    try fixture.appendRun()
    let target = try fixture.target(at: 2)
    #expect(target.selectedRunID == fixture.runs[2] && target.stage == .baseline)
    #expect(target.checkpointRunID == fixture.runs[0] && target.receipt == original.receipt)
    #expect(target.receipt != fixture.thread.runHistory?[2].checkpoints?.baseline.receipt)
    #expect(fixture.thread.conversationHistoryFileTarget(beforeRunID: fixture.runs[0]) == .unavailable(.removedRun))
}

@Test(arguments: ["legacy", "agent", "missing", "alreadyNative", "unreleased", "laterObservation", "inheritedPrefix", "unattributedPrefix", "fork"])
func conversationHistoryFileTargetDoesNotInventAnOriginalBaseline(change: String) throws {
    var fixture = try HistoryFileTargetFixture()
    let priorRewind = UUID()
    switch change {
    case "legacy": fixture.thread.runHistory?[0].messageAttributionVersion = nil
    case "agent": fixture.thread.runHistory?[0].origin = .agent
    case "missing": fixture.thread.runHistory?[0].checkpoints = nil
    case "alreadyNative": fixture.thread.runHistory?[0].configuration.nativeThreadID = fixture.thread.providerThreadID
    case "unreleased":
        fixture.thread.runHistory?[0].checkpoints?.providerReleased = false
        let unavailable = ThreadRunCheckpointAttempt(workspacePath: fixture.thread.workspacePath,
            phase: .unavailable, now: fixture.now, unavailableReason: .providerNotStarted)
        fixture.thread.runHistory?[0].checkpoints?.postRun = unavailable
    case "laterObservation":
        let later = try fixture.readyAttempt(later: true)
        fixture.thread.runHistory?[0].checkpoints?.baseline = later
    case "inheritedPrefix":
        var inherited = ChatMessage(id: "inherited-user", role: .user, text: "Inherited context")
        inherited.runReference = .init(threadID: UUID(), runID: UUID())
        fixture.thread.messages.insert(inherited, at: 0)
    case "unattributedPrefix": fixture.thread.messages.insert(.init(id: "unknown-user", role: .user, text: "Unattributed context"), at: 0)
    default: fixture.thread.forkedFromHistoryOperationID = UUID()
    }
    fixture.hideRun(at: 0, by: priorRewind); fixture.hideRun(at: 1, by: priorRewind)
    // Earlier inherited/unattributed rows are retained audit, not a new scope-zero proof.
    for i in fixture.thread.messages.indices where fixture.thread.messages[i].runReference?.threadID != fixture.thread.id {
        fixture.thread.messages[i].removedByHistoryOperationID = priorRewind
    }
    try fixture.appendRun()
    #expect(fixture.thread.conversationHistoryFileTarget(beforeRunID: fixture.runs[2]) == .unavailable(.originalBaselineUnavailable))
}

@Test func conversationHistoryFileTargetSkipsRemovedPredecessorsAndIncludesVisibleAgentRuns() throws {
    var fixture = try HistoryFileTargetFixture()
    fixture.hideRun(at: 1, by: UUID())
    try fixture.appendRun(origin: .agent)
    try fixture.appendRun()
    let target = try fixture.target(at: 3)
    #expect(target.checkpointRunID == fixture.runs[2] && target.stage == .postRun)
    fixture.hideRun(at: 2, by: UUID())
    #expect(try fixture.target(at: 3).checkpointRunID == fixture.runs[0])
}

@Test(arguments: ["unknownRun", "removed", "agentSelected", "legacySelected", "interleaved", "missingPreviousMessages", "legacyPrevious", "unattributedSuffix"])
func conversationHistoryFileTargetRejectsAmbiguousOrUnsupportedLocalBoundaries(change: String) throws {
    var fixture = try HistoryFileTargetFixture()
    var selectedID = fixture.runs[1]
    switch change {
    case "unknownRun": selectedID = UUID()
    case "removed": fixture.hideRun(at: 1, by: UUID())
    case "agentSelected": fixture.thread.runHistory?[1].origin = .agent
    case "legacySelected": fixture.thread.runHistory?[1].messageAttributionVersion = nil
    case "interleaved": fixture.thread.messages.swapAt(1, 2)
    case "missingPreviousMessages":
        let previous = TranscriptRunReference(threadID: fixture.thread.id, runID: fixture.runs[0])
        // Retained rows with mismatched removal markers cannot establish a visible predecessor.
        for i in fixture.thread.messages.indices where fixture.thread.messages[i].runReference == previous {
            fixture.thread.messages[i].removedByHistoryOperationID = UUID()
        }
    case "legacyPrevious": fixture.thread.runHistory?[0].messageAttributionVersion = nil
    default: fixture.thread.messages.append(.init(id: "unattributed-suffix", role: .assistant, text: "Unknown later output"))
    }
    guard case .unavailable = fixture.thread.conversationHistoryFileTarget(beforeRunID: selectedID) else {
        Issue.record("An unproven local boundary must not produce a restore target."); return
    }
}

@Test(arguments: ["provider", "nativeThread", "capturedNativeThread", "path", "previousPath"])
func conversationHistoryFileTargetRequiresCurrentProviderAndWorkspaceOwnership(change: String) throws {
    var fixture = try HistoryFileTargetFixture()
    switch change {
    case "provider": fixture.thread.provider = .claude
    case "nativeThread": fixture.thread.providerThreadID = "another-native-conversation"
    case "capturedNativeThread": fixture.thread.runHistory?[1].configuration.nativeThreadID = "another-native-conversation"
    case "path": fixture.thread.workspacePath += "-replacement"
    default: fixture.thread.runHistory?[0].configuration.workspacePath += "-different"
    }
    guard case .unavailable = fixture.thread.conversationHistoryFileTarget(beforeRunID: fixture.runs[1]) else {
        Issue.record("Another workspace or provider must not acquire the retained checkpoint."); return
    }
}

@Test(arguments: ["busy", "queued", "archived", "settled", "question"])
func conversationHistoryFileTargetRequiresASettledSource(change: String) throws {
    var fixture = try HistoryFileTargetFixture()
    switch change {
    case "busy": fixture.thread.state = .running
    case "queued": fixture.thread.queuedTurns = [.init(id: UUID(), text: "Retained queued input", configuration: .init(thread: fixture.thread), createdAt: fixture.now)]
    case "archived": fixture.thread.isArchived = true
    case "settled": fixture.thread.settlement = .init(settledAt: fixture.now)
    default: fixture.thread.runtimeRequests = [.init(request: .init(id: .string("held-question"), method: "item/tool/requestUserInput", params: .object([:]))) ]
    }
    #expect(fixture.thread.conversationHistoryFileTarget(beforeRunID: fixture.runs[1]) == .unavailable(.unsettledWorkspace))
}

@Test func conversationHistoryFileTargetRevalidationRestoresOnlyItsOwnRemovedAuditVisibility() throws {
    var fixture = try HistoryFileTargetFixture(count: 3)
    let oldOperation = UUID(), ownOperation = UUID()
    fixture.hideRun(at: 1, by: oldOperation)
    let target = try fixture.target(at: 2)
    #expect(target.checkpointRunID == fixture.runs[0])
    fixture.hideRun(at: 2, by: ownOperation)
    #expect(fixture.thread.conversationHistoryFileTarget(beforeRunID: fixture.runs[2]) == .unavailable(.removedRun))
    #expect(try fixture.target(at: 2, including: ownOperation) == target)
    #expect(fixture.thread.conversationHistoryFileTarget(beforeRunID: fixture.runs[2], includingRemovedByHistoryOperationID: oldOperation) == .unavailable(.removedRun))
    #expect(fixture.thread.runHistory?[1].removedByHistoryOperationID == oldOperation)
    #expect(fixture.thread.runHistory?[2].removedByHistoryOperationID == ownOperation)
}

@Test func conversationHistoryFileTargetValidationRejectsForgedAttemptAndSelfPostOwnership() throws {
    let fixture = try HistoryFileTargetFixture(), target = try fixture.target(at: 1)
    #expect(throws: (any Error).self) {
        try ConversationHistoryFileTarget(selectedRunID: target.selectedRunID, checkpointRunID: target.checkpointRunID,
            stage: .postRun, attemptID: UUID(), receipt: target.receipt)
    }
    #expect(throws: (any Error).self) {
        try ConversationHistoryFileTarget(selectedRunID: target.selectedRunID, checkpointRunID: target.selectedRunID,
            stage: .postRun, attemptID: target.attemptID, receipt: target.receipt)
    }
    let encoded = try JSONEncoder().encode(target)
    #expect(try JSONDecoder().decode(ConversationHistoryFileTarget.self, from: encoded) == target)
    var object = try #require(JSONSerialization.jsonObject(with: encoded) as? [String: Any])
    object["attemptID"] = UUID().uuidString
    let forged = try JSONSerialization.data(withJSONObject: object)
    #expect(throws: (any Error).self) { try JSONDecoder().decode(ConversationHistoryFileTarget.self, from: forged) }
}

@Test func conversationHistoryFileTargetRequiresExactReadyReceiptPlanEvidence() throws {
    var fixture = try HistoryFileTargetFixture()
    let other = try fixture.readyAttempt()
    fixture.thread.runHistory?[0].checkpoints?.postRun?.receipt = other.receipt
    guard case .unavailable = fixture.thread.conversationHistoryFileTarget(beforeRunID: fixture.runs[1]) else {
        Issue.record("A ready flag without its own exact plan receipt cannot establish a file target."); return
    }
}
