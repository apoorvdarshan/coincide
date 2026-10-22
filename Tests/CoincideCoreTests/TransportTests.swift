import Foundation
import Testing
@testable import CoincideCore

func fixtureConnection(_ mode: String) throws -> JSONRPCConnection {
    let file = Bundle.module.url(forResource: "rpc_server", withExtension: "py", subdirectory: "Fixtures")!
    return try JSONRPCConnection(executable: URL(fileURLWithPath: "/usr/bin/python3"), arguments: [file.path, mode])
}

@Test func fragmentedUnicodeAndTrailingFrames() throws {
    var decoder = NDJSONDecoder()
    let data = Data("{\"text\":\"🌍\"}\r\n\n{\"id\":2}".utf8)
    var values: [JSONValue] = []
    for byte in data { values += try decoder.append(Data([byte])) }
    values += try decoder.finish()
    #expect(values == [.object(["text": .string("🌍")]), .object(["id": .number(2)])])
}

@Test func frameLimitAndInvalidJSONFail() throws {
    var limited = NDJSONDecoder(maximumFrameSize: 5)
    #expect(throws: (any Error).self) { try limited.append(Data("123456".utf8)) }
    var invalid = NDJSONDecoder()
    #expect(throws: (any Error).self) { try invalid.append(Data("invalid\n".utf8)) }
}

@Test func concurrentRequestsMatchOutOfOrderResponses() async throws {
    let rpc = try fixtureConnection("reverse")
    async let first = rpc.request("echo", params: .string("first"))
    async let second = rpc.request("echo", params: .string("second"))
    let values = try await [first, second]
    #expect(values == [.string("first"), .string("second")])
    await rpc.close()
}

@Test func timeoutDisconnectAndMalformedResponseReleaseWaiters() async throws {
    for mode in ["hang", "exit", "malformed"] {
        let rpc = try fixtureConnection(mode)
        await #expect(throws: (any Error).self) {
            try await rpc.request("echo", timeout: .milliseconds(200))
        }
        await rpc.close()
    }
}

@Test func cancellationReleasesPendingRequest() async throws {
    let rpc = try fixtureConnection("hang")
    let task = Task { try await rpc.request("never") }
    task.cancel()
    await #expect(throws: CancellationError.self) { try await task.value }
    await rpc.close()
}

@Test(.timeLimit(.minutes(1))) func eventBarriersReleaseWhenCancelledOrTheConnectionCloses() async throws {
    let rpc = try fixtureConnection("hang")
    let cancelled = Task { await rpc.flushEvents() }
    try await Task.sleep(for: .milliseconds(20)); cancelled.cancel(); await cancelled.value
    let closed = Task { await rpc.flushEvents() }
    try await Task.sleep(for: .milliseconds(20)); await rpc.close(); await closed.value
}

@Test func processDrainsBothLargePipesAndPreservesExitCode() async throws {
    let result = try await CommandRunner.run("/usr/bin/python3", ["-c", "import sys; sys.stdout.write('x'*200000); sys.stderr.write('y'*200000); sys.exit(7)"])
    #expect(result.output.count == 200_000); #expect(result.error.count == 200_000); #expect(result.status == 7)
}

@Test func processTimeoutAndOutputLimitTerminateChild() async throws {
    await #expect(throws: (any Error).self) {
        try await CommandRunner.run("/usr/bin/python3", ["-c", "import time; time.sleep(10)"], timeout: .milliseconds(100))
    }
    await #expect(throws: (any Error).self) {
        try await CommandRunner.run("/usr/bin/python3", ["-c", "print('x'*100000)"], limit: 100)
    }
}

@Test func codexHandshakeApprovalStreamingAndCompletion() async throws {
    let fixture = Bundle.module.url(forResource: "rpc_server", withExtension: "py", subdirectory: "Fixtures")!
    let cwd = FileManager.default.temporaryDirectory
    let session = try CodexSession(executable: URL(fileURLWithPath: "/usr/bin/python3"), cwd: cwd, arguments: [fixture.path, "codex"])
    let models = try await session.models()
    #expect(models == [ProviderModel(id: "fixture-model", name: "Fixture Model", catalogID: "fixture")])
    let observer = Task {
        var text = "", approved = false, completed = false
        for await event in session.events {
            switch event {
            case .approval(let request): try await session.respond(request, allow: true); approved = true
            case .delta(_, _, let delta): text += delta
            case .completed(let state): completed = state == .idle; return (text, approved, completed)
            case .failure(let message): throw CoincideError(message)
            default: break
            }
        }
        return (text, approved, completed)
    }
    var thread = CodingThread(project: WorkspaceProject(path: cwd.path)); thread.model = "fixture-model"
    try await session.send(text: "test", thread: thread)
    let result = try await observer.value
    #expect(result.0 == "hello 🌍"); #expect(result.1); #expect(result.2)
    await session.close()
}

@Test(.enabled(if: ProcessInfo.processInfo.environment["COINCIDE_LIVE_CODEX"] == "1"))
func installedCodexHandshakeAndModelDiscovery() async throws {
    let executable = try #require(ProcessChannel.findExecutable("codex"))
    let session = try CodexSession(executable: executable, cwd: FileManager.default.temporaryDirectory)
    do {
        let models = try await session.models()
        #expect(!models.isEmpty)
        #expect(models.allSatisfy { !$0.id.isEmpty })
        let defaults = try await session.codexDefaultModelSelection()
        try defaults.validate()
        #expect(defaults.workspacePath == FileManager.default.temporaryDirectory.standardizedFileURL.resolvingSymlinksInPath().path)
        if let row = defaults.catalogModel, !row.reasoningEfforts.isEmpty {
            #expect(row.id == defaults.model)
            #expect(row.reasoningEfforts.contains { $0.id == defaults.reasoningEffort })
        }
        await session.close()
    } catch { await session.close(); throw error }
}
