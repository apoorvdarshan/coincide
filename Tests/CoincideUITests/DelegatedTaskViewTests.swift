import AppKit
import Foundation
import SwiftUI
import Testing
@testable import Coincide
@testable import CoincideCore

private actor TaskPanelGate {
    private var entered = false
    private var done = false
    private var arrival: [CheckedContinuation<Void, Never>] = []
    private var exit: CheckedContinuation<Void, Never>?
    func wait() async { entered = true; arrival.forEach { $0.resume() }; arrival = []; if !done { await withCheckedContinuation { exit = $0 } } }
    func started() async { if !entered { await withCheckedContinuation { arrival.append($0) } } }
    func release() { done = true; exit?.resume(); exit = nil }
}
private actor TaskPanelPeer {
    var values: [UUID: DelegatedTaskStatusSnapshot]
    var reads: [UUID] = []
    var cancels: [UUID] = []
    var cancellationWasCancelled = false
    var readGate: TaskPanelGate?
    var cancelGate: TaskPanelGate?
    init(_ values: [UUID: DelegatedTaskStatusSnapshot]) { self.values = values }
    func holdRead(_ gate: TaskPanelGate) { readGate = gate }
    func holdCancel(_ gate: TaskPanelGate) { cancelGate = gate }
    var transport: DelegatedTasksTransport {
        .init(inspect: { try await self.inspect(parent: $0, task: $1) }, cancel: { try await self.cancel(parent: $0, task: $1, command: $2) })
    }
    private func inspect(parent: UUID, task: UUID) async throws -> DelegatedTaskStatusSnapshot {
        reads.append(task)
        let value = try #require(values[task]); #expect(value.task.parentThreadID == parent)
        if let gate = readGate { readGate = nil; await gate.wait() }
        return value
    }
    private func cancel(parent: UUID, task: UUID, command: UUID) async throws -> WorkspaceCommandReceipt {
        #expect(values[task]?.task.parentThreadID == parent)
        cancels.append(command)
        if let gate = cancelGate { await gate.wait() }
        cancellationWasCancelled = Task.isCancelled
        return .init(commandID: command, sequence: 1, eventCount: 1, acceptedAt: Date(), rejection: nil)
    }
}
@MainActor private struct TaskPanelFixture {
    let model = DelegatedTasksStore()
    var snapshot: WorkspaceSnapshot
    let parent: CodingThread, child: CodingThread, other: CodingThread
    let original: DelegatedTask, followup: DelegatedTask, foreign: DelegatedTask
    let peer: TaskPanelPeer
    init() {
        let project = WorkspaceProject(path: "/private/offline/task-panel")
        parent = CodingThread(project: project); other = CodingThread(project: project)
        var child = CodingThread(project: project)
        let taskID = UUID(), runID = UUID(), parentRun = UUID()
        child.delegatedTaskLineage = .init(taskID: taskID, parentThreadID: parent.id, parentRunID: parentRun, rootThreadID: parent.id)
        child.runtimeRequests = [
            .init(request: .init(id: .number(1), method: "item/commandExecution/requestApproval", params: .object([:]))),
            .init(request: .init(id: .number(2), method: "item/tool/requestUserInput", params: .object(["questions": .array([])])))
        ]
        self.child = child
        func task(id: UUID, owner: CodingThread, destination: CodingThread, run: UUID, summary: String, isFollowup: Bool) -> DelegatedTask {
            .init(id: id, commandID: UUID(), parentThreadID: owner.id, parentRunID: parentRun, childThreadID: destination.id,
                childRunID: run, parentTaskID: nil, request: .init(parentThreadID: owner.id, parentRunID: parentRun,
                    expectedConfiguration: .init(thread: owner), configuration: .init(thread: destination), task: "Bounded offline task", title: "Task 工作", role: .review),
                createdAt: Date(timeIntervalSince1970: isFollowup ? 2 : 1), updatedAt: Date(timeIntervalSince1970: isFollowup ? 2 : 1),
                status: .completed, workState: .resultAvailable,
                result: .init(runID: run, status: .completed, summary: summary, digest: String(repeating: "a", count: 64), contextTransferID: UUID(), createdAt: Date()),
                latestTerminalResult: nil, wakePolicy: .always, completion: .init(state: .pending), cancelRequestedAt: nil, completedAt: Date(), isFollowup: isFollowup)
        }
        original = task(id: taskID, owner: parent, destination: child, run: runID, summary: "Original result e\u{301} stays exact", isFollowup: false)
        followup = task(id: UUID(), owner: parent, destination: child, run: UUID(), summary: "Latest child follow-up", isFollowup: true)
        let foreignChild = CodingThread(project: project)
        foreign = task(id: UUID(), owner: other, destination: foreignChild, run: UUID(), summary: "Other parent's result", isFollowup: false)
        var snapshot = WorkspaceSnapshot(); snapshot.projects = [project]; snapshot.threads = [parent, child, other, foreignChild]
        snapshot.delegatedTasks = [original, followup, foreign]; self.snapshot = snapshot
        peer = .init([original.id: .init(task: original, hasPendingChildRuns: true, pendingQuestions: [], pendingApproval: nil),
                      foreign.id: .init(task: foreign, hasPendingChildRuns: false, pendingQuestions: [], pendingApproval: nil)])
    }
    func bind(_ id: UUID? = nil, open: @escaping @MainActor (UUID) -> Void = { _ in }) async {
        model.update(conversationID: id ?? parent.id, snapshot: snapshot, transport: await peer.transport, open: open)
    }
}

@MainActor @Test(.timeLimit(.minutes(1)))
func delegatedTaskPanelInspectionKeepsAgentNotificationPendingAndShowsOriginalAndLatestFollowupWithoutAnswering() async throws {
    let f = TaskPanelFixture(); await f.bind()
    #expect(f.model.tasks.map(\.id) == [f.original.id])
    await f.model.inspect(f.original.id)?.value
    #expect(f.model.selectedTask?.result == f.original.result && f.model.latestChildResult == f.followup.result)
    #expect(f.model.pendingQuestionCount == 1 && f.model.pendingApprovalCount == 1)
    #expect(f.model.snapshot.delegatedTasks?.first?.completion.state == .pending)
    #expect(await f.peer.cancels.isEmpty)
    #expect(f.model.parentConversationID == nil)
    await f.bind(f.child.id); #expect(f.model.parentConversationID == f.parent.id)
    await f.model.shutdown()
}

@MainActor @Test(.timeLimit(.minutes(1)))
func delegatedTaskPanelRejectsLateInspectionAfterParentSelectionChangesAndDrainsOwnedReads() async throws {
    let f = TaskPanelFixture(), gate = TaskPanelGate(); await f.bind(); await f.peer.holdRead(gate)
    let old = try #require(f.model.inspect(f.original.id)); await gate.started()
    await f.bind(f.other.id)
    await f.model.inspect(f.foreign.id)?.value
    await gate.release(); await old.value
    #expect(f.model.selectedTaskID == f.foreign.id && f.model.detail?.task.id == f.foreign.id)
    await f.model.shutdown()
    #expect(f.model.inspect(f.foreign.id) == nil)
}

@MainActor @Test(.timeLimit(.minutes(1)))
func delegatedTaskPanelCloseJoinsTheOriginalExplicitCancelWithoutWithdrawingOrRepeatingIt() async throws {
    let f = TaskPanelFixture(), gate = TaskPanelGate(); await f.bind(); await f.model.inspect(f.original.id)?.value
    await f.peer.holdCancel(gate)
    let command = try #require(f.model.cancelSelected()); await gate.started()
    #expect(f.model.cancelSelected() == nil)
    f.model.stop(); let closing = Task { await f.model.shutdown() }
    await gate.release(); await command.value; await closing.value
    let ids = await f.peer.cancels, wasCancelled = await f.peer.cancellationWasCancelled
    #expect(ids.count == 1 && !wasCancelled && !f.model.canCancelSelected)
    #expect(f.model.notice == nil && f.model.errorMessage == nil)
}

@MainActor @Test
func delegatedTaskPanelOffscreenLightAndDarkContentDoesNotInspectAcknowledgeOrCancel() async throws {
    let f = TaskPanelFixture(); await f.bind()
    for scheme in [ColorScheme.light, .dark] {
        let view = NSHostingView(rootView: DelegatedTasksPanelContent(model: f.model, close: {}).environment(\.colorScheme, scheme))
        view.frame = .init(x: 0, y: 0, width: 720, height: 460); view.layoutSubtreeIfNeeded()
        #expect(view.fittingSize.width.isFinite && view.fittingSize.height.isFinite)
    }
    let reads = await f.peer.reads, cancels = await f.peer.cancels
    #expect(reads.isEmpty && cancels.isEmpty && f.model.snapshot.delegatedTasks?.first?.completion.state == .pending)
    await f.model.shutdown()
}
