import AppKit
import Foundation
import SwiftUI
import Testing
@testable import Coincide
@testable import CoincideCore

private struct RemoteTranscriptFixture {
    let binding: RemoteProjectionBinding
    let summary: RemoteMessageSummary
    let presentation: RemoteTranscriptMessagePresentation
    let documents: [UUID: Data]
    static func make(id: String = "tool", role: MessageRole = .tool, owner: UUID? = nil,
                     reference: TranscriptRunReference? = nil, source: String = "$ echo exact\noutput",
                     entity: ProviderEntity? = nil, provider: ProviderKind = .codex,
                     terminal: Bool = false, canPair: Bool = false) throws -> Self {
        let threadID = UUID(), binding = RemoteProjectionBinding(environmentID: UUID(), hostID: UUID(), viewID: UUID(),
            sequence: 1, fingerprint: String(repeating: "a", count: 64), scope: .thread(threadID))
        return try make(binding: binding, id: id, role: role, owner: owner ?? threadID, reference: reference,
                        source: source, entity: entity, provider: provider, terminal: terminal, canPair: canPair)
    }
    static func make(binding: RemoteProjectionBinding, id: String, role: MessageRole, owner: UUID,
                     reference: TranscriptRunReference?, source: String, entity: ProviderEntity? = nil,
                     provider: ProviderKind = .codex, terminal: Bool = false, canPair: Bool = false) throws -> Self {
        var documents: [UUID: Data] = [:]
        let raw = Data(source.utf8)
        let sourceText: RemoteProjectionText
        if raw.count > 1024 {
            let sourceRef = RemoteProjectionContentReference(id: UUID(), kind: .text, totalBytes: raw.count, digest: RemoteProjectionProtocol.digest(raw))
            documents[sourceRef.id] = raw; sourceText = .init(preview: "Exact source available", complete: false, content: sourceRef)
        } else { sourceText = .init(preview: source, complete: true) }
        let created = Date(timeIntervalSince1970: 1_800_000_000)
        let value = RemoteTranscriptMessagePresentation(projectID: UUID(), threadID: owner, threadCreatedAt: created.addingTimeInterval(-60),
            workspacePath: "/remote/only", messageID: id, role: role, createdAt: created, sourceText: sourceText,
            providerEntity: entity, runReference: reference, provider: provider, runStatus: reference == nil ? nil : .completed,
            terminalResponse: terminal, canPairClaudeResult: canPair)
        let data = try RemoteProjectionProtocol.payload(value)
        let ref = RemoteProjectionContentReference(id: UUID(), kind: .transcriptPresentation, totalBytes: data.count, digest: RemoteProjectionProtocol.digest(data))
        documents[ref.id] = data
        let message = RemoteMessageSummary(id: id, role: role, createdAt: created, text: .init(preview: "Rendered preview", complete: true),
            attachmentCount: 0, runReference: reference, presentation: ref)
        return .init(binding: binding, summary: message, presentation: value, documents: documents)
    }
}

@MainActor private func remoteTranscriptWait(_ predicate: () -> Bool) async throws {
    let deadline = ContinuousClock.now + .seconds(5)
    while !predicate() {
        guard ContinuousClock.now < deadline else { throw CoincideError("The private remote transcript read did not settle.") }
        try await Task.sleep(for: .milliseconds(5))
    }
}

private actor RemoteTranscriptReadGate {
    private var entered = false, released = false
    private var arrival: [CheckedContinuation<Void, Never>] = []
    private var continuation: CheckedContinuation<Void, Never>?
    func wait() async {
        entered = true; arrival.forEach { $0.resume() }; arrival.removeAll()
        if !released { await withCheckedContinuation { continuation = $0 } }
    }
    func untilEntered() async { if !entered { await withCheckedContinuation { arrival.append($0) } } }
    func release() { released = true; continuation?.resume(); continuation = nil }
}

@MainActor @Test(.timeLimit(.minutes(1)))
func remoteTranscriptHydratesExactSourceSeparatelyFromPreviewAndAcceptsInheritedRunProvenance() async throws {
    let original = String(repeating: "authored e\u{301} 🌍\n", count: 200)
    let inherited = TranscriptRunReference(threadID: UUID(), runID: UUID())
    let f = try RemoteTranscriptFixture.make(role: .assistant, reference: inherited, source: original, terminal: true)
    let state = RemoteTranscriptState(); var reads = 0
    state.select(f.binding)
    state.request(f.summary, binding: f.binding) { ref, binding in
        #expect(binding == f.binding); reads += 1
        return try #require(f.documents[ref.id])
    }
    try await remoteTranscriptWait { state.entry(f.summary, f.binding) != nil }
    let value = try #require(state.entry(f.summary, f.binding))
    #expect(value.sourceText?.utf8.elementsEqual(original.utf8) == true)
    #expect(value.message.text.utf8.elementsEqual(original.utf8))
    #expect(value.presentation.runReference == inherited && value.presentation.terminalResponse)
    #expect(reads == 2 && f.summary.text.preview != value.sourceText)
    await state.shutdown()
}

@MainActor @Test(.timeLimit(.minutes(1)), arguments: ["foreign-owner", "wrong-digest"])
func remoteTranscriptRefusesForeignPresentationAndUnverifiedSource(mode: String) async throws {
    let f = try RemoteTranscriptFixture.make(owner: mode == "foreign-owner" ? UUID() : nil)
    let state = RemoteTranscriptState(); state.select(f.binding)
    state.request(f.summary, binding: f.binding) { ref, _ in
        let bytes = try #require(f.documents[ref.id])
        return mode == "wrong-digest" ? bytes + Data([0]) : bytes
    }
    try await remoteTranscriptWait { !state.loading.contains(.init(f.summary, f.binding)) }
    #expect(state.entry(f.summary, f.binding) == nil && state.errors[.init(f.summary, f.binding)] != nil)
    await state.shutdown()
}

@MainActor @Test(.timeLimit(.minutes(1)))
func remoteTranscriptReplacementAndShutdownFenceAndDrainLateReadWithoutPublishingForeignRows() async throws {
    let first = try RemoteTranscriptFixture.make(), next = try RemoteTranscriptFixture.make()
    let gate = RemoteTranscriptReadGate(), state = RemoteTranscriptState()
    state.select(first.binding)
    state.request(first.summary, binding: first.binding) { ref, _ in await gate.wait(); return try #require(first.documents[ref.id]) }
    await gate.untilEntered()
    let originalDrain = state.stopAndDrain()
    state.select(next.binding)
    state.request(next.summary, binding: next.binding) { ref, _ in try #require(next.documents[ref.id]) }
    try await remoteTranscriptWait { state.entry(next.summary, next.binding) != nil }
    #expect(state.entry(first.summary, first.binding) == nil)
    await gate.release(); await originalDrain.value
    #expect(state.binding == next.binding && state.entry(next.summary, next.binding) != nil,
            "Joining the original drain never cancels a replacement owner.")
    let held = RemoteTranscriptReadGate(), third = try RemoteTranscriptFixture.make()
    state.select(third.binding)
    state.request(third.summary, binding: third.binding) { ref, _ in await held.wait(); return try #require(third.documents[ref.id]) }
    await held.untilEntered()
    var closed = false
    let shutdown = Task { await state.shutdown(); closed = true }
    try await remoteTranscriptWait { state.binding == nil }
    #expect(!closed, "Shutdown stays joined to its retired cancellation-resistant reader.")
    await held.release(); await shutdown.value
    #expect(closed && state.entries.isEmpty)
}

@MainActor @Test
func remoteTranscriptHostPresentationPreservesOriginalProviderAndSourceOnlyPairPermission() throws {
    let project = WorkspaceProject(path: "/remote/original")
    var original = CodingThread(project: project); original.provider = .claude; original.checkpointPolicy = .disabled
    let runID = UUID(), reference = TranscriptRunReference(threadID: original.id, runID: runID)
    func message(_ id: String, _ role: MessageRole, _ text: String) -> ChatMessage {
        var value = ChatMessage(id: id, role: role, text: text); value.runReference = reference; return value
    }
    let opening = message("opening", .user, "Original prompt"), call = message("call", .tool, "Read\n{\"file_path\":\"safe.swift\"}"),
        result = message("result-call", .tool, "Original read result"), intermediate = message("middle", .assistant, "Intermediate response"),
        terminal = message("terminal", .assistant, "Final response")
    original.messages = [opening, intermediate, call, result, terminal]
    var record = ThreadRunRecord(run: .init(id: runID, configuration: .init(thread: original), startedAt: .now), origin: .user, userMessageID: opening.id)
    record.status = .completed; record.endedAt = .now; record.messageAttributionVersion = 1
    original.runHistory = [record]
    var fork = CodingThread(project: project); fork.provider = .codex; fork.checkpointPolicy = .disabled
    fork.messages = [call, result]
    var snapshot = WorkspaceSnapshot(); snapshot.projects = [project]; snapshot.threads = [original, fork]
    func projected(_ id: UUID, _ snapshot: WorkspaceSnapshot) throws -> [(RemoteMessageSummary, RemoteTranscriptMessagePresentation)] {
        let source = try RemoteProjectionProjector.build(.init(snapshot: snapshot, sequence: 1, error: nil), scope: .thread(id), reserve: { _ in })
        return try source.messages.map { summary in
            let ref = try #require(summary.presentation), bytes = try #require(source.contents[ref.id])
            #expect(bytes.count == ref.totalBytes && RemoteProjectionProtocol.digest(bytes) == ref.digest)
            let object = try #require(JSONSerialization.jsonObject(with: bytes) as? [String: Any])
            #expect(object["configuration"] == nil && object["codexHistory"] == nil && object["checkpoints"] == nil)
            return (summary, try JSONDecoder().decode(RemoteTranscriptMessagePresentation.self, from: bytes))
        }
    }
    let inherited = try projected(fork.id, snapshot)
    #expect(inherited.allSatisfy { $0.1.provider == .claude && $0.1.canPairClaudeResult && $0.1.runReference == reference })
    #expect(inherited.allSatisfy { !$0.1.opensRun && !$0.1.terminalResponse && !$0.1.runActive })
    let own = try projected(original.id, snapshot)
    #expect(own.first { $0.0.id == "opening" }?.1.opensRun == true)
    #expect(own.first { $0.0.id == "middle" }?.1.terminalResponse == false)
    #expect(own.first { $0.0.id == "terminal" }?.1.terminalResponse == true)
    snapshot.threads = [fork]
    let missing = try projected(fork.id, snapshot)
    #expect(missing.allSatisfy { $0.1.provider == nil && !$0.1.canPairClaudeResult })
}

@MainActor @Test(.timeLimit(.minutes(1)))
func remoteTranscriptClaudePairingRequiresUniqueHostProvenanceAndFailedCardsStayUnfolded() async throws {
    let f = try RemoteTranscriptFixture.make(), state = RemoteTranscriptState()
    guard case .thread(let owner) = f.binding.scope else { return }
    let reference = TranscriptRunReference(threadID: UUID(), runID: UUID())
    let call = try RemoteTranscriptFixture.make(binding: f.binding, id: "native-call", role: .tool, owner: owner, reference: reference,
        source: "Read\n{\"file_path\":\"safe.swift\"}", provider: .claude, canPair: true)
    let result = try RemoteTranscriptFixture.make(binding: f.binding, id: "result-native-call", role: .tool, owner: owner, reference: reference,
        source: "Read result", provider: .claude, canPair: true)
    let unproven = try RemoteTranscriptFixture.make(binding: f.binding, id: "unproven", role: .tool, owner: owner, reference: reference,
        source: "Read\n{}", provider: .claude)
    let unprovenResult = try RemoteTranscriptFixture.make(binding: f.binding, id: "result-unproven", role: .tool, owner: owner, reference: reference,
        source: "Unproven result", provider: .claude)
    let failedEntity = ProviderEntity(key: .init(sessionID: "native", type: "tool_call", id: "failed"),
        fields: .object(["title": .string("Failed command"), "status": .string("failed"), "kind": .string("execute")]))
    let failed = try RemoteTranscriptFixture.make(binding: f.binding, id: "failed", role: .tool, owner: owner,
        reference: reference, source: "Failed command", entity: failedEntity)
    state.select(f.binding)
    for fixture in [call, result, unproven, unprovenResult, failed] {
        state.request(fixture.summary, binding: f.binding) { ref, _ in try #require(fixture.documents[ref.id]) }
    }
    try await remoteTranscriptWait { state.loading.isEmpty }
    #expect(RemoteTranscriptLayout.pairedResult(call.summary, messages: [call.summary, result.summary], binding: f.binding, state: state)?.id == result.summary.id)
    #expect(RemoteTranscriptLayout.pairedResult(call.summary, messages: [call.summary, call.summary, result.summary], binding: f.binding, state: state) == nil)
    #expect(RemoteTranscriptLayout.pairedResult(unproven.summary, messages: [unproven.summary, unprovenResult.summary], binding: f.binding, state: state) == nil)
    #expect(state.card(failed.summary, binding: f.binding)?.isFailure == true)
    let rows = RemoteTranscriptLayout.rows([failed.summary], binding: f.binding, state: state, foldCompleted: true)
    #expect(rows.count == 1)
    if case .message(let value, _) = rows[0] { #expect(value.id == failed.summary.id) }
    else { Issue.record("A failed final tool must remain visible instead of folding into earlier activity.") }
    await state.shutdown()
}

@MainActor @Test(.timeLimit(.minutes(1)))
func remoteTranscriptGroupsOnlyProvenRunsKeepsPlansVisibleAndEvictsBoundedLoadedDocuments() async throws {
    let first = try RemoteTranscriptFixture.make()
    guard case .thread(let threadID) = first.binding.scope else { return }
    let reference = TranscriptRunReference(threadID: threadID, runID: UUID())
    let command = try RemoteTranscriptFixture.make(binding: first.binding, id: "command", role: .tool, owner: threadID,
        reference: reference, source: "$ echo hello\nhello")
    let reasoning = try RemoteTranscriptFixture.make(binding: first.binding, id: "reasoning", role: .reasoning, owner: threadID,
        reference: reference, source: "Public reasoning row")
    let plan = ProviderEntity(key: .init(sessionID: "remote", type: "plan", id: "native-plan"), fields: .object(["content": .string("# Plan\n\nKeep original plan")]))
    let proposed = try RemoteTranscriptFixture.make(binding: first.binding, id: "plan", role: .tool, owner: threadID,
        reference: reference, source: "Original native plan", entity: plan)
    let assistant = try RemoteTranscriptFixture.make(binding: first.binding, id: "terminal", role: .assistant, owner: threadID,
        reference: reference, source: "Final response", terminal: true)
    let values = [command, reasoning, proposed, assistant], state = RemoteTranscriptState()
    state.select(first.binding)
    for fixture in values { state.request(fixture.summary, binding: first.binding) { ref, _ in try #require(fixture.documents[ref.id]) } }
    try await remoteTranscriptWait { state.loading.isEmpty }
    let rows = RemoteTranscriptLayout.rows(values.map(\.summary), binding: first.binding, state: state, foldCompleted: false)
    #expect(rows.count == 3)
    if case .group(_, let items) = rows.first { #expect(items.map(\.id) == ["command", "reasoning"]) }
    else { Issue.record("Consecutive same-run activity should form a work log.") }
    #expect(rows.contains { if case .message(let value, _) = $0 { value.id == "plan" } else { false } })
    let folded = RemoteTranscriptLayout.rows(values.map(\.summary), binding: first.binding, state: state, foldCompleted: true)
    #expect(folded.contains { if case .message(let value, _) = $0 { value.id == "plan" } else { false } })
    let documentBytes = try #require(command.summary.presentation?.totalBytes)
    let bounded = RemoteTranscriptState(maximumBytes: documentBytes + 64)
    bounded.select(first.binding)
    for fixture in [command, reasoning] {
        bounded.request(fixture.summary, binding: first.binding) { ref, _ in try #require(fixture.documents[ref.id]) }
        try await remoteTranscriptWait { bounded.loading.isEmpty }
    }
    #expect(bounded.entry(command.summary, first.binding) == nil && bounded.entry(reasoning.summary, first.binding) != nil)
    await state.shutdown(); await bounded.shutdown()
}

@MainActor @Test(.timeLimit(.minutes(1)))
func remoteTranscriptLegacyFallbackAndReadOnlyCardsRenderWithoutInvokingRemoteActions() async throws {
    _ = NSApplication.shared
    let f = try RemoteTranscriptFixture.make()
    let legacy = RemoteMessageSummary(id: "legacy", role: .assistant, createdAt: f.summary.createdAt,
        text: .init(preview: "Original **remote** text", complete: true), attachmentCount: 0)
    let payload = try RemoteProjectionProtocol.payload(legacy)
    #expect(!String(decoding: payload, as: UTF8.self).contains("presentation"))
    #expect(try JSONDecoder().decode(RemoteMessageSummary.self, from: payload).presentation == nil)
    let state = RemoteTranscriptState(), store = RemoteProjectionStore()
    let view = RemoteProjectedMessageView(message: legacy, binding: f.binding, store: store, source: nil, transcript: state)
    #expect(view.copySource?.utf8.elementsEqual(legacy.text.preview.utf8) == true)
    let incomplete = RemoteMessageSummary(id: "incomplete", role: .assistant, createdAt: legacy.createdAt,
        text: .init(preview: "Only a preview", complete: false, content: .init(id: UUID(), kind: .text, totalBytes: 5000, digest: String(repeating: "b", count: 64))), attachmentCount: 0)
    #expect(RemoteProjectedMessageView(message: incomplete, binding: f.binding, store: store, source: nil, transcript: state).copySource == nil)
    var reads = 0
    state.request(legacy, binding: f.binding) { _, _ in reads += 1; throw CancellationError() }
    #expect(reads == 0)
    for scheme in [ColorScheme.light, .dark] {
        let host = NSHostingController(rootView: RemoteProjectedMessageView(message: legacy, binding: f.binding, store: store,
            source: nil, transcript: state).environment(\.colorScheme, scheme))
        let size = host.sizeThatFits(in: .init(width: 680, height: 1200))
        #expect(size.width > 0 && size.width <= 681 && size.height > 0)
    }
    #expect(reads == 0)
    await state.shutdown()
}

@MainActor @Test(.timeLimit(.minutes(1)))
func remoteTranscriptNativeClaudeResultMetadataRetainsScopedPairingAndObservedFailure() async throws {
    let base = try RemoteTranscriptFixture.make(), run = TranscriptRunReference(threadID: UUID(), runID: UUID())
    let call = try RemoteTranscriptFixture.make(binding: base.binding, id: "owned-call", role: .tool,
        owner: base.presentation.threadID, reference: run, source: "Bash\n{\"command\":\"controlled display\"}", provider: .claude, canPair: true)
    var metadata = ProviderEntity(key: .init(sessionID: "owned-native", type: "claude_tool_result", id: "owned-call"), fields: .object(["is_error": .bool(true)]))
    let result = try RemoteTranscriptFixture.make(binding: base.binding, id: "result-owned-call", role: .tool,
        owner: base.presentation.threadID, reference: run, source: "Exact native failure", entity: metadata, provider: .claude, canPair: true)
    let state = RemoteTranscriptState(); state.select(base.binding)
    for fixture in [call, result] { state.request(fixture.summary, binding: base.binding) { ref, _ in try #require(fixture.documents[ref.id]) } }
    try await remoteTranscriptWait { state.entry(call.summary, base.binding) != nil && state.entry(result.summary, base.binding) != nil }
    let paired = RemoteTranscriptLayout.pairedResult(call.summary, messages: [call.summary, result.summary], binding: base.binding, state: state)
    #expect(paired?.id == result.summary.id && state.card(call.summary, result: paired, binding: base.binding)?.status == .failed)
    #expect(RemoteTranscriptLayout.pairedResult(call.summary, messages: [call.summary, call.summary, result.summary], binding: base.binding, state: state) == nil)
    metadata.fields = .object(["is_error": .bool(false), "parent_tool_use_id": .string("foreign-child")])
    let child = try RemoteTranscriptFixture.make(binding: base.binding, id: "result-owned-call", role: .tool,
        owner: base.presentation.threadID, reference: run, source: "Child output", entity: metadata, provider: .claude, canPair: true)
    #expect(throws: RemoteProjectionFailure.self) { try RemoteTranscriptState.validate(child.presentation, message: child.summary, binding: base.binding) }
    await state.shutdown()
}
