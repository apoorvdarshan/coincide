import Foundation

/// Owns only protocol boundary facts. Private summary text never enters this
/// state, ProviderEvent, or Coincide's durable conversation transcript.
actor NativeContextCompactionLatch {
    let provider: ProviderKind
    let nativeThreadID: String
    let operationID: UUID
    private let excludedTurns: Set<String>
    private var nativeTurnID: String?
    private var boundaryCompleted = false
    private var terminalCompleted = false
    private var nativeTurnFinished = false
    private var interruptClaimed = false
    private var acknowledged = false
    private var outcome: Result<ProviderContextCompactionReceipt, ProviderContextCompactionError>?
    private var waiter: CheckedContinuation<ProviderContextCompactionReceipt, any Error>?
    private var deadline: Task<Void, Never>?

    init(provider: ProviderKind, nativeThreadID: String, operationID: UUID, excludedTurns: Set<String> = []) {
        self.provider = provider; self.nativeThreadID = nativeThreadID
        self.operationID = operationID; self.excludedTurns = excludedTurns
    }

    func acknowledge() { acknowledged = true; completeIfConfirmed() }
    func turnID() -> String? { nativeTurnID }
    /// A single exact observed native turn may be interrupted during cleanup.
    /// No start ACK, guessed ID, completed turn, or successor grants authority.
    func claimInterruptTarget() -> String? {
        guard provider == .codex, !nativeTurnFinished, !interruptClaimed,
              let nativeTurnID else { return nil }
        interruptClaimed = true
        return nativeTurnID
    }
    func fail(_ kind: ProviderContextCompactionError.Kind = .unconfirmed) {
        finish(.failure(.init(kind)))
    }

    func consume(method: String, params: JSONValue) {
        guard outcome == nil else { return }
        if provider == .codex { consumeCodex(method: method, params: params) }
        else if provider == .claude { consumeClaude(method: method, frame: params) }
    }

    func wait(timeout: Duration = .seconds(180)) async throws -> ProviderContextCompactionReceipt {
        try await withTaskCancellationHandler {
            if Task.isCancelled { fail() }
            if let outcome { return try outcome.get() }
            return try await withCheckedThrowingContinuation { continuation in
                guard waiter == nil else { continuation.resume(throwing: ProviderContextCompactionError(.notIdle)); return }
                waiter = continuation
                deadline = Task { [weak self] in
                    do { try await Task.sleep(for: timeout) } catch { return }
                    await self?.fail()
                }
            }
        } onCancel: { Task { await self.fail() } }
    }

    private func consumeCodex(method: String, params: JSONValue) {
        guard params["threadId"].string == nativeThreadID else { return }
        if method == "error", params["willRetry"] != .bool(true) { fail(.failed); return }
        let isTurn = method == "turn/started" || method == "turn/completed"
        let isBoundary = (method == "item/started" || method == "item/completed") &&
            params["item"]["type"] == .string("contextCompaction") &&
            params["item"]["id"].string?.isEmpty == false
        guard isTurn || isBoundary,
              let id = (isTurn ? params["turn"]["id"] : params["turnId"]).string,
              !id.isEmpty, id.utf8.count <= 4_096, !excludedTurns.contains(id) else { return }
        if let nativeTurnID, nativeTurnID != id { fail(); return }
        nativeTurnID = id
        if isBoundary, method == "item/completed" { boundaryCompleted = true }
        if method == "turn/completed" {
            nativeTurnFinished = true
            guard params["turn"]["status"] == .string("completed") else { fail(.failed); return }
            // Turn completion is the terminal boundary; a missing compaction
            // item cannot be repaired by guessing or waiting for another turn.
            guard boundaryCompleted else { fail(); return }
            terminalCompleted = true
        }
        completeIfConfirmed()
    }

    private func consumeClaude(method: String, frame: JSONValue) {
        guard frame["parent_tool_use_id"] == .null,
              frame["session_id"].string == nativeThreadID,
              frame["replayed"] != .bool(true), frame["isReplay"] != .bool(true) else { return }
        let stamps: [String]
        if let inputs = frame["user_message_uuids"].array {
            guard inputs.count <= 64, inputs.allSatisfy({ $0.string != nil }) else { return }
            stamps = inputs.compactMap(\.string)
        } else { stamps = frame["user_message_uuid"].string.map { [$0] } ?? [] }
        guard stamps.isEmpty || stamps.contains(operationID.uuidString) else { return }
        if method == "system", frame["subtype"] == .string("compact_boundary"),
           frame["compact_metadata"]["trigger"] == .string("manual") { boundaryCompleted = true }
        if method == "result" {
            guard frame["is_error"] == .bool(false),
                  frame["subtype"] == .null || frame["subtype"] == .string("success") else { fail(.failed); return }
            guard boundaryCompleted else { fail(); return }
            terminalCompleted = true
        }
        completeIfConfirmed()
    }

    private func completeIfConfirmed() {
        guard acknowledged, boundaryCompleted, terminalCompleted else { return }
        finish(.success(.init(provider: provider, nativeThreadID: nativeThreadID)))
    }
    private func finish(_ result: Result<ProviderContextCompactionReceipt, ProviderContextCompactionError>) {
        guard outcome == nil else { return }
        outcome = result; deadline?.cancel(); deadline = nil
        let continuation = waiter; waiter = nil; continuation?.resume(with: result.mapError { $0 as any Error })
    }
}
