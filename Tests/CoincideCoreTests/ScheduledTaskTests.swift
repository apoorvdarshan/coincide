import CryptoKit
import Darwin
import Foundation
import Testing
@testable import CoincideCore

private final class ScheduledFixtureClock: @unchecked Sendable {
    private let lock = NSLock()
    private var instant: Date
    init(_ date: Date) { instant = date }
    var now: Date { lock.withLock { instant } }
    func advance(_ seconds: TimeInterval) { lock.withLock { instant += seconds } }
    var clock: ScheduledTaskClock { .init(now: { self.now }, sleep: { try await Task.sleep(for: $0) }) }
}
private final class ScheduledProviderLog: @unchecked Sendable {
    private let lock = NSLock()
    private var entries: [(UUID, String)] = []
    func append(_ id: UUID, _ text: String) { lock.withLock { entries.append((id, text)) } }
    var rows: [(UUID, String)] { lock.withLock { entries } }
}
private actor ScheduledOfflineProvider: ProviderSession {
    nonisolated let events: AsyncStream<ProviderEvent>
    private let continuation: AsyncStream<ProviderEvent>.Continuation
    private let log: ScheduledProviderLog
    private let complete: Bool
    init(log: ScheduledProviderLog, complete: Bool) {
        self.log = log; self.complete = complete
        let pair = AsyncStream<ProviderEvent>.makeStream(); events = pair.stream; continuation = pair.continuation
    }
    func models() -> [ProviderModel] { [.init(id: "scheduled-offline", name: "Offline fixture")] }
    func send(text: String, thread: CodingThread) {
        log.append(thread.id, text)
        if let run = thread.activeRun {
            continuation.yield(.context(runID: run.id, event: .thread("private-offline-" + thread.id.uuidString)))
            if complete { continuation.yield(.context(runID: run.id, event: .completed(.idle))) }
        }
    }
    func interrupt() { }
    func respond(_ request: ApprovalRequest, allow: Bool) { }
    func answer(_ request: ApprovalRequest, answers: [String: String]) throws {
        throw CoincideError("The scheduling fixture does not answer provider questions.")
    }
    func close() { continuation.finish() }
}
private struct ScheduledFixture {
    let root: URL
    let project: WorkspaceProject
    let source: CodingThread
    let engine: WorkspaceEngine
    let service: ScheduledTaskService
    let log: ScheduledProviderLog
    let clock: ScheduledFixtureClock
    static func make(complete: Bool = true) async throws -> Self {
        let temporary = FileManager.default.temporaryDirectory.path
        let resolved = try #require(realpath(temporary, nil)); defer { free(resolved) }
        let root = URL(fileURLWithPath: String(cString: resolved)).appendingPathComponent("coincide-scheduled-" + UUID().uuidString)
        let checkout = root.appendingPathComponent("Checkout")
        try FileManager.default.createDirectory(at: checkout, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        let project = WorkspaceProject(path: checkout.path)
        var source = CodingThread(project: project, model: "scheduled-offline"); source.draft = "Keep e\u{301} draft unchanged"; source.permission = .supervised
        var snapshot = WorkspaceSnapshot(); snapshot.projects = [project]; snapshot.threads = [source]
        let database = root.appendingPathComponent("workspace.sqlite")
        _ = try await WorkspaceDatabase(url: database).commit(snapshot, event: "private-fixture", commandID: UUID())
        let log = ScheduledProviderLog(), clock = ScheduledFixtureClock(Date(timeIntervalSince1970: 1_700_000_000))
        let engine = try WorkspaceEngine(url: database, providerFactory: { _ in ScheduledOfflineProvider(log: log, complete: complete) }, identityResolver: { _ in nil })
        _ = try await engine.load()
        let service = ScheduledTaskService(engine: engine, clock: clock.clock, secrets: MemoryScheduledTaskSecrets())
        return .init(root: root, project: project, source: source, engine: engine, service: service, log: log, clock: clock)
    }
    func definition(destination: ScheduledTaskDestination = .freshThread, schedule: ScheduledTaskSchedule = .interval(everyMilliseconds: 60_000)) throws -> ScheduledTaskDefinition {
        try .init(title: "Private scheduled task", prompt: "Literal scheduled 工作", enabled: true, schedule: schedule,
                  source: .init(thread: source, project: project), destination: destination, now: clock.now)
    }
    func close() async { await service.shutdown(); await engine.shutdown(); try? FileManager.default.removeItem(at: root) }
}
private func scheduledEventually(_ predicate: () async throws -> Bool) async throws {
    let end = ContinuousClock.now + .seconds(8)
    while try await !predicate() {
        guard ContinuousClock.now < end else { throw CoincideError("The private scheduled fixture did not settle.") }
        try await Task.sleep(for: .milliseconds(5))
    }
}

@Test func scheduledTaskPinnedTimeRulesEnforceWriteFloorElapsedIntervalsAndLocalWeekdaysWithoutCatchupBursts() throws {
    let date = ISO8601DateFormatter().date(from: "2026-10-23T10:00:00Z")!
    #expect(throws: ScheduledTaskError.invalidSchedule) { try ScheduledTaskSchedule.interval(everyMilliseconds: 59_999).validate() }
    try ScheduledTaskSchedule.interval(everyMilliseconds: 1).validate(writing: false)
    #expect(ScheduledTaskSchedule.interval(everyMilliseconds: 1).next(after: date) == date.addingTimeInterval(60))
    let zone = try #require(TimeZone(identifier: "Asia/Kolkata"))
    let fixed = ScheduledTaskSchedule.fixedTime(timeOfDay: "9:30", weekdays: [1, 2, 3, 4, 5])
    let next = try #require(fixed.next(after: date, timeZone: zone))
    #expect(ISO8601DateFormatter().string(from: next) == "2026-10-26T04:00:00Z")
    #expect(fixed.isEquivalent(to: .fixedTime(timeOfDay: "09:30", weekdays: [5, 4, 3, 2, 1])))
    #expect(ScheduledTaskSchedule.fixedTime(timeOfDay: "09:30", weekdays: []).isEquivalent(to: .fixedTime(timeOfDay: "9:30", weekdays: Array(0...6))))
    #expect(!fixed.isMissed(due: date, now: date.addingTimeInterval(600)))
    #expect(fixed.isMissed(due: date, now: date.addingTimeInterval(600.001)))
    #expect(!ScheduledTaskSchedule.interval(everyMilliseconds: 60_000).isMissed(due: date, now: date.addingTimeInterval(86400)))
}

@Test(.timeLimit(.minutes(1)), arguments: [ScheduledTaskDestination.freshThread, .existingThread])
func scheduledTaskAtomicOriginalOccurrenceUsesNormalEngineAndKeepsSourceDraft(destination: ScheduledTaskDestination) async throws {
    let f = try await ScheduledFixture.make()
    do {
        let definition = try f.definition(destination: destination)
        _ = try await f.engine.dispatch(.scheduledTask(.save(definition, expectedRevision: nil)))
        f.clock.advance(59); await f.service.sweep(); #expect(f.log.rows.isEmpty)
        f.clock.advance(1); await f.service.sweep()
        try await scheduledEventually { f.log.rows.count == 1 }
        let snapshot = await f.engine.current().snapshot
        let occurrence = try #require(snapshot.scheduler?.occurrences.first)
        let thread = try #require(snapshot.threads.first(where: { $0.id == occurrence.threadID }))
        #expect(thread.activeRun?.id == occurrence.id || thread.runHistory?.contains(where: { $0.id == occurrence.id }) == true)
        #expect(snapshot.threads.first(where: { $0.id == f.source.id })?.draft.utf8.elementsEqual(f.source.draft.utf8) == true)
        #expect(snapshot.threads.count == (destination == .freshThread ? 2 : 1))
        #expect(occurrence.threadID == (destination == .freshThread ? TaskOrchestration.derivedID(occurrence.id, "scheduled-thread") : f.source.id))
        let receipt = try await f.service.runNow(id: definition.id, commandID: occurrence.id)
        #expect(receipt.commandID == occurrence.id)
        await f.service.sweep(); #expect(f.log.rows.count == 1, "Receipt lookup and repeated clock observation never resend accepted input.")
        f.clock.advance(3600); await f.service.sweep()
        try await scheduledEventually { f.log.rows.count == 2 }
        let later = await f.engine.current().snapshot
        #expect(later.scheduler?.occurrences.count == 2, "An elapsed backlog admits one occurrence, not sixty replayed inputs.")
    } catch { await f.close(); throw error }
    await f.close()
}

@Test(.timeLimit(.minutes(1)))
func scheduledTaskOwnedLoopDoesNotRetainTheMCPCallersExpiredAuthority() async throws {
    let f = try await ScheduledFixture.make()
    do {
        let definition = try f.definition()
        _ = try await f.engine.dispatch(.scheduledTask(.save(definition, expectedRevision: nil)))
        var fields: [String: JSONValue] = [:]
        for key in ["sessionID", "threadID", "projectID", "runtimeID", "incarnation", "providerInstanceID", "runID"] {
            fields[key] = .string(UUID().uuidString)
        }
        fields["workspacePath"] = .string(f.source.workspacePath)
        fields["provider"] = .string(f.source.provider.rawValue)
        fields["permission"] = .string(f.source.permission.rawValue)
        let expiredCaller = try JSONDecoder().decode(AppMCPCommandAuthority.self, from: JSONEncoder().encode(JSONValue.object(fields)))
        // No live provider owns this expired scope. Future execution belongs to
        // the saved task, while explicit MCP writes still require a live caller.
        await AppMCPTaskContext.$authority.withValue(expiredCaller) { await f.service.start() }
        f.clock.advance(60)
        try await scheduledEventually { f.log.rows.count == 1 }
        let snapshot = await f.engine.current().snapshot
        #expect(snapshot.scheduler?.occurrences.count == 1 && snapshot.scheduler?.tasks.first?.enabled == true)
        #expect(snapshot.threads.first(where: { $0.id == f.source.id })?.draft == f.source.draft)
    } catch { await f.close(); throw error }
    await f.close()
}

@Test(.timeLimit(.minutes(1)))
func scheduledTaskRestartKeepsOriginalReceiptAndUnknownInputWithoutAutomaticReplay() async throws {
    let f = try await ScheduledFixture.make(complete: false)
    let definition = try f.definition()
    do {
        _ = try await f.engine.dispatch(.scheduledTask(.save(definition, expectedRevision: nil)))
        f.clock.advance(60); await f.service.sweep(); try await scheduledEventually { f.log.rows.count == 1 }
        let original = try #require(await f.engine.current().snapshot.scheduler?.occurrences.first)
        await f.service.shutdown(); await f.engine.shutdown()
        let reopened = try WorkspaceEngine(url: f.root.appendingPathComponent("workspace.sqlite"), providerFactory: { _ in ScheduledOfflineProvider(log: f.log, complete: false) }, identityResolver: { _ in nil })
        let service = ScheduledTaskService(engine: reopened, clock: f.clock.clock, secrets: MemoryScheduledTaskSecrets())
        do {
            let snapshot = try await reopened.load(), recovered = try #require(snapshot.scheduler?.occurrences.first)
            #expect(recovered.id == original.id && recovered.phase == .uncertain)
            #expect(snapshot.scheduler?.tasks.first?.enabled == false)
            f.clock.advance(3600); await service.sweep()
            let receipt = try await service.runNow(id: definition.id, commandID: original.id)
            #expect(receipt.commandID == original.id && f.log.rows.count == 1)
            await #expect(throws: (any Error).self) { try await service.runNow(id: definition.id, commandID: UUID()) }
            #expect(f.log.rows.count == 1)
        } catch { await service.shutdown(); await reopened.shutdown(); throw error }
        await service.shutdown(); await reopened.shutdown()
    } catch { await f.close(); throw error }
    await f.close()
}

@Test(.timeLimit(.minutes(1)), arguments: ["birth", "path", "model", "permission", "deleted", "physical"])
func scheduledTaskReboundSourceFailsClosedBeforeCreatingAnyInput(change: String) async throws {
    let f = try await ScheduledFixture.make()
    do {
        let definition = try f.definition()
        _ = try await f.engine.dispatch(.scheduledTask(.save(definition, expectedRevision: nil)))
        if change == "physical" {
            try FileManager.default.moveItem(at: URL(fileURLWithPath: f.project.path), to: f.root.appendingPathComponent("RetainedCheckout"))
            try FileManager.default.createDirectory(atPath: f.project.path, withIntermediateDirectories: false)
            f.clock.advance(60); await f.service.sweep()
            #expect(f.log.rows.isEmpty)
            #expect(await f.engine.current().snapshot.scheduler?.tasks.first?.enabled == false)
        } else {
            var snapshot = await f.engine.current().snapshot
            switch change {
            case "birth": snapshot.threads[0].createdAt += 1
            case "path": snapshot.threads[0].workspacePath += "/changed"
            case "model": snapshot.threads[0].model = "other"
            case "permission": snapshot.threads[0].permission = .fullAccess
            default: snapshot.threads = []
            }
            let fire = ScheduledTaskFire(taskID: definition.id, revision: definition.revision, trigger: .manual, dueAt: f.clock.now,
                observedAt: f.clock.now, managedRoot: f.root.appendingPathComponent("Worktrees").path, prompt: nil, delivery: nil)
            #expect(throws: ScheduledTaskError.sourceChanged) { try WorkspaceDecision.make(.client(.scheduledTask(.fire(fire))), id: UUID(), snapshot: snapshot, now: f.clock.now) }
            #expect(f.log.rows.isEmpty)
        }
    } catch { await f.close(); throw error }
    await f.close()
}

@Test(.timeLimit(.minutes(1)))
func scheduledTaskWebhookVerifiesExactBodyHeaderAuthFiltersAndLostResponseDedupeWithoutStoringCredentials() async throws {
    let f = try await ScheduledFixture.make()
    do {
        let id = UUID(), signing = Data("private-offline-fixture-signing-only".utf8)
        let registration = try await f.service.configureWebhook(taskID: id, configuration: .init(signature: .init(), filters: [.init(path: "body.action", operation: .equals, values: ["opened"])]), signingSecret: signing)
        let authorization = try #require(registration.authorizationHeader)
        let task = try ScheduledTaskDefinition(id: id, title: "Private webhook", prompt: "Review {{body.action}} {{body.title}} {{headers.authorization}}", enabled: true,
            schedule: .webhook(registration.configuration), source: .init(thread: f.source, project: f.project), now: f.clock.now)
        _ = try await f.engine.dispatch(.scheduledTask(.save(task, expectedRevision: nil)))
        let body = Data(#"{"action":"opened","title":"$skill @file /command 工作"}"#.utf8)
        let signature = Data(HMAC<SHA256>.authenticationCode(for: body, using: SymmetricKey(data: signing))).map { String(format: "%02x", $0) }.joined()
        let headers = ["authorization": authorization, "x-hub-signature-256": "sha256=" + signature, "idempotency-key": "private-delivery-id", "content-type": "application/json"]
        let bad = await f.service.receiveWebhook(.init(method: "POST", path: "/hooks/" + id.uuidString, headers: [:], body: body))
        #expect(bad.status == 401 && f.log.rows.isEmpty)
        let request = ScheduledTaskHTTPRequest(method: "POST", path: "/hooks/" + id.uuidString, headers: headers, body: body)
        let first = await f.service.receiveWebhook(request)
        #expect(first.status == 202)
        try await scheduledEventually { f.log.rows.count == 1 }
        let second = await f.service.receiveWebhook(request)
        #expect(second.status == 202 && second.outcome == "duplicate" && f.log.rows.count == 1)
        let delivered = try #require(f.log.rows.first?.1)
        #expect(delivered.contains("webhook-data-") && delivered.contains("@\u{2060}file") && !delivered.contains(authorization))
        let snapshotBytes = try JSONEncoder().encode(await f.engine.current().snapshot.scheduler)
        #expect(snapshotBytes.range(of: Data(authorization.utf8)) == nil)
        #expect(snapshotBytes.range(of: signing) == nil)
        var invalid = headers; invalid["x-hub-signature-256"] = "sha256=" + String(repeating: "0", count: 64)
        let refused = await f.service.receiveWebhook(.init(method: "POST", path: request.path, headers: invalid, body: body))
        #expect(refused.status == 401 && f.log.rows.count == 1)
        // Exercise the actual owned loopback listener through authentication,
        // durable Engine admission and the explicitly injected offline provider.
        let port = try await f.service.startWebhookListener()
        let configuration = URLSessionConfiguration.ephemeral
        configuration.connectionProxyDictionary = [:]; configuration.urlCredentialStorage = nil; configuration.httpCookieStorage = nil
        let session = URLSession(configuration: configuration); defer { session.invalidateAndCancel() }
        var wire = URLRequest(url: URL(string: "http://127.0.0.1:\(port)/hooks/" + id.uuidString)!)
        wire.httpMethod = "POST"; wire.httpBody = body
        for (name, value) in headers { wire.setValue(value, forHTTPHeaderField: name) }
        wire.setValue("actual-wire-delivery", forHTTPHeaderField: "Idempotency-Key")
        let (_, wireResponse) = try await session.data(for: wire)
        #expect((wireResponse as? HTTPURLResponse)?.statusCode == 202)
        try await scheduledEventually { f.log.rows.count == 2 }
        let (_, repeatedResponse) = try await session.data(for: wire)
        #expect((repeatedResponse as? HTTPURLResponse)?.statusCode == 202 && f.log.rows.count == 2)

    } catch { await f.close(); throw error }
    await f.close()
}

@Test(.timeLimit(.minutes(1)))
func scheduledTaskWebhookCoalescingRetainsLatestPayloadInFixedWindowAndNeverReplaysAfterRestart() async throws {
    let f = try await ScheduledFixture.make()
    do {
        let id = UUID(), registration = try await f.service.configureWebhook(taskID: id, configuration: .init(coalesceKey: "{{body.repository}}", coalesceWindowSeconds: 10))
        let authorization = try #require(registration.authorizationHeader)
        let task = try ScheduledTaskDefinition(id: id, title: "Coalesced", prompt: "Payload {{body.text}}", enabled: true, schedule: .webhook(registration.configuration), source: .init(thread: f.source, project: f.project), now: f.clock.now)
        _ = try await f.engine.dispatch(.scheduledTask(.save(task, expectedRevision: nil)))
        for (key, value) in [("first", "old"), ("second", "new")] {
            let body = try JSONSerialization.data(withJSONObject: ["repository": "one", "text": value])
            let response = await f.service.receiveWebhook(.init(method: "POST", path: "/hooks/" + id.uuidString,
                headers: ["authorization": authorization, "idempotency-key": key], body: body))
            #expect(response.status == 202)
        }
        #expect(f.log.rows.isEmpty)
        f.clock.advance(9); await f.service.sweep(); #expect(f.log.rows.isEmpty)
        f.clock.advance(1); await f.service.sweep(); try await scheduledEventually { f.log.rows.count == 1 }
        #expect(f.log.rows.first?.1.contains("new") == true && f.log.rows.first?.1.contains(">old<") == false)
        let snapshot = await f.engine.current().snapshot
        #expect(snapshot.scheduler?.webhookPending.isEmpty == true)
        #expect(snapshot.scheduler?.occurrences.filter({ $0.phase == .coalesced }).count == 1)
        await f.service.sweep(); #expect(f.log.rows.count == 1)
    } catch { await f.close(); throw error }
    await f.close()
}

private actor ScheduledWorktreePreparationGate: WorkspaceWorktreeSession {
    let real: GitWorktreeService
    private var released = false
    private var waiter: CheckedContinuation<Void, Never>?
    private(set) var waiting = false
    init(_ real: GitWorktreeService) { self.real = real }
    func release() { released = true; waiter?.resume(); waiter = nil }
    func prepare() async throws -> GitWorktreePlan {
        waiting = true
        if !released { await withCheckedContinuation { waiter = $0 } }
        try Task.checkCancellation(); return try await real.prepare()
    }
    func run(_ plan: GitWorktreePlan) async throws -> GitWorktreeResult { try await real.run(plan) }
    func inspectCompletion(_ plan: GitWorktreePlan) async throws -> GitWorktreeResult? { try await real.inspectCompletion(plan) }
}
private final class ScheduledWorktreeGateRegistry: @unchecked Sendable {
    let fixture: WorktreeFixture
    private let lock = NSLock()
    private var owned: ScheduledWorktreePreparationGate?
    init(_ fixture: WorktreeFixture) { self.fixture = fixture }
    func make(_ request: GitWorktreeRequest) -> ScheduledWorktreePreparationGate {
        let result = ScheduledWorktreePreparationGate(fixture.service(request)); lock.withLock { owned = result }; return result
    }
    var gate: ScheduledWorktreePreparationGate? { lock.withLock { owned } }
}

@Test(.timeLimit(.minutes(1)))
func scheduledTaskFreshWorktreeAtomicallyQueuesUntilActualLocalGitReadinessAndPreservesSourceBytes() async throws {
    let git = try await WorktreeFixture.make(), log = ScheduledProviderLog(), registry = ScheduledWorktreeGateRegistry(git)
    let project = WorkspaceProject(path: git.source.path), source = CodingThread(project: project, model: "scheduled-offline")
    var initial = WorkspaceSnapshot(); initial.projects = [project]; initial.threads = [source]
    let database = git.root.appendingPathComponent("scheduler.sqlite")
    _ = try await WorkspaceDatabase(url: database).commit(initial, event: "fixture", commandID: UUID())
    let engine = try WorkspaceEngine(url: database, providerFactory: { _ in ScheduledOfflineProvider(log: log, complete: true) },
        identityResolver: { _ in nil }, worktreeFactory: { registry.make($0) })
    let service = ScheduledTaskService(engine: engine, secrets: MemoryScheduledTaskSecrets())
    do {
        _ = try await engine.load()
        try Data("Uncommitted source only\n".utf8).write(to: git.source.appendingPathComponent("README.md"))
        try Data("Untracked source only\n".utf8).write(to: git.source.appendingPathComponent("private-untracked.txt"))
        let before = try await git.run(["status", "--porcelain=v1", "-z"])
        let definition = try ScheduledTaskDefinition(title: "Isolated scheduled task", prompt: "Only after checkout readiness", enabled: false,
            schedule: .interval(everyMilliseconds: 60_000), source: .init(thread: source, project: project), workspace: .newWorktree(baseRef: "HEAD", submodules: .none))
        _ = try await engine.dispatch(.scheduledTask(.save(definition, expectedRevision: nil)))
        let commandID = UUID(); _ = try await service.runNow(id: definition.id, commandID: commandID)
        try await scheduledEventually { guard let gate = registry.gate else { return false }; return await gate.waiting }
        let staged = await engine.current().snapshot, child = try #require(staged.threads.first(where: { $0.id != source.id }))
        #expect(child.queuedTurns.map(\.id) == [commandID] && child.workspacePreparation != nil && child.activeRun == nil && log.rows.isEmpty)
        await registry.gate?.release()
        try await scheduledEventually { log.rows.count == 1 }
        let ready = await engine.current().snapshot, current = try #require(ready.threads.first(where: { $0.id == child.id }))
        #expect(ready.workspaceReady(for: current))
        let after = try await git.run(["status", "--porcelain=v1", "-z"])
        #expect(before.output == after.output)
        #expect(try String(contentsOfFile: project.path + "/README.md", encoding: .utf8) == "Uncommitted source only\n")
        #expect(!FileManager.default.fileExists(atPath: current.workspacePath + "/private-untracked.txt"))
        #expect(try String(contentsOfFile: current.workspacePath + "/README.md", encoding: .utf8) == "Committed bytes\n")
    } catch { await registry.gate?.release(); await service.shutdown(); await engine.shutdown(); try? FileManager.default.removeItem(at: git.root); throw error }
    await registry.gate?.release(); await service.shutdown(); await engine.shutdown(); try FileManager.default.removeItem(at: git.root)
}
