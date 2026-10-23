import Foundation
import Testing
@testable import CoincideCore

private func controlCaptureFixture(_ provider: ProviderKind) throws -> (WorkspaceSnapshot, ProviderModel) {
    let project = WorkspaceProject(path: "/private/model-control-capture")
    var thread = CodingThread(project: project, model: "same-advertised-model"); thread.provider = provider
    thread.draft = "Keep current authored draft 工作 e\u{301}\n "
    if provider == .claude {
        thread.claudeRuntimeConfiguration = .init(executable: "/offline/claude", configurationDirectory: "/private/claude-one", workspacePath: project.path)
        thread.agentConfiguration = try ClaudeModelControl.setting(.init(effort: "max"), in: nil)
    } else { thread.agentConfiguration = try CodexServiceTier.setting("priority", in: nil) }
    thread.agentConfiguration?["captureMarker"] = .string("a\u{301}\u{327}")
    var snapshot = WorkspaceSnapshot(); snapshot.projects = [project]; snapshot.threads = [thread]
    let row = ProviderModel(id: thread.model, name: "Same advertised row", reasoningEfforts: [.init(id: "high", description: "High"), .init(id: "max", description: "Max")],
        claudeCapabilities: .init(supportsFastMode: true), codexServiceTiers: [.init(id: "priority", name: "Priority", description: "Native"), .init(id: "ultrafast", name: "Ultrafast", description: "Native")])
    return (snapshot, row)
}

@Test(arguments: ["codex-profile", "codex-options", "codex-unicode", "claude-profile", "claude-options", "claude-unicode"])
func providerModelControlCaptureRefusesStaleSameRowProfileSiblingOptionsAndExactUnicode(change: String) throws {
    let provider: ProviderKind = change.hasPrefix("claude") ? .claude : .codex
    var (snapshot, row) = try controlCaptureFixture(provider)
    let expected = ProviderConfiguration(thread: snapshot.threads[0]), id = snapshot.threads[0].id
    if change.hasSuffix("profile") {
        if provider == .claude { snapshot.threads[0].claudeRuntimeConfiguration = .init(executable: "/offline/claude", configurationDirectory: "/private/claude-two", workspacePath: snapshot.projects[0].path) }
        else { snapshot.threads[0].codexRuntimeConfiguration = .init(instanceID: UUID()) }
    } else if change.hasSuffix("options") {
        snapshot.threads[0].agentConfiguration = provider == .claude
            ? try ClaudeModelControl.setting(.init(effort: "high", fastMode: true), in: snapshot.threads[0].agentConfiguration)
            : try CodexServiceTier.setting("ultrafast", in: snapshot.threads[0].agentConfiguration)
    } else {
        snapshot.threads[0].agentConfiguration?["captureMarker"] = .string("a\u{327}\u{301}")
        #expect(ProviderConfiguration(thread: snapshot.threads[0]) == expected)
    }
    #expect(!ProviderConfiguration(thread: snapshot.threads[0]).matchesModelControlCapture(expected))
    let action: ThreadEdit = provider == .claude ? .claudeModelOptions(model: row, options: .init(effort: "high"), expected: expected)
        : .codexServiceTier(model: row, tier: "default", expected: expected)
    for edit in [action, .resetProviderModelOptions(expected: expected)] {
        #expect(throws: WorkspaceCommandError.self) {
            _ = try WorkspaceDecision.make(.client(.editThread(id, edit)), id: UUID(), snapshot: snapshot, now: Date(), validatingLedger: false)
        }
    }
    #expect(snapshot.threads[0].draft.utf8.elementsEqual("Keep current authored draft 工作 e\u{301}\n ".utf8))
}

@Test func providerModelControlCaptureAllowsCurrentMetadataEditsWithoutChangingDraftOrStartingRuntime() throws {
    let (snapshot, row) = try controlCaptureFixture(.claude), thread = snapshot.threads[0]
    let expected = ProviderConfiguration(thread: thread)
    let result = try WorkspaceDecision.make(.client(.editThread(thread.id, .claudeModelOptions(model: row, options: .init(effort: "high"), expected: expected))),
        id: UUID(), snapshot: snapshot, now: Date(), validatingLedger: false)
    let options = try ClaudeModelControl.options(in: .init(thread: result.snapshot.threads[0]))
    #expect(options.effort == "high" && result.snapshot.threads[0].draft == thread.draft)
    #expect(result.effects.isEmpty && result.closeRuntimes.isEmpty)
}

@Test func providerModelControlCaptureCodecKeepsLegacyOptionalExpectationAbsentAndRoundTripsExactBytes() throws {
    let (snapshot, row) = try controlCaptureFixture(.codex), expected = ProviderConfiguration(thread: snapshot.threads[0])
    let legacy = ThreadEdit.codexServiceTier(model: row, tier: "priority")
    let bytes = try JSONEncoder().encode(legacy), object = try JSONSerialization.jsonObject(with: bytes) as? [String: [String: Any]]
    #expect(object?["codexServiceTier"]?["expected"] == nil)
    let decoded = try JSONDecoder().decode(ThreadEdit.self, from: bytes)
    if case .codexServiceTier(_, _, let oldExpected) = decoded { #expect(oldExpected == nil) } else { Issue.record("Legacy controls changed case") }
    let captured = ThreadEdit.resetProviderModelOptions(expected: expected)
    let copy = try JSONDecoder().decode(ThreadEdit.self, from: JSONEncoder().encode(captured))
    if case .resetProviderModelOptions(let decodedExpected) = copy { #expect(decodedExpected?.matchesModelControlCapture(expected) == true) }
    else { Issue.record("Captured reset changed case") }
    let oldReset = Data(#"{"resetProviderModelOptions":{}}"#.utf8)
    if case .resetProviderModelOptions(let decodedExpected) = try JSONDecoder().decode(ThreadEdit.self, from: oldReset) { #expect(decodedExpected == nil) }
    else { Issue.record("Legacy reset changed case") }
}
