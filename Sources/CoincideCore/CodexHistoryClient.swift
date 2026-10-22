import Foundation

/// Current app-server history contract. No method discovery RPC is advertised by
/// initialize, so mutation additionally requires a reviewed server profile.
struct CodexHistoryClient: Sendable {
    let rpc: JSONRPCConnection
    let userAgent: String?
    private static let pageLimit = 100
    private static let maximumPages = 100
    private static let maximumResponseBytes = 4_194_304

    struct Metadata: Sendable, Equatable {
        let reference: ProviderConversationReference
        let workspacePath: String
        let mode: ProviderHistoryMode
        let status: String
    }

    var hasReviewedProfile: Bool {
        guard let userAgent, userAgent.utf8.count <= 4_096 else { return false }
        // The server prefixes its version with initialize.clientInfo.name.
        // An isolated 0.163 handshake returned coincide/0.163.0 here.
        return userAgent.range(of: #"^(?:coincide|codex_cli_rs|codex)/0\.163\.[0-9]+(?:\s|$|[-+])"#, options: .regularExpression) != nil
    }
    func capabilities(threadID: String) async throws -> ProviderHistoryCapabilities {
        let reference = try ProviderConversationReference(provider: .codex, nativeThreadID: threadID)
        guard hasReviewedProfile else { return .init(reference: reference, unavailableReason: ProviderHistoryError(.unsupported).localizedDescription) }
        let deadline = ContinuousClock.now + .seconds(30)
        let meta = try await metadata(threadID: threadID, deadline: deadline)
        guard meta.mode == .paginated else {
            return .init(reference: reference, historyMode: meta.mode, unavailableReason: ProviderHistoryError(.unsupported).localizedDescription)
        }
        var canRevert = false, reason: String?
        if meta.status == "idle" {
            do { try await requireSafeGoal(threadID: threadID, deadline: deadline); canRevert = true }
            catch is CancellationError { throw CancellationError() }
            catch { reason = (error as? ProviderHistoryError)?.localizedDescription ?? ProviderHistoryError(.unsupported).localizedDescription }
        } else { reason = ProviderHistoryError(.notIdle).localizedDescription }
        return .init(reference: reference, historyMode: meta.mode, canRead: true,
            canForkHead: meta.status != "active", canForkFromTurn: true, canRevertBeforeTurn: canRevert, unavailableReason: reason)
    }
    func page(threadID: String, cursor: String?, limit: Int) async throws -> ProviderHistoryPage {
        try requireProfile(); try ProviderHistoryValidation.id(threadID)
        guard (1...Self.pageLimit).contains(limit) else { throw ProviderHistoryError(.invalidRequest) }
        if let cursor { try ProviderHistoryValidation.cursor(cursor) }
        let deadline = ContinuousClock.now + .seconds(30)
        let meta = try await metadata(threadID: threadID, deadline: deadline)
        guard meta.mode == .paginated else { throw ProviderHistoryError(.unsupported) }
        return try await page(threadID: threadID, cursor: cursor, limit: limit, deadline: deadline)
    }
    func snapshot(threadID: String) async throws -> ProviderConversationSnapshot {
        try requireProfile(); try ProviderHistoryValidation.id(threadID)
        let deadline = ContinuousClock.now + .seconds(30)
        let initial = try await metadata(threadID: threadID, deadline: deadline)
        guard initial.mode == .paginated else { throw ProviderHistoryError(.unsupported) }
        let observedHead = try await head(threadID: threadID, deadline: deadline)
        guard try await metadata(threadID: threadID, deadline: deadline) == initial else { throw ProviderHistoryError(.historyChanged) }
        return try .init(reference: initial.reference, workspacePath: initial.workspacePath, historyMode: initial.mode, headTurnID: observedHead?.id)
    }
    func fork(source: ProviderConversationReference, boundary: ProviderHistoryBoundary,
              configuration: ProviderConfiguration) async throws -> ProviderConversationSnapshot {
        try requireProfile(); try source.validate(); try boundary.validate()
        guard source.provider == .codex, configuration.provider == .codex else { throw ProviderHistoryError(.unsupported) }
        try ProviderHistoryValidation.path(configuration.workspacePath)
        let deadline = ContinuousClock.now + .seconds(30)
        let sourceMetadata = try await metadata(threadID: source.nativeThreadID, deadline: deadline)
        guard sourceMetadata.mode == .paginated else { throw ProviderHistoryError(.unsupported) }
        let expectedHead: String?
        switch boundary {
        case .head:
            let sourceHead = try await head(threadID: source.nativeThreadID, deadline: deadline)
            guard sourceMetadata.status != "active", sourceHead == nil || sourceHead?.status.isTerminal == true else { throw ProviderHistoryError(.boundaryUnavailable) }
            expectedHead = sourceHead?.id
        case .throughTurn(let id):
            let turns = try await history(threadID: source.nativeThreadID, through: id, includePrevious: false, deadline: deadline)
            guard let turn = turns.first(where: { $0.id == id }), turn.status.isTerminal else { throw ProviderHistoryError(.boundaryUnavailable) }
            expectedHead = id
        case .beforeTurn(let id):
            let turns = try await history(threadID: source.nativeThreadID, through: id, includePrevious: true, deadline: deadline)
            guard let i = turns.firstIndex(where: { $0.id == id }), turns[i].status.isTerminal else { throw ProviderHistoryError(.boundaryUnavailable) }
            let previous = turns.indices.contains(i + 1) ? turns[i + 1] : nil
            guard previous == nil || previous?.status.isTerminal == true else { throw ProviderHistoryError(.boundaryUnavailable) }
            expectedHead = previous?.id
        case .beforeMessage, .throughMessage, .throughClaudeMessage, .freshClaudeSession: throw ProviderHistoryError(.unsupported)
        }
        var params: [String: JSONValue] = ["threadId": .string(source.nativeThreadID), "cwd": .string(configuration.workspacePath),
            "approvalPolicy": configuration.permission.approvalPolicy, "approvalsReviewer": configuration.permission.reviewer,
            "sandbox": .string(configuration.permission == .fullAccess ? "danger-full-access" : configuration.permission == .supervised ? "read-only" : "workspace-write"),
            "excludeTurns": .bool(true), "ephemeral": .bool(false), "deferGoalContinuation": .bool(true)]
        if !configuration.model.isEmpty { params["model"] = .string(configuration.model) }
        if let effort = configuration.reasoningEffort { params["config"] = .object(["model_reasoning_effort": .string(effort)]) }
        switch boundary { case .head: break; case .throughTurn(let id): params["lastTurnId"] = .string(id); case .beforeTurn(let id): params["beforeTurnId"] = .string(id)
        case .beforeMessage, .throughMessage, .throughClaudeMessage, .freshClaudeSession: throw ProviderHistoryError(.unsupported) }
        try Task.checkCancellation()
        let response = try await request("thread/fork", params: .object(params), deadline: deadline, mutation: true)
        do {
            let forked = try decodeMetadata(response["thread"])
            guard forked.reference != source, response["thread"]["forkedFromId"].string == source.nativeThreadID,
                  equivalentPath(forked.workspacePath, configuration.workspacePath), forked.mode == .paginated,
                  forked.status == "idle" else { throw ProviderHistoryError(.invalidResponse) }
            let head = try await head(threadID: forked.reference.nativeThreadID, deadline: deadline)
            guard head?.id == expectedHead, head == nil || head?.status.isTerminal == true else { throw ProviderHistoryError(.historyChanged) }
            return try .init(reference: forked.reference, workspacePath: forked.workspacePath, historyMode: forked.mode, headTurnID: head?.id)
        } catch is CancellationError { throw CancellationError() }
        catch { throw ProviderHistoryError(.outcomeUncertain) }
    }
    func revert(thread: ProviderConversationReference, beforeTurnID: String, expectedHeadTurnID: String) async throws -> ProviderConversationSnapshot {
        try requireProfile(); try thread.validate(); try ProviderHistoryValidation.id(beforeTurnID); try ProviderHistoryValidation.id(expectedHeadTurnID)
        guard thread.provider == .codex else { throw ProviderHistoryError(.unsupported) }
        let deadline = ContinuousClock.now + .seconds(30)
        let initial = try await metadata(threadID: thread.nativeThreadID, deadline: deadline)
        guard initial.mode == .paginated else { throw ProviderHistoryError(.unsupported) }
        guard initial.status == "idle" else { throw ProviderHistoryError(.notIdle) }
        let turns = try await history(threadID: thread.nativeThreadID, through: beforeTurnID, includePrevious: true, deadline: deadline)
        guard turns.first?.id == expectedHeadTurnID else { throw ProviderHistoryError(.historyChanged) }
        guard turns.allSatisfy({ $0.status.isTerminal }), let i = turns.firstIndex(where: { $0.id == beforeTurnID }) else { throw ProviderHistoryError(.boundaryUnavailable) }
        let expectedHead = turns.indices.contains(i + 1) ? turns[i + 1].id : nil
        try await requireSafeGoal(threadID: thread.nativeThreadID, deadline: deadline)
        let latest = try await metadata(threadID: thread.nativeThreadID, deadline: deadline)
        // Codex has no compare-and-swap history RPC. This final exact-head read
        // detects observed changes; another client can still race the following RPC.
        guard latest == initial, try await head(threadID: thread.nativeThreadID, deadline: deadline)?.id == expectedHeadTurnID else { throw ProviderHistoryError(.historyChanged) }
        try Task.checkCancellation()
        let response = try await request("thread/revert", params: .object(["threadId": .string(thread.nativeThreadID), "beforeTurnId": .string(beforeTurnID)]), deadline: deadline, mutation: true)
        do {
            let updated = try decodeMetadata(response["thread"])
            guard updated.reference == thread, updated.mode == .paginated, updated.status == "idle",
                  equivalentPath(updated.workspacePath, initial.workspacePath) else { throw ProviderHistoryError(.invalidResponse) }
            let actualHead = try await head(threadID: thread.nativeThreadID, deadline: deadline)
            guard actualHead?.id == expectedHead, actualHead == nil || actualHead?.status.isTerminal == true else { throw ProviderHistoryError(.historyChanged) }
            return try .init(reference: thread, workspacePath: updated.workspacePath, historyMode: updated.mode, headTurnID: actualHead?.id)
        } catch is CancellationError { throw CancellationError() }
        catch { throw ProviderHistoryError(.outcomeUncertain) }
    }

    private func requireProfile() throws { guard hasReviewedProfile else { throw ProviderHistoryError(.unsupported) } }
    private func metadata(threadID: String, deadline: ContinuousClock.Instant) async throws -> Metadata {
        let response = try await request("thread/read", params: .object(["threadId": .string(threadID), "includeTurns": .bool(false)]), deadline: deadline)
        let result = try decodeMetadata(response["thread"])
        guard result.reference.nativeThreadID == threadID else { throw ProviderHistoryError(.invalidResponse) }; return result
    }
    private func decodeMetadata(_ thread: JSONValue) throws -> Metadata {
        guard let id = thread["id"].string, let cwd = thread["cwd"].string,
              let status = thread["status"]["type"].string,
              ["idle", "active", "notLoaded", "systemError"].contains(status) else { throw ProviderHistoryError(.invalidResponse) }
        let reference = try ProviderConversationReference(provider: .codex, nativeThreadID: id)
        try ProviderHistoryValidation.path(cwd)
        // Match the app's captured path spelling at the native ingress boundary.
        // Persisted snapshots remain pure values; reopening them does not resolve
        // filesystem paths again. Codex getcwd may report /private/var aliases.
        let workspacePath = URL(fileURLWithPath: cwd).standardizedFileURL.resolvingSymlinksInPath().path
        return .init(reference: reference, workspacePath: workspacePath,
            mode: ProviderHistoryMode(rawValue: thread["historyMode"].string ?? "") ?? .unknown, status: status)
    }
    private func page(threadID: String, cursor: String?, limit: Int, deadline: ContinuousClock.Instant) async throws -> ProviderHistoryPage {
        var params: [String: JSONValue] = ["threadId": .string(threadID), "limit": .number(Double(limit)), "sortDirection": .string("desc"), "itemsView": .string("summary")]
        if let cursor { params["cursor"] = .string(cursor) }
        let response = try await request("thread/turns/list", params: .object(params), deadline: deadline)
        guard let data = response["data"].array, data.count <= limit,
              let rawCursor = response.object?["nextCursor"] else { throw ProviderHistoryError(.invalidResponse) }
        let next: String?
        if rawCursor == .null { next = nil } else if let value = rawCursor.string { next = value } else { throw ProviderHistoryError(.invalidResponse) }
        let turns = try data.map { value -> ProviderHistoryTurn in
            guard let id = value["id"].string, let status = value["status"].string else { throw ProviderHistoryError(.invalidResponse) }
            return try .init(id: id, status: status == "inProgress" ? .running : ProviderHistoryTurnStatus(rawValue: status) ?? .unknown)
        }
        guard !turns.isEmpty || next == nil else { throw ProviderHistoryError(.invalidResponse) }
        return try .init(reference: .init(provider: .codex, nativeThreadID: threadID), turns: turns, nextCursor: next)
    }
    private func history(threadID: String, through target: String, includePrevious: Bool, deadline: ContinuousClock.Instant) async throws -> [ProviderHistoryTurn] {
        var turns = [ProviderHistoryTurn](), ids = Set<String>(), cursors = Set<String>(), cursor: String?
        var found = false
        for _ in 0..<Self.maximumPages {
            try Task.checkCancellation()
            let result = try await page(threadID: threadID, cursor: cursor, limit: Self.pageLimit, deadline: deadline)
            for turn in result.turns {
                guard ids.insert(turn.id).inserted else { throw ProviderHistoryError(.invalidResponse) }; turns.append(turn)
                if found { return turns }
                if turn.id == target { if !includePrevious { return turns }; found = true }
            }
            guard let next = result.nextCursor else { return turns }
            guard cursors.insert(next).inserted else { throw ProviderHistoryError(.invalidResponse) }; cursor = next
        }
        throw ProviderHistoryError(.limitExceeded)
    }
    private func head(threadID: String, deadline: ContinuousClock.Instant) async throws -> ProviderHistoryTurn? {
        try await page(threadID: threadID, cursor: nil, limit: 1, deadline: deadline).turns.first
    }
    private func requireSafeGoal(threadID: String, deadline: ContinuousClock.Instant) async throws {
        let response = try await request("thread/goal/get", params: .object(["threadId": .string(threadID)]), deadline: deadline)
        guard let goal = response.object?["goal"] else { throw ProviderHistoryError(.unsafeGoal) }
        if goal == .null { return }
        guard goal["threadId"].string == threadID, let status = goal["status"].string,
              ["paused", "complete"].contains(status), goal["objective"].string != nil else { throw ProviderHistoryError(.unsafeGoal) }
        for field in ["tokensUsed", "timeUsedSeconds", "createdAt", "updatedAt"] {
            guard case .number(let value) = goal[field], value.isFinite, value >= 0 else { throw ProviderHistoryError(.unsafeGoal) }
        }
        guard let budget = goal.object?["tokenBudget"] else { throw ProviderHistoryError(.unsafeGoal) }
        if budget != .null { guard case .number(let value) = budget, value.isFinite, value >= 0 else { throw ProviderHistoryError(.unsafeGoal) } }
    }
    private func request(_ method: String, params: JSONValue, deadline: ContinuousClock.Instant, mutation: Bool = false) async throws -> JSONValue {
        try Task.checkCancellation()
        let remaining = ContinuousClock.now.duration(to: deadline)
        guard remaining > .zero else { throw ProviderHistoryError(.limitExceeded) }
        do {
            let response = try await rpc.request(method, params: params, timeout: min(remaining, .seconds(10)))
            try Task.checkCancellation()
            guard try JSONEncoder().encode(response).count <= Self.maximumResponseBytes else { throw ProviderHistoryError(.limitExceeded) }
            return response
        } catch is CancellationError { throw CancellationError() }
        catch let error as JSONRPCRemoteError where error.code == -32601 || error.code == -32602 { throw ProviderHistoryError(.unsupported) }
        catch let error as ProviderHistoryError { throw mutation ? ProviderHistoryError(.outcomeUncertain) : error }
        catch { throw ProviderHistoryError(mutation ? .outcomeUncertain : .invalidResponse) }
    }
    private func equivalentPath(_ a: String, _ b: String) -> Bool {
        URL(fileURLWithPath: a).standardizedFileURL.resolvingSymlinksInPath().path == URL(fileURLWithPath: b).standardizedFileURL.resolvingSymlinksInPath().path
    }
}
