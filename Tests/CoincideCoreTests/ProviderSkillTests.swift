import Foundation
import Testing
@testable import CoincideCore

private struct SkillsPeer: Sendable {
    let root: URL
    let wire: URL
    let session: CodexSession
    init(_ options: [String: JSONValue]) throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("coincide-skills-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        wire = root.appendingPathComponent("wire.jsonl")
        let configuration = root.appendingPathComponent("options.json")
        try JSONEncoder().encode(options).write(to: configuration, options: .atomic)
        let script = try #require(Bundle.module.url(forResource: "codex_skills", withExtension: "py", subdirectory: "Fixtures"))
        session = try CodexSession(executable: URL(fileURLWithPath: "/usr/bin/python3"), cwd: root,
                                   arguments: [script.path, configuration.path, wire.path])
    }
    func frames() throws -> [JSONValue] {
        guard FileManager.default.fileExists(atPath: wire.path) else { return [] }
        let bytes = try Data(contentsOf: wire)
        return try bytes.split(separator: 10).dropLast(bytes.last == 10 ? 0 : 1).map { try JSONDecoder().decode(JSONValue.self, from: Data($0)) }
    }
    func release() throws { try Data().write(to: root.appendingPathComponent("release-skills")) }
    func close() async { try? release(); await session.close(); try? FileManager.default.removeItem(at: root) }
}

private func withSkillsPeer(_ options: [String: JSONValue] = [:], body: (SkillsPeer) async throws -> Void) async throws {
    let peer = try SkillsPeer(options)
    do { try await body(peer); await peer.close() }
    catch { await peer.close(); throw error }
}
private func skillRow(_ name: String = "review", path: String = "relative/SKILL.md", enabled: Bool = true) -> JSONValue {
    .object(["name": .string(name), "path": .string(path), "description": .string("Native description"), "scope": .string("repo"), "enabled": .bool(enabled)])
}
private func skillResponse(cwd: String, skills: [JSONValue], errors: [JSONValue] = []) -> JSONValue {
    .object(["data": .array([.object(["cwd": .string(cwd), "skills": .array(skills), "errors": .array(errors)])])])
}
private func skillsEventually(_ predicate: () async throws -> Bool) async throws {
    let deadline = ContinuousClock.now + .seconds(3)
    while try await !predicate() {
        guard ContinuousClock.now < deadline else { throw CoincideError("The offline skills peer did not reach its expected boundary.") }
        try await Task.sleep(for: .milliseconds(5))
    }
}

private actor UnsupportedSkillsSession: ProviderSession {
    nonisolated let events = AsyncStream<ProviderEvent> { $0.finish() }
    func models() -> [ProviderModel] { [] }
    func send(text: String, thread: CodingThread) throws { throw ProviderSkillError(.unsupported) }
    func interrupt() { }
    func respond(_ request: ApprovalRequest, allow: Bool) { }
    func answer(_ request: ApprovalRequest, answers: [String: String]) { }
    func close() { }
}

@Test func providerSkillDefaultUnsupportedIsDistinctFromAnAvailableEmptyInventory() async throws {
    let session: any ProviderSession = UnsupportedSkillsSession()
    await #expect(throws: ProviderSkillError(.unsupported)) { try await session.codexSkills(forceReload: false) }
    let available = ProviderSkillInventory(cwd: "/synthetic-workspace", skills: [])
    try available.validate()
    #expect(available.skills.isEmpty && !available.isPartial)
}

@Test(arguments: ["review", "2spec", "namespace:review", "with_under-score"])
func providerSkillStableIdentityAndExactMentionGrammarPermitAdvertisedNames(name: String) throws {
    let first = ProviderSkill(name: name, path: "raw/relative/SKILL.md", description: "Source metadata", scope: "repo")
    try first.validate()
    #expect(first.canInvokeFromComposer && first.promptToken == "$" + name)
    #expect(first.id == ProviderSkill(name: name, path: first.path, description: "Refreshed display only", scope: "repo").id)
    #expect(first.id != ProviderSkill(name: name, path: "/different/SKILL.md", scope: "repo").id)
}

@Test(arguments: ["2k", "2e3", "20", "has space", "with.dot", "_prefix", "日本語", "bad\nname"])
func providerSkillMentionGrammarDoesNotInventTokensOrPermitAgentOnlyOrDisabledNames(name: String) {
    #expect(ProviderSkill(name: name, path: "opaque").promptToken == nil)
    #expect(!ProviderSkill(name: "review", path: "opaque", userInvocable: false).canInvokeFromComposer)
    #expect(!ProviderSkill(name: "review", path: "opaque", enabled: false).canInvokeFromComposer)
}

@Test(.timeLimit(.minutes(1))) func codexSkillsListUsesExactCwdAndReloadFlagWithoutCreatingConversation() async throws {
    try await withSkillsPeer { peer in
        let first = try await peer.session.codexSkills(forceReload: false), second = try await peer.session.codexSkills(forceReload: true)
        #expect(first.cwd == peer.root.path && second.workspacePath == peer.root.path && first.problems.isEmpty)
        let skill = try #require(first.skills.first)
        #expect(skill.name == "review-follow-up" && skill.path == "relative/SKILL.md" && skill.displayName == "Offline Review")
        #expect(skill.shortDescription == "Native interface summary" && skill.userInvocable && skill.promptToken == "$review-follow-up")
        #expect(second.skills == first.skills)
        let frames = try peer.frames(), requests = frames.filter { $0["method"] == .string("skills/list") }
        #expect(requests.map { $0["params"] } == [
            .object(["cwds": .array([.string(peer.root.path)]), "forceReload": .bool(false)]),
            .object(["cwds": .array([.string(peer.root.path)]), "forceReload": .bool(true)])])
        #expect(frames.filter { $0["method"] == .string("initialize") }.count == 1)
        #expect(frames.allSatisfy { ["initialize", "initialized", "skills/list"].contains($0["method"].string ?? "") })
    }
}

@Test(.timeLimit(.minutes(1)), arguments: [-32601, -32602, -32000, 401])
func codexSkillsNegotiatesUnsupportedSeparatelyFromSanitizedFailedProbe(code: Int) async throws {
    try await withSkillsPeer(["error": .number(Double(code))]) { peer in
        do { _ = try await peer.session.codexSkills(forceReload: true); Issue.record("A failing skills RPC returned an inventory.") }
        catch let error as ProviderSkillError {
            #expect(error.kind == ([-32601, -32602].contains(code) ? .unsupported : .unavailable))
            #expect(!error.localizedDescription.contains("synthetic-private-skill-error"))
        }
        let frames = try peer.frames()
        #expect(frames.filter { $0["method"] == .string("skills/list") }.count == 1)
        #expect(frames.allSatisfy { ["initialize", "initialized", "skills/list"].contains($0["method"].string ?? "") })
    }
}

@Test func codexSkillParserPreservesPartialNativeErrorsDisabledRowsAndLegacySummaryPrecedence() async throws {
    try await withSkillsPeer { peer in
        var good = try #require(skillRow().object)
        good["shortDescription"] = .string("Legacy summary")
        good["interface"] = .object(["displayName": .string("Friendly Review"), "shortDescription": .string("Interface summary")])
        let invalid: JSONValue = .object(["name": .string("bad"), "path": .string(""), "enabled": .bool(true)])
        let inventory = try CodexSkillInventory.decode(skillResponse(cwd: peer.root.path,
            skills: [.object(good), .object(good), skillRow("disabled", enabled: false), invalid],
            errors: [.object(["path": .string("bad/SKILL.md"), "message": .string("synthetic-private-skill-error")])]), cwd: peer.root.path)
        #expect(inventory.skills.map(\.name) == ["review", "disabled"] && inventory.isPartial && inventory.problems.count == 2)
        #expect(inventory.skills[0].shortDescription == "Legacy summary" && inventory.skills[0].displayName == "Friendly Review")
        #expect(!inventory.skills[1].enabled && !inventory.skills[1].canInvokeFromComposer)
        #expect(inventory.problems.allSatisfy { !$0.message.contains("synthetic-private-skill-error") })
        #expect(inventory.problems[1].path == nil)
    }
}

@Test func codexSkillParserOmitsAllConflictingCopiesRatherThanSelectingEnabledOrDisabledArbitrarily() async throws {
    try await withSkillsPeer { peer in
        let inventory = try CodexSkillInventory.decode(skillResponse(cwd: peer.root.path,
            skills: [skillRow(), skillRow(enabled: false), skillRow(), skillRow("independent")]), cwd: peer.root.path)
        #expect(inventory.skills.map(\.name) == ["independent"] && inventory.problems.count == 1)
    }
}

@Test func codexSkillParserBindsPhysicalWorkspaceAndNeverFallsBackToAnotherCwd() async throws {
    try await withSkillsPeer { peer in
        let alias = peer.root.appendingPathComponent("workspace-alias")
        try FileManager.default.createSymbolicLink(at: alias, withDestinationURL: peer.root)
        let aliased = try CodexSkillInventory.decode(skillResponse(cwd: alias.path, skills: [skillRow()]), cwd: peer.root.path)
        #expect(aliased.cwd == peer.root.path && aliased.skills.count == 1)
        let foreign = peer.root.appendingPathComponent("foreign")
        try FileManager.default.createDirectory(at: foreign, withIntermediateDirectories: false)
        #expect(throws: ProviderSkillError(.invalidResponse)) {
            try CodexSkillInventory.decode(skillResponse(cwd: foreign.path, skills: [skillRow()]), cwd: peer.root.path)
        }
        let duplicate: JSONValue = .object(["data": .array([
            .object(["cwd": .string(alias.path), "skills": .array([]), "errors": .array([])]),
            .object(["cwd": .string(peer.root.path), "skills": .array([]), "errors": .array([])])])])
        #expect(throws: ProviderSkillError(.invalidResponse)) { try CodexSkillInventory.decode(duplicate, cwd: peer.root.path) }
    }
}

@Test(arguments: ["shape", "rows", "problems", "bytes", "missing"])
func codexSkillParserRejectsBoundedMalformedOrOversizedResponses(kind: String) async throws {
    try await withSkillsPeer { peer in
        var response = skillResponse(cwd: peer.root.path, skills: [])
        switch kind {
        case "shape": response = .array([])
        case "rows": response = skillResponse(cwd: peer.root.path, skills: Array(repeating: skillRow(), count: 2_001))
        case "problems": response = skillResponse(cwd: peer.root.path, skills: [], errors: Array(repeating: .object(["path": .string("bad"), "message": .string("bad")]), count: 257))
        case "bytes": response = .object(["data": .array([]), "unknown": .string(String(repeating: "x", count: 4_194_305))])
        default: response = .object(["data": .array([])])
        }
        let invalid = response
        #expect(throws: ProviderSkillError(.invalidResponse)) { try CodexSkillInventory.decode(invalid, cwd: peer.root.path) }
    }
}

@Test(.timeLimit(.minutes(1))) func codexSkillsCancellationRetiresOnlyTheReadAndLateReplyDoesNotStartOrBreakConversation() async throws {
    try await withSkillsPeer(["holdFirst": .bool(true)]) { peer in
        let pending = Task { try await peer.session.codexSkills(forceReload: true) }
        do {
            try await skillsEventually { try peer.frames().contains { $0["method"] == .string("skills/list") } }
            pending.cancel()
            await #expect(throws: CancellationError.self) { try await pending.value }
            let models = try await peer.session.models(); #expect(models.map(\.id) == ["synthetic-model"])
            try peer.release()
            let inventory = try await peer.session.codexSkills(forceReload: false); #expect(inventory.skills.count == 1)
            let frames = try peer.frames()
            #expect(frames.filter { $0["method"] == .string("skills/list") }.count == 2)
            #expect(frames.allSatisfy { ["initialize", "initialized", "skills/list", "model/list"].contains($0["method"].string ?? "") })
        } catch { try? peer.release(); pending.cancel(); _ = await pending.result; throw error }
    }
}

private actor SkillLifetime {
    var acquires = 0, accessReleases = 0, resourceReleases = 0
    func acquire(_ session: CodexSession, revision: UUID) -> CodexOwnedSessionAccess {
        acquires += 1
        return .init(credentialRevision: revision, resolve: {
            .init(session: session, credentialRevision: revision, release: { await self.releaseResource() })
        }, release: { await self.releaseAccess() })
    }
    func releaseAccess() { accessReleases += 1 }
    func releaseResource() { resourceReleases += 1 }
}

@Test(.timeLimit(.minutes(1))) func codexOwnedSkillsDelegateUsingPrivateAccessAndKeepOlderHistoryAndSteeringGates() async throws {
    try await withSkillsPeer(["userAgent": .string("coincide/0.156.1")]) { peer in
        let lifetime = SkillLifetime(), revision = UUID()
        let configuration = CodexRuntimeConfiguration(homeDirectory: peer.root.path, authenticationMode: .ownedChatGPT,
            accountBinding: .init(profileID: UUID(), generation: UUID()))
        let wrapper = CodexOwnedSession(configuration: configuration, cwd: peer.root,
            acquireAccess: { await lifetime.acquire(peer.session, revision: revision) },
            accountSnapshot: { throw CoincideError("This test never reads an account.") })
        do {
            let before = await lifetime.acquires; #expect(before == 0)
            let inventory = try await wrapper.codexSkills(forceReload: true); #expect(inventory.skills.count == 1)
            let capabilities = try await wrapper.historyCapabilities(threadID: "existing-native-id")
            let steering = await wrapper.steeringCapabilities()
            #expect(!capabilities.canRead && !capabilities.canForkHead && !capabilities.canRevertBeforeTurn && !steering.supportsActiveSteering)
            let frames = try peer.frames()
            #expect(frames.allSatisfy { ["initialize", "initialized", "skills/list"].contains($0["method"].string ?? "") })
            await wrapper.close()
            let acquires = await lifetime.acquires, access = await lifetime.accessReleases, resources = await lifetime.resourceReleases
            #expect(acquires == 1 && access == 1 && resources == 1)
        } catch { await wrapper.close(); throw error }
    }
}
