import CryptoKit
import Darwin
import Foundation
import Testing
@testable import CoincideCore

/// Actual native helper and private SQLite. No provider or user login process is
/// permitted: the explicit provider executable records and rejects any launch.
private struct RemoteProjectionNativeFixture: Sendable {
    let root: URL, data: URL, workspace: URL, host: URL
    let environmentID: UUID, snapshot: WorkspaceSnapshot, encodedSnapshotBytes: Int
    var thread: CodingThread { snapshot.threads[0] }
    var environment: [String: String] {
        ["PATH": "/usr/bin:/bin:/usr/sbin:/sbin", "HOME": root.appendingPathComponent("home").path,
         "LANG": "en_US.UTF-8", "LC_ALL": "en_US.UTF-8", "GIT_CONFIG_NOSYSTEM": "1", "GIT_CONFIG_GLOBAL": "/dev/null"]
    }
    var arguments: [String] {
        ["--stdio", "--data-directory", data.path, "--expected-environment-id", environmentID.uuidString,
         "--codex-executable", root.appendingPathComponent("provider-must-not-run").path,
         "--codex-home", root.appendingPathComponent("codex-home").path,
         "--claude-executable", root.appendingPathComponent("provider-must-not-run").path,
         "--claude-configuration-directory", root.appendingPathComponent("claude-home").path]
    }
    static func quote(_ text: String) -> String { "'" + text.replacingOccurrences(of: "'", with: "'\\''") + "'" }
    static func make(oversized: Bool = true, historyProof: Bool = false) async throws -> Self {
        let fm = FileManager.default
        let root = fm.temporaryDirectory.appendingPathComponent("coincide-remote-projection-\(UUID())").resolvingSymlinksInPath()
        try fm.createDirectory(at: root, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        do {
            let workspace = root.appendingPathComponent("workspace"), data = root.appendingPathComponent("data")
            for name in ["workspace", "data", "home", "codex-home", "claude-home"] {
                try fm.createDirectory(at: root.appendingPathComponent(name), withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
            }
            // Create the durable identity without opening Engine or SQLite,
            // then seed valid native state before starting the actual helper.
            let identity = try RemoteEnvironmentService(dataDirectory: data, providerFactory: { _ in throw CoincideError("Projection must not launch a provider") })
            let environmentID = await identity.descriptor().environmentID
            await identity.close()
            var fixture = try ConversationHistoryFilesFixture()
            fixture.snapshot.projects[0].path = workspace.path
            fixture.snapshot.threads[0].workspacePath = workspace.path
            fixture.snapshot.threads[0].draft = oversized
                ? String(repeating: "Preserve escaped draft \"\\\n\0🌍 e\u{301}\n", count: 50_000)
                : "Preserve exact unsent draft 🌍 e\u{301}\n"
            for index in fixture.snapshot.threads[0].runHistory!.indices {
                fixture.snapshot.threads[0].runHistory![index].configuration.workspacePath = workspace.path
                fixture.snapshot.threads[0].runHistory![index].checkpoints = nil
            }
            let runID = try #require(fixture.runs.last)
            let block = String(repeating: "a", count: 32 * 1_024)
            for index in 0..<(oversized ? 600 : 3) {
                var message = ChatMessage(id: "projection-message-\(index)", role: .assistant, text: "row-\(index):" + block)
                message.createdAt = Date(timeIntervalSince1970: Double(100 + index))
                message.runReference = .init(threadID: fixture.threadID, runID: runID)
                fixture.snapshot.threads[0].messages.append(message)
            }
            var giant = ChatMessage(id: "projection-giant-escaped-unicode", role: .assistant,
                text: String(repeating: "\"\\\n\r\t\0🌍é e\u{301}", count: oversized ? 100_000 : 10))
            giant.createdAt = Date(timeIntervalSince1970: 1_000)
            giant.runReference = .init(threadID: fixture.threadID, runID: runID)
            giant.attachments = [.init(id: UUID(), name: "Private metadata é.txt", mimeType: "text/plain", byteCount: 4,
                digest: String(repeating: "a", count: 64), fileExtension: "txt")]
            fixture.snapshot.threads[0].messages.append(giant)
            if historyProof {
                let review = try fixture.review(restoreFiles: false)
                _ = try fixture.accept(review); try fixture.dispatchProvider(review)
                _ = try fixture.finishProvider(review, result: .conversationHistoryUnconfirmed)
            }
            let snapshot = fixture.snapshot
            try WorkspaceJournal.validate(snapshot)
            let encoded = try JSONEncoder().encode(RemoteEnvironmentSnapshot(environmentID: environmentID, sequence: 1, workspace: snapshot))
            if oversized { #expect(encoded.count > RemoteEnvironmentProtocol.maximumFrameBytes) }
            try await WorkspaceDatabase(url: data.appendingPathComponent("workspace.sqlite")).save(snapshot, event: "private-projection-seed")
            #if DEBUG
            let mode = "debug"
            #else
            let mode = "release"
            #endif
            let checkout = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            let helper = checkout.appendingPathComponent(".build/\(mode)/CoincideEnvironment").resolvingSymlinksInPath()
            guard fm.isExecutableFile(atPath: helper.path) else { throw CoincideError("Build the matching native helper before projection acceptance.") }
            let host = root.appendingPathComponent("native-host")
            for (path, text) in [
                (host, "#!/bin/sh\numask 077\nprintf '%s\\n' \"$$\" >> \(quote(root.appendingPathComponent("host-pids.txt").path))\nexec \(quote(helper.path)) \"$@\"\n"),
                (root.appendingPathComponent("provider-must-not-run"), "#!/bin/sh\nprintf '%s\\n' \"$$\" >> \(quote(root.appendingPathComponent("unexpected-provider-pids.txt").path))\nexit 79\n")
            ] {
                try text.write(to: path, atomically: false, encoding: .utf8)
                try fm.setAttributes([.posixPermissions: 0o700], ofItemAtPath: path.path)
            }
            return .init(root: root, data: data, workspace: workspace, host: host, environmentID: environmentID, snapshot: snapshot, encodedSnapshotBytes: encoded.count)
        } catch { try? fm.removeItem(at: root); throw error }
    }
    func connection() throws -> JSONRPCConnection {
        try .init(executable: host, arguments: arguments, cwd: root, dialect: .jsonRPC2,
            maximumFrameSize: RemoteEnvironmentProtocol.maximumFrameBytes, environment: environment, drainProcessOnClose: true)
    }
    func client() -> RemoteEnvironmentClient { .init(factory: { try connection() }, expectedEnvironmentID: environmentID) }
    func verifyDrained() async throws {
        let file = root.appendingPathComponent("host-pids.txt")
        let pids = try String(contentsOf: file, encoding: .utf8).split(whereSeparator: \.isNewline).compactMap { Int32($0) }
        try await remoteProjectionEventually { pids.allSatisfy { kill($0, 0) == -1 && errno == ESRCH } }
        #expect(!FileManager.default.fileExists(atPath: root.appendingPathComponent("unexpected-provider-pids.txt").path))
    }
    func finish(_ client: RemoteEnvironmentClient) async throws {
        await client.close(); try await verifyDrained(); try FileManager.default.removeItem(at: root)
    }
    func failed(_ client: RemoteEnvironmentClient) async { await client.close(); print("Private native projection fixture retained at \(root.path)") }
}
private func remoteProjectionEventually(_ predicate: @escaping @Sendable () async throws -> Bool) async throws {
    let deadline = ContinuousClock.now + .seconds(10)
    while try await !predicate() {
        guard ContinuousClock.now < deadline else { throw CoincideError("The private projection fixture did not reach its bounded lifecycle boundary.") }
        try await Task.sleep(for: .milliseconds(10))
    }
}
private actor RemoteProjectionNativeHints {
    private(set) var latest: RemoteProjectionInvalidation?
    func consume(_ event: RemoteEnvironmentClientEvent) {
        if case .projectionChanged(let value) = event { latest = value }
    }
}

private func remoteProjectionBytes(_ client: RemoteEnvironmentClient, binding: RemoteProjectionBinding,
                                   reference: RemoteProjectionContentReference) async throws -> Data {
    var result = Data(), cursor: UUID?
    repeat {
        let part = try await client.projectionContent(.init(binding: binding, reference: reference, offset: result.count, cursor: cursor))
        #expect(try RemoteProjectionProtocol.payload(part).count <= RemoteProjectionProtocol.maximumResultBytes)
        #expect(part.binding == binding && part.reference == reference && part.offset == result.count)
        #expect(part.data.count <= RemoteProjectionProtocol.maximumContentChunkBytes)
        result.append(part.data); cursor = part.nextCursor
        #expect(part.complete == (cursor == nil))
    } while cursor != nil
    #expect(result.count == reference.totalBytes && RemoteProjectionProtocol.digest(result) == reference.digest)
    return result
}
private func remoteProjectionText(_ client: RemoteEnvironmentClient, binding: RemoteProjectionBinding,
                                  text: RemoteProjectionText) async throws -> Data {
    if text.complete { return Data(text.preview.utf8) }
    let reference = try #require(text.content)
    #expect(reference.kind == .text || reference.kind == .draft)
    return try await remoteProjectionBytes(client, binding: binding, reference: reference)
}

@Test(.timeLimit(.minutes(3)))
func remoteProjectionNativeOversizedValidatedSQLitePagesEveryExactMessageAndKeepsOlderLeaseCoherentDuringControlRefresh() async throws {
    let f = try await RemoteProjectionNativeFixture.make(), client = f.client()
    let hints = RemoteProjectionNativeHints()
    let reader = Task { for await event in client.events { await hints.consume(event) } }
    do {
        #expect(f.encodedSnapshotBytes > RemoteEnvironmentProtocol.maximumFrameBytes)
        let legacy = try f.connection()
        do {
            _ = try await legacy.request(RemoteEnvironmentProtocol.snapshotMethod,
                params: RemoteEnvironmentProtocol.encode(RemoteEnvironmentSnapshotRequest(environmentID: f.environmentID)))
            Issue.record("An oversized legacy snapshot unexpectedly crossed its unchanged frame bound")
        } catch {
            await legacy.close()
            guard let error = error as? JSONRPCRemoteError else { throw error }
            #expect(error.data["kind"].string == "limitExceeded")
        }
        await legacy.close()
        let catalog = try await client.connectProjection()
        #expect(catalog.environmentID == f.environmentID && catalog.scope == .catalog)
        guard case .projects(let projects) = try await client.projectionCatalog(.init(binding: catalog, query: .projects)) else { throw CoincideError("Expected native projected project page") }
        #expect(projects.items.map(\.id) == f.snapshot.projects.map(\.id))
        guard case .threads(let threads) = try await client.projectionCatalog(.init(binding: catalog,
            query: .threads(projectID: f.thread.projectID, includeArchived: true))) else { throw CoincideError("Expected native projected conversation page") }
        #expect(threads.items.count == 1 && threads.items[0].id == f.thread.id && threads.items[0].messageCount == f.thread.messages.count)
        let binding = try await client.openProjection(scope: .thread(f.thread.id))
        let detail = try await client.projectionThread(.init(binding: binding, threadID: f.thread.id))
        #expect(try RemoteProjectionProtocol.payload(detail).count <= RemoteProjectionProtocol.maximumResultBytes)
        let configurationData = try await client.projectionDocument(detail.thread.configuration, binding: binding)
        let configuration = try JSONDecoder().decode(ProviderConfiguration.self, from: configurationData)
        #expect(configuration.workspacePath.utf8.elementsEqual(f.workspace.path.utf8))
        let commandID = UUID(), updatedDraft = "Newer remote draft remains separate 🌍\n"
        let edit = RemoteEnvironmentCommand.editThread(threadID: f.thread.id, edit: .draft(updatedDraft), expectedConfiguration: configuration)
        var cursor: UUID?, seen: [String] = [], pageCount = 0
        let expected = Dictionary(uniqueKeysWithValues: f.thread.messages.map { ($0.id, $0) })
        var changed = false
        repeat {
            let page = try await client.projectionMessages(.init(binding: binding, threadID: f.thread.id, newestFirst: false, cursor: cursor))
            #expect(try RemoteProjectionProtocol.payload(page).count <= RemoteProjectionProtocol.maximumResultBytes)
            #expect(page.binding == binding && page.offset == seen.count && page.totalCount == f.thread.messages.count)
            #expect(!page.items.isEmpty && page.complete == (page.nextCursor == nil))
            for message in page.items {
                let source = try #require(expected[message.id])
                #expect(message.role == source.role && message.createdAt == source.createdAt && message.runReference == source.runReference)
                let bytes = try await remoteProjectionText(client, binding: binding, text: message.text)
                #expect(bytes.count == source.text.utf8.count && RemoteProjectionProtocol.digest(bytes) == RemoteProjectionProtocol.digest(Data(source.text.utf8)))
                if let references = message.attachments {
                    #expect(references.kind == .attachmentReferences)
                    let attachmentData = try await client.projectionDocument(references, binding: binding)
                    #expect(try JSONDecoder().decode([ChatAttachment].self, from: attachmentData) == (source.attachments ?? []))
                } else { #expect(message.attachmentCount == 0) }
                seen.append(message.id)
            }
            pageCount += 1; cursor = page.nextCursor
            if !changed {
                let receipt = try await client.command(edit, id: commandID).receipt
                #expect(receipt.rejection == nil)
                try await remoteProjectionEventually { await hints.latest?.sequence ?? -1 >= receipt.sequence }
                let hint = try #require(await hints.latest)
                #expect(try RemoteProjectionProtocol.payload(hint).count < 2_048)
                let control = try await client.openProjection(scope: .control(f.thread.id), minimumSequence: receipt.sequence)
                let current = try await client.projectionThread(.init(binding: control, threadID: f.thread.id))
                #expect(control.sequence > binding.sequence && current.thread.draft.preview.utf8.elementsEqual(updatedDraft.utf8))
                let oldDraft = try await remoteProjectionText(client, binding: binding, text: detail.thread.draft)
                #expect(RemoteProjectionProtocol.digest(oldDraft) == RemoteProjectionProtocol.digest(Data(f.thread.draft.utf8)))
                #expect(await client.currentProjectionSequence() == control.sequence)
                _ = try await client.projectionRelease(.init(binding: control))
                changed = true
            }
        } while cursor != nil
        #expect(pageCount > 1 && seen == f.thread.messages.map(\.id) && Set(seen).count == seen.count)
        let release = try await client.projectionRelease(.init(binding: binding))
        #expect(release.released && release.binding == binding)
        await #expect(throws: RemoteProjectionFailure(.staleView)) {
            _ = try await client.projectionMessages(.init(binding: binding, threadID: f.thread.id))
        }
        #expect(await client.isConnected())
        let reopened = try await client.reconnectProjection()
        #expect(reopened.hostID != catalog.hostID && reopened.environmentID == f.environmentID)
        await #expect(throws: RemoteProjectionFailure(.staleView)) { _ = try await client.projectionCatalog(.init(binding: catalog, query: .projects)) }
        #expect(try await client.receipt(for: edit, id: commandID).receipt?.commandID == commandID)
        await #expect(throws: RemoteEnvironmentClientError(.commandAlreadyAttempted, commandID: commandID)) { _ = try await client.command(edit, id: commandID) }
        try await f.finish(client); reader.cancel(); await reader.value
    } catch { reader.cancel(); await f.failed(client); await reader.value; throw error }
}

@Test(.timeLimit(.minutes(1)))
func remoteProjectionNativeRetainsValidatedHistoryProofAndHostLocksWhileBoundingViewsAndRefusingExpiredHostBindings() async throws {
    let f = try await RemoteProjectionNativeFixture.make(oversized: false, historyProof: true), client = f.client()
    do {
        let before = try RemoteProjectionProtocol.payload(f.snapshot.conversationHistoryOperations)
        _ = try await client.connectProjection()
        let binding = try await client.openProjection(scope: .thread(f.thread.id))
        let detail = try await client.projectionThread(.init(binding: binding, threadID: f.thread.id))
        #expect(!detail.thread.submit.allowed && !detail.thread.mutateFiles.allowed && !detail.thread.openTerminal.allowed)
        let operations = try await client.projectionOperations(.init(binding: binding, threadID: f.thread.id))
        #expect(operations.items.count == 1 && operations.items[0].kind == .conversationHistory && operations.items[0].phase == "unconfirmed")
        let runs = try await client.projectionRuns(.init(binding: binding, threadID: f.thread.id))
        #expect(runs.items.count == 3 && runs.items.allSatisfy { !$0.fork.allowed && !$0.rewind.allowed })
        await #expect(throws: RemoteProjectionFailure(.invalidRequest)) {
            _ = try await client.projectionMessages(.init(binding: binding, threadID: f.thread.id, cursor: UUID()))
        }
        var views: [RemoteProjectionBinding] = []
        for _ in 0..<RemoteProjectionProtocol.maximumViews { views.append(try await client.openProjection(scope: .control(f.thread.id))) }
        await #expect(throws: RemoteProjectionFailure(.staleView)) {
            _ = try await client.projectionThread(.init(binding: binding, threadID: f.thread.id))
        }
        let recent = try #require(views.last)
        _ = try await client.projectionThread(.init(binding: recent, threadID: f.thread.id))
        _ = try await client.reconnectProjection()
        let reopened = try await client.openProjection(scope: .control(f.thread.id))
        #expect(reopened.hostID != binding.hostID && reopened.environmentID == binding.environmentID)
        await #expect(throws: RemoteProjectionFailure(.staleView)) {
            _ = try await client.projectionThread(.init(binding: recent, threadID: f.thread.id))
        }
        let database = try WorkspaceDatabase(url: f.data.appendingPathComponent("workspace.sqlite"))
        let durable = try await database.load()
        #expect(try RemoteProjectionProtocol.payload(durable.conversationHistoryOperations) == before)
        #expect(durable.threads[0].messages == f.thread.messages)
        try await f.finish(client)
    } catch { await f.failed(client); throw error }
}
