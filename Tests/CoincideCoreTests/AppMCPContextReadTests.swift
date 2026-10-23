import Foundation
import Testing
@testable import CoincideCore

private actor ContextArchivePeer: ProviderSession {
    nonisolated let supportsAppMCP = true
    nonisolated let events: AsyncStream<ProviderEvent>
    private let continuation: AsyncStream<ProviderEvent>.Continuation
    private(set) var connection: AppMCPConnection?
    private(set) var inputs: [ProviderInput] = []
    private var runID: UUID?
    init() { let pair = AsyncStream<ProviderEvent>.makeStream(); events = pair.stream; continuation = pair.continuation }
    func configureAppMCP(_ value: AppMCPConnection) { connection = value }
    func models() -> [ProviderModel] { [.init(id: "context-target", name: "Offline context target")] }
    func send(text: String, thread: CodingThread) { send(input: .init(text: text), thread: thread) }
    func send(input: ProviderInput, thread: CodingThread) {
        inputs.append(input); runID = thread.activeRun?.id
        guard let runID else { return }
        continuation.yield(.context(runID: runID, event: .thread("context-private-native")))
        continuation.yield(.context(runID: runID, event: .turn("context-private-turn-\(runID)")))
    }
    func finish() { if let runID { continuation.yield(.context(runID: runID, event: .completed(.idle))) } }
    func interrupt() { if let runID { continuation.yield(.context(runID: runID, event: .completed(.interrupted))) } }
    func respond(_ request: ApprovalRequest, allow: Bool) {}
    func answer(_ request: ApprovalRequest, answers: [String: String]) {}
    func close() { continuation.finish() }
}

private struct ContextArchiveFixture: Sendable {
    let root: URL
    let engine: WorkspaceEngine
    let peer: ContextArchivePeer
    let sourceID: UUID
    let targetID: UUID
    let transferID: UUID
    let foreignTransferID: UUID
    let body: String
    static func make() async throws -> Self {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("coincide-mcp-context-\(UUID())").resolvingSymlinksInPath()
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        let workspace = root.appendingPathComponent("workspace")
        try FileManager.default.createDirectory(at: workspace, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        let project = WorkspaceProject(path: workspace.path)
        let body = String(repeating: "😀\"\\\0工作\n", count: 3_000)
        func source(_ marker: String, text: String) -> CodingThread {
            var thread = CodingThread(project: project, model: "offline-source"); thread.provider = .muse; thread.checkpointPolicy = .disabled
            let native = MuseConfiguration(executable: root.appendingPathComponent("offline-source-never-launched").path,
                model: .init(modelID: "offline-source"))
            thread.museConfiguration = native; thread.model = native.model!.catalogID
            thread.draft = "UNRELATED-DRAFT-CANARY"
            let run = ActiveRun(id: UUID(), configuration: .init(thread: thread), startedAt: Date(timeIntervalSince1970: 1_700_000_000))
            var record = ThreadRunRecord(run: run, origin: .user, userMessageID: marker + "-user")
            record.status = .completed; record.endReason = .providerCompleted; record.endedAt = Date(); record.messageAttributionVersion = 1
            thread.runHistory = [record]
            thread.messages = [.init(id: marker + "-user", role: .user, text: "Original constraints")] + (0..<3).map {
                .init(id: marker + "-assistant-\($0)", role: .assistant, text: text)
            }
            for index in thread.messages.indices { thread.messages[index].runReference = .init(threadID: thread.id, runID: run.id) }
            return thread
        }
        let original = source("owned", text: body), foreign = source("foreign", text: "FOREIGN-ARCHIVE-CANARY")
        var snapshot = WorkspaceSnapshot(); snapshot.projects = [project]; snapshot.threads = [original, foreign]
        let database = root.appendingPathComponent("workspace.sqlite")
        try await WorkspaceDatabase(url: database).save(snapshot, event: "private-context-fixture")
        let peer = ContextArchivePeer()
        let engine = try WorkspaceEngine(url: database, appMCPEnabled: false, contextMCPEnabled: true,
            providerFactory: { _ in peer }, identityResolver: { _ in nil })
        do {
            _ = try await engine.load()
            func request(_ source: CodingThread) -> ContextTransferReviewRequest {
                var destination = ProviderConfiguration(thread: source); destination.provider = .claude
                destination.model = "context-target"; destination.nativeThreadID = nil; destination.museConfiguration = nil
                return .init(sourceThreadID: source.id, expectedConfiguration: .init(thread: source),
                    sourcePoint: .run(source.runHistory![0].id), intent: .fork(destination: destination))
            }
            let review = try await engine.reviewContextTransfer(request(original))
            #expect(try await engine.acceptContextTransfer(reviewID: review.id, digest: review.digest).rejection == nil)
            let other = try await engine.reviewContextTransfer(request(foreign))
            #expect(try await engine.acceptContextTransfer(reviewID: other.id, digest: other.digest).rejection == nil)
            #expect(await peer.inputs.isEmpty)
            #expect(try await engine.dispatch(.submit(threadID: review.targetThreadID, text: "Read this exact captured context")).rejection == nil)
            try await contextArchiveEventually {
                let connected = await peer.connection != nil
                let update = await engine.current()
                return connected && update.snapshot.contextTransfer(review.id)?.delivery?.status == .delivered &&
                    update.snapshot.threads.first(where: { $0.id == review.targetThreadID })?.activeRun?.nativeTurnID != nil
            }
            return .init(root: root, engine: engine, peer: peer, sourceID: original.id, targetID: review.targetThreadID,
                transferID: review.id, foreignTransferID: other.id, body: body)
        } catch { await engine.shutdown(); print("Private MCP context fixture retained at \(root.path)"); throw error }
    }
    func transfer() async throws -> ContextTransfer { try #require(await engine.current().snapshot.contextTransfer(transferID)) }
    func close() async { await engine.shutdown() }
    func remove() throws { try FileManager.default.removeItem(at: root) }
}

private func contextArchiveEventually(_ predicate: () async throws -> Bool) async throws {
    let end = ContinuousClock.now + .seconds(8)
    while try await !predicate() {
        guard ContinuousClock.now < end else { throw CoincideError("The private captured-context fixture did not reach its boundary.") }
        try await Task.sleep(for: .milliseconds(5))
    }
}

private func contextArchiveRPC(_ connection: AppMCPConnection, method: String, params: JSONValue = .object([:]), initialized: Bool = true) async throws -> JSONValue {
    var request = URLRequest(url: connection.endpoint); request.httpMethod = "POST"
    request.setValue(connection.authorizationHeader, forHTTPHeaderField: "Authorization")
    request.setValue("application/json", forHTTPHeaderField: "Content-Type")
    request.setValue("application/json, text/event-stream", forHTTPHeaderField: "Accept")
    if initialized { request.setValue("2025-06-18", forHTTPHeaderField: "MCP-Protocol-Version") }
    let notification = method.hasPrefix("notifications/")
    var frame: [String: JSONValue] = ["jsonrpc": .string("2.0"), "method": .string(method), "params": params]
    if !notification { frame["id"] = .string(UUID().uuidString) }
    request.httpBody = try MCPProtocol.encode(.object(frame))
    let configuration = URLSessionConfiguration.ephemeral; configuration.connectionProxyDictionary = [:]
    configuration.httpCookieStorage = nil; configuration.urlCredentialStorage = nil; configuration.timeoutIntervalForRequest = 8
    let session = URLSession(configuration: configuration); defer { session.invalidateAndCancel() }
    let (data, response) = try await session.data(for: request)
    if notification {
        guard (response as? HTTPURLResponse)?.statusCode == 202, data.isEmpty else { throw CoincideError("The private context MCP notification was refused.") }
        return .null
    }
    guard (response as? HTTPURLResponse)?.statusCode == 200 else { throw CoincideError("The private context MCP request was refused.") }
    return try MCPProtocol.decode(data)
}

private func contextArchiveInitialize(_ connection: AppMCPConnection) async throws {
    let value = try await contextArchiveRPC(connection, method: "initialize", params: .object(["protocolVersion": .string("2025-06-18"),
        "capabilities": .object([:]), "clientInfo": .object(["name": .string("private-context-tests"), "version": .string("1")])]), initialized: false)
    #expect(value["result"]["protocolVersion"] == .string("2025-06-18"))
    _ = try await contextArchiveRPC(connection, method: "notifications/initialized")
}

@Test(.timeLimit(.minutes(1)))
func appMCPContextReadAuthorizesOnlyThisActiveInputsImmutableCapturedTransfer() async throws {
    let fixture = try await ContextArchiveFixture.make()
    do {
        let context = try await fixture.engine.appMCPContext(threadID: fixture.targetID)
        let arguments = JSONValue.object(["transferId": .string(fixture.transferID.uuidString)])
        let before = try await fixture.engine.appMCPContextRead(arguments, context: context)
        #expect(before["transferId"].string == fixture.transferID.uuidString.lowercased())
        #expect(before["items"].array?.isEmpty == false)
        #expect(!String(decoding: try MCPProtocol.encode(before), as: UTF8.self).contains("UNRELATED-DRAFT-CANARY"))
        _ = try await fixture.engine.dispatch(.editThread(fixture.sourceID, .title("Newer live source header")))
        #expect(try await fixture.engine.appMCPContextRead(arguments, context: context) == before)
        for id in [fixture.foreignTransferID, UUID()] {
            await #expect(throws: AppMCPError(.staleCaller)) {
                _ = try await fixture.engine.appMCPContextRead(.object(["transferId": .string(id.uuidString)]), context: context)
            }
        }
        await fixture.peer.finish()
        try await contextArchiveEventually { await fixture.engine.current().snapshot.threads.first { $0.id == fixture.targetID }?.activeRun == nil }
        await #expect(throws: AppMCPError(.staleCaller)) { _ = try await fixture.engine.appMCPContextRead(arguments, context: context) }
        _ = try await fixture.engine.dispatch(.submit(threadID: fixture.targetID, text: "A later explicit input"))
        try await contextArchiveEventually { await fixture.peer.inputs.count == 2 }
        await #expect(throws: AppMCPError(.staleCaller)) { _ = try await fixture.engine.appMCPContext(threadID: fixture.targetID) }
        await #expect(throws: AppMCPError(.staleCaller)) { _ = try await fixture.engine.appMCPContextRead(arguments, context: context) }
        #expect(await fixture.peer.inputs.last?.historicalContext == nil)
        await fixture.close(); try fixture.remove()
    } catch { await fixture.close(); print("Private MCP context fixture retained at \(fixture.root.path)"); throw error }
}

@Test(.timeLimit(.minutes(1)))
func appMCPContextArchivePagesExactEscapedUnicodeWithinEncodedResponseBounds() async throws {
    let fixture = try await ContextArchiveFixture.make()
    do {
        let transfer = try await fixture.transfer()
        let first = try AppMCPContextArchive.read(transfer: transfer, arguments: .object(["limit": .number(100), "maxBytesPerItem": .number(65_536)]))
        #expect(try MCPProtocol.encode(first).count < 102_400)
        #expect(first["hasMore"] == .bool(true))
        var identifiers: [String] = [], after: JSONValue = .null
        repeat {
            var args: [String: JSONValue] = ["limit": .number(1), "maxBytesPerItem": .number(16)]
            if after != .null { args["afterPosition"] = after }
            let page = try AppMCPContextArchive.read(transfer: transfer, arguments: .object(args))
            let row = try #require(page["items"].array?.first)
            identifiers.append(try #require(row["itemId"].string)); after = page["nextPosition"]
            if page["hasMore"] == .bool(false) { break }
        } while true
        #expect(identifiers == transfer.review.messages.map(\.id))
        let item = try #require(transfer.review.messages.first { $0.role == "assistant" })
        var bytes = Data(), offset = 0
        repeat {
            let page = try AppMCPContextArchive.read(transfer: transfer, arguments: .object(["itemId": .string(item.id), "textOffset": .number(Double(offset)), "maxBytesPerItem": .number(4_096)]))
            let row = try #require(page["items"].array?.first), text = try #require(row["text"].string)
            #expect(row["textOffset"] == .number(Double(offset)))
            bytes.append(contentsOf: text.utf8)
            guard case .number(let next) = row["nextTextOffset"] else { break }
            #expect(next > Double(offset)); offset = Int(next)
        } while true
        #expect(bytes == Data(fixture.body.utf8))
        let invalid: [[String: JSONValue]] = [
            ["itemId": .string(item.id), "textOffset": .number(1)],
            ["itemId": .string(item.id), "maxBytesPerItem": .number(1)],
            ["itemId": .string(item.id), "textOffset": .number(Double(bytes.count + 1))],
            ["textOffset": .number(1)], ["limit": .number(101)], ["afterPosition": .number(-1)]
        ]
        for fields in invalid {
            #expect(throws: AppMCPError(.invalidRequest)) { _ = try AppMCPContextArchive.read(transfer: transfer, arguments: .object(fields)) }
        }
        await fixture.close(); try fixture.remove()
    } catch { await fixture.close(); print("Private MCP context fixture retained at \(fixture.root.path)"); throw error }
}

@Test(.timeLimit(.minutes(1)))
func appMCPContextOnlyProductionHTTPHostAdvertisesOneReadToolAndRefusesEveryWrite() async throws {
    let fixture = try await ContextArchiveFixture.make()
    do {
        let connection = try #require(await fixture.peer.connection)
        try await contextArchiveInitialize(connection)
        let list = try await contextArchiveRPC(connection, method: "tools/list")
        #expect(list["result"]["tools"].array?.compactMap { $0["name"].string } == ["t3_context_read"])
        let before = await fixture.engine.current().snapshot
        for name in ["t3_thread_send", "t3_project_create", "t3_thread_fork", "t3_thread_merge_back", "t3_thread_read"] {
            let denied = try await contextArchiveRPC(connection, method: "tools/call", params: .object(["name": .string(name), "arguments": .object([:])]))
            #expect(denied["error"] != .null || denied["result"]["isError"] == .bool(true))
        }
        let result = try await contextArchiveRPC(connection, method: "tools/call", params: .object(["name": .string("t3_context_read"),
            "arguments": .object(["transferId": .string(fixture.transferID.uuidString), "limit": .number(1)])]))
        #expect(result["result"]["isError"] == .bool(false))
        #expect(result["result"]["structuredContent"]["transferId"].string == fixture.transferID.uuidString.lowercased())
        #expect(await fixture.engine.current().snapshot == before)
        #expect(await fixture.peer.inputs.count == 1)
        await fixture.close(); try fixture.remove()
    } catch { await fixture.close(); print("Private MCP context fixture retained at \(fixture.root.path)"); throw error }
}
