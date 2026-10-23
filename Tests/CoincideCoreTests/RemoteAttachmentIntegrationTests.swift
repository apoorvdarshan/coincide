import CryptoKit
import Darwin
import Foundation
import Testing
@testable import CoincideCore

/// Native helper, production codec and SQLite; every file, Git repository and
/// executable belongs to this private fixture. No installed provider runs.
private struct RemoteAttachmentFixture: Sendable {
    let root: URL, workspace: URL, data: URL, host: URL, provider: URL, proxy: URL
    var environment: [String: String] {
        ["PATH": "/usr/bin:/bin:/usr/sbin:/sbin", "HOME": root.appendingPathComponent("home").path,
         "LANG": "en_US.UTF-8", "GIT_CONFIG_NOSYSTEM": "1", "GIT_CONFIG_SYSTEM": "/dev/null",
         "GIT_CONFIG_GLOBAL": "/dev/null", "GIT_ALLOW_PROTOCOL": "file", "GIT_TERMINAL_PROMPT": "0",
         "GCM_INTERACTIVE": "Never", "GIT_AUTHOR_NAME": "Private attachment", "GIT_COMMITTER_NAME": "Private attachment",
         "GIT_AUTHOR_EMAIL": "attachment@example.invalid", "GIT_COMMITTER_EMAIL": "attachment@example.invalid"]
    }
    var arguments: [String] {
        ["--stdio", "--data-directory", data.path, "--codex-executable", provider.path,
         "--codex-home", root.appendingPathComponent("codex-home").path]
    }
    static func quote(_ value: String) -> String { "'" + value.replacingOccurrences(of: "'", with: "'\\''") + "'" }
    static func make() throws -> Self {
        let manager = FileManager.default
        let root = manager.temporaryDirectory.appendingPathComponent("coincide-remote-attachment-\(UUID())").resolvingSymlinksInPath()
        try manager.createDirectory(at: root, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        do {
            let workspace = root.appendingPathComponent("workspace"), data = root.appendingPathComponent("data")
            for directory in [workspace, data, root.appendingPathComponent("home"), root.appendingPathComponent("codex-home")] {
                try manager.createDirectory(at: directory, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
            }
            let peer = try #require(Bundle.module.url(forResource: "remote_attachment_provider", withExtension: "py", subdirectory: "Fixtures"))
            let proxy = try #require(Bundle.module.url(forResource: "remote_attachment_proxy", withExtension: "py", subdirectory: "Fixtures"))
            #if DEBUG
            let configuration = "debug"
            #else
            let configuration = "release"
            #endif
            let checkout = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            let helper = checkout.appendingPathComponent(".build/\(configuration)/CoincideEnvironment").resolvingSymlinksInPath()
            guard manager.isExecutableFile(atPath: helper.path) else { throw CoincideError("Build the matching native helper before attachment acceptance.") }
            let host = root.appendingPathComponent("native-host"), provider = root.appendingPathComponent("offline-codex")
            for (file, content) in [
                (host, "#!/bin/sh\numask 077\nprintf '%s\\n' \"$$\" >> \(quote(root.appendingPathComponent("host-pids.txt").path))\nexec \(quote(helper.path)) \"$@\"\n"),
                (provider, "#!/bin/sh\nexec /usr/bin/python3 \(quote(peer.path)) \(quote(root.path)) \"$@\"\n")
            ] {
                try content.write(to: file, atomically: false, encoding: .utf8)
                try manager.setAttributes([.posixPermissions: 0o700], ofItemAtPath: file.path)
            }
            return .init(root: root, workspace: workspace, data: data, host: host, provider: provider, proxy: proxy)
        } catch { try? manager.removeItem(at: root); throw error }
    }
    func connection(dropMethod: String? = nil, id: UUID? = nil, waitForTurn: Bool = false) throws -> JSONRPCConnection {
        if let dropMethod, let id {
            return try .init(executable: URL(fileURLWithPath: "/usr/bin/python3"),
                arguments: [proxy.path, root.path, dropMethod, id.uuidString, waitForTurn ? "yes" : "no", host.path] + arguments,
                cwd: root, dialect: .jsonRPC2, maximumFrameSize: RemoteEnvironmentProtocol.maximumFrameBytes,
                environment: environment, drainProcessOnClose: true)
        }
        return try .init(executable: host, arguments: arguments, cwd: root, dialect: .jsonRPC2,
            maximumFrameSize: RemoteEnvironmentProtocol.maximumFrameBytes, environment: environment, drainProcessOnClose: true)
    }
    func rows(_ name: String = "provider-wire.jsonl") throws -> [JSONValue] {
        let path = root.appendingPathComponent(name)
        guard FileManager.default.fileExists(atPath: path.path) else { return [] }
        return try Data(contentsOf: path).split(separator: 10).map { try JSONDecoder().decode(JSONValue.self, from: Data($0)) }
    }
    func register(_ client: RemoteEnvironmentClient, projectID: UUID? = nil) async throws -> RemoteAttachmentTarget {
        let descriptor = try await client.discover(); try await client.trust(environmentID: descriptor.environmentID)
        _ = try await client.connect()
        let project = projectID ?? UUID(), thread = UUID()
        if projectID == nil {
            #expect(try await client.command(.addProject(id: project, path: workspace.path, title: "Private attachments")).receipt.rejection == nil)
        }
        #expect(try await client.command(.createThread(id: thread, projectID: project, provider: .codex,
            title: "Remote attachments", model: "remote-attachment-offline", permission: .supervised)).receipt.rejection == nil)
        _ = try await remoteAttachmentThread(client, thread)
        return .init(environmentID: descriptor.environmentID, projectID: project, threadID: thread)
    }
    func providerExpectation(workspace: URL? = nil, text: String, attachments: [(String, Data, Bool)]) throws {
        let value: [String: Any] = ["workspace": (workspace ?? self.workspace).path, "text": text,
            "attachments": attachments.map { ["kind": $0.2 ? "image" : "file", "name": $0.0,
                "digest": remoteAttachmentDigest($0.1), "byteCount": $0.1.count] as [String: Any] }]
        let bytes = try JSONSerialization.data(withJSONObject: value, options: [.sortedKeys])
        #expect(FileManager.default.createFile(atPath: root.appendingPathComponent("expected-provider.json").path,
            contents: bytes, attributes: [.posixPermissions: 0o600]))
    }
    @discardableResult func git(_ arguments: [String]) async throws -> String {
        let result = try await CommandRunner.run("/usr/bin/git", ["--literal-pathspecs", "-C", workspace.path] + arguments,
            timeout: .seconds(10), environment: environment)
        guard result.status == 0 else { throw CoincideError("Private attachment Git fixture failed.") }
        return result.text.trimmingCharacters(in: .newlines)
    }
    func holdWorktree() async throws {
        _ = try await git(["init", "--initial-branch=main"])
        _ = try await git(["config", "commit.gpgsign", "false"])
        try Data("Private attachment readiness\n".utf8).write(to: workspace.appendingPathComponent("README.md"))
        _ = try await git(["add", "--", "README.md"]); _ = try await git(["commit", "-m", "Private baseline"])
        let peer = root.appendingPathComponent("held-hook.py")
        let source = #"""
import json,os,signal,sys,time
from pathlib import Path
root=Path(sys.argv[1]);os.umask(0o077)
assert root.name.startswith('coincide-remote-attachment-')
signal.signal(signal.SIGTERM,lambda *_:sys.exit(130))
with (root/'hook-pids.jsonl').open('a') as out:out.write(json.dumps({'pid':os.getpid(),'gitPID':os.getppid()})+'\n')
deadline=time.monotonic()+20
while not (root/'release-hook').exists() and time.monotonic()<deadline:time.sleep(.005)
assert (root/'release-hook').exists()
"""#
        try source.write(to: peer, atomically: false, encoding: .utf8)
        let hook = workspace.appendingPathComponent(".git/hooks/post-checkout")
        try "#!/bin/sh\nexec /usr/bin/python3 \(Self.quote(peer.path)) \(Self.quote(root.path))\n".write(to: hook, atomically: false, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: hook.path)
    }
    func releaseHook() { _ = FileManager.default.createFile(atPath: root.appendingPathComponent("release-hook").path, contents: Data(), attributes: [.posixPermissions: 0o600]) }
    func finish(_ client: RemoteEnvironmentClient) async throws {
        releaseHook(); await client.close()
        var pids: [Int32] = []
        for name in ["host-pids.txt", "proxy-pids.txt"] {
            let path = root.appendingPathComponent(name)
            if FileManager.default.fileExists(atPath: path.path) {
                pids += try String(contentsOf: path, encoding: .utf8).split(whereSeparator: \.isNewline).compactMap { Int32($0) }
            }
        }
        for row in try rows() where row["kind"].string == "launch" {
            if case .number(let value) = row["pid"], let pid = Int32(exactly: value) { pids.append(pid) }
        }
        for row in try rows("hook-pids.jsonl") {
            for key in ["pid", "gitPID"] { if case .number(let value) = row[key], let pid = Int32(exactly: value) { pids.append(pid) } }
        }
        let ownedPIDs = pids
        try await remoteAttachmentEventually { ownedPIDs.allSatisfy { kill($0, 0) == -1 && errno == ESRCH } }
        try FileManager.default.removeItem(at: root)
    }
    func failed(_ client: RemoteEnvironmentClient) async {
        releaseHook(); await client.close()
        if let snapshot = await client.currentSnapshot(), let bytes = try? JSONEncoder().encode(snapshot) {
            _ = FileManager.default.createFile(atPath: root.appendingPathComponent("failed-snapshot.json").path,
                contents: bytes, attributes: [.posixPermissions: 0o600])
        }
        print("Private remote attachment fixture retained at \(root.path)")
    }
}
private final class RemoteAttachmentConnections: @unchecked Sendable {
    let fixture: RemoteAttachmentFixture, dropMethod: String?, droppedID: UUID?, waitForTurn: Bool
    private let lock = NSLock()
    private var count = 0
    private var latest: JSONRPCConnection?
    init(_ fixture: RemoteAttachmentFixture, dropMethod: String? = nil, id: UUID? = nil, waitForTurn: Bool = false) {
        self.fixture = fixture; self.dropMethod = dropMethod; droppedID = id; self.waitForTurn = waitForTurn
    }
    func make() throws -> JSONRPCConnection {
        try lock.withLock {
            let value = try fixture.connection(dropMethod: count == 0 ? dropMethod : nil,
                id: droppedID, waitForTurn: waitForTurn)
            count += 1; latest = value; return value
        }
    }
    func current() throws -> JSONRPCConnection { try lock.withLock { try #require(latest) } }
}
private func remoteAttachmentDigest(_ data: Data) -> String { SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined() }
private func remoteAttachmentEventually(_ predicate: @escaping @Sendable () async throws -> Bool) async throws {
    let deadline = ContinuousClock.now + .seconds(12)
    while try await !predicate() {
        guard ContinuousClock.now < deadline else { throw CoincideError("Native attachment fixture did not reach its owned boundary.") }
        try await Task.sleep(for: .milliseconds(10))
    }
}
private func remoteAttachmentThread(_ client: RemoteEnvironmentClient, _ id: UUID) async throws -> CodingThread {
    try #require(await client.snapshot().workspace.threads.first { $0.id == id })
}
private func remoteAttachmentRPC<Request: Encodable & Sendable, Response: Decodable & Sendable>(
    _ connections: RemoteAttachmentConnections, _ method: String, _ request: Request, as: Response.Type
) async throws -> Response {
    try RemoteEnvironmentProtocol.decode(Response.self, from: await connections.current().request(method,
        params: RemoteEnvironmentProtocol.encode(request), timeout: .seconds(5)))
}
private func remoteAttachmentUpload(_ client: RemoteEnvironmentClient, target: RemoteAttachmentTarget,
                                    bytes: Data, name: String, id: UUID = UUID()) async throws -> RemoteAttachmentUpload {
    let request = RemoteAttachmentUploadRequest(id: id, target: target, name: name, byteCount: bytes.count, digest: remoteAttachmentDigest(bytes))
    _ = try await client.beginAttachmentUpload(request)
    for (index, offset) in stride(from: 0, to: bytes.count, by: RemoteAttachmentProtocol.maximumChunkBytes).enumerated() {
        let chunk = bytes.subdata(in: offset..<min(offset + RemoteAttachmentProtocol.maximumChunkBytes, bytes.count))
        _ = try await client.appendAttachmentChunk(.init(upload: request, index: index, data: chunk, digest: remoteAttachmentDigest(chunk)))
    }
    return try await client.finalizeAttachmentUpload(request)
}
private func remoteAttachmentDownload(_ client: RemoteEnvironmentClient, target: RemoteAttachmentTarget,
                                      reference: ChatAttachment) async throws -> Data {
    var bytes = Data()
    repeat {
        let result = try await client.downloadAttachment(.init(target: target, attachmentID: reference.id, offset: bytes.count, maxBytes: 65_537))
        #expect(result.target == target && result.attachment == reference && result.offset == bytes.count)
        #expect(result.data.count <= 65_537 && result.eof == (bytes.count + result.data.count == reference.byteCount))
        bytes.append(result.data)
        if result.eof { break }
        #expect(!result.data.isEmpty)
        guard !result.data.isEmpty else { throw CoincideError("Native attachment download made no progress.") }
    } while bytes.count <= reference.byteCount
    #expect(bytes.count == reference.byteCount && remoteAttachmentDigest(bytes) == reference.digest)
    return bytes
}

@Test(.timeLimit(.minutes(1)))
func remoteAttachmentNativeHostReordersChunksResumesAfterRestartAndKeepsExactImmutablePrivateCopies() async throws {
    let f = try RemoteAttachmentFixture.make(), connections = RemoteAttachmentConnections(f)
    let client = RemoteEnvironmentClient(factory: { try connections.make() })
    do {
        let target = try await f.register(client), size = RemoteAttachmentProtocol.maximumChunkBytes
        var bytes = Data(repeating: 0xa7, count: size * 2); bytes.append(Data("Exact binary tail\0🌍".utf8))
        let source = f.root.appendingPathComponent("original-source.bin"); try bytes.write(to: source)
        let request = RemoteAttachmentUploadRequest(target: target, name: "Exact 🌍.bin", byteCount: bytes.count, digest: remoteAttachmentDigest(bytes))
        let begun = try await client.beginAttachmentUpload(request)
        #expect(begun.state == .receiving && begun.receivedChunks.isEmpty)
        #expect(try await client.beginAttachmentUpload(request) == begun)
        let collision = RemoteAttachmentUploadRequest(id: request.id, target: target, name: "changed.bin", byteCount: bytes.count, digest: request.digest)
        await #expect(throws: (any Error).self) {
            _ = try await remoteAttachmentRPC(connections, RemoteAttachmentProtocol.beginMethod, collision, as: RemoteAttachmentUpload.self)
        }
        let tail = bytes.subdata(in: size * 2..<bytes.count)
        let last = RemoteAttachmentChunkRequest(upload: request, index: 2, data: tail, digest: remoteAttachmentDigest(tail))
        let reordered = try await client.appendAttachmentChunk(last)
        #expect(reordered.receivedChunks == [2])
        #expect(try await client.appendAttachmentChunk(last) == reordered)
        var changed = tail; changed[changed.startIndex] ^= 1
        await #expect(throws: (any Error).self) {
            _ = try await remoteAttachmentRPC(connections, RemoteAttachmentProtocol.appendMethod,
                RemoteAttachmentChunkRequest(upload: request, index: 2, data: changed, digest: remoteAttachmentDigest(changed)), as: RemoteAttachmentUpload.self)
        }
        _ = try await client.reconnect()
        #expect(try await client.attachmentUploadStatus(request)?.receivedChunks == [2])
        for index in [1, 0] {
            let chunk = bytes.subdata(in: index * size..<(index + 1) * size)
            _ = try await client.appendAttachmentChunk(.init(upload: request, index: index, data: chunk, digest: remoteAttachmentDigest(chunk)))
        }
        let finalized = try await client.finalizeAttachmentUpload(request), reference = try #require(finalized.attachment)
        #expect(finalized.state == .ready && reference.byteCount == bytes.count && reference.digest == request.digest)
        #expect(try await client.finalizeAttachmentUpload(request).attachment == reference)
        try Data("Changed original".utf8).write(to: source); try FileManager.default.removeItem(at: source)
        #expect(try await remoteAttachmentDownload(client, target: target, reference: reference) == bytes)
        _ = try await client.reconnect()
        #expect(try await client.attachmentUploadStatus(request)?.attachment == reference)
        #expect(try await remoteAttachmentDownload(client, target: target, reference: reference) == bytes)
        let saved = f.data.appendingPathComponent("Attachments").appendingPathComponent(reference.id.uuidString + "." + reference.fileExtension)
        #expect(try FileManager.default.attributesOfItem(atPath: saved.path)[.posixPermissions] as? Int == 0o600)
        #expect(try f.rows().isEmpty)
        try await f.finish(client)
    } catch { await f.failed(client); throw error }
}

@Test(.timeLimit(.minutes(1)))
func remoteAttachmentNativeHostRefusesInvalidChunksLimitsAndForeignDownloadsAndPersistsCancellation() async throws {
    let f = try RemoteAttachmentFixture.make(), connections = RemoteAttachmentConnections(f)
    let client = RemoteEnvironmentClient(factory: { try connections.make() })
    do {
        let target = try await f.register(client)
        for count in [-1, AttachmentLimits.fileBytes + 1] {
            let invalid = RemoteAttachmentUploadRequest(target: target, name: "invalid.bin", byteCount: count, digest: String(repeating: "0", count: 64))
            await #expect(throws: (any Error).self) {
                _ = try await remoteAttachmentRPC(connections, RemoteAttachmentProtocol.beginMethod, invalid, as: RemoteAttachmentUpload.self)
            }
        }
        let bytes = Data(repeating: 0x53, count: RemoteAttachmentProtocol.maximumChunkBytes + 1)
        let request = RemoteAttachmentUploadRequest(target: target, name: "cancel.bin", byteCount: bytes.count, digest: remoteAttachmentDigest(bytes))
        _ = try await client.beginAttachmentUpload(request)
        let chunk = bytes.prefix(RemoteAttachmentProtocol.maximumChunkBytes)
        for invalid in [
            RemoteAttachmentChunkRequest(upload: request, index: -1, data: Data(chunk), digest: remoteAttachmentDigest(Data(chunk))),
            RemoteAttachmentChunkRequest(upload: request, index: 0, data: bytes, digest: remoteAttachmentDigest(bytes)),
            RemoteAttachmentChunkRequest(upload: request, index: 0, data: Data(chunk), digest: String(repeating: "0", count: 64))
        ] {
            await #expect(throws: (any Error).self) {
                _ = try await remoteAttachmentRPC(connections, RemoteAttachmentProtocol.appendMethod, invalid, as: RemoteAttachmentUpload.self)
            }
        }
        #expect(try await client.attachmentUploadStatus(request)?.receivedChunks.isEmpty == true)
        _ = try await client.appendAttachmentChunk(.init(upload: request, index: 0, data: Data(chunk), digest: remoteAttachmentDigest(Data(chunk))))
        await #expect(throws: (any Error).self) {
            _ = try await remoteAttachmentRPC(connections, RemoteAttachmentProtocol.finalizeMethod, request, as: RemoteAttachmentUpload.self)
        }
        #expect(try await client.cancelAttachmentUpload(request)?.state == .cancelled)
        #expect(try await client.cancelAttachmentUpload(request)?.state == .cancelled)
        _ = try await client.reconnect()
        #expect(try await client.attachmentUploadStatus(request)?.state == .cancelled)
        await #expect(throws: (any Error).self) {
            _ = try await remoteAttachmentRPC(connections, RemoteAttachmentProtocol.finalizeMethod, request, as: RemoteAttachmentUpload.self)
        }
        let complete = try await remoteAttachmentUpload(client, target: target, bytes: Data("Owned download".utf8), name: "owned.txt")
        let reference = try #require(complete.attachment)
        let foreign = try await f.register(client, projectID: target.projectID)
        for download in [
            RemoteAttachmentDownloadRequest(target: foreign, attachmentID: reference.id, offset: 0),
            RemoteAttachmentDownloadRequest(target: target, attachmentID: UUID(), offset: 0),
            RemoteAttachmentDownloadRequest(target: target, attachmentID: reference.id, offset: -1),
            RemoteAttachmentDownloadRequest(target: target, attachmentID: reference.id, offset: 0, maxBytes: RemoteAttachmentProtocol.maximumChunkBytes + 1)
        ] {
            await #expect(throws: (any Error).self) {
                _ = try await remoteAttachmentRPC(connections, RemoteAttachmentProtocol.downloadMethod, download, as: RemoteAttachmentDownloadResult.self)
            }
        }
        let outside = f.root.appendingPathComponent("outside-private.txt"); try Data("Must never be downloaded".utf8).write(to: outside)
        let saved = f.data.appendingPathComponent("Attachments").appendingPathComponent(reference.id.uuidString + "." + reference.fileExtension)
        try FileManager.default.removeItem(at: saved); try FileManager.default.createSymbolicLink(at: saved, withDestinationURL: outside)
        await #expect(throws: (any Error).self) {
            _ = try await remoteAttachmentRPC(connections, RemoteAttachmentProtocol.downloadMethod,
                RemoteAttachmentDownloadRequest(target: target, attachmentID: reference.id, offset: 0), as: RemoteAttachmentDownloadResult.self)
        }
        #expect(try Data(contentsOf: outside) == Data("Must never be downloaded".utf8))
        #expect(try f.rows().isEmpty)
        try await f.finish(client)
    } catch { await f.failed(client); throw error }
}

@Test(.timeLimit(.minutes(1)))
func remoteAttachmentNativeHostLostFinalizeReplyRecoversTheSamePublishedReferenceWithoutRecopying() async throws {
    let f = try RemoteAttachmentFixture.make(), id = UUID()
    let connections = RemoteAttachmentConnections(f, dropMethod: RemoteAttachmentProtocol.finalizeMethod, id: id)
    let client = RemoteEnvironmentClient(factory: { try connections.make() })
    do {
        let target = try await f.register(client), bytes = try attachmentImageData()
        let request = RemoteAttachmentUploadRequest(id: id, target: target, name: "Copied blue.png", byteCount: bytes.count, digest: remoteAttachmentDigest(bytes))
        _ = try await client.beginAttachmentUpload(request)
        _ = try await client.appendAttachmentChunk(.init(upload: request, index: 0, data: bytes, digest: request.digest))
        await #expect(throws: (any Error).self) { _ = try await client.finalizeAttachmentUpload(request) }
        let frame = try JSONDecoder().decode(JSONValue.self, from: Data(contentsOf: f.root.appendingPathComponent("dropped-response.json")))
        let committed = try RemoteEnvironmentProtocol.decode(RemoteAttachmentUpload.self, from: frame["result"])
        let reference = try #require(committed.attachment)
        #expect(committed.state == .ready && reference.isImage && reference.digest == request.digest)
        _ = try await client.reconnect()
        #expect(try await client.attachmentUploadStatus(request)?.attachment == reference)
        #expect(try await client.finalizeAttachmentUpload(request).attachment == reference)
        #expect(try await remoteAttachmentDownload(client, target: target, reference: reference) == bytes)
        let copies = try FileManager.default.contentsOfDirectory(at: f.data.appendingPathComponent("Attachments"), includingPropertiesForKeys: nil)
        #expect(copies.count == 1 && copies[0].lastPathComponent.hasPrefix(reference.id.uuidString))
        #expect(try f.rows().isEmpty)
        try await f.finish(client)
    } catch { await f.failed(client); throw error }
}

private func remoteAttachmentRejected(_ client: RemoteEnvironmentClient, _ command: RemoteEnvironmentCommand) async throws {
    #expect(try await client.command(command).receipt.rejection != nil)
}

@Test(.timeLimit(.minutes(1)))
func remoteAttachmentNativeHostRejectsStaleOwnershipAndDraftAtomicallyThenRecoversLostSubmitWithoutReplay() async throws {
    let f = try RemoteAttachmentFixture.make(), commandID = UUID()
    let connections = RemoteAttachmentConnections(f, dropMethod: RemoteEnvironmentProtocol.commandMethod, id: commandID, waitForTurn: true)
    let client = RemoteEnvironmentClient(factory: { try connections.make() })
    do {
        let target = try await f.register(client), image = try attachmentImageData(), note = Data("Private copied attachment.\0🌍".utf8)
        let imageUpload = try await remoteAttachmentUpload(client, target: target, bytes: image, name: "blue.png")
        let fileUpload = try await remoteAttachmentUpload(client, target: target, bytes: note, name: "note 🌍.txt")
        let imageRef = try #require(imageUpload.attachment), fileRef = try #require(fileUpload.attachment)
        let references = [imageRef, fileRef], ids = references.map(\.id)
        let current = try await remoteAttachmentThread(client, target.threadID), configuration = ProviderConfiguration(thread: current)
        let draft = "Preserve exact draft e\u{301} 🧪"
        #expect(try await client.command(.editThread(threadID: target.threadID, edit: .draft(draft), expectedConfiguration: configuration)).receipt.rejection == nil)
        var changed = configuration; changed.model = "stale-model"
        try await remoteAttachmentRejected(client, .submitWithAttachments(target: target, text: "Must not run", expectedConfiguration: changed,
            expectedDraftAttachments: [], uploadedAttachmentIDs: ids))
        try await remoteAttachmentRejected(client, .submitWithAttachments(target: target, text: "Must not run", expectedConfiguration: configuration,
            expectedDraftAttachments: [fileRef], uploadedAttachmentIDs: ids))
        try await remoteAttachmentRejected(client, .submitWithAttachments(target: target, text: "Must not run", expectedConfiguration: configuration,
            expectedDraftAttachments: [], uploadedAttachmentIDs: [imageRef.id, imageRef.id]))
        let foreign = try await f.register(client, projectID: target.projectID), foreignThread = try await remoteAttachmentThread(client, foreign.threadID)
        try await remoteAttachmentRejected(client, .submitWithAttachments(target: foreign, text: "Must not run", expectedConfiguration: .init(thread: foreignThread),
            expectedDraftAttachments: [], uploadedAttachmentIDs: ids))
        let refused = try await remoteAttachmentThread(client, target.threadID)
        #expect(refused.draft.utf8.elementsEqual(draft.utf8) && refused.draftAttachments.isEmpty && refused.queuedTurns.isEmpty && refused.messages.isEmpty && refused.activeRun == nil)
        #expect(try await client.attachmentUploadStatus(imageUpload.request)?.state == .ready)
        #expect(try await client.attachmentUploadStatus(fileUpload.request)?.state == .ready)
        #expect(try f.rows().isEmpty)
        let text = "Remote attachment response lost"
        try f.providerExpectation(text: text, attachments: [("blue.png", image, true), ("note 🌍.txt", note, false)])
        let submit = RemoteEnvironmentCommand.submitWithAttachments(target: target, text: text, expectedConfiguration: configuration,
            expectedDraftAttachments: [], uploadedAttachmentIDs: ids)
        await #expect(throws: RemoteEnvironmentClientError(.commandUncertain, commandID: commandID)) { _ = try await client.command(submit, id: commandID) }
        let dropped = try JSONDecoder().decode(JSONValue.self, from: Data(contentsOf: f.root.appendingPathComponent("dropped-response.json")))
        let committed = try RemoteEnvironmentProtocol.decode(RemoteEnvironmentCommandResult.self, from: dropped["result"])
        #expect(committed.receipt.commandID == commandID && committed.receipt.rejection == nil)
        _ = try await client.reconnect()
        #expect(try await client.receipt(for: submit, id: commandID).receipt == committed.receipt)
        await #expect(throws: RemoteEnvironmentClientError(.commandAlreadyAttempted, commandID: commandID)) { _ = try await client.command(submit, id: commandID) }
        let recovered = try await remoteAttachmentThread(client, target.threadID)
        #expect(recovered.messages.filter { $0.role == .user }.count == 1)
        #expect(recovered.messages.first { $0.role == .user }?.attachments == references)
        #expect(recovered.draft.isEmpty && recovered.draftAttachments.isEmpty && recovered.queuedTurns.isEmpty)
        #expect(try f.rows().filter { $0["kind"].string == "turn" }.count == 1)
        for upload in [imageUpload, fileUpload] {
            #expect(try await client.attachmentUploadStatus(upload.request)?.state == .claimed)
            #expect(try await client.cancelAttachmentUpload(upload.request)?.state == .claimed)
        }
        #expect(try await remoteAttachmentDownload(client, target: target, reference: imageRef) == image)
        #expect(try await remoteAttachmentDownload(client, target: target, reference: fileRef) == note)
        try await f.finish(client)
    } catch { await f.failed(client); throw error }
}

@Test(.timeLimit(.minutes(1)))
func remoteAttachmentNativeHostQueuesAttachmentOnlyInputUntilWorktreeReadyAndClaimsProtectCleanup() async throws {
    let f = try RemoteAttachmentFixture.make(), connections = RemoteAttachmentConnections(f)
    let client = RemoteEnvironmentClient(factory: { try connections.make() })
    do {
        try await f.holdWorktree()
        let target = try await f.register(client), initial = try await remoteAttachmentThread(client, target.threadID)
        let workspace = try await client.bindWorkspace(.init(environmentID: target.environmentID, projectID: target.projectID,
            threadID: target.threadID, configuration: .init(thread: initial)))
        let catalog = try await client.worktreeCatalog(target: workspace)
        #expect(try await client.command(.prepareWorktree(target: workspace, sourceRootID: catalog.sourceRootID, expectedAttemptID: catalog.attemptID,
            selection: .createBranch(name: "attachment-ready", baseRef: "HEAD"), submodules: .none)).receipt.rejection == nil)
        try await remoteAttachmentEventually { try !f.rows("hook-pids.jsonl").isEmpty }
        let preparing = try await remoteAttachmentThread(client, target.threadID), preparation = try #require(preparing.workspacePreparation)
        #expect(!preparation.isReady)
        let image = try attachmentImageData(), note = Data("Attachment-only input waits for readiness.\n".utf8)
        let imageUpload = try await remoteAttachmentUpload(client, target: target, bytes: image, name: "ready.png")
        let fileUpload = try await remoteAttachmentUpload(client, target: target, bytes: note, name: "ready.txt")
        let imageRef = try #require(imageUpload.attachment), fileRef = try #require(fileUpload.attachment)
        let references = [imageRef, fileRef]
        let command = RemoteEnvironmentCommand.submitWithAttachments(target: target, text: "", expectedConfiguration: .init(thread: preparing),
            expectedDraftAttachments: [], uploadedAttachmentIDs: references.map(\.id))
        #expect(try await client.command(command).receipt.rejection == nil)
        let queued = try await remoteAttachmentThread(client, target.threadID)
        #expect(queued.activeRun == nil && queued.queuedTurns.count == 1 && queued.queuedTurns[0].text.isEmpty)
        #expect(queued.queuedTurns[0].attachments == references && queued.draftAttachments.isEmpty)
        #expect(try f.rows().isEmpty)
        #expect(try await client.cancelAttachmentUpload(imageUpload.request)?.state == .claimed)
        #expect(try await client.cancelAttachmentUpload(fileUpload.request)?.state == .claimed)
        try f.providerExpectation(workspace: URL(fileURLWithPath: preparation.destinationPath), text: "",
            attachments: [("ready.png", image, true), ("ready.txt", note, false)])
        f.releaseHook()
        try await remoteAttachmentEventually {
            let thread = try await remoteAttachmentThread(client, target.threadID)
            return thread.workspacePreparation?.isReady == true && thread.activeRun == nil &&
                thread.messages.contains { $0.role == .assistant && $0.text == "REMOTE_ATTACHMENTS_✓" }
        }
        let completed = try await remoteAttachmentThread(client, target.threadID)
        #expect(completed.queuedTurns.isEmpty && completed.messages.filter { $0.role == .user }.count == 1)
        #expect(completed.messages.first { $0.role == .user }?.attachments == references)
        #expect(try f.rows().filter { $0["kind"].string == "turn" }.count == 1)
        _ = try await client.reconnect()
        #expect(try await client.attachmentUploadStatus(imageUpload.request)?.state == .claimed)
        #expect(try await client.cancelAttachmentUpload(fileUpload.request)?.state == .claimed)
        #expect(try await remoteAttachmentDownload(client, target: target, reference: imageRef) == image)
        #expect(try await remoteAttachmentDownload(client, target: target, reference: fileRef) == note)
        #expect(try f.rows().filter { $0["kind"].string == "turn" }.count == 1)
        try await f.finish(client)
    } catch { await f.failed(client); throw error }
}
