import Foundation
import Testing
@testable import CoincideCore

@Test func providerSessionsKeepClaudeInteractiveAndBackgroundOwnershipSeparate() throws {
    let json = """
    [
      {"kind":"background","id":"agent-1","sessionId":"session-1","cwd":"/project","name":"Background worker","state":"blocked","startedAt":1792790000000},
      {"kind":"interactive","sessionId":"session-2","cwd":"/project","name":"Interactive terminal","status":"running","pid":123,"startedAt":1792790000},
      {"kind":"background","id":"agent-3","sessionId":"session-3","cwd":"/project","state":"done"},
      {"kind":"background","id":"--all","sessionId":"session-4","cwd":"/project","state":"running"},
      {"kind":"background","id":"agent-5","sessionId":"session-5","cwd":"/project","state":"new-future-state"}
    ]
    """
    let rows = try ProviderSessionsService.parseClaude(Data(json.utf8))
    #expect(rows.count == 5)
    #expect(rows[0].canStop && rows[0].canReadOutput && rows[0].state == .waiting)
    #expect(!rows[1].canStop && !rows[1].canReadOutput && rows[1].state == .running)
    #expect(rows[0].updatedAt == rows[1].updatedAt)
    #expect(!rows[2].canStop && rows[2].state == .completed)
    #expect(!rows[3].canStop && rows[3].commandID == nil)
    #expect(!rows[4].canStop && rows[4].state == .unknown)
}

@Test func providerSessionsDoNotTreatSavedCodexHistoryAsACompletedOrRunningSession() throws {
    let saved = try #require(ProviderSessionsService.parseCodex(.object([
        "id": .string("saved-thread"), "preview": .string("Old prompt\nPrivate next line"),
        "status": .object(["type": .string("notLoaded")])
    ])))
    #expect(!saved.isLoaded && !saved.canStop && saved.state == .unknown)
    #expect(saved.title == "Old prompt")
    let active = try #require(ProviderSessionsService.parseCodex(.object([
        "id": .string("active-thread"), "parentThreadId": .string("parent"),
        "status": .object(["type": .string("active"), "activeFlags": .array([.string("waitingOnApproval")])])
    ])))
    #expect(active.isLoaded && active.canStop && active.state == .waiting && active.kind == "subagent")
}

@Test func providerSessionsInterruptRequiresTheExactSingleCurrentTurn() throws {
    func response(_ rows: [JSONValue]) -> JSONValue { .object(["data": .array(rows)]) }
    func turn(_ id: String, _ state: String) -> JSONValue { .object(["id": .string(id), "status": .string(state)]) }
    #expect(try ProviderSessionsService.activeTurnID(response([turn("exact-turn", "inProgress")])) == "exact-turn")
    #expect(throws: CoincideError.self) { try ProviderSessionsService.activeTurnID(response([turn("old-turn", "completed")])) }
    #expect(throws: CoincideError.self) { try ProviderSessionsService.activeTurnID(response([])) }
    #expect(throws: CoincideError.self) { try ProviderSessionsService.activeTurnID(response([turn("one", "inProgress"), turn("two", "inProgress")])) }
    #expect(throws: CoincideError.self) { try ProviderSessionsService.activeTurnID(response([turn("--all", "inProgress")])) }
}

@Test func providerSessionResumeCopyQuotesExecutableConfigAndWorkingDirectory() throws {
    let rows = try ProviderSessionsService.parseClaude(Data("""
    [{"kind":"background","id":"agent-1","sessionId":"session-1","cwd":"/tmp/a'b $(touch marker)","state":"stopped"}]
    """.utf8))
    let session = try #require(rows.first)
    let scope = ProviderSessionsScope(provider: .claude, executable: "/tmp/Claude CLI", configurationDirectory: "/tmp/claude's config")
    let command = ProviderSessionsService.resumeCommand(scope: scope, session: session)
    #expect(command == "cd -- '/tmp/a'\"'\"'b $(touch marker)' && 'env' 'CLAUDE_CONFIG_DIR=/tmp/claude'\"'\"'s config' '/tmp/Claude CLI' 'attach' 'agent-1'")
}

@Test func providerSessionSocketFramesMaskEveryClientPayloadAndEncodeExtendedLengths() {
    for count in [0, 125, 126, 65_535, 65_536] {
        let payload = Data(repeating: 0x41, count: count)
        let frame = Array(ProviderSessionsCodexConnection.clientFrame(payload))
        #expect(frame[0] == 0x81 && frame[1] & 0x80 != 0)
        let lengthBytes = frame[1] & 0x7f == 127 ? 8 : frame[1] & 0x7f == 126 ? 2 : 0
        let offset = 2 + lengthBytes
        let decoded = frame.dropFirst(offset + 4).enumerated().map { $0.element ^ frame[offset + $0.offset % 4] }
        #expect(Data(decoded) == payload)
        if lengthBytes > 0 {
            #expect(frame[2..<offset].reduce(UInt64(0)) { ($0 << 8) | UInt64($1) } == UInt64(count))
        }
    }
}

@Test func providerSessionInspectionStripsTerminalControlsAndBoundsTheDisplay() {
    #expect(ProviderSessionsService.readableOutput("\u{1b}[31mred\u{1b}[0m\nline\u{0}") == "red\nline")
    #expect(ProviderSessionsService.readableOutput(String(repeating: "x", count: 100_000)).count == 65_536)
    let unicode = ProviderSessionsService.readableOutput(String(repeating: "🦉", count: 100_000))
    #expect(unicode.utf8.count == 65_536 && !unicode.contains("�"))
    #expect(ProviderSessionsService.readableOutput("\u{1b}]8;;https://example.com\u{1b}\\link\u{1b}]8;;\u{1b}\\") == "link")
}

@Test func providerSessionMetadataIsBoundedWithoutTruncatingExecutableWorkingDirectories() throws {
    let title = "a" + String(repeating: "\u{301}", count: 10_000)
    let session = try #require(ProviderSessionsService.parseCodex(.object([
        "id": .string("fixture"), "name": .string(title), "updatedAt": .number(.greatestFiniteMagnitude),
        "cwd": .string("/fixture"), "status": .object(["type": .string("idle")])
    ])))
    #expect(session.title.utf8.count <= 1_024)
    #expect(session.updatedAt == nil)
    for invalid in ["relative/path", "/path\u{0}suffix", "/" + String(repeating: "a", count: 4_096)] {
        #expect(ProviderSessionsService.parseCodex(.object(["id": .string("fixture"), "cwd": .string(invalid)])) == nil)
        let json = try JSONEncoder().encode(JSONValue.array([.object([
            "kind": .string("interactive"), "sessionId": .string("fixture"), "cwd": .string(invalid)
        ])]))
        #expect(try ProviderSessionsService.parseClaude(json).isEmpty)
    }
}

@Test func providerSessionDetailsRevalidateInteractiveMembershipWithoutExecutingResume() async throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent("coincide-session-metadata-fixture-\(UUID())")
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }
    let executable = directory.appendingPathComponent("fixture-cli")
    let marker = directory.appendingPathComponent("unexpected-command")
    let script = """
    #!/bin/sh
    if [ "$1" = agents ] && [ "$2" = --json ] && [ "$3" = --all ]; then
        printf '%s\\n' '[]'
        exit 0
    fi
    touch unexpected-command
    exit 2
    """
    try Data(script.utf8).write(to: executable)
    try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: executable.path)
    let scope = ProviderSessionsScope(provider: .claude, executable: executable.path, workspacePath: directory.path)
    let stale = ProviderSessionSummary(provider: .claude, nativeID: "vanished-session", commandID: nil,
        title: "Fixture", directory: directory.path, kind: "interactive", state: .running, updatedAt: nil, isLoaded: true)
    await #expect(throws: CoincideError.self) { try await ProviderSessionsService.details(scope: scope, session: stale) }
    #expect(!FileManager.default.fileExists(atPath: marker.path))
}

@Test func providerSessionMissingDaemonDoesNotStartAProviderOrCreateItsDirectory() async throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent("coincide-absent-session-daemon-\(UUID())")
    #expect(!FileManager.default.fileExists(atPath: directory.path))
    let scope = ProviderSessionsScope(provider: .codex, executable: "/this-must-never-run", configurationDirectory: directory.path)
    await #expect(throws: CoincideError.self) { try await ProviderSessionsService.list(scope: scope) }
    #expect(!FileManager.default.fileExists(atPath: directory.path))
}
