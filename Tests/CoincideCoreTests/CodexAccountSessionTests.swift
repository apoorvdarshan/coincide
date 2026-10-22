import Foundation
import Testing
@testable import CoincideCore

private struct AccountPeer {
    let root: URL
    let wire: URL
    let session: CodexSession
    init(_ options: [String: JSONValue]) throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("coincide-account-\(UUID())", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        let config = root.appendingPathComponent("options.json")
        try JSONEncoder().encode(JSONValue.object(options)).write(to: config)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: config.path)
        wire = root.appendingPathComponent("wire.jsonl")
        let fixture = try #require(Bundle.module.url(forResource: "codex_account", withExtension: "py", subdirectory: "Fixtures"))
        session = try CodexSession(executable: URL(fileURLWithPath: "/usr/bin/python3"), cwd: root,
                                  arguments: [fixture.path, config.path, wire.path])
    }
    func frames() throws -> [JSONValue] {
        guard FileManager.default.fileExists(atPath: wire.path) else { return [] }
        return try Data(contentsOf: wire).split(separator: 10).map { try JSONDecoder().decode(JSONValue.self, from: Data($0)) }
    }
}

private func withAccountPeer(_ options: [String: JSONValue] = [:], _ operation: (AccountPeer) async throws -> Void) async throws {
    let peer = try AccountPeer(options)
    do { try await operation(peer); await peer.session.close(); try FileManager.default.removeItem(at: peer.root) }
    catch { await peer.session.close(); try? FileManager.default.removeItem(at: peer.root); throw error }
}

private func accountReply(_ type: String?, email: String = "offline@example.invalid") -> JSONValue {
    var account: [String: JSONValue] = ["type": .string(type ?? "")]
    if type == "chatgpt" { account["email"] = .string(email); account["planType"] = .string("pro") }
    return .object(["account": type == nil ? .null : .object(account), "requiresOpenaiAuth": .bool(true)])
}

@Test(.timeLimit(.minutes(1)))
func codexAccountReadsExistingCLIIdentityAndAllowanceWithoutLoginOrConversationMutations() async throws {
    try await withAccountPeer { peer in
        let snapshot = try await peer.session.codexAccountSnapshot()
        #expect(snapshot.identity.kind == .chatgpt && snapshot.identity.planType == "pro")
        #expect(snapshot.identity.email == "offline@example.invalid" && !snapshot.usage.isStale)
        let bucket = try #require(snapshot.usage.buckets.first)
        #expect(bucket.id == "codex" && bucket.primary?.usedPercent == 25 && bucket.secondary?.usedPercent == 40)
        let frames = try peer.frames()
        #expect(frames.map { $0["method"].string ?? "" } == ["initialize", "initialized", "account/read", "account/rateLimits/read", "account/read"])
        #expect(frames.filter { $0["method"] == .string("account/read") }.allSatisfy { $0["params"] == .object(["refreshToken": .bool(false)]) })
    }
}

@Test(.timeLimit(.minutes(1)), arguments: ["signedOut", "apiKey", "amazonBedrock", "future-auth-mode"])
func codexAccountNeverRequestsChatGPTAllowanceForOtherAuthenticationKinds(kind: String) async throws {
    let account = accountReply(kind == "signedOut" ? nil : kind)
    try await withAccountPeer(["accounts": .array([account])]) { peer in
        let snapshot = try await peer.session.codexAccountSnapshot()
        #expect(snapshot.usage == .unsupported)
        #expect(snapshot.identity.kind != .chatgpt)
        #expect(try peer.frames().filter { $0["method"] == .string("account/read") }.count == 2)
        #expect(try !peer.frames().contains { $0["method"] == .string("account/rateLimits/read") })
    }
}

@Test(.timeLimit(.minutes(1)), arguments: [-32601, -32602, 401, -32000])
func codexAccountDistinguishesUnsupportedLimitsFromFailedProbes(code: Int) async throws {
    try await withAccountPeer(["usageErrorCode": .number(Double(code))]) { peer in
        let snapshot = try await peer.session.codexAccountSnapshot()
        #expect(snapshot.identity.kind == .chatgpt)
        #expect(snapshot.usage == (code == -32601 || code == -32602 ? .unsupported : .probeFailed(previous: nil)))
        #expect(try peer.frames().filter { $0["method"] == .string("account/read") }.count == 2)
    }
}

@Test(.timeLimit(.minutes(1)), arguments: ["changedIdentity", "accountNotice", "malformedNotice", "accountRPC", "malformedAccount", "disconnected"])
func codexAccountRefusesMixedIdentityInvalidAccountAndPrivateRemoteErrors(kind: String) async throws {
    var options: [String: JSONValue] = [:]
    if kind == "changedIdentity" {
        let a = accountReply("chatgpt"), b = accountReply("chatgpt", email: "other@example.invalid")
        options["accounts"] = .array([a, b, a, b])
    }
    if kind == "accountNotice" || kind == "malformedNotice" {
        options["updatesBeforeFinalAccount"] = .array([.object(["method": .string("account/updated"),
            "params": kind == "accountNotice" ? .object(["authMode": .string("chatgpt"), "planType": .string("pro")]) : .string("synthetic-private-token")])])
    }
    if kind == "accountRPC" { options["accountErrorCode"] = .number(-32000) }
    if kind == "malformedAccount" { options["accounts"] = .array([.object(["account": .string("synthetic-private-token")])]) }
    if kind == "disconnected" { options["exitDuringUsage"] = .bool(true) }
    try await withAccountPeer(options) { peer in
        do { _ = try await peer.session.codexAccountSnapshot(); Issue.record("An unproven account observation was accepted.") }
        catch is CancellationError { Issue.record("A provider error was classified as caller cancellation.") }
        catch { #expect(error.localizedDescription == "The Codex account could not be refreshed. Check the CLI sign-in and try again.") }
    }
}

@Test(.timeLimit(.minutes(1)))
func codexAccountStartupNoticeDiscardsOneObservationThenReadsAStableIdentityWithoutReconnecting() async throws {
    let notice: JSONValue = .object(["method": .string("account/updated"),
                                    "params": .object(["authMode": .string("chatgpt"), "planType": .string("pro")])])
    try await withAccountPeer(["updatesAfterFirstAccount": .array([notice])]) { peer in
        let snapshot = try await peer.session.codexAccountSnapshot()
        #expect(snapshot.identity.kind == .chatgpt && snapshot.usage.buckets.count == 1)
        let frames = try peer.frames()
        #expect(frames.filter { $0["method"] == .string("initialize") }.count == 1)
        #expect(frames.filter { $0["method"] == .string("account/read") }.count == 4)
        #expect(frames.filter { $0["method"] == .string("account/rateLimits/read") }.count == 2)
    }
}

@Test(.timeLimit(.minutes(1)))
func codexAccountSparseNotificationsAreOrderedAfterFullResponseAndPreserveOtherWindows() async throws {
    let notice: (String, JSONValue) -> JSONValue = { method, params in .object(["method": .string(method), "params": params]) }
    let before = notice("account/rateLimits/updated", .object(["rateLimits": .object(["limitId": .string("codex"),
        "primary": .object(["usedPercent": .number(99)])])]))
    let primary = notice("account/rateLimits/updated", .object(["rateLimits": .object(["limitId": .string("codex"),
        "primary": .object(["usedPercent": .number(31), "windowDurationMins": .number(300), "resetsAt": .number(1_800_000_010)])])]))
    let spark = notice("account/rateLimits/updated", .object(["rateLimits": .object(["limitId": .string("codex_spark"),
        "primary": .object(["usedPercent": .number(12)])])]))
    try await withAccountPeer(["updatesBeforeUsage": .array([before]), "updatesAfterUsage": .array([primary]),
                               "updatesBeforeFinalAccount": .array([spark])]) { peer in
        let snapshot = try await peer.session.codexAccountSnapshot()
        let codex = try #require(snapshot.usage.buckets.first { $0.id == "codex" })
        #expect(codex.primary?.usedPercent == 31 && codex.secondary?.usedPercent == 40)
        #expect(snapshot.usage.buckets.first { $0.id == "codex_spark" }?.primary?.usedPercent == 12)
    }
}

@Test(.timeLimit(.minutes(1)))
func codexAccountMalformedUsageIsAnExplicitFailedProbeRatherThanAnEmptyAllowance() async throws {
    let bad: JSONValue = .object(["rateLimits": .object(["primary": .object(["usedPercent": .string("synthetic-private-token")])])])
    try await withAccountPeer(["usage": bad]) { peer in
        let snapshot = try await peer.session.codexAccountSnapshot()
        #expect(snapshot.usage == .probeFailed(previous: nil))
    }
    try await withAccountPeer(["updatesAfterUsage": .array([.object(["method": .string("account/rateLimits/updated"), "params": bad])])]) { peer in
        let snapshot = try await peer.session.codexAccountSnapshot()
        #expect(snapshot.usage == .probeFailed(previous: nil))
    }
}

@Test(.timeLimit(.minutes(1)))
func codexAccountCancellationAndDeadlineRetireReadOwnershipWithoutChangingAuthentication() async throws {
    try await withAccountPeer(["usageDelay": .number(5)]) { peer in
        let read = Task { try await peer.session.codexAccountSnapshot() }
        let deadline = ContinuousClock.now + .seconds(3)
        while try !peer.frames().contains(where: { $0["method"] == .string("account/rateLimits/read") }) {
            guard ContinuousClock.now < deadline else { throw CoincideError("The account fixture did not start its usage read.") }
            try await Task.sleep(for: .milliseconds(5))
        }
        read.cancel()
        do { _ = try await read.value; Issue.record("A canceled account read returned a snapshot.") }
        catch { #expect(error is CancellationError) }
        #expect(try peer.frames().allSatisfy { ["initialize", "initialized", "account/read", "account/rateLimits/read"].contains($0["method"].string ?? "") })
    }
    try await withAccountPeer(["usageDelay": .number(5)]) { peer in
        try await peer.session.connect()
        let start = ContinuousClock.now
        do { _ = try await peer.session.readCodexAccountSnapshot(timeout: .milliseconds(100)); Issue.record("A timed-out account read succeeded.") }
        catch { #expect(!(error is CancellationError)) }
        #expect(start.duration(to: .now) < .seconds(2))
    }
}
